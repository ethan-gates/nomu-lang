import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

// M6 · 6.4 actor mailbox codegen — the message ABI + the runtime-facing drain machinery. A handler
// call becomes a fire-and-forget message enqueued on the receiver's mailbox; a pool worker runs the
// shared drain loop, which invokes each message's per-handler thunk. The message layout, its type-id/
// pointer map, the per-handler thunk, and the drain loop are all ABI/GC contracts both egresses must
// emit identically, so they live in the shared emitter. `lowerActorCall` (which lowers the argument
// exprs) stays on each egress and reaches these through forwarders.
extension LLVMGen {
    // The generic message prefix `{ i64 header, p1 next, i8ptr thunk, p1 self }` — enough for the
    // shared drain loop to reach `thunk` (idx 2). Per-handler message types extend it with args, but
    // share these offsets. (Fire-and-forget: no sender, no reply — §9.)
    func msgPrefixType() -> LLVMTypeRef {
        if let t = msgPrefixTypeRef { return t }
        let t = structTy([i64, p1, i8ptr, p1])
        msgPrefixTypeRef = t
        return t
    }

    // The per-handler message struct `{ header, next, thunk, self, args… }`. Field indices past the
    // 4-slot prefix are 4 + argPos. Handlers are void (fire-and-forget), so there is no reply field.
    func messageType(_ actorName: String, _ h: NOIRHandler) -> LLVMTypeRef? {
        let key = "\(actorName):\(h.name)"
        if let t = messageTypes[key] { return t }
        var elems: [LLVMTypeRef] = [i64, p1, i8ptr, p1]   // header, next, thunk, self
        for p in h.params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            elems.append(t)
        }
        let mt = LLVMStructCreateNamed(ctx, "msg.\(actorName).\(h.name)")!
        setStructBody(mt, elems)
        messageTypes[key] = mt
        return mt
    }

    // Field index of a handler's i-th arg within the message struct (past the 4-slot prefix).
    func msgArgIndex(_ i: Int) -> Int { 4 + i }

    // Total 8-byte slots a handler's message occupies: 4-slot prefix + args. Every leaf is 8-aligned
    // and an 8-multiple (the object-model invariant), so LLVM adds no padding and byte offsets equal
    // slot*8 — the same assumption the class/actor layout makes.
    func messageSlots(_ h: NOIRHandler) -> Int {
        var slots = 4
        for p in h.params { slots += slotCount(p.type) }
        return slots
    }

    // Type-id + pointer map for a handler's message. Managed offsets: next (8) and self (24) always,
    // plus any managed pointers inside the args. thunk (16, a code ptr) is never scanned.
    func messageTypeIdValue(_ actorName: String, _ h: NOIRHandler) -> UInt64 {
        let key = "\(actorName):\(h.name)"
        if let id = messageTypeIds[key] { return id }
        var offsets: [Int32] = [8, 24]   // next, self
        var slot = 4                     // args start past the 4-slot prefix
        for p in h.params {
            collectManagedOffsets(p.type, baseSlot: slot, into: &offsets)
            slot += slotCount(p.type)
        }
        let id = registerMap(offsets, sizeBytes: Int32(slot * 8))
        messageTypeIds[key] = id
        return id
    }

    // The per-handler drain thunk `void @nomu_onthunk_<A>_<h>(ptr addrspace(1) msg)`: unpack self +
    // args from the message and call the handler (void — no reply). Runs on a rented pool worker
    // inside the drain loop; `msg` is a tracked GC root here, so the handler's safepoints relocate it
    // and `self` correctly.
    func actorThunk(_ actorName: String, _ h: NOIRHandler) -> LLVMValueRef {
        let key = "\(actorName):\(h.name)"
        if let f = actorThunks[key] { return f }
        declareActorHandler(actorName, h.name)
        let handler = callables["m:\(actorName):\(h.name)"]!
        let mt = messageType(actorName, h)!
        let (fn, _) = emitFunction("nomu_onthunk_\(actorName)_\(h.name)", ret: voidTy, params: [p1])
        actorThunks[key] = fn
        withStubBody(fn) {
            let msg = LLVMGetParam(fn, 0)!
            let selfV = LLVMBuildLoad2(b, p1, structGEP(mt, msg, 3), "self")!
            var argVals: [LLVMValueRef?] = [selfV]
            for (i, p) in h.params.enumerated() {
                guard let t = llvmType(p.type, p.span) else { continue }
                argVals.append(LLVMBuildLoad2(b, t, structGEP(mt, msg, msgArgIndex(i)), p.name))
            }
            _ = buildCall(handler.fn, handler.ty, argVals)   // void handler; any return is dropped
            LLVMBuildRetVoid(b)
        }
        return fn
    }

    // The one shared drain loop `void @nomu_actor_drain(ptr addrspace(1) mb)` the pool worker calls
    // (runtime.c `rt_pool_worker_main`): pop a message, run its thunk, repeat until the mailbox is
    // empty. `mb` and each `msg` are tracked GC roots across the thunk call — the whole reason this
    // loop is codegen (not C): a moving GC may relocate them at a handler safepoint.
    func actorDrain() -> (LLVMValueRef, LLVMTypeRef) {
        if let f = actorDrainFn { return f }
        let pop = runtimeFn("rt_mailbox_pop", ret: p1, params: [p1], varArg: false)
        let thunkTy = fnType(voidTy, [p1])
        let pre = msgPrefixType()
        let (fn, fnTy) = emitFunction("nomu_actor_drain", ret: voidTy, params: [p1])
        actorDrainFn = (fn, fnTy)
        withStubBody(fn) {
            let mb = LLVMGetParam(fn, 0)!
            let loopBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.loop")!
            let bodyBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.body")!
            let exitBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.exit")!
            LLVMBuildBr(b, loopBB)
            LLVMPositionBuilderAtEnd(b, loopBB)
            let msg = buildCall(pop.0, pop.1, [mb])!
            let isNull = LLVMBuildICmp(b, LLVMIntEQ, msg, LLVMConstNull(p1), "empty?")
            LLVMBuildCondBr(b, isNull, exitBB, bodyBB)
            LLVMPositionBuilderAtEnd(b, bodyBB)
            let thunk = LLVMBuildLoad2(b, i8ptr, structGEP(pre, msg, 2), "thunk")!
            var callArgs: [LLVMValueRef?] = [msg]
            _ = callArgs.withUnsafeMutableBufferPointer {
                LLVMBuildCall2(b, thunkTy, thunk, $0.baseAddress, 1, "")
            }
            LLVMBuildBr(b, loopBB)
            LLVMPositionBuilderAtEnd(b, exitBB)
            LLVMBuildRetVoid(b)
        }
        return actorDrainFn!
    }

    // Build + enqueue a handler message from the already-lowered receiver + argument values (M6 ·
    // 6.4): allocate the message, stamp header/thunk/self/args, and hand it to `rt_actor_send`, which
    // enqueues it and returns. Fire-and-forget — the only actor operation (§9) — so it yields no
    // value. The egress lowers the receiver + arg exprs and calls in with the resulting values.
    func emitActorSend(_ actorName: String, _ handler: String, _ recvValue: LLVMValueRef,
                       _ argVals: [LLVMValueRef], _ span: Span) -> LLVMValueRef? {
        guard let a = actorMap[actorName],
              let h = a.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", span); return nil
        }
        _ = actorDrain()                       // ensure the shared drain loop exists
        let thunk = actorThunk(actorName, h)   // per-handler thunk (+ handler + message type)
        guard let mt = messageType(actorName, h), let at = actorType(actorName) else { return nil }

        // Allocate + populate the message. header, thunk, self, args are set here; `next` is filled by
        // the runtime. The message stays reachable via the mailbox chain once enqueued (no sender root).
        let bytes = messageSlots(h) * 8
        let msg = rtAllocManaged(LLVMConstInt(i64, UInt64(bytes), 0))
        writeTypeIdHeaderRaw(msg, messageTypeIdValue(actorName, h))
        LLVMBuildStore(b, thunk, structGEP(mt, msg, 2))         // thunk (code ptr, not managed)
        storeField(msg, structGEP(mt, msg, 3), recvValue)       // self (managed)
        for (i, v) in argVals.enumerated() {
            storeField(msg, structGEP(mt, msg, msgArgIndex(i)), v)
        }
        let mailbox = LLVMBuildLoad2(b, p1, structGEP(at, recvValue, actorMailboxIndex(actorName)), "mailbox")!
        let send = runtimeFn("rt_actor_send", ret: voidTy, params: [p1, p1], varArg: false)
        _ = buildCall(send.0, send.1, [mailbox, msg])
        return LLVMConstNull(p1)   // fire-and-forget: no value
    }
}
