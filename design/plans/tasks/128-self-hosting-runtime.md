# Self-hosting the runtime: GC + scheduler in Nomu, bootstrapped in assembly

**Avenue:** Risk (author north-star, the core bet) · **Type/Lifecycle:** `perf · refactor · needs-design`
(runtime + language subset + compiler + GC) · **Size:** XL · **Status:** build now — core bet;
decomposes into 125 → 149 → 150 → 127 · **Source:** deferred.md (2026-08-18)

## What

Rewrite the runtime — the GC and the M:N scheduler — in Nomu itself, compiled by the Nomu compiler,
with a small per-architecture assembly floor to bootstrap (context switch, entry / TLS / stack setup,
the pre-runtime moment). The model is Go's: a runtime in the language plus arch-specific asm stubs.
Replaces MMTk (Rust, ~26 MB link archive) and the C runtime (`runtime.c` / `core.c`).

## Three goals (author's framing)

1. **Remove Rust and C** — a pure Nomu + assembly runtime; no foreign-language dependency in produced
   binaries.
2. **Performance** — the runtime compiles through the same optimizing backend (SSAIR + LLVM), so
   runtime ops (alloc fast path, write barriers, scheduler hooks) inline into user code across the
   former runtime/user boundary, the way Go's in-language runtime does.
3. **Binary-size ceiling < 999 KB** — with GC/scheduler present and essential (no reliance on
   dead-stripping them out), the whole self-contained runtime still fits a tiny footprint. Removing
   the 26 MB MMTk archive is the enabler; monomorphization + DCE keep only the runtime paths a
   program uses.

## Why it's architecturally enormous

- **A runtime-Nomu subset.** GC/scheduler code must avoid recursively invoking the services it
  implements: no implicit GC alloc, no write barrier, no unplanned safepoint, controlled stack growth.
  Needs a mechanism analogous to Go's runtime pragmas (`//go:nosplit`, `//go:nowritebarrier`,
  `//go:noescape`) — new surface + new checking.
- **Bootstrap floor.** The irreducible per-arch assembly (context switch, thread/TLS/stack setup,
  entry sequence before collector + scheduler are live).
- **Collector replacement + [LXR](127-lxr-collector.md) overlap.** The collector in Nomu may be one effort
  with LXR — decide whether to fold.
- **Compiler support.** Emitting code that satisfies the runtime-subset constraints, the
  asm-interfacing calling convention, and the bootstrap linkage.

## Base prerequisites

- **[125 unsafe raw memory](125-unsafe-raw-memory.md)** — a hard floor (the collector + allocator
  manipulate untyped memory).
- **[149 runtime-subset mechanism](149-runtime-subset.md)** — the pragmas + checking for runtime code.

## Sequencing

**Build now — the core bet, not a late-stage task.** The earlier "design early, build late"
call was made when Nomu had no memory management at all; it deferred the whole effort on the reasoning
that a Nomu-compiled runtime only pays off once the backend is mature. That reasoning applied to the
*final* performance/size numbers, not to the runtime's architecture — the unsafe surface, the
runtime-subset mechanism, the bootstrap floor, the calling convention. Those are independent of backend
maturity, and discovering them late is the real risk. MMTk/GenImmix now exists as a reference to diff
against, which is what makes an incremental self-host tractable. So we build now, and expect early
perf/size numbers to firm up as the backend matures.

**Self-host first, then evolve the collector.** Self-hosting is a location change (MMTk/Rust → Nomu);
[LXR](127-lxr-collector.md) is an algorithm change (GenImmix → RC-hybrid). Hold the algorithm constant
while moving location, then change the algorithm inside the self-hosted runtime — one unknown at a time.

**Decomposition:**
- [125 unsafe raw memory](125-unsafe-raw-memory.md) — the raw-memory surface the collector/allocator need.
- [149 runtime-subset mechanism](149-runtime-subset.md) — the pragmas + checking for runtime code.
- [150 self-hosted GC ladder](150-selfhosted-gc-ladder.md) — NoGC → mark-verify → Immix → GenImmix, each
  diffed against the matching MMTk plan.
- [127 LXR](127-lxr-collector.md) — the final collector rung, an algorithm swap inside the self-hosted GC.
- The M:N scheduler + per-arch bootstrap assembly floor stay under this task, sequenced after the GC
  ladder (the GC can run hosted alongside the existing runtime first). This task also inherits the GC's
  **full-runtime root-scanning integration** from [150](150-selfhosted-gc-ladder.md): invoking the
  self-hosted stack walk at a real stop-the-world over all live mutators, plus the parked-fiber
  (`scan_parked_fibers`) and scheduler-root (`rt_sched_head`) sources. The ladder proves collector policy
  hosted on the existing C scheduler; wiring the self-hosted walk into a real STW couples to the
  carrier/context machinery built here, so it lands with the scheduler.

