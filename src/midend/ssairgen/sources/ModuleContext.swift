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
    // The mangled call name / SSAFunction name for a type method (matches the backend's callable key).
    static func methodSymbol(_ type: String, _ name: String) -> String { "m:\(type):\(name)" }

    // Which interface of a composition declares `method` (the owning sub-table to dispatch through).
    func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        ifaces.first { interfaceSlots[$0]?.contains(method) ?? false } ?? ifaces.first ?? "?"
    }
}
