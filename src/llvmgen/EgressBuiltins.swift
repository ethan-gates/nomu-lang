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
            // Bit-stealing layout: `word0` is the buffer pointer (immortal/heap case), `word1`'s low 56
            // bits are the byte count; the tag is the top nibble (task 121). The small/inline case is not
            // produced yet (121.3), so pulling `(ptr, count)` from `word0`/`word1` covers every current value.
            let word0 = LLVMBuildExtractValue(g.b, value, 0, "word0")
            let word1 = LLVMBuildExtractValue(g.b, value, 1, "word1")
            // A `heap` String's `word0` is the StringStorage base; its bytes start past `{ header, cap }` at
            // offset 16. `immortal` (and the empty string) keep bytes at `word0` directly (task 176.2).
            let tag = LLVMBuildLShr(g.b, word1, LLVMConstInt(g.e.i64, 60, 0), "tag")
            let isHeap = LLVMBuildICmp(g.b, LLVMIntEQ, tag, LLVMConstInt(g.e.i64, 2, 0), "isheap")
            let heapW0 = LLVMBuildAdd(g.b, word0, LLVMConstInt(g.e.i64, 16, 0), "heapw0")
            let dataInt = LLVMBuildSelect(g.b, isHeap, heapW0, word0, "dataint")
            let data = LLVMBuildIntToPtr(g.b, dataInt, g.e.i8ptr, "data")
            let mask = LLVMConstInt(g.e.i64, 0x00FF_FFFF_FFFF_FFFF, 0)
            let len = LLVMBuildAnd(g.b, word1, mask, "len")
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

    // Concatenation produces a `heap` String (task 176.2): a managed `StringStorage` buffer the moving
    // collector relocates. The allocation is emitted here (not in C) so it rides the plan-aware, shaped-root
    // seam — a live `heap` String in the caller is recorded across it (`rtAllocManaged` picks the rooted
    // variant while `pendingDeopt` is set for this call). The two inputs are snapshotted off-heap *before* the
    // alloc (gc-leaf `rt_str_snapshot`), so a collection triggered by the alloc relocating them can't strand
    // the copy; `rt_str_fill` then blits the snapshot into the storage body. No managed allocation happens
    // between the alloc and the fill, so the fresh storage pointer is stable across the byte work.
    static func emitConcat(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else { g.e.fail("7.2.3: concat expects two arguments", span); return nil }
        let e = g.e, b = g.b
        let a = g.val(args[0]), c = g.val(args[1])
        let mask = LLVMConstInt(e.i64, 0x00FF_FFFF_FFFF_FFFF, 0)
        let alen = LLVMBuildAnd(b, LLVMBuildExtractValue(b, a, 1, "aw1"), mask, "alen")!
        let blen = LLVMBuildAnd(b, LLVMBuildExtractValue(b, c, 1, "bw1"), mask, "blen")!
        let len = LLVMBuildAdd(b, alen, blen, "len")!
        // Snapshot both inputs into one off-heap buffer before any managed allocation (gc-leaf).
        let (snapFn, snapTy) = e.runtimeFn("rt_str_snapshot", ret: e.i8ptr, params: [e.strTy, e.strTy], varArg: false)
        let snap = e.buildCall(snapFn, snapTy, [a, c])!
        // Managed StringStorage: `{ header, cap, bytes… }` = 16 + len bytes, via the rooted plan-aware seam.
        let size = LLVMBuildAdd(b, LLVMConstInt(e.i64, 16, 0), len, "sssize")!
        let ss = e.rtAllocManaged(size)
        let tidG = LLVMGetNamedGlobal(e.mod, "__nomu_stringstorage_typeid")
            ?? LLVMAddGlobal(e.mod, e.i64, "__nomu_stringstorage_typeid")
        LLVMBuildStore(b, LLVMBuildLoad2(b, e.i64, tidG, "ss.tid"), ss)                 // header at offset 0
        LLVMBuildStore(b, len, e.gepByte(ss, LLVMConstInt(e.i64, 8, 0)))                // cap (byte count) at 8
        let body = e.toUnmanaged(e.gepByte(ss, LLVMConstInt(e.i64, 16, 0)))             // bytes at 16
        let (fillFn, fillTy) = e.runtimeFn("rt_str_fill", ret: e.voidTy, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
        _ = e.buildCall(fillFn, fillTy, [body, snap, len])
        // Build the heap String value: word0 = storage base, word1 = (heap tag << 60) | byte count.
        let w0 = LLVMBuildPtrToInt(b, ss, e.i64, "ss.w0")!
        let w1 = LLVMBuildOr(b, LLVMConstInt(e.i64, UInt64(2) << 60, 0), len, "ss.w1")!
        var result = LLVMGetUndef(e.strTy)
        result = LLVMBuildInsertValue(b, result, w0, 0, "s0")!
        result = LLVMBuildInsertValue(b, result, w1, 1, "s1")!
        return result
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
        case .uint8:  return g.e.i8    // a UInt8 builtin result/arg is one byte (e.g. `byte(at:)`)
        default:      return g.e.i64
        }
    }
}
