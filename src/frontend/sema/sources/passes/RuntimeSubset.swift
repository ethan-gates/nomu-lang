import noir
import support
// Runtime-subset check — a read-only NOIR pass (task 149).
//
// A designated function (named via --runtime-subset) may not touch the managed heap
// or call back into the runtime: no class/actor construction, no closures, no `any`
// boxing, no array literals, no `spawn`, and it may call only other designated
// functions or the low-level primitives (__raw*/__ptr*/__gc*/__atomic*/__sys*, and
// pure C leaves). The rules are opt-in — with no designated names the pass is inert.
// It emits diagnostics only; the module is not rewritten.

public func checkRuntimeSubset(_ module: NOIRModule, designated: Set<String>, into diags: DiagnosticSink) {
    guard !designated.isEmpty else { return }
    RuntimeSubsetPass(module: module, designated: designated, diags: diags).run()
}

private struct RuntimeSubsetPass {
    private let decls: [NOIRDecl]
    private let designated: Set<String>
    private let diags: DiagnosticSink
    // Constructing a class or actor allocates on the managed heap. The names are taken
    // from the module's own decls rather than the AST-side tables, so the pass depends
    // only on the module it is handed.
    private let heapTypes: Set<String>

    init(module: NOIRModule, designated: Set<String>, diags: DiagnosticSink) {
        self.decls = module.decls
        self.designated = designated
        self.diags = diags
        var heap: Set<String> = []
        for decl in module.decls {
            switch decl {
            case .classDecl(let c): heap.insert(c.name)
            case .actorDecl(let a): heap.insert(a.name)
            default: break
            }
        }
        self.heapTypes = heap
    }

    func run() {
        for decl in decls {
            guard case .funcDecl(let f) = decl, designated.contains(f.name) else { continue }
            for s in f.body { walkStmt(s, inFn: f.name) }
        }
    }

    // A callee a designated function may reach: the raw-memory/gc-leaf primitives and
    // pure non-allocating leaves, or another designated function.
    private func allows(_ name: String) -> Bool {
        if name.hasPrefix("__raw") || name.hasPrefix("__ptr") { return true }   // 125 raw memory (gc-leaf)
        if name.hasPrefix("__gc") { return true }                               // GC introspection reads (gc-leaf, task 150 rung 2)
        if name.hasPrefix("__atomic") { return true }                           // atomics (gc-leaf, scheduler substrate, task 128.1.1)
        if name.hasPrefix("__sys") { return true }                              // raw OS entries — clock/futex/thread (gc-leaf, scheduler substrate, task 128.1.1)
        if Builtins.cLeaf.contains(name) { return true }                        // pure C leaves
        switch name {
        case "__int_double_double", "__double_int_int", "__int_uint8_uint8", "__uint8_int_int": return true
        case "__schedHandle": return true                                       // gc-leaf read of rt_nomu_sched (scheduler substrate)
        default: return designated.contains(name)                               // another designated function
        }
    }

    private func walkStmt(_ s: NOIRStmt, inFn: String) {
        switch s.kind {
        case .letBinding(_, _, let v): walkExpr(v, inFn: inFn)
        case .spawnLet(_, let v, _):
            diags.error("runtime-subset function '\(inFn)' may not 'spawn' — it allocates a task", at: s.span)
            walkExpr(v, inFn: inFn)
        case .assign(let t, let v), .compoundAssign(let t, let v):
            walkExpr(t, inFn: inFn); walkExpr(v, inFn: inFn)
        case .ret(let e): if let e { walkExpr(e, inFn: inFn) }
        case .ifStmt(let c, let th, let el):
            walkExpr(c, inFn: inFn)
            th.forEach { walkStmt($0, inFn: inFn) }
            (el ?? []).forEach { walkStmt($0, inFn: inFn) }
        case .whileStmt(let c, let body):
            walkExpr(c, inFn: inFn)
            body.forEach { walkStmt($0, inFn: inFn) }
        case .switchStmt(let sw):
            walkExpr(sw.subject, inFn: inFn)
            for arm in sw.arms { arm.body.forEach { walkStmt($0, inFn: inFn) } }
        case .exprStmt(let e): walkExpr(e, inFn: inFn)
        case .breakStmt, .continueStmt: break
        }
    }

    private func walkExpr(_ e: NOIRExpr, inFn: String) {
        switch e.kind {
        case .construct(let typeName, let args):
            if heapTypes.contains(typeName) {
                diags.error("runtime-subset function '\(inFn)' may not allocate a '\(typeName)' — heap allocation is forbidden in runtime-subset code", at: e.span)
            }
            args.forEach { walkExpr($0.value, inFn: inFn) }
        case .closure:
            diags.error("runtime-subset function '\(inFn)' may not create a closure — it is heap-boxed", at: e.span)
        case .box(let v, _):
            diags.error("runtime-subset function '\(inFn)' may not box a value as 'any' — heap allocation", at: e.span)
            walkExpr(v, inFn: inFn)
        case .arrayLit(let elems):
            diags.error("runtime-subset function '\(inFn)' may not build an array — heap allocation", at: e.span)
            elems.forEach { walkExpr($0, inFn: inFn) }
        case .call(let callee, let args, _):
            if case .varRef(let name) = callee.kind, !allows(name) {
                diags.error("runtime-subset function '\(inFn)' may not call '\(name)' — only other runtime-subset functions and the raw-memory primitives are allowed", at: e.span)
            }
            args.forEach { walkExpr($0.value, inFn: inFn) }
        case .methodCall(let recv, _, let margs):
            walkExpr(recv, inFn: inFn); margs.forEach { walkExpr($0, inFn: inFn) }
        case .binary(_, let l, let r): walkExpr(l, inFn: inFn); walkExpr(r, inFn: inFn)
        case .fieldAccess(let base, _): walkExpr(base, inFn: inFn)
        case .index(let base, let idx): walkExpr(base, inFn: inFn); walkExpr(idx, inFn: inFn)
        case .enumInit(_, _, let args): args.forEach { walkExpr($0.value, inFn: inFn) }
        default: break   // literals, varRef, and other leaves carry no allocation or call
        }
    }
}
