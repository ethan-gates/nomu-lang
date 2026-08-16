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

    // The external stop-world flag (`volatile int __nomu_stop_world`, runtime.c) the poll tests.
    func stopWorldGlobal() -> LLVMValueRef {
        if let g = stopWorldGlobalCache { return g }
        let g = LLVMAddGlobal(mod, i32, "__nomu_stop_world")!   // no initializer → external declaration
        stopWorldGlobalCache = g
        return g
    }

    // The `__nomu_poll` seam (M6 · 6.2.3, Q3 branch-on-flag). Filled: load the per-process stop-world
    // flag; if unset (the common case) fall through — a plain load + test + branch, no statepoint; if
    // set, call `__nomu_gc_poll_slow`, which is **not** `gc-leaf`, so that call is a statepoint whose
    // stack map records the loop's live roots, and the carrier parks there precisely scannable (6.2.1).
    // `alwaysinline` + the pass pipeline's `always-inline` (LLVMBridge) collapse the fast path into the
    // loop, so only the cold slow path carries statepoint cost (Q4: the poll stays cheap).
    func nomuPoll() -> (LLVMValueRef, LLVMTypeRef) {
        if let p = pollFn { return p }
        let ty = fnType(voidTy, [])
        let fn = LLVMAddFunction(mod, "__nomu_poll", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        addAlwaysInline(fn)   // not `gc-leaf`: the slow path calls a statepoint
        let flag = stopWorldGlobal()
        let slow = runtimeFn("__nomu_gc_poll_slow", ret: voidTy, params: [], varArg: false)
        withStubBody(fn) {
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.slow")
            let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.cont")
            let v = LLVMBuildLoad2(b, i32, flag, "stopreq")!
            LLVMSetVolatile(v, 1)
            let stop = LLVMBuildICmp(b, LLVMIntNE, v, LLVMConstInt(i32, 0, 0), "stop")
            LLVMBuildCondBr(b, stop, slowBB, contBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            _ = buildCall(slow.0, slow.1, [])
            LLVMBuildBr(b, contBB)
            LLVMPositionBuilderAtEnd(b, contBB)
            LLVMBuildRetVoid(b)
        }
        pollFn = (fn, ty)
        return pollFn!
    }

    func emitSafepointPoll() {
        let p = nomuPoll()
        _ = buildCall(p.0, p.1, [])
    }

    // The `__nomu_gc_alloc` seam: `ptr addrspace(1) (i64 size)`, emitted at every managed-object
    // allocation. §6.6.2 — the inline bump-pointer fast path. Read the per-carrier mutator (a thread-
    // local, §6.6.1) and the published `{cursor, limit}` `BumpPointer` at `__nomu_bump_offset`; bump the
    // cursor and return it when the object fits and is not LOS-sized; else tail-call `rt_alloc` (the
    // slow path — a statepoint, so this function is **not** `gc-leaf`). The returned memory is zeroed
    // (Nomu's zero-init-fields contract; the actor mailbox and array buffers rely on it), matching
    // `rt_alloc`'s `memset`. The bump loads/stores sit in a call-free block, so nothing hoists across a
    // safepoint (the only safepoint is the slow-path `rt_alloc` call, which clobbers the mutator memory).
    func nomuGcAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = gcAllocFn { return g }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_gc_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")   // its slow-path `rt_alloc` call is a statepoint
        addAlwaysInline(fn)
        // A/B: revert to the pre-6.6 out-of-line body when the inline path is disabled.
        guard inlineAlloc else {
            withStubBody(fn) { LLVMBuildRet(b, buildCall(rtAlloc(), rtAllocTy(), [LLVMGetParam(fn, 0)])!) }
            gcAllocFn = (fn, ty)
            return gcAllocFn!
        }
        // External state published by the GC binding (§6.6.1): the Default-semantics bump offset, the
        // LOS threshold, and the per-carrier mutator (thread-local). No initializer → declarations.
        let gOff = LLVMAddGlobal(mod, i64, "__nomu_bump_offset")!
        let gMax = LLVMAddGlobal(mod, i64, "__nomu_max_non_los")!
        let gMut = LLVMAddGlobal(mod, i8ptr, "rt_mutator")!
        LLVMSetThreadLocal(gMut, 1)
        let memset = runtimeFn("memset", ret: i8ptr, params: [i8ptr, i32, i64], varArg: false)
        withStubBody(fn) {
            let size = LLVMGetParam(fn, 0)!
            let fastBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.fast")!
            let bumpBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.bump")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.done")!
            // entry guards: fast path only if the offset is published (!= usize::MAX), the mutator is
            // bound (!= null — else lazy-bind happens in `rt_alloc`), and the size is not LOS-routed.
            let off = LLVMBuildLoad2(b, i64, gOff, "bump.off")!
            let offOk = LLVMBuildICmp(b, LLVMIntNE, off, LLVMConstInt(i64, .max, 0), "off.ok")!
            let mut = LLVMBuildLoad2(b, i8ptr, gMut, "mutator")!
            let mutOk = LLVMBuildICmp(b, LLVMIntNE, mut, LLVMConstPointerNull(i8ptr), "mut.ok")!
            let maxlos = LLVMBuildLoad2(b, i64, gMax, "maxlos")!
            let sizeOk = LLVMBuildICmp(b, LLVMIntULE, size, maxlos, "size.ok")!
            let canFast = LLVMBuildAnd(b, LLVMBuildAnd(b, offOk, mutOk, "g1"), sizeOk, "canfast")!
            LLVMBuildCondBr(b, canFast, fastBB, slowBB)
            // fast: load cursor/limit; align the cursor to 8 (a no-op for our 8-aligned sizes, kept to
            // match MMTk's `align_allocation`); bump; take it if it fits.
            LLVMPositionBuilderAtEnd(b, fastBB)
            let cursorPtr = gepByte(mut, off)
            let cursor = LLVMBuildLoad2(b, i64, cursorPtr, "cursor")!
            let aligned = LLVMBuildAnd(b, LLVMBuildAdd(b, cursor, LLVMConstInt(i64, 7, 0), "c+7"),
                                       LLVMConstInt(i64, ~UInt64(7), 0), "aligned")!
            let off8 = LLVMBuildAdd(b, off, LLVMConstInt(i64, 8, 0), "off+8")!
            let limit = LLVMBuildLoad2(b, i64, gepByte(mut, off8), "limit")!
            let newCursor = LLVMBuildAdd(b, aligned, size, "newcursor")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntULE, newCursor, limit, "fits"), bumpBB, slowBB)
            // bump: publish the new cursor, form the object at the aligned address, zero it.
            LLVMPositionBuilderAtEnd(b, bumpBB)
            LLVMBuildStore(b, newCursor, cursorPtr)
            let obj = LLVMBuildIntToPtr(b, aligned, p1, "obj")!
            _ = buildCall(memset.0, memset.1, [toUnmanaged(obj), LLVMConstInt(i32, 0, 0), size])
            LLVMBuildBr(b, doneBB)
            // slow: out-of-line allocate (handles lazy bind, TLAB refill, and LOS). A statepoint.
            LLVMPositionBuilderAtEnd(b, slowBB)
            let slowP = buildCall(rtAlloc(), rtAllocTy(), [size])!
            LLVMBuildBr(b, doneBB)
            // done: the object from whichever path taken.
            LLVMPositionBuilderAtEnd(b, doneBB)
            let phi = LLVMBuildPhi(b, p1, "obj")!
            var vals: [LLVMValueRef?] = [obj, slowP]
            var blks: [LLVMBasicBlockRef?] = [bumpBB, slowBB]
            vals.withUnsafeMutableBufferPointer { vp in
                blks.withUnsafeMutableBufferPointer { bp in
                    LLVMAddIncoming(phi, vp.baseAddress, bp.baseAddress, 2)
                }
            }
            LLVMBuildRet(b, phi)
        }
        gcAllocFn = (fn, ty)
        return gcAllocFn!
    }

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
    func nomuWriteBarrier() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = barrierFn { return g }
        let i8 = LLVMInt8TypeInContext(ctx)!
        let ty = fnType(voidTy, [p1, p1, p1])
        let fn = LLVMAddFunction(mod, "__nomu_write_barrier", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        let rtBarrier = runtimeFn("rt_gc_write_barrier", ret: voidTy, params: [i8ptr, i8ptr, i8ptr], varArg: false)
        // External globals published by the GC binding (no initializer → declarations).
        let gActive = LLVMAddGlobal(mod, i8, "__nomu_barrier_active")!
        let gBase = LLVMAddGlobal(mod, i64, "__nomu_logbit_base")!
        let gRegion = LLVMAddGlobal(mod, i8, "__nomu_logbit_log_region")!
        withStubBody(fn) {
            let obj = LLVMGetParam(fn, 0)!, slot = LLVMGetParam(fn, 1)!, val = LLVMGetParam(fn, 2)!
            LLVMBuildStore(b, val, slot)   // *slot = val (the field write; barrier is post-store)
            let onBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.on")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.done")!
            // if (!__nomu_barrier_active) return;
            let active = LLVMBuildLoad2(b, i8, gActive, "bar.active")
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, active, LLVMConstInt(i8, 0, 0), "bar.on?"), onBB, doneBB)
            // on: region = addr(obj) >> log_region;  byte = *(base + (region >> 3));  bit = (byte >> (region & 7)) & 1
            LLVMPositionBuilderAtEnd(b, onBB)
            let objInt = LLVMBuildPtrToInt(b, obj, i64, "obj.int")
            let logR = LLVMBuildZExt(b, LLVMBuildLoad2(b, i8, gRegion, "logR8"), i64, "logR")
            let region = LLVMBuildLShr(b, objInt, logR, "region")
            let baseV = LLVMBuildLoad2(b, i64, gBase, "logbit.base")
            let byteOff = LLVMBuildLShr(b, region, LLVMConstInt(i64, 3, 0), "byteoff")
            let metaPtr = LLVMBuildIntToPtr(b, LLVMBuildAdd(b, baseV, byteOff, "metaint"), i8ptr, "metaptr")
            let byte = LLVMBuildLoad2(b, i8, metaPtr, "logbyte")
            let bitpos = LLVMBuildTrunc(b, LLVMBuildAnd(b, region, LLVMConstInt(i64, 7, 0), "bp"), i8, "bitpos")
            let bit = LLVMBuildAnd(b, LLVMBuildLShr(b, byte, bitpos, "sh"), LLVMConstInt(i8, 1, 0), "bit")
            // unlogged (bit == 1) → slow path; else done.
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, bit, LLVMConstInt(i8, 0, 0), "unlogged"), slowBB, doneBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            _ = buildCall(rtBarrier.0, rtBarrier.1, [toUnmanaged(obj), toUnmanaged(slot), toUnmanaged(val)])
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, doneBB)
            LLVMBuildRetVoid(b)
        }
        barrierFn = (fn, ty)
        return barrierFn!
    }

    // Store `val` into a field at `slot` of the object `objBase`. A managed reference (`addrspace(1)`
    // value) stored into a *heap* object goes through the write-barrier seam; everything else is a
    // plain store — value-typed fields are not GC references, and a store into a stack-allocated object
    // (6.5.2/6.5.3, an addrspace(0) base) needs no barrier: the stack slot is a root scanned every GC,
    // not a remembered-set entry, and the barrier's ABI expects an addrspace(1) object regardless.
    func storeField(_ objBase: LLVMValueRef!, _ slot: LLVMValueRef!, _ val: LLVMValueRef!) {
        if LLVMTypeOf(val) == p1, LLVMGetPointerAddressSpace(LLVMTypeOf(objBase)) == 1 {
            let bar = nomuWriteBarrier()
            _ = buildCall(bar.0, bar.1, [objBase, slot, val])
        } else {
            LLVMBuildStore(b, val, slot)
        }
    }

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
                case "__int_double_double", "__double_int_int": return args.contains { exprHasSafepoint($0.value) }   // pure sitofp / round+fptosi
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

    func buildCall(_ fn: LLVMValueRef, _ ty: LLVMTypeRef, _ args: [LLVMValueRef?]) -> LLVMValueRef? {
        var a = args
        return a.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, ty, fn, $0.baseAddress, UInt32(args.count), "")
        }
    }

    // 8-byte slots an LLVM value type occupies. Every value type we build is 8-aligned and a
    // multiple of 8 (i64, pointers, {i8*,i64}, {ptr,ptr}, and structs of those), so a struct is
    // the sum of its members — used to size heap envs.
    func abiSlots(_ t: LLVMTypeRef) -> Int {
        switch LLVMGetTypeKind(t) {
        case LLVMPointerTypeKind, LLVMIntegerTypeKind:
            return 1
        case LLVMStructTypeKind:
            var n = 0
            for i in 0..<LLVMCountStructElementTypes(t) { n += abiSlots(LLVMStructGetTypeAtIndex(t, i)) }
            return n
        default:
            return 1
        }
    }

    // `void* rt_alloc(size_t)` — the runtime allocator (bump-and-leak until the M6 GC). We declare
    // it as returning `ptr addrspace(1)`: the C ABI returns a plain 64-bit pointer, bit-identical to
    // an addrspace(1) pointer on arm64 (addrspace 1 carries no codegen difference here), and this
    // makes the allocation call itself a GC base the rewrite pass can track. An `addrspacecast
    // (0 → 1)` at the call site would *not* work — `RewriteStatepointsForGC::findBaseDefiningValue`
    // rejects a base introduced by a differing-addrspace cast (it strips pointer casts and asserts
    // the address spaces match). So the managed address space enters at the allocator, not via a cast.
    func rtAlloc() -> LLVMValueRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).0 }
    func rtAllocTy() -> LLVMTypeRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).1 }

    // Allocate a managed (GC-heap) object of `bytes` bytes through the `__nomu_gc_alloc` seam
    // (8.4.4, D5) — inert now (the seam tail-calls `rt_alloc`), the inline TLAB fast path in M6.
    // The result is addrspace(1): the tracked managed reference the mutator holds (D1).
    func rtAllocManaged(_ bytes: LLVMValueRef) -> LLVMValueRef {
        let g = nomuGcAlloc()
        return buildCall(g.0, g.1, [bytes])!
    }

    // ---- M6 · 6.1.3 — GC pointer maps ----

    // Register a fixed-size object's pointer map (managed-field byte offsets) plus its total byte size,
    // and return its type-id (the shared index into `typeMaps`/`typeSizes`/`typeKinds`/`typeStrides`).
    func registerMap(_ offsets: [Int32], sizeBytes: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(offsets)
        typeSizes.append(sizeBytes)
        typeKinds.append(0)      // fixed
        typeStrides.append(0)
        return id
    }

    // Register an array buffer type-id (M6 stdlib · Slice 4): `elementOffsets` are the managed-pointer
    // byte offsets *within one element*, `stride` its byte size. The object's total size and live
    // extent come from its `cap`/`len` at run time, so no fixed size is stored.
    func registerArrayMap(_ elementOffsets: [Int32], stride: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // array
        typeStrides.append(stride)
        return id
    }

    // Type-id for a class/actor heap type; assigns one (and computes its pointer map) on first use.
    func typeId(forHeapType name: String) -> UInt64 {
        if let id = typeIds[name] { return id }
        let fieldTypes: [Type] = classMap[name].map { $0.fields.map(\.type) }
            ?? actorMap[name].map { $0.fields.map(\.type) } ?? []
        let isActor = actorMap[name] != nil
        var offsets: [Int32] = []
        var slot = 1   // header occupies slot 0; fields (and the actor's trailing mu) follow
        for ft in fieldTypes {
            collectManagedOffsets(ft, baseSlot: slot, into: &offsets)
            slot += slotCount(ft)
        }
        // slot is now 1 + Σ field slots (matching the class allocation site); an actor reserves one
        // more slot for its trailing mailbox pointer (the actor allocation site's `2 + Σ`). That
        // pointer is a managed GC reference (M6 · 6.4), so it is scanned.
        if isActor { offsets.append(Int32(slot * 8)) }
        let totalSlots = slot + (isActor ? 1 : 0)
        let id = registerMap(offsets, sizeBytes: Int32(totalSlots * 8))
        typeIds[name] = id
        return id
    }

    // Type-id for a fused closure object `{ header, fn, caps… }`: managed captures (scalar `p1`) are
    // scanned, `fn` (addr0) is skipped. Each closure site is its own shape (captures vary), so a
    // fresh map is registered per closure.
    func closureTypeId(_ caps: [Capture]) -> UInt64 {
        var offsets: [Int32] = []
        var slot = 2   // header(0) + fn(1); captures follow
        for cap in caps {
            if cap.local.ty == p1 { offsets.append(Int32(slot * 8)) }
            slot += abiSlots(cap.local.ty)
        }
        return registerMap(offsets, sizeBytes: Int32(slot * 8))   // { header, fn, caps… }
    }

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only
    // (byte 16, slot 2); the witness is a static table (Q7). Registered once.
    func anyBoxTypeId() -> UInt64 {
        if let id = anyBoxMapId { return id }
        let id = registerMap([16], sizeBytes: 24)   // { header, witness, payload }
        anyBoxMapId = id
        return id
    }

    // Append the byte offsets of managed (`p1`) pointers within a field of type `t` laid out starting
    // at `baseSlot`. Recurses into inline value structs; String's buffer is runtime-owned (`addr0`)
    // today so it is skipped (Q6), and enum payloads carry no references in the language today (D6).
    func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32]) {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            offsets.append(Int32(baseSlot * 8))   // an Array<T> field is a managed handle pointer (M6)
        case .named(let n, .struct_):
            var s = baseSlot
            for sf in (structMap[n]?.fields ?? []) {
                collectManagedOffsets(sf.type, baseSlot: s, into: &offsets)
                s += slotCount(sf.type)
            }
        case .opaque:
            collectManagedOffsets(concreteUnderlying(t), baseSlot: baseSlot, into: &offsets)
        default:
            break   // int, bool, string (buffer addr0 until Q6 heap-boxes String), enum payload
        }
    }

    // Write the type-id into the object's header (slot 0 at the object base).
    func writeTypeIdHeader(_ obj: LLVMValueRef, _ name: String) {
        LLVMBuildStore(b, LLVMConstInt(i64, typeId(forHeapType: name), 0), obj)
    }

    // Stamp a raw (non-named-type) type-id into an object header — for the mailbox/message objects,
    // which have no Nomu type name (M6 · 6.4).
    func writeTypeIdHeaderRaw(_ obj: LLVMValueRef, _ id: UInt64) {
        LLVMBuildStore(b, LLVMConstInt(i64, id, 0), obj)
    }

    // MARK: - M6 · 6.4 actor mailbox codegen

    // The shared type-id for every mailbox object
    // `{ i64 header, mb_head, mb_tail, i64 scheduled, sched_next }`: mb_head (8), mb_tail (16), and
    // sched_next (32, the scheduled-mailbox-queue link) are managed pointers (scanned); scheduled (24)
    // is a plain int. 40 bytes.
    func mailboxTypeIdValue() -> UInt64 {
        if let id = mailboxTypeId { return id }
        let id = registerMap([8, 16, 32], sizeBytes: 40)
        mailboxTypeId = id
        return id
    }

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

    // Lower an actor handler call `recv.h(args…)` to a fire-and-forget message-send (M6 · 6.4): build
    // the message and hand it to `rt_actor_send`, which enqueues it and returns. The call is void —
    // fire-and-forget is the only actor operation (§9); there is no reply/ask of any kind.
    func lowerActorCall(_ actorName: String, _ handler: String,
                                _ recvValue: LLVMValueRef, _ args: [NOIRExpr], _ span: Span) -> LLVMValueRef? {
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
        for (i, argE) in args.enumerated() {
            guard let v = lowerExpr(argE) else { return nil }
            storeField(msg, structGEP(mt, msg, msgArgIndex(i)), v)
        }
        let mailbox = LLVMBuildLoad2(b, p1, structGEP(at, recvValue, actorMailboxIndex(actorName)), "mailbox")!
        let send = runtimeFn("rt_actor_send", ret: voidTy, params: [p1, p1], varArg: false)
        _ = buildCall(send.0, send.1, [mailbox, msg])
        return LLVMConstNull(p1)   // fire-and-forget: no value
    }

    // Emit the flat pointer-map tables the runtime/binding reads (always emitted so runtime.c's
    // externs resolve, even with no heap types): `_data` = per-id `[count, off…]` concatenated,
    // `_index[id]` = that id's start in `_data`, `_count` = number of type-ids.
    func emitTypeMaps() {
        var data: [Int32] = []
        var index: [Int32] = []
        for map in typeMaps {
            index.append(Int32(data.count))
            data.append(Int32(map.count))
            data.append(contentsOf: map)
        }
        emitI32Array("nomu_gc_typemap_data", data.isEmpty ? [0] : data)
        emitI32Array("nomu_gc_typemap_index", index.isEmpty ? [0] : index)
        // Parallel per-type-id byte sizes (6.2.4): `_sizes[id]` = total object size. Same fallback
        // shape as the maps so the runtime externs resolve with no heap types.
        emitI32Array("nomu_gc_typemap_sizes", typeSizes.isEmpty ? [0] : typeSizes)
        // Slice 4 — per-type-id kind (0 fixed / 1 array) + array element stride. Lets the collector
        // size/scan a variable-length array buffer from its `cap`/`len` and per-element map.
        emitI32Array("nomu_gc_typemap_kind", typeKinds.isEmpty ? [0] : typeKinds)
        emitI32Array("nomu_gc_typemap_stride", typeStrides.isEmpty ? [0] : typeStrides)
        let g = LLVMAddGlobal(mod, i64, "nomu_gc_typemap_count")!
        LLVMSetInitializer(g, LLVMConstInt(i64, UInt64(typeMaps.count), 0))
        LLVMSetGlobalConstant(g, 1)
    }

    func emitI32Array(_ name: String, _ vals: [Int32]) {
        var consts: [LLVMValueRef?] = vals.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) }
        let g = LLVMAddGlobal(mod, LLVMArrayType2(i32, UInt64(vals.count)), name)!
        let initv = consts.withUnsafeMutableBufferPointer {
            LLVMConstArray2(i32, $0.baseAddress, UInt64(vals.count))
        }
        LLVMSetInitializer(g, initv)
        LLVMSetGlobalConstant(g, 1)
    }

    // The C-ABI boundary cast (D1): a managed reference handed to a C function that takes a `void*`
    // is cast (1 → 0) for the call. This direction is supported by the rewrite pass (the result is
    // not a GC pointer, so it is never traced as a base). One explicit cast site per crossing keeps
    // the boundary auditable.
    func toUnmanaged(_ v: LLVMValueRef) -> LLVMValueRef { LLVMBuildAddrSpaceCast(b, v, i8ptr, "to0")! }

    func runtimeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef], varArg: Bool)
        -> (LLVMValueRef, LLVMTypeRef)
    {
        if let cached = runtimeFns[name] { return cached }
        let f = emitFunction(name, ret: ret, params: params, varArg: varArg, gc: false)
        if NOIRToLLVM.gcLeafRuntimeFns.contains(name) { markGCLeaf(f.0) }
        runtimeFns[name] = f
        return f
    }

    func intFormat() -> LLVMValueRef {
        if let f = intFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%lld\n", "fmt_int")!
        intFmt = f
        return f
    }

    func strFormat() -> LLVMValueRef {
        if let f = strFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%.*s\n", "fmt_str")!
        strFmt = f
        return f
    }

    func fail(_ msg: String, _ span: Span) {
        if error == nil { error = "\(span): \(msg)" }
    }
}
