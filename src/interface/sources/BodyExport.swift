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
// Functions and the private types a shipped body reaches (struct, class, enum, with their methods) are
// canonicalized. A decl's own name stays bare; the consumer keys it when it injects the decl.

// The identifiers a decl references (task 100.5.4): callee / variable names, func refs, and the names of
// the types its signatures, fields, cases and expressions mention. A type's methods count as part of it.
// Over-approximate — no scope tracking, so a shadowing local may add a spurious name, which at worst ships
// an unused decl (dead-stripped). Drives the closure a `.bir` must ship: the reachable non-public callees
// and types the consumer needs to emit locally, since they are absent from the `.nmi` (interface-
// invisible) and so unknown to the consumer's Sema.
public func collectReferencedNames(_ decl: NOIRDecl) -> Set<String> {
    var names = Set<String>()
    func visitType(_ t: Type) {
        switch t {
        case .named(let n, _):                     names.insert(n)
        case .generic(let base, let args):         names.insert(base); args.forEach(visitType)
        case .array(let e), .ptr(let e):           visitType(e)
        case .function(let p, let r):              p.forEach(visitType); visitType(r)
        default:                                   break
        }
    }
    func visitExpr(_ e: NOIRExpr) {
        visitType(e.type)
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit:
            break
        case .globalRef:                           break   // a global is referenced by symbol, never shipped (task 224)
        case .varRef(let n):                       names.insert(n)
        case .funcRef(let n):                      names.insert(n)
        case .construct(let tn, let args):         names.insert(tn); args.forEach { visitExpr($0.value) }
        case .enumInit(let tn, _, let args):       names.insert(tn); args.forEach { visitExpr($0.value) }
        case .fieldAccess(let base, _):            visitExpr(base)
        case .methodCall(let r, _, let args):      visitExpr(r); args.forEach(visitExpr)
        case .call(let callee, let args, _):       visitExpr(callee); args.forEach { visitExpr($0.value) }
        case .staticCall(let t, _, let args):      visitType(t); args.forEach(visitExpr)
        case .binary(_, let l, let r):             visitExpr(l); visitExpr(r)
        case .closure(let ps, let body):           ps.forEach { visitType($0.type) }; body.forEach(visitStmt)
        case .box(let v, _):                       visitExpr(v)
        case .arrayLit(let els):                   els.forEach(visitExpr)
        case .index(let b, let i):                 visitExpr(b); visitExpr(i)
        case .taskStart(_, let m, let c, let f):   visitExpr(m); visitExpr(c); visitExpr(f)
        }
    }
    func visitStmt(_ s: NOIRStmt) {
        switch s.kind {
        case .letBinding(_, _, let v):             visitExpr(v)
        case .fiberStart(let c):                   visitExpr(c)
        case .assign(let t, let v):                visitExpr(t); visitExpr(v)
        case .compoundAssign(let t, let v):        visitExpr(t); visitExpr(v)
        case .ret(let e):                          e.map(visitExpr)
        case .ifStmt(let c, let th, let el):       visitExpr(c); th.forEach(visitStmt); el?.forEach(visitStmt)
        case .whileStmt(let c, let body):          visitExpr(c); body.forEach(visitStmt)
        case .breakStmt, .continueStmt:            break
        case .switchStmt(let sw):
            visitExpr(sw.subject)
            sw.arms.forEach { $0.bindings.forEach { visitType($0.type) }; $0.body.forEach(visitStmt) }
        case .exprStmt(let e):                     visitExpr(e)
        }
    }
    func visitFunc(_ f: NOIRFunc) {
        f.params.forEach { visitType($0.type) }
        visitType(f.returnType)
        f.body.forEach(visitStmt)
    }
    switch decl {
    case .funcDecl(let f):   visitFunc(f)
    case .structDecl(let s): s.fields.forEach { visitType($0.type) }; s.methods.forEach(visitFunc)
    case .classDecl(let c):  c.fields.forEach { visitType($0.type) }; c.methods.forEach(visitFunc)
    case .enumDecl(let e):   e.cases.forEach { $0.fields.forEach { visitType($0.type) } }; e.methods.forEach(visitFunc)
    case .actorDecl, .globalDecl: break
    }
    return names
}

public func canonicalizeForExport(_ decls: [NOIRDecl], origin: String, ownNames: Set<String>) -> [NOIRDecl] {
    let c = Canonicalizer(origin: origin, ownNames: ownNames)
    return decls.map { decl in
        switch decl {
        case .funcDecl(let f):   return .funcDecl(c.function(f))
        case .structDecl(let s): return .structDecl(c.structDecl(s))
        case .classDecl(let k):  return .classDecl(c.classDecl(k))
        case .enumDecl(let e):   return .enumDecl(c.enumDecl(e))
        case .actorDecl, .globalDecl: return decl
        }
    }
}

