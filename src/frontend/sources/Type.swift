// The semantic type model — what a `TypeRef` (syntax) resolves to (design: compiler.md §1).
// Replaces the string-typing the codegen used to carry in `typeOf` / `Scope`.

public enum NamedKind: Equatable {
    case struct_, enum_, class_, actor_
    case interface_   // M5 A1: the type of `self` inside an interface default body
}

public indirect enum Type: Equatable {
    case int
    case bool
    case string
    case void
    case named(String, NamedKind)                 // struct / enum / class / actor
    case existential(String)                       // `any I` — a boxed value conforming to interface I (M5 A1.4)
    case composition([String])                     // `any A & B` — conforms to several interfaces (canonical, M5 A1.5b)
    case function(params: [Type], ret: Type)       // closures and named functions share this
    case error                                     // unresolved / failed typing; suppresses cascades

    // Extension points for M5: `.typeParam`, `.opaque`, `.generic`.
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
        case .existential(let name): return "any \(name)"
        case .composition(let names): return "any " + names.joined(separator: " & ")
        case .function(let params, let ret):
            return "(" + params.map(\.description).joined(separator: ", ") + ") -> \(ret)"
        }
    }
}
