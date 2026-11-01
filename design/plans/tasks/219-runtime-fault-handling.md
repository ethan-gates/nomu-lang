# Runtime fault handling — a signal handler that says where a program died

**Avenue:** Risk · **Type/Lifecycle:** `runtime · needs-design` · **Size:** S–M · **Status:** needs-design
(three open questions below) · **Source:** split from [159](159-gc-observability.md): its phase breadcrumbs
need a fault handler, and the runtime has none.

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
- **Its own stack.** A thread gets an alternate signal stack (`sigaltstack`), so a stack overflow can still be
  reported. Which threads is open question 2.
- **Reporters.** A reporter reads only data written so that an interrupted writer leaves it whole. The first
  is 159's recorder (each thread's last open interval); a fiber guard page (104) is the next. How the handler
  reaches them is open question 1.
- **Linux.** The `siginfo` and `ucontext` offsets and the signal numbers sit in one place, for
  [218](218-linux-support.md).

## Open questions

1. **How reporters are wired in.**
   - (a) A registry: a static table of code addresses the handler calls through `Runtime.callEntry`.
   - (b) A fixed list: the handler calls each reporter by name. The recorder's reporter folds away with
     `gc.record` off, as every recording path does.

   Recommendation: (b). There are two reporters, both known when the runtime compiles, and Nomu has no
   first-class functions for a registry to build on.
2. **Which threads get an alternate stack.**
   - (a) The carriers only.
   - (b) Every thread the runtime starts: main, carriers, timer, GC coordinator, stdin poller, through one
     helper called at each thread's entry.

   Recommendation: (b). The coordinator runs the collector, the setting of 159's segfault, and a thread
   without an alternate stack loses the report on a stack overflow. About 64 KiB per thread.
3. **A backtrace.** Outside the scope as first written.
   - (a) None: the signal, the address, the thread and the reporters.
   - (b) A frame-pointer walk from the `ucontext`'s pc, lr and fp, printed as raw addresses with the image's
     load address, so `atos -o <bin> -l <base> …` symbolizes them. It walks carrier and fiber stacks, where
     the system crash report stops at frame #0. One more intrinsic: the image's load address
     (`__mh_execute_header`).
   - (c) The same walk, symbolized in process. It needs a symbol table in the binary, a larger change.

   Recommendation: (b), as its own step (219.3 below). It answers the frame-#0-only problem that 159 grew
   out of, for little cost.

## Work

Written for the recommended answers; an answer that differs reshapes it.

- **219.1** The handler: the intrinsics and `ofFunc`'s handler shape, installed at startup, an alternate
  stack per runtime thread, the signal, faulting address and thread printed, then the default action.
- **219.2** Reporters: the fixed list; 159's breadcrumbs as the first.
- **219.3** The backtrace: the frame-pointer walk and the image's load address.
- **219.4** Tests: a deliberate fault in a fixture prints the signal, the last interval and a backtrace, and
  the exit status is the signal's.

## Refs

`rtBoundsTrap` (`src/stdlib/runtime/io.nomu`), `rtSchedFiberNew` and `nomuSchedBoot`
(`src/stdlib/runtime/scheduler.nomu`), `Runtime.ofFunc` (`RuntimeIntrinsics.swift`), the recorder
(`src/stdlib/runtime/gcreport.nomu`); [159 GC observability](159-gc-observability.md),
[104 fiber stack strategy](104-fiber-stack-strategy.md), [218 Linux support](218-linux-support.md) (signal
numbers and `ucontext` differ).
