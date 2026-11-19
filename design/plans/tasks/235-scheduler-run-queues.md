# Scheduler: one run queue under one lock

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · done` ·
**Size:** M–L · **Status:** done — 235.1 to 235.6 and 235.9 built; 235.4.2, 235.7 and 235.8 moved to
[254](254-scheduler-performance.md) · **Source:** [234](234-scheduler-wake-and-pool.md).3's
workloads

## Observed

Every carrier takes runnable fibers from one global run queue (sched+0/8), and every mailbox fiber takes
scheduled mailboxes from one global queue (sched+80/88), both under the one scheduler lock (sched+256).
Every readying, spawn, park, pick, send that schedules a mailbox, and mailbox pop takes that lock. 234's
run-queue slot keeps a handing-off pair off the shared queue, but work that spreads across carriers goes
through it.

## Cost

Short jobs get slower as carriers are added (`tools/schedbench.py`, median of 5; ns per item or job, at
1 / 2 / 4 / 8 carriers):

| workload | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| `pipeline_actor`, no work per stage | 171 | 309 | 355–452 | 577–603 |
| `fanout_actor`, no work per job | 36 | 65–72 | 78–82 | 115–129 |
| `fanout_actor`, about 0.8 µs per job | 848 | 466 | 265 | 472 |

With about 0.8 µs of work per job, eight carriers finish later than four; with about 8 µs per job, the
fan-out scales evenly to eight (7,672 → 1,157 ns). The lock is held for a few ns each time; past four
carriers its cache line and the queues' lines move between cores on every operation. The lock was ruled
out for ping-pong in 234 (2.3 ns a pair, no growth with carriers); this is the parallel load 234 left
unmeasured.

Channels show it too ([102](102-channels.md) 102.4): four senders to one receiver over a buffered channel take
21.9 ns per value on one carrier and about 104 on eight, against Go's 55.6. After 102.2 the profile's remaining
waits are carriers taking the scheduler lock after a switch (`rtSchedSwitchedBack`) and wakes readying fibers
under it (`rtChanWake`). 102.6 counted it: the single receiver, the bottleneck, readies a parked sender under the
scheduler lock while the senders' carriers hold it to pick, and a readying wakes an idle carrier with a futex
system call 80,000 to 130,000 times in 4M values. Results swing from run to run with where the fibers land
(2 carriers: 40.5 or 107.6 ns). A fix must take readying off the global lock and wake a carrier only when
none is searching and the readied fiber cannot run where it was readied.

## Constraints on a fix

- **Go's design** is a local run queue per processor (256 entries, lock-free, the owner pushing and
  popping and others stealing half), the global queue only for overflow and fairness (checked every 61
  picks), and `runnext` (234's slot). Its scheduler lock is taken only for the global queue and idle lists.
- **The lock-coupled park** (`concurrency.md` §2) has a fiber switch to its carrier holding the scheduler
  lock, so that a waker, which must hold the same lock to enqueue, cannot run the fiber before its context
  is saved. A channel already parks holding only its own lock, which the carrier releases after the switch
  (`nomuSchedParkReleasing`, 102.2); the carrier then takes the scheduler lock only to pick. Local queues need another way to order a park against a readying: a per-fiber state word a
  waker sets with a compare-and-swap, as Go's goroutine status is.
- **The mailbox queue** needs the same treatment, or its own split, since the actor workloads above go
  through it.
- **A searcher that never stops** (moved from 234). When mailboxes stay queued behind a busy drainer that
  pops them before they age (`NOMU_MBOX_AGE_NS`), an idle carrier claims the search, spins its window,
  finds nothing old enough, and claims it again (`rtSchedMboxBecomeSearcher`), burning a core for as long
  as the backlog lasts. No workload showed it in CPU time. Reworking the mailbox queue changes this code;
  the rework should bound the search (Go caps spinning threads at half the busy processors).
- **The stop-the-world walk** enumerates fibers through the registry, which does not depend on the queues.
- 234.3's settings and workloads measure the change: the slot, the steal age and the search still apply,
  with a local queue between the slot and the global queue.

## Design

Go's model, decided over a lighter step because performance comes first:
- **Local run queues.** Each carrier owns a bounded lock-free ring (256): the owner pushes and pops, an idle
  carrier steals half, and overflow moves half to the global queue. Chosen over a per-carrier deque under its own
  mutex, which is simpler but costs two atomics on every operation.
- **`runnext`.** The carrier's slot becomes atomic; readying a fiber on a carrier puts it there and moves the one
  it displaces to the local queue, with no global lock.
- **The global queue** takes overflow and readyings from off a carrier (timers, the poller), and is checked every
  61 picks for fairness.
- **Parks release their lock after the switch.** Every park holds only the lock guarding its condition, which
  the carrier releases once the fiber's context is saved (`nomuSchedParkReleasing`, from 102.2). No readying then
  needs the scheduler lock to be ordered after a park, unless the scheduler lock is what guards its condition.
- **Waking** keeps 234's policy, Go's `wakep`: wake an idle carrier only when none is searching.
- **The mailbox queue folds in.** Scheduling a mailbox readies a mailbox fiber into the local queue, so actors
  get the local queues and stealing, and the second global queue and its never-stopping searcher go.

## Steps

- **235.1** Baseline. **Done.** `tools/schedbench.py` now includes the channel workloads. Median of 7, default
  build, ns per item:

  | workload | 1 | 2 | 4 | 8 carriers |
  |---|---:|---:|---:|---:|
  | `pingpong_fiber` | 24.9 | 29.8 | 52.6 | 59.0 |
  | `pingpong_actor` | 19.1 | 19.1 | 19.1 | 19.0 |
  | `fanout_actor`, no work | 36.2 | 79.1 | 89.8 | 130.4 |
  | `fanout_actor`, 1 µs jobs | 789 | 427 | 247 | 486 |
  | `fanout_actor`, 10 µs jobs | 7,600 | 3,912 | 2,128 | 1,119 |
  | `forkjoin_fiber`, no work | 348 | 500 | 615 | 1,439 |
  | `forkjoin_fiber`, 10 µs leaves | 4,101 | 2,323 | 1,412 | 1,575 |
  | `pipeline_actor`, no work | 169 | 329 | 490 | 583 |
  | `pingpong_channel` | 48.6 | 53.1 | 72.2 | 80.5 |
  | `stream_channel` | 21.9 | 22.9 | 25.5 | 29.5 |
  | `fanin_channel` | 22.1 | 92.0 | 104.9 | 116.0 |
  | `sleepers_fiber`, total ms (floor 20) | 22.3 | 22.3 | 27.8 | 42.8 |

  Go, from `tools/pingpong.py` (best of 7): `go chan` 85.5 / 82.9 / 100.3 / 100.7, `go stream` 21.2 / 26.8 /
  27.6 / 29.3, `go fanin` 21.2 / 32.8 / 53.3 / 55.6. Short work gets slower with every carrier added, and
  fork-join with 10 µs leaves is slower on 8 carriers than on 4.
- **235.2** Every park releases its lock after the switch. **Done.** A fiber now runs and resumes without the
  scheduler lock: the carrier releases it before switching in, and every resume point stopped releasing it.
  A fiber switches back either holding the scheduler lock (sleep, join, stdin, the collector's stops, a
  finished fiber) or naming its own lock in the record's release word (channels); the carrier releases what
  it was given (`rtSchedSwitchedBack`). The state word turned out unnecessary: a waker must take the lock the
  parker released to find it, so that lock alone orders the two, and the parks that name the scheduler lock
  stay correct once the run queues leave it. Moving sleep and stdin onto their own locks is a later choice.
  The suite passes plain and under both stack-move settings, and the scheduler, channel, actor and fiber cases
  20 of 20 repeats.
- **235.3** Local run queues and an atomic `runnext`. **Built; regressions open below.** Each carrier record (now
  192 bytes) has a ring of 256 fibers (head, tail, ring at +128/+136/+144); the slot at +104 is taken by
  compare-and-swap. `rtSchedReadyOn` readies into the slot with no lock, the displaced fiber to the ring; a spawn
  joins the ring's tail; off a carrier (timers, the poller, boot) both go to the global queue. `rtSchedFind` picks
  slot, ring, global (and the global first every 61 picks), then steals half a ring (`rtRunqSteal`, Go's
  `runqgrab`) or an aged slot, all without the lock. Channel wakes take no lock. The idle path (mailbox, search,
  sleep) keeps the lock; a carrier about to sleep counts itself sleeping, then rechecks the global queue and every
  ring and slot, and a readier pushes, then reads the count, so one sees the other. Stealing is part of this step,
  since a ring without it can strand a fiber behind a busy carrier. The suite passes plain and under both
  stack-move settings, and the concurrency cases 30 of 30.

  Median of 7, ns per item, against 235.1:

  | workload | 1 | 2 | 4 | 8 carriers |
  |---|---:|---:|---:|---:|
  | `fanin_channel` | 22.9 (22.1) | 25.2 (92.0) | 25.6 (104.9) | 106.6 (116.0) |
  | `forkjoin_fiber`, no work | 213 (348) | 460 (500) | 549 (615) | 1,134 (1,439) |
  | `mixed_fiber` pair, ms | 68.6 (61.2) | 12.0 (38.5) | 12.8 (35.1) | 26.5 (30.9) |
  | `pipeline_actor`, no work | 168 (169) | 299 (329) | 304 (490) | 601 (583) |
  | `pingpong_fiber` | 27.1 (24.9) | 31.2 (29.8) | 44.5 (52.6) | 103.6 (59.0) |
  | `pingpong_channel` | 58.0 (48.6) | 60.1 (53.1) | 63.3 (72.2) | 97.7 (80.5) |

  Fan-in now beats Go on 2 and 4 carriers (32.8, 53.3); 235.6 found this rested on the lost wake 235.4.3 fixed
  (see 254.2). Two regressions:
  - **Eight carriers.** Counted on `pingpong_channel`: 30,369 carrier wakes (a futex system call each) and 32,361
    sleeps in 1M hops, 95,449 idle steps, each taking the scheduler lock, and 418 slot steals that split the
    pair across carriers. Woken carriers find nothing, sleep, and the next readying wakes one again; the profile
    is mostly idle carriers reading the clock. That is 235.4's policy.
  - **One carrier**, 5 to 9 ns a hop beyond machine drift (`pingpong_actor` moved 1.6). The profile shows no
    single cause: the pick and run are now separate calls through the runtime's stubs, and the clock read on
    every pick is 13% of the busy samples.
- **235.4** The idle and searching carriers (`wakep`), with the searcher bounded: the eight-carrier regression
  of 235.3. (Stealing itself went into 235.3.) Counted on 8 carriers (`pingpong_channel`, 1M hops /
  `pingpong_fiber`, 2M): 31,380 / 28,468 carrier wakes; 31,881 / 20,390 searches that spun their whole 20 µs
  window and found nothing; 99,921 / 101,800 idle steps, each taking the scheduler lock; 982 / 14,143 slot steals.
  - **235.4.1** The idle path without the scheduler lock. **Done.** Only readying a mailbox fiber takes it; a
    carrier about to sleep counts itself sleeping, then rechecks the global head (now stored atomically), the
    mailbox queue and every ring and slot. The locked idle steps held up readiers that need the lock, whose
    slots then aged and were stolen, splitting the pair. `pingpong_fiber` on 8 carriers 103.6 → 55.7 ns (235.1:
    59.0), on 4 44.5 → 32.0 (52.6); `pingpong_channel` on 8 97.7 → 90.5 (80.5).
  - **235.4.2** Wake churn: nearly every wake on several carriers is wasted. A deferred wake was built,
    measured and set aside; moved to [254](254-scheduler-performance.md).3 with its measurements.
  - **235.4.3** A lost wake. **Done.** `sleepers_fiber` on 4 carriers stalled about one run in ten for 1 s,
    the idle sleep's timeout: a fiber on the global queue, every carrier asleep, and the search flag raised with
    no carrier searching, so every readier skipped the wake. A waker read the sleeping count, a carrier then
    left its sleep and read the flag clear, and the waker's swap raised it for a searcher that never came. The
    waker now reads the sleeping count again after the swap and drops the flag when it is 0. 75 runs on 2, 4 and
    8 carriers, worst 35 ms.
- **235.5** The mailbox queue folded into the run queues, measured on the actor workloads. Baseline, median of 7,
  against Go's counterparts (`practice/go/pingpong`, a goroutine per actor with a buffered channel as its
  mailbox; best and worst of 5, GOMAXPROCS as carriers):

  | workload | 1 | 2 | 4 | 8 carriers |
  |---|---:|---:|---:|---:|
  | `pingpong_actor` | 19.3 | 19.2 | 19.2 | 19.1 |
  | `go mailbox` | 82–88 | 93–98 | 110 | 111–113 |
  | `fanout_actor`, no work | 35.9 | 80.3 | 81.7 | 123.9 |
  | `go fanout` | 37–42 | 65–82 | 60–73 | 86–104 |
  | `pipeline_actor`, no work | 165 | 332 | 453 | 622 |
  | `go pipeline` | 164–167 | 128–185 | 106–122 | 102–116 |

  Actors also run on one carrier at a time: `pipeline_actor` with 1,000 iterations a stage takes 6,045 ns an
  item on 1 to 8 carriers, since a send wakes a carrier only when no mailbox fiber is draining, and that one
  drains every stage.
  - **235.5.1** Mailboxes as run-queue entries. **Done.** A run-queue entry is a fiber, or a mailbox tagged in its
    low bit. A send that schedules a mailbox readies the tagged mailbox like a fiber: into the carrier's slot, the
    displaced entry to the ring, stealable. A carrier that picks a mailbox runs it on its idle mailbox fiber
    (rec+160; the rest pooled at sched+104, no cap), which drains it and then the next mailbox in the carrier's
    slot without a switch, up to 64 in a row. A handler that parks keeps its fiber; the carrier takes another.
    A full ring sends a mailbox to a global mailbox queue (sched+80/88, linked through `sched_next`) beside the
    global fiber queue, so a backlog of scheduled actors costs entries, not fiber stacks (a first version bound
    each overflowing mailbox to a fiber: 1,744 fibers in `gc_actor`). The collector roots the tagged entries:
    the walk untags each in place, roots the word, and re-tags it after the collection through the derived
    pointers' fix (`rtRootsAddFixup`). The drainer count, the mailbox searcher and its aging
    (`NOMU_MBOX_AGE_NS`) are gone.

    Waking: a send that leaves the mailbox alone in the slot from a mailbox fiber wakes no carrier, since the
    sender's fiber drains it next once its own mailbox empties; if the drain goes on instead, its next message pop
    wakes a carrier to steal the waiting mailbox. Waking on every such send took `pingpong_actor` on 8 carriers
    from 19 to 254 ns a hop: the wakes slowed each hop, the slot aged past the steal age, and searchers split the
    pair across carriers.

    `gc_actor` now reports each actor's sum to a tally actor, since the order in which actors run is the
    scheduler's; it and `gen-mc-actor` fail with the run-queue walk or the global mailbox queue's root removed.
  - **235.5.2** Each mailbox's message list without the scheduler lock. **Done.** Vyukov's intrusive queue for
    many senders and one drainer (`rtMailboxPush`, `rtMailboxTake`), and a compare-and-swap on the scheduled
    flag; a drainer that finds the queue empty clears the flag, looks again, and takes it back if a message came
    meanwhile. Without it, 235.5.1 alone was slower than the baseline on 4 and 8 carriers with short jobs
    (`fanout_actor` 149 and 244 ns a job), every send and pop contending for the scheduler lock.
  - **235.5.3** Measured. **Done.** Median of 7, ns per hop, job or item (235.5 baseline in parentheses):

    | workload | 1 | 2 | 4 | 8 carriers |
    |---|---:|---:|---:|---:|
    | `pingpong_actor` | 19.1 (19.3) | 19.0 (19.2) | 18.9 (19.2) | 19.4 (19.1) |
    | `fanout_actor`, no work | 40.9 (35.9) | 38.5 (80.3) | 52.2 (81.7) | 87.5 (123.9) |
    | `fanout_actor`, 1,000 iterations | 781 (775) | 421 (425) | 250 (245) | 175 (463) |
    | `pipeline_actor`, no work | 194 (165) | 157 (332) | 157 (453) | 264 (622) |
    | `pipeline_actor`, 100 iterations | 685 (611) | 419 (611) | 344 (609) | 385 (613) |
    | `pipeline_actor`, 1,000 iterations | 6,212 (6,043) | 3,237 (6,045) | 1,806 (6,045) | 1,026 (6,047) |

    Actors now run in parallel. Against Go: ping-pong 4 to 6 times faster; fan-out with no work even or ahead from
    2 carriers; the pipeline with no work behind on 4 and 8 carriers (157 and 264 against about 110). On one
    carrier, interleaved A/B against the old runtime: about 15 ns an item more on the no-work pipeline (nine
    messages an item) and 2 to 6 ns a job on the no-work fan-out, even with work. Fiber and channel workloads
    are unchanged within noise.
- **235.6** Measure against Go. Check the stack-move stress mode, whose stack pool relies on the scheduler lock
  today, and stop-the-world under load; repeat the multi-carrier suite cases many times for memory ordering.
  **Done.**
  - **Against Go** (`tools/pingpong.py`, best of 7, ns per hop, value, job or item; Go with GOMAXPROCS as
    carriers). The script now runs the actor fan-out and pipeline and their Go counterparts too.

    | benchmark | 1 | 2 | 4 | 8 | Go 1 | Go 2 | Go 4 | Go 8 |
    |---|---:|---:|---:|---:|---:|---:|---:|---:|
    | `pingpong_channel` (`go chan`) | 56.1 | 58.4 | 62.7 | 85.1 | 84.5 | 86.5 | 108.1 | 108.3 |
    | `pingpong_actor` (`go mailbox`) | 19.4 | 18.7 | 19.8 | 19.5 | 86.1 | 85.4 | 107.6 | 108.9 |
    | `stream_channel` | 21.9 | 23.1 | 25.0 | 35.8 | 21.2 | 27.0 | 29.2 | 27.8 |
    | `fanin_channel` | 22.6 | 162.6 | 74.9 | 91.5 | 21.1 | 31.9 | 54.7 | 57.2 |
    | `fanout_actor`, no work | 38.1 | 36.6 | 51.8 | 85.3 | 36.9 | 60.4 | 66.3 | 84.0 |
    | `pipeline_actor`, no work | 180.2 | 125.0 | 135.9 | 225.8 | 163.2 | 119.6 | 104.9 | 98.7 |

    Ahead or even on every ping-pong and on fan-out; behind on fan-in from 2 carriers, on stream at 8, and on
    the pipeline at 4 and 8. Fan-in is 235.8.
  - **The stack pool** (stress modes only) is still touched only under the scheduler lock: `rtStackTake` and
    `rtStackRetire` run inside `rtStackMove`, whose two callers in `rtSchedRun` take the lock first, and
    `rtStackFree` runs at completion under it. Nothing changed.
  - **Stop-the-world under load.** A new fixture, `sched_mixed_load`, has fibers, channels and actors move
    managed messages on every carrier count while collections run: `sched-mixed-load` (a collection every
    4 KiB), `-nursery` (minor collections) and `-stack-move`. All three fail with the run-queue walk removed.
    It found a write-barrier race, fixed here: `rtGcRemember` cleared an object's log bit by rewriting its
    table byte after a separate read, so two carriers remembering the same object both subtracted the bit, and
    the second borrowed from a neighbour's bit, leaving that object unremembered. A mailbox's senders and its
    drainer remember the same mailbox from different carriers, which 235.5 made possible (the scheduler lock
    had serialized them, and shareable objects are otherwise immutable). A minor collection then moved a
    mailbox's young messages without fixing the mailbox, and its drainer spun on reclaimed memory, holding off
    the next stop-the-world: a hang about one run in ten. The clear now takes a short spin lock and reads the
    bit again, so exactly one carrier clears and remembers; it is taken only for a set bit, once per object per
    cycle. 260 of 260 repeats and 1,200 parallel runs with no hang.
  - **Repeats.** The 36 multi-carrier cases 50 times each, and 10 times each with stacks moved at every
    resume: all pass. The suite passes plain and under both stack-move settings.
- **235.7** The one-carrier cost of 235.3 (about 8 ns a hop on `pingpong_channel`). Moved to
  [254](254-scheduler-performance.md).1, with the A/B results and the untried leads.
- **235.8** Fan-in across carriers (about 160 ns a value on 2 carriers; the senders move between carriers on
  every value). Moved to [254](254-scheduler-performance.md).2.

- **235.9** Ready work stranded behind a running fiber. **Done.** Found by [236](236-fiber-preemption.md).1:
  `main` spawned N - 1 fibers that compute, then one more, then parked in a join. On 3 or more carriers the last
  fiber waited 1 s (every run on 3; some on 4 and 8), until the idle sleep's timeout (`rtSchedIdle`'s
  `futexWait`). The cause, on 3 carriers A, B and C: the first spawn woke B to search; the later spawns skipped
  their wakes, since B was searching; `main` parked and A took a busy fiber; B stole half of A's queue (one
  fiber), found its own queue and the global queue empty, and woke no one. The last fiber sat in A's queue
  behind a fiber that never parks, with C asleep. The fix: a searcher that finds work wakes another when work
  is visible anywhere, another carrier's queue included (`rtSchedWorkVisible`), as Go's `resetspinning` wakes
  another spinning M. The suite case `stranded-spawn` (2, 3, 4 and 8 carriers, 10 iterations) passes, and
  fails with the fix reverted. Scheduler workloads, median of 5, before → after: no time regression;
  `forkjoin_fiber` 4–22% faster, `pipeline_actor` up to 30% faster (1 µs stages, 4 carriers), `fanout_actor`
  43–50% faster on 4 carriers, `producer_fiber`'s largest wait 40–75% lower, `server_sim`'s light p99 12–25%
  lower; `fanin_channel` on 8 carriers spends 23% more CPU for 6% per value, near noise.

## Dependents

- **The benchmark against Go and Swift** (`horizon.md`): any parallel workload with short tasks would
  measure this.
- **[103](103-dynamic-spawn-group.md)** (dynamic spawn group): a spawn burst enqueues through the lock.
- **Channels** on several carriers ([102](102-channels.md)): `fanin_channel` and `pingpong_channel` in
  `tools/pingpong.py` measure it.

## Refs

`src/stdlib/runtime/scheduler.nomu` (`rtSchedEnqueue`, `rtSchedDequeue`, `rtSchedPick`, `rtSchedLoop`,
`nomuSchedActorSend`, `rtSchedMboxSchedPop`); `design/internals/concurrency.md` §2; 234.3's results;
`tools/schedbench.py`.
