# Handoff primitives: a direct switch, and the compiler marking handoffs

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design` ·
**Size:** M–L · **Status:** decided: runtime first (the deferred wake and a direct switch at park), the compiler's
marking only if a gap remains; **done**: 237.1–237.5, and the compiler's marking is not taken up (237.5) · **Source:** [234](234-scheduler-wake-and-pool.md)'s step two and
234.3

## Background

234 gave each carrier a run-queue slot: a fiber readied by a running fiber runs next on the same carrier.
Each readying still wakes a carrier (Go's `wakep`), in case the readier keeps running and the readied fiber
must move. From the readier's side there are three cases:

1. **It knows it parks next**: a fiber's completion readying its joiner, or a runtime operation that readies
   and parks in one call.
2. **It parks next, but nothing at the readying knows it**: a send followed by a receive, as in a
   ping-pong.
3. **It keeps running.**

Only case 3 needs the wake. Go's runtime sees one operation at a time, so it treats every readying as
case 3. Nomu's compiler sees the code after a readying.

## The two parts

- **Marking handoffs.** For each readying site, the compiler walks forward on every path to the first park,
  and marks the site when what lies between is bounded and short: no loops but small bounded ones, no calls
  through interfaces or function values, and only callees whose summaries say bounded and never blocking
  (the kind of summary 104 plans for stack bounds). A marked site readies without a wake. A wrong "no"
  costs a wasted wake; a wrong "yes" cannot happen.
- **A direct switch.** At a marked site the compiler emits one operation for the pair (send then receive),
  which hands the value over and switches straight into the partner: one context switch a hop instead of
  two, with no pass through the carrier loop. The operation does the loop's duties itself: the lock handoff
  across the switch, the carrier record's current fiber, the stop-the-world check, the slice, and the
  periodic run-queue check.

## Decision: the runtime first

Four ways were weighed:

1. **The compiler marks existing channel operations** (no new surface): a readying with a park on every path after
   it and only bounded, non-blocking work between skips its wake, and a send then receive becomes one operation
   that switches into the partner. Needs the forward walk and callee summaries, and has the cliff below.
2. **An explicit request-reply method on channels** (new API): no analysis and no cliff, but only code that uses
   it gains, and only the send-then-receive shape. A reply on actors is out: `concurrency.md` gives actors no
   reply.
3. **The runtime alone:** the deferred wake (from [254](254-scheduler-performance.md).3) and a direct switch at
   park. No surface and no analysis; it covers every shape, including those a compiler cannot prove, and
   cannot be lost by an edit.
4. **3 first, then 1** where a measured gap remains.

**Chosen: 4.** The priorities are long-term runtime performance and soundness: 3 serves every program with no
cliff, and [236](236-fiber-preemption.md) closed the gap that set the deferred wake aside (loop-free code now
reaches a stop at function entry, so a readier that keeps running reaches one within a loop chunk or a call).
The compiler's marking stays a later step, taken only if 237.4 leaves a gap it would close. 254.3 moves here.

## The design

- **The deferred wake.** A readying that only fills the readier's carrier's next slot owes a wake instead of
  making it: the carrier records the debt, and the readying raises the readier's own stop word (the request word,
  [236](236-fiber-preemption.md).3), so its next loop poll or entry check takes the slow path. A park drops the
  debt (the readied fiber runs here next); the slow path of a stop, a call into C (`rtEnterC`) and a yield to
  preemption fire it. A readying that leaves more work than the carrier takes next wakes at once, as today.
- **A direct switch at park.** A fiber parking while its carrier's slot holds a fiber switches straight into it,
  with no pass through the carrier loop: one context switch a hop instead of two. The switch does the loop's
  duties itself: the lock handoff across the switch, the carrier's running fiber (rec+64) and switch count, the
  stop-the-world check and arming (`rtSchedArm`), the slice, and the periodic look at the global queue.
- **Invariants** (each with a test in 237.2 or 237.3):
  - **I1. No lost wake.** Every readied fiber is run by the carrier that holds it in its slot, or another carrier
    is woken or searching. A debt is dropped only by a park that leaves its fiber this carrier's next pick.
  - **I2. Bounded deferral.** A debt fires within one stop of its readier: the raised stop word guarantees the
    next poll or entry check takes the slow path, and a call into C fires it before the call.
  - **I3. Stops are unchanged.** A stop-the-world reaches a fiber in a direct switch as it reaches one at a
    carrier switch: the switched-in fiber is armed (its limit raised when the world is stopping) before it runs.
  - **I4. One owner.** A fiber is on at most one carrier, slot or queue at a time; the direct switch takes the
    slot's fiber under the same protocol a pick does, so a stealer cannot take it at once.
  - **I5. The monitor still sees runs.** A direct switch counts as a switch (rec+200), so the monitor's age of a
    run starts over, as at any switch.

## Phases

- **237.1 Baselines.** **Done** (below). Every scheduler workload (`tools/schedbench.py`: the ping-pongs, `stream_channel`,
  `fanin_channel`, `forkjoin_fiber`, `producer_fiber`, `mixed_fiber`, `idle_fiber`, `sleepers_fiber`, the actor
  workloads, `server_sim`) at 1 / 2 / 4 / 8 carriers, wall time and CPU time, median of 5; the binary kept for A/B
  runs.
- **237.2 The deferred wake.** **Built** (below); `NOMU_DEFER_WAKE` sets the stops it waits out, 0 turns it
  off. Planned tests, with I1, I2 and I5: suite cases for a readier that computes after
  readying (one carrier and several), one that enters C after readying, one that is preempted after readying,
  and one that readies and parks; under the stress legs.
- **237.3 The direct switch.** **Built** (below); `NOMU_DIRECT_SWITCH=0` turns it off. Planned tests, with I3
  and I4: a stop-the-world requested during handoff chains, a
  stealer racing the slot, stack moves at the switched-in fiber's resume.
- **237.4 Verify.** **Done** (below: "237.4 so far" and what follows it). Every workload equal or better than
  before 237 but one: `fanout_actor` on 8 carriers spreads small jobs 4% slower in steady state (up to 19% on the
  single round that follows its no-work round, which measures carriers ramping up); carried to
  [254](254-scheduler-performance.md). The full suite tier passes three rounds (4,220 runs, each 3 / 3). 254.3's bar: equal or better than 237.1 on every workload at every carrier count, in wall time
  and CPU time, beyond run-to-run noise; the suite at the full tier, three rounds. A workload that loses is
  fixed or the part that costs it is not kept.
- **237.5 Fold.** **Done.** The design is in `runtime.md` §1.1 (run queues, the slot and its age, wakes, the
  deferred wake, the direct switch), §3 (the remote wake) and §6 (the monitor ages runs), and
  `selfhosted-scheduler.md` (the direct switch in the lock-handoff park; work-stealing built). The compiler's
  marking (option 1) would close no measured gap, so it gets no task:
  - **Case 2, a readier that parks next.** The runtime already drops its wake: `pingpong_channel` on 8 carriers
    uses 61 ms of CPU against 52 on one, so 9 ms is all a marked site could still save there.
  - **Case 3, a readier that keeps running.** A marked site would wake at once and skip the three slow-path stops
    the deferred wake costs it. `stream_channel` with the deferred wake off (the same as waking at once) is
    20.9 / 22.9 / 33.6 ns at 2 / 4 / 8 carriers against 20.8 / 23.0 / 33.7 with it, at the same CPU.
  - **The direct switch** is already made at every lock-coupled park; a fiber hop is 9.7 ns on one carrier.
  
  The gaps left are in stealing and aging (`fanout_actor`, carried to 254.7), which readying sites do not touch.

## What was built

**The deferred wake (237.2).** As designed, with two changes the measurements forced:
- **Pay at the third stop, not the first.** A readier on its way to a park passes stops first: the entry checks
  of the channel wrappers between a send's readying and the receive that parks. Paid at the first stop, nearly
  every handoff woke a carrier anyway (`pingpong_channel` CPU on 8 carriers 1,021 → 945 ms only). The owed wake
  counts down the readier's stops (rec+248) and is paid at the third; until then each slow path raises the limit
  again. Three is the fewest that lets a send then a receive drop it. Paying once the readier had run past the
  slot's steal age (3 µs) was tried and dropped: every call in that window took the slow path and read the clock,
  and `stream_channel` went from 20 to 70 ns a value.
- **No debt when no carrier sleeps.** The wake does nothing then, and owing it only cost the readier its stops
  (`pingpong_channel` on one carrier 59 → 68 ns before this).

A call into C pays at once; a park, an end or an idle mailbox fiber drops the debt when its carrier settles the
fiber (`rtSchedRun`), and any other leaving pays it. The stack check pays only when no move is needed (the reserve
is free); a move's carrier pays it on its own stack.

**The direct switch (237.3).** As designed, from the two lock-coupled parks (`nomuSchedParkReleasing`, which
channels use, and `nomuSchedParkLocked`). Every place a fiber resumes passes the switch's message to
`rtSchedResumed`, which releases a lock handed over; `rtSchedRun` reads the fiber that switched back from the
carrier record.

**Tests.** `deferred-wake` and `deferred-wake-no-preempt` (`tests/fixtures/deferred_wake`: a ping-pong, a readier
that spins without parking, task joins; with preemption off a lost wake hangs the run, checked by a build that
dropped paid wakes, which timed out); `handoff-stress` and `handoff-stress-no-preempt`
(`tests/fixtures/handoff_stress`: eight pairs passing messages under back-to-back collections, a fiber just
switched in growing its stack). The suite's `preempt` and `defer_wake` run settings select the cases. The full
suite passes.

**Measured** (`tools/schedbench.py`, median of 5, ns per hop or value and CPU ms at 1 / 2 / 4 / 8 carriers; `neither`
is both off, as 237.1):

| workload | both | direct switch only | neither |
|---|---|---|---|
| `pingpong_channel` ns | 53.1 / 62.1 / 62.4 / 62.6 | 52.8 / 55.8 / 59.1 / 104.9 | 59.4 / 61.8 / 65.9 / 102.6 |
| its CPU | 55 / 64 / 64 / 65 | 55 / 114 / 238 / 804 | 62 / 125 / 266 / 795 |
| `stream_channel` ns | 20.8 / 22.2 / 24.5 / 33.8 | 20.5 / 22.1 / 24.2 / 35.2 | 20.6 / 21.5 / 23.6 / 33.4 |
| its CPU | 86 / 176 / 349 / 556 | 85 / 175 / 352 / 638 | 85 / 171 / 348 / 658 |
| `fanin_channel` CPU | 89 / 1,471 / 959 / 1,780 | 91 / 1,492 / 959 / 1,984 | 90 / 1,504 / 940 / 1,934 |

The other workloads are even within noise. Rerun at a median of 11 on 2 / 4 / 8 carriers, three small regressions
hold, both against neither: `stream_channel` 22.1 / 24.5 / 34.1 against 21.6 / 23.7 / 33.3 ns (its CPU on 8:
584 against 663 ms); `pingpong_fiber` 31.7 / 34.1 / 65.5 against 30.9 / 33.3 / 63.7 ns, CPU 2–3% more; `mixed_fiber`'s
pair on 8 carriers 19.2 against 18.2 ms, CPU 151 against 144 ms. 237.4 resolves them: the stream's cost is its
slow paths before each paid wake (a readier that keeps running pays three stops for nothing); `pingpong_fiber`
and `mixed_fiber` hand off through `nomuSchedParkLocked`, so their cost is the direct switch's own.

### 237.4 so far: no clock on a switch

The direct switch was slower than the carrier's round trip on `stream_channel` (about 17 ns a switch). Most of it
was the clock read the switch made, for the slot's steal age (rec+112) and the slice check (rec+120): on a fiber's
stack `mach_absolute_time` goes through the libc stack switch. A clock's cost differs across platforms and setups
(a vDSO call on Linux, a system call where the clock source needs one; reading the ARM counter register directly
here doubled every workload's time), so no switch reads it now, as in Go:

- **The slice is a run, and the monitor ends it.** A fiber switched in from a queue begins a run (rec+112, the run
  count); a fiber taken from the slot, by a pick or a direct switch, continues it. The monitor ages runs instead of
  switches, so a chain of handoffs is aged as one fiber computing alone is (Go's `schedtick`, which an inherited
  slice does not bump, read by `sysmon`). A fiber in the slot counts as work waiting only when its carrier has not
  switched since the last tick; a handoff chain's slot refills at every hop. When the monitor preempts a run, its
  carrier moves the slot's fiber behind its queued work, which is what the slice's end did.
- **A searcher ages the slot itself** (`rtSlotAged`): it watches one carrier at a time, and takes the fiber in its
  slot once that carrier's switch count stays unchanged for the steal age by the searcher's own clock (Go's stealer
  waits 3 µs before taking another processor's `runnext`).

Tried and dropped: marking a slot stranded when a deferred wake was paid, or when its readying woke a sleeping
carrier, so a searcher could take its fiber without the watch. A stream's producer pays its three stops within a
fraction of a microsecond, so searchers took the consumer and split the pair (`stream_channel` 34 → 42 ns on 8
carriers).

Found on the way: `pingpong_fiber`, `mixed_fiber` and `producer_fiber` held the scheduler lock across loops and
calls in their own code; with runs aged as a whole, the monitor's preemption reached them there and the fiber
deadlocked on the lock its yield takes (`mixed_fiber` hung). The benchmarks now take the lock only for straight
code. Ordinary programs cannot hold it, and the runtime's own code has no stops.

Suite case `handoff-fair`: a pair handing off through direct switches starts a compute fiber and hands off until it
finishes; on one carrier it ends only if the monitor ends the chain's run (with preemption off it hangs).

Against 237.1 (`tools/schedbench.py`, median of 7; `SCHEDBENCH_NOMU` builds with the kept compiler), at 1 / 2 / 4 / 8
carriers, with the steal age at 3 µs and at 1 µs (`NOMU_SLOT_STEAL_NS`):

| workload | 237.1 | now, 3 µs | now, 1 µs |
|---|---|---|---|
| `pingpong_fiber` ns | 28.5 / 29.9 / 33.7 / 64.0 | 10.2 / 11.3 / 12.4 / 27.9 | 10.6 / 11.4 / 12.4 / 30.4 |
| `pingpong_channel` ns | 60.2 / 62.1 / 65.4 / 108.8 | 53.9 / 59.8 / 59.8 / 60.1 | 51.2 / 59.3 / 60.6 / 59.8 |
| its CPU ms | 62 / 126 / 264 / 835 | 57 / 63 / 63 / 71 | 54 / 63 / 64 / 64 |
| `stream_channel` ns | 20.4 / 21.5 / 23.5 / 34.5 | 21.0 / 22.7 / 24.9 / 35.1 | 20.8 / 22.7 / 25.1 / 32.0 |
| its CPU ms | 84 / 170 / 345 / 672 | 87 / 179 / 369 / 831 | 86 / 179 / 333 / 435 |
| `producer_fiber` wait p50 / p99 µs, 2–8 carriers | 5 / 8 | 8 / 12–14 | 7 / 10–12 |
| its CPU ms, 2–8 carriers | 508–523 | 599–618 | 566–571 |
| `mixed_fiber` pair ms (1 carrier) · CPU ms (8) | 63.6 · 148 | 56.1 · 77 | |

The steal age stays at 3 µs, Go's; 1 µs is recorded as a candidate in [258](258-runtime-policy-tuning.md).7, to
measure once the workloads that would show its cost can be written (readiers that work briefly before they park,
servers on [255](255-networking.md)'s networking).

Open: `producer_fiber`'s stranded wait and CPU (a readier that keeps computing after each readying; it readies
through the scheduler directly, so the deferred wake does not apply), and `stream_channel`'s 1–1.5 ns at 2 and 4
carriers.

**The direct switch's own cost on streams: fixed.** It made its switch inside `rtSchedDirectTarget`, so a parked
fiber resumed one call frame deeper than an ordinary park, and returning through that frame after the other fiber's
calls missed the return predictor (4.5% on `stream_channel`, one carrier). The helper now only prepares the target;
the park function makes the one switch, to the target or the carrier.

**Latest, against 237.1** (median of 7, 1 / 2 / 4 / 8 carriers; the white-box benchmarks rerun on both compilers
with the lock fix):

| workload | 237.1 | now |
|---|---|---|
| `pingpong_fiber` ns · CPU ms | 30.4 / 32.4 / 34.0 / 65.3 · 63 / 132 / 274 / 1,006 | 10.2 / 11.1 / 12.5 / 27.7 · 22 / 46 / 102 / 428 |
| `pingpong_channel` ns · CPU ms | 60.2 / 62.1 / 65.4 / 108.8 · 62 / 126 / 264 / 835 | 51.5 / 57.5 / 57.5 / 57.8 · 55 / 60 / 60 / 61 |
| `stream_channel` ns · CPU ms | 20.4 / 21.5 / 23.5 / 34.5 · 84 / 170 / 345 / 672 | 20.4 / 21.1 / 23.1 / 33.6 · 85 / 167 / 345 / 846 |
| `fanin_channel` ns (8) · CPU ms (8) | 111 · 1,978 | 96 · 1,565 |
| `mixed_fiber` pair ms · CPU ms | 68.1 / 36.7 / 21.6 / 19.1 · 71 / 76 / 89 / 150 | 3.9 / 26.1 / 13.4 / 4.5 · 63 / 62 / 71 / 64 |
| `server_sim` light p99 µs · CPU ms | 459 / 262 / 328 / 328 · 172 / 230 / 247 / 237 | 262 / 229 / 229 / 229 · 145 / 161 / 169 / 189 |
| `idle_fiber` CPU ms | 20 / 31 / 35 / 36 | 17 / 23 / 29 / 30 |
| `producer_fiber` wait p50 / p99 µs (2–8) · CPU ms | 5 / 8–10 · 536–552 | 8 / 12–14 · 592–625 |
| `fanout_actor`, 0 and 100 ns of work, 8 carriers | 123, 180 ns | 156, 230 ns |
| `pingpong_actor` ns | 13.4–13.5 | 13.8 |
| `pipeline_actor`, no work, 2 carriers | 142 ns | 172 ns (better at 4 and 8: 79, 235 against 93, 320) |

**A take keeps the searcher's watch.** The actor rows and `producer_fiber` held at a median of 11 against a
compiler built from before 237 (`fanout_actor` on 8 carriers 131 → 155 ns with no work; `pipeline_actor` on 2
carriers 148 → 164 ns), and held with the deferred wake and the direct switch both off, so the clock removal was
the cause. A variant of `fanout_actor` repeating its no-work round 300 times showed it plainly on 8 carriers: 256 →
408 ns a job, system time 6 → 14.5 s. `rtSchedSteal` cleared the searcher's watch when it took a slot's fiber, so
the next fiber the same readier stranded waited a fresh 3 µs: a toll per fiber, where the stamp at the switch-in
had aged the slot once per run. The hub readies a worker into its slot at nearly every send, and `producer_fiber`'s
producer strands its consumer again and again. Keeping the watch (the count unchanged means the same readier
still runs) brings the variant to 262 ns, the baseline's 256.

Tried and dropped on the way: a carrier about to sleep waiting out the steal age on a watched slot (`fanout_actor`
worse, 185 / 234 / 298 ns at 0 / 10 / 100 work on 8 carriers; `stream_channel`'s CPU on 8 carriers 963 ms); one
taking up the search instead of sleeping (no change); a searcher that found work passing the search on for a slot
at any age (no change once the watch is kept).

After it, against a compiler built from before 237 in the same session (median of 15, 1 / 8 carriers; the other
workloads at a median of 7 are even or better, as in the table above):

| workload | before 237 | now |
|---|---|---|
| `fanout_actor` ns, 0 / 10 / 100 / 1,000 work, 8 carriers | 131 / 165 / 209 / 181 | 127 / 167 / 194 / 167 |
| `pipeline_actor` ns, 0 / 100 work, 8 carriers | 304 / 434 | 251 / 394 |
| `pipeline_actor` ns, 0 / 100 work, 2 carriers (median of 7) | 147 / 359 | 150 / 379 |
| `producer_fiber` wait p50 / p99 µs (2–8) · CPU ms | 5 / 8 · 529–534 | 5 / 8 · 525–538 |
| `pingpong_actor` ns | 13.7–13.9 | 13.7 |
| `stream_channel` ns · CPU ms, 8 carriers | 34.4 · 640 | 33.8 · 807 (fixed below) |

**The slot's age is stamped by its observers.** `stream_channel`'s CPU on 8 carriers (+26%) was search spin: with
the steal age at 1 µs it was 424 ms, with a 5 µs search window 573 ms, and the deferred wake and the direct switch
did not change it. Event counts (a temporary probe, on both compilers, 8 carriers): both woke about as many
searchers (28,000–33,000 search windows), but the baseline's found a slot to take in 6,500–10,900 of them and the
watch's in 2,000, so the rest spun out their 20 µs (spin 475 against 660 ms). The stamp had aged the slot from the
carrier's switch; a watch ages it from the searcher's first look, which comes a wake's latency after the readying
that woke it, so on a stream the producer's run rarely reached the steal age.

So the age now runs from a first-seen word on the watched carrier (rec+256, `rtSlotSeen`): the first observer to
see a new switch count records it with its own clock, and every observer measures from there. The carrier that
wakes a searcher stamps itself (a wake is a system call, so the clock read beside it costs nothing); the monitor
stamps every carrier at each tick, and a searcher stamps a carrier with a full slot once two of its looks in a row
saw the same count there, with the time of the first (it keeps its last look in its own record). No switch reads the
clock. A take leaves the word alone, so the kept watch's fix holds. The record grew to 320 bytes so the word's line,
which observers write, holds nothing else. With it: spin 414–441 ms, user CPU 0.59 s against the baseline's
0.60–0.63.

Tried and dropped: searchers stamping every carrier as they pass, empty slots too (`fanout_actor` on 8 carriers
146 / 192 ns at 0 / 10 work against the baseline's 132 / 160, from the cache traffic on busy carriers' records);
searchers looking every 250 ns instead of every microsecond (little change).

Against the baseline, back to back (median of 11, 1 / 2 / 4 / 8 carriers):

| workload | before 237 | now |
|---|---|---|
| `stream_channel` ns · CPU ms | 20.8 / 21.8 / 23.7 / 34.5 · 86 / 173 / 346 / 672 | 20.7 / 21.8 / 24.2 / 33.4 · 86 / 172 / 346 / 680 |
| `fanout_actor` ns, 0 / 10 / 100 work, 8 carriers | 130 / 164 / 186 | 137 / 176 / 183 |
| `pingpong_fiber` ns, 8 carriers | 64.9 | 33.2 (27 with the kept watch alone) |
| `pingpong_actor` ns | 13.6–13.7 | 14.0–14.2 |
| `mixed_fiber` pair ms · CPU ms, 8 carriers | 19.9 · 157 | 4.5 · 64 |

That table is from searchers stamping at their first look. It cost `pingpong_fiber` on 8 carriers 33 ns against
27 with the kept watch alone: searchers spinning beside a handoff chain wrote its record's word about once a
microsecond each, since the count changes at every hop. `pingpong_actor` was 3–4% slower at every carrier count,
one included; without the monitor's stamping it was 7–9% slower, so that swing follows code layout more than this
code's work. The two-look rule keeps searchers off a chain's record. Against the baseline, back to back (median of
11, 1 / 2 / 4 / 8 carriers):

| workload | before 237 | now |
|---|---|---|
| `pingpong_fiber` ns · CPU ms, 8 carriers | 67.1 · 1,027 | 28.4 · 433 |
| `pingpong_actor` ns | 13.3–13.6 | 13.5–13.8 |
| `stream_channel` ns · CPU ms, 8 carriers | 34.1 · 628 | 33.7 · 681 (the baseline's CPU ran 628–672 across this session) |
| `producer_fiber` wait p50 / p99 µs (2–8) · CPU ms | 6 / 8 · 532–538 | 5 / 8 · 517–534 |
| `fanout_actor` ns, 0 / 10 / 100 work, 8 carriers | 129 / 159 / 203 | 140 / 190 / 188 |

`fanout_actor`'s 10-work round on 8 carriers held at 176–196 ns across every stamped version (167 with the kept
watch alone). That round follows the no-work round, so it measures carriers ramping up as much as spreading. A
variant repeating only that round 300 times: 254 ns a job against the baseline's 244 (+4%).

The full suite tier passes three rounds. `fanout_actor`'s ramp after its no-work round (+4% steady, up to 19% on
the single round) goes to [254](254-scheduler-performance.md).

### 237.1 results: the baselines

`tools/schedbench.py`, median of 5, at 1 / 2 / 4 / 8 carriers, before 237's changes:

| workload | metric | 1 / 2 / 4 / 8 |
|---|---|---|
| `pingpong_fiber` | ns per hop · CPU ms | 28.5 / 29.9 / 33.7 / 64.0 · 59 / 121 / 272 / 992 |
| `pingpong_channel` | ns per hop · CPU ms | 56.9 / 62.1 / 65.0 / 107.2 · 59 / 126 / 262 / 825 |
| `stream_channel` | ns per value · CPU ms | 20.4 / 21.4 / 23.2 / 34.3 · 84 / 170 / 346 / 683 |
| `fanin_channel` | ns per value · CPU ms | 20.2 / 179.9 / 78.7 / 112.8 · 84 / 1,445 / 921 / 1,992 |
| `forkjoin_fiber`, no work | ns per fiber · CPU ms | 185 / 308 / 372 / 709 · 41 / 51 / 71 / 180 |
| `producer_fiber` | wait p99 µs | 918 / 8 / 8 / 8 |
| `mixed_fiber` | pair ms · CPU ms | 63.6 / 35.3 / 13.1 / 18.7 · 66 / 73 / 72 / 148 |
| `server_sim` | light p99 µs · CPU ms | 459 / 262 / 262 / 262 · 234 / 249 / 274 / 302 |
| `pingpong_actor`, `fanout_actor`, `pipeline_actor`, `sleepers_fiber`, `idle_fiber` | | in `tools/schedbench.py`'s output; unchanged by 237 within noise |

## Measured so far

From 234 (ns per hop at 2 / 4 / 8 carriers): the fiber ping-pong with a wake at every readying is 27 / 49 /
52; with no wake (a probe) it is about 22–26 at every count. The register swap is 6 ns a switch; a hop is
two switches and a pass through the carrier loop.

## The cliff

A small edit can lose a site's mark, as an edit can make a Go variable escape or put a function over Go's
inlining budget. The loss is bounded: the wake (case 2 handled as case 3) and one switch a hop. The perf
report should list readying sites and why each did or did not get the fast path, as `-gcflags=-m` does for
Go's escape and inlining decisions.

## Dependents

- **[254](254-scheduler-performance.md)** (scheduler performance) waits on this task: a direct switch skips the
  run queue, the pick and the wake that 254 tunes.

## Refs

234's step two and 234.3 (the cases, the measurements, the cliff discussion);
`src/stdlib/runtime/scheduler.nomu` (`rtSchedReadyNext`, `rtSchedPick`); [104](104-fiber-stack-strategy.md)
(call-tree summaries).
