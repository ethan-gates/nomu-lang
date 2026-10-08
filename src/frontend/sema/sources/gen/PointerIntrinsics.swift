import noir
import ast
import support
// Pointer intrinsics (task 125 + the 128/150 scheduler/GC substrate) — the builtin
// typechecking for `RawPtr` and `Ptr<T>`: their static methods (`RawPtr.alloc`,
// `Ptr<T>.alloc`, …), instance methods (`load`/`store`/`advanced`/atomics/futex/…),
// and the `.null` static property. Reached from expression checking when a receiver
// (or a qualified type name) is a pointer type.
//
// A capability namespace over `inout Sema`: it reads the diagnostic sink and the
// top-level function table, and calls back into the core expression walk (`checkExpr`,
// `coerce`, `checkAssignable`) to check argument sub-expressions. NOIR intrinsic-call
// nodes are built through `Sema.ptrIntrinsic`.
enum PointerIntrinsics {

    // MARK: - Argument helpers

    // Unsafe raw-memory surface (task 125). Element types are limited to the single-word scalars a
    // plain addrspace(0) load/store can move; aggregates are out of the minimal floor.
    private static func isRawScalar(_ t: Type) -> Bool {
        switch t {
        case .int, .uint8, .uint64, .double, .bool, .rawPtr, .ptr: return true
        default: return false
        }
    }

    // Validate a builtin call's argument labels against a fixed expected list (nil = an unlabeled
    // positional argument). The pointer surface spells its offsets/counts explicitly (`toByteOffset:`,
    // `by:`), so the labels are required, matching the design.
    static func checkArgLabels(_ s: inout Sema, _ args: [Arg], _ expected: [String?], _ ctx: String, _ span: Span) -> Bool {
        guard args.count == expected.count else {
            let sig = expected.map { $0.map { "\($0):" } ?? "_" }.joined(separator: ", ")
            s.diags.error("\(ctx) expects \(expected.count) argument(s) (\(sig)), got \(args.count)", at: span)
            return false
        }
        var ok = true
        for (a, want) in zip(args, expected) where a.label != want {
            let wantDesc = want.map { "label '\($0):'" } ?? "no label"
            let gotDesc = a.label.map { "'\($0):'" } ?? "no label"
            s.diags.error("\(ctx): expected \(wantDesc), got \(gotDesc)", at: span)
            ok = false
        }
        return ok
    }

    // Check an `Int`-typed argument of a pointer builtin, enforcing the type as the virtual signature
    // demands (a byte offset / count / alignment). `coerce(_, to: .int)` is a no-op, so this is what
    // actually rejects a non-Int argument.
    static func intArg(_ s: inout Sema, _ e: Expr, _ ctx: String, _ what: String) -> NOIRExpr {
        let v = NOIRGen.checkExpr(&s, e, expected: .int)
        if v.type != .int, v.type != .error {
            s.diags.error("\(ctx): \(what) must be an 'Int', got '\(v.type)'", at: v.span)
        }
        return v
    }

    private static func ptrArg(_ s: inout Sema, _ e: Expr, _ ctx: String, _ what: String) -> NOIRExpr {
        let v = NOIRGen.checkExpr(&s, e)
        if v.type != .rawPtr, v.type != .error {
            s.diags.error("\(ctx): \(what) must be a 'RawPtr', got '\(v.type)'", at: v.span)
        }
        return v
    }

    // MARK: - Static property

