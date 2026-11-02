# Scheduler: one run queue under one lock

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · issue defined` ·
**Size:** M–L · **Status:** issue defined; the fix open · **Source:** [234](234-scheduler-wake-and-pool.md).3's
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

## Constraints on a fix

- **Go's design** is a local run queue per processor (256 entries, lock-free, the owner pushing and
  popping and others stealing half), the global queue only for overflow and fairness (checked every 61
  picks), and `runnext` (234's slot). Its scheduler lock is taken only for the global queue and idle lists.
- **The lock-coupled park** (`concurrency.md` §2) has a fiber switch to its carrier holding the scheduler
  lock, so that a waker, which must hold the same lock to enqueue, cannot run the fiber before its context
  is saved. Local queues need another way to order a park against a readying: a per-fiber state word a
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

## Dependents

- **The benchmark against Go and Swift** (`horizon.md`): any parallel workload with short tasks would
  measure this.
- **[103](103-dynamic-spawn-group.md)** (dynamic spawn group): a spawn burst enqueues through the lock.

## Refs

`src/stdlib/runtime/scheduler.nomu` (`rtSchedEnqueue`, `rtSchedDequeue`, `rtSchedPick`, `rtSchedLoop`,
`nomuSchedActorSend`, `rtSchedMboxSchedPop`); `design/internals/concurrency.md` §2; 234.3's results;
`tools/schedbench.py`.
