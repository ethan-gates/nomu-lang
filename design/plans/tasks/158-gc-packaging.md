# GC packaging — self-contained collector plans behind one trigger protocol

**Avenue:** Risk · **Type/Lifecycle:** `runtime · architecture · needs-design` · **Size:** L ·
**Status:** done (158.1–158.6; 158.7 closed without work) ·
**Source:** grounded during 150.4.5.3 (flipping generational on by default) — the GenImmix nursery-full
minor trigger deadlocked against the legacy `NOMU_GC_PRESSURE` poller.

Package each garbage collector as a self-contained *plan* — allocator + collector + coordinator + the set
of triggers it raises — behind one shared trigger→request protocol, so multiple GCs can coexist without
stepping on each other and without configuration whose combinations interact in unknown ways. Selecting a
GC becomes choosing one plan; the plan carries its own trigger policy, and nothing else has to be tuned in
concert.

## Why — the failure that grounded it

The self-hosted runtime accreted several collection mechanisms wired together by ad-hoc boot conditions and
independent env levers. Two *triggers* (nursery-full; heap-headroom poll) and two *coordinators* (the
default request-driven `rt_gc_sync_thread`; the legacy poll-driven `rt_gc_pressure_thread`) share the STW
flags but speak different request protocols, and boot starts them mutually exclusively
(`selfhost_alloc && !gc_driver_env`). When generational became the default, the nursery-full trigger fired,
posted a minor request to a coordinator that `NOMU_GC_PRESSURE` had prevented from starting, and parked a
carrier forever waiting to be resumed. A trigger fired into a void.

The deeper problem is lever multiplicity: ~10 `NOMU_*` knobs influence *when and how* collection fires
(`NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_GC_TRIGGER_RESERVE`, `NOMU_GC_PRESSURE`,
`NOMU_STW_COLLECT`, `NOMU_STW_SELFHOST`, `NOMU_GC_STRESS`; until 197 also the `NOMU_GC_SMOKE*` drivers and
`NOMU_GC_PLAN`), and their
combinations produce states no one modeled. Predicting the interactions by hand does not scale.

## What — the shared / per-plan split

The lesson from the LXR discussion: do **not** unify on one coordinator. An STW coordinator built for
GenImmix would force LXR — a mostly-concurrent RC/Immix hybrid whose whole point is avoiding
stop-the-world — into a pause shape it is designed to escape, biasing any comparison. So the boundary is:

- **Shared — the trigger→request protocol + one invariant.** How a mutator signals "I need collection"
  (a typed request: the collection *kind*, and whether it needs a stop-the-world or a concurrent assist),
  the safepoint/park contract, and the invariant that broke during GenImmix bring-up: *the active plan's
  coordinator services every trigger that plan can raise.* This layer is plan-independent.
- **Per-plan — the coordinator implementation.** GenImmix, non-generational Immix, and simple mark-sweep
  are stop-the-world tracing collectors and may share an STW coordinator. LXR brings its own concurrent
  coordinator. A plan declares the triggers
  it raises and provides the servicer for them.

Each plan is then exercised on its native coordinator — the apples-to-apples comparison the language's
memory-model experiment needs (proven programmer surfaces over unproven internals).

## Goals

1. **A plan is a package.** One place defines allocator + collector + coordinator + trigger set + default
   trigger policy for a GC. Adding a GC (e.g. simple mark-sweep, later LXR) is adding a package, not
   threading new env levers through boot.
2. **Selecting a GC is one build setting.** `gc.plan` picks a plan at build time, and the plan supplies its
   own defaults. Plans that are not selected are absent from the binary. No secondary knobs must be co-set
   for a plan to work, and no combination of them can wedge two mechanisms together. This is the structural
   version of task 157's env collapse.
3. **No trigger fires into a void.** Boot guarantees exactly one coordinator for the active plan, and that
   coordinator services every trigger kind the plan raises. The interim gate below is removed here.
4. **Plans don't bias each other.** The shared layer imposes no pause model; STW is a property of the
   plan's coordinator, not of the protocol.

## Removes the interim gate

