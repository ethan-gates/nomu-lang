import noir
import ast
import support
// Type formation for the composite type forms (M5 A1.4/A1.5b/A3, 5.2.1) — the heavy
// cases `Sema.resolve` delegates to: `any A & B` existentials/compositions, `some A & B`
// opaque types, and applied generics `Box<Int>`. The simple cases (builtins, bare names,
// function types, type parameters) stay inline in `resolve`, which dispatches here.
//
// A capability namespace over `borrowing Sema`: every path is a read of the declared-type
// and interface tables plus diagnostics, so it borrows `Sema` rather than mutating it.
// Applied-generic arguments recurse back through `s.resolve`.
enum TypeResolution {

    // Validate/canonicalize an interface list shared by `any` and `some`: each name must be
    // an interface; dedup; drop any interface implied by a refiner already present (`A & B`
    // collapses to `B` when `B: A`); sort — so `A & B` and `B & A` are the same (M5 A1.5b).
    // Returns nil after a diagnostic when a name isn't an interface. `keyword` shapes the message.
    private static func canonicalInterfaces(_ s: borrowing Sema, _ names: [String], keyword: String, at span: Span) -> [String]? {
        for n in names where s.interfaces[n] == nil {
            s.diags.error("'\(n)' is not an interface in '\(keyword) \(names.joined(separator: " & "))'", at: span)
            return nil
        }
        var set = Array(Set(names))
        set = set.filter { i in !set.contains { j in j != i && s.transitiveBases(j).contains(i) } }
        set.sort()
        return set
    }

    // Resolve `any A & B …` to an existential (one interface) or a composition (several).
    static func resolveExistential(_ s: borrowing Sema, _ names: [String], at span: Span) -> Type {
        guard let set = canonicalInterfaces(s, names, keyword: "any", at: span) else { return .error }
        // An interface with a *non-covariant* `Self` is constraint-only: a type-erased box can't
        // guarantee two `Self` values share a concrete type, so `any I` is rejected at type
        // formation (M5 5.6, interfaces.md §4.4). Covariant-only `Self` (return position) is
        // erasure-safe and allowed. `some I` / a generic bound `<T: I>` remain fine for both.
        for n in set where s.isConstraintOnly(n) {
            let reason = s.hasStaticRequirement(n)
                ? "declares a static requirement"
                : "uses Self in a non-covariant position (a parameter, a settable property, or nested in a function type)"
            s.diags.error("interface '\(n)' \(reason) and is constraint-only — use 'some \(n)' or a generic bound '<T: \(n)>', not 'any \(n)'", at: span)
            return .error
        }
        return set.count == 1 ? .existential(set[0]) : .composition(set)
    }

    // Resolve `some A & B …` to an opaque type (M5 A3). Unlike `any`, a constraint-only
    // (`Self`-mentioning) interface is allowed — `some I` fixes one concrete underlying, so
    // `Self` binds to a single known type. The `owner` is the opaque's identity (per-function/
    // binding); it is absent (→ a diagnostic) anywhere `some` isn't legal.
    static func resolveOpaque(_ s: borrowing Sema, _ names: [String], owner: String?, at span: Span) -> Type {
        guard let owner else {
            s.diags.error("'some \(names.joined(separator: " & "))' is only allowed as a return type or a 'let'/'var' binding type", at: span)
            return .error
        }
        guard let set = canonicalInterfaces(s, names, keyword: "some", at: span) else { return .error }
        return .opaque(interfaces: set, owner: owner)
    }

    // Resolve `Box<Int>` to `.generic` (M5 5.2.1): the base must be a declared generic type,
    // the argument count must match, and each argument resolves in the current scope.
    static func resolveGeneric(_ s: borrowing Sema, _ base: String, args: [TypeRef], selfAs: Type?, at span: Span) -> Type {
        // `Array<T>` is a builtin generic reference type (M6 stdlib), not a user decl — resolve it to
        // the dedicated `.array` type rather than routing through the user-generic-decl machinery.
        if base == "Array" {
            guard args.count == 1 else {
                s.diags.error("generic type 'Array' expects 1 type argument, got \(args.count)", at: span)
                return .error
            }
            return .array(s.resolve(args[0], selfAs: selfAs))
        }
        // `Ptr<T>` is a builtin typed unmanaged pointer (task 125), also outside the user-generic-decl
        // machinery — resolve to the dedicated `.ptr` type.
        if base == "Ptr" {
            guard args.count == 1 else {
                s.diags.error("generic type 'Ptr' expects 1 type argument, got \(args.count)", at: span)
                return .error
            }
            return .ptr(s.resolve(args[0], selfAs: selfAs))
        }
        guard let arity = s.genericArity(base) else {
            if s.kindOf(base) != nil {
                s.diags.error("type '\(base)' is not generic — it takes no type arguments", at: span)
            } else {
                s.diags.error("unknown generic type '\(base)'", at: span)
            }
            return .error
        }
        if arity != args.count {
            s.diags.error("generic type '\(base)' expects \(arity) type argument(s), got \(args.count)", at: span)
            return .error
        }
        return .generic(base: base, args: args.map { s.resolve($0, selfAs: selfAs) })
    }
}
