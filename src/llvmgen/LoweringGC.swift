import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Inline seams (8.4.4, D5)

    // Each of the three mutator seams — alloc / write-barrier / poll — is emitted as a call to an
    // `alwaysinline` stub with a trivial, provably-inert body (D5's "seam representation"). Keeping
    // the inert phase as a call into a one-line stub (rather than open-coding the disabled fast path
    // at every site) gives M6 a single body to fill; once filled, `alwaysinline` collapses the call
    // sites into the inline fast path. All three are behavior-neutral now: alloc tail-calls
    // `rt_alloc`, the barrier is a plain store, the poll is a no-op.

    // stop-world flag + `__nomu_poll` seam moved to LLVMGen (LLVMGenRuntime.swift).
    func emitSafepointPoll() { e.emitSafepointPoll() }

    // The `__nomu_gc_alloc` seam: `ptr addrspace(1) (i64 size)`, emitted at every managed-object
    // allocation. §6.6.2 — the inline bump-pointer fast path. Read the per-carrier mutator (a thread-
    // local, §6.6.1) and the published `{cursor, limit}` `BumpPointer` at `__nomu_bump_offset`; bump the
    // cursor and return it when the object fits and is not LOS-sized; else tail-call `rt_alloc` (the
    // slow path — a statepoint, so this function is **not** `gc-leaf`). The returned memory is zeroed
    // (Nomu's zero-init-fields contract; the actor mailbox and array buffers rely on it), matching
    // `rt_alloc`'s `memset`. The bump loads/stores sit in a call-free block, so nothing hoists across a
    // safepoint (the only safepoint is the slow-path `rt_alloc` call, which clobbers the mutator memory).
    // `__nomu_gc_alloc` seam moved to LLVMGen (LLVMGenRuntime.swift).

    // The `__nomu_write_barrier` seam: `void (ptr addrspace(1) obj, ptr addrspace(1) slot,
    // ptr addrspace(1) val)`, emitted at every store of a managed reference into a managed object field.
    // Object-remembering *post* barrier (GenImmix's `ObjectBarrier`): store `val` into `*slot`, then
    // remember `obj` the first time it is mutated after promotion so a nursery collection sees the new
    // cross-generation pointer. **Fast path inlined (M6 · 6.3.2):** the common case — barrier off
    // (NoGC/Immix), or `obj` already remembered / young — is a couple of loads + a predicted branch,
    // with no call. Only on an object's first mutation (unlog bit still 1) does it call the out-of-line
    // slow path `rt_gc_write_barrier` (which does the atomic log + remembered-set append). The unlog-bit
    // address is computed from the layout the binding publishes (`__nomu_logbit_base`/`_log_region`,
    // 1 bit/region) rather than hardcoded MMTk constants; `__nomu_barrier_active` gates the whole check
    // (0 under NoGC/Immix, where the log-bit metadata is unmapped). Stays `gc-leaf` (no statepoint);
    // `alwaysinline` collapses it into each store site, and `-O2` LICM hoists the loop-invariant loads.
    // `__nomu_write_barrier` seam moved to LLVMGen (LLVMGenRuntime.swift).
    func storeField(_ objBase: LLVMValueRef!, _ slot: LLVMValueRef!, _ val: LLVMValueRef!) { e.storeField(objBase, slot, val) }

    // Whether a loop body reaches a GC safepoint on its own each iteration — i.e. unconditionally
    // performs a non-leaf call or a heap allocation (both become statepoints after the rewrite). If
    // so, the loop needs no back-edge poll (D3 elision). Conservative in the safe direction: only
    // the body's *top-level* statements count (a safepoint nested in an `if`/`while`/`switch` arm
    // may not run every iteration), so when unsure we place the poll. This is the IR-level
    // approximation of D3; M6 re-audits against precise codegen safepoints when the collector is live.
    func loopBodyHasSafepoint(_ stmts: [NOIRStmt]) -> Bool {
        for s in stmts {
            switch s.kind {
            case .letBinding(_, _, let v): if exprHasSafepoint(v) { return true }
            case .assign(let t, let v), .compoundAssign(let t, let v):
                if exprHasSafepoint(t) || exprHasSafepoint(v) { return true }
            case .ret(let e): if let e = e, exprHasSafepoint(e) { return true }
            case .exprStmt(let e): if exprHasSafepoint(e) { return true }
            case .spawnLet: return true   // fiber_spawn + rt_alloc — a safepoint
            case .ifStmt, .whileStmt, .switchStmt, .breakStmt, .continueStmt: break
            }
        }
        return false
    }

    // Whether evaluating `e` unconditionally hits a safepoint: a non-leaf call, a method/witness
    // dispatch, or a heap allocation. Leaf builtins (`print`, `concat`, string literals) and pure
    // value construction (struct/enum) are not safepoints, but their sub-expressions still execute.
    func exprHasSafepoint(_ e: NOIRExpr) -> Bool {
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef:
            return false
        case .fieldAccess(let base, _):
            return exprHasSafepoint(base)
        case .binary(_, let l, let r):
            return exprHasSafepoint(l) || exprHasSafepoint(r)
        case .construct(let name, let args):
            if classMap[name] != nil || actorMap[name] != nil { return true }   // rt_alloc
            return args.contains { exprHasSafepoint($0.value) }
        case .enumInit(_, _, let args):
            return args.contains { exprHasSafepoint($0.value) }
        case .box, .closure:
            return true   // rt_alloc (the any-box / the fused closure object)
        case .methodCall:
            return true   // dispatches to user / witness code (non-leaf)
        case .call(let callee, let args, _):
            if case .varRef(let n) = callee.kind {
                if Builtins.cLeaf.contains(n) { return args.contains { exprHasSafepoint($0.value) } }   // pure C leaf
                switch n {
                case "print", "concat": return args.contains { exprHasSafepoint($0.value) }   // leaf
                case "__array_count_int", "__arraySet": return args.contains { exprHasSafepoint($0.value) }   // load / store
                case "__arrayAppend": return true                                              // rt_array_grow may rt_alloc
                case "__int_double_double", "__double_int_int",
                     "__int_uint8_uint8", "__uint8_int_int": return args.contains { exprHasSafepoint($0.value) }   // pure numeric conversions
                case "sleep", "readLine": return true                                          // non-leaf runtime
                default: return true                                                            // user function
                }
            }
            return true   // indirect closure call
        case .arrayLit:
            return true   // rt_alloc (the handle + the buffer)
        case .index(let base, let idx):
            return exprHasSafepoint(base) || exprHasSafepoint(idx)   // the load/bounds-trap is not a safepoint
        }
    }

    func buildCall(_ fn: LLVMValueRef, _ ty: LLVMTypeRef, _ args: [LLVMValueRef?]) -> LLVMValueRef? { e.buildCall(fn, ty, args) }

    // 8-byte slots an LLVM value type occupies. Every value type we build is 8-aligned and a
    // multiple of 8 (i64, pointers, {i8*,i64}, {ptr,ptr}, and structs of those), so a struct is
    // the sum of its members — used to size heap envs.
    func abiSlots(_ t: LLVMTypeRef) -> Int { e.abiSlots(t) }

    // `void* rt_alloc(size_t)` — the runtime allocator (bump-and-leak until the M6 GC). We declare
    // it as returning `ptr addrspace(1)`: the C ABI returns a plain 64-bit pointer, bit-identical to
    // an addrspace(1) pointer on arm64 (addrspace 1 carries no codegen difference here), and this
    // makes the allocation call itself a GC base the rewrite pass can track. An `addrspacecast
    // (0 → 1)` at the call site would *not* work — `RewriteStatepointsForGC::findBaseDefiningValue`
    // rejects a base introduced by a differing-addrspace cast (it strips pointer casts and asserts
    // the address spaces match). So the managed address space enters at the allocator, not via a cast.
    func rtAlloc() -> LLVMValueRef { e.rtAlloc() }
    func rtAllocTy() -> LLVMTypeRef { e.rtAllocTy() }

    // Allocate a managed (GC-heap) object of `bytes` bytes through the `__nomu_gc_alloc` seam
    // (8.4.4, D5) — inert now (the seam tail-calls `rt_alloc`), the inline TLAB fast path in M6.
    // The result is addrspace(1): the tracked managed reference the mutator holds (D1).
    func rtAllocManaged(_ bytes: LLVMValueRef) -> LLVMValueRef { e.rtAllocManaged(bytes) }

    // ---- M6 · 6.1.3 — GC pointer maps ----

    // Register a fixed-size object's pointer map (managed-field byte offsets) plus its total byte size,
    // and return its type-id (the shared index into `typeMaps`/`typeSizes`/`typeKinds`/`typeStrides`).
    func registerMap(_ offsets: [Int32], sizeBytes: Int32) -> UInt64 { e.registerMap(offsets, sizeBytes: sizeBytes) }

    // Register an array buffer type-id (M6 stdlib · Slice 4): `elementOffsets` are the managed-pointer
    // byte offsets *within one element*, `stride` its byte size. The object's total size and live
    // extent come from its `cap`/`len` at run time, so no fixed size is stored.
    func registerArrayMap(_ elementOffsets: [Int32], stride: Int32) -> UInt64 { e.registerArrayMap(elementOffsets, stride: stride) }

    // Type-id for a class/actor heap type; assigns one (and computes its pointer map) on first use.
    func typeId(forHeapType name: String) -> UInt64 { e.typeId(forHeapType: name) }

    // Type-id for a fused closure object `{ header, fn, caps… }`: managed captures (scalar `p1`) are
    // scanned, `fn` (addr0) is skipped. Each closure site is its own shape (captures vary), so a
    // fresh map is registered per closure.
    func closureTypeId(_ caps: [Capture]) -> UInt64 { e.closureTypeId(caps) }

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only
    // (byte 16, slot 2); the witness is a static table (Q7). Registered once.
    func anyBoxTypeId() -> UInt64 { e.anyBoxTypeId() }

    // Append the byte offsets of managed (`p1`) pointers within a field of type `t` laid out starting
    // at `baseSlot`. Recurses into inline value structs; String's buffer is runtime-owned (`addr0`)
    // today so it is skipped (Q6), and enum payloads carry no references in the language today (D6).
    func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32]) { e.collectManagedOffsets(t, baseSlot: baseSlot, into: &offsets) }

    // Write the type-id into the object's header (slot 0 at the object base).
    func writeTypeIdHeader(_ obj: LLVMValueRef, _ name: String) { e.writeTypeIdHeader(obj, name) }

    // Stamp a raw (non-named-type) type-id into an object header — for the mailbox/message objects,
    // which have no Nomu type name (M6 · 6.4).
    func writeTypeIdHeaderRaw(_ obj: LLVMValueRef, _ id: UInt64) { e.writeTypeIdHeaderRaw(obj, id) }

    // MARK: - M6 · 6.4 actor mailbox codegen

    // The shared type-id for every mailbox object
    // `{ i64 header, mb_head, mb_tail, i64 scheduled, sched_next }`: mb_head (8), mb_tail (16), and
    // sched_next (32, the scheduled-mailbox-queue link) are managed pointers (scanned); scheduled (24)
    // is a plain int. 40 bytes.
    func mailboxTypeIdValue() -> UInt64 { e.mailboxTypeIdValue() }

    // The actor message ABI + drain machinery + the message-population core (`emitActorSend`) moved to
    // LLVMGen (LLVMGenActor.swift) — GC/ABI contracts shared by both egresses. `lowerActorCall` below
    // is the walker glue: it lowers the argument exprs, then hands the receiver + values to
    // `emitActorSend`. It retires with this path (the SSAIR egress calls `emitActorSend` directly).
    func lowerActorCall(_ actorName: String, _ handler: String,
                                _ recvValue: LLVMValueRef, _ args: [NOIRExpr], _ span: Span) -> LLVMValueRef? {
        var argVals: [LLVMValueRef] = []
        for argE in args {
            guard let v = lowerExpr(argE) else { return nil }
            argVals.append(v)
        }
        return e.emitActorSend(actorName, handler, recvValue, argVals, span)
    }

    // Emit the flat pointer-map tables the runtime/binding reads (always emitted so runtime.c's
    // externs resolve, even with no heap types): `_data` = per-id `[count, off…]` concatenated,
    // `_index[id]` = that id's start in `_data`, `_count` = number of type-ids.
    func emitTypeMaps() { e.emitTypeMaps() }
    func emitI32Array(_ name: String, _ vals: [Int32]) { e.emitI32Array(name, vals) }

    // The C-ABI boundary cast (D1): a managed reference handed to a C function that takes a `void*`
    // is cast (1 → 0) for the call. This direction is supported by the rewrite pass (the result is
    // not a GC pointer, so it is never traced as a base). One explicit cast site per crossing keeps
    // the boundary auditable.
    func toUnmanaged(_ v: LLVMValueRef) -> LLVMValueRef { e.toUnmanaged(v) }
    func runtimeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef], varArg: Bool) -> (LLVMValueRef, LLVMTypeRef) { e.runtimeFn(name, ret: ret, params: params, varArg: varArg) }
    func intFormat() -> LLVMValueRef { e.intFormat() }
    func strFormat() -> LLVMValueRef { e.strFormat() }

    func fail(_ msg: String, _ span: Span) { e.fail(msg, span) }   // → LLVMGen (shared error sink)
}
