import sema
import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// SSAIR→LLVM egress — builtin emission over already-lowered operands: `print`/`putByte`/`concat`/
// `sleep`/`readLine`/`time_monotonic` and the generic C-leaf shim (`Builtins.cLeaf`). A capability
// namespace over the `SSAIRToLLVM` reference: the shared emitter is reached as `g.e`, operands as
// `g.val(...)`, the builder as `g.b`.
enum EgressBuiltins {

    static func emitPrint(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { g.e.fail("7.2.3: print expects one argument", span); return nil }
        let value = g.val(arg)
        let (fn, pty) = g.e.runtimeFn("printf", ret: g.e.i32, params: [g.e.i8ptr], varArg: true)
        switch arg.type {
        case .int:
            return g.e.buildCall(fn, pty, [g.e.intFormat(), value])
        case .double:
            let (pf, pfty) = g.e.runtimeFn("rt_print_double", ret: g.e.voidTy, params: [g.e.f64], varArg: false)
            return g.e.buildCall(pf, pfty, [value])
        case .uint8:
            return g.e.buildCall(fn, pty, [g.e.intFormat(), LLVMBuildZExt(g.b, value, g.e.i64, "u82i")])
        case .uint64:
            return g.e.buildCall(fn, pty, [g.e.uintFormat(), value])
        case .bool:
            return g.e.buildCall(fn, pty, [g.e.intFormat(), LLVMBuildZExt(g.b, value, g.e.i64, "b2i")])
        case .string:
            let data = LLVMBuildExtractValue(g.b, value, 0, "data")
            let len = LLVMBuildExtractValue(g.b, value, 1, "len")
            let len32 = LLVMBuildTrunc(g.b, len, g.e.i32, "len32")
            return g.e.buildCall(fn, pty, [g.e.strFormat(), len32, data])
        default:
            g.e.fail("7.2.3: print supports Int, UInt8, Double, Bool, or String", span); return nil
        }
    }

    // putByte(b): write one raw byte to stdout via libc `putchar`. Output is libc-buffered (block- or
    // line-buffered) and flushed on normal program exit; no explicit flush primitive is exposed.
    static func emitPutByte(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { g.e.fail("putByte expects one argument", span); return nil }
        let (fn, fty) = g.e.runtimeFn("putchar", ret: g.e.i32, params: [g.e.i32], varArg: false)
        let c = LLVMBuildZExt(g.b, g.val(arg), g.e.i32, "byte")
        return g.e.buildCall(fn, fty, [c])
    }

    static func emitTimeMonotonic(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        let (fn, pty) = g.e.runtimeFn("__void_timemonotonic_int", ret: g.e.i64, params: [], varArg: false)
        return g.e.buildCall(fn, pty, [])
    }

    static func emitConcat(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else { g.e.fail("7.2.3: concat expects two arguments", span); return nil }
        let (fn, fty) = g.e.runtimeFn("rt_str_concat", ret: g.e.strTy, params: [g.e.strTy, g.e.strTy], varArg: false)
        return g.e.buildCall(fn, fty, [g.val(args[0]), g.val(args[1])])
    }

    static func emitSleep(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { g.e.fail("7.2.3: sleep expects one argument", span); return nil }
        let (fn, fty) = g.e.runtimeFn("rt_sleep_ms", ret: g.e.i64, params: [g.e.i64], varArg: false)
        return g.e.buildCall(fn, fty, [g.val(arg)])
    }

    static func emitReadLine(_ g: SSAIRToLLVM) -> LLVMValueRef? {
        let (fn, fty) = g.e.runtimeFn("rt_read_line", ret: g.e.strTy, params: [g.e.i32], varArg: false)
        return g.e.buildCall(fn, fty, [LLVMConstInt(g.e.i32, 0, 0)])
    }

    static func emitCLeaf(_ g: SSAIRToLLVM, _ name: String, _ args: [SSAValue]) -> LLVMValueRef? {
        let sig = Builtins.signature(name)
        let paramTys = ([sig.receiver] + sig.params).map { cType(g, $0) }
        let retIsBool = sig.ret == .bool
        let retTy = retIsBool ? g.e.i64 : cType(g, sig.ret)
        let (fn, fty) = g.e.runtimeFn(name, ret: retTy, params: paramTys, varArg: false)
        guard let r = g.e.buildCall(fn, fty, args.map { g.val($0) }) else { return nil }
        return retIsBool ? LLVMBuildTrunc(g.b, r, g.e.i1, "b") : r
    }

    static func cType(_ g: SSAIRToLLVM, _ t: Type) -> LLVMTypeRef {
        switch t {
        case .string: return g.e.strTy
        case .double: return g.e.f64
        case .bool:   return g.e.i1
        default:      return g.e.i64
        }
    }
}
