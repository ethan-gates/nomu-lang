import noir
import ast
import support
// Interface model building (M5 A1–A2) — the driver-phase interface machinery that runs
// once over the program: validate the refinement graph, typecheck interface default
// bodies, check each declared conformance (recording witness facts and inherited
// defaults), synthesize a conformer's inherited-default methods, and build the IR
// witness-table surface.
//
// A capability namespace over `Sema`. The read-only passes borrow (`validateInterfaceGraph`,
// `buildIRInterfaces`); the ones that record conformance facts or lower default bodies take
// `inout`. The interface *queries* it leans on — `transitiveBases`, `aggregatedMethods`,
// `isConstraintOnly`, the `Self`-variance predicates — stay on `Sema` as the shared oracle.
enum InterfaceModel {

    // Validate an interface (M5 A1): its requirement signatures must resolve, and each
    // overridable default body must typecheck. In a default, `self` is the interface
    // type, its property requirements are visible by bare name, and `self.req(...)` /
    // `self.prop` resolve against the requirement set. No IR is retained — conformance
    // (a later slice) compiles the defaults into each conformer's witnesses.
    static func checkInterface(_ s: inout Sema, _ i: InterfaceDecl) {
        // Within an interface, `Self` ≡ the interface's own type (its `self` value's type,
        // §4.4): requirement signatures validate against it and default bodies read it (M5 A2).
        let selfType = Type.named(i.name, .interface_)
        for m in i.methods {
            for p in m.params { _ = s.resolve(p.type, selfAs: selfType) }
            _ = s.resolve(m.returnType, selfAs: selfType)
        }
        for p in i.properties { _ = s.resolve(p.type, selfAs: selfType) }

        for m in i.methods {
            guard let body = m.defaultBody else { continue }
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = s.resolve(m.returnType, selfAs: selfType)
            s.pushScope()
            s.declare("self", selfType)
            for p in params { s.declare(p.name, p.type) }
            let saved = s.currentReturnType; s.currentReturnType = ret
            _ = NOIRGen.lowerBlock(&s, body)
            s.currentReturnType = saved
            s.popScope()
        }
    }

    // MARK: - Refinement graph validation

    // Each base must name an interface, and refinement must be acyclic.
    static func validateInterfaceGraph(_ s: borrowing Sema) {
        for (name, bases) in s.interfaceBases {
            for base in bases {
                if s.interfaces[base.name] == nil {
                    if s.kindOf(base.name) != nil {
                        s.diags.error("'\(base.name)' is not an interface; an interface may only refine interfaces", at: base.span)
                    } else {
                        s.diags.error("unknown interface '\(base.name)'", at: base.span)
                    }
                } else if base.name == name || s.transitiveBases(base.name).contains(name) {
                    s.diags.error("interface '\(name)' refinement is cyclic through '\(base.name)'", at: base.span)
                }
            }
        }
    }

    // The interfaces' requirement surface, resolved to types, for witness-table layout.
    static func buildIRInterfaces(_ s: borrowing Sema) -> [NOIRInterface] {
        var out: [NOIRInterface] = []
        // Own-module and imported interfaces both need a witness-table surface here: a consumer that
        // conforms its own type to an imported interface and dispatches through it (task 100.4.3.3.3)
        // needs the imported interface's slot layout in codegen's `interfaceDefs`.
        for decl in s.program.decls + s.externalDecls {
            guard case .interfaceDecl(let i) = decl else { continue }
            // In the `any I` witness ABI each `-> Self` requirement's slot is **erased to `any I`**
            // (`selfAs: .existential`), so the slot has a uniform concrete representation (`AnyBox`); the
            // thunk re-boxes the concrete result (M5 5.6). A constraint-only interface can't be `any I`, so
            // it never gets that table, only the compiled-once one, which keeps `Self` (`selfParams`).
            let selfErased = Type.existential(i.name)
            // Aggregated (flattened) surface: the witness table carries inherited slots too. Slots are ordered
            // by name: a module reading the interface from a `.nmi` sees its requirements in another order than
            // the declaring module, and both must lay out the same table.
            let methods = s.aggregatedMethods(i.name).sorted { $0.name < $1.name }.map {
                NOIRMethodReq(name: $0.name, params: $0.params.map { s.resolve($0.type, selfAs: selfErased) },
                              ret: s.resolve($0.returnType, selfAs: selfErased),
                              selfParams: $0.params.map { s.resolve($0.type, selfAs: .selfType) },
                              selfRet: s.resolve($0.returnType, selfAs: .selfType), isStatic: $0.isStatic)
            }
            let props = s.aggregatedProperties(i.name).sorted { $0.name < $1.name }.map {
                NOIRPropReq(name: $0.name, type: s.resolve($0.type, selfAs: selfErased), isSettable: $0.isSettable,
                            selfType: s.resolve($0.type, selfAs: .selfType))
            }
            // A witness carries a pointer to each base's (M5 A1.4 upcast).
            let bases = s.transitiveBases(i.name).sorted()
            out.append(NOIRInterface(name: i.name, methods: methods, properties: props, bases: bases,
                                     isConstraintOnly: s.isConstraintOnly(i.name)))
        }
        return out
    }

