// The semantic type model — what a `TypeRef` (syntax) resolves to (m4.9-spec.md §3).
// Replaces the string-typing the codegen used to carry in `typeOf` / `Scope`.

public enum NamedKind: Equatable {
    case struct_, enum_, class_, actor_
}

public indirect enum Type: Equatable {
    case int
    case bool
    case string
    case void
    case named(String, NamedKind)                 // struct / enum / class / actor
    case function(params: [Type], ret: Type)       // closures and named functions share this
    case error                                     // unresolved / failed typing; suppresses cascades

    // Extension points for M5: `.typeParam`, `.existential`, `.opaque`, `.generic`.
}

extension Type: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int:    return "Int"
        case .bool:   return "Bool"
        case .string: return "String"
        case .void:   return "Void"
        case .error:  return "<error>"
        case .named(let name, _): return name
        case .function(let params, let ret):
            return "(" + params.map(\.description).joined(separator: ", ") + ") -> \(ret)"
        }
    }
}
