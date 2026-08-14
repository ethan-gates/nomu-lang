// 6.5.1 — conservative, intra-procedural escape analysis on NOIR (design: m6-spec.md §6.5).
//
// Produces a side table of allocation sites proven not to escape their frame; codegen (6.5.2)
// consumes it to stack-allocate / scalar-replace those sites. Best-effort: a site absent from the
// table heap-allocates exactly as before, so precision affects speed only, correctness always holds.
//
// Targets, the reference allocations in NOIR: a class-instance `construct` and a `closure`. Structs
// and enums are value types (no heap allocation); actors, `any`-boxes, and array buffers are out of
// scope for this phase (m6-spec §6.5). The analysis is intra-procedural — a value that is returned,
// stored into a heap field or a variable, passed to a call, spawned, or captured by a closure is
// treated as escaping. A local `let` bound directly to an allocation stays non-escaping as long as
// that local is only read (field access, or invoked as a call target) and never itself escapes.

public struct AllocSite: Hashable {
    public enum Kind: Hashable { case classInstance, closure }
    public let file: String
    public let startOffset: Int
    public let endOffset: Int
    public let kind: Kind
    public init(span: Span, kind: Kind) {
        file = span.file; startOffset = span.startOffset; endOffset = span.endOffset; self.kind = kind
    }
}

public struct EscapeResult {
    public let nonEscaping: Set<AllocSite>
    public init(nonEscaping: Set<AllocSite>) { self.nonEscaping = nonEscaping }
    // Codegen (6.5.2) queries a site by its span + kind; a miss means "heap-allocate as before".
    public func isNonEscaping(_ span: Span, _ kind: AllocSite.Kind) -> Bool {
        nonEscaping.contains(AllocSite(span: span, kind: kind))
    }
}

public func analyzeEscapes(_ module: NOIRModule) -> EscapeResult {
    var classNames: Set<String> = []
    for decl in module.decls { if case .classDecl(let c) = decl { classNames.insert(c.name) } }

    var nonEscaping: Set<AllocSite> = []
    func run(_ body: [NOIRStmt]) {
        let scope = BodyEscape(classNames: classNames)
        scope.analyze(body)
        nonEscaping.formUnion(scope.nonEscaping)
    }
    for decl in module.decls {
        switch decl {
        case .funcDecl(let f): run(f.body)
        case .structDecl(let s): for m in s.methods { run(m.body) }
        case .enumDecl(let e): for m in e.methods { run(m.body) }
        case .classDecl(let c): for m in c.methods { run(m.body) }
        case .actorDecl(let a): for h in a.handlers { run(h.body) }
        }
    }
    return EscapeResult(nonEscaping: nonEscaping)
}

// One function/method/handler body's worth of analysis. Collect escaping facts in a single walk,
// then decide: an allocation-bound local is non-escaping when its name never lands in `escapingVars`.
private final class BodyEscape {
    let classNames: Set<String>
    // A local `let` bound directly to an allocation site: name → its site.
    private var allocLets: [String: AllocSite] = [:]
    // Names that escape: used in an escaping position, reassigned, captured by a closure, or bound
    // more than once (shadowed → given up on).
    private var escapingVars: Set<String> = []
    // Allocation sites met inline (not bound to a local) in a non-escaping position.
    private var inlineNonEscaping: Set<AllocSite> = []

    init(classNames: Set<String>) { self.classNames = classNames }

    var nonEscaping: Set<AllocSite> {
        var result = inlineNonEscaping
        for (name, site) in allocLets where !escapingVars.contains(name) { result.insert(site) }
        return result
    }

    func analyze(_ body: [NOIRStmt]) { for s in body { walkStmt(s) } }

    // Is `e` one of our target allocation sites? Returns its kind, or nil.
    private func allocKind(_ e: NOIRExpr) -> AllocSite.Kind? {
        switch e.kind {
        case .construct(let typeName, _): return classNames.contains(typeName) ? .classInstance : nil
        case .closure: return .closure
        default: return nil
        }
    }

    private func walkStmt(_ s: NOIRStmt) {
        switch s.kind {
        case .letBinding(let name, _, let value):
            if let kind = allocKind(value) {
                if allocLets[name] != nil || escapingVars.contains(name) {
                    escapingVars.insert(name)              // shadowed / multiply-bound → give up on it
                } else {
                    allocLets[name] = AllocSite(span: value.span, kind: kind)
                }
                walkAllocChildren(value)                   // fate of the site itself follows `name`
            } else {
                walkExpr(value, escaping: true)            // binds an alias into a local — conservative
            }
        case .spawnLet(_, let value, _):
            walkExpr(value, escaping: true)                // handed to another fiber
        case .assign(let target, let value):
            walkAssign(target: target, value: value)
        case .compoundAssign(let target, let value):
            walkAssign(target: target, value: value)
        case .ret(let e):
            if let e { walkExpr(e, escaping: true) }
        case .ifStmt(let cond, let then, let els):
            walkExpr(cond, escaping: false)
            analyze(then); if let els { analyze(els) }
        case .whileStmt(let cond, let body):
            walkExpr(cond, escaping: false); analyze(body)
        case .breakStmt, .continueStmt:
            break
        case .switchStmt(let sw):
            walkExpr(sw.subject, escaping: true)           // subject flows into the arm bindings
            for arm in sw.arms { analyze(arm.body) }
        case .exprStmt(let e):
            walkExpr(e, escaping: false)                   // value discarded
        }
    }