    // The interface declaring the default `name` that `typeName` inherits.
    static func defaultOwner(_ s: borrowing Sema, _ typeName: String, _ name: String) -> String? {
        (s.allConformsTo[typeName] ?? []).sorted().first { iface in
            s.interfaces[iface]?.methods.contains { $0.name == name && $0.defaultBody != nil && !$0.isStatic } == true
        }
    }

    // The function an exported interface's default is compiled once as (`lowerExportedDefaults`).
    static func defaultFunctionName(_ iface: String, _ method: String) -> String { "\(iface).\(method)" }

    // An exported interface's defaults, each compiled once in this module as a generic function over its conformer,
    // `I.m<Self: I>(self, …)`. A module importing the interface has only the fact that a default exists, so a conformer
    // declared there calls this (`lowerInheritedDefaults`); a conformer declared here gets the default's body.
    static func lowerExportedDefaults(_ s: inout Sema, _ i: InterfaceDecl) -> [NOIRDecl] {
        guard i.visibility >= .package else { return [] }
        let selfType = Type.typeParam("Self")
        let savedScope = s.genericScope, savedBounds = s.genericBounds
        s.genericScope = ["Self"]; s.genericBounds["Self"] = [i.name]
        defer { s.genericScope = savedScope; s.genericBounds = savedBounds }
        var out: [NOIRDecl] = []
        for m in i.methods where !m.isStatic {
            guard let body = m.defaultBody else { continue }
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = s.resolve(m.returnType, selfAs: selfType)
            let irBody = NOIRGen.withMethodScope(&s, selfType: selfType, fields: [], params: params, returnType: ret, body)
            out.append(.funcDecl(NOIRFunc(name: defaultFunctionName(i.name, m.name),
                                          generics: [NOIRGenericParam(name: "Self", bounds: [i.name])],
                                          params: [NOIRParam(label: "_", name: "self", type: selfType, span: m.span)] + params,
                                          returnType: ret, body: irBody, isMutating: false, visibility: i.visibility,
                                          span: m.span)))
        }
        return out
    }

    // An imported generic type's inherited defaults are methods of its template in the producer, compiled once there
    // like its declared methods, so each is registered as an imported generic method (`m:<origin@Type>:name`). An
    // imported non-generic type's default is a plain method of the producer, which a call links to.
    static func registerImportedDefaults(_ s: inout Sema) {
        // An imported interface's defaults, compiled once in its producer (`lowerExportedDefaults`).
        for decl in s.externalDecls {
            guard case .interfaceDecl(let i) = decl else { continue }
            let saved = s.genericScope; s.genericScope = ["Self"]; defer { s.genericScope = saved }
            let selfType = Type.typeParam("Self")
            guard let origin = i.origin else { continue }
            for m in i.methods where m.defaultBody != nil && !m.isStatic {
                let sym = ExternalName.encode(origin: origin, name: defaultFunctionName(i.name, m.name))
                s.externalGenericSigs[sym] = ExternalGenericSig(
                    generics: ["Self"], bounds: [[i.name]],
                    params: [selfType] + m.params.map { s.resolve($0.type, selfAs: selfType) },
                    ret: s.resolve(m.returnType, selfAs: selfType))
                s.externalFuncNames.insert(sym)
            }
        }
        for decl in s.externalDecls {
            let name: String, generics: [GenericParam]
            switch decl {
            case .structDecl(let d): name = d.name; generics = d.generics
            case .enumDecl(let d): name = d.name; generics = d.generics
            case .classDecl(let d): name = d.name; generics = d.generics
            default: continue
            }
            guard !generics.isEmpty, let defaults = s.inheritedDefaults[name] else { continue }
            let saved = s.genericScope; s.genericScope = Set(generics.map(\.name)); defer { s.genericScope = saved }
            let selfType = Type.generic(base: name, args: generics.map { .typeParam($0.name) })
            for req in defaults {
                let sym = "m:\(name):\(req.name)"
                s.externalGenericSigs[sym] = ExternalGenericSig(
                    generics: generics.map(\.name), bounds: generics.map { $0.bounds.map(\.name) },
                    params: [selfType] + req.params.map { s.resolve($0.type, selfAs: selfType) },
                    ret: s.resolve(req.returnType, selfAs: selfType))
                s.externalFuncNames.insert(sym)
            }
        }
    }

