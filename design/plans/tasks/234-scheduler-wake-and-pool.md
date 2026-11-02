# Scheduler: wakes on every readying, and a mailbox pool that grows to its cap

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · done` ·
**Size:** S–M · **Status:** done. 234.1 built (wakes only when they can help; a run-queue slot per carrier;
mailbox dispatch by an idle carrier); 234.2 fixed by the mailbox dispatch; 234.3 decided (Go's wake
policy); 234.4 (a stop-the-world ack race) fixed. Moved out: the direct switch and the compiler's marking
of handoffs to [237](237-handoff-primitives.md); the mailbox searcher's open case to
[235](235-scheduler-run-queues.md) · **Source:** [104](104-fiber-stack-strategy.md).1, the ping-pong baseline

Found by 104.1's baseline (`tools/pingpong.py`; numbers in 104's Baseline section). Each issue below is
stated as observed, with the measurement that isolates it. A single scheduler lock was also suspected and
is ruled out for these workloads (below).

## 234.1 Every readying makes a wake system call

**Observed.** Every place that makes a fiber runnable calls `rtSchedWake` unconditionally:
`rtSchedUnpark`, a fiber's completion readying its joiner, `nomuSchedSpawn`, and both branches of
`rtSchedMailboxDispatch`. `rtSchedWake` bumps the wake-generation word and calls `Runtime.futexWake`, a
system call, whether or not a carrier is asleep and whether or not the readying carrier will run the fiber
itself next.

**Cost.**

- With no carrier asleep (one carrier), the call costs about 99 ns. A fiber ping-pong hop is 116 ns; 17 ns
  without the wake (the register swap is 12 ns of that).
- With idle carriers, the call wakes one (538 ns a wake), which takes the scheduler lock to find the work
  already taken by the carrier that parked. A fiber hop rises to 194 ns at two carriers and 416 ns at four;
  an actor hop from 20 ns to 288 ns and 810 ns.
- Isolated: with the wake removed, a fiber hop is 17 ns and an actor hop 21 ns at every carrier count
  from 1 to 8. The whole multi-carrier slowdown in both benchmarks is the wake.

**Constraint on a fix.** Wakes cannot simply be dropped: a parallel workload needs them to spread work to
idle carriers. The issue is the wake policy: when a wake is needed, and which carrier takes the readied
fiber. Go's reference behaviour: it wakes a processor only when one is idle and none is already spinning
(`wakep`), and puts a readied goroutine in the readying processor's `runnext` slot, so a handoff runs on the
same processor. Its channel hop is 83 ns at one processor and 110 ns at four.

### Step one: wake only when it can help (built)

`rtSchedWake` now wakes a carrier only when one is asleep (a count at sched+184, kept under the lock) and
none is searching (a flag at sched+192, set by the waker). A carrier woken with the flag set searches: it
spins up to 20 µs for work, takes the first fiber it finds and passes the search on if more is queued, or
clears the flag, rechecks the queue under the lock, and sleeps. Waking every carrier (stop, stop-the-world)
is unchanged. This is Go's `wakep` and spinning, without its `runnext`.

Ns per hop, best of 3, at 1 / 2 / 4 / 8 carriers (Go at the same `GOMAXPROCS`):

| benchmark | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| pingpong_fiber, before | 116.5 | 194.4 | 416.2 | — |
| pingpong_fiber, after | 18.0 | 71.6 | 89.1 | 101.2 |
| pingpong_actor, before | 20.4 | 288.3 | 809.7 | — |
| pingpong_actor, after | 21.5 | 76.3 | 256.5 | 395.2 |
| go chan | 86.1 | 95.2 | 110.8 | 112.1 |

**What remains, measured with temporary counters.** Every wake ends with the searcher taking a fiber
(fiber ping-pong at four carriers: about 50,000 wakes and as many takes in 2M hops; actor: about 70,000 in
1M), and each take brings about two contended lock acquisitions, each a kernel sleep and wake. Once the
searcher takes one fiber of the pair, the two run on different carriers, and each hop is a cross-thread
handoff until they meet on one carrier again. Two cheaper fixes were tried and dropped: spinning in the
mutex before sleeping made it worse (the searcher won the lock more often: 250,000 wakes, 464 ns a fiber
hop at four carriers), and a searcher that only try-locks changed nothing.

### Step two: hand off to the readying carrier (built: the slot; the direct switch moved to 237)

The remaining cost is a readied fiber leaving the carrier that readied it. A handoff keeps it there: a fiber
readied by a fiber that then parks runs next on the same carrier, out of searchers' reach (Go's `runnext`),
and a direct switch from the parking fiber to it would drop the carrier from the hop (one switch a hop
instead of two). Open: when the readied fiber must be offered to other carriers instead (its readier keeps
running; Go lets a stealer take `runnext` after a few µs), and the lock-coupled park protocol around a
direct switch.

### Step two, mailboxes: dispatch by an idle carrier (built)

A send that scheduled a mailbox readied a mailbox fiber for the shared queue, though the sending fiber
usually popped that mailbox itself moments later. On one carrier the readied fiber never ran and each send
made another (234.2); on several, a searcher took it, popped the mailbox first, and split the pair across
carriers. Three options were measured on one binary (the setting has since been removed, keeping 3):

- **1** (the original): every send that schedules a mailbox readies a fiber.
- **2**: the same, while fewer drainers than carriers exist. A drainer is a mailbox fiber that can pop the
  queue: readied or in its loop, and not parked in a handler or on the free list (sched+200, fiber+296).
- **3** (chosen): the send readies none. A carrier with nothing to run readies one when mailboxes are
  queued and no drainer exists (a handler parked, or the sender was a user fiber). A searcher readies one
  when the queue goes unpopped for `NOMU_MBOX_AGE_NS` (3 µs; a pop counter at sched+208, sampled while it
  spins, so the pop path reads no clock). A drainer that pops a mailbox with more queued behind it wakes a
  searcher; the send wakes one only when no drainer exists.

Actor ping-pong, ns per hop, best of 3, at 1 / 2 / 4 / 8 carriers, and the pool's size after it at 1 / 4:

| dispatch | 1 | 2 | 4 | 8 | pool |
|---|---|---|---|---|---|
| 1 | 21.2 | 81.5 | 225.0 | 377.7 | 64 / 64 |
| 2 | 21.5 | 42.3 | 150.5 | 242.0 | 1 / 4 |
| 3 | 22.1 | 21.5 | 21.4 | 21.8 | 1 / 1 |

`benchmarks/fanout_actor`: one actor sends 50,000 jobs round-robin to 16 actors, which reply to it; ns per
job (throughput), by job size in loop iterations (10,000 is about 7.6 µs):

| dispatch / work | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| 1 / 0 | 37.1 | 91.8 | 117.7 | 280.4 |
| 2 / 0 | 37.3 | 79.5 | 137.2 | 323.0 |
| 3 / 0 | 34.6 | 71.6 | 84.7 | 119.4 |
| 1 / 100 | 99.6 | 194.8 | 245.4 | 420.7 |
| 2 / 100 | 98.5 | 169.4 | 247.0 | 384.3 |
| 3 / 100 | 96.8 | 162.7 | 203.1 | 278.6 |
| 1 / 1000 | 782.9 | 440.1 | 317.6 | 588.3 |
| 2 / 1000 | 786.5 | 442.9 | 322.7 | 585.2 |
| 3 / 1000 | 780.2 | 436.5 | 265.9 | 478.4 |
| 1 / 10000 | 7643.8 | 4037.3 | 2201.3 | 1152.0 |
| 2 / 10000 | 7630.4 | 4037.2 | 2199.6 | 1154.2 |
| 3 / 10000 | 7640.4 | 4047.5 | 2203.6 | 1157.1 |

The 3 µs age costs the fan-out nothing measurable: dispatch 3 is the fastest or equal in every cell. Jobs
of under a µs get slower past four carriers under every dispatch, which points at the single lock
(below). One case stays open, moved to [235](235-scheduler-run-queues.md): a searcher that keeps searching
while a backlog is served promptly but never empties.

## 234.2 The mailbox pool grows to its cap under light load

**Observed.** `rtSchedMailboxDispatch`, on a mailbox's 0→1 schedule edge with no free mailbox fiber,
creates a new one (up to 64). A free fiber exists only after one finds the scheduled queue empty and parks,
so while one fiber keeps draining (each drain scheduling the next mailbox), every dispatch creates another.

**Cost.** Two actors in ping-pong leave all 64 mailbox fibers allocated (64 × 128 KiB = 8 MiB of stacks),
on one carrier or four, while one fiber does the work. With small copied stacks (104) the memory shrinks,
but the fibers, their registry entries and their run-queue traffic remain.

**Constraint on a fix.** The cap exists so many busy actors don't each get a fiber; the issue is creating a
fiber when an existing one will reach the mailbox soon (one already queued to run, or one draining that
will pop the scheduled queue next).

## 234.3 Choosing the wake policy by workload

The run-queue slot keeps a fiber ping-pong on one carrier (99.9% of hops at four carriers run from the
slot), but each readying still wakes a carrier so a searcher can take the slot's fiber if its readier keeps
running. The woken carrier finds nothing, and its lock acquisitions collide with the pair's: at four
carriers, 34,000 wakes and 122,000 contended acquisitions in 2M hops, about 200 ms of a 254 ms run. With
the wake removed a hop is about 26 ns at every carrier count. Three strategies, each a setting:

- **Lock-free searching.** A woken carrier spins, decides to sleep and sleeps with atomic reads only, and
  takes the lock once it sees work. Go's spinning threads work this way.
- **A monitor in place of the readying wake.** Readying into a slot wakes no carrier; the timer thread
  checks the slots periodically and wakes a carrier for a fiber waiting past the steal age. Go wakes at
  every readying and keeps its monitor (`sysmon`) for preemption and blocked system calls, so this goes
  past Go: the gain is the handoff without wakes, the cost a stranded fiber's wait for the next check.
- **No wake where the readier parks next.** Join completion readies its joiner as its fiber finishes.

**Choosing.** A set of workloads covering the scheduler's regimes, each at 1, 2, 4 and 8 carriers, swept
over the settings by one script, measuring throughput, latency where there are requests, and CPU time:

| regime | workload |
|---|---|
| handoff | fiber and actor ping-pong |
| fan-out, fan-in | `fanout_actor`; fibers spawned and joined |
| pipeline | items through a chain of stages, each doing work |
| readier keeps running | a producer readies others, then computes |
| many parked fibers | thousands of sleepers woken in bursts |
| compute plus handoffs | background compute beside latency-sensitive handoffs |
| mostly idle | the cost of spinning and of the monitor |

**Built.** `tools/schedbench.py` runs the workloads in `benchmarks/` (`pingpong_fiber`, `pingpong_actor`,
`fanout_actor`, `forkjoin_fiber`, `pipeline_actor`, `producer_fiber`, `sleepers_fiber`, `mixed_fiber`,
`idle_fiber`) under named groups of settings (`--list`). The strategies below were measured as settings
(`NOMU_SEARCH_LOCKFREE`, `NOMU_SLOT_WAKE`, `NOMU_JOIN_WAKE`, `NOMU_MONITOR_NS`) and removed once the
decision was made; the settings that tune the chosen policy remain: `NOMU_SLOT`, `NOMU_SLOT_STEAL_NS`,
`NOMU_SLICE_NS`, `NOMU_GLOBAL_CHECK`, `NOMU_SEARCH_NS` and `NOMU_MBOX_AGE_NS`. The scheduler's hot words moved to cache lines of
their own (the mutex word to sched+256, `sleeping` and `searching` to +320 and +328): a searching carrier
spinning on the run-queue head shared a line with the mutex word, which alone took the fiber ping-pong at
four carriers from 116 to 49 ns under the original wake.

**Results** (median of 5; ns per hop or ms; at 2 / 4 / 8 carriers):

| workload | original | lock-free | monitor (20 µs) |
|---|---|---|---|
| fiber ping-pong, ns/hop | 32.5 / 43.6 / 46.4 | 23.7 / 26.7 / 43.4 | 23.0 / 22.9 / 22.4 |
| its CPU, ms | 107 / 160 / 160 | 97 / 215 / 666 | 48 / 48 / 47 |
| stranded fiber's wait, p50 / p99 µs | 6 / 8 | 6 / 8 | 14 / 41 |
| compute beside handoffs: the pair, ms | 39 / 35 / 29 | 38 / 27 / 25 | 38 / 26 / 18 |

- **The monitor** gives the fastest handoffs at the least CPU, and costs a stranded fiber's wait: p50 6 →
  14 µs, p99 8 → 41 µs. Its period barely moves the p99 (33–41 µs at 5, 10 and 20 µs): the wait is mostly
  the time to wake a sleeping carrier, which the readying wake pays in advance.
- **Lock-free searching** helps handoffs at 2 and 4 carriers without the monitor, and at 8 burns CPU (its
  searchers cycle faster). With the monitor on it measures the same as without. Its first version lost
  wakes (a carrier that found work while counted as sleeping left the searching flag raised with no
  searcher, so every later wake was skipped until a one-second timeout); fixed. Two full-suite runs under
  it later took about 1,100 s against 150 s, and a third ran in 143 s; the slowdown has not reproduced.
- **No wake at join completion** measures the same as with it: `forkjoin_fiber` costs 4.5–6 µs a fiber
  under every setting, which is spawning itself (stack allocation and setup, task 104's area), and hides it.
- **Insensitive:** actor workloads (no slot), `fanout_actor`, `pipeline_actor` with real work,
  `sleepers_fiber`, `idle_fiber`'s CPU.
- **Seen along the way:** `pipeline_actor` with no work slows past two carriers under every setting (the
  single lock); `producer_fiber` on one carrier leaves its consumers unrun until the producer finishes,
  which is the absence of preemption.

**Decision: Go's policy.** Readying into a slot wakes a carrier (Go's `wakep`), and a woken carrier
searches briefly before sleeping (Go's spinning threads); no monitor, and searching takes the lock as
before. These are the runtime's defaults. Why: it gives a stranded fiber the shortest wait (p99 8 µs)
with no new mechanism, and its handoff cost is Go's own. The monitor's faster handoffs come with a 5×
longer tail for a readier that keeps running, and how common that case is in real programs is unknown.
Going past Go is left to the compiler (below), where Nomu sees what Go's runtime cannot.

The slot costs about 2 ns a hop on one carrier (22–24 ns against 20–21 with `NOMU_SLOT=0`). Reading the
clock on every pick is part of it; counting picks instead, with a searcher timing a slot itself, saved
1.5 ns there but doubled a stranded fiber's wait at eight carriers (p50 5 → 24 µs), so the clock stays.

**Later: the compiler's part** (moved to [237](237-handoff-primitives.md)). Once user code has a handoff primitive (a channel or a request-reply call;
new syntax or API, to be agreed), the compiler can mark readyings that a park follows on every path with
nothing long between (send then receive), so the runtime skips their wake, and fuse the pair into one
operation that switches straight into the partner (one context switch per hop instead of two, decision 3b
of step two). A small edit can lose the classification; the loss is the wake and one switch per hop, which
the perf report should show by site, as Go programmers find escape and inlining changes with `-gcflags=-m`.

Savina (the standard actor suite) and skynet (a tree of a million fibers) supply known shapes, with Go
counterparts in `practice/`. The defaults chosen are the settings never far from the best on any workload;
where a setting matters a lot is recorded as the case for an adaptive policy. Real programs (the I/O
server workloads, the benchmark against Go and Swift) confirm the choice.

## 234.4 A stop-the-world ack can count toward the next collection (fixed)

Found by reading the handshake while looking for 234.3's slow suite runs; not yet observed. At the end of a
collection the coordinator (`rtGcCoordinatorMain`) resets the ack count (sched+144), then clears the
request (+136), then bumps stw-gen (+152). A carrier that reads the request still raised before it is
cleared, and acks after the reset (`rtSchedStwParkCarrier`), adds an ack to the next collection's count;
the next collection can then start with that carrier still running a fiber. Any carrier that polls the
request can do it: the searcher's spin always has. Fixed by tagging the ack word with its generation (high
32 bits, over the count): a carrier adds its ack only while the tag matches the stw-gen it read, and the
coordinator resets the word under the next generation's tag before clearing the request.

## Ruled out: the single scheduler lock

One lock guards the run queue and the scheduled-mailbox queue. Under ping-pong it costs 2.3 ns a lock and
unlock pair and shows no growth with carriers once wakes are removed. Its cost under parallel load (many
carriers readying fibers at once) is unmeasured; a benchmark for that is outside this task.

## Dependents

- **[104](104-fiber-stack-strategy.md)**: its later measurements (the entry check, growth) compare against
  the register swap (6 ns a switch) and the one-carrier hop without the wake (17 ns), so 234.1 does not
  block them.
- **The benchmark against Go and Swift** (`horizon.md`): any concurrent workload there would measure 234.1's
  wakes; 234.1 is fixed before it, at the latest.
- **[103](103-dynamic-spawn-group.md)** (dynamic spawn group): spawn wakes unconditionally (234.1).

## Refs

`src/stdlib/runtime/scheduler.nomu` (`rtSchedWake`, `rtSchedUnpark`, `rtSchedFiberMain`, `nomuSchedSpawn`,
`rtSchedMailboxDispatch`, `rtSchedMailboxFiberMain`); `design/internals/concurrency.md` §9 (the mailbox
pool); 104's Baseline section; `tools/pingpong.py`.
