import sema
import mangle
import noir
import ast
import support
import ssair
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
    // 4-slot prefix are 4 + argPos. Handlers are void (fire-and-forget), so there is no reply field. Each
    // argument has its field storage type, so it sits where the value layout puts it (`messageArgsLayout`),
    // which the message's GC descriptor reads.
    func messageType(_ actorName: String, _ h: NOIRHandler) -> LLVMTypeRef? {
        let key = "\(actorName):\(h.name)"
        if let t = messageTypes[key] { return t }
        var elems: [LLVMTypeRef] = [i64, p1, i8ptr, p1]   // header, next, thunk, self
        for p in h.params {
            guard let t = fieldStorageType(p.type, p.span) else { return nil }
            elems.append(t)
        }
        let mt = LLVMStructCreateNamed(ctx, "msg.\(actorName).\(h.name)")!
        setStructBody(mt, elems)
        messageTypes[key] = mt
        return mt
    }

    // Field index of a handler's i-th arg within the message struct (past the 4-slot prefix).
    func msgArgIndex(_ i: Int) -> Int { 4 + i }

    // A handler's arguments in its message, past the 32-byte prefix.
    func messageArgsLayout(_ h: NOIRHandler) -> FieldsLayout {
        shapes.fieldsLayout(h.params.map(\.type), base: 32)
    }

    // A handler's message size in bytes.
    func messageSize(_ h: NOIRHandler) -> Int { ShapeEnv.alignUp(messageArgsLayout(h).end, 8) }

    // Type-id + pointer map for a handler's message, which the collector reads to scan a queued message as a
    // root (`runtime/msgpool.nomu`). Managed offsets: self (24) always, plus any managed pointers inside the
    // args. next (8) is a raw link between pool slots and thunk (16) a code pointer; neither is scanned.
    func messageTypeIdValue(_ actorName: String, _ h: NOIRHandler) -> UInt64 {
        let key = "\(actorName):\(h.name)"
        if let id = messageTypeIds[key] { return id }
        let d = descriptorEntries(shapes.fieldsShape(h.params.map(\.type), base: 32))   // args past the prefix
        let id = registerMap([24] + d.offsets, sizeBytes: Int32(messageSize(h)),   // self
                             symbol: Mangle.messageDescriptor(actorName, h.name, home: homeModule), foldable: true, shaped: d.shaped)
        messageTypeIds[key] = id
        return id
    }

    // The per-handler drain thunk `void @nomu_onthunk_<A>_<h>(ptr msg)`: unpack self + args from the
    // message, give the message back to the pool (`rtMsgFree`), and call the handler (void — no reply). Runs on
    // a mailbox fiber inside the drain loop. `msg` is a raw pool slot; once read, self and the args are
    // ordinary values in this frame, relocated at the handler's safepoints.
    func actorThunk(_ actorName: String, _ h: NOIRHandler) -> LLVMValueRef {
        let key = "\(actorName):\(h.name)"
        if let f = actorThunks[key] { return f }
        declareActorHandler(actorName, h.name)
        let handler = callables["m:\(actorName):\(h.name)"]!
        let mt = messageType(actorName, h)!
        let (fn, _) = emitFunction("nomu_onthunk_\(actorName)_\(h.name)", ret: voidTy, params: [i8ptr])
        LLVMSetLinkage(fn, LLVMInternalLinkage)   // referenced only from this object's sends
        actorThunks[key] = fn
        withStubBody(fn) {
            let msg = LLVMGetParam(fn, 0)!
            let selfV = LLVMBuildLoad2(b, p1, structGEP(mt, msg, 3), "self")!
            var argVals: [LLVMValueRef?] = [selfV]
            for (i, p) in h.params.enumerated() {
                guard let t = llvmType(p.type, p.span) else { continue }
                argVals.append(LLVMBuildLoad2(b, t, structGEP(mt, msg, msgArgIndex(i)), p.name))
            }
            let free = runtimePreludeFn("rtMsgFree", ret: voidTy, params: [i8ptr])
            markCallGCLeaf(buildCall(free.fn, free.ty, [msg])!)
            _ = buildCall(handler.fn, handler.ty, argVals)   // void handler; any return is dropped
            LLVMBuildRetVoid(b)
        }
        return fn
    }

    // The one shared drain loop `void @nomu_actor_drain(ptr addrspace(1) mb)` the mailbox fibers call
    // (`rtSchedMailboxFiberMain`): pop a message, run its thunk, repeat until the mailbox is
    // empty. `mb` is a tracked GC root across the thunk call — the reason this loop is codegen: a moving GC
    // may relocate it at a handler safepoint. Each `msg` is a raw pool slot, which never moves. Every module that uses
    // actors emits the same body, weak-ODR so the copies fold to one at link.
    func actorDrain() -> (LLVMValueRef, LLVMTypeRef) {
        if let f = actorDrainFn { return f }
        // The scheduler's mailbox pop (`nomuSchedMailboxPop(sched, mailbox)`), called with the managed mailbox,
        // so it stays a tracked GC value across the call, and returning the raw message.
        let popFn = runtimePreludeFn("nomuSchedMailboxPop", ret: i8ptr, params: [i8ptr, i8ptr])
        let pop = (popFn.fn, fnType(i8ptr, [i8ptr, p1]))
        let thunkTy = fnType(voidTy, [i8ptr])
        let pre = msgPrefixType()
        let (fn, fnTy) = emitFunction("nomu_actor_drain", ret: voidTy, params: [p1])
        LLVMSetLinkage(fn, LLVMWeakODRLinkage)
        actorDrainFn = (fn, fnTy)
        // Only a mailbox fiber calls the drain, at the base of its stack, through the scheduler's slot: no indirect
        // call in Nomu code reaches it, so the stack check counts it as an entry.
        runtimeEntries.insert("nomu_actor_drain")
        withStubBody(fn) {
            let mb = LLVMGetParam(fn, 0)!
            let loopBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.loop")!
            let bodyBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.body")!
            let exitBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.exit")!
            LLVMBuildBr(b, loopBB)
            LLVMPositionBuilderAtEnd(b, loopBB)
            let msg = buildCall(pop.0, pop.1, [loadRuntimeGlobal("rtSched", i8ptr), mb])!
            let isNull = LLVMBuildICmp(b, LLVMIntEQ, msg, LLVMConstNull(i8ptr), "empty?")
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

    // Give the scheduler the drain loop: store its address in the scheduler's drain slot (`rtSched`+120,
    // which the mailbox fibers call). Emitted at each actor's creation, so only a program that creates an
    // actor references the drain and the scheduler's actor code; every creation stores the same address.
    // The first send of any message follows a creation, and the send publishes the mailbox to a carrier with
    // sequentially consistent atomics (its scheduled flag, the run queue), which order this store before the
    // mailbox fiber that drains it reads the slot.
    func registerActorDrain() {
        let drain = actorDrain()
        let slot = gepByte(loadRuntimeGlobal("rtSched", i8ptr), LLVMConstInt(i64, 120, 0))
        LLVMBuildStore(b, drain.0, slot)
    }

    // Build + enqueue a handler message from the lowered receiver and argument values (M6 · 6.4): take a
    // slot from the message pool, stamp header/thunk/self/args, and hand it to the scheduler's
    // `nomuSchedActorSend`, which enqueues it and returns. Fire-and-forget — the only actor operation (§9) — so
    // it yields no value. The pool call is gc-leaf and the slot is raw memory, so the stores take no write
    // barrier and no collection can see a half-written message.
    func emitActorSend(_ actorName: String, _ handler: String, _ recvValue: LLVMValueRef,
                       _ argVals: () -> [LLVMValueRef], _ span: Span) -> LLVMValueRef? {
        guard let a = actorMap[actorName],
              let h = a.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", span); return nil
        }
        _ = actorDrain()                       // ensure the shared drain loop exists
        let thunk = actorThunk(actorName, h)   // per-handler thunk (+ handler + message type)
        guard let mt = messageType(actorName, h), let at = actorType(actorName) else { return nil }

        // Allocate + populate the message. thunk, self and args are set here; the header (the type id) by the
        // pool, which keeps a mark of its own beside it, and `next` by the scheduler's send. Every collection
        // scans a live pool slot as a root, so it needs no other.
        let alloc = runtimePreludeFn("rtMsgAlloc", ret: i8ptr, params: [i64, i64])
        let msg = buildCall(alloc.fn, alloc.ty, [LLVMConstInt(i64, UInt64(messageSize(h)), 0),
                                                 descOffsetHeader(messageTypeIdValue(actorName, h))])!
        markCallGCLeaf(msg)
        LLVMBuildStore(b, thunk, structGEP(mt, msg, 2))         // thunk (code ptr, not managed)
        storeField(msg, structGEP(mt, msg, 3), recvValue)       // self (managed)
        for (i, v) in argVals().enumerated() {
            storeField(msg, structGEP(mt, msg, msgArgIndex(i)), v)
        }
        let mailbox = LLVMBuildLoad2(b, p1, structGEP(at, recvValue, actorMailboxIndex(actorName)), "mailbox")!
        // The scheduler's send (`nomuSchedActorSend(sched, mailbox, msg)`), with the managed mailbox and the raw
        // message.
        let sendFn = runtimePreludeFn("nomuSchedActorSend", ret: voidTy, params: [i8ptr, i8ptr, i8ptr])
        let sched = loadRuntimeGlobal("rtSched", i8ptr)
        _ = buildCall(sendFn.fn, fnType(voidTy, [i8ptr, p1, i8ptr]), [sched, mailbox, msg])
        return LLVMConstNull(p1)   // fire-and-forget: no value
    }
}
