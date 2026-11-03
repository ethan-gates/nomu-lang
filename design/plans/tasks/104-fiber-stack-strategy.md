# Fiber stack strategy: growth, overflow, high-fiber-count throughput

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design`
(runtime + compiler architecture) · **Size:** L · **Status:** direction decided (Go-style copying stacks);
104.1 (baseline) done; the entry check decided; waits on [194](194-gc-frame-metadata.md) (the stack copier needs its contract, and 104's other parts wait with it); built before any collector is measured · **Source:** deferred.md

**Scheduled before any collector is measured** (the benchmark against Go and Swift on GenImmix, then the
GenImmix–LXR comparison), so the benchmarks run on large, fiber-heavy programs. Today's three stack
problems are fixed together: overflow is silent (no guard page), every fiber commits its whole 128 KiB up
front (`rtSchedFiberNew` takes its stack from `RawPtr.alloc`), and the size is fixed.

## Decision: Go-style stacks, copied on growth

Fibers start with a small stack (Go's is 2 KiB). A function checks on entry that the stack has room for
it; when it does not, the runtime copies the stack to one twice the size, fixes every pointer into it, and
continues. The collector shrinks a stack that is mostly unused.

**Why.** Nomu's goal is highly concurrent code as fast as Go or faster, and the workloads it means are
switch-heavy: actors and messages, fibers parking and resuming constantly, at very high fiber counts. That
asks for the fastest switch and the least memory per fiber together. Copying stacks give both: a switch
saves and restores registers and moves nothing, and a fiber's stack is as small as a few KiB and gives
memory back. The cost is a check on function entry (a load, a compare and a predicted branch; typically a
few percent), which inference can drop on most paths (below).

**Alternatives considered:**

- **Fixed stacks** (today): no checks, but 128 KiB a fiber caps the fiber count and overflows silently.
- **Guard page and lazy commit**: reserve a large range per fiber and let the system commit pages as they
  are touched, with a guard page past the end. No checks and calls into C stay on the fiber's stack, but a
  stack is at least one page (16 KiB on Apple Silicon, against Go's 2 KiB), committed memory comes back
  only through explicit system calls, and every fiber holds an address range (Linux limits the count of
  mappings to 65,530 by default). It loses on fiber density, which the goal turns on.
- **Segmented stacks**: Go's first design, dropped because a call sitting on a segment boundary allocates
  and frees a segment on every call ("hot split").
- **Frames copied out on park (Java's virtual threads, Loom)**: a fiber runs on its carrier's large stack
  with no checks; parking copies its frames into a heap object, and resuming copies the top frames back
  lazily. Parked fibers are the smallest of any scheme, but every switch copies frames, which taxes the
  switch-heavy workloads Nomu targets; and frames come back at another address on every resume, so every
  pointer into a frame (Nomu places non-escaping objects in frames) would need fixing on every resume, or
  frames that can park could hold no such objects. Not planned.
- **Stackless coroutines** (Rust `async`, C++ coroutines): a suspending function becomes a state machine
  holding only its live values. They need suspending functions marked, which Nomu does not allow: its
  concurrency is colorless. An inferred version would be colorless but would have to treat every call
  through an interface or a function value as one that suspends, transforming most of a program.

## Decided: the entry check

Every non-runtime function checks on entry that its fiber's stack has room for its frame: it compares the
stack pointer, less the frame, with the stack limit, and calls into the runtime to grow when short.

- **The frame size: emitted in IR, verified after code generation.** LLVM computes frame sizes only in its
  code generator, and its split-stack prologue support covers x86 and 32-bit ARM, not arm64. The check is
  emitted in IR with an assumed size; LLVM's report of each function's final frame size is then checked
  against it, and the build fails (or re-emits with the reported size) when a frame exceeds its check. No
  size is ever trusted unverified. The report: prologue/epilogue insertion emits an analysis remark per
  function (`prologepilog`, `StackSize`, "N stack bytes in function"), delivered to the diagnostic handler
  of the LLVM context compiling it, so it works for Mach-O and for modules compiled in parallel; the remark
  is enabled once with `-pass-remarks-analysis=prologepilog` through `LLVMParseCommandLineOptions`. (The
  `.stack_sizes` section is ELF-only; `-stack-usage-file` writes one file per process.) A function with a
  variable-sized stack allocation has no fixed frame; Nomu emits none, and the verification rejects one.
  Rejected: extending LLVM's AArch64 prologue lowering (exact, but a patched LLVM to maintain), and LLVM's
  stack probes (they touch pages below the stack, needing a guard page and page-granular stacks).
- **The limit: in the fiber record; how the check reaches it is measured.** Two candidates:
  - **A reserved register holding the current fiber** (x28; AArch64 allows reserving x20–x28, and Go uses
    x28 for its goroutine). The check is one load, a compare and a branch. The register holds the fiber,
    not the carrier record, because a fiber resumes on whichever carrier picks it; the context switch saves
    and restores it with the other callee-saved registers (`Runtime.fiberInit` seeds a new fiber's with the
    fiber itself), and libc preserves it. It also serves the runtime's other reads of the current fiber.
    Its cost: one fewer callee-saved register for every function, so more spills where registers run short.
  - **The carrier-local slot** (on darwin a read of `tpidrro_el0`, a mask, an index by the slot key, then
    the slot and the fiber's limit: two dependent loads per function entry). No register is taken.

  Both are cheap to build (the first is an LLVM target feature, `+reserve-x28`, and a seeded register); the
  choice is made on the compute benchmarks and the switch benchmarks. Rejected: the limit itself in a
  register (no load, but another thread cannot change it, which the next point needs).
- **Preemption shares it** ([236](236-fiber-preemption.md)). The runtime sets a running fiber's limit to a
  value no stack pointer passes, so its next check enters the runtime, which sees a preemption request
  instead of a short stack, as Go's stack check does.
- **Every function is checked at first,** except the runtime's own code (below). The cost is measured
  against 104.1's baseline; skipping checks by inference is [238](238-stack-check-elision.md), a measured
  optimization on top.

## Open design

- **Moving a stack.** Every pointer into the stack is fixed when it moves: frame pointers, and pointers to
  objects Nomu placed in frames, wherever they sit (slots, registers saved in frames). The stack maps must
  describe these, beyond the GC pointers they describe today. Escape analysis must guarantee no pointer into
  a frame lives outside its fiber's stack, as Go's does.
  **Gated on [194](194-gc-frame-metadata.md).** On stock LLVM this cannot be done soundly: statepoints
  record only `addrspace(1)` values, and raw frame addresses (stack-promoted objects, struct-return and
  by-reference slots, frame addresses LLVM keeps in callee-saved registers) are live across calls. 194's
  replacement for statepoints carries the contract copying needs; if no route meets it, the fallback is
  segmented stacks (gccgo's and gollvm's choice), which never move.
- **The runtime's own code.** Runtime-subset functions hold raw addresses the stack maps do not describe, so
  a stack must not move under them: they run where a stack cannot grow (no checks, a fixed reserve), or on
  the carrier's stack (Go's `systemstack`).
- **Calls into libc.** Nomu has no C of its own, but compiled code and the runtime call libc on fiber stacks:
  memory (`memcpy`, `memset`, `posix_memalign`, `free`, `mmap`), I/O and formatting (`write`, `read`,
  `snprintf` for a `Double`, `strtod`), time and futexes (`clock_gettime_nsec_np`, `mach_absolute_time`,
  `__ulock_wait`/`__ulock_wake`). Rule: **no stack bound is ever declared for code Nomu does not own.**
  libc's stack use differs by platform (libSystem, glibc, musl) and version, and with its inputs, so a
  declared bound is a guess, and a wrong guess is a silent overflow. Each libc call either runs on the
  carrier's stack (a stack-pointer swap around the call, as Go's `libcCall` does for every libc call on
  macOS), or is replaced by Nomu's own implementation, which is checked like any Nomu function. The
  hot leaf calls are the candidates to own: `memcpy`/`memset` beyond what LLVM inlines, and the clock
  (`mach_absolute_time` reads a counter Nomu can read directly). FFI, later, uses the same stack switch.
- **Shrinking.** At collections, a stack using under a quarter of its size is copied to one half the size.
- **The limit.** A maximum stack size per fiber; past it, a fatal error through the runtime's fatal path,
  which [219](219-runtime-fault-handling.md)'s handler reports.

## Work

- **104.1** Baseline: a ping-pong benchmark (two fibers, and two actors) against Go's goroutines and
  channels, with the switch's cost split between the register swap and the scheduler's own work. 104's
  later measurements (the entry check's cost, growth) compare against it. **Done** (results below).
- Further steps are numbered when the open design above is settled; the entry check is decided (above).

## Baseline (104.1)

`tools/pingpong.py` builds and runs the set: `benchmarks/ctx_swap` (two contexts switching directly),
`benchmarks/pingpong_fiber` (two fibers through the scheduler's lock-coupled park and its unpark, built with
the runtime prelude), `benchmarks/pingpong_actor` (two actors sending a counter back and forth), and a
Go program kept outside the repository (unbuffered channels, a buffered channel per goroutine as a mailbox,
and `runtime.Gosched` in turn; the script runs it from the gitignored `practice/go/pingpong` when present).
Apple Silicon, 12 performance cores; best of 3; ns per hop (`ctx_swap`: per
round trip of two switches); columns are carriers, or `GOMAXPROCS` for Go:

| benchmark | 1 | 2 | 4 |
|---|---|---|---|
| ctx_swap | 11.9 | 11.9 | 11.9 |
| pingpong_fiber | 116.5 | 194.4 | 416.2 |
| pingpong_actor | 20.4 | 288.3 | 809.7 |
| go chan | 83.0 | 94.7 | 109.5 |
| go mailbox | 84.0 | 95.6 | 109.1 |
| go gosched | 41.6 | 118.0 | 122.3 |

**The split, on one carrier.** A fiber hop is two switches (fiber to carrier, carrier to fiber), the same
shape as Go's `gopark` and `schedule`. Of its 116 ns:

- **Register swap:** 12 ns (6 ns a switch).
- **Lock, run queue and state:** about 5 ns (a lock and unlock pair alone is 2.3 ns).
- **The wake:** about 99 ns. Every unpark calls `rtSchedWake`, which makes a `futexWake` system call
  whether or not a carrier is asleep. The same benchmark without it runs at 17 ns a hop, under Go's 42 ns
  `Gosched` hop and 83 ns channel hop.

**Findings.**

- **Unconditional wakes dominate a switch.** Go wakes another processor only when one is idle and none is
  already spinning (`wakep`); Nomu's unpark, spawn, join completion and actor dispatch all wake
  unconditionally.
- **More carriers make a ping-pong slower.** Nomu goes from 116 ns to 416 ns at four carriers, Go from
  83 ns to 110 ns. Each wake sends an idle carrier (538 ns a wake) to find the work already taken by the
  carrier that parked; with the wake removed a hop is 17 ns at every carrier count.
- **Two actors on one carrier never switch.** The mailbox fiber that drains one actor pops the other's
  mailbox next, so a hop is a send and a handler run (20 ns, a quarter of Go's channel hop). Across
  carriers the hop takes a wake, as above (810 ns at four; 21 ns with the dispatch's wake removed).
- **The mailbox pool grows to its cap.** Each send that schedules a mailbox, finding no free mailbox fiber,
  makes a new one, so two actors in ping-pong leave all 64 fibers (8 MiB of stacks) allocated while one
  does the work.
- **The register swap is cheap.** At 6 ns a switch, the stack strategy's entry check, paid on every call,
  is the cost to watch.
- **Spawning is slow.** `forkjoin_fiber` (a binary tree of 8,190 spawned and joined fibers, from 234.3)
  costs 4.5–6 µs a fiber under every scheduler setting, against a few hundred ns for a goroutine. Each
  spawn allocates a 128 KiB stack and a fiber record; small stacks should cut it most, and it is the
  figure to compare against after.

The wake and the pool's growth are defined as [234](234-scheduler-wake-and-pool.md), which also rules out
the single lock for these workloads (with the wake removed, a hop is 17 ns at every carrier count). The
register swap and the one-carrier hop without the wake are the figures 104's later steps compare against.

## Dependencies & triggers

- **Trigger:** the first collector measurement (above), ahead of the dynamic spawn group
  ([103](103-dynamic-spawn-group.md)), which the earlier plan tied the build to.
- **Reports through:** [219](219-runtime-fault-handling.md)'s fault handler for faults, and the runtime's
  fatal path for a stack past its limit. Growth never involves the fault handler, which prints and dies once
  (`SA_RESETHAND`).
- **Shares the entry check with:** [236](236-fiber-preemption.md) (preemption), which wants a poll at function
  entry; one check can serve a stack that must grow and a fiber asked to stop, as Go's stack check does.
- **Couples with:** [TCO](129-tail-call-optimization.md) (lowers stack depth), GC statepoints and the
  parked-fiber scan (the stack maps a move reuses), escape analysis (pointers into frames), the dynamic
  spawn group.

## Refs

`runtime.md` §6 (safepoints, parked-fiber scan, mutator); [103 dynamic spawn group](103-dynamic-spawn-group.md);
`rtSchedFiberNew` (`src/stdlib/runtime/scheduler.nomu`); [219 runtime fault handling](219-runtime-fault-handling.md).
