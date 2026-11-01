import mangle
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
                      debug: (name: String, line: Int, file: String)? = nil) -> (fn: LLVMValueRef, ty: LLVMTypeRef) {
        let ty = fnType(ret, params, varArg: varArg)
        let fn = LLVMAddFunction(mod, name, ty)!
        if gc { LLVMSetGC(fn, "statepoint-example") }
        if let debug = debug, let sp = makeSubprogram(debug.name, linkage: name, line: debug.line, file: debug.file) {
            LLVMSetSubprogram(fn, sp)
        }
        return (fn, ty)
    }

    // Runtime C functions that never allocate on the GC heap and never park the fiber — their calls
    // stay plain (no statepoint). Conservative: mislabeling a GC-triggering call as leaf is unsound.
    static let gcLeafRuntimeFns: Set<String> = [
        "printf",
        "memcpy",           // libc block copy — never allocates
        "memset",           // libc fill — never allocates
        "free",             // releases unmanaged memory (`RawPtr.free`)
        "write",            // libc write(2) (`Runtime.writeFd`, `Runtime.fatal`) — never allocates or parks
        "read",             // libc read(2) (`Runtime.readFd`) — never allocates or parks
        "poll",             // libc poll(2) (`Runtime.poll`), zero timeout — never allocates or blocks
        "abort",            // never returns
    ]

    var funcAttrIndex: LLVMAttributeIndex { LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex)) }

    func markGCLeaf(_ fn: LLVMValueRef) {
        let name = "gc-leaf-function"
        let attr = LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, attr)
    }

    // Mark one call site `gc-leaf-function`: it never becomes a statepoint, whatever the callee's own marking.
    func markCallGCLeaf(_ call: LLVMValueRef) {
        let name = "gc-leaf-function"
        LLVMAddCallSiteAttribute(call, funcAttrIndex, LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0))
    }

    // Is `fn` marked `gc-leaf-function`? A gc-leaf call never becomes a `gc.statepoint`, so a `"deopt"`
    // operand bundle on it is both pointless and harmful — the backend mis-handles a deopt bundle on an
    // ordinary call — so shaped-root bundles must never ride a gc-leaf call (task 176).
    func isGCLeafFn(_ fn: LLVMValueRef) -> Bool {
        let name = "gc-leaf-function"
        return name.withCString { LLVMGetStringAttributeAtIndex(fn, funcAttrIndex, $0, UInt32(name.utf8.count)) } != nil
    }

    func addAlwaysInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("alwaysinline", "alwaysinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    func addNoInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("noinline", "noinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    // Fetch an existing module global by name, or declare it. Used for runtime externs a seam may build more
    // than once (the alloc body is emitted for both the inlined and the `noinline` rooted variant); a plain
    // `LLVMAddGlobal` would mint a suffixed duplicate that no longer resolves against the runtime symbol.
    func getOrAddGlobal(_ ty: LLVMTypeRef, _ name: String) -> LLVMValueRef {
        LLVMGetNamedGlobal(mod, name) ?? LLVMAddGlobal(mod, ty, name)!
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

    // Reference a Nomu prelude function (`nomu_fn_*`) by its mangled name: use the existing definition
    // (the whole-program CU compiles the prelude) or forward-declare it, matching the known signature.
    // Unlike `emitFunction`, this never creates a duplicate when the symbol already exists.
    func preludeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef]) -> (LLVMValueRef, LLVMTypeRef) {
        let ty = fnType(ret, params, varArg: false)
        if let f = LLVMGetNamedFunction(mod, name) { return (f, ty) }
        return (LLVMAddFunction(mod, name, ty)!, ty)
    }

    // A function of the runtime prelude, by its Nomu name. A normal build has the prelude prepended, so the
    // function is in `callables`; a package or library build (task 174.3.1) suppresses the prepend, so it is
    // declared external by its runtime symbol (`nomu_fn_<name>`) and resolves against the runtime's weak-ODR
    // definition in the final binary.
    func runtimePreludeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef]) -> (fn: LLVMValueRef, ty: LLVMTypeRef) {
        declareFree(name)
        if let c = callables["f:\(name)"] { return (c.fn, c.ty) }
        let f = runtimeFn("nomu_fn_\(name)", ret: ret, params: params, varArg: false)
        return (f.0, f.1)
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
        // While lowering a safepoint instruction, `pendingDeopt` carries the shaped roots live across it
        // (task 176); attach them so a per-site statepoint call (a user call, concat) records them. Attaching
        // to any leaf setup call in the same instruction is harmless — RS4GC ignores a deopt bundle on a
        // non-statepoint call. (The inlined poll/alloc seams take the explicit `*WithDeopt` path instead.)
        // Only the function being lowered takes the bundle — a lazily-built shared seam body (poll / alloc),
        // whose internal calls are emitted while `pendingDeopt` is set, must not pick up the caller's roots
        // (its slots live in another function). Guard on the current insert block's parent.
        if pendingDeoptApplies() && !isGCLeafFn(fn) {
            return buildCallWithDeopt(fn, ty, args, pendingDeopt!)
        }
        var a = args
        return a.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, ty, fn, $0.baseAddress, UInt32(args.count), "")
        }
    }

    // True when a shaped-root `"deopt"` bundle is pending and belongs to the function currently being lowered
    // (task 176). A lazily-built shared seam body (poll / alloc), whose internal calls are emitted while
    // `pendingDeopt` is set, must not pick up the caller's roots — its slots live in another function — so the
    // check is guarded on the current insert block's parent being `currentFn`.
    func pendingDeoptApplies() -> Bool {
        guard let d = pendingDeopt, !d.isEmpty,
              let ib = LLVMGetInsertBlock(b), LLVMGetBasicBlockParent(ib) == currentFn else { return false }
        return true
    }

    // A call carrying a `"deopt"` operand bundle of shaped-root records (task 176 Stage 4): each root is two
    // operands — an i32 shape ordinal and the value's home-slot pointer. `rewrite-statepoints-for-gc` threads
    // the bundle into the `gc.statepoint`, and the inliner propagates it onto an inlined seam's inner
    // statepoint (the poll/alloc slow call), so the stackmap records `(shape-id, slot)` for the walker.
    func buildCallWithDeopt(_ fn: LLVMValueRef, _ ty: LLVMTypeRef, _ args: [LLVMValueRef?],
                            _ deoptOps: [LLVMValueRef?]) -> LLVMValueRef? {
        if deoptOps.isEmpty { return buildCall(fn, ty, args) }
        var ops = deoptOps
        let bundle = ops.withUnsafeMutableBufferPointer { op in
            "deopt".withCString { LLVMCreateOperandBundle($0, 5, op.baseAddress, UInt32(op.count)) }
        }
        var a = args
        var bundles: [LLVMOperandBundleRef?] = [bundle]
        let r = a.withUnsafeMutableBufferPointer { ap in
            bundles.withUnsafeMutableBufferPointer { bp in
                LLVMBuildCallWithOperandBundles(b, ty, fn, ap.baseAddress, UInt32(ap.count),
                                                bp.baseAddress, UInt32(bp.count), "")
            }
        }
        LLVMDisposeOperandBundle(bundle)
        return r
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

    // The C-ABI boundary cast (D1): a managed reference handed to a C `void*` is converted (1 → 0). The
    // address goes through `pinnedAddress`, so the raw pointer is taken where it is used: a plain
    // `addrspacecast` of a loop-invariant reference can be hoisted out of a loop with safepoints, and would
    // then name where the object was before a collection moved it.
    func toUnmanaged(_ v: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildIntToPtr(b, managedAddress(v), i8ptr, "to0")!
    }

    // The integer address of a pointer. A managed (`addrspace(1)`) pointer's address is pinned to its use
    // (`pinnedAddress`); any other pointer converts directly.
    func managedAddress(_ v: LLVMValueRef) -> LLVMValueRef {
        LLVMGetPointerAddressSpace(LLVMTypeOf(v)) == 1 ? pinnedAddress(v) : LLVMBuildPtrToInt(b, v, i64, "addr")!
    }
    // The reverse boundary cast: a runtime-held `void*` (addrspace 0) back to a managed `p1` — used
    // where a fiber's `env` re-enters managed code (the SSAIR spawn thunk, D1/D4).
    func toManaged(_ v: LLVMValueRef) -> LLVMValueRef { LLVMBuildAddrSpaceCast(b, v, p1, "to1")! }

    // Allocate a managed (GC-heap) object of `bytes` bytes through the `__nomu_gc_alloc` seam.
    //
    // When shaped roots are live across this allocation (task 176), the hit path is emitted here, in the
    // allocating function, instead: a collection can run in the slow call, so the shaped roots must ride
    // that call's `"deopt"` bundle, and the always-inliner drops a bundle on the call it collapses. Emitting
    // the slow call in place lets RS4GC record the roots on its statepoint, as `emitSafepointPollWithDeopt`
    // does for the poll.
    func rtAllocManaged(_ bytes: LLVMValueRef) -> LLVMValueRef {
        if pendingDeoptApplies(), let fn = currentFn {
            return emitAllocHitPath(fn, bytes, deoptOps: pendingDeopt!)
        }
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

    func uintFormat() -> LLVMValueRef {
        if let f = uintFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%llu", "fmt_uint")!
        uintFmt = f
        return f
    }

    func strFormat() -> LLVMValueRef {
        if let f = strFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%.*s", "fmt_str")!
        strFmt = f
        return f
    }

    // A string literal lowered in codegen (task 121, the `fromStaticUTF8` role) — no runtime call, both words
    // compile-time constants. Following Swift: a **short** literal (≤ 15 UTF-8 bytes) is a `small` value with
    // the bytes packed inline (tag 0), avoiding any static storage; a **long** literal is `immortal` — `word0`
    // is the static UTF-8 global's address, `word1 = (immortal tag 1 << 60) | byte count`.
    func lowerStringLit(_ s: String) -> LLVMValueRef {
        let bytes = Array(s.utf8)
        if bytes.count <= 15 {
            // `small`: inline bytes at offsets 0–14 (little-endian: byte i at bit i*8 of word0 for i<8, of
            // word1 for 8≤i≤14). Byte 15 = (small tag 0 in the top nibble) | (count in the low nibble).
            var w0: UInt64 = 0, w1: UInt64 = 0
            for (i, byte) in bytes.enumerated() {
                if i < 8 { w0 |= UInt64(byte) << (i * 8) }
                else { w1 |= UInt64(byte) << ((i - 8) * 8) }
            }
            w1 |= UInt64(bytes.count) << 56   // count ≤ 15 → low nibble of byte 15; tag nibble stays 0 (small)
            var sv = LLVMGetUndef(strTy)
            sv = LLVMBuildInsertValue(b, sv, LLVMConstInt(i64, w0, 0), 0, "lit0")!
            sv = LLVMBuildInsertValue(b, sv, LLVMConstInt(i64, w1, 0), 1, "lit1")!
            return sv!
        }
        let data = LLVMBuildGlobalStringPtr(b, s, "str")!
        let count = UInt64(bytes.count) & 0x00FF_FFFF_FFFF_FFFF
        let w0 = LLVMBuildPtrToInt(b, data, i64, "lit.w0")!
        let w1 = LLVMConstInt(i64, (UInt64(1) << 60) | count, 0)   // immortal tag = 1
        var sv = LLVMGetUndef(strTy)
        sv = LLVMBuildInsertValue(b, sv, w0, 0, "lit0")!
        sv = LLVMBuildInsertValue(b, sv, w1, 1, "lit1")!
        return sv!
    }

    // The stop-the-world flag the poll tests: the runtime's `rtStopWorld` static-storage block, an `Int` read
    // by symbol (declared here, defined by the runtime module; the same global when this is that module).
    func stopWorldGlobal() -> LLVMValueRef {
        if let g = stopWorldGlobalCache { return g }
        let g = getOrAddGlobal(i64, Mangle.staticStorage("rtStopWorld", home: []))
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
        let slow = nomuPollSlow()
        withStubBody(fn) {
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.slow")
            let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.cont")
            let v = LLVMBuildLoad2(b, i64, flag, "stopreq")!
            LLVMSetVolatile(v, 1)
            let stop = LLVMBuildICmp(b, LLVMIntNE, v, LLVMConstInt(i64, 0, 0), "stop")
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

    // A loop-header poll that records shaped roots (task 176 Stage 4). The poll is inlined at this site —
    // rather than calling the shared `alwaysinline` `__nomu_poll` — because the always-inliner does not
    // thread a `"deopt"` operand bundle onto the inlined seam's inner statepoint. Emitting the slow-path
    // `__nomu_gc_poll_slow` call here, in the Nomu body, lets the bundle ride it directly, so
    // `rewrite-statepoints-for-gc` records the shaped roots on that statepoint. Fast path is identical to
    // `__nomu_poll`: a volatile flag load + branch. Leaves the builder at the continuation block.
    func emitSafepointPollWithDeopt(_ deoptOps: [LLVMValueRef?]) {
        guard let fn = currentFn else { emitSafepointPoll(); return }
        let flag = stopWorldGlobal()
        let slow = nomuPollSlow()
        let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.slow")
        let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.cont")
        let v = LLVMBuildLoad2(b, i64, flag, "stopreq")!
        LLVMSetVolatile(v, 1)
        let stop = LLVMBuildICmp(b, LLVMIntNE, v, LLVMConstInt(i64, 0, 0), "stop")
        LLVMBuildCondBr(b, stop, slowBB, contBB)
        LLVMPositionBuilderAtEnd(b, slowBB)
        _ = buildCallWithDeopt(slow.0, slow.1, [], deoptOps)
        LLVMBuildBr(b, contBB)
        LLVMPositionBuilderAtEnd(b, contBB)
    }

    // The `__nomu_gc_alloc` seam: the allocation hit path, `alwaysinline`, so every allocation site bumps the
    // carrier's TLAB in place and calls `__nomu_alloc_slow` only on a miss. Returned memory is zeroed.
    func nomuGcAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = gcAllocFn { return g }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_gc_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")   // its slow call is a statepoint
        addAlwaysInline(fn)
        withStubBody(fn) { LLVMBuildRet(b, emitAllocHitPath(fn, LLVMGetParam(fn, 0)!, deoptOps: [])) }
        gcAllocFn = (fn, ty)
        return gcAllocFn!
    }

    // The allocation hit path, built at the builder's position in `fn`. This carrier's record comes from the
    // carrier-local slot (its TLAB is at offset 0); the request, rounded up to 8 bytes, is bumped within the
    // current hole with no call and no lock, and the object is the old cursor, produced as `inttoptr` to `p1`
    // (a fresh GC base the statepoint rewrite accepts). A hole never spans more than one 32 KiB block, so a
    // large object never fits and takes the miss, which routes it to the large-object space. Under
    // NOMU_GC_STRESS the limit stays 0, so every allocation misses; `opt.inline_alloc: false` sends every
    // allocation to the miss for A/B measurement. A miss (no record yet, the hole exhausted, a large object)
    // calls `__nomu_alloc_slow`, carrying `deoptOps`, the shaped roots live across the allocation, when there
    // are any. Leaves the builder at the join and returns the object.
    func emitAllocHitPath(_ fn: LLVMValueRef, _ size: LLVMValueRef, deoptOps: [LLVMValueRef?]) -> LLVMValueRef {
        let slow = nomuAllocSlow()
        let tlabBB = LLVMAppendBasicBlockInContext(ctx, fn, "tlab")!
        let bumpBB = LLVMAppendBasicBlockInContext(ctx, fn, "tlab.bump")!
        let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "tlab.slow")!
        let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "tlab.done")!
        let tlab = emitCarrierLocalGet()
        LLVMBuildCondBr(b, LLVMBuildIsNull(b, tlab, "carrier.none"), slowBB, tlabBB)
        LLVMPositionBuilderAtEnd(b, tlabBB)
        let cur = LLVMBuildLoad2(b, i64, tlab, "tlab.cur")!
        let lim = LLVMBuildLoad2(b, i64, gepByte(tlab, LLVMConstInt(i64, 8, 0)), "tlab.lim")!
        let need = LLVMBuildAnd(b, LLVMBuildAdd(b, size, LLVMConstInt(i64, 7, 0), "sz+7"),
                                LLVMConstInt(i64, ~UInt64(7), 0), "need")!
        let newCur = LLVMBuildAdd(b, cur, need, "tlab.new")!
        let fits = inlineAlloc ? LLVMBuildICmp(b, LLVMIntULE, newCur, lim, "tlab.fits")!
                               : LLVMConstInt(LLVMInt1TypeInContext(ctx), 0, 0)!
        LLVMBuildCondBr(b, fits, bumpBB, slowBB)
        LLVMPositionBuilderAtEnd(b, bumpBB)
        LLVMBuildStore(b, newCur, tlab)
        if countsAllocations {
            // `full` recording: one more object and `need` more bytes on this carrier (only it writes them).
            let objectsAt = gepByte(tlab, LLVMConstInt(i64, 48, 0))
            let bytesAt = gepByte(tlab, LLVMConstInt(i64, 56, 0))
            let objects = LLVMBuildLoad2(b, i64, objectsAt, "tlab.objs")!
            LLVMBuildStore(b, LLVMBuildAdd(b, objects, LLVMConstInt(i64, 1, 0), "tlab.objs1"), objectsAt)
            let bytes = LLVMBuildLoad2(b, i64, bytesAt, "tlab.bytes")!
            LLVMBuildStore(b, LLVMBuildAdd(b, bytes, need, "tlab.bytes1"), bytesAt)
        }
        let fastObj = LLVMBuildIntToPtr(b, cur, p1, "obj.fast")!
        LLVMBuildBr(b, doneBB)
        LLVMPositionBuilderAtEnd(b, slowBB)
        let slowObj = buildCallWithDeopt(slow.0, slow.1, [size], deoptOps)!
        LLVMBuildBr(b, doneBB)
        LLVMPositionBuilderAtEnd(b, doneBB)
        let obj = LLVMBuildPhi(b, p1, "obj")!
        var ovals: [LLVMValueRef?] = [fastObj, slowObj]
        var oblks: [LLVMBasicBlockRef?] = [bumpBB, slowBB]
        ovals.withUnsafeMutableBufferPointer { vp in
            oblks.withUnsafeMutableBufferPointer { bp in
                LLVMAddIncoming(obj, vp.baseAddress, bp.baseAddress, 2)
            }
        }
        return obj
    }

    // `__nomu_alloc_slow(size)`: the allocation miss path, at the runtime's TLAB allocator (`rtTlabAlloc`),
    // which refills the hole from the shared block pool under the space lock, routes a large object to the
    // large-object space, and collects when the heap is full. The block memory is zeroed on refill, so the
    // object needs no memset. The result is produced as `inttoptr` to `p1`, as on the hit path.
    //
    // Never inlined: it anchors the collector's walk for a collection it triggers. The hit path is inlined
    // into the allocating function, so that function calls this directly: `llvm.returnaddress(0)` is the
    // caller's statepoint PC and `llvm.frameaddress(0)` + 16 the caller's SP (the RT_USER_ANCHOR convention),
    // and the stop-the-world walk starts at the caller's frame and finds the in-flight allocation's roots.
    func nomuAllocSlow() -> (LLVMValueRef, LLVMTypeRef) {
        if let s = allocSlowFn { return s }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_alloc_slow", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")
        addNoInline(fn)
        // `rtTlabAlloc(tlab: RawPtr, space: RawPtr, n: Int, anchorSp: RawPtr, anchorPc: Int) -> RawPtr`.
        let tlabAlloc = runtimePreludeFn("rtTlabAlloc", ret: i8ptr, params: [i8ptr, i8ptr, i64, i8ptr, i64])
        // `rtCarrier() -> RawPtr`: this thread's record, bound on first use; a gc-leaf call (it allocates
        // only raw memory).
        let carrier = runtimePreludeFn("rtCarrier", ret: i8ptr, params: [])
        withStubBody(fn) {
            let size = LLVMGetParam(fn, 0)!
            let (anchorSp, anchorPc) = emitCallerAnchor()
            // The heap is one process-wide space the runtime creates at startup (`rtSpace`), so its descriptor
            // is a constant by the time any allocation runs.
            let space = loadRuntimeGlobal("rtSpace", i8ptr)
            let tlab = buildCall(carrier.fn, carrier.ty, [])!
            markCallGCLeaf(tlab)
            let raw = buildCall(tlabAlloc.fn, tlabAlloc.ty, [tlab, space, size, anchorSp, anchorPc])!
            LLVMBuildRet(b, LLVMBuildIntToPtr(b, LLVMBuildPtrToInt(b, raw, i64, "raw.i"), p1, "obj"))
        }
        allocSlowFn = (fn, ty)
        return allocSlowFn!
    }

    // The process entry, emitted into the program's entry object: `int main(void)` runs the runtime's init
    // function (the run settings, the scheduler, the heap) and boots the scheduler on `rtCarrierCount` carriers
    // with the program's `main` as the first fiber; the boot starts the GC coordinator. Creating an actor fills the scheduler's drain slot (`registerActorDrain`).
    // Its loads of the runtime's globals are plain: the init call that stores them is in this function.
    func emitProcessEntry(main nomuMain: LLVMValueRef, _ mainTy: LLVMTypeRef) {
        // The first fiber's entry, `ptr (ptr)` as the scheduler calls it (`Runtime.callEntry`): calls the
        // program's `main` and returns null. Like the forwarders it has no GC strategy, so the walk of the
        // main fiber ends at `main`'s frame; `noinline` keeps `main` from being inlined into it.
        let entryTy = fnType(i8ptr, [i8ptr])
        // External, so a backtrace names it: the link strips local symbols (`-x`), and the frame between the
        // fiber's start and `main` would otherwise take the name of whatever precedes it.
        let entry = LLVMAddFunction(mod, "__nomu_main_entry", entryTy)!
        addNoInline(entry)
        withStubBody(entry) {
            let call = buildCall(nomuMain, mainTy, [])!
            LLVMAddCallSiteAttribute(call, funcAttrIndex,
                                     LLVMCreateEnumAttribute(ctx, LLVMGetEnumAttributeKindForName("noinline", 8), 0))
            LLVMBuildRet(b, LLVMConstNull(i8ptr))
        }

        let i32 = LLVMInt32TypeInContext(ctx)!
        let (fn, _) = emitFunction("main", ret: i32, params: [], gc: false)
        let runtimeInit = preludeFn(Mangle.moduleInit(home: []), ret: voidTy, params: [])
        let boot = runtimePreludeFn("nomuSchedBoot", ret: voidTy, params: [i8ptr, i8ptr, i64])
        // The fault handler first (`runtime/fault.nomu`), so a fault while the startup globals are computed is
        // reported too.
        let faultInstall = runtimePreludeFn("rtFaultInstall", ret: voidTy, params: [])
        withStubBody(fn) {
            _ = buildCall(faultInstall.fn, faultInstall.ty, [])
            _ = buildCall(runtimeInit.0, runtimeInit.1, [])
            let sched = LLVMBuildLoad2(b, i8ptr, getOrAddGlobal(i8ptr, Mangle.global("rtSched", home: [])), "sched")!
            let carriers = LLVMBuildLoad2(b, i64, getOrAddGlobal(i64, Mangle.global("rtCarrierCount", home: [])),
                                          "carriers")!
            _ = buildCall(boot.fn, boot.ty, [sched, entry, carriers])
            LLVMBuildRet(b, LLVMConstInt(i32, 0, 0))
        }
    }

    // The caller's anchor for the collector's walk, read in a `noinline` function its caller calls directly:
    // the caller's SP (`llvm.frameaddress(0)` + 16, past this frame's saved FP and LR) and the return address
    // into it, a statepoint PC the walk matches. Returns (sp, pc as an i64).
    func emitCallerAnchor() -> (LLVMValueRef, LLVMValueRef) {
        let frameAddr = runtimeFn("llvm.frameaddress.p0", ret: i8ptr, params: [i32], varArg: false)
        let retAddr = runtimeFn("llvm.returnaddress.p0", ret: i8ptr, params: [i32], varArg: false)
        let fp = buildCall(frameAddr.0, frameAddr.1, [LLVMConstInt(i32, 0, 0)])!
        let sp = gepByte(fp, LLVMConstInt(i64, 16, 0))
        let ra = buildCall(retAddr.0, retAddr.1, [LLVMConstInt(i32, 0, 0)])!
        return (sp, LLVMBuildPtrToInt(b, ra, i64, "anchor.pc")!)
    }

    // A scheduler forwarder that parks the calling fiber: a `noinline` internal function, called directly from
    // generated code, that reads its caller's anchor (`emitCallerAnchor`) and the scheduler (`rtSched`) and
    // passes both to the Nomu scheduler function `body` calls. The walk of a parked fiber starts at that
    // anchor, so the forwarder's own frame is never walked: it uses no GC strategy and its calls are plain
    // calls, with no stack-map records.
    func schedForwarder(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef],
                        _ body: (_ fn: LLVMValueRef, _ sched: LLVMValueRef, _ sp: LLVMValueRef,
                                 _ pc: LLVMValueRef) -> LLVMValueRef?) -> (LLVMValueRef, LLVMTypeRef) {
        if let f = forwarderFns[name] { return f }
        let ty = fnType(ret, params)
        let fn = LLVMAddFunction(mod, name, ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        addNoInline(fn)
        forwarderFns[name] = (fn, ty)
        withStubBody(fn) {
            let (sp, pc) = emitCallerAnchor()
            let sched = loadRuntimeGlobal("rtSched", i8ptr)
            if let r = body(fn, sched, sp, pc) { LLVMBuildRet(b, r) } else { LLVMBuildRetVoid(b) }
        }
        return (fn, ty)
    }

    // `__nomu_gc_poll_slow()`: the safepoint slow path, called from the inline poll when the stop-the-world
    // flag is set. Parks the fiber at its caller's anchor until the world resumes (`nomuSchedSafepoint`).
    // Not gc-leaf: the call from the poll site is a statepoint.
    func nomuPollSlow() -> (LLVMValueRef, LLVMTypeRef) {
        let target = runtimePreludeFn("nomuSchedSafepoint", ret: voidTy, params: [i8ptr, i8ptr, i64])
        return schedForwarder("__nomu_gc_poll_slow", ret: voidTy, params: []) { _, sched, sp, pc in
            _ = self.buildCall(target.fn, target.ty, [sched, sp, pc])
            return nil
        }
    }

    // `__nomu_spawn_join(handle, final)`: await a spawned fiber, parking until it completes
    // (`nomuSchedJoin`), and return its result box. `handle` is the spawn site's `{ fiber }` slot; `final`
    // (the structured scope-exit join) drops the fiber from the live-fiber registry after the read.
    func nomuSpawnJoin() -> (LLVMValueRef, LLVMTypeRef) {
        let target = runtimePreludeFn("nomuSchedJoin", ret: i8ptr, params: [i8ptr, i8ptr, i8ptr, i64, i64])
        return schedForwarder("__nomu_spawn_join", ret: i8ptr, params: [i8ptr, i64]) { fn, sched, sp, pc in
            let fiber = LLVMBuildLoad2(self.b, self.i8ptr, LLVMGetParam(fn, 0), "fiber")!
            return self.buildCall(target.fn, target.ty, [sched, fiber, sp, pc, LLVMGetParam(fn, 1)])
        }
    }

    // `__nomu_sleep_ms(ms)`: park the fiber for `ms` milliseconds (`nomuSchedSleep`); returns `ms`.
    func nomuSleepMs() -> (LLVMValueRef, LLVMTypeRef) {
        let target = runtimePreludeFn("nomuSchedSleep", ret: i64, params: [i8ptr, i64, i8ptr, i64])
        return schedForwarder("__nomu_sleep_ms", ret: i64, params: [i64]) { fn, sched, sp, pc in
            self.buildCall(target.fn, target.ty, [sched, LLVMGetParam(fn, 0), sp, pc])
        }
    }

    // The `__nomu_write_barrier` seam: a post-store object-remembering barrier with an inlined fast
    // path (barrier off / already-remembered) and an out-of-line slow path on first mutation. Without a
    // write barrier (`emitsWriteBarrier` off) it is the store alone.
    func nomuWriteBarrier() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = barrierFn { return g }
        let ty = fnType(voidTy, [p1, p1, p1])
        let fn = LLVMAddFunction(mod, "__nomu_write_barrier", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        let remember = nomuRememberBarrier()
        withStubBody(fn) {
            let obj = LLVMGetParam(fn, 0)!, slot = LLVMGetParam(fn, 1)!, val = LLVMGetParam(fn, 2)!
            LLVMBuildStore(b, val, slot)   // *slot = val (barrier is post-store)
            if emitsWriteBarrier { _ = buildCall(remember.0, remember.1, [obj]) }
            LLVMBuildRetVoid(b)
        }
        barrierFn = (fn, ty)
        return barrierFn!
    }

    // `__nomu_remember`: the barrier without its store, for a value stored as words rather than one `p1`
    // (a `String`, or a struct or enum holding managed words). The barrier remembers the object, not the
    // slot, so the caller's plain store followed by this is the same barrier.
    func nomuRememberBarrier() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = rememberFn { return g }
        let i8 = LLVMInt8TypeInContext(ctx)!
        let ty = fnType(voidTy, [p1])
        let fn = LLVMAddFunction(mod, "__nomu_remember", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        // Without a write barrier (`gc.plan: immix`) the seam is empty and inlines away.
        guard emitsWriteBarrier else {
            withStubBody(fn) { LLVMBuildRetVoid(b) }
            rememberFn = (fn, ty)
            return rememberFn!
        }
        let slowPath = runtimePreludeFn("rtRememberStore", ret: voidTy, params: [i8ptr])
        withStubBody(fn) {
            // The object's address as an integer comes from a side-effecting inline asm (`pinnedAddress`). The
            // barrier is inlined before the statepoint rewrite, where the object is one unchanging SSA value
            // across a loop, so a plain `ptrtoint` (and the slow path's `addrspacecast`) would be hoisted out
            // of the loop, and the rewrite cannot relocate an integer: the barrier would test where the object
            // was before a collection moved it (task 176.5.8). The asm is neither hoisted nor merged, so the
            // address is taken from the current, relocated pointer at every store.
            // The heap and its log-bit table exist from startup (`rtSpace`), so the barrier is always on and
            // its values (`rtHeapLo`, `rtHeapHi`, `rtLogbitBase`) are constants, read with invariant loads.
            let obj = LLVMGetParam(fn, 0)!
            let inRangeBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.inrange")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.done")!
            let objInt = managedAddress(obj)
            // Heap-range guard: the log-bit table only covers [rtHeapLo, rtHeapHi), the Immix heap range, so a
            // store into an off-heap object (LOS / immortal) skips the barrier rather than indexing the table
            // out of bounds.
            let lo = loadRuntimeGlobal("rtHeapLo", i64)
            let hi = loadRuntimeGlobal("rtHeapHi", i64)
            let below = LLVMBuildICmp(b, LLVMIntULT, objInt, lo, "obj.below")
            let above = LLVMBuildICmp(b, LLVMIntUGE, objInt, hi, "obj.above")
            LLVMBuildCondBr(b, LLVMBuildOr(b, below, above, "obj.oob"), doneBB, inRangeBB)
            LLVMPositionBuilderAtEnd(b, inRangeBB)
            let region = LLVMBuildLShr(b, objInt, LLVMConstInt(i64, 3, 0), "region")   // one bit per 8-byte region
            let baseV = loadRuntimeGlobal("rtLogbitBase", i64)
            let byteOff = LLVMBuildLShr(b, region, LLVMConstInt(i64, 3, 0), "byteoff")
            let metaPtr = LLVMBuildIntToPtr(b, LLVMBuildAdd(b, baseV, byteOff, "metaint"), i8ptr, "metaptr")
            let byte = LLVMBuildLoad2(b, i8, metaPtr, "logbyte")
            let bitpos = LLVMBuildTrunc(b, LLVMBuildAnd(b, region, LLVMConstInt(i64, 7, 0), "bp"), i8, "bitpos")
            let bit = LLVMBuildAnd(b, LLVMBuildLShr(b, byte, bitpos, "sh"), LLVMConstInt(i8, 1, 0), "bit")
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, bit, LLVMConstInt(i8, 0, 0), "unlogged"), slowBB, doneBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            // The slow path never polls or parks, so its call is gc-leaf.
            let slow = buildCall(slowPath.fn, slowPath.ty, [LLVMBuildIntToPtr(b, objInt, i8ptr, "obj.raw")])!
            markCallGCLeaf(slow)
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, doneBB)
            LLVMBuildRetVoid(b)
        }
        rememberFn = (fn, ty)
        return rememberFn!
    }

    // The integer address of managed pointer `p`, produced by a one-instruction side-effecting inline asm
    // (a register move) rather than `ptrtoint`, so the optimizer can neither prove it loop-invariant nor
    // merge it: it is computed where it is used, from the current (relocated) pointer. The host is the
    // target, so the move is spelled for the host architecture.
    func pinnedAddress(_ p: LLVMValueRef) -> LLVMValueRef {
        let ty = fnType(i64, [p1])
        #if arch(arm64)
        let text = "mov $0, $1"
        #else
        let text = "mov $1, $0"
        #endif
        let constraints = "=r,r"
        let asm = text.withCString { a in
            constraints.withCString { c in
                LLVMGetInlineAsm(ty, UnsafeMutablePointer(mutating: a), text.utf8.count,
                                 UnsafeMutablePointer(mutating: c), constraints.utf8.count,
                                 1, 0, LLVMInlineAsmDialectATT, 0)
            }
        }!
        var args: [LLVMValueRef?] = [p]
        let call = args.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, ty, asm, $0.baseAddress, 1, "bar.addr")!
        }
        // Never a safepoint: the statepoint rewrite must leave the asm a plain call.
        let name = "gc-leaf-function"
        LLVMAddCallSiteAttribute(call, funcAttrIndex, LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0))
        return call
    }

    // Unmanaged memory (`RawPtr.alloc`, `Ptr<T>.alloc`; `unsafe-memory.md`): `__nomu_raw_alloc(bytes, align)`,
    // straight to libSystem. `bytes` at or below zero gives null; the alignment is raised to a pointer's, as
    // `posix_memalign` requires; the memory is zero-filled, which the runtime's allocator relies on; failure
    // prints "out of memory" and exits 1. It never touches the managed heap or parks, so it is gc-leaf and
    // its calls are never statepoints. Never inlined: `posix_memalign` dominates its cost, and inlining it at
    // every site only grows the code.
    func nomuRawAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let f = rawAllocFn { return f }
        let ty = fnType(i8ptr, [i64, i64])
        let fn = LLVMAddFunction(mod, "__nomu_raw_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addNoInline(fn)
        let memalign = runtimeFn("posix_memalign", ret: i32, params: [i8ptr, i64, i64], varArg: false)
        let memset = runtimeFn("memset", ret: i8ptr, params: [i8ptr, i32, i64], varArg: false)
        withStubBody(fn) {
            let bytes = LLVMGetParam(fn, 0)!, align = LLVMGetParam(fn, 1)!
            let allocBB = LLVMAppendBasicBlockInContext(ctx, fn, "raw.alloc")!
            let emptyBB = LLVMAppendBasicBlockInContext(ctx, fn, "raw.empty")!
            let oomBB = LLVMAppendBasicBlockInContext(ctx, fn, "raw.oom")!
            let okBB = LLVMAppendBasicBlockInContext(ctx, fn, "raw.ok")!
            let slot = LLVMBuildAlloca(b, i8ptr, "raw.p")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntSLE, bytes, LLVMConstInt(i64, 0, 0), "raw.none"), emptyBB, allocBB)
            LLVMPositionBuilderAtEnd(b, emptyBB)
            LLVMBuildRet(b, LLVMConstPointerNull(i8ptr))
            LLVMPositionBuilderAtEnd(b, allocBB)
            let word = LLVMConstInt(i64, 8, 0)
            let small = LLVMBuildICmp(b, LLVMIntULT, align, word, "raw.small")
            let a = LLVMBuildSelect(b, small, word, align, "raw.align")!
            let rc = buildCall(memalign.0, memalign.1, [slot, a, bytes])!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, rc, LLVMConstInt(i32, 0, 0), "raw.failed"), oomBB, okBB)
            LLVMPositionBuilderAtEnd(b, oomBB)
            emitOutOfMemoryExit()
            LLVMPositionBuilderAtEnd(b, okBB)
            let p = LLVMBuildLoad2(b, i8ptr, slot, "raw.mem")!
            _ = buildCall(memset.0, memset.1, [p, LLVMConstInt(i32, 0, 0), bytes])
            LLVMBuildRet(b, p)
        }
        rawAllocFn = (fn, ty)
        return rawAllocFn!
    }

    // Print "out of memory" to stderr and exit 1, ending the current block.
    func emitOutOfMemoryExit() {
        let dprintf = runtimeFn("dprintf", ret: i32, params: [i32, i8ptr], varArg: true)
        let exit = runtimeFn("exit", ret: voidTy, params: [i32], varArg: false)
        let message = LLVMBuildGlobalStringPtr(b, "out of memory\n", "oom.msg")!
        _ = buildCall(dprintf.0, dprintf.1, [LLVMConstInt(i32, 2, 0), message])
        _ = buildCall(exit.0, exit.1, [LLVMConstInt(i32, 1, 0)])
        LLVMBuildUnreachable(b)
    }

    // A zeroed reservation (`Runtime.reserveZeroed`): `__nomu_reserve_zeroed(bytes, align)` maps private
    // anonymous memory, which the kernel guarantees reads as zero and backs with physical pages only as they
    // are first touched, so reserving costs no resident memory. The size is rounded up to whole pages and
    // the alignment raised to at least a page (the page size is read with `getpagesize`, since it differs
    // by platform); `bytes + align` is mapped and the unaligned head and the tail beyond `bytes` are
    // unmapped. Never freed. `bytes` at or below zero gives null; a failed map prints "out of memory" and
    // exits 1. gc-leaf and never inlined, like `__nomu_raw_alloc`.
    func nomuReserveZeroed() -> (LLVMValueRef, LLVMTypeRef) {
        if let f = reserveZeroedFn { return f }
        let platform = TargetPlatform.host
        let ty = fnType(i8ptr, [i64, i64])
        let fn = LLVMAddFunction(mod, "__nomu_reserve_zeroed", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addNoInline(fn)
        let pageSize = runtimeFn("getpagesize", ret: i32, params: [], varArg: false)
        let mmap = runtimeFn("mmap", ret: i8ptr, params: [i8ptr, i64, i32, i32, i32, i64], varArg: false)
        let munmap = runtimeFn("munmap", ret: i32, params: [i8ptr, i64], varArg: false)
        withStubBody(fn) {
            let bytes = LLVMGetParam(fn, 0)!, align = LLVMGetParam(fn, 1)!
            let mapBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.map")!
            let emptyBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.empty")!
            let oomBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.oom")!
            let trimBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.trim")!
            let headBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.head")!
            let tailCheckBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.tailcheck")!
            let tailBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.tail")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "reserve.done")!
            let zero = LLVMConstInt(i64, 0, 0), one = LLVMConstInt(i64, 1, 0)
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntSLE, bytes, zero, "reserve.none"), emptyBB, mapBB)
            LLVMPositionBuilderAtEnd(b, emptyBB)
            LLVMBuildRet(b, LLVMConstPointerNull(i8ptr))

            LLVMPositionBuilderAtEnd(b, mapBB)
            let page = LLVMBuildSExt(b, buildCall(pageSize.0, pageSize.1, [])!, i64, "reserve.page")!
            let pageMask = LLVMBuildSub(b, page, one, "reserve.pagemask")!
            let n = LLVMBuildAnd(b, LLVMBuildAdd(b, bytes, pageMask, "")!, LLVMBuildNot(b, pageMask, "")!, "reserve.bytes")!
            let a = LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntULT, align, page, ""), page, align, "reserve.align")!
            let span = LLVMBuildAdd(b, n, a, "reserve.span")!
            let base = buildCall(mmap.0, mmap.1, [LLVMConstPointerNull(i8ptr), span,
                                                 LLVMConstInt(i32, UInt64(platform.protReadWrite), 0),
                                                 LLVMConstInt(i32, UInt64(platform.mapPrivateAnonymous), 0),
                                                 LLVMConstInt(i32, UInt64(bitPattern: -1), 1), zero])!
            let baseInt = LLVMBuildPtrToInt(b, base, i64, "reserve.base")!
            let failed = LLVMBuildICmp(b, LLVMIntEQ, baseInt, LLVMConstInt(i64, UInt64(bitPattern: -1), 1), "reserve.failed")
            LLVMBuildCondBr(b, failed, oomBB, trimBB)
            LLVMPositionBuilderAtEnd(b, oomBB)
            emitOutOfMemoryExit()

            LLVMPositionBuilderAtEnd(b, trimBB)
            let alignMask = LLVMBuildSub(b, a, one, "reserve.alignmask")!
            let start = LLVMBuildAnd(b, LLVMBuildAdd(b, baseInt, alignMask, "")!, LLVMBuildNot(b, alignMask, "")!, "reserve.start")!
            let head = LLVMBuildSub(b, start, baseInt, "reserve.headlen")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, head, zero, ""), headBB, tailCheckBB)
            LLVMPositionBuilderAtEnd(b, headBB)
            _ = buildCall(munmap.0, munmap.1, [base, head])
            LLVMBuildBr(b, tailCheckBB)
            LLVMPositionBuilderAtEnd(b, tailCheckBB)
            let end = LLVMBuildAdd(b, start, n, "reserve.end")!
            let tail = LLVMBuildSub(b, LLVMBuildAdd(b, baseInt, span, "")!, end, "reserve.taillen")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, tail, zero, ""), tailBB, doneBB)
            LLVMPositionBuilderAtEnd(b, tailBB)
            _ = buildCall(munmap.0, munmap.1, [LLVMBuildIntToPtr(b, end, i8ptr, "")!, tail])
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, doneBB)
            LLVMBuildRet(b, LLVMBuildIntToPtr(b, start, i8ptr, "reserve.ptr")!)
        }
        reserveZeroedFn = (fn, ty)
        return reserveZeroedFn!
    }

    // A runtime startup global (`runtime/startup.nomu`), read by symbol from generated code. `nomu_runtime_init` sets
    // it before any other code runs and it never changes after, so the load is invariant.
    func loadRuntimeGlobal(_ name: String, _ ty: LLVMTypeRef) -> LLVMValueRef {
        let load = LLVMBuildLoad2(b, ty, getOrAddGlobal(ty, Mangle.global(name, home: [])), name)!
        markInvariantLoad(load)
        return load
    }

    // Mark `load` invariant: the location it reads never changes once the program's init functions have run.
    func markInvariantLoad(_ load: LLVMValueRef) {
        let name = "invariant.load"
        LLVMSetMetadata(load, LLVMGetMDKindIDInContext(ctx, name, UInt32(name.utf8.count)), LLVMMDNodeInContext(ctx, nil, 0))
    }

    // The carrier-local slot's thread-specific-data key (`Runtime.carrierLocal`, design in
    // `tasks/223-retire-the-c-floor.md`, "The floor"): an `Int64` the `runtime` package defines and its init
    // function fills before any other runtime code runs.
    static let carrierKeySymbol = "nomu_carrier_key"
    func carrierKeyGlobal() -> LLVMValueRef { getOrAddGlobal(i64, Self.carrierKeySymbol) }

    func loadCarrierKey() -> LLVMValueRef {
        let key = LLVMBuildLoad2(b, i64, carrierKeyGlobal(), "carrier.key")!
        markInvariantLoad(key)
        return key
    }

    // The address of this thread's carrier-local slot: the thread's TSD array (`tpidrro_el0`, its low three
    // bits masked as libpthread and Go do on darwin) indexed by the key, as libpthread's own
    // `pthread_getspecific` reads it. The register read is side-effecting asm, so it is redone after any call
    // (a fiber can resume on another carrier after a park) and never becomes a safepoint.
    func carrierLocalSlot(key: LLVMValueRef? = nil) -> LLVMValueRef {
        let ty = fnType(i64, [])
        let text = "mrs $0, tpidrro_el0"
        let constraints = "=r"
        let asm = text.withCString { a in
            constraints.withCString { c in
                LLVMGetInlineAsm(ty, UnsafeMutablePointer(mutating: a), text.utf8.count,
                                 UnsafeMutablePointer(mutating: c), constraints.utf8.count,
                                 1, 0, LLVMInlineAsmDialectATT, 0)
            }
        }!
        let tp = LLVMBuildCall2(b, ty, asm, nil, 0, "tsd.base")!
        let name = "gc-leaf-function"
        LLVMAddCallSiteAttribute(tp, funcAttrIndex, LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0))
        let base = LLVMBuildAnd(b, tp, LLVMConstInt(i64, ~UInt64(7), 0), "tsd.base.aligned")!
        let offset = LLVMBuildShl(b, key ?? loadCarrierKey(), LLVMConstInt(i64, 3, 0), "tsd.off")!
        return LLVMBuildIntToPtr(b, LLVMBuildAdd(b, base, offset, "tsd.slot")!, i8ptr, "tsd.slot.ptr")!
    }

    // `key` is the key's value when the caller has just loaded it (the init function, which writes the key and
    // so must not read it invariantly); otherwise the invariant load.
    func emitCarrierLocalGet(key: LLVMValueRef? = nil) -> LLVMValueRef {
        if TargetPlatform.host.readsCarrierLocalDirectly {
            return LLVMBuildLoad2(b, i8ptr, carrierLocalSlot(key: key), "carrier.local")!
        }
        let (fn, fty) = runtimeFn("pthread_getspecific", ret: i8ptr, params: [i64], varArg: false)
        return buildCall(fn, fty, [key ?? loadCarrierKey()])!
    }

    func emitCarrierLocalSet(_ v: LLVMValueRef) {
        if TargetPlatform.host.readsCarrierLocalDirectly {
            LLVMBuildStore(b, v, carrierLocalSlot())
            return
        }
        let (fn, fty) = runtimeFn("pthread_setspecific", ret: i32, params: [i64, i8ptr], varArg: false)
        _ = buildCall(fn, fty, [loadCarrierKey(), v])
    }

    // Create the carrier-local key, then check the direct read against `pthread_getspecific` once: write a
    // sentinel through `pthread_setspecific`, read it back both ways, and abort if they differ. Emitted at the
    // start of the runtime's init function, on the main thread before the scheduler boots.
    func emitCarrierKeySetup() {
        let key = carrierKeyGlobal()
        LLVMSetInitializer(key, LLVMConstInt(i64, 0, 0))
        let create = runtimeFn("pthread_key_create", ret: i32, params: [i8ptr, i8ptr], varArg: false)
        _ = buildCall(create.0, create.1, [key, LLVMConstPointerNull(i8ptr)])
        let k = LLVMBuildLoad2(b, i64, key, "carrier.key.new")!
        let set = runtimeFn("pthread_setspecific", ret: i32, params: [i64, i8ptr], varArg: false)
        let get = runtimeFn("pthread_getspecific", ret: i8ptr, params: [i64], varArg: false)
        _ = buildCall(set.0, set.1, [k, key])   // the sentinel: the key's own address
        let viaLibrary = buildCall(get.0, get.1, [k])!
        let direct = emitCarrierLocalGet(key: k)
        guard let fn = LLVMGetBasicBlockParent(LLVMGetInsertBlock(b)) else { return }
        let bad = LLVMAppendBasicBlockInContext(ctx, fn, "carrier.key.bad")!
        let ok = LLVMAppendBasicBlockInContext(ctx, fn, "carrier.key.ok")!
        let same = LLVMBuildICmp(b, LLVMIntEQ, direct, viaLibrary, "carrier.key.same")
        LLVMBuildCondBr(b, same, ok, bad)
        LLVMPositionBuilderAtEnd(b, bad)
        let message = LLVMBuildGlobalStringPtr(b, "nomu: the carrier-local slot's direct read disagrees with pthread_getspecific\n", "carrier.key.msg")!
        let dprintf = runtimeFn("dprintf", ret: i32, params: [i32, i8ptr], varArg: true)
        _ = buildCall(dprintf.0, dprintf.1, [LLVMConstInt(i32, 2, 0), message])
        let abort = runtimeFn("abort", ret: voidTy, params: [], varArg: false)
        _ = buildCall(abort.0, abort.1, [])
        LLVMBuildUnreachable(b)
        LLVMPositionBuilderAtEnd(b, ok)
        _ = buildCall(set.0, set.1, [k, LLVMConstPointerNull(i8ptr)])
    }

    // Store `val` into a field at `slot` of object `objBase`. A store into a heap object goes through the
    // write barrier when the value can hold a managed word: a managed reference (`p1`) takes the barrier
    // seam, and an aggregate (a `String`, or a struct or enum value) is stored plainly and its object
    // remembered. `type` refines the aggregate case: given, only a type with a non-empty shape is
    // remembered; absent, every aggregate is. Everything else is a plain store.
    func storeField(_ objBase: LLVMValueRef!, _ slot: LLVMValueRef!, _ val: LLVMValueRef!, type: Type? = nil) {
        let heap = LLVMGetPointerAddressSpace(LLVMTypeOf(objBase)) == 1
        if LLVMTypeOf(val) == p1, heap {
            let bar = nomuWriteBarrier()
            _ = buildCall(bar.0, bar.1, [objBase, slot, val])
            return
        }
        LLVMBuildStore(b, val, slot)
        let kind = LLVMGetTypeKind(LLVMTypeOf(val))
        guard heap, kind == LLVMStructTypeKind || kind == LLVMArrayTypeKind else { return }
        if let t = type, shapes.shape(t).isEmpty { return }
        let remember = nomuRememberBarrier()
        _ = buildCall(remember.0, remember.1, [objBase])
    }
}
