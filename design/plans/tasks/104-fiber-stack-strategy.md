# Fiber stack strategy: growth, overflow, high-fiber-count throughput

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design`
(runtime + compiler architecture) · **Size:** L · **Status:** direction decided (Go-style copying stacks);
104.1 (baseline) done; the entry check decided; unblocked by [194](194-gc-frame-metadata.md)'s decision
(extended statepoints; the copier and its stress mode are built); 104.2.1–104.2.5 done (the entry check, through x28, before the first call; overflow is now a fatal error; frames verified against the reserve; its cost measured); 104.2.6 accepted at parity with Go; 104.3.1–104.3.8 done (growth; raw pointers tracked; the platform layer, libc on the carrier's stack; Nomu's own memory routines; the link checks unchecked chains against the reserve; nothing outside a fiber points into its stack; every fiber starts at the minimum, completed stacks freed; 2 KiB stacks, large frames behind wrappers); next 250 (104.3.9 completes at 250.4), then 104.4, then performance (104.5); built before any collector is measured · **Source:** deferred.md

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
- **Shrinking.** At collections, a stack using under a quarter of its size is copied to one half the size.
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
    candidates stay open for a later pass on the check's cost.
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
      formatting (104.5).
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
    - **The reserve** is 1 KiB (`rtStackReserve`, `FrameTable.stackReserve`), a checked frame at most
      768 bytes (`FrameTable.frameLimit`), leaving the slow path 256; every fiber starts at 2 KiB
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
    free the record.
- **104.4** Shrinking at collections (above). Counted in functional completeness: without it a fiber that
  once ran deep keeps that memory, against the fiber-density goal.
- **104.5** Performance, after 104.4: growth by doubling and starting sizes learned per spawn site; stacks
  pooled per carrier with no guard pages; a smaller reserve once libc is off fiber stacks; the check
  elision of [238](238-stack-check-elision.md) and 104.2.6's other candidates; 247's frame table for the
  copier's walk. Each measured with counters for growths, bytes copied and time, and against Go on a
  spawn-heavy and a deep-recursion benchmark. And the per-routine choices of the libc rule (above): each
  candidate (short and bulk memory operations, integer and float formatting, float parsing, the clock)
  benchmarked against libc on workloads with the stack switch in place, the result deciding it.

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