    // Synthesize a method on `T` for each defaulted requirement it inherits (on a generic type, `T` is the template
    // applied to its own parameters): the
    // default body lowered with `self: T`, so both concrete calls and witness slots resolve
    // to it (M5 A1.4). First cut: a default may reference directly-implemented requirements
    // (via `self.req()`) and stored-field state (bare name); default-calling-default and
    // computed-backed bare access are later work.
    static func lowerInheritedDefaults(_ s: inout Sema, _ typeName: String, selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        // An imported type's are synthesized in its producer, and called there (`registerImportedDefaults`).
        if ExternalName.isEncoded(typeName) { return [] }
        var out: [NOIRFunc] = []
        for req in s.inheritedDefaults[typeName] ?? [] {
            guard let body = req.defaultBody else { continue }
            // A default is synthesized as a concrete method of the conformer, so `Self` binds
            // to the conformer's concrete type here (M5 A2).
            let params = req.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = s.resolve(req.returnType, selfAs: selfType)
            // An imported interface's default has no body here: the method calls the producer's compiled-once copy.
            if let owner = defaultOwner(s, typeName, req.name), let origin = s.interfaces[owner]?.origin {
                let callee = NOIRExpr(type: .void, span: req.span,
                                      kind: .varRef(ExternalName.encode(origin: origin, name: defaultFunctionName(owner, req.name))))
                let args = [NOIRArg(label: nil, value: NOIRExpr(type: selfType, span: req.span, kind: .varRef("self")))]
                    + params.map { NOIRArg(label: nil, value: NOIRExpr(type: $0.type, span: $0.span, kind: .varRef($0.name))) }
                let call = NOIRExpr(type: ret, span: req.span, kind: .call(callee: callee, args: args, typeArgs: [selfType]))
                let stmt = NOIRStmt(kind: ret == .void ? .exprStmt(call) : .ret(call), span: req.span)
                out.append(NOIRFunc(name: req.name, params: params, returnType: ret, body: [stmt], isMutating: false, span: req.span))
                continue
            }
            s.pushScope()
            s.declare("self", selfType)
            for f in fields { s.declare(f.name, f.type) }
            for p in params { s.declare(p.name, p.type) }
            let saved = s.currentReturnType; s.currentReturnType = ret
            let irBody = NOIRGen.lowerBlock(&s, body)
            s.currentReturnType = saved
            s.popScope()
            out.append(NOIRFunc(name: req.name, params: params, returnType: ret, body: irBody, isMutating: false, span: req.span))
        }
        return out
    }

    // MARK: - Conformance checking (M5 A1.3)

    // Verify each declared conformance: every requirement of the interface is satisfied
    // by a matching member (or an interface default); an actor's by a handler (`checkActorConformance`).
    static func checkConformances(_ s: inout Sema) {
        // An imported type's conformances are declared in its `.nmi` and recorded here as an own type's are, so the
        // type satisfies bounds and boxes; its witness tables are built here, over the producer's methods.
        for decl in s.program.decls + s.externalDecls {
            // A generic type's conformances are checked on its template, with its type parameters in scope.
            switch decl {
            case .structDecl(let d) where !d.generics.isEmpty:
                checkConformance(&s, d.name, .struct_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties,
                                 generics: d.generics)
                continue
            case .enumDecl(let d) where !d.generics.isEmpty:
                checkConformance(&s, d.name, .enum_, d.conformances, methods: d.methods, fields: [], properties: d.properties,
                                 generics: d.generics)
                continue
            case .classDecl(let d) where !d.generics.isEmpty:
                checkConformance(&s, d.name, .class_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties,
                                 generics: d.generics)
                continue
            default:
                break
            }
            switch decl {
            case .structDecl(let d):
                checkConformance(&s, d.name, .struct_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties)
            case .enumDecl(let d):
                checkConformance(&s, d.name, .enum_, d.conformances, methods: d.methods, fields: [], properties: d.properties)
            case .classDecl(let d):
                checkConformance(&s, d.name, .class_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties)
            case .actorDecl(let d):
                checkActorConformance(&s, d)
            default:
                break
            }
        }
    }

