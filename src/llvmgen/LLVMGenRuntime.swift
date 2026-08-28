import support
import LLVM_C

// Runtime/GC-ABI emission (moved into the shared emitter, ssair.md): the function-creation
// seam, runtime-fn declarations, the inert mutator seams (`__nomu_poll`/`__nomu_gc_alloc`/
// `__nomu_write_barrier`), managed allocation + the write-barrier store, and small LLVM helpers
// (`buildCall`/`structGEP`/`gepByte`/`toUnmanaged`/string literals). Both egresses emit through here.
extension LLVMGen {
    // The single seam through which every LLVM function is created; attaches a `DISubprogram` when
    // `debug` is given. Every function we emit a body for is `gc "statepoint-example"`; runtime C
    // declarations pass `gc: false`.
    func emitFunction(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef],
                      varArg: Bool = false, gc: Bool = true,
                      debug: (name: String, line: Int)? = nil) -> (fn: LLVMValueRef, ty: LLVMTypeRef) {
        let ty = fnType(ret, params, varArg: varArg)
        let fn = LLVMAddFunction(mod, name, ty)!
        if gc { LLVMSetGC(fn, "statepoint-example") }
        if let debug = debug, let sp = makeSubprogram(debug.name, linkage: name, line: debug.line) {
            LLVMSetSubprogram(fn, sp)
        }
        return (fn, ty)
    }

    // Runtime C functions that never allocate on the GC heap and never park the fiber — their calls
    // stay plain (no statepoint). Conservative: mislabeling a GC-triggering call as leaf is unsound.
    static let gcLeafRuntimeFns: Set<String> = [
        "printf", "rt_str_lit", "rt_mutex_new", "rt_mutex_unlock",
        "rt_bounds_trap",   // aborts, never allocates
        "memcpy",           // libc block copy — never allocates
        "memset",           // libc fill — never allocates
        "rt_gc_write_barrier",   // remembers the mutated object; never triggers GC
    ]

    var funcAttrIndex: LLVMAttributeIndex { LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex)) }

    func markGCLeaf(_ fn: LLVMValueRef) {
        let name = "gc-leaf-function"
        let attr = LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, attr)
    }

    func addAlwaysInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("alwaysinline", "alwaysinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    func addNoInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("noinline", "noinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    // Prelude functions that read their own stack frame (`llvm.frameaddress`/`returnaddress`, task 150 the
    // pcsp walk) must not be inlined — inlining would resolve those intrinsics to the caller's frame and
    // shift the walk by one frame. Kept as a name set until a per-function attribute exists.
    static let noInlineFns: Set<String> = ["rtCollectRoots"]

    // Build a stub seam's body without disturbing the caller's builder position / debug location.
    func withStubBody(_ fn: LLVMValueRef, _ build: () -> Void) {
        let savedBlock = LLVMGetInsertBlock(b)
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        if di != nil { LLVMSetCurrentDebugLocation2(b, nil) }
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        build()
        if let savedBlock = savedBlock { LLVMPositionBuilderAtEnd(b, savedBlock) }
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

    func runtimeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef], varArg: Bool)
        -> (LLVMValueRef, LLVMTypeRef)
    {
        if let cached = runtimeFns[name] { return cached }
        let f = emitFunction(name, ret: ret, params: params, varArg: varArg, gc: false)
        if LLVMGen.gcLeafRuntimeFns.contains(name) { markGCLeaf(f.0) }
        runtimeFns[name] = f
        return f
    }

    func buildCall(_ fn: LLVMValueRef, _ ty: LLVMTypeRef, _ args: [LLVMValueRef?]) -> LLVMValueRef? {
        var a = args
        return a.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, ty, fn, $0.baseAddress, UInt32(args.count), "")
        }
    }

    func structGEP(_ structTy: LLVMTypeRef, _ addr: LLVMValueRef, _ idx: Int) -> LLVMValueRef {
        var idxs: [LLVMValueRef?] = [LLVMConstInt(i32, 0, 0), LLVMConstInt(i32, UInt64(idx), 0)]
        return idxs.withUnsafeMutableBufferPointer {
            LLVMBuildGEP2(b, structTy, addr, $0.baseAddress, 2, "fld")
        }!
    }

    // GEP a managed pointer by a byte offset (`i8`-typed indexing), yielding a p1 to that byte.
    func gepByte(_ ptr: LLVMValueRef, _ off: LLVMValueRef) -> LLVMValueRef {
        let i8 = LLVMInt8TypeInContext(ctx)
        var idx: LLVMValueRef? = off
        return withUnsafeMutablePointer(to: &idx) { LLVMBuildGEP2(b, i8, ptr, $0, 1, "aoff")! }
    }

    // The C-ABI boundary cast (D1): a managed reference handed to a C `void*` is cast (1 → 0).
    func toUnmanaged(_ v: LLVMValueRef) -> LLVMValueRef { LLVMBuildAddrSpaceCast(b, v, i8ptr, "to0")! }
    // The reverse boundary cast: a runtime-held `void*` (addrspace 0) back to a managed `p1` — used
    // where a fiber's `env` re-enters managed code (the SSAIR spawn thunk, D1/D4).
    func toManaged(_ v: LLVMValueRef) -> LLVMValueRef { LLVMBuildAddrSpaceCast(b, v, p1, "to1")! }

    func rtAlloc() -> LLVMValueRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).0 }
    func rtAllocTy() -> LLVMTypeRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).1 }

    // Allocate a managed (GC-heap) object of `bytes` bytes through the `__nomu_gc_alloc` seam.
    func rtAllocManaged(_ bytes: LLVMValueRef) -> LLVMValueRef {
        let g = nomuGcAlloc()
        return buildCall(g.0, g.1, [bytes])!
    }

    // A stack slot placed in `currentFn`'s **entry block** (never the current insertion point): LLVM
    // only treats entry-block allocas as fixed frame slots, so an alloca in a loop body would grow the
    // stack every iteration. A scratch builder keeps the main builder's position untouched. Shared by
    // both egresses (the NOIR walker keeps its own copy while it lives).
    func entryAlloca(_ ty: LLVMTypeRef, _ name: String) -> LLVMValueRef {
        guard let fn = currentFn, let entry = LLVMGetEntryBasicBlock(fn) else {
            return LLVMBuildAlloca(b, ty, name)!
        }
        let tmp = LLVMCreateBuilderInContext(ctx)!
        defer { LLVMDisposeBuilder(tmp) }
        if let first = LLVMGetFirstInstruction(entry) {
            LLVMPositionBuilderBefore(tmp, first)
        } else {
            LLVMPositionBuilderAtEnd(tmp, entry)
        }
        return LLVMBuildAlloca(tmp, ty, name)!
    }

    func intFormat() -> LLVMValueRef {
        if let f = intFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%lld", "fmt_int")!
        intFmt = f
        return f
    }

    func strFormat() -> LLVMValueRef {
        if let f = strFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%.*s", "fmt_str")!
        strFmt = f
        return f
    }

    func lowerStringLit(_ s: String) -> LLVMValueRef {
        let data = LLVMBuildGlobalStringPtr(b, s, "str")!
        let len = LLVMConstInt(i64, UInt64(s.utf8.count), 0)
        let (fn, ty) = runtimeFn("rt_str_lit", ret: strTy, params: [i8ptr, i64], varArg: false)
        return buildCall(fn, ty, [data, len])!
    }

    // The external stop-world flag (`volatile int __nomu_stop_world`) the poll tests.
    func stopWorldGlobal() -> LLVMValueRef {
        if let g = stopWorldGlobalCache { return g }
        let g = LLVMAddGlobal(mod, i32, "__nomu_stop_world")!   // no initializer → external declaration
        stopWorldGlobalCache = g
        return g
    }

    // The `__nomu_poll` seam: load the stop-world flag; if set, call the (non-leaf) slow path (a
    // statepoint). `alwaysinline` collapses the fast path into each poll site.
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

    // The `__nomu_gc_alloc` seam: the inline bump-pointer fast path, tail-calling `rt_alloc` (a
    // statepoint) on the slow path. Returned memory is zeroed. `inlineAlloc` off reverts to the
    // out-of-line body for A/B measurement.
    func nomuGcAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = gcAllocFn { return g }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_gc_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")   // its slow-path `rt_alloc` call is a statepoint
        addAlwaysInline(fn)
        guard inlineAlloc else {
            withStubBody(fn) { LLVMBuildRet(b, buildCall(rtAlloc(), rtAllocTy(), [LLVMGetParam(fn, 0)])!) }
            gcAllocFn = (fn, ty)
            return gcAllocFn!
        }
        let gOff = LLVMAddGlobal(mod, i64, "__nomu_bump_offset")!
        let gMax = LLVMAddGlobal(mod, i64, "__nomu_max_non_los")!
        let gMut = LLVMAddGlobal(mod, i8ptr, "rt_mutator")!
        LLVMSetThreadLocal(gMut, 1)
        // task 150 — under `NOMU_GC_PLAN=nomu` this extern flag (set at init) routes allocation at the
        // self-hosted Nomu allocator: the MMTk-TLAB fast path is disabled and the slow path branches to it.
        let gSelf = LLVMAddGlobal(mod, i8, "__nomu_selfhosted_alloc")!
        let memset = runtimeFn("memset", ret: i8ptr, params: [i8ptr, i32, i64], varArg: false)
        withStubBody(fn) {
            let size = LLVMGetParam(fn, 0)!
            let fastBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.fast")!
            let bumpBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.bump")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.slow")!
            let selfBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.self")!
            let mmtkBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.mmtk")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.done")!
            let off = LLVMBuildLoad2(b, i64, gOff, "bump.off")!
            let offOk = LLVMBuildICmp(b, LLVMIntNE, off, LLVMConstInt(i64, .max, 0), "off.ok")!
            let mut = LLVMBuildLoad2(b, i8ptr, gMut, "mutator")!
            let mutOk = LLVMBuildICmp(b, LLVMIntNE, mut, LLVMConstPointerNull(i8ptr), "mut.ok")!
            let maxlos = LLVMBuildLoad2(b, i64, gMax, "maxlos")!
            let sizeOk = LLVMBuildICmp(b, LLVMIntULE, size, maxlos, "size.ok")!
            let selfOn = LLVMBuildLoad2(b, i8, gSelf, "selfhost")!
            let selfOff = LLVMBuildICmp(b, LLVMIntEQ, selfOn, LLVMConstInt(i8, 0, 0), "self.off")!
            let g12 = LLVMBuildAnd(b, LLVMBuildAnd(b, offOk, mutOk, "g1"), sizeOk, "g12")!
            let canFast = LLVMBuildAnd(b, g12, selfOff, "canfast")!   // self-hosted plan never fast-paths
            LLVMBuildCondBr(b, canFast, fastBB, slowBB)
            LLVMPositionBuilderAtEnd(b, fastBB)
            let cursorPtr = gepByte(mut, off)
            let cursor = LLVMBuildLoad2(b, i64, cursorPtr, "cursor")!
            let aligned = LLVMBuildAnd(b, LLVMBuildAdd(b, cursor, LLVMConstInt(i64, 7, 0), "c+7"),
                                       LLVMConstInt(i64, ~UInt64(7), 0), "aligned")!
            let off8 = LLVMBuildAdd(b, off, LLVMConstInt(i64, 8, 0), "off+8")!
            let limit = LLVMBuildLoad2(b, i64, gepByte(mut, off8), "limit")!
            let newCursor = LLVMBuildAdd(b, aligned, size, "newcursor")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntULE, newCursor, limit, "fits"), bumpBB, slowBB)
            LLVMPositionBuilderAtEnd(b, bumpBB)
            LLVMBuildStore(b, newCursor, cursorPtr)
            let obj = LLVMBuildIntToPtr(b, aligned, p1, "obj")!
            _ = buildCall(memset.0, memset.1, [toUnmanaged(obj), LLVMConstInt(i32, 0, 0), size])
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            LLVMBuildCondBr(b, selfOff, mmtkBB, selfBB)   // flag off → MMTk; on → self-hosted
            LLVMPositionBuilderAtEnd(b, selfBB)
            let selfP = buildCall(nomuSelfhostAlloc().0, nomuSelfhostAlloc().1, [size])!
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, mmtkBB)
            let mmtkP = buildCall(rtAlloc(), rtAllocTy(), [size])!
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, doneBB)
            let phi = LLVMBuildPhi(b, p1, "obj")!
            var vals: [LLVMValueRef?] = [obj, selfP, mmtkP]
            var blks: [LLVMBasicBlockRef?] = [bumpBB, selfBB, mmtkBB]
            vals.withUnsafeMutableBufferPointer { vp in
                blks.withUnsafeMutableBufferPointer { bp in
                    LLVMAddIncoming(phi, vp.baseAddress, bp.baseAddress, 3)
                }
            }
            LLVMBuildRet(b, phi)
        }
        gcAllocFn = (fn, ty)
        return gcAllocFn!
    }

    // The self-hosted allocation slow path (task 150): route allocation at the Nomu Immix allocator in the
    // runtime prelude (`rtImmixNew` / `rtImmixAlloc`, rung 3 increment 150.3.2). On first call it creates
    // one Immix space and caches its descriptor in `__nomu_selfhost_space`; each call bumps a chunk within
    // the current 32 KiB block (refilling from the block pool on overflow) and produces the managed object
    // via `ptrtoint`→`inttoptr` to `p1` — the same integer→`p1` step the fast path uses, which
    // `RewriteStatepointsForGC` accepts as a fresh GC base (no `addrspacecast`, no intrinsic). The block
    // memory is fresh-zeroed by `rt_raw_alloc` and never reused while non-collecting, so the object is
    // zero-initialized with no memset. The allocator holds no `p1`; the seam produces it here. (Rung 1's
    // single-arena bump `rtArenaNew`/`rtBumpAlloc` stays in the prelude for its own tests.)
    func nomuSelfhostAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let s = selfhostAllocFn { return s }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_selfhost_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")
        // Get-or-add: `RawPtr.gcSelfhostSpace()` (the tracer's reach into this space) may have created the
        // same global first, so share it rather than minting a duplicate symbol.
        let gSpace = LLVMGetNamedGlobal(mod, "__nomu_selfhost_space") ?? {
            let g = LLVMAddGlobal(mod, i8ptr, "__nomu_selfhost_space")!
            LLVMSetInitializer(g, LLVMConstPointerNull(i8ptr))
            LLVMSetLinkage(g, LLVMInternalLinkage)
            return g
        }()
        // The runtime prelude is always compiled in, so its allocator functions are declared. Guard
        // defensively: a missing prelude falls back to a null return rather than a codegen crash.
        guard let immixNew = callables["f:rtImmixNew"], let immixAlloc = callables["f:rtImmixAlloc"] else {
            withStubBody(fn) { LLVMBuildRet(b, LLVMConstPointerNull(p1)) }
            selfhostAllocFn = (fn, ty)
            return selfhostAllocFn!
        }
        let numBlocks = LLVMConstInt(i64, UInt64(8192), 0)   // 8192 × 32 KiB = 256 MiB heap
        withStubBody(fn) {
            let size = LLVMGetParam(fn, 0)!
            let entryBB = LLVMGetInsertBlock(b)!
            let mkBB = LLVMAppendBasicBlockInContext(ctx, fn, "space.mk")!
            let useBB = LLVMAppendBasicBlockInContext(ctx, fn, "space.use")!
            let space0 = LLVMBuildLoad2(b, i8ptr, gSpace, "space")!
            let isNull = LLVMBuildICmp(b, LLVMIntEQ, space0, LLVMConstPointerNull(i8ptr), "space.null")!
            LLVMBuildCondBr(b, isNull, mkBB, useBB)
            LLVMPositionBuilderAtEnd(b, mkBB)
            let made = buildCall(immixNew.fn, immixNew.ty, [numBlocks])!
            LLVMBuildStore(b, made, gSpace)
            LLVMBuildBr(b, useBB)
            LLVMPositionBuilderAtEnd(b, useBB)
            let space = LLVMBuildPhi(b, i8ptr, "space.p")!
            var avals: [LLVMValueRef?] = [space0, made]
            var ablks: [LLVMBasicBlockRef?] = [entryBB, mkBB]
            avals.withUnsafeMutableBufferPointer { vp in
                ablks.withUnsafeMutableBufferPointer { bp in
                    LLVMAddIncoming(space, vp.baseAddress, bp.baseAddress, 2)
                }
            }
            let raw = buildCall(immixAlloc.fn, immixAlloc.ty, [space, size])!
            let addr = LLVMBuildPtrToInt(b, raw, i64, "raw.i")!
            let obj = LLVMBuildIntToPtr(b, addr, p1, "obj")!
            LLVMBuildRet(b, obj)
        }
        selfhostAllocFn = (fn, ty)
        return selfhostAllocFn!
    }

    // The `__nomu_write_barrier` seam: a post-store object-remembering barrier with an inlined fast
    // path (barrier off / already-remembered) and an out-of-line slow path on first mutation.
    func nomuWriteBarrier() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = barrierFn { return g }
        let i8 = LLVMInt8TypeInContext(ctx)!
        let ty = fnType(voidTy, [p1, p1, p1])
        let fn = LLVMAddFunction(mod, "__nomu_write_barrier", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        let rtBarrier = runtimeFn("rt_gc_write_barrier", ret: voidTy, params: [i8ptr, i8ptr, i8ptr], varArg: false)
        let gActive = LLVMAddGlobal(mod, i8, "__nomu_barrier_active")!
        let gBase = LLVMAddGlobal(mod, i64, "__nomu_logbit_base")!
        let gRegion = LLVMAddGlobal(mod, i8, "__nomu_logbit_log_region")!
        withStubBody(fn) {
            let obj = LLVMGetParam(fn, 0)!, slot = LLVMGetParam(fn, 1)!, val = LLVMGetParam(fn, 2)!
            LLVMBuildStore(b, val, slot)   // *slot = val (barrier is post-store)
            let onBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.on")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.done")!
            let active = LLVMBuildLoad2(b, i8, gActive, "bar.active")
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, active, LLVMConstInt(i8, 0, 0), "bar.on?"), onBB, doneBB)
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

    // Store `val` into a field at `slot` of object `objBase`. A managed reference stored into a heap
    // object goes through the write-barrier seam; everything else is a plain store.
    func storeField(_ objBase: LLVMValueRef!, _ slot: LLVMValueRef!, _ val: LLVMValueRef!) {
        if LLVMTypeOf(val) == p1, LLVMGetPointerAddressSpace(LLVMTypeOf(objBase)) == 1 {
            let bar = nomuWriteBarrier()
            _ = buildCall(bar.0, bar.1, [objBase, slot, val])
        } else {
            LLVMBuildStore(b, val, slot)
        }
    }
}
