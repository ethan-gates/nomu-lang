import noir
import support
// Builtins registry + NOIR construction.
//
// A C-backed builtin's mangled name encodes everything about it and is *also* the C symbol name:
//
//     __<receiver>_<name>_<return>[_<arg>...]
//
// e.g. `__string_count_int` = receiver `String`, member `count`, returns `Int`, no args (a trailing
// `_<arg>…` would name each argument type). The C function has the same name. Because the name carries the
// full signature, both Sema (build the typed call) and codegen (emit the extern call) derive types from it
// instead of hand-writing a case per builtin.

// The signature parsed out of a mangled name: the receiver type, the member name, argument types
// (receiver excluded), and the return type.
public struct BuiltinSig {
    public let receiver: Type
    public let name: String
    public let params: [Type]      // arguments only (receiver not included)
    public let ret: Type
    public let mangled: String
}

public enum Builtins {
    // Builtins whose mangled name is a same-named C leaf function (pure, no GC allocation, no safepoint),
    // dispatched generically to an extern C call in codegen. Currently empty: the former string entries
    // (`__string_count_int`, `__string_bytepointer_rawptr`) are lowered codegen-native (`strLen`/`strPtr` in
    // `SSAIRToLLVM`), so no builtin routes through the C floor. The facility stays for any future C-leaf op.
    public static let cLeaf: Set<String> = []

    // Parse `__<recv>_<name>_<ret>[_<arg>...]`. `split` drops the leading empties from `__`.
    public static func signature(_ mangled: String) -> BuiltinSig {
        let t = mangled.split(separator: "_")
        let receiver = Type.fromLowerCase(t[0])
        let name = String(t[1])
        let ret = Type.fromLowerCase(t[2])
        let params = t.dropFirst(3).map { Type.fromLowerCase($0) }
        return BuiltinSig(receiver: receiver, name: name, params: params, ret: ret, mangled: mangled)
    }
}

// A namespace for building NomuIR (NOIR) for builtins.
struct BuiltinsSema {
    /// A zero-argument member builtin, e.g. `i.double` or a bare `StringBase`'s `count`. `base` is the receiver.
    static func member(_ mangled: String, _ base: NOIRExpr, _ span: Span) -> NOIRExpr {
        call(mangled, base, [], span)
    }

    /// A method builtin with arguments, e.g. `"a".eq("b")`. The receiver is passed as the first
    /// call argument, then `args`. The return type is read from the mangled name. Arg count/types
    /// are checked by the caller (which holds the diagnostic sink).
    static func method(_ mangled: String, _ base: NOIRExpr, _ args: [NOIRExpr], _ span: Span) -> NOIRExpr {
        call(mangled, base, args, span)
    }

    private static func call(_ mangled: String, _ base: NOIRExpr, _ args: [NOIRExpr], _ span: Span) -> NOIRExpr {
        let sig = Builtins.signature(mangled)
        let callee = NOIRExpr(type: .void, span: span, kind: .varRef(mangled))
        let callArgs = ([base] + args).map { NOIRArg(label: nil, value: $0) }
        return NOIRExpr(type: sig.ret, span: span, kind: .call(callee: callee, args: callArgs, typeArgs: []))
    }
}

extension Type {
    static func fromLowerCase(_ type: Substring) -> Type {
        switch type {
        case "void":   return .void
        case "int":    return .int
        case "uint8":  return .uint8
        case "uint64": return .uint64
        case "double": return .double
        case "bool":   return .bool
        case "string": return .stringBase
        case "rawptr": return .rawPtr
        default:       return .error
        }
    }
}
