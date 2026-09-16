import noir
import ast
import support
// Enum-value construction: turning `EnumType.case(args)` (and the leading-dot `.case(args)`
// form) into a typed `enumInit`. Reached from expression/call checking.
//
// The payload is paired to the case's declared fields (by label, else by position) and
// type-checked. A generic enum (`Option<T>`) infers its type arguments from the payload —
// and, for a no-payload case like `.none`, seeds them from the expected type context.
//
// A capability namespace over `inout Sema`. Expression checking (`checkExpr`), type
// resolution/substitution/unification (`resolve`/`substitute`/`unify`), and generic type-arg
// inference (`GenericInference.inferredTypeArgs`) stay on the hub and are called as `s.…`.
enum EnumConstruction {

    // Leading-dot `.case(...)`: resolve the enum from the expected type, then build. The
    // context may name a concrete enum (`.named`) or an applied generic one (`.generic`, M5 5.2.3).
    static func buildImplicitEnum(_ s: inout Sema, _ caseName: String, _ args: [Arg], expected: Type?, at span: Span) -> NOIRExpr {
        let enumName: String?
        switch expected {
        case .named(let n, .enum_) where s.enums[n] != nil:    enumName = n
        case .generic(let n, _) where s.enums[n] != nil:       enumName = n
        default:                                             enumName = nil
        }
        guard let enumName else {
            s.diags.error("cannot infer enum type for '.\(caseName)' here", at: span)
            let irArgs = args.map { NOIRArg(label: $0.label, value: NOIRGen.checkExpr(&s, $0.value)) }
            return NOIRExpr(type: .error, span: span, kind: .enumInit(typeName: "", caseName: caseName, args: irArgs))
        }
        return buildEnumInit(&s, enumName, caseName, args, expected: expected, at: span)
    }

    // `EnumType.case(args)` → a typed enumInit, checking the payload against the case. For a
    // generic enum (`Option<T>`) the type argument is inferred from the payload — and, for a
    // no-payload case like `.none`, seeded from the expected type context (M5 5.2.3).
    static func buildEnumInit(_ s: inout Sema, _ enumName: String, _ caseName: String, _ args: [Arg],
                              explicit: [Type]? = nil, expected: Type? = nil, at span: Span) -> NOIRExpr {
        guard let caseDecl = s.enums[enumName]?.cases.first(where: { $0.name == caseName }) else {
            s.diags.error("enum '\(enumName)' has no case '\(caseName)'", at: span)
            let irArgs = args.map { NOIRArg(label: $0.label, value: NOIRGen.checkExpr(&s, $0.value)) }
            return NOIRExpr(type: .named(enumName, .enum_), span: span, kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
        }
        if let generics = s.enums[enumName]?.generics, !generics.isEmpty {
            return buildGenericEnumInit(&s, enumName, generics, caseDecl, args, explicit: explicit, expected: expected, at: span)
        }
        if explicit != nil {
            s.diags.error("enum '\(enumName)' is not generic; type arguments are not allowed", at: span)
        }
        let irArgs = matchEnumArgs(&s, args, fields: caseDecl.fields, case: caseName, at: span)
        return NOIRExpr(type: .named(enumName, .enum_), span: span,
                      kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
    }

    // A generic enum case: unify each payload arg against the case field's declared type
    // (a `T` payload resolves to `.typeParam`), seed inference from the expected type when the
    // case carries no payload, then bound-check — yielding a `.generic(base, args)` (M5 5.2.3).
    static func buildGenericEnumInit(_ s: inout Sema, _ enumName: String, _ generics: [GenericParam],
                                     _ caseDecl: EnumCaseDecl, _ args: [Arg],
                                     explicit: [Type]? = nil, expected: Type?, at span: Span) -> NOIRExpr {
        let saved = s.genericScope; s.genericScope = Set(generics.map(\.name)); defer { s.genericScope = saved }
        var subst: [String: Type] = [:]
        // Explicit type arguments (`Option<Int>.some(...)`) seed inference; the payload is then
        // unified against them, so a mismatch (`Option<Int>.some("hi")`) is a conflict error.
        if let explicit {
            if explicit.count != generics.count {
                s.diags.error("generic enum '\(enumName)' expects \(generics.count) type argument(s), got \(explicit.count)", at: span)
            } else {
                for (p, a) in zip(generics, explicit) { subst[p.name] = a }
            }
        } else if case .generic(let b, let eargs)? = expected, b == enumName, eargs.count == generics.count {
            for (p, a) in zip(generics, eargs) { subst[p.name] = a }
        }
        if args.count != caseDecl.fields.count {
            s.diags.error("case '\(caseDecl.name)' expects \(caseDecl.fields.count) argument(s), got \(args.count)", at: span)
        }
        var irArgs: [NOIRArg] = []
        for (i, field) in caseDecl.fields.enumerated() {
            let fieldTy = s.resolve(field.type)
            let expArg = s.substitute(fieldTy, subst)
            let hint: Type? = { if case .typeParam = expArg { return nil }; return expArg }()
            guard let arg = args.first(where: { $0.label == field.name }) ?? (i < args.count ? args[i] : nil) else { continue }
            let v = NOIRGen.checkExpr(&s, arg.value, expected: hint)
            s.unify(param: fieldTy, arg: v.type, into: &subst, at: span)
            irArgs.append(NOIRArg(label: field.name, value: v))
        }
        let typeArgs = GenericInference.inferredTypeArgs(&s, generics, subst, owner: enumName, at: span)
        return NOIRExpr(type: .generic(base: enumName, args: typeArgs), span: span,
                      kind: .enumInit(typeName: enumName, caseName: caseDecl.name, args: irArgs))
    }

    // Pair payload args to the case's declared fields (by label, else by position),
    // type-checking each against its field; arity/type mismatches are diagnostics.
    static func matchEnumArgs(_ s: inout Sema, _ args: [Arg], fields: [VarField], case caseName: String, at span: Span) -> [NOIRArg] {
        if args.count != fields.count {
            s.diags.error("case '\(caseName)' expects \(fields.count) argument(s), got \(args.count)", at: span)
        }
        var out: [NOIRArg] = []
        for (i, field) in fields.enumerated() {
            let fieldTy = s.resolve(field.type)
            guard let arg = args.first(where: { $0.label == field.name }) ?? (i < args.count ? args[i] : nil) else { continue }
            let v = NOIRGen.checkExpr(&s, arg.value, expected: fieldTy)
            if v.type != fieldTy && v.type != .error && fieldTy != .error {
                s.diags.error("argument of type '\(v.type)' does not match expected '\(fieldTy)'", at: v.span)
            }
            out.append(NOIRArg(label: field.name, value: v))
        }
        return out
    }
}
