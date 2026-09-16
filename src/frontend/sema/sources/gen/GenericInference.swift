import noir
import ast
import support
// Generic inference and generic-type construction (M5 5.2.1–5.2.3, task 151).
//
// Two related jobs, both reached from expression/call checking:
//   • Generic *function* calls — infer each type parameter by unifying the declared
//     parameter types against the argument types (falling back to the expected type
//     for return-only parameters), bound-check the result, and substitute into the
//     return type (`checkGenericCall`).
//   • Generic *type* construction and member access — infer a struct/class's parameters
//     from its constructor arguments, and resolve a field read / method signature at an
//     instantiation `Base<args>` by substituting the applied arguments.
//
// A capability namespace over `inout Sema`. The shared unification/substitution
// primitives (`unify`, `substitute`, `mismatch`) and the call/member dispatch helper
// (`typeNameAndArgs`) stay on `Sema` — used across the hub — and are called here as
// `s.unify` / `s.substitute`.
enum GenericInference {

    // MARK: - Generic function calls (M5 5.2.2)

    static func checkGenericCall(_ s: inout Sema, _ name: String, _ sig: Sema.FnSig, _ args: [NOIRArg], at span: Span, expected: Type? = nil) -> NOIRExpr {
        if args.count != sig.params.count {
            s.diags.error("function '\(name)' expects \(sig.params.count) argument(s), got \(args.count)", at: span)
        }
        // A type parameter nested in a generic-type *parameter* (`o: Option<T>`) used to be
        // rejected: witness-passing had to destructure an abstract container, which needs value
        // witnesses and miscompiled. Whole-program monomorphization (M5 5.4) specializes such a
        // function to a concrete copy (`Option<Int>`), so the abstract body never reaches codegen
        // — the restriction is lifted. Inference of `T` *through* the container is still shallow
        // (a `.none` argument can't pin `T`); that surfaces as the ordinary "cannot infer" error.
        var subst: [String: Type] = [:]
        for (p, a) in zip(sig.params, args) { s.unify(param: p, arg: a.value.type, into: &subst, at: span) }
        // Type parameters that appear only in the return type (`makeTable<K>() -> HashTable<K>`) can't
        // be inferred from the arguments; fall back to the call's expected type when one is known
        // (`var t: HashTable<str> = makeTable()`). Best-effort and structural — a shape that doesn't
        // line up simply binds nothing, leaving the "cannot infer" error below.
        if let expected, sig.generics.contains(where: { subst[$0.name] == nil }) {
            bindFromExpected(sig.ret, expected, into: &subst)
        }
        for g in sig.generics where subst[g.name] == nil {
            s.diags.error("cannot infer type parameter '\(g.name)' of '\(name)' from the arguments or the expected type", at: span)
            subst[g.name] = .error
        }
        for g in sig.generics {
            let inferred = subst[g.name] ?? .error
            for b in g.bounds where inferred != .error && !typeConforms(&s, inferred, to: b.name) {
                s.diags.error("type '\(inferred)' does not conform to '\(b.name)', required by type parameter '\(g.name)' of '\(name)'", at: span)
            }
            // Discharge a `<shared T>` bound: the inferred type argument must be shareable (M5 5.3.2).
            if g.isShared && inferred != .error && !s.isShareable(inferred) {
                s.diags.error("type '\(inferred)' is not shareable, but type parameter '\(g.name)' of '\(name)' is declared 'shared'", at: span)
            }
        }
        let typeArgs = sig.generics.map { subst[$0.name] ?? .error }
        let calleeType = Type.function(params: sig.params, ret: sig.ret)
        return NOIRExpr(type: s.substitute(sig.ret, subst), span: span,
                      kind: .call(callee: NOIRGen.irVar(name, calleeType, span), args: args, typeArgs: typeArgs))
    }

