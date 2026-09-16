import ast
import noir
import ssair
import support

// Closure conversion support: the per-module sink that collects lifted closure bodies and
// their synthesized environment layouts, and the free-variable collection that decides what
// each closure captures (respecting shadowing). Used by FunctionLowerer.lowerClosure.

// Shared across every `FunctionLowerer` in a module: closure conversion lifts each closure body to a
// top-level `SSAFunction` and synthesizes a struct layout for its captured environment. Both accumulate
// here (closures can appear in any function/method and can nest), collected after all bodies lower.
final class ClosureSink {
    var lifted: [SSAFunction] = []
    var envAggregates: [SSAAggregate] = []
    var nextId = 0
}

// MARK: - Free-variable collection (respects shadowing via `bound`) — ports the codegen analysis.

func collectUses(_ stmts: [NOIRStmt], _ bound: inout Set<String>, _ used: inout [String]) {
    for s in stmts { collectUsesStmt(s, &bound, &used) }
}

func collectUsesStmt(_ stmt: NOIRStmt, _ bound: inout Set<String>, _ used: inout [String]) {
    switch stmt.kind {
    case .letBinding(let name, _, let value):
        collectUsesExpr(value, bound, &used); bound.insert(name)
    case .spawnLet(let name, let value, _):
        collectUsesExpr(value, bound, &used); bound.insert(name)
    case .assign(let t, let v), .compoundAssign(let t, let v):
        collectUsesExpr(t, bound, &used); collectUsesExpr(v, bound, &used)
    case .ret(let e):
        if let e = e { collectUsesExpr(e, bound, &used) }
    case .ifStmt(let cond, let then, let els):
        collectUsesExpr(cond, bound, &used)
        var b1 = bound; collectUses(then, &b1, &used)
        if let els = els { var b2 = bound; collectUses(els, &b2, &used) }
    case .whileStmt(let cond, let body):
        collectUsesExpr(cond, bound, &used)
        var wb = bound; collectUses(body, &wb, &used)
    case .breakStmt, .continueStmt:
        break
    case .switchStmt(let sw):
        collectUsesExpr(sw.subject, bound, &used)
        for arm in sw.arms {
            var ab = bound
            for bnd in arm.bindings { ab.insert(bnd.name) }
            collectUses(arm.body, &ab, &used)
        }
    case .exprStmt(let e):
        collectUsesExpr(e, bound, &used)
    }
}

func collectUsesExpr(_ e: NOIRExpr, _ bound: Set<String>, _ used: inout [String]) {
    switch e.kind {
    case .intLit, .doubleLit, .boolLit, .stringLit, .funcRef:
        break                              // funcRef names a top-level function, not a captured local
    case .varRef(let n):
        if !bound.contains(n) { used.append(n) }
    case .fieldAccess(let base, _):
        collectUsesExpr(base, bound, &used)
    case .construct(_, let args), .enumInit(_, _, let args):
        for a in args { collectUsesExpr(a.value, bound, &used) }
    case .methodCall(let receiver, _, let args):
        collectUsesExpr(receiver, bound, &used)
        for a in args { collectUsesExpr(a, bound, &used) }
    case .call(let callee, let args, _):
        collectUsesExpr(callee, bound, &used)
        for a in args { collectUsesExpr(a.value, bound, &used) }
    case .binary(_, let l, let r):
        collectUsesExpr(l, bound, &used); collectUsesExpr(r, bound, &used)
    case .closure(let ps, let cbody):
        var nb = bound
        for p in ps { nb.insert(p.name) }
        collectUses(cbody, &nb, &used)
    case .box(let value, _):
        collectUsesExpr(value, bound, &used)
    case .arrayLit(let elements):
        for el in elements { collectUsesExpr(el, bound, &used) }
    case .index(let base, let idx):
        collectUsesExpr(base, bound, &used); collectUsesExpr(idx, bound, &used)
    case .staticCall(_, _, let args):
        for a in args { collectUsesExpr(a, bound, &used) }   // monomorphization lowers these to `call`
    }
}

