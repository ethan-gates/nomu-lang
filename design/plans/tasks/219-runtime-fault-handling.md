# Runtime fault handling — a signal handler that says where a program died

**Avenue:** Risk · **Type/Lifecycle:** `runtime` · **Size:** M · **Status:** done (219.1–219.5) ·
**Source:** split from [159](159-gc-observability.md): its phase breadcrumbs need a fault handler, and the
runtime has none.

## Today

The runtime installs no signal handlers. Its own fatal paths print and stop: an out-of-range index
(`rtBoundsTrap`, through `Runtime.fatal`, which aborts) and the runtime's other `Runtime.fatal` sites. A real
fault (`SIGSEGV`, `SIGBUS`, `SIGILL`) takes the operating system's default: the process dies and macOS writes
a crash report whose backtrace cannot unwind fiber or carrier stacks (frame #0 only). Fiber stacks are
128 KiB blocks from `RawPtr.alloc` (`rtSchedFiberNew`) with no guard page, so a fiber stack overflow
overwrites the memory below it without faulting ([104](104-fiber-stack-strategy.md)).

The runtime's threads: the main thread (`nomuSchedBoot`), the carriers (`rtSchedCarrierMain`), the timer
(`rtSchedTimerMain`), the GC coordinator (`rtGcCoordinatorMain`) and the stdin poller (`rtStdinPollerMain`).

## What

One fault handler for the runtime. On a fault it prints what the runtime knows (the signal, the faulting
address, the thread, and what each subsystem reports) and then dies with the signal's default action, so the
exit status and the system crash report are unchanged.

## Design

- **Constraints of a handler.** It runs on the faulting thread at an arbitrary instruction, possibly while
  that thread holds a lock or is midway through an update. So it takes no locks, allocates nothing, and calls
  only async-signal-safe functions: it prints with `write(2)`.
- **The handler is Nomu.** A runtime-subset function: subset functions carry no safepoint poll, so the
  handler never joins a collection or parks. `sigaction`, `sigaltstack` and `raise` become `Runtime`
  intrinsics beside `kevent` and `poll`, adding no C.
- **Its entry shape.** `Runtime.ofFunc` accepts a second shape, `fun (Int, RawPtr, RawPtr)`, the
  `SA_SIGINFO` handler's. The handler reads the signal number from `siginfo` at offset 0
  (`Runtime.loadInt32`): the `int` argument's high bits are undefined on arm64.
- **Signals.** `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP` and `SIGABRT`. With `SIGABRT`, `Runtime.fatal` and the
  bounds trap get the report too.
- **Dying with the default action.** Installed with `SA_RESETHAND | SA_ONSTACK | SA_SIGINFO`; after printing,
  the handler calls `raise(sig)` and returns. The signal stays blocked until the return, then the default
  action runs. This covers a signal sent with `kill` as well as a synchronous fault. A second thread faulting
  meanwhile dies on the default action at once.
- **Its own stack.** Every thread the runtime starts gets an alternate signal stack (`sigaltstack`), so a
  stack overflow can still be reported: main, carriers, timer, GC coordinator and stdin poller, through one
  helper called at each thread's entry, about 64 KiB each. Fibers run on carriers and share the carrier's.
  The coordinator runs the collector, the setting of 159's segfault.
- **Reporters, a fixed list.** A reporter is a runtime component's function that prints what it knows when
  the handler runs. It reads only data written so that an interrupted writer leaves it whole, takes no locks
  and allocates nothing. The handler calls each by name: the first is 159's recorder (each thread's last open
  interval), which folds away with `gc.record` off; a fiber guard page (104) is the next. All are known when
  the runtime compiles, and Nomu has no function values for a registry to build on. A registry can replace
  the list if code outside the runtime ever adds reporters.