150.4.5.3 landed a workaround: `rtGenReserve` returns 0 (generational off) when an external STW driver is
active (`__nomu_gc_ext_driver`, set from `NOMU_STW_SELFHOST`/`NOMU_STW_COLLECT`/`NOMU_GC_PRESSURE`), so the
default-on generational trigger cannot collide with a legacy driver. That is a rule papered over the lever
interaction. This task subsumes it: with plans self-contained and one coordinator per plan, the collision
cannot form, and the gate (`gcExternalDriver` intrinsic + `__nomu_gc_ext_driver` + the `rtGenReserve`
check) comes out.

## Design axes to settle

- **Request shape.** Settled: a single slot with precedence and a STW-or-concurrent bit (see 158.2).
- **Where a plan is declared.** Settled: a build setting, `gc.plan`, folded to a constant (see 158.2).
- **Legacy driver disposition.** Settled: the drivers retire (see 158.2).
- **Concurrent-assist protocol for LXR.** Deferred to [127](127-lxr-collector.md). The request slot carries
  the STW-or-concurrent bit; what a concurrent assist does at the carrier is designed with LXR, under its
  own plan.

## Deterministic GC tests

Moved here from [159](159-gc-observability.md): the fixes for the driver cases go through this task's
trigger protocol. 159's report gives the cycle counts the cases assert.


Accepted for now, recorded here: some suite cases decide pass or fail by thread timing. The rule to reach is
that a case's result depends only on the program. Timing may decide where a collection lands, but every
assertion holds for every timing, and what the case exists to exercise is guaranteed to happen.

- **Found.** With the long cases shortened ([155](155-integration-suite-harness.md) Phase 3), the three
  `-self` heap-pressure cases (`gc-roots-across-modules-self`, `gc-shapes-across-modules-self`,
  `gc-generic-two-consumers-self`) each failed once under suite load: the driver thread fired 0 collections
  before the 0.1 s program exited, so the `min 2` collection check failed. Output was correct each time; the
  runs exercised no collection. Alone they pass 20 of 20. They are marked `timing_sensitive` (run alone at the
  end), as is `read-line`; that lowers the odds without removing the race.
- **Where the suite relies on timing.** `gc_pressure_driver` (5 cases: a polling thread must reach its
  threshold before exit), `stw_collect_driver` (7) and `stw_selfhost_driver` (2: a timer must fire while the
  interesting frames are live), and `stdin_delay_ms` (3: other fibers must print before a delayed feed).
  Multi-carrier interleaving is intended nondeterminism for race hunting; outputs do not depend on it.
- **Options for the driver cases.** (a) Fire on program progress, not wall time: after N allocated bytes or N
  safepoint polls, through the real trigger protocol (as `gc_stress_bytes` already does). (b) A hand-off: at
  the threshold the mutator signals the driver and waits at its next safepoint until the collection completes,
  so the trigger-thread path runs exactly every time. (c) An exit hold until N collections ran, which can pass
  while testing nothing (the frames are gone by exit). (d) Longer programs, which keeps the race. Options (a) and (b) go through
  this task's trigger protocol.
- **Options for the stdin cases.** (e) An event-driven feed: the harness writes stdin once stdout has shown a
  given text (`stdin_after`). (f) Keep the delay.
- **Harness support.** `timing_sensitive` as a temporary marker with a removal phase, and a full-tier
  determinism check that runs every case several times under load and fails a case whose result changes.

## Work