    // Pointer static properties: `RawPtr.null` / `Ptr<T>.null` — a null address of the named type.
    static func checkPointerStaticMember(_ s: inout Sema, _ tn: String, _ explicit: [Type]?, _ field: String, _ span: Span) -> NOIRExpr {
        guard field == "null" else {
            let ty = tn == "Ptr" ? "Ptr<T>" : tn
            s.diags.error("type '\(ty)' has no static property '\(field)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        if tn == "RawPtr" { return s.ptrIntrinsic("__ptrNull", .rawPtr, [], span) }
        guard let elems = explicit, elems.count == 1 else {
            s.diags.error("'Ptr' needs one type argument, e.g. 'Ptr<Int>.null'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        return s.ptrIntrinsic("__ptrNull", .ptr(elems[0]), [], span)
    }

    // MARK: - RawPtr static methods

    static func checkRawPtrStatic(_ s: inout Sema, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(&s, args, ["bytes", "align"], "RawPtr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let bytes = intArg(&s, args[0].value, "RawPtr.alloc", "bytes")
            let align = intArg(&s, args[1].value, "RawPtr.alloc", "align")
            return s.ptrIntrinsic("__rawAlloc", .rawPtr, [bytes, align], span)
        // GC type-table reads (task 150 rung 2). Reach the codegen-emitted per-type-id side tables
        // (`c-types.md` §1/§3.2) from Nomu: each lowers to a call to the existing runtime accessor. All
        // are gc-leaf pure reads — no managed heap, no alloc — so the Nomu tracer reads its object model
        // through the same tables the MMTk binding reads.
        case "gcTypeCount":
            guard checkArgLabels(&s, args, [], "RawPtr.gcTypeCount", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcTypeCount", .int, [], span)
        case "gcDescSize":
            // The descriptor record byte size (task 180): the single source of truth the self-hosted
            // collector reads for the type-id ↔ ordinal stride, rather than hardcoding the record width.
            guard checkArgLabels(&s, args, [], "RawPtr.gcDescSize", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcDescSize", .int, [], span)
        case "gcTypeSize", "gcTypeKind", "gcTypeStride", "gcTypeNumPtrs", "gcTypeHeaderSize", "gcHeaderPtrCount":
            guard checkArgLabels(&s, args, [nil], "RawPtr.\(method)", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.\(method)", "id")
            let intr = "__" + method   // __gcTypeSize / __gcTypeKind / __gcTypeStride / __gcTypeNumPtrs / __gcTypeHeaderSize
            return s.ptrIntrinsic(intr, .int, [id], span)
        case "gcTypePtrOffset":
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.gcTypePtrOffset", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.gcTypePtrOffset", "id")
            let i = intArg(&s, args[1].value, "RawPtr.gcTypePtrOffset", "i")
            return s.ptrIntrinsic("__gcTypePtrOffset", .int, [id, i], span)
        case "gcHeaderOffsetAt":
            // The k-th managed-pointer byte offset within a buffer's header (task 180), relative to the
            // header base (`base + 16`). Paired with `gcHeaderPtrCount` to scan the header once per buffer.
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.gcHeaderOffsetAt", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.gcHeaderOffsetAt", "id")
            let k = intArg(&s, args[1].value, "RawPtr.gcHeaderOffsetAt", "k")
            return s.ptrIntrinsic("__gcHeaderOffsetAt", .int, [id, k], span)
        // The shared shaped-root/field enumerator (task 176, shaped-roots.md Stage 5): resolve the live
        // managed-pointer byte offsets of a value of type-id `id` at address `base`. For kind 0/1 this is the
        // static flat map (`base` unused), identical to `gcTypeNumPtrs`/`gcTypePtrOffset`; for kind 2 (shaped)
        // the tag is read from the value at `base` and the live case's offsets returned. Both collectors read
        // their object model through this one enumerator so the kind-2 tag-decode lives in exactly one place.
        case "gcLiveCount":
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.gcLiveCount", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.gcLiveCount", "id")
            let base = ptrArg(&s, args[1].value, "RawPtr.gcLiveCount", "base")
            return s.ptrIntrinsic("__gcLiveCount", .int, [id, base], span)
        case "gcLiveOffsetAt":
            guard checkArgLabels(&s, args, [nil, nil, nil], "RawPtr.gcLiveOffsetAt", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.gcLiveOffsetAt", "id")
            let base = ptrArg(&s, args[1].value, "RawPtr.gcLiveOffsetAt", "base")
            let i = intArg(&s, args[2].value, "RawPtr.gcLiveOffsetAt", "i")
            return s.ptrIntrinsic("__gcLiveOffsetAt", .int, [id, base, i], span)
        // Shaped-field accessors (task 176 Stage 1 site 2): the fields of an object (type-id) that are
        // themselves shaped values (a `String`), recursed into via their sub-shape. `gcShapedCount` is the
        // number of such fields; `gcShapedOffset`/`gcShapedShapeId` give the k-th field's byte offset and
        // sub-shape type-id. The object-scan loops read these to recurse into each shaped field.
        case "gcShapedCount":
            guard checkArgLabels(&s, args, [nil], "RawPtr.gcShapedCount", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcShapedCount", .int, [intArg(&s, args[0].value, "RawPtr.gcShapedCount", "id")], span)
        case "gcShapedOffset", "gcShapedShapeId":
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.\(method)", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let id = intArg(&s, args[0].value, "RawPtr.\(method)", "id")
            let k = intArg(&s, args[1].value, "RawPtr.\(method)", "k")
            return s.ptrIntrinsic("__" + method, .int, [id, k], span)   // __gcShapedOffset / __gcShapedShapeId
        // Map a frame-root shape ordinal (a `"deopt"`-bundle Constant, task 176 Stage 4) to its kind-2
        // descriptor type-id. The self-hosted stackmap walker (`rtWalkFrom`) resolves each shaped root
        // through this, the same C `nomu_shape_desc_for_ordinal` the C walker uses — one ordinal→descriptor
        // mapping for both collectors.
        case "gcShapeDescForOrdinal":
            guard checkArgLabels(&s, args, [nil], "RawPtr.gcShapeDescForOrdinal", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let ord = intArg(&s, args[0].value, "RawPtr.gcShapeDescForOrdinal", "ordinal")
            return s.ptrIntrinsic("__gcShapeDescForOrdinal", .int, [ord], span)
        // The `__llvm_stackmaps` section (task 150 rung 2, the pcsp root walk): base address + byte size,
        // reached through the linker-provided section-bracket symbols (no libc, no new runtime C). The Nomu
        // pcsp walk parses this section (return-address → SP-relative root slots + per-function frame size).
        case "gcStackmapBase":
            guard checkArgLabels(&s, args, [], "RawPtr.gcStackmapBase", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcStackmapBase", .rawPtr, [], span)
        case "gcStackmapSize":
            guard checkArgLabels(&s, args, [], "RawPtr.gcStackmapSize", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcStackmapSize", .int, [], span)
        // Stack-walk anchors (task 150 rung 2, pcsp walk): the caller frame's frame pointer (as a RawPtr)
        // and the return address into the caller (as an Int) — `llvm.frameaddress`/`llvm.returnaddress`.
        // From these the pcsp walk derives each frame's SP and steps by the stackmap's per-function size.
        case "gcFrameAddr":
            guard checkArgLabels(&s, args, [], "RawPtr.gcFrameAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcFrameAddr", .rawPtr, [], span)
        case "gcReturnAddr":
            guard checkArgLabels(&s, args, [], "RawPtr.gcReturnAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcReturnAddr", .int, [], span)
        // Force one collection at a clean program point (task 150 rung 2, mark-verify oracle): drive a
        // deterministic GC so MMTk emits its live-set fingerprint (`MMTK-FP`, under NOMU_GC_MARKVERIFY),
        // the independent oracle the self-hosted Nomu tracer's fingerprint is diffed against.
        case "gcForceCollect":
            guard checkArgLabels(&s, args, [], "RawPtr.gcForceCollect", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcForceCollect", .void, [], span)
        // Task 128.3.1 (parked-fiber root scan): fetch each parked fiber's saved frame-pointer anchor from
        // the C fiber registry into `outBuf` (up to `cap` words), returning the count. The self-hosted walk
        // (`rtScanParkedFibers`) chains past the C park frames from each anchor and runs the pcsp walk.
        case "gcParkedAnchors":
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.gcParkedAnchors", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let outBuf = NOIRGen.checkExpr(&s, args[0].value)
            if outBuf.type != .error, outBuf.type != .rawPtr {
                s.diags.error("RawPtr.gcParkedAnchors expects a RawPtr buffer, got '\(outBuf.type)'", at: outBuf.span)
            }
            let cap = intArg(&s, args[1].value, "RawPtr.gcParkedAnchors", "cap")
            return s.ptrIntrinsic("__gcParkedAnchors", .int, [outBuf, cap], span)
        // Task 128.3.1 (scheduler root): read the global scheduled-mailbox queue head (`rt_sched_head`), a
        // single managed GC root that keeps every queued mailbox's pending work alive. Returns its value as a
        // RawPtr (null when the queue is empty). The self-hosted scan (`rtScanSchedRoot`) reports it as a root.
        case "gcSchedHead":
            guard checkArgLabels(&s, args, [], "RawPtr.gcSchedHead", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcSchedHead", .rawPtr, [], span)
        // Task 128.3.2: the self-hosted scheduler's Sched handle (`rt_nomu_sched`), bound at boot under
        // NOMU_SCHED=nomu (null under the C plan). Lets a driver run the self-hosted STW walk.
        case "schedHandle":
            guard checkArgLabels(&s, args, [], "RawPtr.schedHandle", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__schedHandle", .rawPtr, [], span)
        // The self-hosted Immix space descriptor (task 150 rung 3): the codegen-internal global
        // `__nomu_selfhost_space` the alloc seam lazily creates under NOMU_GC_PLAN=nomu. Null under other
        // plans (MMTk allocates). The self-hosted tracer reads it to mark lines in the space objects live in.
        case "gcSelfhostSpace":
            guard checkArgLabels(&s, args, [], "RawPtr.gcSelfhostSpace", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcSelfhostSpace", .rawPtr, [], span)
        // This carrier's write-barrier mod-buffer (task 150.4.2): the growable remembered-set append buffer
        // bound _Thread_local in the C runtime (rt_self_modbuf_get). Lets a fixture read the remembered count
        // (rtModBufCount) to check the barrier filled it. Same no-arg shape as gcSelfhostSpace.
        case "gcSelfModBuf":
            guard checkArgLabels(&s, args, [], "RawPtr.gcSelfModBuf", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcSelfModBuf", .rawPtr, [], span)
        // The nursery-reserve override in blocks (env NOMU_NURSERY_RESERVE): 0 = unset (use the descriptor
        // default, 1/4 of the pool — generational on); positive overrides the reserve; negative disables
        // generational. rtGenReserve resolves it against the descriptor. A gc-leaf pure read of the C global.
        case "gcNurseryReserve":
            guard checkArgLabels(&s, args, [], "RawPtr.gcNurseryReserve", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcNurseryReserve", .int, [], span)
        // The mature-pressure floor in blocks (task 150.4.4, env NOMU_MATURE_FLOOR): when free mature blocks
        // fall below it a nursery-full trigger escalates to a full defrag major instead of a minor. 0 = default
        // (the minor/major driver uses the worst-case-promotion bound). A gc-leaf pure read of the C global.
        case "gcMatureFloor":
            guard checkArgLabels(&s, args, [], "RawPtr.gcMatureFloor", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcMatureFloor", .int, [], span)
        // Nonzero when an external STW driver (NOMU_STW_SELFHOST / NOMU_STW_COLLECT / NOMU_GC_PRESSURE) owns
        // collection, so the default minor coordinator is not running. rtGenReserve returns 0 in that case so
        // the generational minor trigger doesn't park a carrier on a coordinator that never runs. Pure read.
        case "gcExternalDriver":
            guard checkArgLabels(&s, args, [], "RawPtr.gcExternalDriver", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcExternalDriver", .int, [], span)
        // Drain every carrier's write-barrier mod-buffer into `outBuf` (task 150.4.3): the minor GC's
        // remembered set. Copies each remembered object pointer (up to `cap`), resets the buffers, and
        // returns the total count. Same shape as gcParkedAnchors.
        case "gcDrainModBufs":
            guard checkArgLabels(&s, args, [nil, nil], "RawPtr.gcDrainModBufs", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let outBuf = NOIRGen.checkExpr(&s, args[0].value)
            if outBuf.type != .error, outBuf.type != .rawPtr {
                s.diags.error("RawPtr.gcDrainModBufs expects a RawPtr buffer, got '\(outBuf.type)'", at: outBuf.span)
            }
            let cap = intArg(&s, args[1].value, "RawPtr.gcDrainModBufs", "cap")
            return s.ptrIntrinsic("__gcDrainModBufs", .int, [outBuf, cap], span)
        // Scheduler substrate — raw OS clock (task 128.1.1). Monotonic time in nanoseconds, the primitive
        // under the scheduler's timer heap. It reaches the OS directly (macOS: the libSystem entry
        // `clock_gettime_nsec_np`; selfhosted-scheduler.md §3.3), bypassing the C-runtime shim — a step
        // toward retiring the C floor (128 goal 1). gc-leaf: no managed heap, no alloc, subset-legal.
        case "monotonicNanos":
            guard checkArgLabels(&s, args, [], "RawPtr.monotonicNanos", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysMonotonicNanos", .int, [], span)
        // Asm-floor isolation self-test (task 128.2). Drives the per-arch context switch (rtSwitch /
        // rtFiberInit) through a seed → switch-in → switch-back round-trip and returns 1 if the fiber ran
        // with its argument intact, else 0 (0 also on an arch with no asm floor yet). The isolation check
        // the design calls for before any scheduler rides the floor.
        case "asmSelfTest":
            guard checkArgLabels(&s, args, [], "RawPtr.asmSelfTest", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysAsmSelfTest", .int, [], span)
        // Carrier-local slot for the self-hosted scheduler (task 128.1.6): the running fiber handle
        // (`rt_current`). `RawPtr.tlsGet()` reads it, `RawPtr.tlsSet(v)` writes it. Backed by a
        // `_Thread_local` word in the embedded floor (core.c), so a fiber that self-parks can find itself
        // without threading its handle through user code. Subset-legal (`__sys`).
        case "tlsGet":
            guard checkArgLabels(&s, args, [], "RawPtr.tlsGet", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysTlsGet", .rawPtr, [], span)
        case "tlsSet":
            guard checkArgLabels(&s, args, [nil], "RawPtr.tlsSet", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let v = NOIRGen.checkExpr(&s, args[0].value)
            if v.type != .rawPtr, v.type != .error {
                s.diags.error("RawPtr.tlsSet expects a 'RawPtr', got '\(v.type)'", at: v.span)
            }
            return s.ptrIntrinsic("__sysTlsSet", .void, [v], span)
        // I/O poller substrate (task 128.1.7): the macOS kqueue floor + the fds a poller test drives to
        // readiness. All libSystem externs (selfhosted-scheduler.md §3.3), subset-legal (`__sys`). fds and
        // event/change buffers are raw memory; fd numbers and counts are Int.
        case "kqueue":
            guard checkArgLabels(&s, args, [], "RawPtr.kqueue", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysKqueue", .int, [], span)      // int kqueue(void)
        case "kevent":
            guard checkArgLabels(&s, args, ["kq", "changes", "nchanges", "events", "nevents"], "RawPtr.kevent", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let kq = intArg(&s, args[0].value, "RawPtr.kevent", "kq")
            let changes = ptrArg(&s, args[1].value, "RawPtr.kevent", "changes")
            let nch = intArg(&s, args[2].value, "RawPtr.kevent", "nchanges")
            let events = ptrArg(&s, args[3].value, "RawPtr.kevent", "events")
            let nev = intArg(&s, args[4].value, "RawPtr.kevent", "nevents")
            return s.ptrIntrinsic("__sysKevent", .int, [kq, changes, nch, events, nev], span)
        case "pipe":
            guard checkArgLabels(&s, args, ["fds"], "RawPtr.pipe", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysPipe", .int, [ptrArg(&s, args[0].value, "RawPtr.pipe", "fds")], span)  // int pipe(int fds[2])
        case "writeFd":
            guard checkArgLabels(&s, args, ["fd", "buf", "count"], "RawPtr.writeFd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let wfd = intArg(&s, args[0].value, "RawPtr.writeFd", "fd")
            let wbuf = ptrArg(&s, args[1].value, "RawPtr.writeFd", "buf")
            let wcnt = intArg(&s, args[2].value, "RawPtr.writeFd", "count")
            return s.ptrIntrinsic("__sysWrite", .int, [wfd, wbuf, wcnt], span)
        case "readFd":
            guard checkArgLabels(&s, args, ["fd", "buf", "count"], "RawPtr.readFd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let rfd = intArg(&s, args[0].value, "RawPtr.readFd", "fd")
            let rbuf = ptrArg(&s, args[1].value, "RawPtr.readFd", "buf")
            let rcnt = intArg(&s, args[2].value, "RawPtr.readFd", "count")
            return s.ptrIntrinsic("__sysRead", .int, [rfd, rbuf, rcnt], span)
        // The C-ABI code address of a top-level, non-capturing function as a RawPtr (task 128.2). A
        // runtime-tier primitive for handing an entry point to the asm floor (rtFiberInit) or
        // pthread_create — deliberately not first-class functions (task 128 note: full first-class
        // functions/closures for user code are a later, separate language step). The argument must name a
        // top-level `fun (_: RawPtr) -> RawPtr` — the carrier/fiber-entry ABI (a bare pointer, no env).
        case "ofFunc":
            guard args.count == 1, args[0].label == nil else {
                s.diags.error("RawPtr.ofFunc takes one argument: a top-level function name", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .ident(let fname, _) = args[0].value else {
                s.diags.error("RawPtr.ofFunc expects a bare top-level function name, e.g. 'RawPtr.ofFunc(carrierMain)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard let sig = s.funcs[fname] else {
                s.diags.error("no top-level function named '\(fname)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard sig.generics.isEmpty, sig.params == [.rawPtr], sig.ret == .rawPtr else {
                s.diags.error("RawPtr.ofFunc requires a non-generic 'fun \(fname)(_: RawPtr) -> RawPtr'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return NOIRExpr(type: .rawPtr, span: span, kind: .funcRef(name: fname))
        default:
            s.diags.error("type 'RawPtr' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // MARK: - RawPtr instance methods

    static func checkRawPtrMethod(_ s: inout Sema, _ recv: NOIRExpr, _ name: String, _ args: [Arg], _ span: Span, expected: Type?) -> NOIRExpr {
        switch name {
        case "free":
            guard checkArgLabels(&s, args, [], "RawPtr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawFree", .void, [recv], span)
        case "advanced":
            guard checkArgLabels(&s, args, ["by"], "RawPtr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(&s, args[0].value, "RawPtr.advanced", "by")
            return s.ptrIntrinsic("__rawAdvanced", .rawPtr, [recv, by], span)
        case "store":
            guard checkArgLabels(&s, args, [nil, "toByteOffset"], "RawPtr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = NOIRGen.checkExpr(&s, args[0].value)
            if value.type != .error, !isRawScalar(value.type) {
                s.diags.error("RawPtr.store supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(value.type)'", at: value.span)
            }
            let off = intArg(&s, args[1].value, "RawPtr.store", "toByteOffset")
            return s.ptrIntrinsic("__rawStore", .void, [recv, value, off], span)
        // Bulk-zero `n` bytes from this pointer — a `memset(self, 0, n)` (task 150.4.5.1). The self-hosted
        // allocator hands out reused heap holes whose bytes are stale from the previous occupant; zeroing the
        // hole restores the zero-init contract the collector relies on (an over-allocated array buffer's
        // unwritten tail must read null, so the tracer never scans stale words as pointers).
        case "zeroBytes":
            guard checkArgLabels(&s, args, [nil], "RawPtr.zeroBytes", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let n = intArg(&s, args[0].value, "RawPtr.zeroBytes", "n")
            return s.ptrIntrinsic("__rawZeroBytes", .void, [recv, n], span)
        // memcpy(self, from, byteCount) — copy a raw byte range. Used to grow the minor collector's promotion
        // queue (alloc a larger buffer, copy the live prefix over). Non-overlapping.
        case "copyBytes":
            guard checkArgLabels(&s, args, ["from", "byteCount"], "RawPtr.copyBytes", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let src = ptrArg(&s, args[0].value, "RawPtr.copyBytes", "from")
            let cn = intArg(&s, args[1].value, "RawPtr.copyBytes", "byteCount")
            return s.ptrIntrinsic("__rawCopyBytes", .void, [recv, src, cn], span)
        case "load":
            guard checkArgLabels(&s, args, ["fromByteOffset"], "RawPtr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard let elem = expected, isRawScalar(elem) else {
                s.diags.error("cannot infer the element type of 'RawPtr.load' — annotate the result with a scalar type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let off = intArg(&s, args[0].value, "RawPtr.load", "fromByteOffset")
            return s.ptrIntrinsic("__rawLoad", elem, [recv, off], span)
        // Atomics (task 128.1.1, scheduler substrate). i64 sequentially-consistent ops over a RawPtr slot
        // — the primitive under the MT-safe run queue, STW flags, and futex words. Int-width only for now.
        case "atomicLoad":
            guard checkArgLabels(&s, args, ["fromByteOffset"], "RawPtr.atomicLoad", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let off = intArg(&s, args[0].value, "RawPtr.atomicLoad", "fromByteOffset")
            return s.ptrIntrinsic("__atomicLoad", .int, [recv, off], span)
        case "atomicStore":
            guard checkArgLabels(&s, args, [nil, "toByteOffset"], "RawPtr.atomicStore", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = intArg(&s, args[0].value, "RawPtr.atomicStore", "value")
            let off = intArg(&s, args[1].value, "RawPtr.atomicStore", "toByteOffset")
            return s.ptrIntrinsic("__atomicStore", .void, [recv, value, off], span)
        // Compare-and-swap: returns the value read (the old word). The caller compares it to `expected` to
        // learn whether the swap took, the standard CAS-loop shape.
        case "atomicCas":
            guard checkArgLabels(&s, args, [nil, nil, "atByteOffset"], "RawPtr.atomicCas", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let expc = intArg(&s, args[0].value, "RawPtr.atomicCas", "expected")
            let desr = intArg(&s, args[1].value, "RawPtr.atomicCas", "desired")
            let coff = intArg(&s, args[2].value, "RawPtr.atomicCas", "atByteOffset")
            return s.ptrIntrinsic("__atomicCas", .int, [recv, expc, desr, coff], span)
        // Fetch-and-add: returns the previous value.
        case "atomicFetchAdd":
            guard checkArgLabels(&s, args, [nil, "atByteOffset"], "RawPtr.atomicFetchAdd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let delta = intArg(&s, args[0].value, "RawPtr.atomicFetchAdd", "delta")
            let aoff = intArg(&s, args[1].value, "RawPtr.atomicFetchAdd", "atByteOffset")
            return s.ptrIntrinsic("__atomicFetchAdd", .int, [recv, delta, aoff], span)
        case "atomicExchange":
            guard checkArgLabels(&s, args, [nil, "atByteOffset"], "RawPtr.atomicExchange", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let newv = intArg(&s, args[0].value, "RawPtr.atomicExchange", "value")
            let xoff = intArg(&s, args[1].value, "RawPtr.atomicExchange", "atByteOffset")
            return s.ptrIntrinsic("__atomicExchange", .int, [recv, newv, xoff], span)
        // Asm-floor context switch (task 128.2). The receiver is the *from* context buffer (≥168 bytes,
        // the saved callee-saved set); `to` is the context to resume. Saves the current registers into the
        // receiver and jumps into `to` (rtSwitch). Subset-legal (`__sys`).
        case "ctxSwitchTo":
            guard checkArgLabels(&s, args, [nil], "RawPtr.ctxSwitchTo", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let to = NOIRGen.checkExpr(&s, args[0].value)
            if to.type != .rawPtr, to.type != .error {
                s.diags.error("RawPtr.ctxSwitchTo expects a 'RawPtr' context buffer, got '\(to.type)'", at: to.span)
            }
            return s.ptrIntrinsic("__sysCtxSwitch", .void, [recv, to], span)
        // Seed a fresh fiber's context buffer (the receiver) so the first switch into it lands in the
        // trampoline running `entry(arg)` on `stackTop` (rtFiberInit). `entry` is a code address from
        // RawPtr.ofFunc; `stackTop` and `arg` are raw pointers.
        case "fiberInit":
            guard checkArgLabels(&s, args, ["stackTop", "entry", "arg"], "RawPtr.fiberInit", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let stackTop = NOIRGen.checkExpr(&s, args[0].value)
            let entry = NOIRGen.checkExpr(&s, args[1].value)
            let arg = NOIRGen.checkExpr(&s, args[2].value)
            for (v, n) in [(stackTop, "stackTop"), (entry, "entry"), (arg, "arg")] where v.type != .rawPtr && v.type != .error {
                s.diags.error("RawPtr.fiberInit '\(n)' must be a 'RawPtr', got '\(v.type)'", at: v.span)
            }
            return s.ptrIntrinsic("__sysFiberInit", .void, [recv, stackTop, entry, arg], span)
        // Carrier thread create (task 128.2). The receiver is a slot holding the thread handle
        // (`pthread_t`, ≥8 bytes). Starts `entry(arg)` on a new OS thread via pthread_create (the stable
        // macOS floor, §3.3). `entry` is a `(RawPtr) -> RawPtr` address from RawPtr.ofFunc. Returns 0 on
        // success (else the error number).
        case "threadCreate":
            guard checkArgLabels(&s, args, ["entry", "arg"], "RawPtr.threadCreate", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let entry = NOIRGen.checkExpr(&s, args[0].value)
            let arg = NOIRGen.checkExpr(&s, args[1].value)
            for (v, n) in [(entry, "entry"), (arg, "arg")] where v.type != .rawPtr && v.type != .error {
                s.diags.error("RawPtr.threadCreate '\(n)' must be a 'RawPtr', got '\(v.type)'", at: v.span)
            }
            return s.ptrIntrinsic("__sysThreadCreate", .int, [recv, entry, arg], span)
        // Join the thread whose handle this slot holds (pthread_join). Blocks until it exits; returns 0 on
        // success. The receiver is the same slot passed to threadCreate.
        case "threadJoin":
            guard checkArgLabels(&s, args, [], "RawPtr.threadJoin", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysThreadJoin", .int, [recv], span)
        // Call through a code address with the fiber-entry ABI `(RawPtr) -> RawPtr` (task 128.1.3). The
        // receiver is a function address (from RawPtr.ofFunc); this invokes it with `arg` and returns its
        // result. The scheduler's fiber trampoline uses it to run a fiber's user entry through the stored
        // pointer. An indirect call — the subset closure check does not see a named non-subset callee, so a
        // subset scheduler may run a non-subset fiber body across this boundary.
        case "callEntry":
            guard checkArgLabels(&s, args, [nil], "RawPtr.callEntry", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let a = NOIRGen.checkExpr(&s, args[0].value)
            if a.type != .rawPtr, a.type != .error {
                s.diags.error("RawPtr.callEntry expects a 'RawPtr' argument, got '\(a.type)'", at: a.span)
            }
            return s.ptrIntrinsic("__sysCallEntry", .rawPtr, [recv, a], span)
        // Futex (task 128.1.1, scheduler substrate) — the address of a memory word a carrier sleeps on and
        // is woken from, the primitive under mutex/condvar and idle-carrier sleep. macOS: the libSystem
        // entries __ulock_wait / __ulock_wake (selfhosted-scheduler.md §3.3), no C-runtime shim. gc-leaf,
        // subset-legal (the `__sys` prefix). The receiver is the futex word's address.
        // `futexWait(expected:, timeoutMicros:)`: sleep only while the word still equals `expected` (the
        // kernel re-checks atomically, closing the check-then-sleep race); a mismatch returns at once, a
        // match blocks up to the timeout. Returns the raw result (≥ 0 ok; < 0 a negated errno).
        case "futexWait":
            guard checkArgLabels(&s, args, ["expected", "timeoutMicros"], "RawPtr.futexWait", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let expc = intArg(&s, args[0].value, "RawPtr.futexWait", "expected")
            let tmo = intArg(&s, args[1].value, "RawPtr.futexWait", "timeoutMicros")
            return s.ptrIntrinsic("__sysFutexWait", .int, [recv, expc, tmo], span)
        // `futexWake(all:)`: wake one waiter (lock handoff) or all (STW broadcast). Returns the raw result.
        case "futexWake":
            guard checkArgLabels(&s, args, ["all"], "RawPtr.futexWake", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let all = NOIRGen.checkExpr(&s, args[0].value)
            if all.type != .bool, all.type != .error {
                s.diags.error("RawPtr.futexWake expects a Bool 'all' argument, got '\(all.type)'", at: all.span)
            }
            return s.ptrIntrinsic("__sysFutexWake", .int, [recv, all], span)
        case "eq":
            guard checkArgLabels(&s, args, [nil], "RawPtr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = NOIRGen.checkExpr(&s, args[0].value)
            if other.type != .rawPtr, other.type != .error {
                s.diags.error("RawPtr.eq expects a 'RawPtr' argument, got '\(other.type)'", at: other.span)
            }
            return s.ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        // The pointer's numeric address as an Int (ptrtoint), for addr→index math over raw memory (the
        // Immix side tables, task 150 rung 3): `(addr − heapBase) / lineSize`. Sound on addrspace(0) raw
        // memory the collector owns off-heap.
        case "toInt":
            guard checkArgLabels(&s, args, [], "RawPtr.toInt", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawToInt", .int, [recv], span)
        case "asPtr":
            guard checkArgLabels(&s, args, [], "RawPtr.asPtr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .ptr = (expected ?? .error) else {
                s.diags.error("cannot infer the target type of 'RawPtr.asPtr' — annotate the result as 'Ptr<T>'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawAsPtr", expected!, [recv], span)
        default:
            s.diags.error("value of type 'RawPtr' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // MARK: - Ptr<T> static and instance methods

    static func checkPtrStatic(_ s: inout Sema, _ elem: Type, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(&s, args, ["count"], "Ptr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            if elem != .error, !isRawScalar(elem) {
                s.diags.error("Ptr<T>.alloc requires a scalar element type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(elem)'", at: span)
            }
            let count = intArg(&s, args[0].value, "Ptr.alloc", "count")
            return s.ptrIntrinsic("__ptrAlloc", .ptr(elem), [count], span)
        default:
            s.diags.error("type 'Ptr<\(elem)>' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    static func checkPtrMethod(_ s: inout Sema, _ recv: NOIRExpr, _ elem: Type, _ name: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        if elem != .error, !isRawScalar(elem) {
            s.diags.error("Ptr<\(elem)> supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        switch name {
        case "load":
            guard checkArgLabels(&s, args, ["at"], "Ptr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let at = intArg(&s, args[0].value, "Ptr.load", "at")
            return s.ptrIntrinsic("__ptrLoad", elem, [recv, at], span)
        case "store":
            guard checkArgLabels(&s, args, [nil, "at"], "Ptr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let ce = NOIRGen.checkExpr(&s, args[0].value, expected: elem)
            let value = NOIRGen.coerce(&s, ce, to: elem)
            NOIRGen.checkAssignable(&s, value.type, to: elem, role: "argument", at: value.span)
            let at = intArg(&s, args[1].value, "Ptr.store", "at")
            return s.ptrIntrinsic("__ptrStore", .void, [recv, value, at], span)
        case "advanced":
            guard checkArgLabels(&s, args, ["by"], "Ptr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(&s, args[0].value, "Ptr.advanced", "by")
            return s.ptrIntrinsic("__ptrAdvanced", .ptr(elem), [recv, by], span)
        case "asRaw":
            guard checkArgLabels(&s, args, [], "Ptr.asRaw", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__ptrAsRaw", .rawPtr, [recv], span)
        case "free":
            guard checkArgLabels(&s, args, [], "Ptr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawFree", .void, [recv], span)   // same addrspace(0) word as RawPtr.free
        case "eq":
            guard checkArgLabels(&s, args, [nil], "Ptr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = NOIRGen.checkExpr(&s, args[0].value)
            if other.type != .ptr(elem), other.type != .error {
                s.diags.error("Ptr<\(elem)>.eq expects a 'Ptr<\(elem)>' argument, got '\(other.type)'", at: other.span)
            }
            return s.ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        default:
            s.diags.error("value of type 'Ptr<\(elem)>' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }
}

// Task 180: `ManagedBuffer<Header, Element>` — the four compiler intrinsics for the stdlib generic class
// (core.nomu). The declared class carries no method bodies; `create` (static) and `capacity` / `headerPtr` /
// `elementPtr` (instance) are synthesized here as `__managedBuffer*` intrinsic calls. Codegen derives the
// header byte size, element stride, and GC descriptor from the concrete `Header`/`Element` (through
// monomorphization's type-arg table), so Sema only emits the calls carrying the `ManagedBuffer` type on the
// relevant operand (the result for `create`, the receiver for the accessors).
enum ManagedBufferIntrinsics {
    private static func err(_ span: Span) -> NOIRExpr {
        NOIRExpr(type: .error, span: span, kind: .intLit(0))
    }

    // `ManagedBuffer<Header, Element>.create(capacity: Int) -> ManagedBuffer<Header, Element>`.
    static func checkStatic(_ s: inout Sema, header: Type, element: Type,
                            _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "create":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["capacity"], "ManagedBuffer.create", span) else {
                return err(span)
            }
            let cap = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.create", "capacity")
            return s.ptrIntrinsic("__managedBufferCreate",
                                  .generic(base: "ManagedBuffer", args: [header, element]), [cap], span)
        default:
            s.diags.error("'ManagedBuffer' has no static method '\(method)'", at: span)
            return err(span)
        }
    }

    // Instance accessors on a `ManagedBuffer` receiver: the raw accessors (`capacity()`, `headerPtr()`,
    // `elementPtr(at:)`) whose layout is resolved at codegen, and the typed *reference* accessors
    // (`storeRef`/`ref`, `storeHeaderRef`/`headerRef`) which read `Header`/`Element` from the receiver's
    // generic type here. The reference accessors store/load a managed pointer through the write-barrier /
    // `p1` path (codegen), the facility `Array<SomeClass>` needs to put a reference in a buffer; the raw
    // `RawPtr` accessors reject references (barrier-free), so scalar code uses those instead.
    static func checkMethod(_ s: inout Sema, _ recv: NOIRExpr,
                            _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        // `Header`/`Element` from `ManagedBuffer<Header, Element>`; the reference accessors require them.
        var header: Type? = nil, element: Type? = nil
        if case .generic(_, let gargs) = recv.type, gargs.count == 2 {
            header = gargs[0]; element = gargs[1]
        }
        switch method {
        case "capacity":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.capacity", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferCapacity", .int, [recv], span)
        case "headerPtr":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.headerPtr", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferHeaderPtr", .rawPtr, [recv], span)
        case "elementPtr":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at"], "ManagedBuffer.elementPtr", span) else { return err(span) }
            let i = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.elementPtr", "at")
            return s.ptrIntrinsic("__managedBufferElementPtr", .rawPtr, [recv, i], span)
        // Typed managed element access: store/load a reference at element slot `at`, through the write
        // barrier so the collector records the edge. Reference `Element` only — a bare `p1`, no aggregate;
        // a scalar/value element uses `elementPtr(at:)`.
        case "storeRef":
            guard let elem = requireRefArg(&s, element, kind: "Element", "storeRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil, "at"], "ManagedBuffer.storeRef", span) else { return err(span) }
            let value = refValueArg(&s, args[0].value, elem, span)
            let i = PointerIntrinsics.intArg(&s, args[1].value, "ManagedBuffer.storeRef", "at")
            return s.ptrIntrinsic("__managedBufferStoreRef", .void, [recv, value, i], span)
        case "ref":
            guard let elem = requireRefArg(&s, element, kind: "Element", "ref", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at"], "ManagedBuffer.ref", span) else { return err(span) }
            let i = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.ref", "at")
            return s.ptrIntrinsic("__managedBufferRef", elem, [recv, i], span)
        // The same, for a reference `Header` (the whole header is one managed pointer).
        case "storeHeaderRef":
            guard let hdr = requireRefArg(&s, header, kind: "Header", "storeHeaderRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil], "ManagedBuffer.storeHeaderRef", span) else { return err(span) }
            let value = refValueArg(&s, args[0].value, hdr, span)
            return s.ptrIntrinsic("__managedBufferStoreHeaderRef", .void, [recv, value], span)
        case "headerRef":
            guard let hdr = requireRefArg(&s, header, kind: "Header", "headerRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.headerRef", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferHeaderRef", hdr, [recv], span)
        default:
            s.diags.error("value of type 'ManagedBuffer' has no method '\(method)'", at: span)
            return err(span)
        }
    }

    // A reference accessor is well-formed only when the relevant type argument is a reference type (class /
    // actor / array). Returns the type on success; diagnoses and returns nil otherwise.
    private static func requireRefArg(_ s: inout Sema, _ t: Type?, kind: String,
                                      _ method: String, _ span: Span) -> Type? {
        guard let t = t else {
            s.diags.error("'ManagedBuffer.\(method)' needs the buffer's \(kind) type, e.g. 'ManagedBuffer<Header, Element>'", at: span)
            return nil
        }
        guard s.isReferenceType(t) else {
            s.diags.error("'ManagedBuffer.\(method)' requires a reference \(kind) (class or actor), but \(kind) is '\(t)'; use the raw accessor for a scalar or value \(kind.lowercased())", at: span)
            return nil
        }
        return t
    }

    // Typecheck a reference-valued argument against the expected reference type.
    private static func refValueArg(_ s: inout Sema, _ e: Expr, _ expected: Type, _ span: Span) -> NOIRExpr {
        let value = NOIRGen.coerce(&s, NOIRGen.checkExpr(&s, e, expected: expected), to: expected)
        NOIRGen.checkAssignable(&s, value.type, to: expected, role: "argument", at: span)
        return value
    }
}
