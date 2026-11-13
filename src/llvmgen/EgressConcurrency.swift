import sema
import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// SSAIR→LLVM egress — actor / closure / fiber emission: actor mailbox init, the managed closure
// `{header, fn, env}` object (stack-allocated when non-escaping), and `fiber` (the per-fiber thunk). A capability
// namespace over the `SSAIRToLLVM` reference; the GC/fiber ABI primitives are reached through `g.e`.
enum EgressConcurrency {

    static func lowerMailboxInit(_ g: SSAIRToLLVM, _ obj: SSAValue, _ span: Span) {
        guard case .named(let name, _) = obj.type, let at = g.e.actorType(name) else {
            g.e.fail("7.2.3: mailboxInit on a non-actor", span); return
        }
        let mailbox = g.e.rtAllocManaged(LLVMConstInt(g.e.i64, 40, 0))
        g.e.writeTypeIdHeaderRaw(mailbox, g.e.mailboxTypeIdValue())
        g.e.storeField(g.val(obj), g.e.structGEP(at, g.val(obj), g.e.actorMailboxIndex(name)), mailbox)
        g.e.registerActorDrain()
    }

    // A closure value is a managed `{ i64 header, i8ptr fn, p1 env }` object (the env carries the
    // captures, built separately as a class object). Same shape as an `any` box (one managed field at
    // byte 16), so it reuses the any-box type-id for GC scanning.
    static func makeClosure(_ g: SSAIRToLLVM, _ funcName: String, _ env: SSAValue?, _ onStack: Bool, _ span: Span) -> LLVMValueRef? {
        guard let c = g.e.callables["f:\(funcName)"] else { g.e.fail("7.2.3: unknown closure body '\(funcName)'", span); return nil }
        let cloTy = g.e.structTy([g.e.i64, g.e.i8ptr, g.e.p1])
        // A non-escaping closure object lives on the stack (EA 7.3): an entry alloca in place of the
        // managed heap object. Same `{header, fn, env}` layout, so the indirect-call GEPs are unchanged;
        // the env field stays `p1` (the env object itself is still heap this slice). `storeField` sees
        // an addrspace(0) base and emits a plain store (no barrier, I7); SROA then scalar-replaces the
        // slot so its managed env field becomes a statepoint-tracked root (I5).
        let obj: LLVMValueRef = onStack ? g.e.entryAlloca(cloTy, "clo") : g.e.rtAllocManaged(LLVMConstInt(g.e.i64, 24, 0))
        LLVMBuildStore(g.b, g.e.descOffsetHeader(g.e.anyBoxTypeId()), g.e.structGEP(cloTy, obj, 0))
        LLVMBuildStore(g.b, c.fn, g.e.structGEP(cloTy, obj, 1))
        let envVal = env != nil ? g.val(env!) : LLVMConstNull(g.e.p1)
        g.e.storeField(obj, g.e.structGEP(cloTy, obj, 2), envVal)
        return obj
    }

    // Start `startFn(env)` on a fiber. The runtime's fiber routine ABI is `i8ptr(i8ptr)`, so a thunk calls the
    // lifted `fiber:N(env)` and returns null; the body's result is dropped.
    static func lowerFiber(_ g: SSAIRToLLVM, startFn: String, env: SSAValue?, span: Span) {
        guard let start = g.e.callables["f:\(startFn)"] else {
            g.e.fail("7.2.3: unknown fiber body '\(startFn)'", span); return
        }
        let (thunk, _) = g.e.emitFunction("nomu_fiberthunk", ret: g.e.i8ptr, params: [g.e.i8ptr])
        LLVMSetLinkage(thunk, LLVMInternalLinkage)
        g.e.withStubBody(thunk) {
            _ = g.e.buildCall(start.fn, start.ty, [LLVMGetParam(thunk, 0)!])
            LLVMBuildRet(g.b, LLVMConstNull(g.e.i8ptr))
        }
        let startFiber = g.e.runtimePreludeFn("nomuSchedStartFiber", ret: g.e.voidTy, params: [g.e.i8ptr, g.e.i8ptr, g.e.i8ptr])
        let envArg = env != nil ? g.e.toUnmanaged(g.val(env!)) : LLVMConstNull(g.e.i8ptr)
        let sched = g.e.loadRuntimeGlobal("rtSched", g.e.i8ptr)
        _ = g.e.buildCall(startFiber.fn, startFiber.ty, [sched, thunk, envArg])
    }
}
