import noir
import ast
import support
// The semantic pass: resolves names, types every expression, and lowers the AST
// to the typed IR, collecting diagnostics (design: noir.md). Concrete types
// only — interfaces/generics are M5; type methods are T3.

public struct SemaResult {
    public let module: NOIRModule
    public let diagnostics: DiagnosticSink
}

public struct Sema {
    private let program: Program
    private let diags = DiagnosticSink()
    private let subsetFuncs: Set<String>   // task 149 — functions compiled under the runtime-subset rules

    // Global declarations, by name.
    private var structs: [String: StructDecl] = [:]
    private var enums:   [String: EnumDecl]   = [:]
    private var classes: [String: ClassDecl]  = [:]
    private var actors:  [String: ActorDecl]  = [:]
    private var interfaces: [String: InterfaceDecl] = [:]   // M5 A1

    // `static fun` members lowered to free functions (named `Type.method`, no `self`), collected
    // during declaration lowering and appended to the module's decls after the main pass.
    private var pendingStaticFuncs: [NOIRDecl] = []
    private var funcs:   [String: FnSig]      = [:]   // named functions + non-print builtins

    // Computed properties (M5 A1), by owning type then property name. Drives member
    // read → getter-call and assignment → setter-call routing during body lowering.
    private struct PropInfo { let type: Type; let hasSetter: Bool }
    private var computedProps: [String: [String: PropInfo]] = [:]

    // Conformance facts (M5 A1.4), filled by checkConformances before body lowering.
    private var conformsTo: [String: Set<String>] = [:]      // type name → interface names
    private var conformanceList: [NOIRConformance] = []        // one per valid `T: I`
    private var conformancePairs: Set<String> = []           // "T:I" seen, so witnesses aren't duplicated
    private var inheritedDefaults: [String: [InterfaceMethod]] = [:]   // defaulted reqs a type inherits
    private var interfaceBases: [String: [Conformance]] = [:]   // M5 A1.5: interface → direct base interfaces
    private var compositeList: [NOIRComposite] = []               // M5 A1.5b: (type, any A & B) pairs boxed
    private var compositePairs: Set<String> = []

    // M5 A3: `some I` opaque types. `allConformsTo` records every checked conformance
    // (including constraint-only interfaces, which have no witness) so `some I` can verify
    // its underlying conforms; `conformsTo` above stays witness-only for `any`. `opaqueUnderlyings`
    // maps an opaque owner (a `some`-returning function/method, or a `let`/`var: some I` binding)
    // to its single hidden concrete type, filled during lowering and read by codegen.
    private var allConformsTo: [String: Set<String>] = [:]
    private var opaqueUnderlyings: [String: Type] = [:]
    private var opaqueBindingCounter = 0

    // M5 5.2.1: the generic type parameters (`T`, `U`) in scope while resolving a generic
    // decl's signatures — a bare name here resolves to `.typeParam`, not an unknown type.
    private var genericScope: Set<String> = []

    // Lexical scope stack for locals/params (name → type + mutability).
    private var scopes: [[String: Local]] = []
    private struct Local {
        let type: Type
        let isMutable: Bool
    }

    // Declared return type of the body being lowered — the contextual type for a
    // `return .case(...)` leading-dot construction (M4.10).
    private var currentReturnType: Type = .void
    private var loopDepth = 0   // >0 inside a `while` body; gates `break`/`continue`

    // Value-type method calls, recorded during lowering with their receiver's
    // mutability; checked against inferred mutating-ness after the mutation pass (M4.11).
    private struct CallSite { let callee: String; let receiverMutable: Bool; let span: Span }
    private var methodCallSites: [CallSite] = []

    private struct FnSig { let params: [Type]; let ret: Type; var generics: [GenericParam] = [] }

    // M5 5.2.2: the bounds of each generic type parameter in scope (`T` → its interfaces),
    // so a requirement call on a `.typeParam` receiver dispatches through the right witness.
    private var genericBounds: [String: [String]] = [:]

    // M5 5.3.2: the `shared` type parameters in scope (`<shared T>`), so a shared `T`
    // used inside the body counts as shareable when passed to another `shared` bound.
    private var sharedParams: Set<String> = []

    // M5 5.3.2: the structural share-analysis predicate over the program's types,
    // built once after global collection; discharges `<shared T>` bounds at call sites.
    private var shareChecker = Shareability(lookup: { _ in nil })

    public init(_ program: Program, subsetFuncs: Set<String> = []) {
        self.program = program
        self.subsetFuncs = subsetFuncs
    }

    public mutating func check() -> SemaResult {
        collectGlobals()
        buildShareChecker()
        validateInterfaceGraph()
        checkConformances()
        var decls: [NOIRDecl] = []
        for decl in program.decls {
            // Interfaces are abstract: validate them, but emit no IR (conformance in a
            // later slice generates the concrete witnesses that carry the defaults).
            if case .interfaceDecl(let i) = decl { checkInterface(i); continue }
            // Generic *types* lower to one uniform C shape — a `T` field is held boxed
            // (`void*`), sized/copied at construction where the concrete `T` is known; no
            // value witness (M5 5.2.3). Generic *functions* are witness-passed (5.2.2).
            if isGenericType(decl) { decls.append(lowerGenericDecl(decl)); continue }
            decls.append(lowerDecl(decl))
        }
        // `static fun` members lowered as free functions, emitted alongside the type decls.
        decls.append(contentsOf: pendingStaticFuncs)

        // M4.11: infer method mutating-ness, validate `let`-field / `self` writes,
        // annotate the IR, then check that mutating value-type calls have a mutable receiver.
        let module0 = NOIRModule(decls: decls, interfaces: buildIRInterfaces(),
                               conformances: conformanceList, composites: compositeList,
                               opaqueUnderlyings: opaqueUnderlyings)
        let mutation = analyzeMutation(module0, into: diags)
        for site in methodCallSites where mutation.mutating.contains(site.callee) && !site.receiverMutable {
            diags.error("cannot call mutating method on an immutable value — the receiver must be a 'var'", at: site.span)
        }
        checkRuntimeSubset(mutation.module)
        return SemaResult(module: mutation.module, diagnostics: diags)
    }

    // MARK: - Global collection

