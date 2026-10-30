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
            let (pf, pfty) = printDoubleFn(g.e)
            let call = g.e.buildCall(pf, pfty, [value])!
            g.e.markCallGCLeaf(call)
            return call
        case .uint8:
            return g.e.buildCall(fn, pty, [g.e.intFormat(), LLVMBuildZExt(g.b, value, g.e.i64, "u82i")])
        case .uint64:
            return g.e.buildCall(fn, pty, [g.e.uintFormat(), value])
        case .bool:
            return g.e.buildCall(fn, pty, [g.e.intFormat(), LLVMBuildZExt(g.b, value, g.e.i64, "b2i")])
        case .stringBase:
            // Print the UTF-8 bytes through `%.*s`, reading the tag-aware address and byte count off the
            // bit-stealing layout — the same two StringBase ops the byte layer uses (task 121).
            let data = g.strPtr(value)
            let len32 = LLVMBuildTrunc(g.b, g.strLen(value), g.e.i32, "len32")
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

    // `__nomu_print_double(x)`, built once per module: print a Double with the fewest significant digits
    // that read back to the same value, always with a decimal point (`42.0`, never `42`), then a newline.
    // `snprintf("%.*g")` at precision 1, 2, … until `strtod` returns `x` (17 always does); `.0` is appended
    // when the result has no '.', exponent, or inf/nan letter; out through `printf`, as every `print` is.
    // Shortest round-trip formatting in Nomu is task 227. No GC strategy: it never allocates or parks.
    static func printDoubleFn(_ e: LLVMGen) -> (LLVMValueRef, LLVMTypeRef) {
        let ty = e.fnType(e.voidTy, [e.f64])
        if let f = LLVMGetNamedFunction(e.mod, "__nomu_print_double") { return (f, ty) }
        let b = e.b
        let fn = LLVMAddFunction(e.mod, "__nomu_print_double", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        let i32 = LLVMInt32TypeInContext(e.ctx)!
        let snprintf = e.runtimeFn("snprintf", ret: i32, params: [e.i8ptr, e.i64, e.i8ptr], varArg: true)
        let strtod = e.runtimeFn("strtod", ret: e.f64, params: [e.i8ptr, e.i8ptr], varArg: false)
        let strpbrk = e.runtimeFn("strpbrk", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr], varArg: false)
        let strlen = e.runtimeFn("strlen", ret: e.i64, params: [e.i8ptr], varArg: false)
        let printf = e.runtimeFn("printf", ret: i32, params: [e.i8ptr], varArg: true)
        e.withStubBody(fn) {
            let x = LLVMGetParam(fn, 0)!
            let bufTy = LLVMArrayType2(e.i8, 32)!
            let buf = LLVMBuildAlloca(b, bufTy, "buf")!
            let gFmt = LLVMBuildGlobalStringPtr(b, "%.*g", "fmt_g")!
            let marks = LLVMBuildGlobalStringPtr(b, ".eEnN", "fmt_g_marks")!
            let line = LLVMBuildGlobalStringPtr(b, "%s\n", "fmt_line")!
            let entry = LLVMGetInsertBlock(b)!
            let loop = LLVMAppendBasicBlockInContext(e.ctx, fn, "prec.try")!
            let next = LLVMAppendBasicBlockInContext(e.ctx, fn, "prec.next")!
            let widest = LLVMAppendBasicBlockInContext(e.ctx, fn, "prec.17")!
            let check = LLVMAppendBasicBlockInContext(e.ctx, fn, "point.check")!
            let append = LLVMAppendBasicBlockInContext(e.ctx, fn, "point.append")!
            let out = LLVMAppendBasicBlockInContext(e.ctx, fn, "out")!
            let format: (LLVMValueRef) -> Void = { prec in
                _ = e.buildCall(snprintf.0, snprintf.1, [buf, LLVMConstInt(e.i64, 32, 0), gFmt, prec, x])
            }
            LLVMBuildBr(b, loop)

            // Try precisions 1 through 16; the first that reads back exactly is the shortest.
            LLVMPositionBuilderAtEnd(b, loop)
            let prec = LLVMBuildPhi(b, i32, "prec")!
            format(prec)
            let back = e.buildCall(strtod.0, strtod.1, [buf, LLVMConstNull(e.i8ptr)])!
            let exact = LLVMBuildFCmp(b, LLVMRealOEQ, back, x, "exact")
            LLVMBuildCondBr(b, exact, check, next)
            LLVMPositionBuilderAtEnd(b, next)
            let prec1 = LLVMBuildAdd(b, prec, LLVMConstInt(i32, 1, 0), "prec.1")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntSLT, prec1, LLVMConstInt(i32, 17, 0), "prec.more"), loop, widest)
            var incoming: [LLVMValueRef?] = [LLVMConstInt(i32, 1, 0), prec1]
            var blocks: [LLVMBasicBlockRef?] = [entry, next]
            LLVMAddIncoming(prec, &incoming, &blocks, 2)

            // 17 significant digits round-trip any double.
            LLVMPositionBuilderAtEnd(b, widest)
            format(LLVMConstInt(i32, 17, 0))
            LLVMBuildBr(b, check)

            LLVMPositionBuilderAtEnd(b, check)
            let mark = e.buildCall(strpbrk.0, strpbrk.1, [buf, marks])!
            LLVMBuildCondBr(b, LLVMBuildIsNull(b, mark, "integral"), append, out)
            LLVMPositionBuilderAtEnd(b, append)
            let n = e.buildCall(strlen.0, strlen.1, [buf])!
            LLVMBuildStore(b, LLVMConstInt(e.i8, 46, 0), e.gepByte(buf, n))   // '.'
            LLVMBuildStore(b, LLVMConstInt(e.i8, 48, 0),
                           e.gepByte(buf, LLVMBuildAdd(b, n, LLVMConstInt(e.i64, 1, 0), "n.1")!))   // '0'
            LLVMBuildStore(b, LLVMConstInt(e.i8, 0, 0),
                           e.gepByte(buf, LLVMBuildAdd(b, n, LLVMConstInt(e.i64, 2, 0), "n.2")!))
            LLVMBuildBr(b, out)

            LLVMPositionBuilderAtEnd(b, out)
            _ = e.buildCall(printf.0, printf.1, [line, buf])
            LLVMBuildRetVoid(b)
        }
        return (fn, ty)
    }

    static func emitTimeMonotonic(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        // `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, as `Runtime.monotonicNanos` lowers.
        let (fn, fty) = g.e.runtimeFn("clock_gettime_nsec_np", ret: g.e.i64, params: [g.e.i32], varArg: false)
        return g.e.buildCall(fn, fty, [LLVMConstInt(g.e.i32, 6, 0)])
    }

    static func emitSleep(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { g.e.fail("7.2.3: sleep expects one argument", span); return nil }
        let (fn, fty) = g.e.nomuSleepMs()
        return g.e.buildCall(fn, fty, [g.val(arg)])
    }

    static func emitReadLine(_ g: SSAIRToLLVM) -> LLVMValueRef? {
        let (fn, fty) = readLineFn(g)
        return g.e.buildCall(fn, fty, [])
    }

    // `__nomu_read_line() -> StringBase`, built once per module: the runtime's `rtReadLine`, reached through a
    // parking forwarder (it may park the fiber until stdin has input), returns a raw block holding the line's
    // byte count at 0 and its bytes at 8. This function copies the line into a `small` value (15 bytes or
    // fewer) or a fresh `heap` buffer, frees the block, and returns the string. It is a GC frame: the
    // forwarder's anchor is a statepoint here, and the walk continues to the `readLine` caller. Nothing
    // managed is live across its calls, and after the heap allocation only gc-leaf calls follow (memcpy,
    // free), so the fresh buffer stays put until it is returned.
    static func readLineFn(_ g: SSAIRToLLVM) -> (LLVMValueRef, LLVMTypeRef) {
        let e = g.e, b = g.b
        let ty = e.fnType(e.strTy, [])
        if let f = LLVMGetNamedFunction(e.mod, "__nomu_read_line") { return (f, ty) }
        let target = e.runtimePreludeFn("rtReadLine", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64])
        let park = e.schedForwarder("__nomu_read_line_park", ret: e.i8ptr, params: []) { _, sched, sp, pc in
            e.buildCall(target.fn, target.ty, [sched, sp, pc])
        }
        let fn = LLVMAddFunction(e.mod, "__nomu_read_line", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")
        e.addNoInline(fn)
        let savedFn = e.currentFn, savedDeopt = e.pendingDeopt
        e.currentFn = fn
        e.pendingDeopt = nil
        e.withStubBody(fn) {
            let slot = LLVMBuildAlloca(b, e.strTy, "small.build")!
            let block = e.buildCall(park.0, park.1, [])!
            let n = LLVMBuildLoad2(b, e.i64, block, "line.n")!
            let src = e.gepByte(block, LLVMConstInt(e.i64, 8, 0))
            let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
            let (free, freeTy) = e.runtimeFn("free", ret: e.voidTy, params: [e.i8ptr], varArg: false)
            let smallBB = LLVMAppendBasicBlockInContext(e.ctx, fn, "line.small")!
            let heapBB = LLVMAppendBasicBlockInContext(e.ctx, fn, "line.heap")!
            let fits = LLVMBuildICmp(b, LLVMIntSLE, n, LLVMConstInt(e.i64, 15, 0), "line.fits")
            LLVMBuildCondBr(b, fits, smallBB, heapBB)

            // `small`: the bytes inline, zero-padded, with the count in byte 15 (tag 0).
            LLVMPositionBuilderAtEnd(b, smallBB)
            LLVMBuildStore(b, LLVMConstNull(e.strTy), slot)
            _ = e.buildCall(memcpy, mty, [slot, src, n])
            LLVMBuildStore(b, LLVMBuildTrunc(b, n, e.i8, "small.b15")!, e.gepByte(slot, LLVMConstInt(e.i64, 15, 0)))
            let small = LLVMBuildLoad2(b, e.strTy, slot, "small.val")!
            _ = e.buildCall(free, freeTy, [block])
            LLVMBuildRet(b, small)

            // `heap`: a fresh `ManagedBuffer<EmptyHeader, UInt8>`, its bytes at 16, as `__stringAllocHeap` builds.
            LLVMPositionBuilderAtEnd(b, heapBB)
            let buf = g.emitManagedBufferAlloc(header: .named("EmptyHeader", .struct_), element: .uint8, capacity: n)
            let w0 = LLVMBuildPtrToInt(b, buf, e.i64, "sb.w0")!
            let dst = LLVMBuildIntToPtr(b, LLVMBuildAdd(b, w0, LLVMConstInt(e.i64, 16, 0), "sb.data.i")!, e.i8ptr,
                                        "sb.data")!
            _ = e.buildCall(memcpy, mty, [dst, src, n])
            _ = e.buildCall(free, freeTy, [block])
            let w1 = LLVMBuildOr(b, LLVMConstInt(e.i64, UInt64(2) << 60, 0), n, "sb.w1")!
            var sb = LLVMGetUndef(e.strTy)
            sb = LLVMBuildInsertValue(b, sb, w0, 0, "sb0")!
            sb = LLVMBuildInsertValue(b, sb, w1, 1, "sb1")!
            LLVMBuildRet(b, sb)
        }
        e.currentFn = savedFn
        e.pendingDeopt = savedDeopt
        return (fn, ty)
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
        case .stringBase: return g.e.strTy
        case .double: return g.e.f64
        case .bool:   return g.e.i1
        case .uint8:  return g.e.i8    // a UInt8 builtin result/arg is one byte (e.g. `byte(at:)`)
        case .rawPtr: return g.e.i8ptr // a RawPtr result is an addrspace(0) byte address (e.g. `bytePointer()`)
        default:      return g.e.i64
        }
    }
}
