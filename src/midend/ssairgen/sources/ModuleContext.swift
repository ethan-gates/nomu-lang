import ast
import noir
import ssair
import support

// Type-layout tables the lowerer needs: field order/index for struct & class construction and field
// access, and enum case order for `enumInit`/match. Physical layout stays the egress's concern —
// SSAIR carries only logical field/case indices.
struct ModuleContext {
    let structFields: [String: [NOIRField]]
    let classFields: [String: [NOIRField]]
    let enumCases: [String: [NOIREnumCase]]
    let methodsByType: [String: [NOIRFunc]]   // struct/enum/class instance methods, by owning type
    let actorFields: [String: [NOIRActorField]]   // actor storage + per-field initializers
    let opaqueUnderlyings: [String: Type]     // `some I` owner → concrete underlying (static dispatch)
    let interfaceSlots: [String: Set<String>] // interface → its requirement slots (method / `prop.get` / `prop.set`)
    // Imported methods inferred mutating in their producing module, keyed `origin@Type.method` (task
    // 100.4.3.5.2). An imported method's body is stripped, so `methodsByType` lacks it; this carries its
    // mutating-ness from the `.nmi` so a call passes `self` by pointer, matching the producer's ABI.
    var externalMutatingMethods: Set<String> = []

    func fields(_ name: String, _ kind: NamedKind) -> [NOIRField]? {
        switch kind {
        case .struct_: return structFields[name]
        case .class_:  return classFields[name]
        case .actor_:  return actorFields[name]?.map { NOIRField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) }
        default:       return nil
        }
    }
    func fieldIndex(_ name: String, _ kind: NamedKind, _ field: String) -> Int? {
        fields(name, kind)?.firstIndex { $0.name == field }
    }
    func enumCaseIndex(_ name: String, _ caseName: String) -> Int? {
        enumCases[name]?.firstIndex { $0.name == caseName }
    }
    func method(_ type: String, _ name: String) -> NOIRFunc? {
        methodsByType[type]?.first { $0.name == name }
    }
    // Is `type.name` a mutating method? An own-module method answers from its inferred `isMutating`; an
    // imported one (body stripped, so absent from `methodsByType`) answers from the carried external set
    // (task 100.4.3.5.2) — both decide whether a call passes `self` by pointer.
    func methodIsMutating(_ type: String, _ name: String) -> Bool {
        if let m = method(type, name) { return m.isMutating }
        if externalMutatingMethods.contains("\(type).\(name)") { return true }
        // A generic instantiation (`origin@Box<Int>`) keys the carried set under its bare type name
        // (`origin@Box`): mutating-ness is a property of the generic method, not the instantiation, so the
        // driver records it once per type (task 100.4.3.10). This drives self-by-pointer for a mutating
        // erased method, so the erased `T`-field write lands in the caller's storage.
        let bare = String(type.prefix { $0 != "<" })
        return bare != type && externalMutatingMethods.contains("\(bare).\(name)")
    }
    // The mangled call name / SSAFunction name for a type method (matches the backend's callable key).
    static func methodSymbol(_ type: String, _ name: String) -> String { "m:\(type):\(name)" }

    // Which interface of a composition declares `method` (the owning sub-table to dispatch through).
    func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        ifaces.first { interfaceSlots[$0]?.contains(method) ?? false } ?? ifaces.first ?? "?"
    }

    // Whether `iface` declares a requirement named `method` (task 100.4.3.3.3): picks the bound of a
    // type parameter that a requirement call on a `.typeParam` receiver dispatches through.
    func interfaceDeclares(_ iface: String, _ method: String) -> Bool {
        interfaceSlots[iface]?.contains(method) ?? false
    }
}
