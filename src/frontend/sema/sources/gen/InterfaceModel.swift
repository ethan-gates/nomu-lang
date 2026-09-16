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
        for decl in s.program.decls {
            guard case .interfaceDecl(let i) = decl else { continue }
            // A non-covariant-`Self` (constraint-only) interface can't be `any I`, so it gets no
            // witness table. A covariant-only interface *does* — each `-> Self` requirement's slot
            // is **erased to `any I`** (`selfAs: .existential`), so the slot has a uniform concrete
            // representation (`AnyBox`); the thunk re-boxes the concrete result (M5 5.6).
            if s.isConstraintOnly(i.name) { continue }
            let selfErased = Type.existential(i.name)
            // Aggregated (flattened) surface: the witness table carries inherited slots too.
            let methods = s.aggregatedMethods(i.name).map { NOIRMethodReq(name: $0.name, params: $0.params.map { s.resolve($0.type, selfAs: selfErased) }, ret: s.resolve($0.returnType, selfAs: selfErased)) }
            let props = s.aggregatedProperties(i.name).map { NOIRPropReq(name: $0.name, type: s.resolve($0.type, selfAs: selfErased), isSettable: $0.isSettable) }
            // Only any-able bases carry a witness, so only they get a base pointer (M5 A1.4 upcast).
            let bases = s.transitiveBases(i.name).filter { !s.isConstraintOnly($0) }.sorted()
            out.append(NOIRInterface(name: i.name, methods: methods, properties: props, bases: bases))
        }
        return out
    }

    // Synthesize a concrete method on `T` for each defaulted requirement it inherits: the
    // default body lowered with `self: T`, so both concrete calls and witness slots resolve
    // to it (M5 A1.4). First cut: a default may reference directly-implemented requirements
    // (via `self.req()`) and stored-field state (bare name); default-calling-default and
    // computed-backed bare access are later work.
    static func lowerInheritedDefaults(_ s: inout Sema, _ typeName: String, selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        for req in s.inheritedDefaults[typeName] ?? [] {
            guard let body = req.defaultBody else { continue }
            // A default is synthesized as a concrete method of the conformer, so `Self` binds
            // to the conformer's concrete type here (M5 A2).
            let params = req.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type, selfAs: selfType), span: $0.span) }
            let ret = s.resolve(req.returnType, selfAs: selfType)
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
    // by a matching member (or an interface default). Struct/enum/class only — actor
    // conformance is parked post-M5 (interfaces.md §1). No witnesses yet (A1.4).
    static func checkConformances(_ s: inout Sema) {
        for decl in s.program.decls {
            // A generic type's conformance is checked when it is lowered (5.2.3), not here.
            if s.isGenericType(decl) { continue }
            switch decl {
            case .structDecl(let d):
                checkConformance(&s, d.name, .struct_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties)
            case .enumDecl(let d):
                checkConformance(&s, d.name, .enum_, d.conformances, methods: d.methods, fields: [], properties: d.properties)
            case .classDecl(let d):
                checkConformance(&s, d.name, .class_, d.conformances, methods: d.methods, fields: d.fields, properties: d.properties)
            case .actorDecl(let d):
                for conf in d.conformances {
                    s.diags.error("actors cannot conform to interfaces yet ('\(d.name): \(conf.name)') — parked post-M5", at: conf.span)
                }
            default:
                break
            }
        }
    }

    static func checkConformance(_ s: inout Sema, _ typeName: String, _ kind: NamedKind, _ conformances: [Conformance],
                                 methods: [FuncDecl], fields: [VarField], properties: [ComputedProperty]) {
        for conf in conformances {
            guard s.interfaces[conf.name] != nil else {
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
                // A witness is emitted only for an any-able (covariant-only-`Self`) interface;
                // a non-covariant-`Self` interface stays witness-less (M5 5.6).
                guard !s.hasNonCovariantSelf(iface) else { continue }
                s.conformsTo[typeName, default: []].insert(iface)
                if s.conformancePairs.insert("\(typeName):\(iface)").inserted {
                    s.conformanceList.append(NOIRConformance(typeName: typeName, typeKind: kind, interfaceName: iface))
                }
            }
            // Check the full (aggregated) requirement set, so inherited requirements count.
            for req in s.aggregatedMethods(conf.name) { checkMethodRequirement(&s, req, typeName: typeName, kind: kind, interface: conf, methods: methods) }
            for req in s.aggregatedProperties(conf.name) { checkPropertyRequirement(s, req, typeName: typeName, kind: kind, interface: conf, fields: fields, properties: properties) }
        }
    }

    // A method requirement is satisfied by a same-named method with matching parameter
    // types and return type, or (if none) by the interface's overridable default.
    static func checkMethodRequirement(_ s: inout Sema, _ req: InterfaceMethod, typeName: String, kind: NamedKind, interface conf: Conformance, methods: [FuncDecl]) {
        let selfType = Type.named(typeName, kind)
        // A `static fun` requirement is satisfied by a `static fun` of the type; an instance
        // requirement by an instance method. The kinds never cross-satisfy.
        let named = methods.filter { $0.name == req.name && $0.isStatic == req.isStatic }
        if named.contains(where: { methodMatches(s, req, $0, selfAs: selfType) }) { return }
        if req.defaultBody != nil && !req.isStatic {
            // Satisfied by the interface's overridable default — this conformer inherits
            // it, so it is synthesized once as a concrete method of the type (M5 A1.4).
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
    static func checkPropertyRequirement(_ s: borrowing Sema, _ req: InterfacePropertyReq, typeName: String, kind: NamedKind, interface conf: Conformance, fields: [VarField], properties: [ComputedProperty]) {
        let reqType = s.resolve(req.type, selfAs: .named(typeName, kind))
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
