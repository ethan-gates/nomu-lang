# GC packaging — self-contained collector plans behind one trigger protocol

**Avenue:** Risk · **Type/Lifecycle:** `runtime · architecture · needs-design` · **Size:** L ·
**Status:** needs-design (after 159, whose tracing it is debugged with) ·
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
2. **Selecting a GC is one lever.** One lever picks a plan (`NOMU_GC_PLAN` was deleted with MMTk in
   [197](197-retire-mmtk-and-c-scheduler.md); a second Nomu plan brings its successor); the plan
   supplies its own defaults. No secondary knobs must be co-set for a plan to work, and no combination of
   them can wedge two mechanisms together. This is the structural version of task 157's env collapse.
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

- **Request shape.** Single-slot with precedence (a pending defrag outranks a pending minor) vs. a real
  request queue. The current flags are a single slot (`@136` request, `@176` kind); adding a
  STW-vs-concurrent bit and a clear precedence rule may suffice without a full queue.
- **Where a plan is declared.** A Nomu-side plan table vs. a C-side registry vs. a hybrid; how it composes
  with the plan-selection lever.
- **Legacy driver disposition.** The `NOMU_GC_PRESSURE` poller and the `NOMU_STW_*`/`NOMU_GC_SMOKE*` smoke
  drivers are pre-generational mechanisms generational subsumes; folding them into plans (the poller becomes
  a trigger source, not a coordinator) or retiring them (with tests migrated to the 155 harness) is decided
  here jointly with 157.
- **Concurrent-assist protocol for LXR.** What a "concurrent assist" request means at the mutator/carrier
  boundary, so the protocol is ready when LXR arrives rather than retrofitted.

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

## Non-goals

- Not the collector algorithms themselves (150's ladder, 127's LXR). This is the packaging/coordination
  substrate they plug into.
- Not the general env-var collapse ([157](157-env-var-audit.md)) — but the GC-lever share of it lands here,
  and the two are done together.

## Refs

[150 GC ladder](150-selfhosted-gc-ladder.md), [127 LXR](127-lxr-collector.md),
[157 env-var audit](157-env-var-audit.md), [155 integration-suite harness](155-integration-suite-harness.md)
(where migrated GC tests land); [197](197-retire-mmtk-and-c-scheduler.md) (MMTk retirement).
