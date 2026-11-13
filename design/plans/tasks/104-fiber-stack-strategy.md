# Fiber stack strategy: growth, overflow, high-fiber-count throughput

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design`
(runtime + compiler architecture) · **Size:** L · **Status:** done — Go-style copying stacks: an entry check through x28 against a 1,152-byte reserve, 2 KiB starting stacks that grow by copying and shrink at major collections, libc on the carrier's stack (104.1–104.4); 104.5 made growth 2.5 to 3 times faster than Go's, a spawn as cheap as Go's on one carrier, and memory routines up to 42% faster. Policies left at their defaults went to [258](258-runtime-policy-tuning.md), libc-or-own choices to [259](259-libc-or-own-per-routine.md), the scheduler gaps 104.5 found to [254](254-scheduler-performance.md) · **Source:** deferred.md

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

Every non-runtime function checks on entry that its fiber's stack pointer is above a reserve of G bytes at
the stack's low end, and calls into the runtime to grow when it is inside it.

- **Where the check runs: in IR, after the prologue, against a reserve.** IR runs after the prologue has
  reserved the frame (moved SP down by the frame size), and LLVM may write into the frame (saved registers,
  spilled arguments) before any IR check. The reserve makes that safe: a running function has passed its
  check, so its SP is at least `lo + G`, and a callee whose frame is at most G lands at or above `lo` before
  its own check. The check is `sp < lo + G`, with no frame size in it. Its slow path is an ordinary call,
  so the arguments live across it are recorded like any value at a stop, and the stack never moves with
  arguments in registers (the contract's R8 does not arise).
- **Every frame fits the reserve, verified after code generation.** Each function's frame, plus the slow
  path's own stack use, must be at most G. LLVM's report of each function's final frame size is checked
  against it, and the build fails naming the function when one exceeds it. If real code exceeds G, such a
  function is split: a wrapper with a small frame passes the normal check, then checks `sp - F` against
  `lo + G` for the inner function's size F and calls it unchecked. Unchecked code (the runtime's own, and
  238's exempted calls) must fit along its whole call chain, which the same sizes and the call graph bound.
  The report: prologue/epilogue insertion emits an analysis remark per function (`prologepilog`,
  `StackSize`, "N stack bytes in function"), delivered to the diagnostic handler of the LLVM context
  compiling it, so it works for Mach-O and for modules compiled in parallel; the remark is enabled once
  with `-pass-remarks-analysis=prologepilog` through `LLVMParseCommandLineOptions`. (The `.stack_sizes`
  section is ELF-only; `-stack-usage-file` writes one file per process.) A function with a variable-sized
  stack allocation has no fixed frame; Nomu emits none, and the verification rejects one.
- **Considered:**
  - A check in the prologue, before the frame is reserved (Go's): exact and needs no reserve, through a
    patched LLVM or a Nomu machine pass after prologue insertion (as K2 is added). The stack then moves with
    arguments in registers, which needs their kinds from 247's table (R8). A later option once 247 exists.
  - An IR check with an assumed frame size: the frame is already reserved and possibly written when the
    check runs, so an overflowing frame writes past the stack first.
  - LLVM's split-stack prologue (x86 and 32-bit ARM only, segmented) and its stack probes (they touch pages
    below the stack, needing a guard page and page-granular stacks).
- **The limit: in the fiber record, reached through x28,** which holds the running fiber in all Nomu code
  (LLVM's `+reserve-x28`; Go uses x28 for its goroutine). The check is a load, a compare and a branch. The
  register holds the fiber, not the carrier record, because a fiber resumes on whichever carrier picks it;
  the context switch saves and restores it with the other callee-saved registers, the scheduler seeds each
  of its fibers' with the fiber itself, and libc preserves it. Chosen over the carrier-local slot (a read
  of `tpidrro_el0`, a mask, the slot key, the slot, then the limit: three dependent loads), which 104.2.5
  measured at 40% on recursive `fib`. Rejected: the limit itself in a register (no load, but another
  thread cannot change it, which the next point needs).
- **Placed before the function's first call, after optimization.** The reserve holds the function's own
  frame, so the check only has to precede what the function calls: it goes at the nearest common
  dominator of its calls, moved out of loops, and a function that calls nothing has none. Codegen emits a
  placeholder at entry; the copies inlining makes are deleted right after inlining, and the pass
  `nomu-expand-stack-checks` places and expands each function's own after optimization
  (`src/llvmpasses/StackChecks.cpp`). The slow path uses `preserve_most`, so callers keep their values in
  registers across it.
- **Preemption shares it** ([236](236-fiber-preemption.md)). The runtime sets a running fiber's limit to a
  value no stack pointer passes, so its next check enters the runtime, which sees a preemption request
  instead of a short stack, as Go's stack check does.
- **Every function that calls something is checked,** except the runtime's own code (below). Skipping more
  checks by inference (a bounded call tree under one check) is [238](238-stack-check-elision.md), a
  measured optimization on top.

## Open design

- **Moving a stack.** Every pointer into the stack is fixed when it moves: frame pointers, and pointers to
  objects Nomu placed in frames, wherever they sit (slots, registers saved in frames). The stack maps must
  describe these, beyond the GC pointers they describe today. Escape analysis must guarantee no pointer into
  a frame lives outside its fiber's stack, as Go's does.
  **Settled by [194](194-gc-frame-metadata.md):** extended statepoints. Possibly-stack pointers are
  tracked values recorded at each stop, K2 recomputes frame addresses after each stop, and the copier
  (`runtime/stackmove.nomu`) fixes every recorded word in the old stack's range. The full suite passes with
  the stack moved at every resume (243, claim 4). Segmented stacks stay the fallback.
- **The runtime's own code.** Runtime-subset functions hold raw addresses the stack maps do not describe, so
  a stack must not move under them: they run where a stack cannot grow (no checks, a fixed reserve), or on
  the carrier's stack (Go's `systemstack`).
- **Calls into libc.** Nomu has no C of its own, but compiled code and the runtime call libc on fiber stacks:
  memory (`memcpy`, `memset`, `posix_memalign`, `free`, `mmap`), I/O and formatting (`write`, `read`,
  `snprintf` for a `Double`, `strtod`), time and futexes (`clock_gettime_nsec_np`, `mach_absolute_time`,
  `__ulock_wait`/`__ulock_wake`). Rule: **no stack bound is ever declared for code Nomu does not own.**
  libc's stack use differs by platform (libSystem, glibc, musl) and version, and with its inputs, so a
  declared bound is a guess, and a wrong guess is a silent overflow. Every OS and libc call goes through
  one runtime module, the platform layer (104.3.3), which runs the libc ones on the carrier's stack (a
  stack-pointer swap around the call, as Go's `libcCall` does for every libc call on macOS). Code Nomu
  owns is checked like any Nomu function and needs no switch. FFI, later, uses the same stack switch.
- **Libc or Nomu's own, per routine: decided by performance.** The priorities are performance, then binary
  size, then ease of deployment. Per routine and per platform, the faster implementation on common
  workloads wins whenever the gain is real, however small (a 2% gain outweighs binary size), measured on
  workloads (the `benchmarks/` set plus string and number-formatting cases), not isolated calls. Real
  means reproducible beyond run-to-run noise: single runs vary by about ±4%, so small gaps are measured
  with interleaved runs and enough repetitions to separate them. Only when no gain can be shown does the
  smaller binary win, then the easier deployment. A larger binary is accepted for performance, past the
  1 MB target if need be. What this is expected to give:
  - *Own:* short memory operations (inlined, specialized for known sizes), number formatting (Ryu-style)
    and parsing (Eisel–Lemire), the clock (a direct counter read), and anything that would otherwise pay
    the stack switch.
  - *Bulk memory* (`memcpy`, `memset`, `memcmp`, `memmove` past a few hundred bytes): libc's advantage is
    its tuned per-CPU routines, which exist as standalone code under permissive licenses (Arm's
    optimized-routines, the source of glibc's arm64 string functions; LLVM's libc). Embedding them gives
    the same speed without libc.
  - *System calls:* the kernel's cost dominates, so they tie. On macOS they must go through libSystem
    (its system-call interface is not stable, which moved Go to libSystem in 1.12); on Linux they can be
    made directly, as Go does, with the clock read through the vDSO. So Linux is expected to need no libc
    for these, which also lets its binaries run in an empty (`scratch`) container
    ([218](218-linux-support.md)).
  - *Linked anyway:* programs still link libc for what Nomu does not replicate, name resolution (DNS)
    first. A portable resolver covers `/etc/resolv.conf` and `/etc/hosts` (Go's pure resolver does), but
    full fidelity with the system's configuration needs its library: NSS modules on Linux
    (`/etc/nsswitch.conf`: LDAP, mDNS, `systemd-resolved`), and on macOS the system resolver with its
    per-interface and VPN scopes (Go uses libSystem's there). Such calls block, so they run on a thread
    of their own, as Go's cgo lookups do. Which lookups use which belongs to the networking work.
- **Shrinking.** At major collections, a stack using under a quarter of its size is copied to one half the
  size (104.4).
- **The limit.** A maximum stack size per fiber; past it, a fatal error through the runtime's fatal path,
  which [219](219-runtime-fault-handling.md)'s handler reports.

## Work

- **104.1** Baseline: a ping-pong benchmark (two fibers, and two actors) against Go's goroutines and
  channels, with the switch's cost split between the register swap and the scheduler's own work. 104's
  later measurements (the entry check's cost, growth) compare against it. **Done** (results below).
- **104.2** The entry check (above), and moving at it. With fixed 128 KiB stacks still, a short stack is
  a fatal error, which already ends silent overflow; growth is 104.3.
  - **104.2.1** The limit: `lo + G` for the running fiber where the check reads it (the carrier record
    first; the reserved register is measured in 104.2.5), set at every switch-in, 0 on threads with no fiber.
    **Done:** after 104.2.5, the fiber record's offset 304 (the record grew to 312 bytes), set by
    `rtStackLimitSet` at creation and after every move; the fiber is in x28. G is `rtStackReserve`, 16 KiB.
    The runtime's globals' initializers prepended into `rt_prelude` tests are runtime subset too, since they
    run before any fiber exists.
  - **104.2.2** The check in codegen, in every non-runtime function, its slow path a statepoint carrying
    the shaped roots live at entry. **Done:** `emitStackCheck` (`LLVMGenRuntime.swift`) emits the
    placeholder in every body that is not runtime code; SP and x28 read with `llvm.read_register`; shaped
    values live into the entry block get homes. The fast path is five instructions with one load.
  - **104.2.3** The slow path: overflow reported through the fatal path; the preemption hook 236 needs;
    a stress mode moving the stack at every check (through the park-and-resume move 243 built).
    **Done, except the preemption hook** (it comes with 236): `nomuSchedStackCheck` reports "stack
    overflow" through `Runtime.fatal`; `NOMU_STACK_MOVE_CHECKS=N` (run setting `stack_move_checks`) sets
    the limit so every check takes the slow path and moves the stack at every Nth, through a new fiber
    state 5 the carrier loop handles like a stop. An SP outside the running fiber's stack (a white-box
    test's own fibers) is left alone. Suite: case `stack-overflow`, group `stack-move-checks` (N=1); the
    full suite passes at N=3 and N=7, and N=1 over the `shape`, `stack-move` and `string-eq-moving` runs
    (the full suite at N=1 exceeds the deadline: each move costs two `mprotect` calls).
  - **104.2.4** Frame-size verification from LLVM's remarks: every frame within G, the build failing
    otherwise; the largest frames in the suite and benchmarks measured. **Done**, through LLVM's
    `warn-stack-size` attribute in place of the remark: each checked function carries it at the frame
    limit (`LLVMGen.stackFrameLimit`, G less 4 KiB for the slow path), and a diagnostic handler on the
    module's context turns LLVM's warning into a build error naming the function (checked by hand: a
    4,500-field struct live across a call gives a 27,408-byte frame and fails; too slow to compile for a
    suite case). The runtime package is unchecked as a whole, its startup-global initializers included.
    `NOMU_FRAME_SIZES=1` reports every frame and direct call; `tools/frame-depth.py` reads it. Over every
    example and benchmark, debug and release (188 builds): the largest checked frame is 528 bytes
    (`binary_tree`, debug); the deepest unchecked chain below a checked frame is 352 bytes (the allocation
    slow path into `rtImmixRefill`); the check's slow path uses about 130 bytes before it leaves the stack;
    no cycle among unchecked functions. Unmeasured: libc called on fiber stacks, `printf` (from `print`)
    the largest, a few KiB. So G stays 16 KiB while libc runs on fiber stacks (none does after 104.3.4); once 104.3 moves those calls
    to the carrier's stack, the numbers above allow a G of about 1–2 KiB.
  - **104.2.5** The cost, against 104.1 and the compute benchmarks; the carrier record against a
    reserved register for reaching the limit. **Done.** `measure.no_stack_checks` (config
    `measure_no_stack_checks`, `tools/frames-ceiling.py --configs no-stack-checks`) removes the check.
    Change without the check, median of 11, release, one carrier (noise about ±4%):

    | workload | carrier record | x28 | x28, before calls, inlined copies removed |
    |---|---|---|---|
    | `frames_fib` | −40.4% | −33.5% | −2.9% |
    | `frames_tree` | −16.7% | −8.4% | −1.7% |
    | `binary_tree` | −10.2% | −4.7% | +0.6% |
    | `frames_mutating` | −41.3% | −39.2% | −35.6% |
    | `micro_dispatch` | −4.3% | +0.7% | −3.0% |
    | `pingpong_fiber`, `pingpong_actor`, `frames_loops`, `frames_strings`, `micro_carried` | within noise | within noise | within noise |

    Three costs, in order: the carrier-local slot's dependent loads (x28 removes them); inlined copies of
    callees' checks, which sat in callers' loops (6 in one module initializer); and the check's place at
    entry, which put the prologue on paths that call nothing. What remains is `frames_mutating`: in its
    `mix`, four of seven calls are leaves, and the register allocator copies an argument into a
    callee-saved register before the branch, keeping the prologue on the leaf path (104.2.6). Go's check
    at entry pays the same on such leaves.
  - **104.2.6** The leaf path keeps the prologue in some functions (`frames_mutating`, 512 ms against
    317 ms without the check). Candidates: pass the argument registers through the slow path (Go's
    `morestack` keeps them; tracked pointers cannot, since a collection there would leave the returned copy
    stale); duplicate the entry so the leaf path's code has no check region; or accept parity with Go.
    **Accepted** at parity with Go, whose check at entry pays the same on such leaves; the two other
    candidates moved to [238](238-stack-check-elision.md), with the rest of the check's cost.
- **104.3** The copier in production: fibers start small and grow by copying (`rtStackMove` from 243,
  today a stress mode), the limit, the runtime's own code and libc calls kept off growable stacks (above).
  Small stacks are the default since 104.3.7; `NOMU_STACK_START` still sets the starting size.
  - **104.3.1** Growth at the check: the slow path moves a short stack to one twice its size and frees the
    old one; past the maximum size, the fatal error. The starting size a setting.
    **Done:** the fiber record's offset 312 holds its stack size (the record is 320 bytes). A check inside
    the reserve stops the fiber in state 5, as the stress mode does, and the carrier's `rtStackMove` doubles
    the size until the used part leaves the reserve free, keeping the used part's distance from the top.
    Past the maximum (`NOMU_STACK_MAX`, default 1 GiB) the check is the fatal error "a fiber's stack
    reached its maximum size". The starting size is `NOMU_STACK_START` (default 128 KiB, at least 32 KiB);
    the suite settings `stack_start` and `stack_max` carry both. Under the stress modes, quarantined stacks
    keep their sizes and are reused only at the same size; `NOMU_STACK_MOVE_CHECKS` moves only stacks using
    under 64 KiB, since moving deep recursion every Nth call costs the square of its depth. Tests: the
    `stack-growth` case (four fibers recursing to 300,000 frames from 32 KiB, holding objects) and
    `stack-overflow` (to a 1 MiB maximum). The suite passes plain, at `stack_move=1`, at
    `stack_move_checks=7`, and with every fiber at 32 KiB (995/995 each). At `stack_move_checks=1` and `=3`,
    `globals-startup` and `string-surface` crash, from 104.3.2's class: since 104.2.5 the check runs before
    the first call, after a function may have taken a short string's inline-byte address in its frame (the
    select 246 describes), and `preserve_most` keeps that address in a scratch register across the slow
    path; a move there leaves it stale. At entry no such address existed yet.
  - **104.3.2** Raw pointers into the stack held across a stop: [246](246-raw-pointers-into-managed-memory.md).2,
    decided (d), lands before stacks move in production. Reachable at the stack check (104.3.1): in
    `trace` of `globals_startup`, `print`'s byte address is taken before the check and used by `printf` after.
    **Done:** such pointers are recorded with their base (246.2 has the details); the suite passes at
    `stack_move_checks=3`, which crashed on them.
  - **104.3.3** The platform layer: every OS and libc call the runtime and generated code make goes through
    one runtime module, which runs the libc ones on the carrier's stack (above, calls into libc). Each
    routine's implementation, libc or Nomu's own, is then a choice inside the layer, made by the rule above.
    **Done:**
    - **The stubs.** Each libc function codegen calls (39 of them: I/O, formatting, memory allocation,
      time, futexes, threads, signals) has a stub `_nomu_libc_<name>` in the asm floor
      (`rtasm_arm64.s`), and codegen's `buildCall` sends every call to one of them
      (`LLVMGen.libcViaCarrier`, which must match the stubs). On a fiber's stack (x28 a fiber, SP inside
      its stack) the stub moves SP to 256 bytes below the SP its carrier saved when it switched into the
      fiber, leaves a frame record chained to the fiber's, calls the function, and switches back; anywhere
      else it branches straight to the function. A variadic function's stub also copies the caller's
      outgoing argument area (64 bytes), where Darwin passes variadic arguments. Every stub call is
      gc-leaf: libc never calls back into Nomu.
    - **x28 off fibers.** Generated `main` clears x28 on the main thread, and every thread Nomu creates
      starts in `rtThreadStart` (asm), which clears it, so code off any fiber reads 0 there.
    - **Left on fiber stacks:** the memory routines, which 104.3.4 made Nomu's own. (`rtThreadStart`'s
      `free` runs on a thread's own stack.)
    - **Cost.** `measure.libc_direct` (config `measure_libc_direct`, also a `tools/frames-ceiling.py`
      config) calls libc directly, for comparison. A first version, one shared trampoline taking the
      function as an argument, cost 4.2% on `benchmarks/print_loop` (six million `printf` calls), 3.5% of
      it the trampoline's one indirect branch, whose target changes between calls; the per-function stubs
      cost 1.4% (about 0.7 ns a call). Against direct calls: `pingpong_fiber`, `forkjoin_fiber`,
      `sleepers_fiber`, `fanout_actor`, `pipeline_actor`, `mixed_fiber`, `producer_fiber`, `alloc_live`,
      `micro_alloc` and `frames_strings` within noise. What remains on printing goes with owning number
      formatting ([227](227-double-formatting-in-nomu.md)).
    - **Tests.** The suite passes plain, at `stack_move=1`, `stack_move_checks=3` and with 32 KiB stacks
      (995/995 each). A fatal error on a fiber now aborts on its carrier's stack.
  - **104.3.4** The memory routines LLVM emits (`memcpy`, `memmove`, `memset`, `memcmp`): LLVM calls them
    directly for large, variable-size and aggregate copies, after Nomu's codegen, so the layer cannot
    wrap them. Nomu defines the symbols, so every call binds to its version: small sizes done inline,
    large ones either through embedded tuned routines or by switching stacks and calling libc, as
    104.5 measures.
    **Done:** the asm floor defines `memcpy` (also `memmove`), `memset`, `bzero` and `memcmp`, and a
    binary's own references bind to them, LLVM's included (a local definition wins over libSystem's;
    libSystem's internal calls keep its own). Up to 128 bytes for copies and fills, 16 for compares, they
    run in straight-line code with overlapping loads and stores and no stack; the copy loads everything
    before it stores, so overlapping copies are correct. Larger sizes switch stacks and call libSystem's
    tuned routines (`_platform_memmove`, `_platform_memset`, `_platform_memcmp`). With this, no libc code
    runs on a fiber's stack. Against libSystem's routines called directly: `benchmarks/mem_routines`
    (string concatenation and equality at 16 to 140 bytes, and 64 KiB copies) 6.4–7.1% faster over three
    runs; `frames_strings`, `binary_tree`, `alloc_live`, `micro_alloc`, `gc_footprint`, `gc_barrier`,
    `frames_tree`, `micro_carried`, `forkjoin_fiber`, `fanout_actor` and `print_loop` within noise. Test:
    `memory-routines` (debug and release), every size to 300 at each alignment, larger sizes, overlapping
    copies both ways, with the bytes around each destination checked. The suite passes plain, at
    `stack_move=1`, `stack_move_checks=3` and with 32 KiB stacks (997/997 each).
  - **104.3.5** The runtime's unchecked call chains verified against the reserve by the build, failing it
    when one exceeds it (104.2.4 measured them with `tools/frame-depth.py`).
    **Done:**
    - **The tables.** Code generation writes each module's frame table beside its object
      (`<stem>.frames`, `src/llvmgen/FrameTable.swift`), cached with it: every defined function's frame
      size (LLVM reports each, through `warn-stack-size` 0 on every function), whether it checks its stack,
      its direct callees, whether it calls through a pointer, and the functions whose address the module
      takes. Functions whose address `Runtime.ofFunc` takes are entries (thread, fiber and signal-handler
      starts), at the base of a stack.
    - **The check.** The link merges the tables of every object it links and fails the build
      (`checkFrameTables`, `Link.swift`) when, below any checked function, a chain of unchecked frames
      exceeds the reserve (16 KiB; a checked callee counts its frame and the slow path), when the slow
      path exceeds what a checked frame leaves it (4 KiB), when unchecked code reached from checked code
      recurses, or when it calls a function of unknown stack use (the asm floor's context switch, fiber
      setup and memory routines, and the libc stubs, are known to use none of the fiber's stack). An
      indirect call counts as a call to every address-taken function that is not an entry. A white-box
      test compiled against the runtime prelude (`test.runtime_prelude`) is not checked: its checked code
      calls the collector's internals, which recurse over nested shapes and run off fiber stacks in a
      program.
    - **What it measures today:** the deepest chain 336 bytes (allocation's slow path into the heap's
      refill), the slow path 128 bytes, the largest checked frame 240 bytes in the growth fixture;
      `tools/frame-depth.py` reads the tables.
    - **Tests.** `//src/driver:frame_table_tests` (chains within and over the reserve, a checked callee's
      frame and slow path, the slow path's limit, recursion reached and unreached, unknown callees,
      indirect calls with and without entries, the text form, the link's reading). The suite passes
      (997/997), the driver's tests pass, and builds stay reproducible (`--check-reproducible`).
  - **104.3.6** Nothing outside a fiber points into its stack: an audit of the scheduler's wait records,
    timers, channel and actor waiters, and other fibers, against escape analysis's guarantee.
    **Done:** nothing outside a fiber holds an address into its stack, apart from the records the copier
    fixes. What can hold one, and why each is safe:
    - **The runtime's own records:** the saved context (SP, FP), the anchor (`anchor-sp`) and the
      shadow-stack list, all fixed by `rtStackMove`. Runtime code that keeps an anchor across a park keeps
      it as an offset from the stack top (`rtAnchorOffset`). The carrier's context and the libc stubs'
      frames are on the carrier's stack.
    - **Waiting:** timer entries and joiners hold fiber records (heap); every futex address is a field of
      the scheduler or collector records; the stdin poller's state and kqueue buffers are heap; the
      runtime has no channels.
    - **The collector:** root slots are collected with the world stopped, and a move happens only on a
      carrier in runtime code, which a stop waits for, so no slot list spans a move. The write barrier
      records objects, and only inside the Immix heap's range (its heap-range guard), which no fiber
      stack can share, so a stack-placed object passed to a callee that stores into it is never
      remembered.
    - **The compiler:** an object is stack-placed only when it does not escape (I4, `ssair.md`): returned,
      stored, boxed, captured, sent or spawned is escaping, and a call argument stays local only when the
      callee is shown not to leak it, and every callee runs on the same fiber. Actors are never
      stack-placed; spawn environments are heap; actor messages copy their arguments, so a reference sent
      is escaping. Frame addresses passed down (a `mutating` receiver, an erased buffer, a struct return)
      reach only callees on the same fiber and are tracked (243, 246.2).
    - **Evidence:** the suite passes with every resume moving the stack (`stack_move=1`) and with moves at
      every stack check (`stack_move_checks=1`), with each moved-from stack made inaccessible, so a stale
      address into one faults.
  - **104.3.7** A suite leg with every fiber at the smallest starting size, so every program grows for real.
    **Done** as the default instead of a leg: every fiber now starts at the minimum (`rtStackStart`
    defaults to `rtStackMin`, 2 KiB since 104.3.8), so every suite run grows stacks for real; the first
    fiber, `main`'s, starts at 64 KiB (`rtStackMain`), saving the copies a deep `main` would make. Found
    on the way: a completed fiber's stack was never freed, so a program holding no live fibers kept every
    stack it had ever made (`idle_fiber`, 2,800 fibers over its run: 355 MiB at 128 KiB stacks). The
    carrier now frees it when the fiber finishes (`rtStackFree`; a retired, inaccessible stack under the
    stress modes). Against the old 128 KiB default: `forkjoin_fiber` 45% faster (45 ms against 81),
    `sleepers_fiber` 20%, `idle_fiber` and `mixed_fiber` 1–3%, `fanout_actor`, `pipeline_actor`,
    `pingpong_fiber`, `binary_tree`, `frames_fib`, `frames_tree` within noise; `idle_fiber` holds 3.9 MiB
    (91 MiB before the free). The suite passes plain, at `stack_move=1` and at `stack_move_checks=3`
    (997/997 each).
  - **104.3.8** Go-size stacks: a 2 KiB minimum, which beating Go on highly concurrent workloads needs (a
    million parked fibers at 2 KiB is 2 GB of stack; at 32 KiB, 32 GB). The minimum is twice the reserve,
    so the reserve drops from 16 KiB to about 1 KiB, now that no libc code runs on fiber stacks and the
    link checks every unchecked chain (the deepest 336 bytes, the slow path 128). Checked frames are then
    limited to about 768 bytes (the largest measured, 528). A function with a larger frame gets a wrapper:
    a small checked frame that checks `sp − F` for the function's frame F and calls it; F is known only
    after code generation, so a module holding such a function compiles a second time with the wrapper,
    and the link's check counts the wrapper's check as covering the body. Considered: a check before the
    prologue in a machine pass, Go's (exact for any frame, but the stack then moves with arguments in
    registers, which needs [247](247-frame-table.md)'s table; the later replacement); keeping a 16 KiB
    reserve and a 32 KiB minimum (rejected: 16 times Go's footprint). Stacks stay page-sized under the
    stress modes, which protect them.
    **Done:**
    - **The reserve** is 1152 bytes (`rtStackReserve`, `FrameTable.stackReserve`), a checked frame at most
      768 bytes (`FrameTable.frameLimit`), leaving the slow path 384, which holds the 224 bytes the context
      switch pushes ([250](250-fiber-task-surface.md) 250.8.2; 1 KiB and 256 before); every fiber starts at 2 KiB
      (`rtStackMin`; 16 KiB under the stress modes), `main`'s at 64 KiB.
    - **Large frames.** `emitObject` compiles a module; when a checked function's frame comes out over
      the limit, it compiles it again with each such function split (`nomuSplitLargeFrame`,
      `src/llvmpasses/StackChecks.cpp`): the code moves to a hidden, unchecked, never-inlined body
      `<name>.frame`, and the function becomes a wrapper with the same signature, never inlined, whose
      check also asks for the body's frame plus 256 bytes (`!nomu.stack.need`) below its SP. A body whose
      frame comes out larger than asked compiles once more (at most three attempts, stopping early when no
      frame asks for more). Arguments the body
      marks as frame addresses are marked in the wrapper too. The wrapper's check records no shaped
      arguments, sound while the slow path cannot collect (preemption, 236, must add them).
    - **The slow path** takes the room asked for (`__nomu_stack_slow(need)`, `nomuSchedStackCheck`), kept in
      the fiber record (offset 320, the record now 328 bytes) for the move, which grows the stack to hold
      it and the reserve below the used part.
    - **The link's check** treats a body as covered by its wrapper (`w` in the frame table): its frame must
      fit what the wrapper asked for, and its callees the reserve below it, as a checked function's do.
    - **Found and fixed: a marker the optimizer moved.** `nomu.frame.addr` and `nomu.raw.interior` have no
      memory effects, so the optimizer may sink one past calls to its first use; the tracking pass then
      made the tracked value there, leaving the untracked operand live across those calls. In release, a
      `mutating` method kept `self` in a callee-saved register across a call that moved the stack, and
      wrote through the stale address (`large-frame-release-moving`). The tracking pass now makes the
      tracked value right after its operand's definition (the entry, for an argument).
    - **Results.** Against 32 KiB starting stacks: `forkjoin_fiber` 33% faster, `sleepers_fiber` 6%, the
      rest (`idle_fiber`, `mixed_fiber`, `fanout_actor`, `pipeline_actor`, `pingpong_fiber`, `binary_tree`,
      `frames_fib`, `frames_tree`) within noise. `sleepers_fiber` (1,024 parked fibers) holds 7.3 MiB, against
      67.5 MiB at 32 KiB and 260 MiB at the former 128 KiB.
    - **Tests.** `large-frame` (two 4.7 KiB frames split, recursion 400 deep on several fibers from
      2 KiB) and `large-frame-release-moving`; frame-table unit tests for covered bodies. The suite passes
      plain, at `stack_move=1`, `stack_move_checks=3` and `=1` (999/999 each).
  - **104.3.9** A completed fiber's record (328 bytes) is never freed. Records are freed at fiber exit under
    the detached model, which [250](250-fiber-task-surface.md) 250.1–250.4 builds; removing `fiber let` there
    also fixes the crash on a `fiber let` in an untaken branch, which joins an uninitialized handle at
    function exit. The carrier clears its current-fiber word when a fiber returns, since another carrier may
    free the record. **Done** with 250.4: every fiber's record is freed when it ends, except `main`'s.
  - **104.3.10** The fastbuild compiler (LLVM with assertions) aborts compiling the runtime in `-c release`:
    "Odd number of callee-saved regs to spill!" in `rtImmixRefill`. With `+reserve-x28`, LLVM pairs x27 with
    x28 for Mach-O's compact unwind, then drops x28 as user-reserved, leaving x27 alone; any function using
    x19–x27 trips it. Release LLVM saves x27 singly and the compact unwind falls back to DWARF, so `-c opt`
    builds work. The runtime is compiled optimized in every configuration, so any fastbuild-compiler build that compiles it afresh aborts; `build_tests` fail whenever they compile the runtime afresh (`testVerifyCache`, `testVerifyCacheCoversLinks`, `testConcurrentWorkspacesShareOneCache`) and pass when a cached runtime serves them.
    Options: patch LLVM's pairing to skip a user-reserved partner, keep x27 out of allocation as well, or
    take x28's role in a register outside the callee-saved pairs.
    **Decision: generated code stays as it is**, x28 reserved and x27 allocatable, because it is the fastest.
    Release LLVM saves x27 with a single `str` (`rtImmixRefill`: `str x27, [sp, #0x30]`), at most one store
    per prologue. Keeping x27 out of allocation costs a register in every function; moving the fiber pointer
    to a thread-local adds a TLS load to every stack check, and to a caller-saved register adds a restore
    after every libc call and at every entry from C. **Done:** `.bazelrc` builds `AArch64FrameLowering.cpp`
    and `AArch64PrologueEpilogue.cpp` with `-DNDEBUG`, so the fastbuild compiler takes the release path for
    this spill; the rest of LLVM keeps its assertions. Both files, because they share
    `AArch64PrologueEpilogueCommon`, whose members depend on NDEBUG; LLVM's other layout switches follow
    `LLVM_ENABLE_ABI_BREAKING_CHECKS`, which is global. A fastbuild compiler now compiles the runtime afresh
    under `-c release`, and `build_tests` pass. `testConcurrentWorkspacesShareOneCache` then failed
    intermittently on a non-deterministic `std/prelude` object, fixed in
    [207](207-build-determinism.md) 207.7.
  - **104.3.11** A frame addressed through a base pointer breaks when its stack moves. With run-time-sized
    buffers (compiled-once code's values of unknown size) and 256 bytes or more of fixed locals, LLVM addresses
    the locals through x19, set from SP in the prologue. The mover fixes frame pointers and recorded slots but
    not x19, so after a move the function reads its old stack. Found with a two-case `select` in a
    compiled-once generic (`firstOf(a, b)`, two receive cases, under `stack_move=1`; `select_generic` keeps its compiled-once selects to one case until this is fixed); any compiled-once
    function that large that stops while holding such a buffer is exposed, and stack growth moves stacks
    outside the stress mode too. The collector has the same gap: a stack map records such a frame's root
    slots relative to x19, and the walk reads every register other than x29 as SP, so it reads the wrong
    words (a collection while `firstOf` is parked loses the channels its `select` holds). Options: an LLVM patch so these functions address locals from the frame
    pointer, or the mover fixing x19 in the context and in each callee's save slot, which sits at a fixed
    place below the frame record under Darwin's compact unwind layout.
    Decided: the runtime handles these frames, with the facts it needs found after the link. An LLVM patch
    (address the locals from x29) would cost an instruction or two on many accesses in these frames, and a
    per-fiber side stack for run-time-sized values would cost a bump and a reset per use and a second region
    per fiber; this costs nothing outside collections and stack moves.
    - **104.3.11.1** After the link, the driver reads the binary's unwind info and adds a table to the frame
      index: for each function, where it saves x19 (its offset from the frame pointer), and whether it uses a
      base pointer. **Done** (`driver/sources/UnwindFacts.swift`, frame index version 3). The save comes from
      `__unwind_info` (frame mode: x19 at fp−8 with the x19/x20 pair) or, for a function in DWARF mode, from
      its `__eh_frame` FDE (the first save rule, relative to the CFA, the frame record at CFA−16). A base
      pointer is LLVM's `mov x19, sp` in the prologue. The step checks every stack-map slot location: based on
      x19 only in a base-pointer function, and on no register but x19, x29 and SP. The section's size is
      reserved from the objects' compact-unwind entry counts.
    - **104.3.11.2** The collector's walk carries each frame's x19 outward. **Done.** `rtX19AtAnchor` follows
      the frame-pointer chain from the fiber's context to the anchor; `rtWalkFrom` continues frame by frame;
      `rtSlotBase` reads a slot's base, fatal for any register it cannot read.
    - **104.3.11.3** The mover adjusts the saved x19 of each base-pointer frame. **Done**, after the
      frame-pointer chain and before the root slots, which a base-pointer frame records relative to it. The
      frames contract names it (S4, R2a).
    - **104.3.11.4** Tests. **Done.** `select_generic` has its two-case compiled-once `firstOf` back, under
      collections and stack moves; `base-pointer-frame` (`-stack-move`, `-stack-checks`) holds two channels in
      x19-based slots across a park 40 frames down while another fiber churns the heap. With the mover's x19
      fix removed, it faults under `stack_move=1`.
    - **104.3.11.5** Verification. **Done.** Full tier 1420/1420; fast tier 534/534 under `stack_move=1`,
      `stack_move_checks=1` and `=3`; the base-pointer, select, task, channel, scheduler, fiber, actor, stdin,
      STW and module-generic cases 20× each plain and 10× with stacks moving, all passing.
- **104.4** Shrinking at collections (above). **Done** (104.4.1–104.4.5). Counted in functional completeness: without it a fiber that
  once ran deep keeps that memory, against the fiber-density goal. A fiber parked on a channel is held by raw
  addresses into its stack: the channel's queue points at its waiter (in the caller's frame), and the waiter's
  slot, or a `select` waiter's slot, points at its value ([102](102-channels.md) 102.3). The resume move is
  safe, since the waker has finished with them by then; a shrink is not. Decided: fix those addresses. Go
  does the same: it shrinks goroutines parked on channels and adjusts the pointers into the stack under the
  channels' locks (`activeStackChans`, `syncadjustsudogs`), skipping only a goroutine in the middle of parking.
  Skipping would leave the most common parked fiber unshrunk. Nomu shrinks while the world is stopped, so no
  waker runs during the fix.
  - **104.4.1** List every address into a parked fiber's stack held outside it, by wait reason (channel,
    `select`, sleep, `readLine`, `Task` join, actor mailbox, safepoint stop), and confirm no channel lock is
    held while the world is stopped.
    **Done.** 104.3.6's audit predates channels in the runtime; this extends it. By wait reason:
    - **Channel receive, send and `Task` join** (`rtChanPark`): the waiter is in the caller's frame. Its slot
      and shadow link are a node of the fiber's shadow list, which `rtStackMove` already walks and fixes. The
      channel's queue points at it: the queue's head or the previous waiter's `next` (offset 24), and the
      tail. Those are the only addresses 104.4.3 has to fix. The fiber record's wait object (offset 120) is the
      channel's buffer, whose state at +16 holds both queues.
    - **`select`**: its waiters are in a heap record; each is a shadow node whose slot points into the stack,
      fixed by the same walk. Nothing else points in.
    - **Sleep**: the timer holds the fiber record. **`readLine`**: its waiter is on the heap and holds the
      fiber record. **Mailbox fibers** (idle, state 6): the carrier holds the record. **Safepoint and stack-check
      stops** (states 4 and 5): only the runtime's own records, which the mover already fixes (the resume
      and check stress modes move these states today).
    - **Locks**: runtime code compiles with no safepoint polls (`noSafepoint`, the runtime subset), so a fiber
      stops only in user code, and every channel lock is taken and released inside runtime code. The one
      release outside it is the carrier's, right after the switch back (`rtSchedSwitchedBack`), before the
      carrier can take part in a stop. So no channel lock is held while the world is stopped, and the fix-up
      needs none.
  - **104.4.2** Shrinking at collections for fibers with no such addresses: a stack using under a quarter of
    its size moves to one half, through the existing mover. **Done** (`rtStackShrinkAll`, `stackmove.nomu`).
    The GC coordinator runs it after each major collection, with the world stopped, over the fibers the
    collector walks as stopped: ready, parked and stopped at a safepoint. A stack never goes below the
    starting size, and always keeps the reserve below its used part. Majors only: minors are frequent, and
    the pass visits every fiber. The move is `rtStackMoveTo(fib, bytes)`, which the growth path
    (`rtStackMove`) now calls with its doubled size. Suite case `stack-shrink`: three fibers grow, then sleep
    shallow, and come back smaller with their objects intact; `main`, stopped at a safepoint, shrinks too. It
    fails with the pass removed.
  - **104.4.3** The fix-up for channel and `select` waits: after the copy, every address into the old range in
    the channel's queues and the waiters' slots moves by the same delta. The fiber record's wait object (the
    channel's buffer or the `select`'s record) says where to look. **Done.** Slots needed nothing new: every
    waiter, `select`'s included, is a node of the shadow list the mover already fixes. Only the queue links
    to a plain waiter on the stack were left. A fiber parked in a channel operation has that waiter as its
    shadow list's newest node, so the pass knows its old and new address. A first version walked the
    channel's queues once per moved fiber: 10,000 receivers on one channel made each major take 5.6 s. The
    pass now lists every moved waiter first, then walks each listed channel's queues once through a table
    from old to new waiter addresses. Suite case `stack-shrink-chan`: three receivers on one channel (one in
    the middle of the queue), two senders, and a `Task` join. It crashes with the fix-up removed (SIGSEGV;
    SIGBUS with the old stack protected).
  - **104.4.4** A stress mode that shrinks every eligible fiber at every collection; the suite under it.
    **Done.** `NOMU_STACK_SHRINK=1`, run setting `stack_shrink`: every collection, minor or major, moves every
    stopped fiber's stack, halving it where the rules allow and at its size otherwise, with the old stack
    protected as in the other stack-move modes. The fast tier passes 543/543 under it; the two shrink cases
    pass under it combined with `gc_stress_bytes=65536` and with `stack_move=1`. Combined with
    `gc_stress_bytes` across the whole suite, the failures and timeouts are the same set as under
    `gc_stress_bytes` alone (cases that require more collections than the run-wide value gives).
  - **104.4.5** Measures: peak and settled memory on a workload that runs deep and then parks, and the added
    pause. **Done** (`benchmarks/stack_shrink`, `--config=rt_prelude`): 10,000 fibers recurse 1,000 frames,
    then park on one channel's receive. Six majors in a row:

    | Major | Pause | Total stack |
    |---|---|---|
    | before | | 655 MB (64 KiB each) |
    | 1 | 62 ms | 328 MB |
    | 2 | 58 ms | 164 MB |
    | 3 | 45 ms | 82 MB |
    | 4 | 40 ms | 41 MB (4 KiB each) |
    | 5, 6 | 26 ms | 41 MB, nothing left to shrink |

    The same at 1 and 4 carriers. Shrinking adds 14–36 ms to a pause for 10,000 fibers, about 3.6 µs a fiber
    at the largest size: a stack's allocation and free, and the walk of its frames for root slots. Stacks
    pooled per carrier (104.5) cut the first part. The stacks end at 4 KiB, since 2 KiB would leave less than
    the reserve below the used part.
