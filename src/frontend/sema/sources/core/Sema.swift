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
    let program: Program
    let diags = DiagnosticSink()
    private let subsetFuncs: Set<String>   // task 149 — functions compiled under the runtime-subset rules

    // Global declarations, by name.
    var structs: [String: StructDecl] = [:]
    var enums:   [String: EnumDecl]   = [:]
    var classes: [String: ClassDecl]  = [:]
    var actors:  [String: ActorDecl]  = [:]
    var interfaces: [String: InterfaceDecl] = [:]   // M5 A1

    // `static fun` members lowered to free functions (named `Type.method`, no `self`), collected
    // during declaration lowering and appended to the module's decls after the main pass.
    var pendingStaticFuncs: [NOIRDecl] = []
    var funcs:   [String: FnSig]      = [:]   // named functions + non-print builtins

    // Computed properties (M5 A1), by owning type then property name. Drives member
    // read → getter-call and assignment → setter-call routing during body lowering.
    struct PropInfo { let type: Type; let hasSetter: Bool }
    var computedProps: [String: [String: PropInfo]] = [:]

    // Conformance facts (M5 A1.4), filled by checkConformances before body lowering.
    var conformsTo: [String: Set<String>] = [:]      // type name → interface names
    var conformanceList: [NOIRConformance] = []        // one per valid `T: I`
    var conformancePairs: Set<String> = []           // "T:I" seen, so witnesses aren't duplicated
    var inheritedDefaults: [String: [InterfaceMethod]] = [:]   // defaulted reqs a type inherits
    var interfaceBases: [String: [Conformance]] = [:]   // M5 A1.5: interface → direct base interfaces
    var compositeList: [NOIRComposite] = []               // M5 A1.5b: (type, any A & B) pairs boxed
    var compositePairs: Set<String> = []

    // M5 A3: `some I` opaque types. `allConformsTo` records every checked conformance
    // (including constraint-only interfaces, which have no witness) so `some I` can verify
    // its underlying conforms; `conformsTo` above stays witness-only for `any`. `opaqueUnderlyings`
    // maps an opaque owner (a `some`-returning function/method, or a `let`/`var: some I` binding)
    // to its single hidden concrete type, filled during lowering and read by codegen.
    var allConformsTo: [String: Set<String>] = [:]
    var opaqueUnderlyings: [String: Type] = [:]
    var opaqueBindingCounter = 0

    // M5 5.2.1: the generic type parameters (`T`, `U`) in scope while resolving a generic
    // decl's signatures — a bare name here resolves to `.typeParam`, not an unknown type.
    var genericScope: Set<String> = []

    // Lexical scope stack for locals/params (name → type + mutability).
    private var scopes: [[String: Local]] = []
    private struct Local {
        let type: Type
        let isMutable: Bool
    }

    // Declared return type of the body being lowered — the contextual type for a
    // `return .case(...)` leading-dot construction (M4.10).
    var currentReturnType: Type = .void
    var loopDepth = 0   // >0 inside a `while` body; gates `break`/`continue`

    // Value-type method calls, recorded during lowering with their receiver's
    // mutability; checked against inferred mutating-ness after the mutation pass (M4.11).
    struct CallSite { let callee: String; let receiverMutable: Bool; let span: Span }
    var methodCallSites: [CallSite] = []

    struct FnSig { let params: [Type]; let ret: Type; var generics: [GenericParam] = [] }

    // M5 5.2.2: the bounds of each generic type parameter in scope (`T` → its interfaces),
    // so a requirement call on a `.typeParam` receiver dispatches through the right witness.
    var genericBounds: [String: [String]] = [:]

    // M5 5.3.2: the `shared` type parameters in scope (`<shared T>`), so a shared `T`
    // used inside the body counts as shareable when passed to another `shared` bound.
    var sharedParams: Set<String> = []

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
        InterfaceModel.validateInterfaceGraph(self)
        InterfaceModel.checkConformances(&self)
        var decls: [NOIRDecl] = []
        for decl in program.decls {
            // Interfaces are abstract: validate them, but emit no IR (conformance in a
            // later slice generates the concrete witnesses that carry the defaults).
            if case .interfaceDecl(let i) = decl { InterfaceModel.checkInterface(&self, i); continue }
            // Generic *types* lower to one uniform C shape — a `T` field is held boxed
            // (`void*`), sized/copied at construction where the concrete `T` is known; no
            // value witness (M5 5.2.3). Generic *functions* are witness-passed (5.2.2).
            if isGenericType(decl) { decls.append(NOIRGen.lowerGenericDecl(&self, decl)); continue }
            decls.append(NOIRGen.lowerDecl(&self, decl))
        }
        // `static fun` members lowered as free functions, emitted alongside the type decls.
        decls.append(contentsOf: pendingStaticFuncs)

        // M4.11: infer method mutating-ness, validate `let`-field / `self` writes,
        // annotate the IR, then check that mutating value-type calls have a mutable receiver.
        let module0 = NOIRModule(decls: decls, interfaces: InterfaceModel.buildIRInterfaces(self),
                               conformances: conformanceList, composites: compositeList,
                               opaqueUnderlyings: opaqueUnderlyings)
        let mutation = analyzeMutation(module0, into: diags)
        for site in methodCallSites where mutation.mutating.contains(site.callee) && !site.receiverMutable {
            diags.error("cannot call mutating method on an immutable value — the receiver must be a 'var'", at: site.span)
        }
        checkRuntimeSubset(mutation.module, designated: subsetFuncs, into: diags)
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
            case .structDecl(let s): NOIRGen.registerProps(&self, s.name, s.properties, generics: s.generics)
            case .enumDecl(let e):   NOIRGen.registerProps(&self, e.name, e.properties, generics: e.generics)
            case .classDecl(let c):  NOIRGen.registerProps(&self, c.name, c.properties, generics: c.generics)
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
    func isShareable(_ t: Type) -> Bool {
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
    func resolve(_ ref: TypeRef?, selfAs: Type? = nil, opaqueOwner: String? = nil) -> Type {
        guard let ref else { return .void }
        if let ifaces = ref.existentialOf {   // `any I` / `any A & B` (M5 A1.4/A1.5b)
            return TypeResolution.resolveExistential(self, ifaces, at: ref.span)
        }
        if let ifaces = ref.opaqueOf {        // `some I` / `some A & B` (M5 A3)
            return TypeResolution.resolveOpaque(self, ifaces, owner: opaqueOwner, at: ref.span)
        }
        if let args = ref.genericArgs {       // `Box<Int>` — an applied generic type (M5 5.2.1)
            return TypeResolution.resolveGeneric(self, ref.name, args: args, selfAs: selfAs, at: ref.span)
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

    // The number of type parameters of a declared type, or nil if it isn't generic (M5 5.2.1).
    func genericArity(_ name: String) -> Int? {
        let n = structs[name]?.generics.count ?? enums[name]?.generics.count ?? classes[name]?.generics.count ?? 0
        return n > 0 ? n : nil
    }

    // The interface(s) an existential/composition ranges over; empty for other types.
    func existentialInterfaces(_ type: Type) -> [String] {
        switch type {
        case .existential(let i): return [i]
        case .composition(let is_): return is_
        default: return []
        }
    }

    // Is `name` a property member reachable by bare name through `self`? A property
    // requirement when `self` is an interface (default body), or a computed property on a
    // concrete receiver. Stored fields are bound by name already, so they aren't here (M5).
    func bareMemberOfSelf(_ selfTy: Type, _ name: String) -> Bool {
        switch selfTy {
        case .named(let iface, .interface_): return aggregatedProperties(iface).contains { $0.name == name }
        case .named(let tn, _):              return computedProps[tn]?[name] != nil
        default:                             return false
        }
    }

    // A heap (reference) type: a class/actor instance or an Array handle — a managed `p1` at runtime,
    // so `addrOf` (task 150 rung 2) can take its raw address. Structs/enums are value types.
    func isReferenceType(_ t: Type) -> Bool {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .array: return true
        default: return false
        }
    }

    func kindOf(_ name: String) -> NamedKind? {
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
    func constructorFields(_ name: String) -> [(label: String, type: Type)]? {
        if let s = structs[name] { return s.fields.map { ($0.name, resolve($0.type)) } }
        if let c = classes[name] { return c.fields.map { ($0.name, resolve($0.type)) } }
        if let a = actors[name]  { return a.fields.map { ($0.name, resolve($0.type)) } }
        return nil
    }

    // The declared instance method `name` on a struct/enum/class, if any (T3). Static members are
    // excluded — they are called on the type, never on a value.
    func methodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
        typeMethods(typeName, kind)?.first { $0.name == name && !$0.isStatic }
    }

    // The declared `static fun name` on a struct/enum/class, if any — the type-associated form.
    func staticMethodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
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

    // MARK: - Generic decls (M5 5.2.1)

    func isGenericType(_ decl: TopDecl) -> Bool {
        switch decl {
        case .structDecl(let s): return !s.generics.isEmpty
        case .enumDecl(let e):   return !e.generics.isEmpty
        case .classDecl(let c):  return !c.generics.isEmpty
        default: return false
        }
    }

    // A method requirement (or default) named `name` reachable from an interface,
    // including inherited requirements (aggregated over the refinement graph).
    func interfaceMethod(_ typeName: String, _ name: String) -> InterfaceMethod? {
        aggregatedMethods(typeName).first { $0.name == name }
    }

    // MARK: - Refinement graph (M5 A1.5)

    // Base interfaces reachable from `iface` (transitive), cycle-guarded.
    func transitiveBases(_ iface: String) -> [String] {
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
    func hasNonCovariantSelf(_ iface: String) -> Bool {
        ownHasNonCovariantSelf(iface) || transitiveBases(iface).contains { ownHasNonCovariantSelf($0) }
    }

    // A static requirement (`static fun`) has no receiver, so it can't be dispatched through an
    // erased `any I` value — the interface is constraint-only, like a non-covariant `Self`.
    func hasStaticRequirement(_ iface: String) -> Bool {
        let own = { (n: String) in self.interfaces[n]?.methods.contains(where: \.isStatic) ?? false }
        return own(iface) || transitiveBases(iface).contains(where: own)
    }

    // An interface usable as a generic bound / `some I` but not `any I` (M5 5.6): a non-covariant
    // `Self`, or a static requirement.
    func isConstraintOnly(_ iface: String) -> Bool {
        hasNonCovariantSelf(iface) || hasStaticRequirement(iface)
    }

    // The full method-requirement set of `iface` = its own plus every inherited one,
    // deduplicated by signature; each carries its resolved default (§4.3).
    func aggregatedMethods(_ iface: String) -> [InterfaceMethod] {
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
                                   defaultBody: resolveDefault(defaults[key] ?? []), isStatic: m.isStatic, span: m.span)
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

    func aggregatedProperties(_ iface: String) -> [InterfacePropertyReq] {
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

    // A call to a generic function (M5 5.2.2): infer each type parameter from the arguments,
    // check every inferred type satisfies the parameter's bounds (a witness must exist), and
    // record the inferred type arguments so codegen can pass the witnesses.
    // Unify a (possibly type-parameter) parameter type against a concrete argument type,
    // binding type parameters in `subst` (M5 5.2.2). Shallow — enough for `T` and concrete
    // params; nested generic arguments extend this in a later slice.
    mutating func unify(param: Type, arg: Type, into subst: inout [String: Type], at span: Span) {
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
    // Substitute inferred type parameters into a type (M5 5.2.2).
    func substitute(_ t: Type, _ subst: [String: Type]) -> Type {
        switch t {
        case .typeParam(let n):        return subst[n] ?? t
        case .generic(let b, let a):   return .generic(base: b, args: a.map { substitute($0, subst) })
        case .array(let e):            return .array(substitute(e, subst))
        case .function(let p, let r):  return .function(params: p.map { substitute($0, subst) }, ret: substitute(r, subst))
        default:                        return t
        }
    }
    // MARK: - Generic types (M5 5.2.3)

    // A construction base that is a plain type name (`Type`) or a name carrying explicit type
    // arguments (`Type<Args>`, parsed as `.genericIdent`). The arguments are resolved in the
    // current generic scope so a `T` at the site binds to the enclosing function's parameter.
    func typeNameAndArgs(_ e: Expr) -> (name: String, explicit: [Type]?)? {
        switch e {
        case .ident(let n, _):                   return (n, nil)
        case .genericIdent(let n, let refs, _):  return (n, refs.map { resolve($0) })
        default:                                 return nil
        }
    }
    // Build a NOIR call to a codegen intrinsic (`__rawAlloc` etc.); the result type is carried on the
    // node so codegen reads the element type from it (e.g. a typed load).
    func ptrIntrinsic(_ name: String, _ result: Type, _ args: [NOIRExpr], _ span: Span) -> NOIRExpr {
        let callee = NOIRExpr(type: .void, span: span, kind: .varRef(name))
        return NOIRExpr(type: result, span: span,
                        kind: .call(callee: callee, args: args.map { NOIRArg(label: nil, value: $0) }, typeArgs: []))
    }

    // MARK: - Scopes

    mutating func pushScope() { scopes.append([:]) }
    mutating func popScope()  { scopes.removeLast() }
    mutating func declare(_ name: String, _ type: Type, isMutable: Bool = false) {
        scopes[scopes.count - 1][name] = Local(type: type, isMutable: isMutable)
    }

    func lookup(_ name: String) -> Type? {
        for scope in scopes.reversed() {
            if let l = scope[name] {
                return l.type
            }
        }
        return nil
    }

    // Whether `name` is a mutable (`var`) local — used by the M4.11 caller check.
    func lookupMutable(_ name: String) -> Bool {
        for scope in scopes.reversed() { if let l = scope[name] { return l.isMutable } }
        return false
    }
}
