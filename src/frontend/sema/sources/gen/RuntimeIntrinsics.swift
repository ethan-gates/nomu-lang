import noir
import ast
import support
// Runtime intrinsics — the privileged operations of the runtime tier, spelled on `Runtime`, a type with
// no values that only the runtime tier may name (`internals/runtime-subset.md` §5): GC metadata reads, the
// scheduler handle, carrier-local state, the clocks and OS calls the runtime makes, the context switch, and
// thread and futex primitives. Each lowers to an internal intrinsic id (`__gc*`, `__sys*`, …) that
// `SSAIRToLLVM` emits. The unsafe raw-memory surface stays on `RawPtr` / `Ptr<T>` (PointerIntrinsics.swift).
enum RuntimeIntrinsics {

    private static func err(_ span: Span) -> NOIRExpr {
        NOIRExpr(type: .error, span: span, kind: .intLit(0))
    }

    // `Runtime.<method>(...)`, reached only in the runtime tier (outside it `Runtime` is an undefined name).
    static func checkStatic(_ s: inout Sema, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        // Static storage: zeroed bytes reserved in the data section, legal only as a global's whole initializer
        // with literal arguments. The global is a constant `RawPtr` folded to the block's address
        // (`tasks/223-retire-the-c-floor.md`, "The floor").
        case "staticStorage":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["bytes", "align"], "Runtime.staticStorage", span) else {
                return err(span)
            }
            guard s.staticStorageSite == span else {
                s.diags.error("'Runtime.staticStorage' is legal only as a global's whole initializer", at: span)
                return err(span)
            }
            guard case .intLit(let bytes, _) = args[0].value, case .intLit(let align, _) = args[1].value else {
                s.diags.error("'Runtime.staticStorage' takes integer literals for 'bytes' and 'align'", at: span)
                return err(span)
            }
            guard bytes > 0, align > 0, align & (align - 1) == 0, align <= 4096 else {
                s.diags.error("'Runtime.staticStorage' needs 'bytes' above 0 and 'align' a power of two up to 4096", at: span)
                return err(span)
            }
            return s.ptrIntrinsic("__staticStorage", .rawPtr,
                                  [NOIRExpr(type: .int, span: span, kind: .intLit(bytes)),
                                   NOIRExpr(type: .int, span: span, kind: .intLit(align))], span)
        // The GC type tables, read by the runtime's descriptor accessors (`runtime/descriptors.nomu`, "GC type
        // descriptors"). `gcTypeCount` is the number of descriptor records; `gcDescBase` and `gcPtrmapBase` are
        // the starts of the descriptor and pointer-map sections, through the linker's section-bracket symbols.
        // All are gc-leaf reads of read-only data.
        case "gcTypeCount":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcTypeCount", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcTypeCount", .int, [], span)
        case "gcDescBase", "gcPtrmapBase":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.\(method)", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__" + method, .rawPtr, [], span)   // __gcDescBase / __gcPtrmapBase
        // A sign-extending 32-bit load: the descriptor fields and pointer-map entries are `int32`, and Nomu has
        // no 32-bit integer type yet. When it has one, `RawPtr.load` as that type replaces this.
        case "loadInt32":
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil, "at"], "Runtime.loadInt32", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let p = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.loadInt32", "pointer")
            let off = PointerIntrinsics.intArg(&s, args[1].value, "Runtime.loadInt32", "at")
            return s.ptrIntrinsic("__rawLoadInt32", .int, [p, off], span)
        // Write a string literal and a newline to standard error, then abort: the runtime's fatal error. The
        // argument must be a literal, since the runtime subset calls no `String` method. Never returns.
        case "fatal":
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil], "Runtime.fatal", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .stringLit(let v, let lspan) = args[0].value else {
                s.diags.error("Runtime.fatal expects a string literal", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let text = NOIRExpr(type: .stringBase, span: lspan, kind: .stringLit(v + "\n"))
            return s.ptrIntrinsic("__sysFatal", .void, [text], span)
        // The `__llvm_stackmaps` section (task 150 rung 2, the pcsp root walk): base address + byte size,
        // reached through the linker-provided section-bracket symbols (no libc, no new runtime C). The Nomu
        // pcsp walk parses this section (return-address → SP-relative root slots + per-function frame size).
        case "gcStackmapBase":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcStackmapBase", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcStackmapBase", .rawPtr, [], span)
        case "gcStackmapSize":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcStackmapSize", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcStackmapSize", .int, [], span)
        // The GC frame index the driver writes after the link (task 195): the start of its section
        // (`__DATA_CONST,__nomu_frameidx`; the index begins at the first 8-aligned address in it). The
        // self-hosted walk maps a return address to its stackmap record through it (`rtFrameLookup`).
        case "gcFrameIndexBase":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcFrameIndexBase", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcFrameIndexBase", .rawPtr, [], span)
        // Stack-walk anchors (task 150 rung 2, pcsp walk): the caller frame's frame pointer (as a RawPtr)
        // and the return address into the caller (as an Int) — `llvm.frameaddress`/`llvm.returnaddress`.
        // From these the pcsp walk derives each frame's SP and steps by the stackmap's per-function size.
        case "gcFrameAddr":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcFrameAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcFrameAddr", .rawPtr, [], span)
        case "gcReturnAddr":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcReturnAddr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__gcReturnAddr", .int, [], span)
        // Scheduler substrate — raw OS clock (task 128.1.1). Monotonic time in nanoseconds, the primitive
        // under the scheduler's timer heap. It reaches the OS directly (macOS: the libSystem entry
        // `clock_gettime_nsec_np`; selfhosted-scheduler.md §3.3), bypassing the C-runtime shim — a step
        // toward retiring the C floor (128 goal 1). gc-leaf: no managed heap, no alloc, subset-legal.
        case "monotonicNanos":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.monotonicNanos", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysMonotonicNanos", .int, [], span)
        // The collector's clock: raw ticks of the CPU's monotonic counter (`mach_absolute_time`, ~5 ns), converted
        // to time only when a report is written. gc-leaf, subset-legal.
        case "ticks":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.ticks", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysTicks", .int, [], span)
        // The process-level calls the collector's report needs (gc-observability), each a libSystem entry.
        // Wall-clock time in nanoseconds since the epoch (`clock_gettime_nsec_np(CLOCK_REALTIME)`).
        case "wallNanos":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.wallNanos", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysWallNanos", .int, [], span)
        // `mach_timebase_info` into `info` (two UInt32: numer @0, denom @4): ticks × numer / denom = ns.
        case "timebase":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["info"], "Runtime.timebase", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysTimebase", .int, [PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.timebase", "info")], span)
        // `getenv`: the variable's NUL-terminated value, or null.
        case "getenv":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["name"], "Runtime.getenv", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysGetenv", .rawPtr, [PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.getenv", "name")], span)
        // `_NSGetExecutablePath(buf, size)`: the executable's path, NUL-terminated; `size` is a UInt32 cell
        // holding the buffer's size. Returns 0 on success.
        case "executablePath":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["buf", "size"], "Runtime.executablePath", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysExecutablePath", .int,
                                  [PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.executablePath", "buf"),
                                   PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.executablePath", "size")], span)
        // `creat(path, mode)`: create or truncate the file at the NUL-terminated `path` for writing; the fd or -1.
        case "createFile":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["path", "mode"], "Runtime.createFile", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysCreat", .int,
                                  [PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.createFile", "path"),
                                   PointerIntrinsics.intArg(&s, args[1].value, "Runtime.createFile", "mode")], span)
        case "closeFd":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["fd"], "Runtime.closeFd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysClose", .int, [PointerIntrinsics.intArg(&s, args[0].value, "Runtime.closeFd", "fd")], span)
        // Copy a string literal's UTF-8 bytes to `to`; returns their count. The runtime's way to write text,
        // since the runtime subset calls no `String` method. The argument must be a literal.
        case "copyLiteral":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["to", nil], "Runtime.copyLiteral", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let dst = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.copyLiteral", "to")
            guard case .stringLit(let v, let lspan) = args[1].value else {
                s.diags.error("Runtime.copyLiteral expects a string literal", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            // The literal's `StringBase`, unwrapped: the subset calls no `String` method.
            let text = NOIRExpr(type: .stringBase, span: lspan, kind: .stringLit(v))
            return s.ptrIntrinsic("__sysCopyLiteral", .int, [dst, text], span)
        // The `gc.record` setting as a constant (0 off, 1 limited, 2 full), so recording code under a level the
        // setting leaves off folds away.
        case "gcRecordLevel":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcRecordLevel", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return NOIRExpr(type: .int, span: span, kind: .intLit(s.gcRecordLevel))
        // The `gc.plan` setting as a constant (0 genimmix, 1 immix), so code for the plan not chosen folds away.
        case "gcPlan":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.gcPlan", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return NOIRExpr(type: .int, span: span, kind: .intLit(s.gcPlan))
        // The carrier-local slot: one word per carrier thread, holding the running fiber, so a fiber that
        // parks can find itself without threading its handle through user code. A direct read of the
        // thread's TSD slot for a key the runtime creates at startup (`tasks/223-retire-the-c-floor.md`,
        // "The floor"). Subset-legal (`__sys`).
        // A zeroed reservation: `bytes` of memory guaranteed to read as zero, aligned to `align`, whose pages
        // become resident only as they are first touched; never freed. For long-lived regions sized up front
        // (the collector's heap and side tables), where `RawPtr.alloc`'s zero-fill would make every page
        // resident at once. Subset-legal (`__sys`).
        case "reserveZeroed":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["bytes", "align"], "Runtime.reserveZeroed", span) else {
                return err(span)
            }
            let bytes = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.reserveZeroed", "bytes")
            let align = PointerIntrinsics.intArg(&s, args[1].value, "Runtime.reserveZeroed", "align")
            return s.ptrIntrinsic("__sysReserveZeroed", .rawPtr, [bytes, align], span)
        case "carrierLocal":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.carrierLocal", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysCarrierLocal", .rawPtr, [], span)
        case "setCarrierLocal":
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil], "Runtime.setCarrierLocal", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let v = NOIRGen.checkExpr(&s, args[0].value)
            if v.type != .rawPtr, v.type != .error {
                s.diags.error("Runtime.setCarrierLocal expects a 'RawPtr', got '\(v.type)'", at: v.span)
            }
            return s.ptrIntrinsic("__sysSetCarrierLocal", .void, [v], span)
        // I/O poller substrate (task 128.1.7): the macOS kqueue floor + the fds a poller test drives to
        // readiness. All libSystem externs (selfhosted-scheduler.md §3.3), subset-legal (`__sys`). fds and
        // event/change buffers are raw memory; fd numbers and counts are Int.
        case "kqueue":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.kqueue", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysKqueue", .int, [], span)      // int kqueue(void)
        case "kevent":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["kq", "changes", "nchanges", "events", "nevents"], "Runtime.kevent", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let kq = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.kevent", "kq")
            let changes = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.kevent", "changes")
            let nch = PointerIntrinsics.intArg(&s, args[2].value, "Runtime.kevent", "nchanges")
            let events = PointerIntrinsics.ptrArg(&s, args[3].value, "Runtime.kevent", "events")
            let nev = PointerIntrinsics.intArg(&s, args[4].value, "Runtime.kevent", "nevents")
            return s.ptrIntrinsic("__sysKevent", .int, [kq, changes, nch, events, nev], span)
        case "pipe":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["fds"], "Runtime.pipe", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__sysPipe", .int, [PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.pipe", "fds")], span)  // int pipe(int fds[2])
        case "writeFd":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["fd", "buf", "count"], "Runtime.writeFd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let wfd = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.writeFd", "fd")
            let wbuf = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.writeFd", "buf")
            let wcnt = PointerIntrinsics.intArg(&s, args[2].value, "Runtime.writeFd", "count")
            return s.ptrIntrinsic("__sysWrite", .int, [wfd, wbuf, wcnt], span)
        case "readFd":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["fd", "buf", "count"], "Runtime.readFd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let rfd = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.readFd", "fd")
            let rbuf = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.readFd", "buf")
            let rcnt = PointerIntrinsics.intArg(&s, args[2].value, "Runtime.readFd", "count")
            return s.ptrIntrinsic("__sysRead", .int, [rfd, rbuf, rcnt], span)
        // Whether `fd` has input, or end of input, right now: `poll(2)` with a zero timeout. 1 if so, else 0.
        // The readiness check line input makes before it parks (`rtReadLine`).
        case "poll":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["fd"], "Runtime.poll", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let pfd = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.poll", "fd")
            return s.ptrIntrinsic("__sysPoll", .int, [pfd], span)
        // The C-ABI code address of a top-level, non-capturing function as a RawPtr (task 128.2). A
        // runtime-tier primitive for handing an entry point to the asm floor (rtFiberInit) or
        // pthread_create — deliberately not first-class functions (task 128 note: full first-class
        // functions/closures for user code are a later, separate language step). The argument must name a
        // top-level `fun (_: RawPtr) -> RawPtr` — the carrier/fiber-entry ABI (a bare pointer, no env) — or a
        // `fun (_: Int, _: RawPtr, _: RawPtr)`, the `SA_SIGINFO` signal handler's (`Runtime.sigaction`).
        case "ofFunc":
            guard args.count == 1, args[0].label == nil else {
                s.diags.error("Runtime.ofFunc takes one argument: a top-level function name", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .ident(let fname, _) = args[0].value else {
                s.diags.error("Runtime.ofFunc expects a bare top-level function name, e.g. 'Runtime.ofFunc(carrierMain)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard let sig = s.funcs[fname] else {
                s.diags.error("no top-level function named '\(fname)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let entryShape = sig.params == [.rawPtr] && sig.ret == .rawPtr
            let handlerShape = sig.params == [.int, .rawPtr, .rawPtr] && sig.ret == .void
            guard sig.generics.isEmpty, entryShape || handlerShape else {
                s.diags.error("Runtime.ofFunc requires a non-generic 'fun \(fname)(_: RawPtr) -> RawPtr' or "
                              + "'fun \(fname)(_: Int, _: RawPtr, _: RawPtr)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return NOIRExpr(type: .rawPtr, span: span, kind: .funcRef(name: fname))
        // Fault handling (task 219): install a signal handler, give the calling thread an alternate signal
        // stack, read the stack the calling thread has, and send a signal to the calling thread. libSystem
        // externs; the `struct sigaction` and `stack_t` layouts are built in the lowering. Each returns the C
        // call's result (0 on success), except `currentAltStack`.
        //   sigaction(signal:handler:flags:)  handler from Runtime.ofFunc (the SA_SIGINFO shape); no mask
        //   sigaltstack(base:size:)           the stack for this thread's handlers, enabled
        //   currentAltStack()                 this thread's alternate stack base, or null when it has none
        //   raise(signal:)                    the signal, sent to the calling thread
        //   imageHeader()                     the executable's Mach-O header, where it is loaded
        case "sigaction":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["signal", "handler", "flags"], "Runtime.sigaction", span) else { return err(span) }
            let sg = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.sigaction", "signal")
            let h = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.sigaction", "handler")
            let fl = PointerIntrinsics.intArg(&s, args[2].value, "Runtime.sigaction", "flags")
            return s.ptrIntrinsic("__sysSigaction", .int, [sg, h, fl], span)
        case "sigaltstack":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["base", "size"], "Runtime.sigaltstack", span) else { return err(span) }
            let base = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.sigaltstack", "base")
            let size = PointerIntrinsics.intArg(&s, args[1].value, "Runtime.sigaltstack", "size")
            return s.ptrIntrinsic("__sysSigaltstack", .int, [base, size], span)
        case "currentAltStack":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.currentAltStack", span) else { return err(span) }
            return s.ptrIntrinsic("__sysCurrentAltStack", .rawPtr, [], span)
        case "imageHeader":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "Runtime.imageHeader", span) else { return err(span) }
            return s.ptrIntrinsic("__sysImageHeader", .rawPtr, [], span)
        case "raise":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["signal"], "Runtime.raise", span) else { return err(span) }
            let sg = PointerIntrinsics.intArg(&s, args[0].value, "Runtime.raise", "signal")
            return s.ptrIntrinsic("__sysRaise", .int, [sg], span)
        // Asm-floor context switch (task 128.2). `from` is the context buffer to save into (≥168 bytes, the
        // callee-saved set); `to` is the context to resume. Saves the current registers into `from` and jumps
        // into `to` (rtSwitch). Subset-legal (`__sys`).
        case "ctxSwitch":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["from", "to"], "Runtime.ctxSwitch", span) else { return err(span) }
            let from = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.ctxSwitch", "from")
            let to = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.ctxSwitch", "to")
            return s.ptrIntrinsic("__sysCtxSwitch", .void, [from, to], span)
        // Seed a fresh fiber's context buffer so the first switch into it lands in the trampoline running
        // `entry(arg)` on `stackTop` (rtFiberInit). `entry` is a code address from Runtime.ofFunc.
        case "fiberInit":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["context", "stackTop", "entry", "arg"], "Runtime.fiberInit", span) else { return err(span) }
            let ctx = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.fiberInit", "context")
            let stackTop = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.fiberInit", "stackTop")
            let entry = PointerIntrinsics.ptrArg(&s, args[2].value, "Runtime.fiberInit", "entry")
            let arg = PointerIntrinsics.ptrArg(&s, args[3].value, "Runtime.fiberInit", "arg")
            return s.ptrIntrinsic("__sysFiberInit", .void, [ctx, stackTop, entry, arg], span)
        // Carrier thread create (task 128.2). `handle` is a slot holding the thread handle (`pthread_t`,
        // ≥8 bytes). Starts `entry(arg)` on a new OS thread via pthread_create. `entry` is a
        // `(RawPtr) -> RawPtr` address from Runtime.ofFunc. Returns 0 on success (else the error number).
        case "threadCreate":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["handle", "entry", "arg"], "Runtime.threadCreate", span) else { return err(span) }
            let handle = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.threadCreate", "handle")
            let entry = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.threadCreate", "entry")
            let arg = PointerIntrinsics.ptrArg(&s, args[2].value, "Runtime.threadCreate", "arg")
            return s.ptrIntrinsic("__sysThreadCreate", .int, [handle, entry, arg], span)
        // Join the thread whose handle `handle` holds (pthread_join): the slot passed to threadCreate.
        // Blocks until it exits; returns 0 on success.
        case "threadJoin":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["handle"], "Runtime.threadJoin", span) else { return err(span) }
            let handle = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.threadJoin", "handle")
            return s.ptrIntrinsic("__sysThreadJoin", .int, [handle], span)
        // Call through a code address with the fiber-entry ABI `(RawPtr) -> RawPtr` (task 128.1.3): invoke
        // `fn` (from Runtime.ofFunc) with `arg` and return its result. The scheduler's fiber trampoline runs a
        // fiber's user entry this way. An indirect call — the subset closure check does not see a named
        // non-subset callee, so a subset scheduler may run a non-subset fiber body across this boundary.
        case "callEntry":
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil, "arg"], "Runtime.callEntry", span) else { return err(span) }
            let fn = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.callEntry", "the function address")
            let a = PointerIntrinsics.ptrArg(&s, args[1].value, "Runtime.callEntry", "arg")
            return s.ptrIntrinsic("__sysCallEntry", .rawPtr, [fn, a], span)
        // Futex (task 128.1.1) — the address of a memory word a carrier sleeps on and is woken from, the
        // primitive under the mutex and idle-carrier sleep. macOS: the libSystem entries __ulock_wait /
        // __ulock_wake, no C-runtime shim. gc-leaf, subset-legal (`__sys`).
        // `futexWait(at:expected:timeoutMicros:)`: sleep only while the word at `at` still equals `expected`
        // (the kernel re-checks atomically, closing the check-then-sleep race); a mismatch returns at once, a
        // match blocks up to the timeout. Returns the raw result (≥ 0 ok; < 0 a negated errno).
        case "futexWait":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at", "expected", "timeoutMicros"], "Runtime.futexWait", span) else { return err(span) }
            let word = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.futexWait", "at")
            let expc = PointerIntrinsics.intArg(&s, args[1].value, "Runtime.futexWait", "expected")
            let tmo = PointerIntrinsics.intArg(&s, args[2].value, "Runtime.futexWait", "timeoutMicros")
            return s.ptrIntrinsic("__sysFutexWait", .int, [word, expc, tmo], span)
        // `futexWake(at:all:)`: wake one waiter (lock handoff) or all (STW broadcast). Returns the raw result.
        case "futexWake":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at", "all"], "Runtime.futexWake", span) else { return err(span) }
            let word = PointerIntrinsics.ptrArg(&s, args[0].value, "Runtime.futexWake", "at")
            let all = NOIRGen.checkExpr(&s, args[1].value)
            if all.type != .bool, all.type != .error {
                s.diags.error("Runtime.futexWake expects a Bool 'all' argument, got '\(all.type)'", at: all.span)
            }
            return s.ptrIntrinsic("__sysFutexWake", .int, [word, all], span)
        default:
            s.diags.error("type 'Runtime' has no member '\(method)'", at: span)
            return err(span)
        }
    }
}