private final class Canonicalizer {
    let origin: String
    let ownNames: Set<String>
    init(origin: String, ownNames: Set<String>) { self.origin = origin; self.ownNames = ownNames }

    private func key(_ name: String) -> String { ExternalName.encode(origin: origin, name: name) }
    // An own name, or a static function of an own type (`Box.make`), is keyed.
    private func keyed(_ name: String) -> String {
        if ownNames.contains(name) { return key(name) }
        if let dot = name.firstIndex(of: "."), ownNames.contains(String(name[..<dot])) { return key(name) }
        return name
    }
    // An interface keeps its bare name: a consumer knows an imported interface by it (`encodeExternalDecl`).
    private func interface(_ name: String) -> String { name }

    // MARK: types
    func type(_ t: Type) -> Type {
        switch t {
        case .named(let n, let k):            return .named(keyed(n), k)
        case .generic(let base, let args):    return .generic(base: keyed(base), args: args.map(type))
        case .array(let e):                   return .array(type(e))
        case .ptr(let e):                     return .ptr(type(e))
        case .function(let p, let r):         return .function(params: p.map(type), ret: type(r))
        case .existential(let n):             return .existential(interface(n))
        case .composition(let ns):            return .composition(ns.map(interface))
        case .opaque(let ifs, let owner):     return .opaque(interfaces: ifs.map(interface), owner: owner)
        default:                              return t
        }
    }

    // MARK: declarations
    func generics(_ gs: [NOIRGenericParam]) -> [NOIRGenericParam] {
        gs.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(interface), isShared: $0.isShared) }
    }
    func fields(_ fs: [NOIRField]) -> [NOIRField] {
        fs.map { NOIRField(name: $0.name, type: type($0.type), isMutable: $0.isMutable, span: $0.span,
                           fromTypeParameter: $0.fromTypeParameter) }
    }
    // A method keeps its name; its type is the keyed owner. `self` is bound in its body.
    func method(_ f: NOIRFunc) -> NOIRFunc { function(f, bound: ["self"]) }
    func structDecl(_ s: NOIRStruct) -> NOIRStruct {
        NOIRStruct(name: s.name, generics: generics(s.generics), fields: fields(s.fields),
                   methods: s.methods.map(method), span: s.span)
    }
    func classDecl(_ c: NOIRClass) -> NOIRClass {
        NOIRClass(name: c.name, generics: generics(c.generics), fields: fields(c.fields),
                  methods: c.methods.map(method), span: c.span)
    }
    func enumDecl(_ e: NOIREnum) -> NOIREnum {
        NOIREnum(name: e.name, generics: generics(e.generics),
                 cases: e.cases.map { NOIREnumCase(name: $0.name, fields: fields($0.fields), span: $0.span) },
                 methods: e.methods.map(method), span: e.span)
    }
    func function(_ f: NOIRFunc, bound outer: Set<String> = []) -> NOIRFunc {
        let bound = outer.union(f.params.map(\.name))
        return NOIRFunc(name: f.name,
            generics: generics(f.generics),
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
        case .assign(let target, let value):
            return (here(.assign(target: expr(target, bound), value: expr(value, bound))), bound)
        case .compoundAssign(let target, let value):
            return (here(.compoundAssign(target: expr(target, bound), value: expr(value, bound))), bound)
        case .ret(let e):
            return (here(.ret(e.map { expr($0, bound) })), bound)
        case .fiberStart(let call):
            return (here(.fiberStart(call: expr(call, bound))), bound)
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
        case .globalRef(let n):
            return here(.globalRef(keyed(n)))   // the producer's one global, by its origin-keyed name
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
            return here(.box(value: expr(value, bound), interfaces: interfaces.map(interface)))
        case .arrayLit(let elements):
            return here(.arrayLit(elements: elements.map { expr($0, bound) }))
        case .index(let base, let idx):
            return here(.index(base: expr(base, bound), idx: expr(idx, bound)))
        case .funcRef(let name):
            return here(.funcRef(name: keyed(name)))
        case .taskStart(let binder, let make, let call, let fulfill):
            return here(.taskStart(binder: binder, make: expr(make, bound), call: expr(call, bound),
                                   fulfill: expr(fulfill, bound.union([binder, "\(binder).v"]))))
        }
    }
}
