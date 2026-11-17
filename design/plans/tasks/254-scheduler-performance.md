# Scheduler performance: the gaps left after the run queues

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · issue defined` ·
**Size:** M · **Status:** issue defined; waits on [236](236-fiber-preemption.md) and
[237](237-handoff-primitives.md) ([250](250-fiber-task-surface.md) and [104](104-fiber-stack-strategy.md) are done) ·
**Source:** [235](235-scheduler-run-queues.md)
(235.4.2, 235.7, 235.8)

## What

[235](235-scheduler-run-queues.md) gave each carrier its own run queue, took the idle path, channels and actors
off the scheduler lock, and measured the result against Go (235.6). Three gaps remain, each investigated far
enough to know its cause or to rule out the obvious ones:

- one carrier pays a few ns more per handoff than before 235 (254.1);
- fan-in across carriers moves its senders between carriers on every value (254.2);
- most wakes on several carriers find nothing to do (254.3).

Where these stand against Go, from 235.6 (best of 7, ns; Go with GOMAXPROCS as carriers):

| benchmark | 1 | 2 | 4 | 8 | Go 1 | Go 2 | Go 4 | Go 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `pingpong_channel` (`go chan`) | 56.1 | 58.4 | 62.7 | 85.1 | 84.5 | 86.5 | 108.1 | 108.3 |
| `stream_channel` | 21.9 | 23.1 | 25.0 | 35.8 | 21.2 | 27.0 | 29.2 | 27.8 |
| `fanin_channel` | 22.6 | 162.6 | 74.9 | 91.5 | 21.1 | 31.9 | 54.7 | 57.2 |
| `pipeline_actor`, no work | 180.2 | 125.0 | 135.9 | 225.8 | 163.2 | 119.6 | 104.9 | 98.7 |

`pipeline_actor`'s row was measured on runs with no collections; under [230](230-heap-sizing.md)'s heap sizing the same
source collects and ran 312 / 254 / 205 / 264 ([261](261-actor-follow-ups.md).3, .5). With messages in a pool (261.4)
it is 96 / 90–160 / 74 / 260, ahead of Go through 4 carriers and still behind at 8.

## Depends on

Tuning the scheduler before the features that change its hot paths would be measured against a scheduler that
is about to change, so this task comes after them:

- **[236](236-fiber-preemption.md), preemption.** It decides the stop points (loop polls kept and strip-mined,
  function-entry polls, or signals), which 254.3's deferred wake fires at, and adds a check to the poll or the
  entry that every handoff pays. Its monitor and slices also change when a carrier gives up a fiber.
- **[237](237-handoff-primitives.md), handoff primitives.** A direct switch from a readier to the fiber it
  readies skips the run queue, the pick and the wake, which is most of what 254.1 measures, and changes which
  carrier a handed-off fiber runs on, which 254.2's steals depend on.
- **[250](250-fiber-task-surface.md), the fiber and task surface, through 250.8 (done).** 250.3 replaces the join with
  a `Task` over a one-shot channel (the spawn and join that `forkjoin_fiber` measures); 250.5 adds `select`,
  whose waiters change how a channel operation parks and wakes, and with it [135](135-cancellation-continuations.md)'s
  one-shot continuation, if parking moves onto it; 250.8 shrinks the fiber record each switch touches.
- **[104](104-fiber-stack-strategy.md), fiber stacks, through 104.5 (done).** Shrinking stacks at collections (104.4)
  and stacks pooled per carrier (104.5) change what a spawn costs and what `rtSchedRun` does at a stack move.
  Starting sizes, tuned later in [258](258-runtime-policy-tuning.md), change it again; rerun then.

Rerun 235.6's comparison once all four are in, then take whichever of 254.1 to 254.3 still shows. A gap with Go need
not close here if other planned work is expected to close it; record the expectation instead.

## Steps

- **254.1** The one-carrier cost (from 235.7). `pingpong_channel` takes about 8 ns more a hop on one carrier
  than before 235. Interleaved A/B, median of 15, ns per hop: the runtime before 235.2 47; after 235.3 55;
  without dyld stubs (hidden visibility) 55; readying under the scheduler lock again 59; the owner's slot
  operations as plain loads and stores 59. So neither the stubs nor the atomics are the cost, and builds that
  only remove work measure 3 to 4 ns slower, a sign of code placement or branch prediction. Other one-carrier
  workloads are even or better (`stream_channel` 19.7 → 19.2, `forkjoin_fiber` 348 → 213). Untried:
  - **The clock on every pick.** `rtSchedFind` reads `Runtime.ticks()` on every pick, a `mach_absolute_time`
    call through the libc stack switch (`nomu_libc_mach_absolute_time`). Called directly on the fiber's stack
    it costs about 4.5 ns and stays monotonic across threads (254.3); it needs `FrameTable.noStack` to admit it.
  - **The loop's shape.** The pick, run and switch-back are separate calls (`rtSchedFind`, `rtSchedRun`,
    `rtSchedSwitchedBack`).

  Hidden visibility was tried and reverted: the link strips local symbols (`-x`), so the runtime's names left
  profiles and crash reports.
- **254.2** Fan-in across carriers (from 235.8). `fanin_channel` on 2 carriers takes about 160 ns a value (22 on
  one, Go 32). Counted: about 500 wakes but 3.9M steals in 4M values, one per value. The receiver readies a
  blocked sender each time it frees a buffer slot; the readied sender goes to the ring, the other carrier steals
  it at once, it sends one value into the full channel and parks again, so the senders move between carriers on
  every value. 235.3's figure for 2 carriers (25 ns, beating Go) rested on a lost wake fixed in 235.4.3: with
  wakes suppressed, the second carrier slept and fan-in ran on one carrier. Tried: making a carrier that finds
  work only elsewhere search (look once a microsecond) instead of stealing at once; no change, since the steals
  come from the pick itself. Untried: a steal policy that leaves a just-readied fiber to its owner (Go's
  `runqsteal` takes `runnext` only after 3 µs, but not the ring), or a cheaper cross-carrier handoff.
- **254.3** Wake churn (from 235.4.2, set aside there). On several carriers nearly every wake is wasted: the
  readied fiber runs on the readier's carrier moments later, the woken carrier searches its window, finds
  nothing and sleeps, and the next readying wakes another, a system call on the readier's path each time. Go's
  `wakep` does the same, which is why `go chan` sits near 100 ns on 8.

  Policy rule: a choice that departs from Go's must improve CPU use or unpark latency without giving up the
  other. That rules out a searcher that keeps spinning while handoffs continue (CPU for latency; Go caps its
  spinners) and a monitor that wakes for aged slots (latency for CPU).

  Acceptance: equal or better on every scheduler benchmark (`tools/schedbench.py`: `pingpong`, `stream`,
  `fanin`, `forkjoin`, `producer`, `mixed`, `idle`, `sleepers`) on 1, 2, 4 and 8 carriers, in both wall time and
  CPU time, beyond run-to-run noise. Large concurrent programs would be the better test; none exist yet.

  The candidate, the deferred wake: a readying that only fills the carrier's next slot owes a wake instead of
  making it. The readier settles it at its next scheduling point: a park drops it (the readied fiber runs
  here), a safepoint poll or a blocking or foreign call fires it. A readying that leaves more work than the
  carrier takes next wakes at once. Go makes this wake and then mostly wastes it: its stealers already wait 3 µs
  before taking another processor's next slot. Gap: loop-free code reaches no poll, the gap
  [236](236-fiber-preemption.md) closes with polls at function entry. If 236 removes loop polls instead, the
  deferred wake reverts to waking at once.

  Measured with a probe: the time from a readying into an empty slot to the readier's next switch back to its
  carrier. On every handoff workload (`pingpong_fiber`, `pingpong_channel`, `stream_channel`, `forkjoin_fiber`,
  `mixed_fiber`) at 1 to 8 carriers, over 99.9% of readiers switched back within 1 µs; the deferred wake would
  drop those wakes (on 8 carriers 40,102, 29,274, 22,229, 48 and 4,330 system calls). `producer_fiber` is the
  opposite: the readier computes for about 20 µs, so each of its 20,000 wakes is needed.

  Built and measured, then set aside as more work than its place among the performance tasks warranted. What
  was built: an owed wake per carrier, counted in the poll's word (`rtStopWorld`: bit 0 the stop request, the
  rest twice the carriers owing), so the poll stayed one load and a branch; a park dropped it, and the poll's
  slow path made it once 1 µs old; a carrier whose owed wake a poll had to make woke at once afterwards, until a
  readying was followed by a park within the grace. Against waking at once: `pingpong_channel` on 8 carriers
  90 → 55 ns and CPU 707 → 57 ms; `stream_channel` and `fanin_channel` on 8 better; CPU lower nearly everywhere.
  Not universal: `pingpong_fiber` on 2 carriers slower (the readier passes two polls per hop, each a slow-path
  call while its wake is owed). What it needs before it returns:
  - **A cheap clock on a fiber** (shared with 254.1; the choice is [259](259-libc-or-own-per-routine.md) 259.4). Reading `cntvct_el0` inline costs 0.25 ns but is
    unordered: across threads it read up to 125 ticks (5 µs) behind a published value, past the 3 µs steal age,
    and slots were stolen early (`pingpong_channel` on 8 carriers 90 → 250 ns). A direct call of
    `mach_absolute_time` restored the baseline.
  - **A poll that skips the owing readier's own passes**, or fewer of them: in handoff loops the readier passes
    its loop-header poll between readying and parking.
  - **Large concurrent programs** to judge it by.
- **254.4** The context switch (from [250](250-fiber-task-surface.md) 250.8.2, which moved the callee-saved
  registers onto the fiber's stack). Two items, judged on P-core cycles from the hardware counters
  ([265](265-compiler-dev-loop.md)):
  - **The E-core gap.** On E cores the switch costs about 2% more cycles a hop than 250.8.1's record-based one;
    on P cores it costs fewer.
  - **The target's saved SP by value.** `rtSwitch` takes a pointer to the slot and starts with a dependent
    load, which delays resolving the `ret`'s misprediction. A prototype where the caller loads the SP early and
    passes the value made `pingpong_fiber` at 1 carrier 0.9 ns a hop faster than 250.8.1 (250.8.2: 0.4).
    `ctx_swap` and the scheduler test fixtures use the pointer form and need updating.
- **254.5** Fibers left queued on a busy carrier (from [104](104-fiber-stack-strategy.md) 104.5.2). A searcher
  that finds work wakes another only when its own local queue or the global queue still holds work
  (`rtSchedLoop`). Work left in another carrier's local queue gets no searcher, and with no preemption it waits
  until that carrier's fiber parks. Four compute-only tasks started together on 4 carriers ran on about 2: 158 ms
  against 300 on one carrier. Go wakes another searcher whenever a searcher finds work and none is left
  searching (`resetspinning`). That rule, tried as an experiment and reverted: the same tasks 84 ms;
  `deep_recursion` at 4 carriers 80 → 44 ms (Go 35). It adds wakes, so it meets 254.3's wake churn; judge it by
  254.3's acceptance (every scheduler benchmark at 1, 2, 4 and 8 carriers, wall and CPU time).

## Refs

[235](235-scheduler-run-queues.md) (the run queues, and the measurements these steps come from);
[236](236-fiber-preemption.md) (polls and preemption, which 254.3 depends on);
[237](237-handoff-primitives.md) (direct switches, which may close part of 254.1 and 254.2);
[250](250-fiber-task-surface.md) (`Task`, `select`, the fiber record); [104](104-fiber-stack-strategy.md) (stacks);
`src/stdlib/runtime/scheduler.nomu` (`rtSchedFind`, `rtSchedRun`, `rtSchedSteal`, `rtRunqSteal`, `rtSchedWake`);
`tools/schedbench.py`; `tools/pingpong.py`.