    // Best-effort binding of return-position type parameters from the call's expected type. Unlike
    // `unify`, it never reports a mismatch: where the shapes line up it binds an unbound parameter,
    // and anywhere they diverge it just stops (the real diagnostic is the "cannot infer" error).
    static func bindFromExpected(_ ret: Type, _ expected: Type, into subst: inout [String: Type]) {
        guard expected != .error else { return }
        switch (ret, expected) {
        case (.typeParam(let t), _):
            if subst[t] == nil { subst[t] = expected }
        case let (.generic(rb, ra), .generic(eb, ea)) where rb == eb && ra.count == ea.count:
            for (r, e) in zip(ra, ea) { bindFromExpected(r, e, into: &subst) }
        case let (.array(re), .array(ee)):
            bindFromExpected(re, ee, into: &subst)
        case let (.function(rp, rr), .function(ep, er)) where rp.count == ep.count:
            for (r, e) in zip(rp, ep) { bindFromExpected(r, e, into: &subst) }
            bindFromExpected(rr, er, into: &subst)
        default:
            break
        }
    }

    // Does a type parameter appear inside an applied generic type within `t` (e.g. `Option<T>`)?
    // Such a parameter would let a generic body build/destructure an abstract `T` — deferred to
    // value witnesses (M5). A type parameter under a *function* type is handled by a thunk.
    static func typeParamUnderGeneric(_ t: Type, _ tparams: Set<String>) -> Bool {
        switch t {
        case .generic(_, let a):      return a.contains { mentionsTypeParam($0, tparams) }
        case .array(let e):           return mentionsTypeParam(e, tparams)
        case .function(let p, let r): return p.contains { typeParamUnderGeneric($0, tparams) } || typeParamUnderGeneric(r, tparams)
        default:                      return false
        }
    }

    static func mentionsTypeParam(_ t: Type, _ tparams: Set<String>) -> Bool {
        switch t {
        case .typeParam(let n):        return tparams.contains(n)
        case .function(let p, let r):  return p.contains { mentionsTypeParam($0, tparams) } || mentionsTypeParam(r, tparams)
        case .generic(_, let a):       return a.contains { mentionsTypeParam($0, tparams) }
        case .array(let e):            return mentionsTypeParam(e, tparams)
        default:                       return false
        }
    }

    // Does a concrete type conform to an interface, with a witness available (M5 5.2.2)?
    // Bound satisfaction consults *all* checked conformances (incl. constraint-only), not just
    // the witnessed ones: a `<T: Cloneable>` / `<T: Combinable>` bound is discharged by mono, which
    // specializes to a concrete `T` — no witness required (M5 5.6).
    static func typeConforms(_ s: inout Sema, _ t: Type, to iface: String) -> Bool {
        if case .named(let tn, _) = t { return s.allConformsTo[tn]?.contains(iface) == true }
        // A bound type parameter satisfies a bound it declares, directly or by refinement — so a
        // `K: Hashable` in scope can be passed as the argument of a `<K2: Hashable>` type (`Entry<K>`).
        if case .typeParam(let n) = t {
            let bounds = s.genericBounds[n] ?? []
            return bounds.contains(iface) || bounds.contains { s.transitiveBases($0).contains(iface) }
        }
        return false
    }

    // MARK: - Generic types (M5 5.2.3)

    // The type parameters and stored fields of a generic struct/class, or nil if `name` names
    // neither (a generic enum constructs through `buildEnumInit`).
    static func genericTypeShape(_ s: inout Sema, _ name: String) -> (generics: [GenericParam], fields: [VarField])? {
        if let st = s.structs[name] { return (st.generics, st.fields) }
        if let c = s.classes[name] { return (c.generics, c.fields) }
        return nil
    }