- **A backtrace of raw addresses.** A frame-pointer walk from the `ucontext`'s pc, lr and fp, printed as raw
  return addresses. It follows carrier and fiber stacks, where the system crash report stops at frame #0.
  The binary carries no symbols: names are recovered afterwards from debug info kept outside it (below).
  Go embeds names and lines in every binary (`pclntab`), at a large share of its size; Nomu keeps that
  weight out of the binary.
- **Linux.** The `siginfo` and `ucontext` offsets and the signal numbers sit in one place, for
  [218](218-linux-support.md).
- **Stack growth (104).** Fiber stacks will grow from a small start. 104 grows them without the fault
  handler: either a check on function entry that moves the stack (as Go does), or a reserved range the system
  commits as it is touched, with a guard page past its end. Growth driven by the fault itself would make the
  handler part of normal execution, which a one-shot handler that prints and dies cannot be.

## Symbolication

The report is the same in every case; what differs is who turns its addresses into names, and where the
debug info comes from.

1. **A binary built on the same machine** (compiler developers, today's case). `nomu run` symbolizes its
   program's crash itself: it knows the binary it just built, and reads the debug info from it (its dSYM, or
   one made from the objects the binary names).
2. **A binary built elsewhere.** A developer, or a service, looks up the debug info by build ID: the local
   store first, then configured stores (a shared directory or a server, as Windows symbol servers,
   `debuginfod` and Sentry work), and symbolizes locally. Publishing a release's debug info is a build step.
   The command is `nomu tool symbolize`, under a `nomu tool` group for infrequent tools, as Go keeps
   `go tool addr2line`.
3. **An end user's crash sent to the developers.** The handler cannot prompt, open a connection or allocate,
   so the pattern is a report written to a file and sent later by the app or a library (as Crashpad,
   Breakpad and PLCrashReporter do). Re-raising with the default action keeps the system's crash report, and
   with it Apple's crash collection.

What the report and the handler hold to, so none of these is locked out:

- **Every loaded image is identified**: its build ID (`LC_UUID` on macOS) and load address, the main
  binary's and any library's.
- **A stable, versioned format**: lines a person reads on a terminal, under a fixed header block a tool
  parses.
- **Addresses and runtime state only**: no memory contents, arguments or environment, so a report is safe to
  send off the machine.
- **The default action after printing**, already above.
- **Room for later**: a file destination beside stderr (writing a file is safe in a handler), remote symbol
  stores in the lookup list, and chaining a handler installed before the runtime's.

## Work

- **219.1** The handler: the intrinsics (`sigaction`, `sigaltstack`, `raise`) and `ofFunc`'s handler shape,
  installed at startup; an alternate stack per runtime thread; the report's header, signal, faulting address
  and thread; then the default action. *Done:* `runtime/fault.nomu`; `Runtime.sigaction`, `sigaltstack`,
  `currentAltStack` and `raise`; the process entry installs the handler before the startup globals, and each
  runtime thread calls `rtFaultThreadStart` at its entry, which labels its alternate stack with the thread's
  kind and number. The report is lines prefixed `nomu-crash: `, the first `format 1`. A null read reports
  `SIGSEGV` with its address and exits 139; an out-of-range index reports `SIGABRT` after the fatal error and
  exits 134. Checked by hand; the suite cases come with 219.4, which needs the harness to expect a crash.
