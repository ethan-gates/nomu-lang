import noir
import ast
import support

// Producer-side reference canonicalization for `.bir` export (task 100.5.4 / 100.5 "A").
//
// A shipped generic body references other decls. Before serialization the producer rewrites every
// reference that names one of **its own** module decls to that decl's origin-keyed absolute identity
// (`origin@name`, the `ExternalName` encoding the consumer already resolves imports with, task 100.2.3.2).
// So when the consumer injects the body, its internal references speak the consumer's cross-module
// vocabulary and `Monomorphize` + the existing resolver bind them with no new namespace mechanism — a
// nested generic call (`relay` → `echo`) re-points at the injected `origin@echo`, which specializes
// transitively.
//
// Left bare (they resolve identically in the consumer): the generic's own type parameters, a body's
// locals / parameters / case bindings (scope-tracked), prelude and builtin names, and any reference
// already keyed to another module (not in this module's own-name set). Names are never double-encoded —
// own names are bare by construction.
//
// Only generic **functions** are canonicalized today (the shipped unit); a non-function decl rides
// through unchanged until generic types/methods are shipped (a later 100.5.4 increment).

// The identifiers a decl's body references (task 100.5.4): callee / variable names, func refs, and
// constructed/enum/static type names. Over-approximate — no scope tracking, so a shadowing local may add
// a spurious name, which at worst ships an unused decl (dead-stripped). Drives the private-callee closure
// a `.bir` must ship: the reachable non-public callees whose bodies the consumer needs to emit locally,
// since they are absent from the `.nmi` (interface-invisible) and so unknown to the consumer's Sema.
public func collectReferencedNames(_ decl: NOIRDecl) -> Set<String> {
    guard case .funcDecl(let f) = decl else { return [] }
    var names = Set<String>()
    func visitExpr(_ e: NOIRExpr) {
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit:
            break
        case .varRef(let n):                       names.insert(n)
        case .funcRef(let n):                      names.insert(n)
        case .construct(let tn, let args):         names.insert(tn); args.forEach { visitExpr($0.value) }
        case .enumInit(let tn, _, let args):       names.insert(tn); args.forEach { visitExpr($0.value) }
        case .fieldAccess(let base, _):            visitExpr(base)
        case .methodCall(let r, _, let args):      visitExpr(r); args.forEach(visitExpr)
        case .call(let callee, let args, _):       visitExpr(callee); args.forEach { visitExpr($0.value) }
        case .staticCall(_, _, let args):          args.forEach(visitExpr)
        case .binary(_, let l, let r):             visitExpr(l); visitExpr(r)
        case .closure(_, let body):                body.forEach(visitStmt)
        case .box(let v, _):                       visitExpr(v)
        case .arrayLit(let els):                   els.forEach(visitExpr)
        case .index(let b, let i):                 visitExpr(b); visitExpr(i)
        }
    }
    func visitStmt(_ s: NOIRStmt) {
        switch s.kind {
        case .letBinding(_, _, let v):             visitExpr(v)
        case .spawnLet(_, let v, _):               visitExpr(v)
        case .assign(let t, let v):                visitExpr(t); visitExpr(v)
        case .compoundAssign(let t, let v):        visitExpr(t); visitExpr(v)
        case .ret(let e):                          e.map(visitExpr)
        case .ifStmt(let c, let th, let el):       visitExpr(c); th.forEach(visitStmt); el?.forEach(visitStmt)
        case .whileStmt(let c, let body):          visitExpr(c); body.forEach(visitStmt)
        case .breakStmt, .continueStmt:            break
        case .switchStmt(let sw):                  visitExpr(sw.subject); sw.arms.forEach { $0.body.forEach(visitStmt) }
        case .exprStmt(let e):                     visitExpr(e)
        }
    }
    f.body.forEach(visitStmt)
    return names
}

public func canonicalizeForExport(_ decls: [NOIRDecl], origin: String, ownNames: Set<String>) -> [NOIRDecl] {
    let c = Canonicalizer(origin: origin, ownNames: ownNames)
    return decls.map { decl in
        if case .funcDecl(let f) = decl { return .funcDecl(c.function(f)) }
        return decl
    }
}

private final class Canonicalizer {
    let origin: String
    let ownNames: Set<String>
    init(origin: String, ownNames: Set<String>) { self.origin = origin; self.ownNames = ownNames }

    private func key(_ name: String) -> String { ExternalName.encode(origin: origin, name: name) }
    private func keyed(_ name: String) -> String { ownNames.contains(name) ? key(name) : name }

    // MARK: types
    func type(_ t: Type) -> Type {
        switch t {
        case .named(let n, let k):            return .named(keyed(n), k)
        case .generic(let base, let args):    return .generic(base: keyed(base), args: args.map(type))
        case .array(let e):                   return .array(type(e))
        case .ptr(let e):                     return .ptr(type(e))
        case .function(let p, let r):         return .function(params: p.map(type), ret: type(r))
        case .existential(let n):             return .existential(keyed(n))
        case .composition(let ns):            return .composition(ns.map(keyed))
        case .opaque(let ifs, let owner):     return .opaque(interfaces: ifs.map(keyed), owner: owner)
        default:                              return t
        }
    }

