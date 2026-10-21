import sema
import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// SSAIR→LLVM egress — actor / closure / spawn emission: actor mailbox init, the managed closure
// `{header, fn, env}` object (stack-allocated when non-escaping), and `spawn`/`spawn`-join (the
// per-spawn fiber thunk that boxes the result, and the join that reads it back). A capability
// namespace over the `SSAIRToLLVM` reference; the GC/fiber ABI primitives are reached through `g.e`.
enum EgressConcurrency {

    static func lowerMailboxInit(_ g: SSAIRToLLVM, _ obj: SSAValue, _ span: Span) {
        guard case .named(let name, _) = obj.type, let at = g.e.actorType(name) else {
            g.e.fail("7.2.3: mailboxInit on a non-actor", span); return
        }
        let mailbox = g.e.rtAllocManaged(LLVMConstInt(g.e.i64, 40, 0))
        g.e.writeTypeIdHeaderRaw(mailbox, g.e.mailboxTypeIdValue())
        g.e.storeField(g.val(obj), g.e.structGEP(at, g.val(obj), g.e.actorMailboxIndex(name)), mailbox)
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

    // Start `startFn(env)` on a fiber. The lifted `spawn:N(env: envClass) -> R` returns its result
    // directly, but the runtime's fiber routine ABI is `i8ptr(i8ptr)`, so wrap it in a per-spawn thunk
    // that re-manages the env pointer, calls the lifted body, boxes the result, and returns the box.
    static func lowerSpawn(_ g: SSAIRToLLVM, binding: Int, startFn: String, env: SSAValue?, resultType: Type, span: Span) {
        guard let start = g.e.callables["f:\(startFn)"], let resTy = g.ty(resultType, span) else {
            g.e.fail("7.2.3: unknown spawn body '\(startFn)'", span); return
        }
        let (thunk, _) = g.e.emitFunction("nomu_spawnthunk_\(binding)", ret: g.e.i8ptr, params: [g.e.i8ptr])
        g.e.withStubBody(thunk) {
            let envArg = LLVMGetParam(thunk, 0)!   // addr0 void* — matches `spawn:N`'s addr0 env param
            let r = g.e.buildCall(start.fn, start.ty, [envArg])!
            // A proper typed box { header, result } (150.3.13): the header lets a moving collection relocate
            // the box, which the self-hosted STW walk roots at fib+216 until the join; its pointer map scans a
            // managed result so that survives + is fixed up too. Result lives after the 8-byte header.
            let slots = 1 + g.e.slotCount(resultType)
            let bytes = LLVMConstInt(g.e.i64, UInt64(slots * 8), 0)!
            let box: LLVMValueRef
            var result = r
            if g.e.shapes.hasConditional(resultType), let lt = g.ty(resultType, span) {
                // A shaped result crosses the box's allocation in a recorded frame slot, as a home does: stored
                // before, recorded in the allocation's deopt bundle, reloaded after. The thunk is built while
                // `currentFn` is the spawning function, so it is this function's for the allocation.
                let savedFn = g.e.currentFn, savedDeopt = g.e.pendingDeopt
                g.e.currentFn = thunk
                let home = g.e.entryAlloca(lt, "spawn.res.home")
                LLVMBuildStore(g.b, r, home)
                g.e.pendingDeopt = [LLVMConstInt(g.e.i32, UInt64(bitPattern: Int64(g.e.shapeOrdinal(resultType))), 0), home]
                box = g.e.rtAllocManaged(bytes)
                g.e.pendingDeopt = savedDeopt
                g.e.currentFn = savedFn
                result = g.loadReloading(home, resultType, lt)
            } else {
                box = g.e.rtAllocManaged(bytes)
            }
            g.e.writeTypeIdHeaderRaw(box, g.e.spawnBoxTypeId(resultType))
            g.e.storeField(box, g.e.gepByte(box, LLVMConstInt(g.e.i64, 8, 0)), result, type: resultType)
            LLVMBuildRet(g.b, g.e.toUnmanaged(box))
        }
        let (spawn, sty) = g.e.runtimeFn("fiber_spawn", ret: g.e.i8ptr, params: [g.e.i8ptr, g.e.i8ptr], varArg: false)
        let envArg = env != nil ? g.e.toUnmanaged(g.val(env!)) : LLVMConstNull(g.e.i8ptr)
        let fiber = g.e.buildCall(spawn, sty, [thunk, envArg])!
        _ = resTy
        let handleSlot = g.e.entryAlloca(g.e.spawnHandleTy, "spawn.h")
        LLVMBuildStore(g.b, fiber, g.e.structGEP(g.e.spawnHandleTy, handleSlot, 0))
        g.spawnHandles[binding] = handleSlot
    }

    static func lowerSpawnJoin(_ g: SSAIRToLLVM, _ inst: SSAInst, binding: Int, resultType: Type, final: Bool, span: Span) {
        guard let handleSlot = g.spawnHandles[binding] else { return }
        // `final` (the structured scope-exit join) tells the runtime to drop the fiber from the live-fiber
        // registry after reading the result — the point its result box stops being rooted (150.3.13).
        let (sj, sty) = g.e.runtimeFn("spawn_join", ret: g.e.i8ptr, params: [g.e.i8ptr, g.e.i64], varArg: false)
        let box = g.e.buildCall(sj, sty, [handleSlot, LLVMConstInt(g.e.i64, final ? 1 : 0, 0)])!
        if let result = inst.result, let rt = g.ty(resultType, span) {
            let payload = g.e.gepByte(box, LLVMConstInt(g.e.i64, 8, 0))   // result after the 8-byte header (150.3.13)
            g.define(inst, LLVMBuildLoad2(g.b, rt, payload, "spawn.res"))
        }
    }
}