- **219.2** Reporters: the fixed list; 159's breadcrumbs as the first. *Done:* `rtGcFaultReport`
  (`runtime/gcreport.nomu`), called by the handler after the thread line: with `gc.record` on, one line with
  the coordinator's cycle and kind and its open phases, outermost first (`nomu-crash: gc: cycle 23 (minor), in
  collect > scan`), or `between cycles, N completed`; nothing with recording off. Phase and kind names come
  from `rtGcName`, which the report writer's `rtGcPutName` now calls too. Checked by hand: a null read under
  `gc_record`, and `SIGABRT` sent to binary-trees during collections.
- **219.3** The backtrace: the frame-pointer walk; each image's build ID and load address in the report.
  *Done:* `rtFaultBacktrace` (`runtime/fault.nomu`): an `image:` line (the executable's LC_UUID, read from its
  Mach-O header through `Runtime.imageHeader`, and its load address), a `registers:` line (pc, lr, sp, fp), one
  `frame i:` line per frame record from the faulting fp, then `end`; written a line at a time, so a walk that
  faults on a bad frame pointer leaves the lines before it. The walk stops at a null or misaligned fp, a null
  return address, a record not above the last, or 64 frames; fibers end at the trampoline's null fp. Every
  function now keeps frame pointers (`frame-pointer`=`non-leaf`, set on each defined function before the
  pass pipeline, `LLVMBridge.swift`): LLVM had kept x29 as an ordinary register, so there was no chain.
  binary-trees is unchanged (depth 18 0.37 s, depth 19 0.97 s). Checked by hand: the build ID matches
  `dwarfdump --uuid`, and `atos` with the printed load address names the frames (a null read: `nomu_main`,
  `rtSchedFiberMain`); a symbolizer looks up return addresses less one. Only the executable is listed:
  addresses in system libraries are left to the system's own symbolization.
- **219.4** Tests: a deliberate fault in a fixture prints the signal, the last interval and a backtrace, and
  the exit status is the signal's. *Done:* the harness takes `expect.signal` (`SIGSEGV`, `SIGABRT`, …): each
  run must die from that signal, and `stdout` and `stderr_match` are still checked. Three cases
  (`runtime.yaml`): `crash-segv` (a null read: the report's lines, the address, three or more frames, no GC
  line, `end`), `crash-bounds` (an out-of-range index: the fatal error, then `SIGABRT` with no address line)
  and `crash-gc-record` (the null read under `gc_record`: `between cycles, 0 completed`). A run that exits
  instead, or dies from another signal, fails with the expected signal named. Each crash leaves a system crash
  report in `~/Library/Logs/DiagnosticReports`.
- **219.5** `nomu run` symbolizes its program's crash. *Done:* the runtime also writes its report to the file
  `NOMU_CRASH_REPORT` names (read once at install; the planned file destination); `nomu run` sets it, and when
  its program dies from a signal it prints `nomu: crash backtrace`, a line per frame with its name and
  `file:line` (`CrashReport.swift`). Debug info comes from the binary's `.dSYM` when the build gathered one,
  else from a `dsymutil` run made then over the objects the binary names; `atos` maps each address (return
  addresses less one) and `c++filt` demangles the v0 names; frames in system libraries show as outside the
  binary. Every step is best-effort, leaving the raw report. `nomu run` now exits 128 plus the signal, as a
  shell reports a crash. Three fixes it needed: debug info now puts each function in its own source file (a
  module of several files had every function in one); the first fiber's entry (`__nomu_main_entry`) and the
  fiber trampoline (`rtFiberTrampoline`) are global symbols, since the link strips local ones and those frames
  took a neighbour's name. Tested in `build_tests` (`testRunSymbolizesCrash`). Keeping debug info by build ID
  is not needed while `nomu run` holds the binary; it moves to scenario 2 below.
- Later: `nomu tool symbolize` for scenario 2, with debug info kept by build ID (the host cache) and remote
  symbol stores; handler chaining.

## Refs

`rtBoundsTrap` (`src/stdlib/runtime/io.nomu`), `rtSchedFiberNew` and `nomuSchedBoot`
(`src/stdlib/runtime/scheduler.nomu`), `Runtime.ofFunc` (`RuntimeIntrinsics.swift`), the recorder
(`src/stdlib/runtime/gcreport.nomu`); [159 GC observability](159-gc-observability.md),
[104 fiber stack strategy](104-fiber-stack-strategy.md), [218 Linux support](218-linux-support.md) (signal
numbers and `ucontext` differ).