    // MARK: declarations
    func function(_ f: NOIRFunc) -> NOIRFunc {
        let bound = Set(f.params.map(\.name))
        return NOIRFunc(name: f.name,
            generics: f.generics.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(keyed), isShared: $0.isShared) },
            params: f.params.map { NOIRParam(label: $0.label, name: $0.name, type: type($0.type), span: $0.span) },
            returnType: type(f.returnType),
            body: stmts(f.body, bound),
            isMutating: f.isMutating, visibility: f.visibility, span: f.span)
    }

    // MARK: statements — threads the set of names bound so far (a later `let` shadows an own name)
    func stmts(_ ss: [NOIRStmt], _ bound: Set<String>) -> [NOIRStmt] {
        var b = bound
        var out: [NOIRStmt] = []
        for s in ss { let (rewritten, next) = stmt(s, b); out.append(rewritten); b = next }
        return out
    }

    func stmt(_ s: NOIRStmt, _ bound: Set<String>) -> (NOIRStmt, Set<String>) {
        func here(_ k: StmtKind) -> NOIRStmt { NOIRStmt(kind: k, span: s.span) }
        switch s.kind {
        case .letBinding(let name, let isMutable, let value):
            let v = expr(value, bound)
            return (here(.letBinding(name: name, isMutable: isMutable, value: v)), bound.union([name]))
        case .spawnLet(let name, let value, let resultType):
            let v = expr(value, bound)
            return (here(.spawnLet(name: name, value: v, resultType: type(resultType))), bound.union([name]))
        case .assign(let target, let value):
            return (here(.assign(target: expr(target, bound), value: expr(value, bound))), bound)
        case .compoundAssign(let target, let value):
            return (here(.compoundAssign(target: expr(target, bound), value: expr(value, bound))), bound)
        case .ret(let e):
            return (here(.ret(e.map { expr($0, bound) })), bound)
        case .ifStmt(let cond, let then, let els):
            return (here(.ifStmt(cond: expr(cond, bound), then: stmts(then, bound), else: els.map { stmts($0, bound) })), bound)
        case .whileStmt(let cond, let body):
            return (here(.whileStmt(cond: expr(cond, bound), body: stmts(body, bound))), bound)
        case .breakStmt, .continueStmt:
            return (s, bound)
        case .switchStmt(let sw):
            let arms = sw.arms.map { arm -> NOIRCaseArm in
                let inner = bound.union(arm.bindings.map(\.name))
                return NOIRCaseArm(caseName: arm.caseName,
                                   bindings: arm.bindings.map { NOIRBinding(name: $0.name, type: type($0.type)) },
                                   body: stmts(arm.body, inner), span: arm.span)
            }
            return (here(.switchStmt(NOIRSwitch(subject: expr(sw.subject, bound), arms: arms))), bound)
        case .exprStmt(let e):
            return (here(.exprStmt(expr(e, bound))), bound)
        }
    }

    // MARK: expressions
    func arg(_ a: NOIRArg, _ bound: Set<String>) -> NOIRArg { NOIRArg(label: a.label, value: expr(a.value, bound)) }

    func expr(_ e: NOIRExpr, _ bound: Set<String>) -> NOIRExpr {
        let t = type(e.type)
        func here(_ k: ExprKind) -> NOIRExpr { NOIRExpr(type: t, span: e.span, kind: k) }
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit:
            return here(e.kind)
        case .varRef(let n):
            return here(.varRef(bound.contains(n) ? n : keyed(n)))
        case .fieldAccess(let base, let field):
            return here(.fieldAccess(base: expr(base, bound), field: field))
        case .construct(let typeName, let args):
            return here(.construct(typeName: keyed(typeName), args: args.map { arg($0, bound) }))
        case .enumInit(let typeName, let caseName, let args):
            return here(.enumInit(typeName: keyed(typeName), caseName: caseName, args: args.map { arg($0, bound) }))
        case .methodCall(let receiver, let method, let args):
            return here(.methodCall(receiver: expr(receiver, bound), method: method, args: args.map { expr($0, bound) }))
        case .call(let callee, let args, let typeArgs):
            return here(.call(callee: expr(callee, bound), args: args.map { arg($0, bound) }, typeArgs: typeArgs.map(type)))
        case .staticCall(let onType, let method, let args):
            return here(.staticCall(onType: type(onType), method: method, args: args.map { expr($0, bound) }))
        case .binary(let op, let l, let r):
            return here(.binary(op, expr(l, bound), expr(r, bound)))
        case .closure(let params, let body):
            let inner = bound.union(params.map(\.name))
            return here(.closure(params: params.map { NOIRParam(label: $0.label, name: $0.name, type: type($0.type), span: $0.span) },
                                 body: stmts(body, inner)))
        case .box(let value, let interfaces):
            return here(.box(value: expr(value, bound), interfaces: interfaces.map(keyed)))
        case .arrayLit(let elements):
            return here(.arrayLit(elements: elements.map { expr($0, bound) }))
        case .index(let base, let idx):
            return here(.index(base: expr(base, bound), idx: expr(idx, bound)))
        case .funcRef(let name):
            return here(.funcRef(name: keyed(name)))
        }
    }
}