## Subtasks

The parts this task owns directly (the delegated prerequisites 125/149/150/127 keep their own numbers):

- **128.1 — M:N scheduler in Nomu.** Replace the C/pthread scheduler (run queue, carriers, fibers,
  safepoints) with a self-hosted one under the 149 subset. **Full plan:
  [`internals/selfhosted-scheduler.md`](../../internals/selfhosted-scheduler.md).** Two framing decisions
  (agreed with Ethan): **full scheduler now** (replace the entire C scheduler before returning to GenImmix,
  not a minimal substrate) and **raw syscalls + atomics** (no pthread/libc floor; the aggressive end of
  `runtime.md` §4's no-libc question). Climbed as a rung ladder, `NOMU_SCHED=nomu`-selectable, C scheduler
  as the differential oracle — the same method as the GC ladder (150):
  - **128.1.1** — atomics + raw-syscall substrate (the scheduler's analog of 125): atomic intrinsics,
    thread create / futex / clock / poller / TLS. On macOS each OS entry is a `libSystem` extern emitted by
    codegen (not an `svc` stub — Darwin's raw syscall ABI is unstable; the `svc` floor is Linux-only, plan
    §3.3). Also lands 149's poll-suppression slice (pull-forward, plan §4). *Codegen-only substrate —
    complete:* atomics, poll-suppression, the monotonic clock (`RawPtr.monotonicNanos()`), and the futex
    (`RawPtr.futexWait`/`futexWake` → `__ulock_*`) are built and green. Raw thread-create + the two-thread
    futex ping-pong moved to 128.1.2 (they couple to the asm floor / carrier callback).
  - **128.1.2** — single-fiber context round-trip (the `rtSwitch`/`rtFiberInit` asm floor) + carrier
    thread-create (`pthread_create`, the stable macOS floor — not raw `bsdthread_create`) and the
    two-thread futex ping-pong. *Core built:* the Nomu-driven fiber round-trip (`tools/fiberswitch.sh`)
    and the two-thread ping-pong (`tools/pingpong.sh`), on the `RawPtr.ofFunc` function-address primitive
    (a runtime-tier code pointer; full first-class functions are deferred to
    [152](152-first-class-functions.md)) plus `ctxSwitchTo`/`fiberInit`/`threadCreate`/`threadJoin`.
    *Remaining:* the run queue proper (128.1.3) and a formal diff against the C `swapcontext` oracle.
  - **128.1.3** — single-carrier run queue + spawn / park / unpark / join. *Built:* a Nomu scheduler loop
    over the substrate (intrusive run queue, `fiberSpawn`, the `fiberMain` completion trampoline, `park` /
    `unpark` / `joinFiber`), subset-legal, on the new `RawPtr.callEntry` indirect-call primitive. Three
    scenarios green — spawn/run/complete, park/unpark, join (`tools/scheduler.sh`). Deferred: freeing
    fiber handles/stacks (128.1.6), permit/lock-coupled park (128.1.4), a formal C-oracle byte-diff.
  - **128.1.4** — mutex over futex + MT-safe run queue + lock-handoff park. *Built:* a self-hosted `Mutex`
    (3-state futex word, Drepper "mutex1") is the single scheduler lock; the run queue moves under it, and
    the lock-coupled park protocol (`concurrency.md` §2, M6 6.4) is threaded through every fiber↔scheduler
    switch — held across the switch, released after switch-in, re-acquired to suspend, so no waker re-queues
    a fiber mid-save. Added `RawPtr.atomicExchange` (the mutex swap). Four scenarios green incl. a 2000-cycle
    parking-heavy relay (`tools/scheduler-lock.sh`), subset-legal, GC-independent, watchdogged. Still
    single-carrier (uncontended); real contention arrives at 128.1.5.
  - **128.1.5** — multi-carrier + idle sleep + cross-thread wake. *Built (wake-on-push half):* N carrier
    OS threads (`threadCreate`) drain one shared MT-safe queue; an idle carrier sleeps in `futexWait` on a
    wake-generation word and is woken when a producer bumps it + `futexWake`s; an atomic outstanding-fiber
    counter drives a stop broadcast for clean shutdown. First rung where the mutex genuinely contends
    (main vs carriers → the `__ulock_wait` slow path). Sum-of-atomic-accumulator = 600 across 4 carriers,
    NoGC-only, looped + watchdogged (`tools/scheduler-mc.sh`). *Deferred to after 128.1.6:* cross-thread
    fiber PARK/UNPARK (self-park needs thread-local `rt_current`), where the M6 6.4 race reproduces.
  - **128.1.6** — carrier-local state (TLS) + live-fiber registry. *Built:* `rt_current` in a
    `_Thread_local` slot (macOS floor; `RawPtr.tlsGet`/`tlsSet`) gives an argument-free `park()`, which
    unblocks the cross-thread park/unpark stress deferred from 128.1.5 — 16 token-pair rings × 4 carriers
    with a **lock-coupled hand-off** (make partner runnable + park self under one lock hold), budget
    claimed exactly once (=2000), clean 300× (`tools/scheduler-tls.sh`); the M6 6.4 race reproduced and
    closed. The intrusive live-fiber registry (O(1) insert/remove, iterate) is built + tested in isolation
    (`tools/fiber-registry.sh`); 128.3.2 drives its iteration from a real STW.
  - **128.1.7** — wakeup feeders: timer heap + I/O poller. *Built (both):* a Nomu min-heap + timer thread
    (deadlines woke in order, `tools/scheduler-timer.sh`) and a kqueue poller thread (8 fibers parked on fd
    readiness, unparked via kevent udata, `tools/scheduler-poller.sh`), each with the 6.4 handoff spanning
    feeder ↔ scheduler and a self-pipe / futex for shutdown. New substrate: `RawPtr.kqueue`/`kevent`/`pipe`/
    `readFd`/`writeFd` (libSystem externs). Blocking-syscall offload stays deferred.
  - **128.1.8** — actor mailbox + mailbox-fiber pool. *Built:* self-hosted `actorSend` + MT-safe FIFO
    mailbox + global scheduled-mailbox queue + the single-drain invariant + a capped pool of reusable
    mailbox fibers (free-list park, dispatch-or-create-to-cap) + drain-to-quiescence shutdown
    (`examples/scheduler_actor.nomu`, `tools/scheduler-actor.sh`). 8 actors × 50 msgs drained FIFO by ≤4
    reused fibers, handled=400 errors=0, clean 250×. The drain loop is plain Nomu (off-heap messages, no
    GC roots to track, unlike the codegen-emitted C loop). The M6 pthread-mutex actor is retired.
  - **128.1.9** — integration: the self-hosted scheduler runs real user programs behind `NOMU_SCHED=nomu`.
    *Built.* The 128.1.x rungs each proved one mechanism as a standalone NoGC-only fixture that builds its
    own raw carriers; none was yet the process scheduler for a GC-registered user program. This rung
    consolidates the machinery (mutex, MT run queue, carriers + idle wake, `rt_current` TLS, lock-coupled
    park, timer heap + timer thread, actor mailbox + capped mailbox-fiber pool) into one canonical scheduler
    in `src/stdlib/runtime.nomu` (the runtime-subset prelude) — `rtSched*` helpers + C-callable `nomuSched*`
    entries under a canonical Sched(256B)/Fiber(288B) layout — and makes `fiber_spawn` / `spawn_join` /
    `rt_sleep_ms` / `rt_actor_send` / `rt_mailbox_pop` and `main` dispatch on an `rt_sched_plan` global
    (`NOMU_SCHED=nomu` vs the default C path, codegen unchanged). Real user programs run on self-hosted
    carrier pthreads that poll at real safepoints; the actor drain reuses the codegen-emitted
    `nomu_actor_drain` as the mailbox-fiber body (weak fallback for actor-less programs). Scope (option C):
    **NoGC** — a real stop-the-world over these carriers saving a Nomu-readable context is 128.3.2; GC
    coupling here is just lazy per-carrier mutator binding (`rt_gc_alloc`). Diffed against the C scheduler
    on real spawn/join, sleep, and actor programs at 1 and 4 carriers (`tools/sched-integration.sh`, green);
    all 23 pre-existing drivers stay green. The kqueue poller + live-fiber registry are not consolidated yet
    (no NoGC user surface for the poller; the registry lands with 128.3.2, which drives its STW iteration).

  Terminal rung is **128.3.2** (below) — the STW-over-all-mutators integration that unblocks GenImmix,
  driven over the production carriers 128.1.9 wires in.
- **128.2 — Per-arch bootstrap assembly floor.** The irreducible asm: context switch, thread/TLS/stack
  setup, the entry sequence before collector + scheduler are live. *Built (arm64):* `rtSwitch` +
  `rtFiberInit` + trampoline in `src/runtime/embedded/rtasm_arm64.s`, embedded in nomuc and archived into
  `libnomuruntime.a`, isolation-tested via a C round-trip harness reached as `RawPtr.asmSelfTest()`
  (`tools/asmswitch.sh`). x86-64 deferred (no x86 machine yet); `rtTLSGet`/`svc rtSyscall` not yet needed
  on the macOS path.
- **128.3 — Full-runtime root-scanning integration (inherited from 150).** The GC ladder proves the
  collector's marking/tracing/fingerprint and the current-stack pcsp walk hosted on the existing C
  scheduler (150.2, `selfhosted-gc.md` §9). The remaining root-scanning pieces couple to the
  scheduler/carrier machinery, so they land here:
  - **128.3.1 — Self-hosted parked-fiber walk + scheduler-root (both built).** The parked-fiber
    walk is built and oracle-checked: `rt_gc_parked_anchors` (C) hands Nomu each parked fiber's innermost
    Nomu-frame anchor as a `(sp, pc)` pair, and `rtWalkFrom` (Nomu — a copy of the current-stack walk's
    pcsp loop, parameterized by an explicit anchor; kept separate because `rtCollectRoots` must keep its
    own inline for the caller-spill constraint, `selfhosted-gc.md` §9) reads its root slots and steps
    between Nomu frames self-hosted. Recovers a parked
    worker's live set `{111, 222}` and excludes the dead object, matching the C `nomu_gc_scan_parked_fibers`
    libunwind oracle in one process (`examples/walk_parked.nomu` + `tools/walk-parked.sh`). The caller-spill
    constraint (`selfhosted-gc.md` §9) does not apply — a saved context's roots were already spilled at the
    park.
    - *Finding — crossing the C park frames stays in C for now.* The first plan (Nomu skips the park frames
      via a frame-pointer chain from the saved `ucontext`) does not work: Darwin's `swapcontext` is asm with
      no clean FP chain, so a raw FP-walk derives the wrong SP for the first Nomu frame (found it latched
      onto the right function but an SP off by 96 bytes). C frames also carry no pcsp table, so only CFI
      (`.eh_frame`/libunwind) can step out of them — the C runtime already has it. So C crosses the park
      frames and hands over a Nomu-frame anchor; the GC-relevant walk (Nomu frames) is self-hosted. A fully
      self-hosted entry needs the park to save a Nomu-frame anchor directly, which lands with the
      self-hosted context switch (**128.1**).
    - *Scheduler root (built).* `rt_sched_head` — the global scheduled-mailbox queue head, a single managed
      root that keeps every queued mailbox's pending work alive — is read self-hosted via `RawPtr.gcSchedHead()`
      (a direct load of the C global; `rtScanSchedRoot` reports it) and diffed in-process against a C oracle
      that reads the same global. The fixture sends one fire-and-forget `bump` and runs single-carrier
      (`NOMU_CARRIERS=1`, a new env knob on the carrier count) so the mailbox fiber cannot drain the head
      before `main` reads it (`examples/sched_root.nomu` + `tools/sched-root.sh`). With this, root scanning is
      complete for all three source shapes buildable now — live stack, saved/parked context, and global —
      leaving only 128.3.2 (STW-over-all-mutators integration, blocked on 128.1).
  - **128.3.2 — STW-over-all-mutators walk integration.** *Built.* A real stop-the-world across the
    128.1.9 self-hosted carriers, each stopped mutator's roots recovered by the self-hosted pcsp walk
    (`rtWalkFrom`) with no libunwind — standing in for the C libunwind walk the MMTk binding calls today.
    The anchor for the walk is the **user frame** (where the return address is a statepoint `rtWalkFrom` can
    match), captured in the C dispatch shims (`spawn_join`/`rt_sleep_ms`/`__nomu_gc_poll_slow`) via
    `__builtin_return_address(0)`/`__builtin_frame_address(0)+16` — a direct immediate-caller read, the same
    caller-frame math `rtCollectRoots` uses, not libunwind/CFI. A running mutator is stopped at a safepoint
    poll (`nomuSchedSafepoint`, fiber state 4); the STW handshake is a request flag + ack-count-vs-carrier-
    total + resume futex in the `Sched`, driven by a plain coordinator thread. `nomuSchedWalkParked`
    iterates the live-fiber registry (128.1.6, consolidated here) and walks each stopped fiber's anchor.
    Forced-STW smoke `tools/stw-selfhost.sh`: busy-loop workers stopped mid-run + a sleep-parked fiber both
    recover `{111,222}` at 2 and 4 carriers, matching the C libunwind STW oracle (`NOMU_GC_STW_SMOKE`); dead
    roots excluded. All 25 drivers green. A live MMTk collection driving this STW (and moving-GC pointer
    fix-up) is 150.4. With this, the scheduler self-host (128.1) is complete and GenImmix (150.4) can land
    on the self-hosted scheduler.

- **128.4 — Unify the self-hosted runtime surface (one lever).** *Built.* `NOMU_RUNTIME` is resolved in C
  at the top of `main` (before `nomu_gc_init`): `selfhost` promotes the scheduler (`rt_sched_plan =
  RT_SCHED_NOMU`) and stores the `__nomu_runtime_selfhost` byte that `nomu_gc_init` reads to route allocation
  at the Nomu allocator. A self-hosted allocator auto-promotes the scheduler; pinning `NOMU_SCHED=c` with a
  self-hosted allocator aborts with a message (the forbidden quadrant is closed). `NOMU_SCHED` /
  `NOMU_GC_PLAN` remain the oracle overrides. Verified: `NOMU_RUNTIME=selfhost` reproduces `NOMU_SCHED=nomu
  NOMU_GC_PLAN=nomu` on `gc_pressure` (94950 + repeated collections); `NOMU_GC_PLAN=nomu` alone auto-promotes;
  the forbidden combo aborts (rc 134); native default stays MMTk; all 27 drivers green. Until
  150.3.9 the scheduler (`NOMU_SCHED`) and allocator (`NOMU_GC_PLAN`) were independent selectors, validly
  exercised in isolation (the scheduler was brought up on MMTk NoGC). Collecting-on-scheduler couples them:
  the self-hosted collector's STW handshake, pcsp root walk, and slot fixup all live in the scheduler
  machinery, so **self-hosted GC requires the self-hosted scheduler** (the reverse does not hold — the
  scheduler runs on MMTk). Two co-equal user levers therefore expose one incoherent combination. This phase
  collapses the user-facing surface to a single lever and pins the supported matrix.
  - *One product lever.* A `NOMU_RUNTIME={native,selfhost}` umbrella (default `native` for now). `selfhost`
    turns on the self-hosted scheduler + self-hosted allocator + collector as one unit. Product docs name only
    `NOMU_RUNTIME`.
  - *Decomposed selectors demoted to oracle overrides.* `NOMU_SCHED` / `NOMU_GC_PLAN` survive as the
    differential-test harness surface (we diff against MMTk and the C scheduler until MMTk retirement, after
    150.4). They are documented as internal oracle knobs, not co-equal product levers.
  - *Enumerated support matrix — three configs supported, one forbidden:*
    - (C sched, MMTk) — the joint differential oracle.
    - (Nomu sched, MMTk NoGC) — the scheduler-isolation oracle (bisect a scheduler bug from an allocator bug).
    - (Nomu sched, Nomu GC) — the product runtime; what `NOMU_RUNTIME=selfhost` selects; eventually the default.
    - (C sched, Nomu GC) — **forbidden.** Collection needs the Nomu STW/root-walk. Setting the allocator
      self-hosted auto-promotes the scheduler to self-hosted (or errors if the harness pinned `NOMU_SCHED=c`).
  - *One carrier-boot path.* Fold the scheduler-carrier boot and the allocator's per-carrier binding into a
    single "boot a carrier in the self-hosted runtime" path, so the 150.3.10 per-carrier TLAB hangs off one
    boot site rather than two independently-gated ones. This is why 128.4 precedes 150.3.10.
  - *Making `selfhost` the default* (retiring the `native` lever) waits for the self-hosted runtime to reach
    feature parity — multi-carrier allocation (150.3.10), the production pressure path (150.3.11), and broader
    roots (150.3.12) — and ultimately MMTk retirement after 150.4.

## Refs

deferred.md "Self-hosting the runtime"; `runtime.md` (scheduler, safepoints, mutator);
`memory-model.md` §3 (`VMBinding`); `backend.md`; [LXR](127-lxr-collector.md),
[unsafe raw memory](125-unsafe-raw-memory.md).
