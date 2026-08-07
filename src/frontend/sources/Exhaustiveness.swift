// Exhaustiveness — an IR pass over the typed module (design: compiler.md §1; types.md §2).
//
// A `switch` on an enum must cover every case; there is no `_`/default arm, so
// exhaustiveness is exactly "every declared case appears." Runs after Sema on the
// typed IR (Rust runs it on THIR, the same altitude) and reports into the shared
// DiagnosticSink, collect-and-continue. Non-enum subjects are out of scope here.

public func checkExhaustiveness(_ module: IRModule, into diags: DiagnosticSink) {
    // Enum name → its full set of case names, gathered from the module's decls.
    var enumCases: [String: [String]] = [:]
    for decl in module.decls {
        if case .enumDecl(let e) = decl { enumCases[e.name] = e.cases.map(\.name) }
    }
    let pass = ExhaustivenessPass(enumCases: enumCases, diags: diags)
    pass.run(module)
}

private struct ExhaustivenessPass {
    let enumCases: [String: [String]]
    let diags: DiagnosticSink

    func run(_ module: IRModule) {
        for decl in module.decls { walkDecl(decl) }
    }

    // MARK: - Declarations (walk every body that can hold a switch)

    private func walkDecl(_ decl: IRDecl) {
        switch decl {
        case .funcDecl(let f):   walk(f.body)
        case .structDecl(let s): for m in s.methods { walk(m.body) }
        case .enumDecl(let e):   for m in e.methods { walk(m.body) }
        case .classDecl(let c):  for m in c.methods { walk(m.body) }
        case .actorDecl(let a):
            for field in a.fields { if let initv = field.initializer { walkExpr(initv) } }
            for h in a.handlers { walk(h.body) }
        }
    }

    // MARK: - Statements

    private func walk(_ stmts: [IRStmt]) {
        for s in stmts { walkStmt(s) }
    }

    private func walkStmt(_ stmt: IRStmt) {
        switch stmt.kind {
        case .letBinding(_, _, let value):    walkExpr(value)
        case .spawnLet(_, let value, _):      walkExpr(value)
        case .assign(let t, let v),
             .compoundAssign(let t, let v):   walkExpr(t); walkExpr(v)
        case .ret(let e):                     if let e { walkExpr(e) }
        case .ifStmt(let cond, let then, let els):
            walkExpr(cond); walk(then); if let els { walk(els) }
        case .whileStmt(let cond, let body):
            walkExpr(cond); walk(body)
        case .breakStmt, .continueStmt:
            break
        case .switchStmt(let sw):
            checkSwitch(sw, at: stmt.span)
            walkExpr(sw.subject)
            for arm in sw.arms { walk(arm.body) }
        case .exprStmt(let e):                walkExpr(e)
        }
    }

    // MARK: - Expressions (descend only to reach nested statement bodies)

    private func walkExpr(_ e: IRExpr) {
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef:
            break
        case .fieldAccess(let base, _):
            walkExpr(base)
        case .construct(_, let args), .enumInit(_, _, let args):
            for a in args { walkExpr(a.value) }
        case .methodCall(let receiver, _, let args):
            walkExpr(receiver); for a in args { walkExpr(a) }
        case .call(let callee, let args, _):
            walkExpr(callee); for a in args { walkExpr(a.value) }
        case .binary(_, let l, let r):
            walkExpr(l); walkExpr(r)
        case .closure(_, let body):
            walk(body)
        case .box(let value, _):
            walkExpr(value)
        case .arrayLit(let elements):
            for el in elements { walkExpr(el) }
        case .index(let base, let idx):
            walkExpr(base); walkExpr(idx)
        }
    }

    // MARK: - The check

    private func checkSwitch(_ sw: IRSwitch, at span: Span) {
        // A concrete enum (`.named`) or an applied generic one (`.generic`, M5 5.2.3): the case
        // set is the generic definition's — instantiation adds no cases.
        let enumName: String
        switch sw.subject.type {
        case .named(let n, .enum_): enumName = n
        case .generic(let n, _):    enumName = n
        default:                    return
        }
        guard let allCases = enumCases[enumName] else { return }
        let covered = Set(sw.arms.map(\.caseName))
        let missing = allCases.filter { !covered.contains($0) }
        if !missing.isEmpty {
            let list = missing.map { "'\($0)'" }.joined(separator: ", ")
            diags.error("switch must be exhaustive: missing case \(list)", at: span)
        }
    }
}
