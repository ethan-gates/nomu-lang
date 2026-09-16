import sema
import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// SSAIR→LLVM egress — array emission: the managed `{header, len, buf}` handle layout, literal
// construction, the bounds-check trap sequence, element addressing, and the `__arraySet`/
// `__arrayAppend` builtins (append grows/copies the backing buffer). A capability namespace over the
// `SSAIRToLLVM` reference; layout/alloc primitives are reached through `g.e`.
enum EgressArrays {

    static func lowerArrayLit(_ g: SSAIRToLLVM, _ elements: [SSAValue], _ elem: Type, _ span: Span) -> LLVMValueRef? {
        let stride = g.e.arrayElemStride(elem)
        let n = elements.count
        let handle = g.e.rtAllocManaged(LLVMConstInt(g.e.i64, 24, 0))
        LLVMBuildStore(g.b, LLVMConstInt(g.e.i64, g.e.arrayHandleTypeId(), 0), handle)
        LLVMBuildStore(g.b, LLVMConstInt(g.e.i64, UInt64(n), 0), g.e.gepByte(handle, LLVMConstInt(g.e.i64, 8, 0)))
        let buf = g.e.rtAllocManaged(LLVMConstInt(g.e.i64, UInt64(16 + n * stride), 0))
        LLVMBuildStore(g.b, LLVMConstInt(g.e.i64, g.e.arrayBufTypeId(elem), 0), buf)
        LLVMBuildStore(g.b, LLVMConstInt(g.e.i64, UInt64(n), 0), g.e.gepByte(buf, LLVMConstInt(g.e.i64, 8, 0)))
        for (i, el) in elements.enumerated() {
            g.e.storeField(buf, g.e.gepByte(buf, LLVMConstInt(g.e.i64, UInt64(16 + i * stride), 0)), g.val(el))
        }
        g.e.storeField(handle, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 16, 0)), buf)
        return handle
    }

    // The bounds-check trap sequence (`index UGE length` → `rt_bounds_trap` → unreachable); on return
    // the builder sits in the in-bounds continuation.
    static func emitBoundscheck(_ g: SSAIRToLLVM, _ idx: LLVMValueRef, _ len: LLVMValueRef) {
        guard let fn = g.e.currentFn else { return }
        let oob = LLVMBuildICmp(g.b, LLVMIntUGE, idx, len, "arr.oob")!
        let trapBB = LLVMAppendBasicBlockInContext(g.ctx, fn, "arr.trap")!
        let okBB = LLVMAppendBasicBlockInContext(g.ctx, fn, "arr.ok")!
        LLVMBuildCondBr(g.b, oob, trapBB, okBB)
        LLVMPositionBuilderAtEnd(g.b, trapBB)
        let (trap, tty) = g.e.runtimeFn("rt_bounds_trap", ret: g.e.voidTy, params: [g.e.i64, g.e.i64], varArg: false)
        _ = g.e.buildCall(trap, tty, [idx, len])
        LLVMBuildUnreachable(g.b)
        LLVMPositionBuilderAtEnd(g.b, okBB)
    }

    static func elementAddr(_ g: SSAIRToLLVM, _ handle: SSAValue, _ index: SSAValue, _ elemType: Type, _ span: Span) -> LLVMValueRef {
        let buf = LLVMBuildLoad2(g.b, g.e.p1, g.e.gepByte(g.val(handle), LLVMConstInt(g.e.i64, 16, 0)), "arr.buf")!
        let stride = LLVMConstInt(g.e.i64, UInt64(g.e.arrayElemStride(elemType)), 0)
        let off = LLVMBuildAdd(g.b, LLVMConstInt(g.e.i64, 16, 0), LLVMBuildMul(g.b, g.val(index), stride, "arr.mul"), "arr.off")!
        return g.e.gepByte(buf, off)
    }

    static func emitArraySet(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 3 else { g.e.fail("7.2.3: __arraySet expects 3 args", span); return nil }
        let handle = g.val(args[0]), idxV = g.val(args[1]), value = g.val(args[2])
        let len = LLVMBuildLoad2(g.b, g.e.i64, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 8, 0)), "arr.len")!
        emitBoundscheck(g, idxV, len)
        let buf = LLVMBuildLoad2(g.b, g.e.p1, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 16, 0)), "arr.buf")!
        let stride = LLVMConstInt(g.e.i64, UInt64(g.e.arrayElemStride(args[2].type)), 0)
        let off = LLVMBuildAdd(g.b, LLVMConstInt(g.e.i64, 16, 0), LLVMBuildMul(g.b, idxV, stride, "arr.mul"), "arr.off")!
        g.e.storeField(buf, g.e.gepByte(buf, off), value)
        return LLVMConstInt(g.e.i64, 0, 0)
    }

    static func emitArrayAppend(_ g: SSAIRToLLVM, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2, let fn = g.e.currentFn else { g.e.fail("7.2.3: __arrayAppend expects 2 args", span); return nil }
        let elem = args[1].type
        let handle = g.val(args[0]), value = g.val(args[1])
        let stride = g.e.arrayElemStride(elem)
        let strideV = LLVMConstInt(g.e.i64, UInt64(stride), 0)
        let len = LLVMBuildLoad2(g.b, g.e.i64, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 8, 0)), "app.len")!
        let buf0 = LLVMBuildLoad2(g.b, g.e.p1, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 16, 0)), "app.buf")!
        let cap = LLVMBuildLoad2(g.b, g.e.i64, g.e.gepByte(buf0, LLVMConstInt(g.e.i64, 8, 0)), "app.cap")!
        let full = LLVMBuildICmp(g.b, LLVMIntUGE, len, cap, "app.full")!
        let growBB = LLVMAppendBasicBlockInContext(g.ctx, fn, "app.grow")!
        let contBB = LLVMAppendBasicBlockInContext(g.ctx, fn, "app.cont")!
        LLVMBuildCondBr(g.b, full, growBB, contBB)

        LLVMPositionBuilderAtEnd(g.b, growBB)
        let isZero = LLVMBuildICmp(g.b, LLVMIntEQ, cap, LLVMConstInt(g.e.i64, 0, 0), "app.cap0")!
        let dbl = LLVMBuildMul(g.b, cap, LLVMConstInt(g.e.i64, 2, 0), "app.dbl")!
        let newCap = LLVMBuildSelect(g.b, isZero, LLVMConstInt(g.e.i64, 4, 0), dbl, "app.newcap")!
        let newBytes = LLVMBuildAdd(g.b, LLVMConstInt(g.e.i64, 16, 0), LLVMBuildMul(g.b, newCap, strideV, "app.nb"), "app.bytes")!
        let newBuf = g.e.rtAllocManaged(newBytes)
        LLVMBuildStore(g.b, LLVMConstInt(g.e.i64, g.e.arrayBufTypeId(elem), 0), newBuf)
        LLVMBuildStore(g.b, newCap, g.e.gepByte(newBuf, LLVMConstInt(g.e.i64, 8, 0)))
        let copyBytes = LLVMBuildMul(g.b, len, strideV, "app.copy")!
        let (memcpy, mty) = g.e.runtimeFn("memcpy", ret: g.e.i8ptr, params: [g.e.i8ptr, g.e.i8ptr, g.e.i64], varArg: false)
        _ = g.e.buildCall(memcpy, mty, [g.e.toUnmanaged(g.e.gepByte(newBuf, LLVMConstInt(g.e.i64, 16, 0))),
                                      g.e.toUnmanaged(g.e.gepByte(buf0, LLVMConstInt(g.e.i64, 16, 0))), copyBytes])
        g.e.storeField(handle, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 16, 0)), newBuf)
        LLVMBuildBr(g.b, contBB)

        LLVMPositionBuilderAtEnd(g.b, contBB)
        let buf = LLVMBuildLoad2(g.b, g.e.p1, g.e.gepByte(handle, LLVMConstInt(g.e.i64, 16, 0)), "app.buf2")!
        let off = LLVMBuildAdd(g.b, LLVMConstInt(g.e.i64, 16, 0), LLVMBuildMul(g.b, len, strideV, "app.mul"), "app.off")!
        g.e.storeField(buf, g.e.gepByte(buf, off), value)
        LLVMBuildStore(g.b, LLVMBuildAdd(g.b, len, LLVMConstInt(g.e.i64, 1, 0), "app.inc"), g.e.gepByte(handle, LLVMConstInt(g.e.i64, 8, 0)))
        return LLVMConstInt(g.e.i64, 0, 0)
    }
}