- **104.5** Performance of the stack mechanisms, after 104.4: what a spawn, a growth, a shrink and the
  calls that switch stacks cost, measured on synthetic benchmarks, since a mechanism's cost does not depend on
  the workload. The policies (the growth factor, starting sizes, the shrink threshold) need real programs and
  moved to [258](258-runtime-policy-tuning.md); they keep their current defaults here. Moved elsewhere: check
  elision and 104.2.6's other candidates to [238](238-stack-check-elision.md); the copier reading the frame
  table is part of [247](247-frame-table.md)'s deliverable; number formatting and parsing to
  [227](227-double-formatting-in-nomu.md). The smaller reserve was 104.3.8.
  - **104.5.1** Baseline and counters. Runtime counters for stack growths, bytes copied, and time in moves and
    in the shrink pass, printed at exit under a setting. Two benchmarks with Go counterparts in
    `practice/go`: spawn-heavy (many short fibers, each a little deeper than the starting size) and
    deep-recursion (a few fibers recursing far, growing through every size). With `forkjoin_fiber`,
    `sleepers_fiber` and `stack_shrink`, these are the set the later steps measure against.
    **Done:**
    - **Counters.** `NOMU_STACK_STATS=1` (suite setting `stack_stats`) prints one line to stderr at exit:
      `nomu-stacks: moves= grown= move-bytes= move-ns= shrink-passes= shrunk= shrink-bytes= shrink-ns=`.
      Kept in `rtStackStats`, added to atomically; off, a move pays one branch. Test:
      `stack-stats`.
    - **Benchmarks.** `benchmarks/spawn_grow`: 100,000 fibers per round in waves of 1,000, each recursing
      to a depth (0, 16, 64, 256, 1024) and returning. `benchmarks/deep_recursion`: 4 fibers recursing to
      10,000, 100,000 and 1,000,000. Both recurse through the same non-tail function. Go counterparts:
      `practice/go/stacks` (`spawn`, `deep`).
    - **Results.** Median of 3, M3 Max; `spawn_grow` in ns a fiber, `deep_recursion` in ms; columns are
      carriers, or `GOMAXPROCS`:

      | benchmark | Nomu 1 | Go 1 | Nomu 4 | Go 4 |
      |---|---|---|---|---|
      | spawn_grow, depth 0 | 203 | 130 | 453 | 155 |
      | spawn_grow, depth 16 | 201 | 148 | 460 | 147 |
      | spawn_grow, depth 64 | 1,748 | 1,323 | 3,067 | 388 |
      | spawn_grow, depth 256 | 15,328 | 10,285 | 20,647 | 2,780 |
      | spawn_grow, depth 1024 | 68,857 | 48,060 | 88,638 | 13,302 |
      | deep_recursion, 10,000 | 2.4 | 1.8 | 2.4 | 0.6 |
      | deep_recursion, 100,000 | 18.3 | 14.4 | 17.2 | 4.4 |
      | deep_recursion, 1,000,000 | 144 | 122 | 134 | 35 |

      Counters: `spawn_grow` makes 900,000 moves copying 7.3 GB, 8.0 s of its 8.8 s at one carrier;
      `deep_recursion` 132 moves copying 153 MB, 143 ms of its 145. `stack_shrink`: 50,000 growth moves
      (887 ms), and 40,005 stacks shrunk over six passes copying 38 MB in 87 ms, about 2.2 µs a stack for
      under 1 KiB copied each. `forkjoin_fiber` and `sleepers_fiber` never grow.
    - **Findings.**
      - Growth does not scale with carriers: a move holds the scheduler lock, so moves on different
        carriers run one at a time. Go's growth scales about 3.7 times from 1 to 4. (104.5.2)
      - A move costs about 9 µs for 8 KiB copied, about 40 ns a frame; the copy itself is a small part.
        Go's copier costs about the same per frame (its time at depth 1024 is also mostly copying), so
        this is where beating Go is open. (104.5.3)
      - A spawn with no growth costs 203 ns against Go's 130 at one carrier, 453 against 155 at four.
        Part of it is the stack's `malloc` and `free` (104.5.4); the scheduler's part belongs to
        [254](254-scheduler-performance.md).
  - **104.5.2** Growth off the scheduler lock. A fiber stopped at its check (state 5) is on no channel queue
    and runs on no other carrier, so its move touches only its own stack and record. Find what the lock
    guards in a growth move today (the stress modes' stack pool; anything reading a running fiber's stack:
    the fiber dump, the leak pass, the stop-the-world), and move growth outside it where it is safe. Measure
    `deep_recursion` and `spawn_grow` at 4 carriers.
    **Done:**
    - **What the lock guarded.** Only the stress modes' stack pool (`rtStackTake`, `rtStackRetire`), which
      the lock still guards; outside them a move's stacks come from `malloc`. The stop-the-world cannot start
      during a move: the coordinator waits for every carrier's ack, and a carrier gives it only once its fiber
      runs again and stops at a poll. The shrink pass and the leak pass run inside it; the deadlock check
      counts a state-5 fiber as running either way.
    - **The change.** `nomuSchedStackCheck` takes the lock only under the stress modes, and the carrier moves
      the stack without it otherwise (`rtStackGrowLocked`; `rtSchedSwitchedBack` reports state 5 as not
      holding it). The counters became atomic.
    - **Results.** Paired against the same build with the lock, 30 pairs: `deep_recursion` (depth
      1,000,000) at 4 carriers 140 → 81 ms (−59.7 ms, 95% interval [−60.2, −58.6]); at 1 carrier equal
      (−0.06 ms, [−0.63, +0.31]). Median of 3 at 4 carriers, ns a fiber, against 104.5.1:

      | spawn_grow depth | before | after | Go 4 |
      |---|---|---|---|
      | 0 | 453 | 446 | 155 |
      | 64 | 3,067 | 633 | 388 |
      | 256 | 20,647 | 4,535 | 2,780 |
      | 1024 | 88,638 | 19,148 | 13,302 |

      `deep_recursion` at 4 carriers stays at 81 ms against Go's 35 because the four fibers run on about
      two carriers. The same happens with no growth (four compute-only tasks: 158 ms on 4 carriers against
      300 on 1): a searcher that finds work wakes another only when its own queues hold more, and the rest
      wait on a busy carrier. Go's rule (wake another whenever a searcher finds work) brought it to 44 ms in
      an experiment; that is scheduler policy and went to [254](254-scheduler-performance.md) 254.5.
    - **Tests.** The full tier three times (1430/1430 each); the fast tier at `stack_move=1`,
      `stack_move_checks=3` and `stack_shrink=1` (544/544 each); `stack-growth`, `large-frame*` and
      `stack-shrink*` five times each under `gc_stress_bytes=65536`.
  - **104.5.3** The move itself. Profile a growth and a shrink: the walk of frames for root slots and base
    pointers (a frame-index lookup per frame), the copy, the pointer fixes. Cut what shows, without the
    frame table (247 replaces the lookup later).
    **Done:**
    - **Where the time went.** The copy was about 1% of a move. Most of it was two binary searches per
      frame, each a chain of dependent loads: the stack-map record (`rtFrameLookup`) and the x19 fact
      (`rtFrameFact`), the second made twice, once in the mover's x19 pass and once in the root walk. Then
      zero-filling: `RawPtr.alloc` zeroes what it returns, so each growth zeroed its whole new stack before
      copying over its top, and each move zeroed a 32 KiB root buffer.
    - **The changes.**
      - A lookup cache (`rtFrameCached`): 64 direct-mapped entries from a return address to its record and
        fact. An address's lookups never change, so each thread keeps one in its carrier record (offset 176)
        for the whole run; a thread without a record makes one per walk or pass. The mover, the collector's
        walk of stopped fibers and the leak pass use it. Go keeps a pcvalue cache per thread the same way.
      - One pass over the frame-pointer chain fixes both the saved frame pointers and each base-pointer
        frame's x19, where there were two.
      - The move's root buffer starts at 64 roots (`rtRootsNewSized`) and grows as before.
      - The stack a move copies into is left unfilled: `Runtime.allocUninitialized(bytes:align:)`, a new
        runtime-only intrinsic, `RawPtr.alloc` without the fill. A new fiber's stack keeps it.
    - **Results.** Time in moves at one carrier (`move-ns`, median of 7):

      | step | `deep_recursion` | `spawn_grow` |
      |---|---|---|
      | before | 158 ms | 8.65 s |
      | lookup cache | 27 ms | 2.27 s |
      | kept per thread | 27 ms | 2.19 s |
      | one chain pass | 23 ms | 1.92 s |
      | small root buffer | 24 ms | 1.68 s |
      | unfilled stacks | 20 ms | 1.49 s |

      Finding the frame index once per run instead of per lookup changed nothing and was dropped. Wall time,
      median of 3 (`spawn_grow` in ns a fiber, `deep_recursion` in ms):

      | benchmark | Nomu 1 | Go 1 | Nomu 4 | Go 4 |
      |---|---|---|---|---|
      | spawn_grow, depth 0 | 215 | 147 | 481 | 160 |
      | spawn_grow, depth 64 | 870 | 1,427 | 427 | 414 |
      | spawn_grow, depth 256 | 4,766 | 10,930 | 1,435 | 2,892 |
      | spawn_grow, depth 1024 | 18,182 | 51,083 | 4,950 | 13,739 |
      | deep_recursion, 1,000,000 | 41 | 124 | 22 | 37 |

      Growth now beats Go by 2.5 to 3 times at depth 256 and beyond. A spawn with no growth is still slower
      (104.5.4, and the scheduler's part in 254). The shrink pass is unchanged at about 87 ms for 40,005
      stacks: its stacks are shallow, so lookups were never its cost; a profile splits it between `malloc`
      and `free` of the stacks (104.5.4), the copy, and touching 10,000 cold records and stacks.
    - **Tests.** The full tier twice (1430/1430); the fast tier at `stack_move=1`, `stack_move_checks=3`,
      `stack_move_checks=1` and `stack_shrink=1` (544/544 each); the growth, shrink and large-frame cases
      five times each under `gc_stress_bytes=65536`; a sema test for the intrinsic.
  - **104.5.4** Stacks pooled per carrier. Stacks come from `malloc` today and return to it at each fiber's
    end, growth and shrink. A free list per size class on each carrier, filled and drained without the
    scheduler lock, with a cap, and the surplus returned at major collections. Measure spawn cost
    (`spawn_grow` at depth 0), growth and the shrink pause against `malloc`, whose own per-thread caches
    may already take most of the gain; kept only if it wins.
    **Done:**
    - **What a spawn paid.** A profile of a spawn-only loop (2 million fibers, none growing, 191 ns a fiber
      on one carrier) put about a quarter of it in `malloc`, `free` and zero-fill, nearly all for the fiber
      record (128 bytes) and its stack, allocated at the spawn and freed when the fiber ends.
    - **The pools** (`runtime/stackmove.nomu`, "Pools per carrier"), shaped as Go keeps dead goroutines:
      each carrier keeps lists of records and of stacks by size class (2 to 64 KiB), behind its record at
      offset 184. A list holds up to 64; past that a batch of 32 moves to a shared pool under its own lock,
      and an empty list takes up to 32 back, so a fiber that starts on one carrier and ends on another is
      still reused. The shared pool has no cap; a major collection empties it and every carrier's
      (`rtPoolDrainAll`). Spawns, growth moves and finished fibers use them; a pooled record comes back
      zeroed, a stack as it was left. A thread with no carrier record and the stress modes use `malloc`.
      A first version with only per-carrier caps (256 records, 256 KiB a class) missed: `spawn_grow`'s
      waves keep 1,000 fibers alive, and most went back to `malloc`.
    - **Results.** Against the same build with pools off, median of 5 interleaved runs:

      | benchmark | 1 carrier | 4 carriers |
      |---|---|---|
      | spawn-only loop, ns a fiber | 171 → 147 (−14%) | 407 → 339 (−17%) |
      | spawn_grow, depth 0 | 180 → 152 (−16%) | 426 → 349 (−18%) |
      | spawn_grow, depth 64 | 696 → 652 (−6%) | 409 → 361 (−12%) |
      | spawn_grow, depth 1024 | 16,285 → 15,766 (−3%) | 4,571 → 4,338 (−5%) |
      | forkjoin_fiber, work 0 / 100 / 1,000 | −15% / −21% / −4% | −21% / −29% / −31% |
      | stack_shrink, six majors | −3% | −3% |

      `sleepers_fiber` and `forkjoin_fiber` at work 10,000 within 1–3%. `deep_recursion`'s 100,000-deep
      round read 1.8% slower between the two builds (paired, [+0.04, +0.11] ms); the same binary with pools
      switched off at run time measured equal ([−0.05, +0.07] ms), so the difference is code layout. Peak
      memory equal or lower on every benchmark (`stack_shrink` 970 → 881 MiB). A spawn now costs about what
      Go's does on one carrier (147 against 147 ns); on four carriers it is 339 against 160, the
      scheduler's part ([254](254-scheduler-performance.md)).
    - **Tests.** The full tier twice (1430/1430); the fast tier at `stack_move=1`, `stack_move_checks=3`
      and `stack_shrink=1`; the growth, shrink and large-frame cases five times each under
      `gc_stress_bytes=65536`, which runs majors that drain pools in use.
  - **104.5.5** Bulk memory past 128 bytes. Today it switches to the carrier's stack and calls libSystem's
    tuned routines. Against embedded tuned routines (Arm's optimized-routines) run on the fiber's stack, on
    `mem_routines`, `frames_strings` and `binary_tree`, by the libc rule above.
    **Done:**
    - **The ceiling.** A variant calling libSystem directly, with no stack switch (against the libc rule, for
      measuring only), showed what the switch costs: 0.3–0.5 ns a call, 12% of a 160-byte copy, under 5%
      from 1 KiB up; `mem_routines` 1.2% faster, `binary_tree` and `frames_strings` equal.
    - **Our own loops**, in place of embedding Arm's routines: copies and fills from 129 bytes to
      `NOMU_MEM_OWN_MAX` (4096) run 64 bytes a step on the caller's stack (the copy picks its direction by
      overlap and loads what a store could overwrite first, so it stays a correct `memmove`); past 4096 they
      switch to libSystem, which zeroes about twice as fast at 64 KiB and up (likely `DC ZVA`) and where the
      switch costs under 1%. Compares run here at every size, 32 bytes a step with vector registers, faster
      than libSystem's `memcmp` at every size measured; `memcmp` no longer calls libSystem.
    - **Results.** Against the build before, median of 11 interleaved runs, ns a call (`practice/memsize`):

      | bytes | copy | fill | compare |
      |---|---|---|---|
      | 160 | 3.4 → 2.5 | 3.2 → 2.1 | 5.0 → 3.2 |
      | 256 | 5.2 → 3.6 | 3.4 → 3.3 | 6.9 → 4.0 |
      | 1024 | 12.2 → 11.9 | 9.9 → 9.2 | 19.7 → 13.4 |
      | 4096 | 51.8 → 45.5 | 36.3 → 35.7 | 94.0 → 58.0 |
      | 65536 | 617 → 650 | 331 → 395 | 1,307 → 821 |
      | 1 MiB | equal | equal | 19,126 → 18,068 |

      Workloads: `mem_routines` 2.2% faster ([−3.3, −0.4] ms), `binary_tree` 0.6% faster ([−4.6, −1.8]
      ms), `frames_strings` equal. The 64 KiB copy and fill run the same libSystem path in both builds.
      Most of their gap comes from the sweep's order: without its compare phase it falls to +2.2% and +3.2%
      (an A/A control moves them 2% and 0.3%), so the new compare loop leaves cache state the next phases
      see. The +3% fill residue on unchanged code is unexplained, probably layout; with the loops switched
      off the new build measures the same.
    - **Tests.** `memory-routines` extended: sizes around the 64-byte steps and 4096 at two alignments;
      overlapping copies of 1000 and 4096 bytes, shifts 1 to 500, both ways; a compare with one byte changed
      at every position of 17 to 4097 bytes, and with a later byte changed the other way. It fails with the
      compare made to skip half of each 32-byte step, and with copies always run forward. The full tier
      (1430/1430), and the fast tier at `stack_move=1` and `stack_move_checks=3`.
    - **Left for later.** Arm's optimized-routines against these loops, and `DC ZVA` zeroing for large fills:
      [259](259-libc-or-own-per-routine.md).
  - **104.5.6** The clock: moved to [259](259-libc-or-own-per-routine.md) 259.4, where the other per-routine
    libc choices are and where [254](254-scheduler-performance.md)'s need for a cheap clock is in view.

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

## Dependents

- **[254](254-scheduler-performance.md)** (scheduler performance) waited on this task through 104.5: stack
  shrinking and stack pools changed what a spawn and a stack move cost. Done.

## Refs

`runtime.md` §6 (safepoints, parked-fiber scan, mutator); [103 dynamic spawn group](103-dynamic-spawn-group.md);
`rtSchedFiberNew` (`src/stdlib/runtime/scheduler.nomu`); [219 runtime fault handling](219-runtime-fault-handling.md).
