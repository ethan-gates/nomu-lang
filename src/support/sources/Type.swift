// The semantic type model — what a `TypeRef` (syntax) resolves to (design: noir.md).
// Replaces the string-typing the codegen used to carry in `typeOf` / `Scope`.

public enum NamedKind: Equatable, Codable {
    case struct_, enum_, class_, actor_
    case interface_   // M5 A1: the type of `self` inside an interface default body
}

public indirect enum Type: Equatable, Codable {
    case int
    case uint8    // an 8-bit unsigned byte; wrapping arithmetic, unsigned compares/shifts (i8)
    case uint64   // a 64-bit unsigned word; wrapping arithmetic, unsigned compares/shifts (i64)
    case double
    case bool
    case stringBase
    case void
    case named(String, NamedKind)                 // struct / enum / class / actor
    case existential(String)                       // `any I` — a boxed value conforming to interface I (M5 A1.4)
    case composition([String])                     // `any A & B` — conforms to several interfaces (canonical, M5 A1.5b)
    case selfType                                  // `Self` in an interface requirement (M5 A2); constraint-only, never reaches codegen
    case opaque(interfaces: [String], owner: String)  // `some I` / `some A & B` — one hidden concrete underlying (M5 A3). `owner` gives per-function/binding identity (Swift-style); the underlying is looked up in NOIRModule.opaqueUnderlyings. Unboxed, statically dispatched.
    case typeParam(String)                          // a generic type parameter `T` in scope (M5 5.2.1)
    case generic(base: String, args: [Type])        // an applied generic type `Box<Int>` (M5 5.2.1)
    case array(Type)                                // `Array<T>` — a builtin variable-size reference type (M6 stdlib). Reference semantics (a managed handle); the element `T` is monomorphized like any other generic argument.
    case rawPtr                                     // `RawPtr` — an untyped, byte-addressable unmanaged (addrspace 0) address (task 125). A value type holding one raw word; never a GC root.
    case ptr(Type)                                  // `Ptr<T>` — a typed unmanaged (addrspace 0) pointer to `T`; `T` gives the element stride + load/store type (task 125). A value type; never a GC root.
    case function(params: [Type], ret: Type)       // closures and named functions share this
    case error                                     // unresolved / failed typing; suppresses cascades
}

extension Type: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int:    return "Int"
        case .uint8:  return "UInt8"
        case .uint64: return "UInt64"
        case .double: return "Double"
        case .bool:   return "Bool"
        case .stringBase: return "String"
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
        case .rawPtr:          return "RawPtr"
        case .ptr(let elem):   return "Ptr<\(elem)>"
        case .function(let params, let ret):
            return "(" + params.map(\.description).joined(separator: ", ") + ") -> \(ret)"
        }
    }
}

// The signature of an imported generic function (task 100.4.3.4; ABI in internals/backend.md §4): its
// type-parameter names in declaration order, the interface bounds per type parameter (parallel to
// `generics`), its (possibly `.typeParam`-carrying) parameter types, and its return type. A consumer
// emits a call through the erased witness-passing ABI — a VWT pointer per type parameter, then a PWT
// pointer per (type parameter, bound) with bounds in sorted order, then a result buffer when the return
// mentions a type parameter, then the value parameters (a `.typeParam` one passed by buffer pointer).
public struct ExternalGenericSig {
    public let generics: [String]
    public let bounds: [[String]]
    public let params: [Type]
    public let ret: Type
    public init(generics: [String], bounds: [[String]], params: [Type], ret: Type) {
        self.generics = generics; self.bounds = bounds; self.params = params; self.ret = ret
    }
    public var bounded: Bool { bounds.contains { !$0.isEmpty } }
}

extension Type {
    // The name of a generic type's specialization: `base<argKey,argKey>`, carried as a nominal name; Mangle
    // 9-encodes the `<`, `>`, `,` (backend.md) into a valid C identifier. `Monomorphize` names its specializations
    // so, and codegen finds a concrete instance in an imported signature by it.
    public static func specializedName(_ base: String, _ args: [Type]) -> String {
        args.isEmpty ? base : base + "<" + args.map(\.specializationKey).joined(separator: ",") + ">"
    }

    // A mangling-safe key for a type argument. Named types may already carry `<…>` from a
    // prior specialization (nesting composes); function/existential/opaque types get an
    // identifier-ish rendering rather than their spaced `description`.
    public var specializationKey: String {
        switch self {
        case .int: return "Int"
        case .uint8: return "UInt8"
        case .uint64: return "UInt64"
        case .double: return "Double"
        case .bool: return "Bool"
        case .stringBase: return "String"
        case .void: return "Void"
        case .named(let n, _): return n
        case .generic(let b, let a): return Type.specializedName(b, a)
        case .array(let e): return "Array<" + e.specializationKey + ">"
        case .rawPtr: return "RawPtr"
        case .ptr(let e): return "Ptr<" + e.specializationKey + ">"
        case .function(let p, let r): return "fn<" + (p + [r]).map(\.specializationKey).joined(separator: ",") + ">"
        case .existential(let i): return "any_" + i
        case .composition(let is_): return "any_" + is_.joined(separator: "_")
        case .opaque(let ifs, _): return "some_" + ifs.joined(separator: "_")
        case .typeParam(let p): return p
        case .selfType: return "Self"
        case .error: return "error"
        }
    }

    // Whether a type parameter occurs anywhere in this type.
    // Whether this is, or holds, the error type.
    public var mentionsError: Bool {
        switch self {
        case .error: return true
        case .generic(_, let args): return args.contains { $0.mentionsError }
        case .array(let e), .ptr(let e): return e.mentionsError
        case .function(let ps, let r): return r.mentionsError || ps.contains { $0.mentionsError }
        default: return false
        }
    }

    // `Self` anywhere in the type, as an interface requirement spells it.
    public var mentionsSelf: Bool {
        switch self {
        case .selfType: return true
        case .generic(_, let args): return args.contains { $0.mentionsSelf }
        case .array(let e), .ptr(let e): return e.mentionsSelf
        case .function(let ps, let r): return r.mentionsSelf || ps.contains { $0.mentionsSelf }
        default: return false
        }
    }

    // The type with each `Self` replaced by `t`.
    public func replacingSelf(with t: Type) -> Type {
        switch self {
        case .selfType: return t
        case .generic(let base, let args): return .generic(base: base, args: args.map { $0.replacingSelf(with: t) })
        case .array(let e): return .array(e.replacingSelf(with: t))
        case .ptr(let e): return .ptr(e.replacingSelf(with: t))
        case .function(let ps, let r): return .function(params: ps.map { $0.replacingSelf(with: t) }, ret: r.replacingSelf(with: t))
        default: return self
        }
    }

    public var mentionsTypeParameter: Bool {
        switch self {
        case .typeParam: return true
        case .generic(_, let args): return args.contains { $0.mentionsTypeParameter }
        case .array(let e), .ptr(let e): return e.mentionsTypeParameter
        case .function(let ps, let r): return r.mentionsTypeParameter || ps.contains { $0.mentionsTypeParameter }
        default: return false
        }
    }
}