- **158.1** Baseline: measure the current collector before any routing changes, so the cost of plan
  dispatch can be read against it. If dispatch costs measurable time, a plan that is not selected stays
  out of the binary (chosen at build time, like `gc.record`) and is not routed to at run time.

  **Done.** `tools/gc-baseline.py` builds each benchmark workload `release` (timed, best of 7) and
  `release` + `gc_record` (the report's metrics). Each workload runs on 1 and 4 carriers, generational and
  major-only (`NOMU_NURSERY_RESERVE=-1`). The table is from Apple arm64 on the tree after 159.6. Times are
  in ms, except wall, which is in s.

  | workload | car | mode | wall | cycles | gc | p50 pause | max pause | ttsp p99 | peak MB |
  |---|---|---|---|---|---|---|---|---|---|
  | alloc_live | 1 | gen | 0.111 | 9 | 2.7 | 0.29 | 0.36 | 0.26 | 64 |
  | alloc_live | 1 | major | 0.117 | 2 | 0.9 | 0.43 | 0.49 | 0.26 | 256 |
  | alloc_live | 4 | gen | 0.112 | 9 | 2.7 | 0.30 | 0.33 | 0.27 | 64 |
  | alloc_live | 4 | major | 0.123 | 2 | 0.9 | 0.45 | 0.47 | 0.26 | 256 |
  | binary_tree | 1 | gen | 0.395 | 40 | 106.0 | 0.33 | 35.38 | 0.26 | 64 |
  | binary_tree | 1 | major | 0.557 | 11 | 258.8 | 21.38 | 38.57 | 0.27 | 256 |
  | binary_tree | 4 | gen | 0.400 | 40 | 104.2 | 0.36 | 34.21 | 0.28 | 64 |
  | binary_tree | 4 | major | 0.557 | 11 | 247.9 | 20.32 | 35.33 | 0.26 | 256 |
  | micro_dispatch | 1 | gen | 0.051 | 4 | 1.1 | 0.27 | 0.34 | 0.26 | 64 |
  | micro_dispatch | 1 | major | 0.060 | 1 | 0.5 | 0.45 | 0.45 | 0.26 | 256 |
  | micro_dispatch | 4 | gen | 0.051 | 4 | 1.1 | 0.27 | 0.32 | 0.27 | 64 |
  | micro_dispatch | 4 | major | 0.060 | 1 | 0.4 | 0.43 | 0.43 | 0.26 | 256 |

  What it shows:
  - Four of the seven workloads (`micro_alloc`, `gc_barrier`, `gc_footprint`, `micro_carried`) run no
    collection and finish in 5–20 ms, so they measure allocation and barrier cost only. Comparing plans
    needs larger, longer-lived workloads; 104's fiber-heavy benchmarks are the planned source.
  - Generational wins every collecting workload: `binary_tree` 0.40 s against 0.56 s, with a p50 pause of
    0.3 ms against 20 ms. Major-only collects only when the heap is full (256 MB peak).
  - Time to safepoint has a floor of about 0.26 ms in every collecting run, on 1 carrier as on 4. The
    coordinator polls for carrier acks with a 200 µs sleep (`rt_gc_sync_thread`), which matches the floor.
    That poll makes up most of a minor pause (0.29 ms p50 on `alloc_live`).
  - The write barrier is emitted unconditionally (`__nomu_write_barrier`, `LLVMGenRuntime.swift`), so the
    major-only mode pays for a barrier it does not need. That cost is fixed when the binary is built, so
    only build-time plan selection can remove it; run-time routing leaves it in.
  - Where routing would cost anything: the trigger check runs at block refill (once per 32 KiB), and the
    coordinator's dispatch runs once per cycle. Both are small next to a 0.26 ms pause floor. The barrier
    and the allocation fast path are the per-store and per-object costs; the plan choice changes them only
    if it is made at build time.
- **158.2** Design: settle the remaining axes above, given 158.1.

  **Settled: plans are selected at build time.** A `gc.plan` setting (`genimmix`, the default, and
  `immix`, major-only) selects the plan for the whole program. It follows `gc.record`'s path:
  - It's declared in `Settings.swift`, applies to the whole program, and is part of every module's cache
    key. A module built under one plan cannot link with a module built under another.
  - `Runtime.gcPlan()` folds to an integer literal in sema, so the trigger in `rtImmixRefill`, the
    coordinator's dispatch and `rtGenReserve` keep only the selected plan's branch.
  - Codegen reads the plan the way it reads `countsAllocations`. Under `immix`, `__nomu_write_barrier`
    and `__nomu_remember` emit the plain store with no barrier body.

  Why: 158.1 shows run-time dispatch would cost little, one check per block refill and one dispatch per
  cycle. The write barrier, though, is emitted for every store whatever the run-time mode, and only
  build-time selection removes it from a plan that does not need it. `NOMU_NURSERY_RESERVE=-1` becomes
  `gc.plan: immix`; suite cases that set it select the config instead.

  To verify while building: the major collector runs correctly with no log bits ever set. It clears log
  bits as part of its work, which becomes a no-op.

  **Settled: the legacy drivers retire.** The `NOMU_GC_PRESSURE` poller and the `NOMU_STW_COLLECT` and
  `NOMU_STW_SELFHOST` smoke drivers are removed, with `NOMU_GC_TRIGGER_RESERVE` and the interim gate. Why:
  generational collection plus the out-of-memory trigger already covers what the poller did, and the
  drivers' cases ran a collector setup no program ships with, on wall-clock timers. How their cases move
  is in 158.3.

  **Settled: the request stays a single slot.** The slot gains a precedence rule, where a pending major
  outranks a pending minor, and a stop-the-world-or-concurrent bit. Why: with plans chosen at build time,
  LXR brings its own coordinator and barrier under the same constant gate, so the shared protocol needs no
  more than the bit until LXR arrives. A queue adds nothing for two stop-the-world plans.

  **Settled: the coordinator waits for acks on a futex.** Each carrier's ack increments the ack word and
  wakes the coordinator, which sleeps on that word until the count reaches the number of carriers. Why: the
  200 µs sleep between checks sets the 0.26 ms time-to-safepoint floor in 158.1, and the scheduler already
  has the futex primitives.

  **Done.**
- **158.3** Retire the legacy drivers and the interim gate.

  **Done.** Removed: the three driver threads in `runtime.c` (the coordinator now starts unconditionally),
  `NOMU_GC_PRESSURE`, `NOMU_STW_COLLECT`, `NOMU_STW_SELFHOST`, `NOMU_GC_TRIGGER_RESERVE`, the
  `rtGcExternalDriver` global with its checks in `rtGenReserve` and `rtStressTick`, the force-all
  collection (`nomuSchedStwCollect`, `rtImmixCollectRoots`, cycle kind `forced`), and the four suite
  settings that set the variables.

  The 14 driver cases split in two:
  - **Six duplicated a case that already ran the same fixture through the real coordinator**, so they were
    deleted: `gc-pressure` (`gc-oom`), `gc-concurrent` (`gc-oom-concurrent`, which gained 8 carriers), the
    three `-self` cross-module cases (their `-evac` twins gained 2 carriers), and `managed-buffer-ref-self`
    (`managed-buffer-ref-evac`).
  - **Eight catch a fiber mid-loop in a loop that does not allocate**, which a stress trigger cannot reach
    on one carrier. Their fixtures now request the collection themselves. `rtGcRequest(kind)` (runtime,
    callable from `rt_prelude` fixtures) raises a request through the coordinator and returns, and the
    caller stops at its next safepoint poll. It returns a ticket, and the fixture's loop spins until
    `rtGcCollected(ticket)`, so the collection always lands inside the loop. Fixtures where a second fiber
    must be mid-loop raise a flag just before the loop (no poll lies between the flag and the loop), and the
    requester waits for it. The request is a minor: every object these fixtures hold is young, so the
    minor moves all of them, as the force-all collection did.

  The walk-only collection kind was not needed: the two stack-walk cases (`stw-running`,
  `stw-inlined-loop`) assert the same roots through a requested minor, which also moves them.

  The suite's `collections` matcher gained `trigger` and `roots` (stack roots in the cycle, from the
  report's `roots` counter), replacing the drivers' stderr lines. Each moved case asserts exactly one
  `program request` minor (60 for `module-generic-producer-loop`, one per iteration) with the root count
  the driver used to print. `module-generic-string` shared its fixture with `module-generic-string-evac`
  and was removed. The report names trigger 5, `program request`.

  Coverage given up: the loop-iteration case moves its object once (it is mature after the first minor),
  where the force-all collection moved it every round; the root walk still runs every iteration. The
  cross-module `-self` cases ran defrag majors; their `-evac` twins run stress collections.

  Checks: the 38 affected cases pass 10 of 10 under `--repeat 10`; the fast tier passes (342).
- **158.4** Move the coordinator into Nomu.

  **Done.** `rtGcCoordinatorMain` (`runtime/collect.nomu`) replaces `rt_gc_sync_thread`: the same request
  protocol (gc-request @168, stw-request @136, kind @176) and the same handshake, run as a raw OS thread that
  `nomuSchedBoot` starts beside the timer thread and joins at exit; `rtSchedSignalStop` wakes it so it
  exits promptly. The ack wait sleeps on the ack word, which each carrier's ack already bumps and wakes
  (`rtSchedStwParkCarrier`), with a 1 ms backstop. `rtStopWorld` widens to 8 bytes so Nomu writes it with
  `atomicStore`; the poll loads it as an `i64`. `main` no longer calls `rt_gc_threads_start`. `runtime.c`
  and `runtime.h` are deleted with their embedding (`embed.sh`, the genrule, `EmbeddedSources`) and the
  archive's key; the runtime archive holds only the asm floor. This completes 223's C removal.

  `tools/gc-baseline.py` after the change (best of 7, Apple arm64), against 158.1:

  | workload | car | mode | wall (s) | p50 pause (ms) | max pause (ms) | ttsp p99 (ms) |
  |---|---|---|---|---|---|---|
  | alloc_live | 1 | gen | 0.110 (0.111) | 0.04 (0.29) | 0.12 (0.36) | 0.01 (0.26) |
  | alloc_live | 4 | gen | 0.110 (0.112) | 0.04 (0.30) | 0.07 (0.33) | 0.02 (0.27) |
  | binary_tree | 1 | gen | 0.377 (0.395) | 0.08 (0.33) | 34.65 (35.38) | 0.01 (0.26) |
  | binary_tree | 4 | gen | 0.380 (0.400) | 0.09 (0.36) | 34.09 (34.21) | 0.03 (0.28) |
  | binary_tree | 1 | major | 0.546 (0.557) | 20.08 (21.38) | 34.91 (38.57) | 0.01 (0.27) |
  | micro_dispatch | 1 | gen | 0.050 (0.051) | 0.02 (0.27) | 0.10 (0.34) | 0.01 (0.26) |

  The 0.26 ms time-to-safepoint floor is gone, and a minor pause's median drops about 7×. `binary_tree`
  gains about 5% wall time.

  Checks: the full tier (753 passed), the GC, scheduler, actor and line-input cases 10 of 10 under
  `--repeat 10` (84 cases), `--check-reproducible` (1745 identical), the 18 Bazel test targets.
- **158.5** The plan setting and the request protocol.

  **Done.**
  - **`gc.plan`** (`genimmix`, the default, or `immix`) is a compile setting of program granularity,
    beside `gc.record`, so it reaches every module's cache key, the runtime's included. The `gc_immix`
    config selects `immix`. `Runtime.gcPlan()` folds to its id in sema (0 genimmix, 1 immix).
  - **Runtime.** `rtGenReserve` returns 0 under `immix`, a constant, so the nursery trigger, the minor
    escalation and the generational defrag fold away; the coordinator's minor dispatch is gated on the plan
    too. `NOMU_NURSERY_RESERVE` keeps its positive override; its negative value (major-only) is gone.
  - **Codegen.** `emitsWriteBarrier` (`LLVMGen`) is off under `immix`: `__nomu_write_barrier` is the store
    alone and `__nomu_remember` is empty, so no store carries a barrier. `rtRememberStore` drops out of the
    binary.
  - **Request protocol.** Every requester (`rtSelfhostOom`, `rtSelfhostMinorGc`, `rtGcRequest`) raises
    through `rtGcRaise`. The first sets the kind and wakes the coordinator; a later major joins and
    outranks a pending minor (the kind becomes major, and the report's trigger becomes the major's). The
    coordinator reads the kind only after every carrier has acked, so no requester can change it after.
    Bit 8 of the kind word is documented as reserved for a concurrent request (127); no code sets it yet.
  - **Tests.** `gc-overflow-mark` builds under `gc_immix` in place of `nursery_blocks: -1`. A new `gc`
    dimension value, `immix-stress` (full tier), runs every shape fixture under `immix` with stress
    collections and asserts at least 100 majors and no minor: the major collector is correct with no log
    bit ever set. A new case, `gc-request-precedence`, requests a minor then a major with no poll between
    and asserts one major and no minor. `tools/gc-baseline.py` selects major-only through `gc_immix`.

  The barrier's cost, from `tools/gc-baseline.py` (best of 9, Apple arm64), `immix` against `genimmix`:
  `gc_barrier` (stores into a managed array, no collection) 11.7 ms against 13.1 ms on 1 and 4 carriers,
  about 11% of wall time including process start; `binary_tree` under major-only 0.507 s against 0.557 s
  with the barrier in (158.4), 9%.

  Found: functions with GC safepoints survive `-dead_strip`. Under `immix`, nothing calls the minor
  collector (`nomuSchedStwCollectMinor`, `rtImmixCollectMinor`, `rtSelfhostMinorGc`), yet the binary keeps
  them; an unused user function with an allocation loop is kept the same way, while an unused leaf function
  is stripped. The likely cause is the stack-map section, which refers to every function with a
  statepoint, so the linker counts them as referenced. That is 158.7.

  Checks: the full tier (864 passed, 111 of them `immix-stress`), the fast tier (342), `--check-reproducible`
  (1754 identical), the 18 Bazel test targets.
- **158.6** Deterministic tests.

  **Done.**
  - **The determinism check is `--repeat`.** It runs the selection N times on the shared pool, so cases
    load each other, and fails a case whose result changes between rounds; no separate mode was needed.
    `tests/README.md` names `--tier full --repeat 3` as the check. Run here: every case passed 3 of 3 (exit 0).
  - **The stdin cases are event-driven (option (e)).** The harness's `stdin_delay_ms` became `stdin_after`:
    the file is written once the program's stderr shows a text. Stdout cannot carry the signal: `print` is
    buffered on a pipe and flushed only at exit. The fixtures build with `rt_prelude` and write `ready` to
    stderr when the wait is certain: `read-line` after the ticker's third tick; `read-line-readers` from a
    fourth fiber once `rtStdinWaiters()` (new, `runtime/io.nomu`) counts three readers on the stdin waiter
    list; `read-line-gc` from `churn`, which starts collecting only once `main` is on the list and signals
    when done, so every collection runs with `main` parked. All three pass 10 of 10.
  - **`timing_sensitive` is removed** from the harness (no case needs it), with `stdin_delay_ms`.
  - Whether `readLine` should flush stdout before it waits (as C++ ties `cin` to `cout`) is a stdio
    question, recorded open in [120](120-stdlib-core.md) for the I/O work.

  Checks: the full tier three rounds (`--repeat 3`, exit 0), `--check-reproducible` (1754 identical), the 18
  Bazel test targets.
- **158.7** Unused code with safepoints is not dead-stripped.

  **Closed without work.** The cause is confirmed (`-why_live`): an object's `__llvm_stackmaps` section is one
  unit to the linker, with a relocation to every function that has safepoints, so all of them stay when the
  section does. For the plans, it means the `immix` binary keeps the minor collector it never calls. That
  cost does not matter here: once the comparison with LXR picks the collector for Nomu's workloads, the others
  either leave the normal build or are made zero-cost to keep (recorded in [127](127-lxr-collector.md)).
  The same cause keeps every unused function with a safepoint in every program, user code included; that is
  [229](229-dead-strip-safepoint-code.md).

## Non-goals

- Not the collector algorithms themselves (150's ladder, 127's LXR). This is the packaging/coordination
  substrate they plug into.
- Not the general env-var collapse ([157](157-env-var-audit.md)) — but the GC-lever share of it lands here,
  and the two are done together.

## Refs

[150 GC ladder](150-selfhosted-gc-ladder.md), [127 LXR](127-lxr-collector.md),
[157 env-var audit](157-env-var-audit.md), [155 integration-suite harness](155-integration-suite-harness.md)
(where migrated GC tests land); [197](197-retire-mmtk-and-c-scheduler.md) (MMTk retirement).