    private mutating func collectGlobals() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e):   enums[e.name]   = e
            case .classDecl(let c):  classes[c.name] = c
            case .actorDecl(let a):  actors[a.name]  = a
            case .interfaceDecl(let i): interfaces[i.name] = i; interfaceBases[i.name] = i.refines
            case .funcDecl(let f):
                let saved = genericScope; genericScope = Set(f.generics.map(\.name))
                funcs[f.name] = FnSig(params: f.params.map { resolve($0.type) },
                                      ret: resolve(f.returnType, opaqueOwner: "fn:\(f.name)"),
                                      generics: f.generics)
                genericScope = saved
            case .extensionDecl:
                break   // merged into its target before Sema (M4.12)
            }
        }
        // Computed-property tables need the type dicts above populated first (a property
        // type may name any user type), so register them in a second pass.
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): registerProps(s.name, s.properties, generics: s.generics)
            case .enumDecl(let e):   registerProps(e.name, e.properties, generics: e.generics)
            case .classDecl(let c):  registerProps(c.name, c.properties, generics: c.generics)
            default: break
            }
        }
        // Prototype builtins (print is special-cased in checkCall — it is variadic-ish).
        funcs["concat"]   = FnSig(params: [.string, .string], ret: .string)
        funcs["readLine"] = FnSig(params: [], ret: .string)
        funcs["sleep"]    = FnSig(params: [.int], ret: .int)
    }

    // MARK: - Share analysis (M5 5.3.2)

    // Build the structural share-analysis predicate over every declared type. Field
    // types are resolved under each decl's own generic scope so a `T` field becomes
    // `.typeParam("T")` for the conditional-conformance substitution to work.
    private mutating func buildShareChecker() {
        var table: [String: Shareability.Decl] = [:]
        for (n, s) in structs {
            table[n] = Shareability.Decl(fields: resolveFields(s.fields, params: s.generics),
                                         isClass: false, params: s.generics.map(\.name))
        }
        for (n, c) in classes {
            table[n] = Shareability.Decl(fields: resolveFields(c.fields, params: c.generics),
                                         isClass: true, params: c.generics.map(\.name))
        }
        for (n, e) in enums {
            let caseFields = e.cases.flatMap { $0.fields }
            table[n] = Shareability.Decl(fields: resolveFields(caseFields, params: e.generics),
                                         isClass: false, params: e.generics.map(\.name))
        }
        shareChecker = Shareability(lookup: { table[$0] })
    }

    private mutating func resolveFields(_ fields: [VarField], params: [GenericParam]) -> [(type: Type, isMutable: Bool)] {
        let saved = genericScope
        genericScope = saved.union(params.map(\.name))
        defer { genericScope = saved }
        return fields.map { (type: resolve($0.type), isMutable: $0.isMutable) }
    }

    // A type is shareable if it can cross a task boundary. A bare `.typeParam` is
    // shareable only when its parameter is declared `<shared T>` and thus in scope here.
    private func isShareable(_ t: Type) -> Bool {
        if case .typeParam(let p) = t { return sharedParams.contains(p) }
        return shareChecker.isShareable(t)
    }

    // MARK: - Type resolution (syntax → semantics)

    // `selfAs` gives the type `Self` resolves to (M5 A2): the abstract `.selfType` while
    // laying out an interface's requirements, the conformer's concrete type while matching
    // conformance. nil (the default) means `Self` is illegal here — it is contextual to
    // interface requirements (interfaces.md §4.4).
    // `opaqueOwner`, when set, is the identity key for a `some I` type at this position
    // (per-function/binding identity, M5 A3). nil means `some` is illegal here (only return
    // types and let/var bindings supply an owner).
    private func resolve(_ ref: TypeRef?, selfAs: Type? = nil, opaqueOwner: String? = nil) -> Type {
        guard let ref else { return .void }
        if let ifaces = ref.existentialOf {   // `any I` / `any A & B` (M5 A1.4/A1.5b)
            return resolveExistential(ifaces, at: ref.span)
        }
        if let ifaces = ref.opaqueOf {        // `some I` / `some A & B` (M5 A3)
            return resolveOpaque(ifaces, owner: opaqueOwner, at: ref.span)
        }
        if let args = ref.genericArgs {       // `Box<Int>` — an applied generic type (M5 5.2.1)
            return resolveGeneric(ref.name, args: args, selfAs: selfAs, at: ref.span)
        }
        if genericScope.contains(ref.name) {  // a generic type parameter `T` in scope (M5 5.2.1)
            return .typeParam(ref.name)
        }
        if let fn = ref.fn {
            return .function(params: fn.params.map { resolve($0, selfAs: selfAs) }, ret: resolve(fn.ret, selfAs: selfAs))
        }
        if ref.name == "Self" {
            if let selfAs { return selfAs }
            diags.error("'Self' can only be used in an interface requirement", at: ref.span)
            return .error
        }
        switch ref.name {
        case "Int":    return .int
        case "UInt8":  return .uint8
        case "UInt64": return .uint64
        case "Double": return .double
        case "Bool":   return .bool
        case "String": return .string
        case "RawPtr": return .rawPtr    // task 125 — untyped unmanaged address
        case "Void":   return .void
        default:
            if let k = kindOf(ref.name) {
                // A bare interface name isn't a usable type — `any I` / `some I` (later
                // slices) make the erasure explicit (interfaces.md §4.4).
                if k == .interface_ {
                    diags.error("interface type '\(ref.name)' must be written as 'any \(ref.name)' or 'some \(ref.name)'", at: ref.span)
                    return .error
                }
                return .named(ref.name, k)
            }
            diags.error("unknown type '\(ref.name)'", at: ref.span)
            return .error
        }
    }

    // Validate/canonicalize an interface list shared by `any` and `some`: each name must be
    // an interface; dedup; drop any interface implied by a refiner already present (`A & B`
    // collapses to `B` when `B: A`); sort — so `A & B` and `B & A` are the same (M5 A1.5b).
    // Returns nil after a diagnostic when a name isn't an interface. `keyword` shapes the message.
    private func canonicalInterfaces(_ names: [String], keyword: String, at span: Span) -> [String]? {
        for n in names where interfaces[n] == nil {
            diags.error("'\(n)' is not an interface in '\(keyword) \(names.joined(separator: " & "))'", at: span)
            return nil
        }
        var set = Array(Set(names))
        set = set.filter { i in !set.contains { j in j != i && transitiveBases(j).contains(i) } }
        set.sort()
        return set
    }

    // Resolve `any A & B …` to an existential (one interface) or a composition (several).
    private func resolveExistential(_ names: [String], at span: Span) -> Type {
        guard let set = canonicalInterfaces(names, keyword: "any", at: span) else { return .error }
        // An interface with a *non-covariant* `Self` is constraint-only: a type-erased box can't
        // guarantee two `Self` values share a concrete type, so `any I` is rejected at type
        // formation (M5 5.6, interfaces.md §4.4). Covariant-only `Self` (return position) is
        // erasure-safe and allowed. `some I` / a generic bound `<T: I>` remain fine for both.
        for n in set where hasNonCovariantSelf(n) {
            diags.error("interface '\(n)' uses Self in a non-covariant position (a parameter, a settable property, or nested in a function type) and is constraint-only — use 'some \(n)' or a generic bound '<T: \(n)>', not 'any \(n)'", at: span)
            return .error
        }
        return set.count == 1 ? .existential(set[0]) : .composition(set)
    }

    // Resolve `some A & B …` to an opaque type (M5 A3). Unlike `any`, a constraint-only
    // (`Self`-mentioning) interface is allowed — `some I` fixes one concrete underlying, so
    // `Self` binds to a single known type. The `owner` is the opaque's identity (per-function/
    // binding); it is absent (→ a diagnostic) anywhere `some` isn't legal.
    private func resolveOpaque(_ names: [String], owner: String?, at span: Span) -> Type {
        guard let owner else {
            diags.error("'some \(names.joined(separator: " & "))' is only allowed as a return type or a 'let'/'var' binding type", at: span)
            return .error
        }
        guard let set = canonicalInterfaces(names, keyword: "some", at: span) else { return .error }
        return .opaque(interfaces: set, owner: owner)
    }

    // Resolve `Box<Int>` to `.generic` (M5 5.2.1): the base must be a declared generic type,
    // the argument count must match, and each argument resolves in the current scope.
    private func resolveGeneric(_ base: String, args: [TypeRef], selfAs: Type?, at span: Span) -> Type {
        // `Array<T>` is a builtin generic reference type (M6 stdlib), not a user decl — resolve it to
        // the dedicated `.array` type rather than routing through the user-generic-decl machinery.
        if base == "Array" {
            guard args.count == 1 else {
                diags.error("generic type 'Array' expects 1 type argument, got \(args.count)", at: span)
                return .error
            }
            return .array(resolve(args[0], selfAs: selfAs))
        }
        // `Ptr<T>` is a builtin typed unmanaged pointer (task 125), also outside the user-generic-decl
        // machinery — resolve to the dedicated `.ptr` type.
        if base == "Ptr" {
            guard args.count == 1 else {
                diags.error("generic type 'Ptr' expects 1 type argument, got \(args.count)", at: span)
                return .error
            }
            return .ptr(resolve(args[0], selfAs: selfAs))
        }
        guard let arity = genericArity(base) else {
            if kindOf(base) != nil {
                diags.error("type '\(base)' is not generic — it takes no type arguments", at: span)
            } else {
                diags.error("unknown generic type '\(base)'", at: span)
            }
            return .error
        }
        if arity != args.count {
            diags.error("generic type '\(base)' expects \(arity) type argument(s), got \(args.count)", at: span)
            return .error
        }
        return .generic(base: base, args: args.map { resolve($0, selfAs: selfAs) })
    }

    // The number of type parameters of a declared type, or nil if it isn't generic (M5 5.2.1).
    private func genericArity(_ name: String) -> Int? {
        let n = structs[name]?.generics.count ?? enums[name]?.generics.count ?? classes[name]?.generics.count ?? 0
        return n > 0 ? n : nil
    }

    // The interface(s) an existential/composition ranges over; empty for other types.
    private func existentialInterfaces(_ type: Type) -> [String] {
        switch type {
        case .existential(let i): return [i]
        case .composition(let is_): return is_
        default: return []
        }
    }

    // Is `name` a property member reachable by bare name through `self`? A property
    // requirement when `self` is an interface (default body), or a computed property on a
    // concrete receiver. Stored fields are bound by name already, so they aren't here (M5).
    private func bareMemberOfSelf(_ selfTy: Type, _ name: String) -> Bool {
        switch selfTy {
        case .named(let iface, .interface_): return aggregatedProperties(iface).contains { $0.name == name }
        case .named(let tn, _):              return computedProps[tn]?[name] != nil
        default:                             return false
        }
    }

    // A heap (reference) type: a class/actor instance or an Array handle — a managed `p1` at runtime,
    // so `addrOf` (task 150 rung 2) can take its raw address. Structs/enums are value types.
    private func isReferenceType(_ t: Type) -> Bool {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .array: return true
        default: return false
        }
    }

    private func kindOf(_ name: String) -> NamedKind? {
        if structs[name] != nil { return .struct_ }
        if enums[name]   != nil { return .enum_ }
        if classes[name] != nil { return .class_ }
        if actors[name]  != nil { return .actor_ }
        if interfaces[name] != nil { return .interface_ }
        return nil
    }

    // The stored fields (label + resolved type, declaration order) of a constructible named type —
    // a struct, class, or actor. Used to thread the expected field type into each constructor
    // argument (so a literal adopts a `UInt8`/`Double` field) and to reject a mismatch cleanly.
    private func constructorFields(_ name: String) -> [(label: String, type: Type)]? {
        if let s = structs[name] { return s.fields.map { ($0.name, resolve($0.type)) } }
        if let c = classes[name] { return c.fields.map { ($0.name, resolve($0.type)) } }
        if let a = actors[name]  { return a.fields.map { ($0.name, resolve($0.type)) } }
        return nil
    }

    // The declared instance method `name` on a struct/enum/class, if any (T3). Static members are
    // excluded — they are called on the type, never on a value.
    private func methodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
        typeMethods(typeName, kind)?.first { $0.name == name && !$0.isStatic }
    }

    // The declared `static fun name` on a struct/enum/class, if any — the type-associated form.
    private func staticMethodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
        typeMethods(typeName, kind)?.first { $0.name == name && $0.isStatic }
    }

    private func typeMethods(_ typeName: String, _ kind: NamedKind) -> [FuncDecl]? {
        switch kind {
        case .struct_: return structs[typeName]?.methods
        case .enum_:   return enums[typeName]?.methods
        case .class_:  return classes[typeName]?.methods
        case .actor_, .interface_:  return nil
        }
    }

    // MARK: - Declarations

    private mutating func lowerDecl(_ decl: TopDecl) -> NOIRDecl {
        switch decl {
        case .structDecl(let s):
            let fields = s.fields.map(lowerField)
            var methods = lowerMethods(s.methods, selfType: .named(s.name, .struct_), fields: fields)
            methods += lowerAccessors(s.properties, selfType: .named(s.name, .struct_), fields: fields)
            methods += lowerInheritedDefaults(s.name, selfType: .named(s.name, .struct_), fields: fields)
            lowerStaticMethods(s.methods, typeName: s.name)
            return .structDecl(NOIRStruct(name: s.name, fields: fields, methods: methods, span: s.span))
        case .enumDecl(let e):
            let cases = e.cases.map { NOIREnumCase(name: $0.name, fields: $0.fields.map(lowerField), span: $0.span) }
            var methods = lowerMethods(e.methods, selfType: .named(e.name, .enum_), fields: [])
            methods += lowerAccessors(e.properties, selfType: .named(e.name, .enum_), fields: [])
            methods += lowerInheritedDefaults(e.name, selfType: .named(e.name, .enum_), fields: [])
            lowerStaticMethods(e.methods, typeName: e.name)
            return .enumDecl(NOIREnum(name: e.name, cases: cases, methods: methods, span: e.span))
        case .classDecl(let c):
            let fields = c.fields.map(lowerField)
            var methods = lowerMethods(c.methods, selfType: .named(c.name, .class_), fields: fields)
            methods += lowerAccessors(c.properties, selfType: .named(c.name, .class_), fields: fields)
            methods += lowerInheritedDefaults(c.name, selfType: .named(c.name, .class_), fields: fields)
            lowerStaticMethods(c.methods, typeName: c.name)
            return .classDecl(NOIRClass(name: c.name, fields: fields, methods: methods, span: c.span))
        case .actorDecl(let a):
            return .actorDecl(lowerActor(a))
        case .funcDecl(let f):
            return .funcDecl(lowerFunc(f))
        case .interfaceDecl:
            preconditionFailure("interfaces are validated in check(), not lowered (M5 A1)")
        case .extensionDecl:
            preconditionFailure("extensions must be merged before Sema (M4.12)")
        }
    }

    // Validate an interface (M5 A1): its requirement signatures must resolve, and each
    // overridable default body must typecheck. In a default, `self` is the interface
    // type, its property requirements are visible by bare name, and `self.req(...)` /
    // `self.prop` resolve against the requirement set. No IR is retained — conformance
    // (a later slice) compiles the defaults into each conformer's witnesses.
    private mutating func checkInterface(_ i: InterfaceDecl) {
        // Within an interface, `Self` ≡ the interface's own type (its `self` value's type,
        // §4.4): requirement signatures validate against it and default bodies read it (M5 A2).
        let selfType = Type.named(i.name, .interface_)
        for m in i.methods {
            for p in m.params { _ = resolve(p.type, selfAs: selfType) }
            _ = resolve(m.returnType, selfAs: selfType)
        }
        for p in i.properties { _ = resolve(p.type, selfAs: selfType) }

        for m in i.methods {
            guard let body = m.defaultBody else { continue }
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = resolve(m.returnType, selfAs: selfType)
            pushScope()
            declare("self", selfType)
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            _ = lowerBlock(body)
            currentReturnType = saved
            popScope()
        }
    }

    // MARK: - Generic decls (M5 5.2.1)

    // A generic bound must name an interface. A `Self`-mentioning (constraint-only) bound is now
    // allowed: monomorphization (M5 5.4) specializes `<T: I>` to a concrete `T` where `-> Self` is
    // a direct call — no Self-witness needed — so the 5.2.2 deferral is lifted (M5 5.6).
    private func validateBounds(_ generics: [GenericParam]) {
        for g in generics {
            for b in g.bounds where interfaces[b.name] == nil {
                diags.error("'\(b.name)' is not an interface — a generic bound must name an interface", at: b.span)
            }
        }
    }

    private func isGenericType(_ decl: TopDecl) -> Bool {
        switch decl {
        case .structDecl(let s): return !s.generics.isEmpty
        case .enumDecl(let e):   return !e.generics.isEmpty
        case .classDecl(let c):  return !c.generics.isEmpty
        default: return false
        }
    }

    // Validate a generic *type*'s parameter bounds and field signatures with its type
    // parameters in scope, emitting no IR (M5 5.2.1). Value-witness lowering is 5.2.3.
    // Lower a generic type to one uniform IR shape (M5 5.2.3): its type parameters are in
    // scope while resolving fields (so a `T` field becomes `.typeParam("T")`), the bounds are
    // recorded, and the generic params ride onto the IR decl for codegen. Instance methods /
    // computed properties on a generic type are deferred — rejected with a clear message.
    private mutating func lowerGenericDecl(_ decl: TopDecl) -> NOIRDecl {
        let generics: [GenericParam]
        switch decl {
        case .structDecl(let s): generics = s.generics
        case .enumDecl(let e):   generics = e.generics
        case .classDecl(let c):  generics = c.generics
        default: preconditionFailure("lowerGenericDecl on a non-generic-capable decl")
        }
        let savedScope = genericScope; let savedBounds = genericBounds
        genericScope = Set(generics.map(\.name))
        for g in generics { genericBounds[g.name] = g.bounds.map(\.name) }
        defer { genericScope = savedScope; genericBounds = savedBounds }
        validateBounds(generics)
        let irGenerics = generics.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(\.name), isShared: $0.isShared) }
        switch decl {
        case .structDecl(let s):
            // Instance methods on a generic struct (task 151, slice 1). `self` is the applied generic
            // type `S<T…>`; fields and signatures resolve with the type's params in scope (set above),
            // so a `T` becomes `.typeParam`. Monomorphization specializes each method per instantiation.
            let selfT = Type.generic(base: s.name, args: generics.map { .typeParam($0.name) })
            let fields = s.fields.map(lowerField)
            let methods = lowerMethods(s.methods, selfType: selfT, fields: fields)
                        + lowerAccessors(s.properties, selfType: selfT, fields: fields)
            lowerStaticMethods(s.methods, typeName: s.name, generics: irGenerics)
            return .structDecl(NOIRStruct(name: s.name, generics: irGenerics,
                                        fields: fields, methods: methods, span: s.span))
        case .classDecl(let c):
            let selfT = Type.generic(base: c.name, args: generics.map { .typeParam($0.name) })
            let fields = c.fields.map(lowerField)
            let methods = lowerMethods(c.methods, selfType: selfT, fields: fields)
                        + lowerAccessors(c.properties, selfType: selfT, fields: fields)
            lowerStaticMethods(c.methods, typeName: c.name, generics: irGenerics)
            return .classDecl(NOIRClass(name: c.name, generics: irGenerics,
                                      fields: fields, methods: methods, span: c.span))
        case .enumDecl(let e):
            let selfT = Type.generic(base: e.name, args: generics.map { .typeParam($0.name) })
            let cases = e.cases.map { NOIREnumCase(name: $0.name, fields: $0.fields.map(lowerField), span: $0.span) }
            let methods = lowerMethods(e.methods, selfType: selfT, fields: [])
                        + lowerAccessors(e.properties, selfType: selfT, fields: [])
            lowerStaticMethods(e.methods, typeName: e.name, generics: irGenerics)
            return .enumDecl(NOIREnum(name: e.name, generics: irGenerics, cases: cases, methods: methods, span: e.span))
        default: preconditionFailure("unreachable")
        }
    }

    private mutating func rejectGenericMembers(_ methods: [FuncDecl], _ properties: [ComputedProperty], at span: Span) {
        if !methods.isEmpty || !properties.isEmpty {
            diags.error("methods and computed properties on a generic type aren't supported yet (M5 5.2.3)", at: span)
        }
    }


    // A method requirement (or default) named `name` reachable from an interface,
    // including inherited requirements (aggregated over the refinement graph).
    private func interfaceMethod(_ typeName: String, _ name: String) -> InterfaceMethod? {
        aggregatedMethods(typeName).first { $0.name == name }
    }

    // MARK: - Refinement graph (M5 A1.5)

    // Base interfaces reachable from `iface` (transitive), cycle-guarded.
    private func transitiveBases(_ iface: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = [iface]
        var stack = (interfaceBases[iface] ?? []).map(\.name)
        while let b = stack.popLast() {
            guard !seen.contains(b) else { continue }
            seen.insert(b)
            result.append(b)
            stack.append(contentsOf: (interfaceBases[b] ?? []).map(\.name))
        }
        return result
    }

    private func methodKey(_ m: InterfaceMethod) -> String {
        m.name + "(" + m.params.map { resolve($0.type, selfAs: .selfType).description }.joined(separator: ",") + ")"
    }

    // MARK: - `Self`-requirement / constraint-only analysis (M5 A2)

    // Does this type reference mention `Self` (directly or nested in a function type)?
    private func mentionsSelf(_ ref: TypeRef?) -> Bool {
        guard let ref else { return false }
        if ref.name == "Self" { return true }
        if let fn = ref.fn { return fn.params.contains(where: mentionsSelf) || mentionsSelf(fn.ret) }
        return false
    }

    // `Self` used covariantly is safe to erase behind `any I` (it only *produces* a Self, handed
    // back as another box); used contravariantly/invariantly it is not (M5 5.6, interfaces.md §4.4).
    // Conservative rule: covariant = a bare `-> Self` method return, or a `{ get }`-only `Self`
    // property. Non-covariant = `Self` in a parameter, a `{ get set }` `Self` property, or `Self`
    // nested inside a function type (either side — the full variance calculus is deferred).
    private func isBareSelf(_ ref: TypeRef?) -> Bool { ref?.name == "Self" && ref?.fn == nil }

    // Does an interface's *own* requirements use `Self` in a non-covariant position?
    private func ownHasNonCovariantSelf(_ iface: String) -> Bool {
        guard let d = interfaces[iface] else { return false }
        for m in d.methods {
            if m.params.contains(where: { mentionsSelf($0.type) }) { return true }        // parameter
            if mentionsSelf(m.returnType) && !isBareSelf(m.returnType) { return true }     // nested in return
        }
        for p in d.properties where mentionsSelf(p.type) {
            if !isBareSelf(p.type) || p.isSettable { return true }                         // nested, or get set
        }
        return false
    }

    // Constraint-only after 5.6: has a non-covariant `Self` (own or inherited) — usable as a
    // generic bound / `some I` but rejected as `any I`, and it emits no witness table. A
    // covariant-only `Self` interface (or one with no `Self`) is existential-legal: it *does*
    // emit a witness, with each `-> Self` requirement erased to `-> any I` at the box boundary.
    // Refinement propagates the property (`B: A` is constraint-only if `A` is).
    private func hasNonCovariantSelf(_ iface: String) -> Bool {
        ownHasNonCovariantSelf(iface) || transitiveBases(iface).contains { ownHasNonCovariantSelf($0) }
    }

    // The full method-requirement set of `iface` = its own plus every inherited one,
    // deduplicated by signature; each carries its resolved default (§4.3).
    private func aggregatedMethods(_ iface: String) -> [InterfaceMethod] {
        let all = [iface] + transitiveBases(iface)
        var order: [String] = []
        var rep: [String: InterfaceMethod] = [:]
        var defaults: [String: [(String, Block)]] = [:]   // key → [(declaring interface, default body)]
        for ifn in all {
            for m in interfaces[ifn]?.methods ?? [] {
                let key = methodKey(m)
                if rep[key] == nil { rep[key] = m; order.append(key) }
                if let body = m.defaultBody { defaults[key, default: []].append((ifn, body)) }
            }
        }
        return order.map { key in
            let m = rep[key]!
            return InterfaceMethod(name: m.name, params: m.params, returnType: m.returnType,
                                   defaultBody: resolveDefault(defaults[key] ?? []), span: m.span)
        }
    }

    // Most-specific default wins; incomparable sibling defaults cancel → mandatory (nil).
    private func resolveDefault(_ candidates: [(String, Block)]) -> Block? {
        guard candidates.count != 1 else { return candidates[0].1 }
        guard !candidates.isEmpty else { return nil }
        // A candidate dominates if it refines (or equals) every other candidate's interface.
        let dominators = candidates.filter { x in
            candidates.allSatisfy { y in x.0 == y.0 || transitiveBases(x.0).contains(y.0) }
        }
        return dominators.count == 1 ? dominators[0].1 : nil
    }

    private func aggregatedProperties(_ iface: String) -> [InterfacePropertyReq] {
        let all = [iface] + transitiveBases(iface)
        var order: [String] = []
        var byName: [String: InterfacePropertyReq] = [:]
        for ifn in all {
            for p in interfaces[ifn]?.properties ?? [] {
                if let existing = byName[p.name] {
                    // A settable requirement anywhere makes the aggregated one settable.
                    byName[p.name] = InterfacePropertyReq(name: p.name, type: p.type,
                                                          isSettable: existing.isSettable || p.isSettable, span: p.span)
                } else {
                    byName[p.name] = p
                    order.append(p.name)
                }
            }
        }
        return order.map { byName[$0]! }
    }

    // Each base must name an interface, and refinement must be acyclic.
    private func validateInterfaceGraph() {
        for (name, bases) in interfaceBases {
            for base in bases {
                if interfaces[base.name] == nil {
                    if kindOf(base.name) != nil {
                        diags.error("'\(base.name)' is not an interface; an interface may only refine interfaces", at: base.span)
                    } else {
                        diags.error("unknown interface '\(base.name)'", at: base.span)
                    }
                } else if base.name == name || transitiveBases(base.name).contains(name) {
                    diags.error("interface '\(name)' refinement is cyclic through '\(base.name)'", at: base.span)
                }
            }
        }
    }

    // The interfaces' requirement surface, resolved to types, for witness-table layout.
    private func buildIRInterfaces() -> [NOIRInterface] {
        var out: [NOIRInterface] = []
        for decl in program.decls {
            guard case .interfaceDecl(let i) = decl else { continue }
            // A non-covariant-`Self` (constraint-only) interface can't be `any I`, so it gets no
            // witness table. A covariant-only interface *does* — each `-> Self` requirement's slot
            // is **erased to `any I`** (`selfAs: .existential`), so the slot has a uniform concrete
            // representation (`AnyBox`); the thunk re-boxes the concrete result (M5 5.6).
            if hasNonCovariantSelf(i.name) { continue }
            let selfErased = Type.existential(i.name)
            // Aggregated (flattened) surface: the witness table carries inherited slots too.
            let methods = aggregatedMethods(i.name).map { NOIRMethodReq(name: $0.name, params: $0.params.map { resolve($0.type, selfAs: selfErased) }, ret: resolve($0.returnType, selfAs: selfErased)) }
            let props = aggregatedProperties(i.name).map { NOIRPropReq(name: $0.name, type: resolve($0.type, selfAs: selfErased), isSettable: $0.isSettable) }
            // Only any-able bases carry a witness, so only they get a base pointer (M5 A1.4 upcast).
            let bases = transitiveBases(i.name).filter { !hasNonCovariantSelf($0) }.sorted()
            out.append(NOIRInterface(name: i.name, methods: methods, properties: props, bases: bases))
        }
        return out
    }

    // Synthesize a concrete method on `T` for each defaulted requirement it inherits: the
    // default body lowered with `self: T`, so both concrete calls and witness slots resolve
    // to it (M5 A1.4). First cut: a default may reference directly-implemented requirements
    // (via `self.req()`) and stored-field state (bare name); default-calling-default and
    // computed-backed bare access are later work.
    private mutating func lowerInheritedDefaults(_ typeName: String, selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        for req in inheritedDefaults[typeName] ?? [] {
            guard let body = req.defaultBody else { continue }
            // A default is synthesized as a concrete method of the conformer, so `Self` binds
            // to the conformer's concrete type here (M5 A2).
            let params = req.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = resolve(req.returnType, selfAs: selfType)
            pushScope()
            declare("self", selfType)
            for f in fields { declare(f.name, f.type) }
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let irBody = lowerBlock(body)
            currentReturnType = saved
            popScope()
            out.append(NOIRFunc(name: req.name, params: params, returnType: ret, body: irBody, isMutating: false, span: req.span))
        }
        return out
    }

    // MARK: - Conformance checking (M5 A1.3)

    // Verify each declared conformance: every requirement of the interface is satisfied
    // by a matching member (or an interface default). Struct/enum/class only — actor
    // conformance is parked post-M5 (interfaces.md §1). No witnesses yet (A1.4).
    private mutating func checkConformances() {
        for decl in program.decls {
            // A generic type's conformance is checked when it is lowered (5.2.3), not here.
            if isGenericType(decl) { continue }
            switch decl {
            case .structDecl(let s):
                checkConformance(s.name, .struct_, s.conformances, methods: s.methods, fields: s.fields, properties: s.properties)
            case .enumDecl(let e):
                checkConformance(e.name, .enum_, e.conformances, methods: e.methods, fields: [], properties: e.properties)
            case .classDecl(let c):
                checkConformance(c.name, .class_, c.conformances, methods: c.methods, fields: c.fields, properties: c.properties)
            case .actorDecl(let a):
                for conf in a.conformances {
                    diags.error("actors cannot conform to interfaces yet ('\(a.name): \(conf.name)') — parked post-M5", at: conf.span)
                }
            default:
                break
            }
        }
    }

    private mutating func checkConformance(_ typeName: String, _ kind: NamedKind, _ conformances: [Conformance],
                                           methods: [FuncDecl], fields: [VarField], properties: [ComputedProperty]) {
        for conf in conformances {
            guard interfaces[conf.name] != nil else {
                if kindOf(conf.name) != nil {
                    diags.error("'\(conf.name)' is not an interface; '\(typeName)' can only conform to interfaces", at: conf.span)
                } else {
                    diags.error("unknown interface '\(conf.name)'", at: conf.span)
                }
                continue
            }
            // Conforming to a refining interface conforms to every base too, so a witness
            // exists for each (dedup so one isn't emitted twice, M5 A1.5). A constraint-only
            // (`Self`-mentioning) interface emits no witness (M5 A2) — it can't be `any I`, so
            // no table/instance is needed — but this is decided *per interface*: a constraint-
            // only refiner of an any-able base still needs the base's witness, so `any Base`
            // accepts the conformer. Its conformance is still checked below for correctness.
            for iface in [conf.name] + transitiveBases(conf.name) {
                // The conformance fact is recorded for every interface (incl. constraint-only),
                // so `some I` can verify its underlying (M5 A3).
                allConformsTo[typeName, default: []].insert(iface)
                // A witness is emitted only for an any-able (covariant-only-`Self`) interface;
                // a non-covariant-`Self` interface stays witness-less (M5 5.6).
                guard !hasNonCovariantSelf(iface) else { continue }
                conformsTo[typeName, default: []].insert(iface)
                if conformancePairs.insert("\(typeName):\(iface)").inserted {
                    conformanceList.append(NOIRConformance(typeName: typeName, typeKind: kind, interfaceName: iface))
                }
            }
            // Check the full (aggregated) requirement set, so inherited requirements count.
            for req in aggregatedMethods(conf.name) { checkMethodRequirement(req, typeName: typeName, kind: kind, interface: conf, methods: methods) }
            for req in aggregatedProperties(conf.name) { checkPropertyRequirement(req, typeName: typeName, kind: kind, interface: conf, fields: fields, properties: properties) }
        }
    }

    // A method requirement is satisfied by a same-named method with matching parameter
    // types and return type, or (if none) by the interface's overridable default.
    private mutating func checkMethodRequirement(_ req: InterfaceMethod, typeName: String, kind: NamedKind, interface conf: Conformance, methods: [FuncDecl]) {
        let selfType = Type.named(typeName, kind)
        let named = methods.filter { $0.name == req.name }
        if named.contains(where: { methodMatches(req, $0, selfAs: selfType) }) { return }
        if req.defaultBody != nil {
            // Satisfied by the interface's overridable default — this conformer inherits
            // it, so it is synthesized once as a concrete method of the type (M5 A1.4).
            if !(inheritedDefaults[typeName] ?? []).contains(where: { $0.name == req.name }) {
                inheritedDefaults[typeName, default: []].append(req)
            }
            return
        }
        if named.isEmpty {
            diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing method '\(req.name)'", at: conf.span)
        } else {
            diags.error("type '\(typeName)' does not conform to '\(conf.name)': method '\(req.name)' has the wrong signature", at: conf.span)
        }
    }

    // A requirement's `Self` binds to the conformer's concrete type when matching, so
    // `fun clone() -> Self` is satisfied by `fun clone() -> Point` on `Point` (M5 A2). The
    // implementation is concrete, so its own signature never mentions `Self`.
    private func methodMatches(_ req: InterfaceMethod, _ impl: FuncDecl, selfAs: Type) -> Bool {
        guard req.params.count == impl.params.count else { return false }
        for (rp, ip) in zip(req.params, impl.params) where resolve(rp.type, selfAs: selfAs) != resolve(ip.type) { return false }
        return resolve(req.returnType, selfAs: selfAs) == resolve(impl.returnType)
    }

    // A property requirement is satisfied by a stored field or computed property of the
    // same name and type; a `{ get set }` requirement needs a settable member.
    private mutating func checkPropertyRequirement(_ req: InterfacePropertyReq, typeName: String, kind: NamedKind, interface conf: Conformance, fields: [VarField], properties: [ComputedProperty]) {
        let reqType = resolve(req.type, selfAs: .named(typeName, kind))
        if let f = fields.first(where: { $0.name == req.name }) {
            if resolve(f.type) != reqType {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(resolve(f.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && !f.isMutable {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' must be a 'var' to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        if let p = properties.first(where: { $0.name == req.name }) {
            if resolve(p.type) != reqType {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(resolve(p.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && p.setter == nil {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': computed property '\(req.name)' needs a setter to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing property '\(req.name)'", at: conf.span)
    }

    private func lowerField(_ f: VarField) -> NOIRField {
        NOIRField(name: f.name, type: resolve(f.type), isMutable: f.isMutable, span: f.span)
    }

    // Lower each `fun` member with `self` (immutable) and the receiver's fields
    // declared by bare name, mirroring how actor handlers see their fields (T3).
    private mutating func lowerMethods(_ methods: [FuncDecl], selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        let ownerType: String? = {
            switch selfType {
            case .named(let n, _), .generic(let n, _): return n
            default:                                   return nil
            }
        }()
        for m in methods where !m.isStatic {
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            // A `some I` method return keys its opaque identity by "m:Type.method" — the same
            // key the call site uses when it resolves the method's return type (M5 A3).
            let ret = resolve(m.returnType, opaqueOwner: ownerType.map { "m:\($0).\(m.name)" })
            pushScope()
            declare("self", selfType)
            for f in fields { declare(f.name, f.type) }
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let body = lowerBlock(m.body)
            currentReturnType = saved
            popScope()
            out.append(NOIRFunc(name: m.name, params: params, returnType: ret, body: body, isMutating: false, span: m.span))
        }
        return out
    }

    // Lower each `static fun` member as a free function named `Type.method` — no `self` and no
    // fields in scope, so a body that references `self` or a bare field name is an undefined-name
    // error. The qualified name is unspellable by users, so it never collides with a real free
    // function; the call site `Type.method(...)` targets it as an ordinary direct call.
    private mutating func lowerStaticMethods(_ methods: [FuncDecl], typeName: String,
                                             generics: [NOIRGenericParam] = []) {
        for m in methods where m.isStatic {
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let ret = resolve(m.returnType)
            pushScope()
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let body = lowerBlock(m.body)
            currentReturnType = saved
            popScope()
            // On a generic type the free function carries the type's parameters, so monomorphization
            // treats it as a generic template and specializes it per instantiation (task 151).
            pendingStaticFuncs.append(.funcDecl(NOIRFunc(name: "\(typeName).\(m.name)", generics: generics,
                                                         params: params, returnType: ret, body: body,
                                                         isMutating: false, span: m.span)))
        }
    }

    private mutating func registerProps(_ typeName: String, _ props: [ComputedProperty], generics: [GenericParam] = []) {
        let saved = genericScope; genericScope = Set(generics.map(\.name)); defer { genericScope = saved }
        var table: [String: PropInfo] = [:]
        for p in props { table[p.name] = PropInfo(type: resolve(p.type), hasSetter: p.setter != nil) }
        computedProps[typeName] = table
    }

    // A computed property lowers to accessor methods on its type: a getter `prop.get`
    // (() -> T) and, if settable, a setter `prop.set` ((T) -> Void). The `.` keeps
    // their names out of any user method's namespace (Mangle 9-encodes it), and being
    // ordinary methods they reuse method codegen, self-passing, and mutation inference
    // (the setter is inferred mutating because it writes a field).
    private mutating func lowerAccessors(_ props: [ComputedProperty], selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        for p in props {
            let propType = resolve(p.type)
            let getBody = accessorBody(p.getter, returnType: propType, selfType: selfType,
                                       fields: fields, params: [], span: p.span)
            out.append(NOIRFunc(name: "\(p.name).get", params: [], returnType: propType,
                              body: getBody, isMutating: false, span: p.span))
            if let setter = p.setter {
                let param = NOIRParam(label: setter.paramName, name: setter.paramName, type: propType, span: p.span)
                let setBody = accessorBody(setter.body, returnType: .void, selfType: selfType,
                                           fields: fields, params: [param], span: p.span)
                out.append(NOIRFunc(name: "\(p.name).set", params: [param], returnType: .void,
                                  body: setBody, isMutating: false, span: p.span))
            }
        }
        return out
    }

    // Lowers an accessor body with `self`, the type's fields, and any accessor param in
    // scope (mirroring `lowerMethods`). A single-expression getter body is an implicit
    // `return` of that expression (the bare-body shorthand, and the common `get` form).
    private mutating func accessorBody(_ block: Block, returnType: Type, selfType: Type,
                                       fields: [NOIRField], params: [NOIRParam], span: Span) -> [NOIRStmt] {
        var block = block
        if returnType != .void, block.count == 1, case .expr(let e) = block[0] {
            block = [.ret(e, span: span)]
        }
        pushScope()
        declare("self", selfType)
        for f in fields { declare(f.name, f.type) }
        for p in params { declare(p.name, p.type) }
        let saved = currentReturnType; currentReturnType = returnType
        let body = lowerBlock(block)
        currentReturnType = saved
        popScope()
        return body
    }

    private mutating func lowerFunc(_ f: FuncDecl) -> NOIRFunc {
        // A generic function's type parameters + bounds are in scope while lowering its body,
        // so `x: T` typechecks and `x.req()` dispatches through the bound's witness (M5 5.2.2).
        let savedScope = genericScope, savedBounds = genericBounds, savedShared = sharedParams
        genericScope = Set(f.generics.map(\.name))
        genericBounds = Dictionary(f.generics.map { ($0.name, $0.bounds.map(\.name)) }, uniquingKeysWith: { a, _ in a })
        sharedParams = Set(f.generics.filter(\.isShared).map(\.name))
        defer { genericScope = savedScope; genericBounds = savedBounds; sharedParams = savedShared }
        validateBounds(f.generics)
        let params = f.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
        let ret = resolve(f.returnType, opaqueOwner: "fn:\(f.name)")
        pushScope()
        for p in params { declare(p.name, p.type) }
        let saved = currentReturnType; currentReturnType = ret
        let body = lowerBlock(f.body)
        currentReturnType = saved
        popScope()
        let irGenerics = f.generics.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(\.name), isShared: $0.isShared) }
        return NOIRFunc(name: f.name, generics: irGenerics, params: params, returnType: ret, body: body, isMutating: false, span: f.span)
    }

    private mutating func lowerActor(_ a: ActorDecl) -> NOIRActor {
        let fields = a.fields.map { af in
            NOIRActorField(name: af.name, type: resolve(af.type),
                         initializer: af.initializer.map { checkExpr($0) }, span: af.span)
        }
        var handlers: [NOIRHandler] = []
        for h in a.handlers {
            let params = h.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let ret = resolve(h.returnType)
            // Actors are fire-and-forget message-send only (§9): a handler is a one-way message
            // sink and cannot return a value to the sender. There is no reply/ask mechanism; a value
            // from concurrent work comes from a `spawn let` result or a channel, not an actor.
            if ret != .void {
                diags.error("an actor 'on' handler cannot return a value — actor messages are fire-and-forget (a handler is a one-way message sink). To get a value from concurrent work, use a spawned task's result or a channel, not an actor", at: h.span)
            }
            pushScope()
            for f in fields { declare(f.name, f.type) }   // handler body sees actor fields by name
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let body = lowerBlock(h.body)
            currentReturnType = saved
            popScope()
            handlers.append(NOIRHandler(name: h.name, params: params, returnType: ret, body: body, span: h.span))
        }
        return NOIRActor(name: a.name, fields: fields, handlers: handlers, span: a.span)
    }

    // MARK: - Statements

    private mutating func lowerBlock(_ block: Block) -> [NOIRStmt] {
        pushScope()
        let stmts = block.map { lowerStmt($0) }
        popScope()
        return stmts
    }

    private mutating func lowerStmt(_ stmt: Stmt) -> NOIRStmt {
        switch stmt {
        case .binding(let b):
            // `let x: some I = expr` — a fresh opaque binding whose hidden underlying is
            // `expr`'s concrete type (M5 A3). Each such binding gets its own opaque identity.
            if let tref = b.type, tref.opaqueOf != nil {
                opaqueBindingCounter += 1
                let owner = "let:\(opaqueBindingCounter)"
                let ann = resolve(tref, opaqueOwner: owner)
                let value = checkExpr(b.value)
                if case .opaque(let ifaces, _) = ann {
                    recordOpaque(value, interfaces: ifaces, owner: owner, at: b.span)
                }
                declare(b.name, ann, isMutable: b.isMutable)
                return NOIRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)
            }
            let annotated = b.type.map { resolve($0) }
            let value = coerce(checkExpr(b.value, expected: annotated), to: annotated)
            checkAssignable(value.type, to: annotated, role: "bind", at: b.span)
            let type = annotated ?? value.type
            declare(b.name, type, isMutable: b.isMutable)
            return NOIRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)

        case .spawnLet(let name, _, let value, let span):
            let v = checkExpr(value)
            declare(name, v.type)   // reading a spawn binding yields its result value
            return NOIRStmt(kind: .spawnLet(name: name, value: v, resultType: v.type), span: span)

        case .assign(let lhs, let rhs, let span):
            // Array subscript write `a[i] = x` — reference semantics (mutates the shared buffer, so a
            // `let`-bound array is fine, like a class field). Lowered to a builtin call codegen handles.
            if case .index(let arr, let idxE, _) = lhs {
                let a = checkExpr(arr)
                guard case .array(let elem) = a.type else {
                    if a.type != .error { diags.error("cannot subscript-assign a value of type '\(a.type)' — only 'Array<T>' supports '[ ] ='", at: span) }
                    return NOIRStmt(kind: .exprStmt(checkExpr(rhs)), span: span)
                }
                let iIdx = checkExpr(idxE, expected: .int)
                if iIdx.type != .int && iIdx.type != .error {
                    diags.error("array index must be an 'Int', got '\(iIdx.type)'", at: iIdx.span)
                }
                let value = coerce(checkExpr(rhs, expected: elem), to: elem)
                checkAssignable(value.type, to: elem, role: "assign", at: span)
                let callee = NOIRExpr(type: .void, span: span, kind: .varRef("__arraySet"))
                let call = NOIRExpr(type: .void, span: span, kind: .call(callee: callee,
                    args: [NOIRArg(label: nil, value: a), NOIRArg(label: nil, value: iIdx), NOIRArg(label: nil, value: value)], typeArgs: []))
                return NOIRStmt(kind: .exprStmt(call), span: span)
            }
            // A write to a computed property lowers to a setter accessor call (M5 A1).
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(base)
                // A property write through `any I` / `any A & B` — dispatched via the witness
                // set slot (M5 A1.4). A get-only requirement is a clean local error.
                if let iface = existentialInterfaces(b.type).first(where: { aggregatedProperties($0).contains { $0.name == field } }),
                   let prop = aggregatedProperties(iface).first(where: { $0.name == field }) {
                    let propType = resolve(prop.type)
                    guard prop.isSettable else {
                        diags.error("cannot assign to read-only property '\(field)' of 'any \(iface)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(rhs, expected: propType)
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                // A property write inside an interface default (self: interface) — routes to the
                // set slot; the concrete synthesized copy writes the real field/setter (M5).
                if case .named(let tn, .interface_) = b.type,
                   let prop = aggregatedProperties(tn).first(where: { $0.name == field }) {
                    let propType = resolve(prop.type)
                    guard prop.isSettable else {
                        diags.error("cannot assign to read-only property '\(field)' of '\(tn)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(rhs, expected: propType)
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                if case .named(let tn, let kind) = b.type, let info = computedProps[tn]?[field] {
                    guard info.hasSetter else {
                        diags.error("cannot assign to read-only computed property '\(field)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(rhs, expected: info.type)), span: span)
                    }
                    let value = checkExpr(rhs, expected: info.type)
                    // The setter mutates the value; on a value type it needs a mutable receiver.
                    if kind != .class_ {
                        methodCallSites.append(CallSite(callee: "\(tn).\(field).set",
                                                        receiverMutable: isMutableReceiver(base), span: span))
                    }
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                // Computed-property write on an applied generic type `Box<Int>` (task 151).
                if case .generic(let gbase, let gargs) = b.type, let info = computedProps[gbase]?[field] {
                    let propType = substitute(info.type, genericSubst(gbase, gargs))
                    guard info.hasSetter else {
                        diags.error("cannot assign to read-only computed property '\(field)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(rhs, expected: propType)
                    if kindOf(gbase) != .class_ {
                        methodCallSites.append(CallSite(callee: "\(gbase).\(field).set",
                                                        receiverMutable: isMutableReceiver(base), span: span))
                    }
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                let ftype = fieldType(of: b.type, field: field, at: mspan)
                let target = NOIRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(target)
                let value = coerce(checkExpr(rhs, expected: ftype), to: ftype)
                checkAssignable(value.type, to: ftype, role: "assign", at: span)
                return NOIRStmt(kind: .assign(target: target, value: value), span: span)
            }
            let target = checkExpr(lhs)
            rejectLetFieldTarget(target)
            let value = coerce(checkExpr(rhs, expected: target.type), to: target.type)
            checkAssignable(value.type, to: target.type, role: "assign", at: span)
            return NOIRStmt(kind: .assign(target: target, value: value), span: span)

        case .compoundAssign(let lhs, let rhs, let span):
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(base)
                if case .named(let tn, _) = b.type, computedProps[tn]?[field] != nil {
                    diags.error("compound assignment ('+=') to a computed property is not supported yet", at: span)
                    return NOIRStmt(kind: .exprStmt(checkExpr(rhs)), span: span)
                }
                let ftype = fieldType(of: b.type, field: field, at: mspan)
                let target = NOIRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(target)
                // The `+=` operand takes the target's type as context, so a bare literal adopts it
                // (`w += 1` on a UInt64 keeps the whole op UInt64) rather than defaulting to Int.
                return NOIRStmt(kind: .compoundAssign(target: target, value: checkExpr(rhs, expected: ftype)), span: span)
            }
            let target = checkExpr(lhs)
            rejectLetFieldTarget(target)
            return NOIRStmt(kind: .compoundAssign(target: target, value: checkExpr(rhs, expected: target.type)), span: span)

        case .ret(let e, let span):
            // A `some I` return is not a coercion target — it yields the concrete value
            // unboxed and records the one hidden underlying type (M5 A3).
            if case .opaque(let ifaces, let owner) = currentReturnType {
                let v = e.map { checkExpr($0) }
                if let v { recordOpaque(v, interfaces: ifaces, owner: owner, at: span) }
                return NOIRStmt(kind: .ret(v), span: span)
            }
            let ret = e.map { coerce(checkExpr($0, expected: currentReturnType), to: currentReturnType) }
            if let ret { checkAssignable(ret.type, to: currentReturnType, role: "return", at: span) }
            return NOIRStmt(kind: .ret(ret), span: span)

        case .ifStmt(let s):
            let cond = checkExpr(s.cond)
            let then = lowerBlock(s.thenBody)
            let els = s.elseBody.map { lowerBlock($0) }
            return NOIRStmt(kind: .ifStmt(cond: cond, then: then, else: els), span: s.span)

        case .whileStmt(let s):
            let cond = checkExpr(s.cond)
            loopDepth += 1
            let body = lowerBlock(s.body)
            loopDepth -= 1
            return NOIRStmt(kind: .whileStmt(cond: cond, body: body), span: s.span)

        case .breakStmt(let span):
            if loopDepth == 0 { diags.error("'break' outside a loop", at: span) }
            return NOIRStmt(kind: .breakStmt, span: span)

        case .continueStmt(let span):
            if loopDepth == 0 { diags.error("'continue' outside a loop", at: span) }
            return NOIRStmt(kind: .continueStmt, span: span)

        case .switchStmt(let sw):
            return NOIRStmt(kind: .switchStmt(lowerSwitch(sw)), span: sw.span)

        case .expr(let e):
            let ir = checkExpr(e)
            return NOIRStmt(kind: .exprStmt(ir), span: ir.span)
        }
    }

    private mutating func lowerSwitch(_ sw: SwitchStmt) -> NOIRSwitch {
        let subject = checkExpr(sw.subject)
        // The subject's enum, if any, gives payload binding types. An applied generic enum
        // (`Option<Int>`) substitutes its type arguments into each payload binding (M5 5.2.3).
        let enumDecl: EnumDecl?
        var enumSubst: [String: Type] = [:]
        switch subject.type {
        case .named(let n, .enum_):
            enumDecl = enums[n]
        case .generic(let n, let a):
            enumDecl = enums[n]
            for (p, t) in zip(enums[n]?.generics ?? [], a) { enumSubst[p.name] = t }
        default:
            enumDecl = nil
        }
        let savedScope = genericScope
        if let g = enumDecl?.generics, !g.isEmpty { genericScope = Set(g.map(\.name)) }
        defer { genericScope = savedScope }
        var arms: [NOIRCaseArm] = []
        for arm in sw.cases {
            guard case .enumCase(let name, let names, _) = arm.pattern else { continue }
            let caseDecl = enumDecl?.cases.first { $0.name == name }
            let bindings: [NOIRBinding] = zip(names, caseDecl?.fields ?? []).map {
                NOIRBinding(name: $0.0, type: substitute(resolve($0.1.type), enumSubst))
            }
            pushScope()
            for b in bindings { declare(b.name, b.type) }
            let body = lowerBlock(arm.body)
            popScope()
            arms.append(NOIRCaseArm(caseName: name, bindings: bindings, body: body, span: arm.span))
        }
        return NOIRSwitch(subject: subject, arms: arms)
    }

    // MARK: - Expressions

    // Coerce a concrete conformer to `any I` / `any A & B` where an existential is
    // expected, inserting a box (M5 A1.4/A1.5b). A conformance mismatch is diagnosed here.
    // A binding/return annotation must match the value's type once coercions have run
    // (existential/opaque targets already rewrote the type). Anything still unequal is a
    // mismatch — caught here rather than leaking to the C compiler, and (for generics, whose
    // instantiations share one C layout) rather than passing silently.
    private mutating func checkAssignable(_ actual: Type, to expected: Type?, role: String, at span: Span) {
        guard let expected, actual != expected, actual != .error, expected != .error else { return }
        switch role {
        case "return": diags.error("cannot return value of type '\(actual)' where '\(expected)' is expected", at: span)
        case "assign": diags.error("cannot assign value of type '\(actual)' to '\(expected)'", at: span)
        default:       diags.error("cannot bind value of type '\(actual)' to '\(expected)'", at: span)
        }
    }

    private mutating func coerce(_ e: NOIRExpr, to expected: Type?) -> NOIRExpr {
        let target: [String]
        switch expected {
        case .existential(let iface): target = [iface]
        case .composition(let ifaces): target = ifaces
        default: return e
        }
        // Already this existential/composition.
        if e.type == expected { return e }
        switch e.type {
        case .named(let t, let kind):
            let missing = target.filter { conformsTo[t]?.contains($0) != true }
            if missing.isEmpty {
                if target.count > 1 { recordComposite(t, kind, target) }
                return NOIRExpr(type: expected!, span: e.span, kind: .box(value: e, interfaces: target))
            }
            diags.error("type '\(t)' does not conform to '\(missing.joined(separator: " & "))'", at: e.span)
            return e
        case .existential(let src):
            // `any B` → `any A` where B refines A: re-box through the source witness's base
            // pointer (M5 A1.4). Composition targets/sources stay unsupported for now.
            if target.count == 1, target[0] == src || transitiveBases(src).contains(target[0]) {
                return NOIRExpr(type: expected!, span: e.span, kind: .box(value: e, interfaces: target))
            }
            diags.error("cannot convert 'any \(src)' to 'any \(target.joined(separator: " & "))' — 'any B' only widens to a base interface of B", at: e.span)
            return e
        case .composition:
            diags.error("existential upcast from a composition is not supported yet; box the concrete value directly", at: e.span)
            return e
        case .error:
            return e
        default:
            diags.error("cannot convert '\(e.type)' to 'any \(target.joined(separator: " & "))'", at: e.span)
            return e
        }
    }

    // Validate and record the hidden underlying of a `some I` site (M5 A3): the value must be
    // a concrete type conforming to every listed interface, and — across a function's returns —
    // must be the *same* concrete type each time (the one underlying).
    private mutating func recordOpaque(_ v: NOIRExpr, interfaces: [String], owner: String, at span: Span) {
        // Look through an opaque initializer/return to its concrete underlying (M5 A3): a
        // `some I` value can be produced by returning / binding another opaque of a known
        // underlying, not only a concrete literal.
        var concrete = v.type
        if case .opaque(_, let innerOwner) = concrete {
            guard let u = opaqueUnderlyings[innerOwner] else {
                diags.error("cannot resolve the underlying type of this opaque value yet — declare the producing function before this use", at: span)
                return
            }
            concrete = u
        }
        guard case .named(let tn, _) = concrete else {
            if concrete != .error {
                diags.error("a 'some \(interfaces.joined(separator: " & "))' value must be a concrete type; got '\(v.type)'", at: span)
            }
            return
        }
        for i in interfaces where allConformsTo[tn]?.contains(i) != true {
            diags.error("type '\(tn)' does not conform to '\(i)', so it can't be returned as 'some \(interfaces.joined(separator: " & "))'", at: span)
        }
        if let existing = opaqueUnderlyings[owner], existing != concrete {
            diags.error("a 'some' type resolves to one concrete type — this also yields '\(existing)', not just '\(tn)'", at: span)
            return
        }
        opaqueUnderlyings[owner] = concrete
    }

    private mutating func recordComposite(_ typeName: String, _ kind: NamedKind, _ ifaces: [String]) {
        let key = "\(typeName):\(ifaces.joined(separator: "&"))"
        if compositePairs.insert(key).inserted {
            compositeList.append(NOIRComposite(typeName: typeName, typeKind: kind, interfaces: ifaces))
        }
    }

    // `expected` carries a contextual type inward (binding annotation, return
    // position, call-argument slot) so leading-dot `.case` construction can infer
    // its enum (M4.10). nil elsewhere; most expressions ignore it.
    private mutating func checkExpr(_ e: Expr, expected: Type? = nil) -> NOIRExpr {
        switch e {
        case .intLit(let v, let span):
            // An integer literal takes a `UInt8` context directly (`let b: UInt8 = 200`), with a
            // compile-time range check. Otherwise it is `Int`.
            if expected == .uint8 {
                if v < 0 || v > 255 {
                    diags.error("integer literal '\(v)' is out of range for UInt8 (0...255)", at: span)
                }
                return NOIRExpr(type: .uint8, span: span, kind: .intLit(v))
            }
            // A `UInt64` context takes a nonnegative literal directly. Literals are stored as a signed
            // 64-bit `Int`, so values in 2^63...2^64-1 are out of literal reach — build those with `~`
            // and shifts (e.g. `~UInt64(0)` for all-ones).
            if expected == .uint64 {
                if v < 0 {
                    diags.error("integer literal '\(v)' is out of range for UInt64 (must be nonnegative)", at: span)
                }
                return NOIRExpr(type: .uint64, span: span, kind: .intLit(v))
            }
            return NOIRExpr(type: .int,    span: span, kind: .intLit(v))
        case .doubleLit(let v, let span): return NOIRExpr(type: .double, span: span, kind: .doubleLit(v))
        case .boolLit(let v, let span):   return NOIRExpr(type: .bool,   span: span, kind: .boolLit(v))
        case .stringLit(let v, let span): return NOIRExpr(type: .string, span: span, kind: .stringLit(v))

        case .ident(let name, let span):
            if let t = lookup(name) {
                return NOIRExpr(type: t, span: span, kind: .varRef(name))
            }
            // Bare access to a property member of `self` — `p` means `self.p` (M5). Fires for
            // an interface default (self: interface, a property requirement) and for a computed
            // property on a concrete receiver; stored fields are already bound by name.
            if let selfTy = lookup("self"), bareMemberOfSelf(selfTy, name) {
                return checkExpr(.member(.ident("self", span: span), name, span: span))
            }
            if let sig = funcs[name] {
                return NOIRExpr(type: .function(params: sig.params, ret: sig.ret), span: span, kind: .varRef(name))
            }
            diags.error("undefined name '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .varRef(name))

        case .genericIdent(let name, _, let span):
            // Reached only when `Name<Args>` is used somewhere other than a construction or a
            // qualified enum case (those are intercepted by checkCall / the `.member` branch).
            diags.error("type arguments on '\(name)' are only valid when constructing it, e.g. '\(name)<...>(...)' or '\(name)<...>.case(...)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .varRef(name))

        case .member(let base, let field, let span):
            // Qualified no-payload enum construction: `EnumType.case` / `EnumType<Args>.case`.
            // (A payload case used bare falls through buildEnumInit as a wrong-arity error.)
            if let (typeName, explicit) = typeNameAndArgs(base), lookup(typeName) == nil, enums[typeName] != nil {
                return buildEnumInit(typeName, field, [], explicit: explicit, expected: expected, at: span)
            }
            // Pointer static properties (task 125): `RawPtr.null`, `Ptr<T>.null`.
            if let (tn, explicit) = typeNameAndArgs(base), lookup(tn) == nil, tn == "RawPtr" || tn == "Ptr" {
                return checkPointerStaticMember(tn, explicit, field, span)
            }
            let b = checkExpr(base)
            // Pointer instance properties (task 125): `p.isNull`.
            if case .rawPtr = b.type, field == "isNull" { return ptrIntrinsic("__ptrIsNull", .bool, [b], span) }
            if case .ptr = b.type, field == "isNull" { return ptrIntrinsic("__ptrIsNull", .bool, [b], span) }
            // Numeric conversions (M6 stdlib), property-style: `i.double` widens Int→Double;
            // `d.int` narrows Double→Int, rounding to nearest (ties away from zero). These are the
            // only Int/Double conversions — arithmetic never converts implicitly.
            if b.type == .int, field == "double" {
                return BuiltinsSema.member("__int_double_double", b, span)
            }
            if b.type == .double, field == "int" {
                return BuiltinsSema.member("__double_int_int", b, span)
            }
            // Byte conversions: `i.uint8` truncates Int→UInt8 (low 8 bits); `b.int` zero-extends
            // UInt8→Int (unsigned, always 0...255). These are the only Int/UInt8 conversions.
            if b.type == .int, field == "uint8" {
                return BuiltinsSema.member("__int_uint8_uint8", b, span)
            }
            if b.type == .uint8, field == "int" {
                return BuiltinsSema.member("__uint8_int_int", b, span)
            }
            // Word conversions: `i.uint64` reinterprets Int→UInt64 (same 64 bits); `u.int` reinterprets
            // back. `b.uint64` zero-extends UInt8→UInt64; `u.uint8` truncates UInt64→UInt8 (low 8 bits).
            if b.type == .int, field == "uint64" {
                return BuiltinsSema.member("__int_uint64_uint64", b, span)
            }
            if b.type == .uint64, field == "int" {
                return BuiltinsSema.member("__uint64_int_int", b, span)
            }
            if b.type == .uint8, field == "uint64" {
                return BuiltinsSema.member("__uint8_uint64_uint64", b, span)
            }
            if b.type == .uint64, field == "uint8" {
                return BuiltinsSema.member("__uint64_uint8_uint8", b, span)
            }

            // String property builtins (`str.hash`). Method builtins with arguments (`str.eq(x)`)
            // are handled in checkCall, since they parse with a call's argument list.
            if b.type == .string, field == "hash" {
                return BuiltinsSema.member("__string_hash_int", b, span)
            }
            // Array<T> builtin members (M6 stdlib). `count` is the element count; lowered to a builtin
            // call codegen recognizes by name (element type comes from the receiver's `.array` type).
            if case .array = b.type {
                switch field {
                case "count":
                    return BuiltinsSema.member("__array_count_int", b, span)
                default:
                    diags.error("value of type '\(b.type)' has no member '\(field)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
            }
            // A property-requirement read through `any I` / `any A & B` — via the getter slot.
            if let iface = existentialInterfaces(b.type).first(where: { aggregatedProperties($0).contains { $0.name == field } }),
               let prop = aggregatedProperties(iface).first(where: { $0.name == field }) {
                return NOIRExpr(type: resolve(prop.type), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read through `some I` — statically dispatched to the hidden
            // underlying (M5 A3). Emit the getter form uniformly; codegen resolves it to a direct
            // field load or a getter call once the underlying is known (so a forward reference to
            // a later-declared producer needs no underlying at check time). A `Self`-typed
            // property binds to the underlying when it is already resolved, else stays opaque.
            if case .opaque(let ifaces, let owner) = b.type,
               let iface = ifaces.first(where: { aggregatedProperties($0).contains { $0.name == field } }),
               let prop = aggregatedProperties(iface).first(where: { $0.name == field }) {
                let ty = resolve(prop.type, selfAs: opaqueUnderlyings[owner] ?? b.type)
                return NOIRExpr(type: ty, span: span, kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read through a bounded type parameter `T: I` — via the
            // bound's witness getter slot (M5 5.2.2).
            if case .typeParam(let t) = b.type,
               let iface = (genericBounds[t] ?? []).first(where: { aggregatedProperties($0).contains { $0.name == field } }),
               let prop = aggregatedProperties(iface).first(where: { $0.name == field }) {
                return NOIRExpr(type: resolve(prop.type, selfAs: b.type), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read inside an interface default (self: interface).
            if case .named(let tn, .interface_) = b.type,
               let prop = aggregatedProperties(tn).first(where: { $0.name == field }) {
                return NOIRExpr(type: resolve(prop.type), span: span, kind: .fieldAccess(base: b, field: field))
            }
            // A computed-property read lowers to a getter accessor call (M5 A1).
            if case .named(let tn, _) = b.type, let info = computedProps[tn]?[field] {
                return NOIRExpr(type: info.type, span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A computed-property read on an applied generic type `Box<Int>` (task 151): the getter's
            // declared type substitutes `T` to the concrete argument.
            if case .generic(let gbase, let gargs) = b.type, let info = computedProps[gbase]?[field] {
                return NOIRExpr(type: substitute(info.type, genericSubst(gbase, gargs)), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A field read on an applied generic type `Box<Int>` (M5 5.2.3): the field is stored
            // boxed; its declared `T` substitutes to the concrete argument for the result type.
            if case .generic(let gbase, let gargs) = b.type {
                let type = genericMemberType(gbase, gargs, field, at: span)
                return NOIRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))
            }
            let type = fieldType(of: b.type, field: field, at: span)
            return NOIRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))

        case .implicitMember(let name, let span):
            return buildImplicitEnum(name, [], expected: expected, at: span)

        case .binary(let op, let l, let r, let span):
            // A value op (arithmetic / bitwise / shift) produces its operand type, so an expected
            // type flows into both operands — `let b: UInt8 = 5 + 3` or `1 << 4` types its literals
            // as UInt8. A comparison yields Bool, so its context does not describe the operands.
            let operandExpected: Type? = isComparisonOp(op) ? nil : expected
            var lhs = checkExpr(l, expected: operandExpected)
            var rhs = checkExpr(r, expected: operandExpected)
            // A bare integer literal on one side of a UInt8 operation adopts the UInt8 type, so
            // `b + 1`, `b << 2`, `b & 240` need no conversion (arithmetic still never converts a
            // non-literal Int to UInt8).
            (lhs, rhs) = adoptUInt8Literal(op, lhs, rhs)
            let type = binaryResult(op, lhs, rhs, at: span)
            return NOIRExpr(type: type, span: span, kind: .binary(op, lhs, rhs))

        case .unary(let op, let operand, let span):
            // `-x` / `~x` produce the operand's type, so an expected type flows in (`let m: UInt8 =
            // ~0`); `!x` operates on Bool, so its context does not describe the operand.
            return checkUnary(op, operand, at: span, expected: op == .not ? nil : expected)

        case .call(let callee, let args, let span):
            return checkCall(callee: callee, args: args, span: span, expected: expected)

        case .closure(let params, let ret, let body, let span):
            let ps = params.map { NOIRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let retTy = resolve(ret)
            pushScope()
            for p in ps { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = retTy
            let savedLoop = loopDepth; loopDepth = 0   // `break`/`continue` can't cross into a closure
            let irBody = lowerBlock(body)
            loopDepth = savedLoop
            currentReturnType = saved
            popScope()
            let type = Type.function(params: ps.map(\.type), ret: retTy)
            return NOIRExpr(type: type, span: span, kind: .closure(params: ps, body: irBody))

        case .arrayLit(let elems, let span):
            // Element type: unify the elements' types, or take it from an `Array<T>` annotation on
            // the left (needed for an empty literal, which has nothing to infer from).
            var expectedElem: Type? = nil
            if case .array(let e)? = expected { expectedElem = e }
            let irElems = elems.map { checkExpr($0, expected: expectedElem) }
            var elemTy = expectedElem ?? irElems.first?.type
            if elemTy == nil {
                diags.error("cannot infer the element type of an empty array literal — add an annotation like 'Array<Int>'", at: span)
                elemTy = .error
            }
            // Every element must match the element type.
            for ir in irElems where ir.type != .error && ir.type != elemTy! {
                diags.error("array element has type '\(ir.type)', expected '\(elemTy!)'", at: ir.span)
            }
            return NOIRExpr(type: .array(elemTy!), span: span, kind: .arrayLit(elements: irElems))

        case .index(let base, let idx, let span):
            let irBase = checkExpr(base)
            let irIdx = checkExpr(idx, expected: .int)
            if irIdx.type != .int && irIdx.type != .error {
                diags.error("array index must be an 'Int', got '\(irIdx.type)'", at: irIdx.span)
            }
            guard case .array(let elem) = irBase.type else {
                if irBase.type != .error {
                    diags.error("cannot subscript a value of type '\(irBase.type)' — only 'Array<T>' supports '[ ]'", at: span)
                }
                return NOIRExpr(type: .error, span: span, kind: .index(base: irBase, idx: irIdx))
            }
            return NOIRExpr(type: elem, span: span, kind: .index(base: irBase, idx: irIdx))

        case .error(let span):
            // A parser error-recovery placeholder. The driver stops before Sema when the
            // parse sink holds errors, so this is unreachable in the normal flow; type it
            // `.error` (which suppresses further diagnostics) and emit no new diagnostic.
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // A call to a generic function (M5 5.2.2): infer each type parameter from the arguments,
    // check every inferred type satisfies the parameter's bounds (a witness must exist), and
    // record the inferred type arguments so codegen can pass the witnesses.
    private mutating func checkGenericCall(_ name: String, _ sig: FnSig, _ args: [NOIRArg], at span: Span) -> NOIRExpr {
        if args.count != sig.params.count {
            diags.error("function '\(name)' expects \(sig.params.count) argument(s), got \(args.count)", at: span)
        }
        // A type parameter nested in a generic-type *parameter* (`o: Option<T>`) used to be
        // rejected: witness-passing had to destructure an abstract container, which needs value
        // witnesses and miscompiled. Whole-program monomorphization (M5 5.4) specializes such a
        // function to a concrete copy (`Option<Int>`), so the abstract body never reaches codegen
        // — the restriction is lifted. Inference of `T` *through* the container is still shallow
        // (a `.none` argument can't pin `T`); that surfaces as the ordinary "cannot infer" error.
        var subst: [String: Type] = [:]
        for (p, a) in zip(sig.params, args) { unify(param: p, arg: a.value.type, into: &subst, at: span) }
        for g in sig.generics where subst[g.name] == nil {
            diags.error("cannot infer type parameter '\(g.name)' of '\(name)' from the arguments", at: span)
            subst[g.name] = .error
        }
        for g in sig.generics {
            let inferred = subst[g.name] ?? .error
            for b in g.bounds where inferred != .error && !typeConforms(inferred, to: b.name) {
                diags.error("type '\(inferred)' does not conform to '\(b.name)', required by type parameter '\(g.name)' of '\(name)'", at: span)
            }
            // Discharge a `<shared T>` bound: the inferred type argument must be shareable (M5 5.3.2).
            if g.isShared && inferred != .error && !isShareable(inferred) {
                diags.error("type '\(inferred)' is not shareable, but type parameter '\(g.name)' of '\(name)' is declared 'shared'", at: span)
            }
        }
        let typeArgs = sig.generics.map { subst[$0.name] ?? .error }
        let calleeType = Type.function(params: sig.params, ret: sig.ret)
        return NOIRExpr(type: substitute(sig.ret, subst), span: span,
                      kind: .call(callee: irVar(name, calleeType, span), args: args, typeArgs: typeArgs))
    }

    // Unify a (possibly type-parameter) parameter type against a concrete argument type,
    // binding type parameters in `subst` (M5 5.2.2). Shallow — enough for `T` and concrete
    // params; nested generic arguments extend this in a later slice.
    private mutating func unify(param: Type, arg: Type, into subst: inout [String: Type], at span: Span) {
        switch param {
        case .typeParam(let t):
            if let existing = subst[t] {
                if existing != arg && existing != .error && arg != .error {
                    diags.error("conflicting types inferred for '\(t)': '\(existing)' and '\(arg)'", at: span)
                }
            } else {
                subst[t] = arg
            }
        // Structural cases: recurse so a `T` nested in a closure (`(T) -> U`) or an applied
        // generic (`Option<T>`) is inferred from the argument's shape (M5 5.2.3).
        case .function(let pp, let pr):
            guard case .function(let ap, let ar) = arg, pp.count == ap.count else { return mismatch(param, arg, at: span) }
            for (p, a) in zip(pp, ap) { unify(param: p, arg: a, into: &subst, at: span) }
            unify(param: pr, arg: ar, into: &subst, at: span)
        case .generic(let pb, let pargs):
            guard case .generic(let ab, let aargs) = arg, pb == ab, pargs.count == aargs.count else { return mismatch(param, arg, at: span) }
            for (p, a) in zip(pargs, aargs) { unify(param: p, arg: a, into: &subst, at: span) }
        case .array(let pe):
            guard case .array(let ae) = arg else { return mismatch(param, arg, at: span) }
            unify(param: pe, arg: ae, into: &subst, at: span)
        default:
            if param != arg { mismatch(param, arg, at: span) }
        }
    }

    private mutating func mismatch(_ param: Type, _ arg: Type, at span: Span) {
        if param != .error && arg != .error {
            diags.error("argument of type '\(arg)' does not match expected '\(param)'", at: span)
        }
    }

    // Does a type parameter appear inside an applied generic type within `t` (e.g. `Option<T>`)?
    // Such a parameter would let a generic body build/destructure an abstract `T` — deferred to
    // value witnesses (M5). A type parameter under a *function* type is handled by a thunk.
    private func typeParamUnderGeneric(_ t: Type, _ tparams: Set<String>) -> Bool {
        switch t {
        case .generic(_, let a):      return a.contains { mentionsTypeParam($0, tparams) }
        case .array(let e):           return mentionsTypeParam(e, tparams)
        case .function(let p, let r): return p.contains { typeParamUnderGeneric($0, tparams) } || typeParamUnderGeneric(r, tparams)
        default:                      return false
        }
    }

    private func mentionsTypeParam(_ t: Type, _ tparams: Set<String>) -> Bool {
        switch t {
        case .typeParam(let n):        return tparams.contains(n)
        case .function(let p, let r):  return p.contains { mentionsTypeParam($0, tparams) } || mentionsTypeParam(r, tparams)
        case .generic(_, let a):       return a.contains { mentionsTypeParam($0, tparams) }
        case .array(let e):            return mentionsTypeParam(e, tparams)
        default:                       return false
        }
    }

    // Substitute inferred type parameters into a type (M5 5.2.2).
    private func substitute(_ t: Type, _ subst: [String: Type]) -> Type {
        switch t {
        case .typeParam(let n):        return subst[n] ?? t
        case .generic(let b, let a):   return .generic(base: b, args: a.map { substitute($0, subst) })
        case .array(let e):            return .array(substitute(e, subst))
        case .function(let p, let r):  return .function(params: p.map { substitute($0, subst) }, ret: substitute(r, subst))
        default:                        return t
        }
    }

    // Does a concrete type conform to an interface, with a witness available (M5 5.2.2)?
    // Bound satisfaction consults *all* checked conformances (incl. constraint-only), not just
    // the witnessed ones: a `<T: Cloneable>` / `<T: Combinable>` bound is discharged by mono, which
    // specializes to a concrete `T` — no witness required (M5 5.6).
    private func typeConforms(_ t: Type, to iface: String) -> Bool {
        if case .named(let tn, _) = t { return allConformsTo[tn]?.contains(iface) == true }
        return false
    }

    // MARK: - Generic types (M5 5.2.3)

    // A construction base that is a plain type name (`Type`) or a name carrying explicit type
    // arguments (`Type<Args>`, parsed as `.genericIdent`). The arguments are resolved in the
    // current generic scope so a `T` at the site binds to the enclosing function's parameter.
    private func typeNameAndArgs(_ e: Expr) -> (name: String, explicit: [Type]?)? {
        switch e {
        case .ident(let n, _):                   return (n, nil)
        case .genericIdent(let n, let refs, _):  return (n, refs.map { resolve($0) })
        default:                                 return nil
        }
    }

    // The type parameters and stored fields of a generic struct/class, or nil if `name` names
    // neither (a generic enum constructs through `buildEnumInit`).
    private func genericTypeShape(_ name: String) -> (generics: [GenericParam], fields: [VarField])? {
        if let s = structs[name] { return (s.generics, s.fields) }
        if let c = classes[name] { return (c.generics, c.fields) }
        return nil
    }

    // `Box(value: e)` — infer each type parameter by unifying the field's declared type
    // (a `T` resolves to `.typeParam`) against the argument, then bound-check (M5 5.2.3).
    private mutating func checkGenericConstruct(_ name: String, _ args: [Arg], explicit: [Type]? = nil, at span: Span) -> NOIRExpr {
        guard let shape = genericTypeShape(name) else {
            diags.error("generic enum '\(name)' is constructed through one of its cases, e.g. '\(name).case(...)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
        }
        let saved = genericScope; genericScope = Set(shape.generics.map(\.name)); defer { genericScope = saved }
        var subst: [String: Type] = [:]
        // Explicit type arguments (`Box<Int>(value: 3)`) seed inference; each field is then unified
        // against them, so a mismatch is reported as a conflict.
        if let explicit {
            if explicit.count != shape.generics.count {
                diags.error("generic type '\(name)' expects \(shape.generics.count) type argument(s), got \(explicit.count)", at: span)
            } else {
                for (p, a) in zip(shape.generics, explicit) { subst[p.name] = a }
            }
        }
        var irArgs: [NOIRArg] = []
        for f in shape.fields {
            let fieldTy = resolve(f.type)
            let expected: Type? = { if case .typeParam = fieldTy { return nil }; return fieldTy }()
            guard let arg = args.first(where: { $0.label == f.name }) else {
                diags.error("missing argument for field '\(f.name)'", at: span); continue
            }
            let v = checkExpr(arg.value, expected: expected)
            unify(param: fieldTy, arg: v.type, into: &subst, at: span)
            irArgs.append(NOIRArg(label: f.name, value: v))
        }
        let typeArgs = inferredTypeArgs(shape.generics, subst, owner: name, at: span)
        return NOIRExpr(type: .generic(base: name, args: typeArgs), span: span,
                      kind: .construct(typeName: name, args: irArgs))
    }

    // Finish inference for a generic decl: every parameter must be bound, and each inferred
    // type must satisfy the parameter's bounds (a witness must exist). Shared by generic
    // struct construction and generic enum construction (M5 5.2.3).
    private mutating func inferredTypeArgs(_ generics: [GenericParam], _ subst: [String: Type],
                                           owner: String, at span: Span) -> [Type] {
        var subst = subst
        for g in generics where subst[g.name] == nil {
            diags.error("cannot infer type parameter '\(g.name)' of '\(owner)' — add a type annotation", at: span)
            subst[g.name] = .error
        }
        for g in generics {
            let inferred = subst[g.name] ?? .error
            for b in g.bounds where inferred != .error && !typeConforms(inferred, to: b.name) {
                diags.error("type '\(inferred)' does not conform to '\(b.name)', required by type parameter '\(g.name)' of '\(owner)'", at: span)
            }
        }
        return generics.map { subst[$0.name] ?? .error }
    }

    // A field read on `Box<Int>`: resolve the field's declared type with the type's parameters
    // in scope, then substitute the applied arguments to get the concrete result type (M5 5.2.3).
    private func genericParamsOf(_ base: String) -> [GenericParam] {
        structs[base]?.generics ?? enums[base]?.generics ?? classes[base]?.generics ?? []
    }

    // The substitution binding a generic type's own parameters to an instantiation's arguments
    // (`Box<Int>` → `[T: Int]`).
    private func genericSubst(_ base: String, _ args: [Type]) -> [String: Type] {
        var subst: [String: Type] = [:]
        for (p, a) in zip(genericParamsOf(base), args) { subst[p.name] = a }
        return subst
    }

    // A generic type's method signature at an instantiation `Base<args>`: each param/return type is
    // resolved with the type's own generic params in scope (so a bare `T` becomes `.typeParam`), then
    // substituted to the concrete arguments. Mirrors `genericMemberType` for fields (task 151).
    private mutating func genericMethodSig(_ base: String, _ args: [Type], _ m: FuncDecl) -> (params: [Type], ret: Type) {
        let gens = genericParamsOf(base)
        let saved = genericScope; genericScope = Set(gens.map(\.name)); defer { genericScope = saved }
        let subst = genericSubst(base, args)
        return (m.params.map { substitute(resolve($0.type), subst) }, substitute(resolve(m.returnType), subst))
    }

    private mutating func genericMemberType(_ base: String, _ args: [Type], _ field: String, at span: Span) -> Type {
        guard let shape = genericTypeShape(base), let f = shape.fields.first(where: { $0.name == field }) else {
            diags.error("type '\(base)' has no field '\(field)'", at: span)
            return .error
        }
        let saved = genericScope; genericScope = Set(shape.generics.map(\.name)); defer { genericScope = saved }
        var subst: [String: Type] = [:]
        for (p, a) in zip(shape.generics, args) { subst[p.name] = a }
        return substitute(resolve(f.type), subst)
    }

    // Unsafe raw-memory surface (task 125). Element types are limited to the single-word scalars a
    // plain addrspace(0) load/store can move; aggregates are out of the minimal floor.
    private func isRawScalar(_ t: Type) -> Bool {
        switch t {
        case .int, .uint8, .uint64, .double, .bool, .rawPtr, .ptr: return true
        default: return false
        }
    }

    // Validate a builtin call's argument labels against a fixed expected list (nil = an unlabeled
    // positional argument). The pointer surface spells its offsets/counts explicitly (`toByteOffset:`,
    // `by:`), so the labels are required, matching the design.
    private mutating func checkArgLabels(_ args: [Arg], _ expected: [String?], _ ctx: String, _ span: Span) -> Bool {
        guard args.count == expected.count else {
            let sig = expected.map { $0.map { "\($0):" } ?? "_" }.joined(separator: ", ")
            diags.error("\(ctx) expects \(expected.count) argument(s) (\(sig)), got \(args.count)", at: span)
            return false
        }
        var ok = true
        for (a, want) in zip(args, expected) where a.label != want {
            let wantDesc = want.map { "label '\($0):'" } ?? "no label"
            let gotDesc = a.label.map { "'\($0):'" } ?? "no label"
            diags.error("\(ctx): expected \(wantDesc), got \(gotDesc)", at: span)
            ok = false
        }
        return ok
    }

    // Check an `Int`-typed argument of a pointer builtin, enforcing the type as the virtual signature
    // demands (a byte offset / count / alignment). `coerce(_, to: .int)` is a no-op, so this is what
    // actually rejects a non-Int argument.
    private mutating func intArg(_ e: Expr, _ ctx: String, _ what: String) -> NOIRExpr {
        let v = checkExpr(e, expected: .int)
        if v.type != .int, v.type != .error {
            diags.error("\(ctx): \(what) must be an 'Int', got '\(v.type)'", at: v.span)
        }
        return v
    }

    // Build a NOIR call to a codegen intrinsic (`__rawAlloc` etc.); the result type is carried on the
    // node so codegen reads the element type from it (e.g. a typed load).
    private func ptrIntrinsic(_ name: String, _ result: Type, _ args: [NOIRExpr], _ span: Span) -> NOIRExpr {
        let callee = NOIRExpr(type: .void, span: span, kind: .varRef(name))
        return NOIRExpr(type: result, span: span,
                        kind: .call(callee: callee, args: args.map { NOIRArg(label: nil, value: $0) }, typeArgs: []))
    }

    // Pointer static properties: `RawPtr.null` / `Ptr<T>.null` — a null address of the named type.
    private mutating func checkPointerStaticMember(_ tn: String, _ explicit: [Type]?, _ field: String, _ span: Span) -> NOIRExpr {
        guard field == "null" else {
            let ty = tn == "Ptr" ? "Ptr<T>" : tn
            diags.error("type '\(ty)' has no static property '\(field)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        if tn == "RawPtr" { return ptrIntrinsic("__ptrNull", .rawPtr, [], span) }
        guard let elems = explicit, elems.count == 1 else {
            diags.error("'Ptr' needs one type argument, e.g. 'Ptr<Int>.null'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        return ptrIntrinsic("__ptrNull", .ptr(elems[0]), [], span)
    }

    private mutating func checkRawPtrStatic(_ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(args, ["bytes", "align"], "RawPtr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let bytes = intArg(args[0].value, "RawPtr.alloc", "bytes")
            let align = intArg(args[1].value, "RawPtr.alloc", "align")
            return ptrIntrinsic("__rawAlloc", .rawPtr, [bytes, align], span)
        // GC type-table reads (task 150 rung 2). Reach the codegen-emitted per-type-id side tables
        // (`c-types.md` §1/§3.2) from Nomu: each lowers to a call to the existing runtime accessor. All
        // are gc-leaf pure reads — no managed heap, no alloc — so the Nomu tracer reads its object model
        // through the same tables the MMTk binding reads.
        case "gcTypeCount":
            guard checkArgLabels(args, [], "RawPtr.gcTypeCount", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcTypeCount", .int, [], span)
        case "gcTypeSize", "gcTypeKind", "gcTypeStride", "gcTypeNumPtrs":
            guard checkArgLabels(args, [nil], "RawPtr.\(method)", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(args[0].value, "RawPtr.\(method)", "id")
            let intr = "__" + method   // __gcTypeSize / __gcTypeKind / __gcTypeStride / __gcTypeNumPtrs
            return ptrIntrinsic(intr, .int, [id], span)
        case "gcTypePtrOffset":
            guard checkArgLabels(args, [nil, nil], "RawPtr.gcTypePtrOffset", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(args[0].value, "RawPtr.gcTypePtrOffset", "id")
            let i = intArg(args[1].value, "RawPtr.gcTypePtrOffset", "i")
            return ptrIntrinsic("__gcTypePtrOffset", .int, [id, i], span)
        // The `__llvm_stackmaps` section (task 150 rung 2, the pcsp root walk): base address + byte size,
        // reached through the linker-provided section-bracket symbols (no libc, no new runtime C). The Nomu
        // pcsp walk parses this section (return-address → SP-relative root slots + per-function frame size).
        case "gcStackmapBase":
            guard checkArgLabels(args, [], "RawPtr.gcStackmapBase", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcStackmapBase", .rawPtr, [], span)
        case "gcStackmapSize":
            guard checkArgLabels(args, [], "RawPtr.gcStackmapSize", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcStackmapSize", .int, [], span)
        // Stack-walk anchors (task 150 rung 2, pcsp walk): the caller frame's frame pointer (as a RawPtr)
        // and the return address into the caller (as an Int) — `llvm.frameaddress`/`llvm.returnaddress`.
        // From these the pcsp walk derives each frame's SP and steps by the stackmap's per-function size.
        case "gcFrameAddr":
            guard checkArgLabels(args, [], "RawPtr.gcFrameAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcFrameAddr", .rawPtr, [], span)
        case "gcReturnAddr":
            guard checkArgLabels(args, [], "RawPtr.gcReturnAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcReturnAddr", .int, [], span)
        // Force one collection at a clean program point (task 150 rung 2, mark-verify oracle): drive a
        // deterministic GC so MMTk emits its live-set fingerprint (`MMTK-FP`, under NOMU_GC_MARKVERIFY),
        // the independent oracle the self-hosted Nomu tracer's fingerprint is diffed against.
        case "gcForceCollect":
            guard checkArgLabels(args, [], "RawPtr.gcForceCollect", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcForceCollect", .void, [], span)
        // Task 128.3.1 (parked-fiber root scan): fetch each parked fiber's saved frame-pointer anchor from
        // the C fiber registry into `outBuf` (up to `cap` words), returning the count. The self-hosted walk
        // (`rtScanParkedFibers`) chains past the C park frames from each anchor and runs the pcsp walk.
        case "gcParkedAnchors":
            guard checkArgLabels(args, [nil, nil], "RawPtr.gcParkedAnchors", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let outBuf = checkExpr(args[0].value)
            if outBuf.type != .error, outBuf.type != .rawPtr {
                diags.error("RawPtr.gcParkedAnchors expects a RawPtr buffer, got '\(outBuf.type)'", at: outBuf.span)
            }
            let cap = intArg(args[1].value, "RawPtr.gcParkedAnchors", "cap")
            return ptrIntrinsic("__gcParkedAnchors", .int, [outBuf, cap], span)
        // Task 128.3.1 (scheduler root): read the global scheduled-mailbox queue head (`rt_sched_head`), a
        // single managed GC root that keeps every queued mailbox's pending work alive. Returns its value as a
        // RawPtr (null when the queue is empty). The self-hosted scan (`rtScanSchedRoot`) reports it as a root.
        case "gcSchedHead":
            guard checkArgLabels(args, [], "RawPtr.gcSchedHead", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcSchedHead", .rawPtr, [], span)
        // The self-hosted Immix space descriptor (task 150 rung 3): the codegen-internal global
        // `__nomu_selfhost_space` the alloc seam lazily creates under NOMU_GC_PLAN=nomu. Null under other
        // plans (MMTk allocates). The self-hosted tracer reads it to mark lines in the space objects live in.
        case "gcSelfhostSpace":
            guard checkArgLabels(args, [], "RawPtr.gcSelfhostSpace", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__gcSelfhostSpace", .rawPtr, [], span)
        default:
            diags.error("type 'RawPtr' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    private mutating func checkRawPtrMethod(_ recv: NOIRExpr, _ name: String, _ args: [Arg], _ span: Span, expected: Type?) -> NOIRExpr {
        switch name {
        case "free":
            guard checkArgLabels(args, [], "RawPtr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__rawFree", .void, [recv], span)
        case "advanced":
            guard checkArgLabels(args, ["by"], "RawPtr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(args[0].value, "RawPtr.advanced", "by")
            return ptrIntrinsic("__rawAdvanced", .rawPtr, [recv, by], span)
        case "store":
            guard checkArgLabels(args, [nil, "toByteOffset"], "RawPtr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = checkExpr(args[0].value)
            if value.type != .error, !isRawScalar(value.type) {
                diags.error("RawPtr.store supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(value.type)'", at: value.span)
            }
            let off = intArg(args[1].value, "RawPtr.store", "toByteOffset")
            return ptrIntrinsic("__rawStore", .void, [recv, value, off], span)
        case "load":
            guard checkArgLabels(args, ["fromByteOffset"], "RawPtr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard let elem = expected, isRawScalar(elem) else {
                diags.error("cannot infer the element type of 'RawPtr.load' — annotate the result with a scalar type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let off = intArg(args[0].value, "RawPtr.load", "fromByteOffset")
            return ptrIntrinsic("__rawLoad", elem, [recv, off], span)
        case "eq":
            guard checkArgLabels(args, [nil], "RawPtr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = checkExpr(args[0].value)
            if other.type != .rawPtr, other.type != .error {
                diags.error("RawPtr.eq expects a 'RawPtr' argument, got '\(other.type)'", at: other.span)
            }
            return ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        // The pointer's numeric address as an Int (ptrtoint), for addr→index math over raw memory (the
        // Immix side tables, task 150 rung 3): `(addr − heapBase) / lineSize`. Sound on addrspace(0) raw
        // memory the collector owns off-heap.
        case "toInt":
            guard checkArgLabels(args, [], "RawPtr.toInt", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__rawToInt", .int, [recv], span)
        case "asPtr":
            guard checkArgLabels(args, [], "RawPtr.asPtr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .ptr = (expected ?? .error) else {
                diags.error("cannot infer the target type of 'RawPtr.asPtr' — annotate the result as 'Ptr<T>'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__rawAsPtr", expected!, [recv], span)
        default:
            diags.error("value of type 'RawPtr' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    private mutating func checkPtrStatic(_ elem: Type, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(args, ["count"], "Ptr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            if elem != .error, !isRawScalar(elem) {
                diags.error("Ptr<T>.alloc requires a scalar element type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(elem)'", at: span)
            }
            let count = intArg(args[0].value, "Ptr.alloc", "count")
            return ptrIntrinsic("__ptrAlloc", .ptr(elem), [count], span)
        default:
            diags.error("type 'Ptr<\(elem)>' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    private mutating func checkPtrMethod(_ recv: NOIRExpr, _ elem: Type, _ name: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        if elem != .error, !isRawScalar(elem) {
            diags.error("Ptr<\(elem)> supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        switch name {
        case "load":
            guard checkArgLabels(args, ["at"], "Ptr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let at = intArg(args[0].value, "Ptr.load", "at")
            return ptrIntrinsic("__ptrLoad", elem, [recv, at], span)
        case "store":
            guard checkArgLabels(args, [nil, "at"], "Ptr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = coerce(checkExpr(args[0].value, expected: elem), to: elem)
            checkAssignable(value.type, to: elem, role: "argument", at: value.span)
            let at = intArg(args[1].value, "Ptr.store", "at")
            return ptrIntrinsic("__ptrStore", .void, [recv, value, at], span)
        case "advanced":
            guard checkArgLabels(args, ["by"], "Ptr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(args[0].value, "Ptr.advanced", "by")
            return ptrIntrinsic("__ptrAdvanced", .ptr(elem), [recv, by], span)
        case "asRaw":
            guard checkArgLabels(args, [], "Ptr.asRaw", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__ptrAsRaw", .rawPtr, [recv], span)
        case "free":
            guard checkArgLabels(args, [], "Ptr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return ptrIntrinsic("__rawFree", .void, [recv], span)   // same addrspace(0) word as RawPtr.free
        case "eq":
            guard checkArgLabels(args, [nil], "Ptr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = checkExpr(args[0].value)
            if other.type != .ptr(elem), other.type != .error {
                diags.error("Ptr<\(elem)>.eq expects a 'Ptr<\(elem)>' argument, got '\(other.type)'", at: other.span)
            }
            return ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        default:
            diags.error("value of type 'Ptr<\(elem)>' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // Task 149 — the runtime-subset check (design: runtime-subset.md §4, the call-graph closure). A
    // function designated runtime-subset may not do the things it would otherwise implement: trigger an
    // implicit GC allocation (a heap construct — class/actor, closure, `any`-box, array — or a `spawn`),
    // or call a function that is not itself subset or an allowlisted primitive. The allowlist is the 125
    // raw-memory intrinsics (gc-leaf, no managed heap) plus pure non-allocating leaves. Runs over the
    // final NOIR module (pre-mono), where callees carry source names. The codegen-site guards (barrier /
    // safepoint suppression) are a later slice; this catches the alloc + call recursion the allocator
    // must avoid.
    private func checkRuntimeSubset(_ module: NOIRModule) {
        guard !subsetFuncs.isEmpty else { return }
        for decl in module.decls {
            guard case .funcDecl(let f) = decl, subsetFuncs.contains(f.name) else { continue }
            for s in f.body { subsetWalkStmt(s, inFn: f.name) }
        }
    }

    // A callee a subset function may reach: the 125 primitives and pure non-allocating leaves.
    private func subsetAllows(_ name: String) -> Bool {
        if name.hasPrefix("__raw") || name.hasPrefix("__ptr") { return true }   // 125 raw memory (gc-leaf)
        if name.hasPrefix("__gc") { return true }                               // GC introspection reads (gc-leaf, task 150 rung 2)
        if Builtins.cLeaf.contains(name) { return true }                        // pure C leaves
        switch name {
        case "__int_double_double", "__double_int_int", "__int_uint8_uint8", "__uint8_int_int": return true
        default: return subsetFuncs.contains(name)                              // another subset function
        }
    }

    private func subsetWalkStmt(_ s: NOIRStmt, inFn: String) {
        switch s.kind {
        case .letBinding(_, _, let v): subsetWalkExpr(v, inFn: inFn)
        case .spawnLet(_, let v, _):
            diags.error("runtime-subset function '\(inFn)' may not 'spawn' — it allocates a task", at: s.span)
            subsetWalkExpr(v, inFn: inFn)
        case .assign(let t, let v), .compoundAssign(let t, let v):
            subsetWalkExpr(t, inFn: inFn); subsetWalkExpr(v, inFn: inFn)
        case .ret(let e): if let e { subsetWalkExpr(e, inFn: inFn) }
        case .ifStmt(let c, let th, let el):
            subsetWalkExpr(c, inFn: inFn)
            th.forEach { subsetWalkStmt($0, inFn: inFn) }
            (el ?? []).forEach { subsetWalkStmt($0, inFn: inFn) }
        case .whileStmt(let c, let body):
            subsetWalkExpr(c, inFn: inFn)
            body.forEach { subsetWalkStmt($0, inFn: inFn) }
        case .switchStmt(let sw):
            subsetWalkExpr(sw.subject, inFn: inFn)
            for arm in sw.arms { arm.body.forEach { subsetWalkStmt($0, inFn: inFn) } }
        case .exprStmt(let e): subsetWalkExpr(e, inFn: inFn)
        case .breakStmt, .continueStmt: break
        }
    }

    private func subsetWalkExpr(_ e: NOIRExpr, inFn: String) {
        switch e.kind {
        case .construct(let typeName, let args):
            if let k = kindOf(typeName), k == .class_ || k == .actor_ {
                diags.error("runtime-subset function '\(inFn)' may not allocate a '\(typeName)' — heap allocation is forbidden in runtime-subset code", at: e.span)
            }
            args.forEach { subsetWalkExpr($0.value, inFn: inFn) }
        case .closure:
            diags.error("runtime-subset function '\(inFn)' may not create a closure — it is heap-boxed", at: e.span)
        case .box(let v, _):
            diags.error("runtime-subset function '\(inFn)' may not box a value as 'any' — heap allocation", at: e.span)
            subsetWalkExpr(v, inFn: inFn)
        case .arrayLit(let elems):
            diags.error("runtime-subset function '\(inFn)' may not build an array — heap allocation", at: e.span)
            elems.forEach { subsetWalkExpr($0, inFn: inFn) }
        case .call(let callee, let args, _):
            if case .varRef(let name) = callee.kind, !subsetAllows(name) {
                diags.error("runtime-subset function '\(inFn)' may not call '\(name)' — only other runtime-subset functions and the raw-memory primitives are allowed", at: e.span)
            }
            args.forEach { subsetWalkExpr($0.value, inFn: inFn) }
        case .methodCall(let recv, _, let margs):
            subsetWalkExpr(recv, inFn: inFn); margs.forEach { subsetWalkExpr($0, inFn: inFn) }
        case .binary(_, let l, let r): subsetWalkExpr(l, inFn: inFn); subsetWalkExpr(r, inFn: inFn)
        case .fieldAccess(let base, _): subsetWalkExpr(base, inFn: inFn)
        case .index(let base, let idx): subsetWalkExpr(base, inFn: inFn); subsetWalkExpr(idx, inFn: inFn)
        case .enumInit(_, _, let args): args.forEach { subsetWalkExpr($0.value, inFn: inFn) }
        default: break   // literals, varRef, and other leaves carry no allocation or call
        }
    }

    private mutating func checkCall(callee: Expr, args: [Arg], span: Span, expected: Type? = nil) -> NOIRExpr {
        // Qualified enum construction: `EnumType.case(args)` or `EnumType<Args>.case(args)`. A
        // `static fun` of the same enum takes precedence over case construction for that name.
        if case .member(let base, let caseName, _) = callee,
           let (typeName, explicit) = typeNameAndArgs(base), lookup(typeName) == nil, enums[typeName] != nil,
           staticMethodDecl(typeName, .enum_, caseName) == nil {
            return buildEnumInit(typeName, caseName, args, explicit: explicit, expected: expected, at: span)
        }
        // Pointer static constructors (task 125): `RawPtr.alloc(...)`, `Ptr<T>.alloc(...)`.
        if case .member(let base, let method, _) = callee,
           let (tn, explicit) = typeNameAndArgs(base), lookup(tn) == nil {
            if tn == "RawPtr" { return checkRawPtrStatic(method, args, span) }
            if tn == "Ptr" {
                guard let elems = explicit, elems.count == 1 else {
                    diags.error("'Ptr' needs one type argument, e.g. 'Ptr<Int>.\(method)(...)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                return checkPtrStatic(elems[0], method, args, span)
            }
        }
        // Static method: `Type.method(args)` — a type-associated function with no receiver. Only
        // for a non-generic user type (generic types reject members entirely, so no static free
        // function is ever emitted for them); the call lowers to a direct call of `Type.method`.
        if case .member(let base, let name, _) = callee,
           let (tn, explicit) = typeNameAndArgs(base), lookup(tn) == nil,
           let k = kindOf(tn), let m = staticMethodDecl(tn, k, name) {
            // A generic type's static method: `Box<Int>.make(...)`. The signature substitutes the
            // explicit type args, and they ride on the call so monomorphization specializes the
            // static free function per instantiation (task 151). Inference of the args from the
            // value arguments is not done yet — the args are required explicitly.
            if let arity = genericArity(tn) {
                guard let targs = explicit, targs.count == arity else {
                    diags.error("static method '\(tn).\(name)' on a generic type needs explicit type arguments, e.g. '\(tn)<…>.\(name)(…)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                let (paramTypes, ret) = genericMethodSig(tn, targs, m)
                let irArgs = checkArgs(args, expectedParams: paramTypes)
                checkArgTypes(irArgs.map(\.value), against: paramTypes, at: span)
                let calleeType = Type.function(params: paramTypes, ret: ret)
                return NOIRExpr(type: ret, span: span,
                              kind: .call(callee: irVar("\(tn).\(name)", calleeType, span), args: irArgs, typeArgs: targs))
            }
            let paramTypes = m.params.map { resolve($0.type) }
            let irArgs = checkArgs(args, expectedParams: paramTypes)
            checkArgTypes(irArgs.map(\.value), against: paramTypes, at: span)
            let ret = resolve(m.returnType)
            let calleeType = Type.function(params: paramTypes, ret: ret)
            return NOIRExpr(type: ret, span: span,
                          kind: .call(callee: irVar("\(tn).\(name)", calleeType, span), args: irArgs, typeArgs: []))
        }
        // `Type.member(...)` on a user type that is not a static method: a targeted diagnostic
        // instead of falling through to "undefined name 'Type'" (the type name is not a value).
        if case .member(let base, let name, _) = callee,
           let (tn, _) = typeNameAndArgs(base), lookup(tn) == nil, genericArity(tn) == nil,
           let k = kindOf(tn), k != .enum_ {
            if methodDecl(tn, k, name) != nil {
                diags.error("'\(name)' is an instance method of '\(tn)'; call it on a value, not on the type", at: span)
            } else {
                diags.error("type '\(tn)' has no static method '\(name)'", at: span)
            }
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        // Leading-dot enum construction: `.case(args)` — enum inferred from context.
        if case .implicitMember(let caseName, _) = callee {
            return buildImplicitEnum(caseName, args, expected: expected, at: span)
        }
        // Member call: base.member(args) — an actor send or an instance method.
        if case .member(let base, let name, _) = callee {
            let recv = checkExpr(base)
            // Array<T> builtin methods (M6 stdlib). `append(x)` grows the array; lowered to a builtin
            // call codegen recognizes (element type from the receiver's `.array` type).
            if case .array(let elem) = recv.type {
                switch name {
                case "append":
                    guard args.count == 1 else {
                        diags.error("Array.append expects 1 argument, got \(args.count)", at: span)
                        return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                    }
                    let value = coerce(checkExpr(args[0].value, expected: elem), to: elem)
                    checkAssignable(value.type, to: elem, role: "argument", at: span)
                    let ac = NOIRExpr(type: .void, span: span, kind: .varRef("__arrayAppend"))
                    return NOIRExpr(type: .void, span: span, kind: .call(callee: ac,
                        args: [NOIRArg(label: nil, value: recv), NOIRArg(label: nil, value: value)], typeArgs: []))
                default:
                    diags.error("value of type '\(recv.type)' has no method '\(name)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
            }
            // RawPtr instance methods (task 125): free / advanced / store / load / asPtr.
            if case .rawPtr = recv.type {
                return checkRawPtrMethod(recv, name, args, span, expected: expected)
            }
            // Ptr<T> instance methods (task 125): load / store / advanced / asRaw. T is fixed by the
            // receiver, so load/store need no annotation (unlike RawPtr).
            if case .ptr(let elem) = recv.type {
                return checkPtrMethod(recv, elem, name, args, span)
            }
            // String method builtins. `eq(other)` is byte equality (there is no `==` on String yet).
            if recv.type == .string {
                switch name {
                case "eq":
                    guard args.count == 1 else {
                        diags.error("String.eq expects 1 argument, got \(args.count)", at: span)
                        return NOIRExpr(type: .error, span: span, kind: .boolLit(false))
                    }
                    let rhs = checkExpr(args[0].value)
                    if rhs.type != .string && rhs.type != .error {
                        diags.error("String.eq expects a String argument, got '\(rhs.type)'", at: rhs.span)
                    }
                    return BuiltinsSema.method("__string_eq_bool_string", recv, [rhs], span)
                default:
                    diags.error("value of type 'String' has no method '\(name)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .boolLit(false))
                }
            }
            // A method-requirement call through `any I` / `any A & B` — dispatched via the
            // witness slot (including requirements inherited by refinement, M5 A1.5).
            if let iface = existentialInterfaces(recv.type).first(where: { aggregatedMethods($0).contains { $0.name == name } }),
               let req = aggregatedMethods(iface).first(where: { $0.name == name }) {
                let irArgs = args.map { checkExpr($0.value) }
                // Covariant `Self` erases to the receiver's own existential type: `c.clone()` on
                // `any B` yields `any B` (M5 5.6). Params are `Self`-free here (a contravariant
                // `Self` would have made the interface non-existential-legal).
                checkArgTypes(irArgs, against: req.params.map { resolve($0.type, selfAs: recv.type) }, at: span)
                return NOIRExpr(type: resolve(req.returnType, selfAs: recv.type), span: span,
                              kind: .methodCall(receiver: recv, method: name, args: irArgs))
            }
            // A method-requirement call through `some I` — statically dispatched to the hidden
            // underlying (M5 A3). `Self` binds to the underlying concrete type (chosen: the
            // caller gets the concrete type back), falling back to the opaque type itself if the
            // underlying isn't resolved yet (a forward reference to a later-declared producer).
            if case .opaque(let ifaces, let owner) = recv.type,
               let iface = ifaces.first(where: { aggregatedMethods($0).contains { $0.name == name } }),
               let req = aggregatedMethods(iface).first(where: { $0.name == name }) {
                let irArgs = args.map { checkExpr($0.value) }
                let selfBind = opaqueUnderlyings[owner] ?? recv.type
                checkArgTypes(irArgs, against: req.params.map { resolve($0.type, selfAs: selfBind) }, at: span)
                return NOIRExpr(type: resolve(req.returnType, selfAs: selfBind), span: span,
                              kind: .methodCall(receiver: recv, method: name, args: irArgs))
            }
            // A requirement call through a bounded type parameter `T: I` — dispatched via the
            // witness passed for that bound (M5 5.2.2). `Self` binds to `T`.
            if case .typeParam(let t) = recv.type,
               let iface = (genericBounds[t] ?? []).first(where: { aggregatedMethods($0).contains { $0.name == name } }),
               let req = aggregatedMethods(iface).first(where: { $0.name == name }) {
                let irArgs = args.map { checkExpr($0.value) }
                checkArgTypes(irArgs, against: req.params.map { resolve($0.type, selfAs: recv.type) }, at: span)
                return NOIRExpr(type: resolve(req.returnType, selfAs: recv.type), span: span,
                              kind: .methodCall(receiver: recv, method: name, args: irArgs))
            }
            // Instance method on an applied generic type `Box<Int>` (task 151): resolve the method on
            // the template and substitute the instantiation's type args into its signature. The
            // `.methodCall` rides through, and monomorphization specializes the body per instantiation.
            if case .generic(let gbase, let gargs) = recv.type,
               let gkind = kindOf(gbase),
               let method = methodDecl(gbase, gkind, name) {
                let (paramTypes, ret) = genericMethodSig(gbase, gargs, method)
                let irArgs = args.map { checkExpr($0.value) }
                checkArgTypes(irArgs, against: paramTypes, at: span)
                if gkind != .class_ {
                    methodCallSites.append(CallSite(callee: "\(gbase).\(name)",
                                                    receiverMutable: isMutableReceiver(base), span: span))
                }
                return NOIRExpr(type: ret, span: span, kind: .methodCall(receiver: recv, method: name, args: irArgs))
            }
            if case .named(let typeName, let kind) = recv.type {
                // Actor send: base.handler(args).
                if kind == .actor_, let handler = actors[typeName]?.handlers.first(where: { $0.name == name }) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: handler.params.map { resolve($0.type) }, at: span)
                    return NOIRExpr(type: resolve(handler.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // Requirement call inside an interface default (self: interface). `Self` in the
                // requirement binds to the receiver's type (M5 A2).
                if kind == .interface_, let req = interfaceMethod(typeName, name) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: req.params.map { resolve($0.type, selfAs: recv.type) }, at: span)
                    return NOIRExpr(type: resolve(req.returnType, selfAs: recv.type), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // Instance method on a struct/enum/class value.
                if let method = methodDecl(typeName, kind, name) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: method.params.map { resolve($0.type) }, at: span)
                    // Value types (struct/enum) get the mutating-receiver check; classes are
                    // reference types, so a mutating method is callable on any binding.
                    if kind != .class_ {
                        methodCallSites.append(CallSite(callee: "\(typeName).\(name)",
                                                        receiverMutable: isMutableReceiver(base), span: span))
                    }
                    return NOIRExpr(type: resolve(method.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // A default requirement this type inherits (synthesized as a concrete method).
                // `Self` in the requirement binds to the concrete receiver type (M5 A2).
                if let req = (inheritedDefaults[typeName] ?? []).first(where: { $0.name == name }) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: req.params.map { resolve($0.type, selfAs: recv.type) }, at: span)
                    return NOIRExpr(type: resolve(req.returnType, selfAs: recv.type), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
            }
            if recv.type != .error {
                diags.error("value of type '\(recv.type)' has no method '\(name)'", at: span)
            }
            return NOIRExpr(type: .error, span: span, kind: .methodCall(receiver: recv, method: name,
                                                                       args: args.map { checkExpr($0.value) }))
        }

        if case .ident(let name, _) = callee {
            // print — accepts zero or one arg of any printable type.
            if name == "print" {
                let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr($0.value)) }
                return NOIRExpr(type: .void, span: span, kind: .call(callee: irVar(name, .void, span), args: irArgs, typeArgs: []))
            }

            // putByte(b: UInt8) — write one raw byte to stdout (libc-buffered, flushed at exit).
            // The low-level output primitive a string type builds its printing on.
            if name == "putByte" {
                guard args.count == 1 else {
                    diags.error("putByte expects one argument (a UInt8)", at: span)
                    return NOIRExpr(type: .void, span: span, kind: .intLit(0))
                }
                let a = checkExpr(args[0].value, expected: .uint8)
                if a.type != .uint8, a.type != .error {
                    diags.error("putByte expects a UInt8, got '\(a.type)'", at: a.span)
                }
                return NOIRExpr(type: .void, span: span, kind: .call(callee: irVar(name, .void, span), args: [NOIRArg(label: nil, value: a)], typeArgs: []))
            }

            if name == "time_monotonic" {
                return NOIRExpr(type: .int, span: span, kind: .call(callee: irVar("__void_timemonotonic_int", .int, span), args: [], typeArgs:[]))
            }
            // addrOf(obj) — the raw address of a heap (reference-type) object as a RawPtr (task 150 rung 2).
            // A GC-internal seed for the mark-verify tracer: it hands the Nomu tracer a root to walk from.
            // Valid only on a non-moving heap (rung 2 NoGC); a moving collector would invalidate the alias.
            if name == "addrOf" {
                guard args.count == 1 else {
                    diags.error("addrOf expects one argument (a heap object)", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                let a = checkExpr(args[0].value)
                if a.type != .error, !isReferenceType(a.type) {
                    diags.error("addrOf expects a heap (reference-type) object, got '\(a.type)'", at: span)
                }
                return ptrIntrinsic("__gcObjAddr", .rawPtr, [a], span)
            }
            // Construction of a generic type — infer the type arguments from the fields (M5 5.2.3).
            if genericArity(name) != nil {
                return checkGenericConstruct(name, args, at: span)
            }
            // Construction: TypeName(...) for struct/class/actor. Thread each field's declared type
            // in as the expected type of its argument (matched by label, else by position), so a
            // literal adopts a `UInt8`/`Double` field and a real mismatch is a clean diagnostic.
            if let k = kindOf(name), k != .enum_ {
                let fields = constructorFields(name)
                let irArgs = args.enumerated().map { (i, a) -> NOIRArg in
                    let exp: Type? = fields.flatMap { fs in
                        a.label.flatMap { l in fs.first { $0.label == l }?.type } ?? (i < fs.count ? fs[i].type : nil)
                    }
                    let v = checkExpr(a.value, expected: exp)
                    if let exp, v.type != exp, v.type != .error, exp != .error {
                        diags.error("argument of type '\(v.type)' does not match expected '\(exp)'", at: v.span)
                    }
                    return NOIRArg(label: a.label, value: v)
                }
                return NOIRExpr(type: .named(name, k), span: span, kind: .construct(typeName: name, args: irArgs))
            }
            // Named function / non-print builtin.
            if let sig = funcs[name] {
                if !sig.generics.isEmpty {
                    let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr($0.value)) }
                    return checkGenericCall(name, sig, irArgs, at: span)
                }
                let irArgs = checkArgs(args, expectedParams: sig.params)
                checkArgTypes(irArgs.map(\.value), against: sig.params, at: span)
                let calleeType = Type.function(params: sig.params, ret: sig.ret)
                return NOIRExpr(type: sig.ret, span: span, kind: .call(callee: irVar(name, calleeType, span), args: irArgs, typeArgs: []))
            }
        }

        // Generic construction with explicit type arguments: `Box<Int>(value: 3)`.
        if case .genericIdent(let name, let refs, _) = callee {
            let explicit = refs.map { resolve($0) }
            if genericTypeShape(name) != nil {
                return checkGenericConstruct(name, args, explicit: explicit, at: span)
            }
            if enums[name] != nil {
                diags.error("generic enum '\(name)' is constructed through a case, e.g. '\(name)<...>.case(...)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
            }
            diags.error("'\(name)' is not a generic type; explicit type arguments are not allowed here", at: span)
            return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
        }

        // Fallback: type the callee; call it if it is a function value.
        let c = checkExpr(callee)
        let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr($0.value)) }
        if case .function(_, let ret) = c.type {
            return NOIRExpr(type: ret, span: span, kind: .call(callee: c, args: irArgs, typeArgs: []))
        }
        if c.type != .error {
            diags.error("value of type '\(c.type)' is not callable", at: span)
        }
        return NOIRExpr(type: .error, span: span, kind: .call(callee: c, args: irArgs, typeArgs: []))
    }

    // MARK: - Type checks

    // Assigning to a `let` field is rejected (M4.10 field-level immutability). Bare
    // field writes inside methods are already caught by the AST Typechecker (self is
    // read-only); this covers `value.field = …` targets on struct/class values.
    private func rejectLetFieldTarget(_ target: NOIRExpr) {
        guard case .fieldAccess(let base, let field) = target.kind else { return }
        let typeName: String
        switch base.type {
        case .named(let n, .struct_), .named(let n, .class_): typeName = n   // concrete value/reference
        case .generic(let n, _):                              typeName = n   // an applied generic type (5.2.3)
        default:                                              return
        }
        let fields = structs[typeName]?.fields ?? classes[typeName]?.fields ?? []
        if let f = fields.first(where: { $0.name == field }), !f.isMutable {
            diags.error("cannot assign to 'let' field '\(field)'", at: target.span)
        }
    }

    private mutating func fieldType(of type: Type, field: String, at span: Span) -> Type {
        // A field on an applied generic type `Box<Int>` — substitute the arguments (M5 5.2.3).
        if case .generic(let base, let args) = type {
            return genericMemberType(base, args, field, at: span)
        }
        guard case .named(let name, let kind) = type else {
            if type != .error { diags.error("value of type '\(type)' has no field '\(field)'", at: span) }
            return .error
        }
        let fields: [VarField]
        switch kind {
        case .struct_: fields = structs[name]?.fields ?? []
        case .class_:  fields = classes[name]?.fields ?? []
        case .actor_:  fields = actors[name]?.fields.map { VarField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) } ?? []
        case .enum_, .interface_:   fields = []
        }
        if let f = fields.first(where: { $0.name == field }) { return resolve(f.type) }
        diags.error("type '\(name)' has no field '\(field)'", at: span)
        return .error
    }

    private func binaryResult(_ op: BinOp, _ lhs: NOIRExpr, _ rhs: NOIRExpr, at span: Span) -> Type {
        switch op {
        case .add, .sub, .mul, .div, .mod:
            // Arithmetic is Int, UInt8, or Double, with no implicit conversion between them: both
            // operands must be the same numeric type (use `.double`/`.int`/`.uint8` to convert).
            func numeric(_ t: Type, _ span: Span) -> Bool {
                if t == .int || t == .uint8 || t == .uint64 || t == .double { return true }
                if t != .error { diags.error("arithmetic requires Int, UInt8, UInt64, or Double, got '\(t)'", at: span) }
                return false
            }
            let lok = numeric(lhs.type, lhs.span), rok = numeric(rhs.type, rhs.span)
            if lok && rok && lhs.type != rhs.type {
                diags.error("arithmetic operands must match: '\(lhs.type)' and '\(rhs.type)' (no implicit conversion)", at: lhs.span)
                return lok ? lhs.type : .int
            }
            return lok ? lhs.type : (rok ? rhs.type : .int)
        case .bitAnd, .bitOr, .bitXor, .shl, .shr:
            // Bitwise and shift are integer-only (Int or UInt8), operands the same type. `>>` is an
            // arithmetic shift on the signed Int and a logical shift on the unsigned UInt8 (egress).
            func integral(_ t: Type, _ span: Span) -> Bool {
                if t == .int || t == .uint8 || t == .uint64 { return true }
                if t != .error { diags.error("bitwise and shift operators require Int, UInt8, or UInt64, got '\(t)'", at: span) }
                return false
            }
            let lok = integral(lhs.type, lhs.span), rok = integral(rhs.type, rhs.span)
            if lok && rok && lhs.type != rhs.type {
                diags.error("bitwise operands must match: '\(lhs.type)' and '\(rhs.type)' (no implicit conversion)", at: lhs.span)
                return lok ? lhs.type : .int
            }
            return lok ? lhs.type : (rok ? rhs.type : .int)
        case .lt, .gt, .lte, .gte:
            checkComparison(lhs, rhs, equality: false, at: span)
            return .bool
        case .eq, .neq:
            checkComparison(lhs, rhs, equality: true, at: span)
            return .bool
        case .and, .or:
            // Logical `&&` / `||`: both operands Bool, result Bool. Short-circuit lowering happens
            // in SSAIRgen; here it types like any Bool-producing operator.
            let sym = op == .and ? "&&" : "||"
            if lhs.type != .bool && lhs.type != .error {
                diags.error("logical '\(sym)' requires Bool, got '\(lhs.type)'", at: lhs.span)
            }
            if rhs.type != .bool && rhs.type != .error {
                diags.error("logical '\(sym)' requires Bool, got '\(rhs.type)'", at: rhs.span)
            }
            return .bool
        }
    }

    // A comparison / equality operator (result Bool), vs a value op (result = operand type).
    private func isComparisonOp(_ op: BinOp) -> Bool {
        switch op {
        case .eq, .neq, .lt, .gt, .lte, .gte: return true
        default:                              return false
        }
    }

    // `-x` / `!x` / `~x` desugar to a binary form so no unary node reaches NOIR (or the egress):
    // `-x` → `0 - x`, `!x` → `x == false`, `~x` → `x ^ allOnes`. `expected` flows into the operand
    // for the value ops (`-`, `~`) so a UInt8 context reaches its literal.
    private mutating func checkUnary(_ op: UnaryOp, _ operand: Expr, at span: Span, expected: Type?) -> NOIRExpr {
        let x = checkExpr(operand, expected: expected)
        switch op {
        case .neg:
            switch x.type {
            case .int, .uint8, .uint64:
                let zero = NOIRExpr(type: x.type, span: span, kind: .intLit(0))
                return NOIRExpr(type: x.type, span: span, kind: .binary(.sub, zero, x))
            case .double:
                let zero = NOIRExpr(type: .double, span: span, kind: .doubleLit(0))
                return NOIRExpr(type: .double, span: span, kind: .binary(.sub, zero, x))
            default:
                if x.type != .error { diags.error("unary '-' requires Int, UInt8, or Double, got '\(x.type)'", at: span) }
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
        case .not:
            guard x.type == .bool || x.type == .error else {
                diags.error("unary '!' requires Bool, got '\(x.type)'", at: span)
                return NOIRExpr(type: .bool, span: span, kind: .boolLit(false))
            }
            let f = NOIRExpr(type: .bool, span: span, kind: .boolLit(false))
            return NOIRExpr(type: .bool, span: span, kind: .binary(.eq, x, f))
        case .bitNot:
            switch x.type {
            case .int:
                let ones = NOIRExpr(type: .int, span: span, kind: .intLit(-1))
                return NOIRExpr(type: .int, span: span, kind: .binary(.bitXor, x, ones))
            case .uint8:
                let ones = NOIRExpr(type: .uint8, span: span, kind: .intLit(255))
                return NOIRExpr(type: .uint8, span: span, kind: .binary(.bitXor, x, ones))
            case .uint64:
                let ones = NOIRExpr(type: .uint64, span: span, kind: .intLit(-1))
                return NOIRExpr(type: .uint64, span: span, kind: .binary(.bitXor, x, ones))
            default:
                if x.type != .error { diags.error("unary '~' requires Int, UInt8, or UInt64, got '\(x.type)'", at: span) }
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
        }
    }

    // Let an integer literal opposite a UInt8 operand adopt UInt8 (range-checked), so `b + 1` and
    // `b & 240` typecheck without an explicit conversion. Only a literal moves — a non-literal Int
    // never silently becomes UInt8.
    private func adoptUInt8Literal(_ op: BinOp, _ lhs: NOIRExpr, _ rhs: NOIRExpr) -> (NOIRExpr, NOIRExpr) {
        func asType(_ e: NOIRExpr, _ target: Type, range: ClosedRange<Int>? = nil) -> NOIRExpr? {
            guard case .intLit(let v) = e.kind, e.type == .int, v >= 0 else { return nil }
            if let r = range, !r.contains(v) { return nil }
            return NOIRExpr(type: target, span: e.span, kind: .intLit(v))
        }
        if lhs.type == .uint8, let r = asType(rhs, .uint8, range: 0...255) { return (lhs, r) }
        if rhs.type == .uint8, let l = asType(lhs, .uint8, range: 0...255) { return (l, rhs) }
        // A bare nonnegative Int literal adopts UInt64 against a UInt64 operand (`w << 8`, `w & 255`).
        if lhs.type == .uint64, let r = asType(rhs, .uint64) { return (lhs, r) }
        if rhs.type == .uint64, let l = asType(lhs, .uint64) { return (l, rhs) }
        return (lhs, rhs)
    }

    // Comparison operators are numeric-only for now (a holistic operator design comes later).
    // Relational (`< > <= >=`) allows Int/Double; equality (`== !=`) also allows Bool. Both sides
    // must be the same type. Strings compare with `.eq`, not `==`; aggregates have no operator yet.
    private func checkComparison(_ lhs: NOIRExpr, _ rhs: NOIRExpr, equality: Bool, at span: Span) {
        if lhs.type == .error || rhs.type == .error { return }
        let allowed: [Type] = equality ? [.int, .uint8, .uint64, .double, .bool] : [.int, .uint8, .uint64, .double]
        if lhs.type != rhs.type {
            diags.error("cannot compare '\(lhs.type)' and '\(rhs.type)'", at: span)
            return
        }
        guard allowed.contains(lhs.type) else {
            if lhs.type == .string && equality {
                diags.error("String has no '==' / '!=' operator yet — use '.eq(...)'", at: span)
            } else {
                diags.error("type '\(lhs.type)' does not support comparison", at: span)
            }
            return
        }
    }

    private func checkArgTypes(_ args: [NOIRExpr], against params: [Type], at span: Span) {
        if args.count != params.count {
            diags.error("expected \(params.count) argument(s), got \(args.count)", at: span)
            return
        }
        for (a, p) in zip(args, params) where a.type != p && a.type != .error && p != .error {
            diags.error("argument of type '\(a.type)' does not match expected '\(p)'", at: a.span)
        }
    }

    // Check call args, threading a per-position expected type inward (for leading-dot
    // enum inference); `expectedParams` is nil where the slots aren't known.
    private mutating func checkArgs(_ args: [Arg], expectedParams: [Type]?) -> [NOIRArg] {
        var out: [NOIRArg] = []
        for (i, a) in args.enumerated() {
            let exp = expectedParams.flatMap { i < $0.count ? $0[i] : nil }
            out.append(NOIRArg(label: a.label, value: coerce(checkExpr(a.value, expected: exp), to: exp)))
        }
        return out
    }

    // Leading-dot `.case(...)`: resolve the enum from the expected type, then build. The
    // context may name a concrete enum (`.named`) or an applied generic one (`.generic`, M5 5.2.3).
    private mutating func buildImplicitEnum(_ caseName: String, _ args: [Arg], expected: Type?, at span: Span) -> NOIRExpr {
        let enumName: String?
        switch expected {
        case .named(let n, .enum_) where enums[n] != nil:    enumName = n
        case .generic(let n, _) where enums[n] != nil:       enumName = n
        default:                                             enumName = nil
        }
        guard let enumName else {
            diags.error("cannot infer enum type for '.\(caseName)' here", at: span)
            let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr($0.value)) }
            return NOIRExpr(type: .error, span: span, kind: .enumInit(typeName: "", caseName: caseName, args: irArgs))
        }
        return buildEnumInit(enumName, caseName, args, expected: expected, at: span)
    }

    // `EnumType.case(args)` → a typed enumInit, checking the payload against the case. For a
    // generic enum (`Option<T>`) the type argument is inferred from the payload — and, for a
    // no-payload case like `.none`, seeded from the expected type context (M5 5.2.3).
    private mutating func buildEnumInit(_ enumName: String, _ caseName: String, _ args: [Arg],
                                        explicit: [Type]? = nil, expected: Type? = nil, at span: Span) -> NOIRExpr {
        guard let caseDecl = enums[enumName]?.cases.first(where: { $0.name == caseName }) else {
            diags.error("enum '\(enumName)' has no case '\(caseName)'", at: span)
            let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr($0.value)) }
            return NOIRExpr(type: .named(enumName, .enum_), span: span, kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
        }
        if let generics = enums[enumName]?.generics, !generics.isEmpty {
            return buildGenericEnumInit(enumName, generics, caseDecl, args, explicit: explicit, expected: expected, at: span)
        }
        if explicit != nil {
            diags.error("enum '\(enumName)' is not generic; type arguments are not allowed", at: span)
        }
        let irArgs = matchEnumArgs(args, fields: caseDecl.fields, case: caseName, at: span)
        return NOIRExpr(type: .named(enumName, .enum_), span: span,
                      kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
    }

    // A generic enum case: unify each payload arg against the case field's declared type
    // (a `T` payload resolves to `.typeParam`), seed inference from the expected type when the
    // case carries no payload, then bound-check — yielding a `.generic(base, args)` (M5 5.2.3).
    private mutating func buildGenericEnumInit(_ enumName: String, _ generics: [GenericParam],
                                               _ caseDecl: EnumCaseDecl, _ args: [Arg],
                                               explicit: [Type]? = nil, expected: Type?, at span: Span) -> NOIRExpr {
        let saved = genericScope; genericScope = Set(generics.map(\.name)); defer { genericScope = saved }
        var subst: [String: Type] = [:]
        // Explicit type arguments (`Option<Int>.some(...)`) seed inference; the payload is then
        // unified against them, so a mismatch (`Option<Int>.some("hi")`) is a conflict error.
        if let explicit {
            if explicit.count != generics.count {
                diags.error("generic enum '\(enumName)' expects \(generics.count) type argument(s), got \(explicit.count)", at: span)
            } else {
                for (p, a) in zip(generics, explicit) { subst[p.name] = a }
            }
        } else if case .generic(let b, let eargs)? = expected, b == enumName, eargs.count == generics.count {
            for (p, a) in zip(generics, eargs) { subst[p.name] = a }
        }
        if args.count != caseDecl.fields.count {
            diags.error("case '\(caseDecl.name)' expects \(caseDecl.fields.count) argument(s), got \(args.count)", at: span)
        }
        var irArgs: [NOIRArg] = []
        for (i, field) in caseDecl.fields.enumerated() {
            let fieldTy = resolve(field.type)
            let expArg = substitute(fieldTy, subst)
            let hint: Type? = { if case .typeParam = expArg { return nil }; return expArg }()
            guard let arg = args.first(where: { $0.label == field.name }) ?? (i < args.count ? args[i] : nil) else { continue }
            let v = checkExpr(arg.value, expected: hint)
            unify(param: fieldTy, arg: v.type, into: &subst, at: span)
            irArgs.append(NOIRArg(label: field.name, value: v))
        }
        let typeArgs = inferredTypeArgs(generics, subst, owner: enumName, at: span)
        return NOIRExpr(type: .generic(base: enumName, args: typeArgs), span: span,
                      kind: .enumInit(typeName: enumName, caseName: caseDecl.name, args: irArgs))
    }

    // Pair payload args to the case's declared fields (by label, else by position),
    // type-checking each against its field; arity/type mismatches are diagnostics.
    private mutating func matchEnumArgs(_ args: [Arg], fields: [VarField], case caseName: String, at span: Span) -> [NOIRArg] {
        if args.count != fields.count {
            diags.error("case '\(caseName)' expects \(fields.count) argument(s), got \(args.count)", at: span)
        }
        var out: [NOIRArg] = []
        for (i, field) in fields.enumerated() {
            let fieldTy = resolve(field.type)
            guard let arg = args.first(where: { $0.label == field.name }) ?? (i < args.count ? args[i] : nil) else { continue }
            let v = checkExpr(arg.value, expected: fieldTy)
            if v.type != fieldTy && v.type != .error && fieldTy != .error {
                diags.error("argument of type '\(v.type)' does not match expected '\(fieldTy)'", at: v.span)
            }
            out.append(NOIRArg(label: field.name, value: v))
        }
        return out
    }

    private func irVar(_ name: String, _ type: Type, _ span: Span) -> NOIRExpr {
        NOIRExpr(type: type, span: span, kind: .varRef(name))
    }

    // A mutable receiver for a mutating method call (M4.11, conservative first cut):
    // a `var` local, or `self` (mutation through self makes the enclosing method
    // mutating by inference, which keeps the check sound). Anything else — a `let`
    // local, a parameter, a field access, a temporary — is immutable.
    private func isMutableReceiver(_ base: Expr) -> Bool {
        if case .ident(let name, _) = base {
            return name == "self" || lookupMutable(name)
        }
        return false
    }

    // MARK: - Scopes

    private mutating func pushScope() { scopes.append([:]) }
    private mutating func popScope()  { scopes.removeLast() }
    private mutating func declare(_ name: String, _ type: Type, isMutable: Bool = false) {
        scopes[scopes.count - 1][name] = Local(type: type, isMutable: isMutable)
    }

    private func lookup(_ name: String) -> Type? {
        for scope in scopes.reversed() {
            if let l = scope[name] {
                return l.type
            }
        }
        return nil
    }

    // Whether `name` is a mutable (`var`) local — used by the M4.11 caller check.
    private func lookupMutable(_ name: String) -> Bool {
        for scope in scopes.reversed() { if let l = scope[name] { return l.isMutable } }
        return false
    }
}
