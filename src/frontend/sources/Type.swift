// The semantic type model — what a `TypeRef` (syntax) resolves to (design: compiler.md §1).
// Replaces the string-typing the codegen used to carry in `typeOf` / `Scope`.

public enum NamedKind: Equatable {
    case struct_, enum_, class_, actor_
    case interface_   // M5 A1: the type of `self` inside an interface default body
}

public indirect enum Type: Equatable {
    case int
    case double
    case bool
    case string
    case void
    case named(String, NamedKind)                 // struct / enum / class / actor
    case existential(String)                       // `any I` — a boxed value conforming to interface I (M5 A1.4)
    case composition([String])                     // `any A & B` — conforms to several interfaces (canonical, M5 A1.5b)
    case selfType                                  // `Self` in an interface requirement (M5 A2); constraint-only, never reaches codegen
    case opaque(interfaces: [String], owner: String)  // `some I` / `some A & B` — one hidden concrete underlying (M5 A3). `owner` gives per-function/binding identity (Swift-style); the underlying is looked up in NOIRModule.opaqueUnderlyings. Unboxed, statically dispatched.
    case typeParam(String)                          // a generic type parameter `T` in scope (M5 5.2.1)
    case generic(base: String, args: [Type])        // an applied generic type `Box<Int>` (M5 5.2.1)
    case array(Type)                                // `Array<T>` — a builtin variable-size reference type (M6 stdlib). Reference semantics (a managed handle); the element `T` is monomorphized like any other generic argument.
    case function(params: [Type], ret: Type)       // closures and named functions share this
    case error                                     // unresolved / failed typing; suppresses cascades
}

extension Type: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int:    return "Int"
        case .double: return "Double"
        case .bool:   return "Bool"
        case .string: return "String"
        case .void:   return "Void"
        case .error:  return "<error>"
        case .named(let name, _): return name
        case .existential(let name): return "any \(name)"
        case .composition(let names): return "any " + names.joined(separator: " & ")
        case .selfType: return "Self"
        case .opaque(let interfaces, _): return "some " + interfaces.joined(separator: " & ")
        case .typeParam(let n): return n
        case .generic(let base, let args): return base + "<" + args.map(\.description).joined(separator: ", ") + ">"
        case .array(let elem): return "Array<\(elem)>"
        case .function(let params, let ret):
            return "(" + params.map(\.description).joined(separator: ", ") + ") -> \(ret)"
        }
    }
}