    // A generic type (`generics` non-empty) records only the conformance fact, which every application of it shares
    // (`typeConforms`): its witness tables are per instantiation, built in the backend from the specialized methods.
    static func checkConformance(_ s: inout Sema, _ typeName: String, _ kind: NamedKind, _ conformances: [Conformance],
                                 methods: [FuncDecl], fields: [VarField], properties: [ComputedProperty],
                                 generics: [GenericParam] = []) {
        let selfType: Type = generics.isEmpty ? .named(typeName, kind)
                                              : .generic(base: typeName, args: generics.map { .typeParam($0.name) })
        let savedScope = s.genericScope
        s.genericScope.formUnion(generics.map(\.name))
        defer { s.genericScope = savedScope }
        let imported = ExternalName.isEncoded(typeName)
        for conf in conformances {
            guard s.interfaces[conf.name] != nil else {
                // An imported type may conform to an interface this module cannot see; that conformance is unused here.
                if imported { continue }
                if s.kindOf(conf.name) != nil {
                    s.diags.error("'\(conf.name)' is not an interface; '\(typeName)' can only conform to interfaces", at: conf.span)
                } else {
                    s.diags.error("unknown interface '\(conf.name)'", at: conf.span)
                }
                continue
            }
            // Conforming to a refining interface conforms to every base too, so a witness
            // exists for each (dedup so one isn't emitted twice, M5 A1.5). A constraint-only
            // (`Self`-mentioning) interface emits no witness (M5 A2) — it can't be `any I`, so
            // no table/instance is needed — but this is decided *per interface*: a constraint-
            // only refiner of an any-able base still needs the base's witness, so `any Base`
            // accepts the conformer. Its conformance is still checked below for correctness.
            for iface in [conf.name] + s.transitiveBases(conf.name) {
                // The conformance fact is recorded for every interface (incl. constraint-only),
                // so `some I` can verify its underlying (M5 A3).
                s.allConformsTo[typeName, default: []].insert(iface)
                if !generics.isEmpty { continue }
                // A witness is emitted only for an any-able (covariant-only-`Self`) interface;
                // a non-covariant-`Self` interface stays witness-less (M5 5.6).
                guard !s.hasNonCovariantSelf(iface) else { continue }
                s.conformsTo[typeName, default: []].insert(iface)
                if s.conformancePairs.insert("\(typeName):\(iface)").inserted {
                    s.conformanceList.append(NOIRConformance(typeName: typeName, typeKind: kind, interfaceName: iface))
                }
            }
            // Check the full (aggregated) requirement set, so inherited requirements count.
            for req in s.aggregatedMethods(conf.name) {
                checkMethodRequirement(&s, req, typeName: typeName, selfType: selfType, interface: conf, methods: methods)
            }
            for req in s.aggregatedProperties(conf.name) {
                checkPropertyRequirement(s, req, typeName: typeName, selfType: selfType, interface: conf, fields: fields, properties: properties)
            }
        }
    }