    // `Box(value: e)` — infer each type parameter by unifying the field's declared type
    // (a `T` resolves to `.typeParam`) against the argument, then bound-check (M5 5.2.3).
    static func checkGenericConstruct(_ s: inout Sema, _ name: String, _ args: [Arg], explicit: [Type]? = nil, at span: Span) -> NOIRExpr {
        guard let shape = genericTypeShape(&s, name) else {
            s.diags.error("generic enum '\(name)' is constructed through one of its cases, e.g. '\(name).case(...)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
        }
        let saved = s.genericScope; s.genericScope = Set(shape.generics.map(\.name)); defer { s.genericScope = saved }
        var subst: [String: Type] = [:]
        // Explicit type arguments (`Box<Int>(value: 3)`) seed inference; each field is then unified
        // against them, so a mismatch is reported as a conflict.
        if let explicit {
            if explicit.count != shape.generics.count {
                s.diags.error("generic type '\(name)' expects \(shape.generics.count) type argument(s), got \(explicit.count)", at: span)
            } else {
                for (p, a) in zip(shape.generics, explicit) { subst[p.name] = a }
            }
        }
        var irArgs: [NOIRArg] = []
        for f in shape.fields {
            let fieldTy = s.resolve(f.type)
            let expected: Type? = { if case .typeParam = fieldTy { return nil }; return fieldTy }()
            guard let arg = args.first(where: { $0.label == f.name }) else {
                s.diags.error("missing argument for field '\(f.name)'", at: span); continue
            }
            let v = NOIRGen.checkExpr(&s, arg.value, expected: expected)
            s.unify(param: fieldTy, arg: v.type, into: &subst, at: span)
            irArgs.append(NOIRArg(label: f.name, value: v))
        }
        let typeArgs = inferredTypeArgs(&s, shape.generics, subst, owner: name, at: span)
        return NOIRExpr(type: .generic(base: name, args: typeArgs), span: span,
                      kind: .construct(typeName: name, args: irArgs))
    }

    // Finish inference for a generic decl: every parameter must be bound, and each inferred
    // type must satisfy the parameter's bounds (a witness must exist). Shared by generic
    // struct construction and generic enum construction (M5 5.2.3).
    static func inferredTypeArgs(_ s: inout Sema, _ generics: [GenericParam], _ subst: [String: Type],
                                 owner: String, at span: Span) -> [Type] {
        var subst = subst
        for g in generics where subst[g.name] == nil {
            s.diags.error("cannot infer type parameter '\(g.name)' of '\(owner)' — add a type annotation", at: span)
            subst[g.name] = .error
        }
        for g in generics {
            let inferred = subst[g.name] ?? .error
            for b in g.bounds where inferred != .error && !typeConforms(&s, inferred, to: b.name) {
                s.diags.error("type '\(inferred)' does not conform to '\(b.name)', required by type parameter '\(g.name)' of '\(owner)'", at: span)
            }
        }
        return generics.map { subst[$0.name] ?? .error }
    }

    // The type parameters of a generic struct/enum/class (empty if not generic / not a type).
    static func genericParamsOf(_ s: inout Sema, _ base: String) -> [GenericParam] {
        s.structs[base]?.generics ?? s.enums[base]?.generics ?? s.classes[base]?.generics ?? []
    }

    // The substitution binding a generic type's own parameters to an instantiation's arguments
    // (`Box<Int>` → `[T: Int]`).
    static func genericSubst(_ s: inout Sema, _ base: String, _ args: [Type]) -> [String: Type] {
        var subst: [String: Type] = [:]
        for (p, a) in zip(genericParamsOf(&s, base), args) { subst[p.name] = a }
        return subst
    }

    // A generic type's method signature at an instantiation `Base<args>`: each param/return type is
    // resolved with the type's own generic params in scope (so a bare `T` becomes `.typeParam`), then
    // substituted to the concrete arguments. Mirrors `genericMemberType` for fields (task 151).
    static func genericMethodSig(_ s: inout Sema, _ base: String, _ args: [Type], _ m: FuncDecl) -> (params: [Type], ret: Type) {
        let gens = genericParamsOf(&s, base)
        let saved = s.genericScope; s.genericScope = Set(gens.map(\.name)); defer { s.genericScope = saved }
        let subst = genericSubst(&s, base, args)
        return (m.params.map { s.substitute(s.resolve($0.type), subst) }, s.substitute(s.resolve(m.returnType), subst))
    }

    // A field read on `Box<Int>`: resolve the field's declared type with the type's parameters
    // in scope, then substitute the applied arguments to get the concrete result type (M5 5.2.3).
    static func genericMemberType(_ s: inout Sema, _ base: String, _ args: [Type], _ field: String, at span: Span) -> Type {
        guard let shape = genericTypeShape(&s, base), let f = shape.fields.first(where: { $0.name == field }) else {
            s.diags.error("type '\(base)' has no field '\(field)'", at: span)
            return .error
        }
        let saved = s.genericScope; s.genericScope = Set(shape.generics.map(\.name)); defer { s.genericScope = saved }
        var subst: [String: Type] = [:]
        for (p, a) in zip(shape.generics, args) { subst[p.name] = a }
        return s.substitute(s.resolve(f.type), subst)
    }
}