    private func walkAssign(target: NOIRExpr, value: NOIRExpr) {
        switch target.kind {
        case .varRef(let n):
            escapingVars.insert(n)                         // reassigned — its binding is no longer a single site
            walkExpr(value, escaping: true)
        case .fieldAccess(let base, _):
            walkExpr(base, escaping: false)                // base is read to reach its field
            walkExpr(value, escaping: true)                // stored into a heap field
        case .index(let base, let idx):
            walkExpr(base, escaping: false); walkExpr(idx, escaping: false)
            walkExpr(value, escaping: true)                // stored into an array buffer
        default:
            walkExpr(target, escaping: true); walkExpr(value, escaping: true)
        }
    }

    // Walk the children of an allocation whose own fate is decided elsewhere (it is `let`-bound).
    private func walkAllocChildren(_ e: NOIRExpr) {
        switch e.kind {
        case .construct(_, let args):
            for a in args { walkExpr(a.value, escaping: true) }
        case .closure(_, let body):
            enterClosure(body)
        default:
            break
        }
    }

    private func walkExpr(_ e: NOIRExpr, escaping: Bool) {
        // A target allocation met inline (not `let`-bound) in a non-escaping position is stack-eligible.
        if !escaping, let kind = allocKind(e) {
            inlineNonEscaping.insert(AllocSite(span: e.span, kind: kind))
        }
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit:
            break
        case .varRef(let name):
            if escaping { escapingVars.insert(name) }
        case .fieldAccess(let base, _):
            walkExpr(base, escaping: false)                // reading a field never leaks the base
        case .construct(_, let args):
            for a in args { walkExpr(a.value, escaping: true) }
        case .enumInit(_, _, let args):
            for a in args { walkExpr(a.value, escaping: true) }
        case .methodCall(let receiver, _, let args):
            walkExpr(receiver, escaping: true)             // `self` may be captured by the method
            for a in args { walkExpr(a, escaping: true) }
        case .call(let callee, let args, _):
            walkExpr(callee, escaping: false)              // invoking a value does not leak it
            for a in args { walkExpr(a.value, escaping: true) }
        case .binary(_, let l, let r):
            walkExpr(l, escaping: true); walkExpr(r, escaping: true)
        case .closure(_, let body):
            enterClosure(body)
        case .box(let value, _):
            walkExpr(value, escaping: true)                // wrapped into a heap `any`-box
        case .arrayLit(let elements):
            for el in elements { walkExpr(el, escaping: true) }
        case .index(let base, let idx):
            walkExpr(base, escaping: false); walkExpr(idx, escaping: false)
        }
    }

    // A closure's body is analyzed as its own scope; its non-escaping allocations fold up unchanged
    // (they are local to the closure's own frame regardless of whether the closure itself escapes).
    // Every name the body references is conservatively treated as captured → escaping in this scope.
    private func enterClosure(_ body: [NOIRStmt]) {
        for name in referencedNames(body) { escapingVars.insert(name) }
        let nested = BodyEscape(classNames: classNames)
        nested.analyze(body)
        inlineNonEscaping.formUnion(nested.nonEscaping)
    }
}

// Every variable name referenced anywhere in a statement subtree — the conservative capture set for a
// closure body.
private func referencedNames(_ body: [NOIRStmt]) -> Set<String> {
    var names: Set<String> = []
    for s in body { collectNames(s, into: &names) }
    return names
}

private func collectNames(_ s: NOIRStmt, into names: inout Set<String>) {
    switch s.kind {
    case .letBinding(_, _, let value): collectNames(value, into: &names)
    case .spawnLet(_, let value, _): collectNames(value, into: &names)
    case .assign(let t, let v), .compoundAssign(let t, let v):
        collectNames(t, into: &names); collectNames(v, into: &names)
    case .ret(let e): if let e { collectNames(e, into: &names) }
    case .ifStmt(let cond, let then, let els):
        collectNames(cond, into: &names)
        for st in then { collectNames(st, into: &names) }
        if let els { for st in els { collectNames(st, into: &names) } }
    case .whileStmt(let cond, let body):
        collectNames(cond, into: &names)
        for st in body { collectNames(st, into: &names) }
    case .breakStmt, .continueStmt: break
    case .switchStmt(let sw):
        collectNames(sw.subject, into: &names)
        for arm in sw.arms { for st in arm.body { collectNames(st, into: &names) } }
    case .exprStmt(let e): collectNames(e, into: &names)
    }
}

private func collectNames(_ e: NOIRExpr, into names: inout Set<String>) {
    switch e.kind {
    case .intLit, .doubleLit, .boolLit, .stringLit: break
    case .varRef(let n): names.insert(n)
    case .fieldAccess(let base, _): collectNames(base, into: &names)
    case .construct(_, let args), .enumInit(_, _, let args):
        for a in args { collectNames(a.value, into: &names) }
    case .methodCall(let recv, _, let args):
        collectNames(recv, into: &names)
        for a in args { collectNames(a, into: &names) }
    case .call(let callee, let args, _):
        collectNames(callee, into: &names)
        for a in args { collectNames(a.value, into: &names) }
    case .binary(_, let l, let r): collectNames(l, into: &names); collectNames(r, into: &names)
    case .closure(_, let body): for st in body { collectNames(st, into: &names) }
    case .box(let value, _): collectNames(value, into: &names)
    case .arrayLit(let elements): for el in elements { collectNames(el, into: &names) }
    case .index(let base, let idx): collectNames(base, into: &names); collectNames(idx, into: &names)
    }
}