    // An actor conforms through its handlers: each requirement is a method with no result, satisfied by the handler
    // of the same name and parameter types, and a call through the interface sends the message (`interfaces.md` §2).
    // The arguments cross to the actor, so the requirement's parameter types must be shareable. A property, a result
    // and a static requirement have nothing on an actor to satisfy them, and an interface default would run as a
    // synchronous method, which an actor does not have.
    static func checkActorConformance(_ s: inout Sema, _ d: ActorDecl) {
        let selfType = Type.named(d.name, .actor_)
        for conf in d.conformances {
            guard s.interfaces[conf.name] != nil else {
                if s.kindOf(conf.name) != nil {
                    s.diags.error("'\(conf.name)' is not an interface; '\(d.name)' can only conform to interfaces", at: conf.span)
                } else {
                    s.diags.error("unknown interface '\(conf.name)'", at: conf.span)
                }
                continue
            }
            for iface in [conf.name] + s.transitiveBases(conf.name) {
                s.allConformsTo[d.name, default: []].insert(iface)
                guard !s.hasNonCovariantSelf(iface) else { continue }
                s.conformsTo[d.name, default: []].insert(iface)
                if s.conformancePairs.insert("\(d.name):\(iface)").inserted {
                    s.conformanceList.append(NOIRConformance(typeName: d.name, typeKind: .actor_, interfaceName: iface))
                }
            }
            let prefix = "actor '\(d.name)' cannot conform to '\(conf.name)'"
            for p in s.aggregatedProperties(conf.name) {
                s.diags.error("\(prefix): property '\(p.name)' needs a value from the actor, and an actor only receives messages", at: conf.span)
            }
            for req in s.aggregatedMethods(conf.name) {
                if req.isStatic {
                    s.diags.error("\(prefix): static method '\(req.name)' has no actor to send to", at: conf.span)
                    continue
                }
                if s.resolve(req.returnType, selfAs: selfType) != .void {
                    s.diags.error("\(prefix): method '\(req.name)' returns a value, and a handler returns none", at: conf.span)
                    continue
                }
                guard let h = d.handlers.first(where: { $0.name == req.name }) else {
                    let inherited = req.defaultBody != nil ? "; an actor implements each requirement as a handler, so it does not inherit the default" : ""
                    s.diags.error("type '\(d.name)' does not conform to '\(conf.name)': missing handler '\(req.name)'\(inherited)", at: conf.span)
                    continue
                }
                let reqTypes = req.params.map { s.resolve($0.type, selfAs: selfType) }
                guard reqTypes.count == h.params.count, zip(reqTypes, h.params).allSatisfy({ $0 == s.resolve($1.type) }) else {
                    s.diags.error("type '\(d.name)' does not conform to '\(conf.name)': handler '\(req.name)' has the wrong signature", at: conf.span)
                    continue
                }
                for (t, p) in zip(reqTypes, req.params) where !s.isShareable(t) {
                    s.diags.error("\(prefix): parameter '\(p.name)' of '\(req.name)' has type '\(t)', which is not shareable, so it cannot be sent to an actor", at: conf.span)
                }
            }
        }
    }

    // A method requirement is satisfied by a same-named method with matching parameter
    // types and return type, or (if none) by the interface's overridable default.
    static func checkMethodRequirement(_ s: inout Sema, _ req: InterfaceMethod, typeName: String, selfType: Type,
                                       interface conf: Conformance, methods: [FuncDecl]) {
        // A `static fun` requirement is satisfied by a `static fun` of the type; an instance
        // requirement by an instance method. The kinds never cross-satisfy.
        let named = methods.filter { $0.name == req.name && $0.isStatic == req.isStatic }
        if named.contains(where: { methodMatches(s, req, $0, selfAs: selfType) }) { return }
        if req.defaultBody != nil && !req.isStatic {
            // Satisfied by the interface's overridable default — this conformer inherits
            // it, so it is synthesized once as a method of the type (M5 A1.4); a generic type's on its template,
            // specialized with its other methods.
            if !(s.inheritedDefaults[typeName] ?? []).contains(where: { $0.name == req.name }) {
                s.inheritedDefaults[typeName, default: []].append(req)
            }
            return
        }
        let kindWord = req.isStatic ? "static method" : "method"
        if named.isEmpty {
            s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing \(kindWord) '\(req.name)'", at: conf.span)
        } else {
            s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': \(kindWord) '\(req.name)' has the wrong signature", at: conf.span)
        }
    }

    // A requirement's `Self` binds to the conformer's concrete type when matching, so
    // `fun clone() -> Self` is satisfied by `fun clone() -> Point` on `Point` (M5 A2). The
    // implementation is concrete, so its own signature never mentions `Self`.
    static func methodMatches(_ s: borrowing Sema, _ req: InterfaceMethod, _ impl: FuncDecl, selfAs: Type) -> Bool {
        guard req.params.count == impl.params.count else { return false }
        for (rp, ip) in zip(req.params, impl.params) where s.resolve(rp.type, selfAs: selfAs) != s.resolve(ip.type) { return false }
        return s.resolve(req.returnType, selfAs: selfAs) == s.resolve(impl.returnType)
    }

    // A property requirement is satisfied by a stored field or computed property of the
    // same name and type; a `{ get set }` requirement needs a settable member.
    static func checkPropertyRequirement(_ s: borrowing Sema, _ req: InterfacePropertyReq, typeName: String, selfType: Type, interface conf: Conformance, fields: [VarField], properties: [ComputedProperty]) {
        let reqType = s.resolve(req.type, selfAs: selfType)
        if let f = fields.first(where: { $0.name == req.name }) {
            if s.resolve(f.type) != reqType {
                s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(s.resolve(f.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && !f.isMutable {
                s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' must be a 'var' to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        if let p = properties.first(where: { $0.name == req.name }) {
            if s.resolve(p.type) != reqType {
                s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(s.resolve(p.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && p.setter == nil {
                s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': computed property '\(req.name)' needs a setter to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        s.diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing property '\(req.name)'", at: conf.span)
    }
}
