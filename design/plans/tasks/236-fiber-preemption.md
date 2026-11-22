# Fiber preemption: a running fiber keeps its carrier until it parks

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · issue defined`
· **Size:** M–L · **Status:** done; time to stop in large copies and stack moves is a recorded limit (236.10) · **Source:** [234](234-scheduler-wake-and-pool.md).3's
workloads

## Observed

A fiber runs until it parks, finishes, or stops at a safepoint for a stop-the-world. Nothing takes a
carrier back from a fiber that keeps computing. 234's slice (`NOMU_SLICE_NS`, 1 ms) bounds only a chain of
fibers handed through one carrier's slot, and acts at a pick, so it never interrupts a running fiber.

## Cost

- **Starvation.** `producer_fiber` on one carrier: the producer readies a consumer and computes for about
  20 µs, 20,000 times. The consumers never run until the producer finishes; every readying misses (19,992
  of 20,000), and the one recorded wait is the whole run, about 335 ms.
- **Latency behind compute.** `mixed_fiber` on one carrier: a pair handing a turn back and forth finishes
  after the 55 ms of compute queued beside it (63 ms), where with carriers to spare it finishes in 17–38 ms.
- **Stop-the-world.** The safepoint poll sits at loop headers only (`SSAIRToLLVM.swift`, pass B). A fiber
  in loop-free code (recursion, straight-line code) or in a call into C reaches no poll, so a collection
  waits for it. That is the same gap preemption has: no point at which the fiber can be stopped.

## Goals

- **G1. Bounded wait behind compute.** A ready fiber starts within 1 ms when another fiber on its carrier is
  computing.
- **G2. Bounded time to stop the world.** Every fiber reaches a stop within a bounded amount of work: loops,
  recursion, straight-line code, the runtime's own code, calls into C. Time to stop all fibers is at or below
  Go's, measured on the same machine; 100 µs is the ceiling until Go is measured.
- **G3. Near-zero cost in compute code.** Polls and the stack check together cost under 3% on a tight loop.
- **G4. A fiber blocked in C or a syscall gives up its carrier,** and counts as stopped for a collection. A
  call into C costs what a raw call costs, within about a nanosecond (FFI goal F1, [130](130-ffi-c-abi.md)).
- **G5. Tail latency in mixed workloads.** A server with occasional heavy requests keeps its p99 close to the
  same server without them.

The design must also fit a precise, moving collector and copying fiber stacks: wherever a fiber stops, its
frames are described.

**Non-goals:** hard real-time deadlines, priorities between fibers, fairness across carriers beyond what work
stealing gives.

## Performance rules

Shared with [130](130-ffi-c-abi.md); the two copies stay identical. Rules for any task that touches
performance, measured against Go first; Swift, Rust and Zig once Go is beaten. Designs are compared against
Go, Swift, C# Native AOT, Java's virtual threads, Rust and Zig.

- **P1. Compute.** Beat Swift and C# Native AOT on value-heavy code, and Swift on reference-heavy code. Polls
  and stack checks cost under 3% on tight loops.
- **P2. Concurrency primitives.** Spawn, switch and channel handoff cost less than Go's.
- **P3. Servers.** Beat Go on throughput and p99 latency in a server that mixes I/O and compute.
- **P4. Collection pauses.** Small and bounded, time to stop all fibers included: at or below Go's, with
  100 µs as the ceiling until measured.
- **P5. Memory.** Fiber stacks start at 2 KiB; the heap stays within 1.1–1.3× the live set.
- **P6. Size.** The runtime under 999 KB, a binary under 9 MB.
- **P7. Predictability.** No hidden cliffs: a loop that keeps its full poll cost, an object that lands on the
  heap. Tooling explains these decisions.

**Non-goals:** compile time (its own discussion), hard real-time latency.

## Constraints on a fix

- **Go's design.** Its monitor (`sysmon`) marks a goroutine that has run over 10 ms for preemption. It is
  stopped cooperatively at the next function prologue (the stack check, made to fail), or asynchronously
  by a signal (`SIGURG`) whose handler checks the goroutine is at an asynchronous safe point and injects a
  call to the scheduler. Asynchronous preemption needs the compiler to mark safe points, and the collector
  to scan a frame stopped anywhere conservatively, or precisely with maps for every instruction.
- **Nomu's polls.** Preempting at the existing loop-header polls is cooperative and nearly free: the poll
  already reads a flag. It misses loop-free code. Adding polls at function entries covers recursion, and
  fits with 104's entry check, which a growth check and a preemption request can share, as Go's stack
  check does.
- **Stop-the-world shares the mechanism.** A preemption request and a stop-the-world request both ask a
  running fiber to stop at its next safe point; one mechanism should serve both, and fix the
  stop-the-world gap above with it.
- **Precise stack maps.** Nomu's collector is precise: a fiber stopped at a poll has a statepoint and its
  roots are known. An asynchronous signal would stop a fiber between statepoints, which the stack maps do
  not describe.
- **The runtime's own code** (the runtime subset) has no polls and must not be preempted.

## Phases

What the code does today, which the phases build on: the entry check compares SP with a stack limit in the
running fiber's record (`[x28+40]`, `emitStackCheck`); the loop poll reads a global flag, `rtStopWorld`
(`nomuPoll`).

- **236.1 Measurements first.**
  - **236.1.1** G1: record the waits in `producer_fiber` and `mixed_fiber` (`tools/schedbench.py`).
  - **236.1.2** G2 and P4: Nomu's time to stop all fibers, and Go's on the same machine (its stop latencies,
    through `runtime/metrics`).
  - **236.1.3** G5: a server workload on simulated I/O, fibers woken by timers or pipes standing in for
    requests; deterministic, so it is also a test fixture.
- **236.2 Strip mining: task [245](245-loop-strip-mining.md).** **Done:** counted loops at the no-poll speed;
  loops that keep a bounds check moved to [117](117-loop-improvements.md).2. Its kernel set first, then the transformation.
  After 236.1, so the baselines are taken before loops stop differently; before 236.3, which checks the poll's
  new form on the kernel set. Carries G3.
- **236.3 One request word.** **Done.** The request word is the running fiber's stack limit: a stop-the-world
  writes all ones there, as Go does its stack guard; the coordinator raises the stop flag, then each carrier's
  running fiber's limit, and a carrier switching a fiber in restores its limit, publishes it, then reads the
  flag (`rtSchedArm`), so one of them always sees the other. The loop poll loads the limit through x28 and
  compares it with all ones (a loop needs no SP test: a stack overflows at an entry); `rtStopWorld` stays as the
  flag the slow paths read, and codegen no longer reads it. The slow paths restore the limit before reading the
  flag, so a raise left on a fiber that parked first clears itself. Runtime-package polls test x28 for 0 first,
  since that code also runs with no fiber. Measured: time to stop in loops unchanged (p99 14 / 15 / 35 µs at 2
  / 4 / 8 carriers); the kernel set within run-to-run noise except `probe`, about 10% slower (its loops run a few
  iterations, and the poll is now four instructions, a copy of x28 among them, against the old two). Until
  236.4, a fiber in recursion takes the entry check's slow path at every call while a stop is pending: its time
  to stop rose from 0.8 to 1.7 ms at p99.
- **236.4 Stops at function entry.** **Done.** The entry check's slow path parks for a pending stop-the-world
  when its `need` is 0, as a loop poll does; a frame-split wrapper's check and a runtime-sized buffer's (which
  now asks for at least 1) raise the limit again for the next stop. Time to stop in recursion with no loop: p99
  14 / 37 / 75 µs at 2 / 4 / 8 carriers, from 0.8–1.7 ms. Suite case `stw-recursion`. Five places had relied on
  the check never collecting, each found by the suite:
  - **The carrier armed a fiber before moving its stack** (236.3's bug): the move reset the limit and dropped a
    request raised meanwhile. Arming is now last before each switch.
  - **A large argument forwarded past the check** (`LargeValues.cpp`): a call reached with no stop since entry
    passed on the pointer its argument arrived in, so the values sat in an unrecorded slot across the check. Only
    a frame-split wrapper, whose check never stops, forwards now.
  - **The check moved past values a stop does not describe** (`StackChecks.cpp`): after optimization the check
    moves to just before the function's first call, past a raw managed address (`pinnedAddress`), a shaped
    value's words or a store. It now moves only past instructions whose results a stop describes (comparisons,
    arithmetic, address offsets, loads of managed pointers); otherwise it stays at the entry.
  - **A fiber routine's environment arrived raw** (`SSAIRToLLVM`): its captures were read off an untracked
    pointer, safe only while nothing could collect before they were read. It becomes a managed pointer first in
    the entry (`adoptManaged`).
  - **The stack-move stress mode's limit** was the request value, so every loop poll took its slow path (the
    `stack-move-checks` cases went from 2 s to 900 s): the stress mode now uses all ones but the last bit.
- **236.5 The monitor and preemption.** **Done.** A monitor thread (`rtSchedMonitorMain`) looks at every carrier
  each tick: the same fiber running with no switch since the last tick (the carrier's switch count, rec+200,
  unchanged; no clock read on the switch path) has run at least one period, a quarter of the slice. If work
  waits there (its run queue or slot, or the global queue) it names the fiber as the carrier's target (rec+208)
  and raises the fiber's limit; with a carrier asleep it wakes one instead. The period stays at its shortest while
  a carrier runs one fiber across a tick or has work waiting behind it, backs off to 1 ms while carriers run only
  short bursts, and to 10 ms while none runs a fiber (a first version reset it whenever a fiber ran, and
  `idle_fiber` spent 23–34% more CPU). At its next loop poll or ordinary entry check the fiber restores its limit, stops for a
  pending stop-the-world first, and otherwise, as its carrier's target, switches back ready holding the
  scheduler lock; the carrier puts it on the global queue before releasing the lock. `NOMU_PREEMPT=0` turns it
  off. 254.3's deferred wake was set aside before this task and is not in the code, so there is nothing to check
  against it. Suite case `preempt-spin`: spinners in a call-free loop and in loop-free recursion hold every
  carrier, and the fiber that ends them runs only through preemption.
  G1 and G5 (`tools/schedbench.py`, median of 5): `producer_fiber` on one carrier, the readied consumer's wait
  p50 / p99 / max 0.46 / 0.92 / 1.05 ms, from 402 ms; `server_sim` with heavy requests, light p99 0.66 ms on one
  carrier (from 14.7 ms) and 0.52 ms on two (from 2.1 ms), against 0.46 and 0.26 ms light-only; the one-carrier
  heavy run ends in 692 ms, from 1,178. `mixed_fiber` is unchanged: preemption shares the carrier fairly, so the
  handing pair still waits its turn behind 256 compute fibers; its end is bound by the compute.
  Against `NOMU_PREEMPT=0`, every scheduler workload at 1–8 carriers: within run-to-run noise (the actor fan-out
  and pipeline swing both ways, as before), `idle_fiber`'s CPU within noise (−13% to +11%), and the latency
  workloads better.
- **236.6 Print through a runtime buffer: task [271](271-print-without-printf.md).** **Done** (`print_loop`
  277 → 34 ms). `print` copies into a
  stdout buffer the runtime owns and flushes it with `write`, so the one call that can block is not variadic and
  holds no managed memory: what 236.7 needs to make it a stop.
- **236.7 Calls into C as stops: task [270](270-c-calls-as-stops.md).** **Done:** a collection beside a `print`
  blocked 2 s in `write` takes 1–3 ms (was 1.95 s); a carrier blocked in C is handed off to a spare, so two
  compute fibers on two carriers finish in 423 ms beside it (785 without). Carries G2's C-call part and G4.
- **236.8 The runtime's own code.** **Done.** `benchmarks/stop_latency` gained modes 2–6, which keep busy fibers in
  runtime code (small-object allocation, arrays grown by append, fresh fibers recursing deep, a channel
  ping-pong, small prints), and its Go counterpart the same; `tools/stopbench.py` runs both (`--depth` sets
  mode 4's recursion). Time to stop is below Go's in every mode but arrays grown by append, where the two are
  even (both wait out the same copy), so G2 holds (results below). Two modes pass the 100 µs ceiling, in Go too:
  large copies and deep stacks, whose cost grows with the data.
  - **Allocation, channels and print** stay within 6–34 µs at p99, as the call-free loops do: their runtime loops
    are short (a hole scan is at most one block's 128 lines, a refill zeroes at most one 32 KiB block).
  - **Arrays grown by append** (mode 3): p99 108 / 196 / 566 µs at 2 / 4 / 8 carriers against Go's 66 / 229 /
    524; an earlier run had 60 / 227 / 463 against 82 / 262 / 655. The growth copy is a `memcpy` from compiled code, a plain call into C with no stop, so a stop waits
    out the copy (4 MB at the last doubling here).
  - **Deep stacks** (mode 4): p99 0.6–0.8 ms at 100,000 frames (Go 1.6–1.8), 2.8–3.1 ms at 300,000, 3.9–5.8 ms at
    1,000,000, against Go's 5.2–7.3 and 12.6–14.7 ms at the larger two. Two parts: the stack move, runtime code that
    copies the used stack and walks every frame with no stop (1,755 moves averaging 480 µs at 300,000 frames,
    `NOMU_STACK_STATS=1`); and the return path, where unwinding meets no entry check or poll (p99 1.3 ms at
    300,000 frames with stacks started at 64 MiB, so nothing moves). Go's stack copy is not preemptible either.
  - **Found: a fiber stopped by frequent collections was never preempted.** Resuming a fiber after a
    stop-the-world or a stack move went through `rtSchedArm`, which counts a switch and clears the monitor's
    target, so the monitor saw a fresh run at every tick while collections came faster than it ticked. On one
    carrier a fiber requesting collections back to back held the carrier forever. A resume within the same run
    now goes through `rtSchedRearm`, which keeps the count and the target and raises the limit again for either a
    stop or the target.
  - Suite case `stw-runtime`: workers in allocation refills, array growth, stack moves and channel handoffs
    check their results while a requester asks for minor collections back to back, on 1–8 carriers; the
    compiler before the fix times out on one carrier.
- **236.9 Verify and fold.** **Done.** G1–G5 against 236.1's baselines (results below): G1, G2, G4 and G5 met; G3
  met on counted loops, with the misses owned by 117.2, 182 and 236.10. The design is folded into `runtime.md`
  §2 and §6 and `concurrency.md` §1. `tools/loopbench.py` gained the `no-stops` configuration (no loop polls
  and no entry checks), G3's bound.
- **236.10 Left after verifying.** **Done**, with one limit recorded.
  - **`probe`'s poll: improved, 13% → 7% behind the no-poll build.** Two kinds of redundant poll are dropped
    (`LoopPolls.cpp`). Strip mining deletes the polls the optimizer left outside every cycle (the copy loop
    rotation puts in a loop's guard, a peeled or fully unrolled iteration's): each ran once in straight-line code
    between two stops. The poll expansion deletes a loop header's poll when another poll it keeps dominates
    every latch, as a strip-mined inner loop's poll does for its outer loop; loops go innermost first, so the
    poll an outer loop relies on stays. `find`, inlined into `probe`, went from three checks of the request word
    a call to one beside its entry check. The rest of the gap is the chunk counter on an inner loop that runs
    one or two iterations. Time to stop unchanged (`tools/stopbench.py` modes 0, 1, 2, 5).
  - **A normal exit dropped output queued behind a blocked write: fixed.** The exit flush skips the queue when
    another thread holds a lock (`nomuOutFlushAtExit`), so a crash inside a print cannot hang the exit. A normal
    end now flushes first with `nomuOutFlushAtEnd` (`rtSchedFinish`), which waits for the locks, as Go's `main`
    blocks in its own write: with a detached fiber blocked in `write` on a stalled pipe, `main`'s last line came
    out 3 of 3 runs, against 0 of 3 before. A program whose reader never reads now waits at its end, as Go's
    does. Not in the suite: it needs a pipe whose reader stalls.
  - **Time to stop in large copies and stack moves:** a recorded limit (236.8), shared with Go; at or below Go's,
    so G2 holds. Taken up only if a workload needs it. The candidates, each with its cost:
    - **Chunked growth copies** with a poll between chunks. A collection mid-copy finds the new buffer holding
      copied young references the copy wrote with no barrier, so the collector would have to treat it as
      remembered or the copy would need barriers.
    - **A stop before a stack move** when one is pending, at an ordinary check (`need` 0; a wrapper's check
      cannot stop). Helps only a request that arrives before the move starts; most of the wait is a move
      already under way.
    - **An abortable move:** checks the request during the frame walk, drops the new stack and starts over
      after the stop. Collections more frequent than a move would starve it, so it needs a rule such as
      finishing on the second try.

Phases run in number order. 236.2, 236.6 and 236.7 are tasks of their own, done as phases of this one.

### 236.9 results: the goals against the baselines

Release build, the same machine as 236.1, median of 5 (`tools/schedbench.py`) or 3 (`tools/stopbench.py`);
`tools/loopbench.py` median of 7.

**G1, wait behind compute: met.** `producer_fiber` on one carrier, the readied consumer's wait p50 / p99 / max
0.46 / 0.92 / 1.05 ms, from 402 ms (`NOMU_PREEMPT=0`: 336 ms); misses 14,802 of 20,000, from 19,992. With
carriers to spare the wait stays 5 / 8 / 14–41 µs. `mixed_fiber` is unchanged (pair 63 / 35 / 21 / 19 ms at
1 / 2 / 4 / 8 carriers): preemption shares the carrier fairly, so the pair waits its turn behind the compute,
and its end is bound by the compute (59 / 31 / 16 / 8 ms).

**G2, time to stop: met.** At or below Go in every mode at p99, µs (2 / 4 / 8 carriers):

| | Nomu | Go 1.27 | 236.1's Nomu |
|---|---|---|---|
| call-free loops | 13 / 14 / 38 | 12 / 33 / 131 | 18 / 32 / 37 |
| recursion, no loop | 13 / 16 / 33 | 25 / 57 / 164 | 810 / 777 / 843 |

Runtime code (236.8): below Go except arrays grown by append, where the two are even; large copies and deep
stacks pass 100 µs in both. A fiber in a blocked call into C: a collection beside a `print` blocked 2 s in
`write` finishes in 0.27–0.92 ms (1.95 s before 236.7).

**G3, polls and stack checks under 3%: met on counted loops.** Each kernel's change with no loop polls, then with
no polls and no entry checks:

| kernel | ms | no polls | no stops | owner of the gap |
|---|---|---|---|---|
| sum | 15.5 | −0.4% | −0.9% | |
| count | 15.3 | −0.4% | +0.2% | |
| spectral | 3.2 | +0.3% | +1.7% | |
| sieve | 69.6 | −13.2% | −13.1% | 117.2 (bounds check) |
| matmul | 49.5 | −21.9% | −23.3% | 117.2 |
| insertion | 41.8 | −16.4% | −19.4% | 117.2 |
| probe | 6.0 | −13.1% | −12.9% | 236.10 (now −7%) |
| bytes | 134.2 | −0.9% | −10.1% | 182 (entry checks in uninlined cross-module calls) |

**G4, a fiber blocked in C gives up its carrier: met.** Two carriers, one fiber blocked in `print`'s write on a
stalled pipe, two fibers computing: they finish in 338–377 ms, against 635–650 ms with `NOMU_PREEMPT=0`. The
per-call cost against a raw call and cgo belongs to compiled code's stub path, in 130.

**G5, tail latency: met on one and two carriers,** where 236.1 judged it. `server_sim` light p99 with heavy
requests 0.66 / 0.52 ms at 1 / 2 carriers, from 14.7 / 2.1 ms, against 0.46 / 0.26 ms light-only; the
one-carrier heavy run ends in 683 ms, from 1,178. At 4 and 8 carriers 66 / 57 µs.

### 236.1 results: the baselines

Release build, M-series Mac (12 performance cores), before any of 236's changes and after
[235](235-scheduler-run-queues.md).9's wake fix; median of 3–5 runs. Run to run, the light-only latencies in
`server_sim` vary about 2×, so compare against several runs.

**G1, wait behind compute** (`tools/schedbench.py`, `producer_fiber` and `mixed_fiber`):

| carriers | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| `producer_fiber` wait p50 | 402 ms | 6 µs | 6 µs | 6 µs |
| `producer_fiber` wait p99 | 402 ms | 14 µs | 14 µs | 12 µs |
| `producer_fiber` misses (of 20,000) | 19,992 | 0 | 0 | 0 |
| `mixed_fiber` pair finishes | 65 ms | 35 ms | 20 ms | 16 ms |
| `mixed_fiber` compute finishes | 61 ms | 31 ms | 16 ms | 8 ms |

On one carrier a ready fiber waits for the whole run; with carriers to spare it waits microseconds.

**G2 and P4, time to stop the world** (`tools/stopbench.py`: `benchmarks/stop_latency` with the recorder,
against `practice/go/stop_latency` and Go's `/sched/pauses/stopping/gc:seconds`; a collection requested every
2 ms beside busy fibers on every other carrier; µs, p50 / p99 / max):

| | carriers | Nomu | Go 1.27 |
|---|---|---|---|
| call-free loops | 2 | 5 / 18 / 79 | 7 / 33 / 41 |
| | 4 | 10 / 32 / 38 | 25 / 66 / 164 |
| | 8 | 17 / 37 / 40 | 82 / 115 / 197 |
| recursion, no loop | 2 | 572 / 810 / 823 | 8 / 49 / 49 |
| | 4 | 190 / 777 / 849 | 10 / 82 / 98 |
| | 8 | 261 / 843 / 881 | 10 / 164 / 197 |

In loops, Nomu's polls stop all fibers 2–5× faster than Go's signals at 4 and 8 carriers, and stay under
P4's 100 µs. In recursion a stop waits out the call in progress (about 0.8 ms here; unbounded in general):
the gap 236.4 closes. Go's histogram reports bucket upper bounds, so its figures are coarser.

**236.8, time to stop with fibers in runtime code** (`tools/stopbench.py --modes 0,2,3,4,5,6`, median of 3 runs,
with 236.8's fix; mode 0 for reference; mode 4 at its default 100,000 frames; µs, p50 / p99 / max):

| mode | carriers | Nomu | Go 1.27 |
|---|---|---|---|
| 0 call-free loops | 2 | 5 / 11 / 13 | 6 / 12 / 16 |
| | 4 | 8 / 14 / 15 | 25 / 33 / 197 |
| | 8 | 19 / 38 / 40 | 82 / 131 / 229 |
| 2 small objects | 2 | 5 / 11 / 13 | 7 / 12 / 14 |
| | 4 | 7 / 14 / 19 | 12 / 33 / 197 |
| | 8 | 15 / 34 / 41 | 33 / 197 / 229 |
| 3 arrays by append | 2 | 6 / 108 / 116 | 0 / 66 / 229 |
| | 4 | 12 / 196 / 454 | 14 / 229 / 524 |
| | 8 | 66 / 566 / 1,682 | 131 / 524 / 786 |
| 4 deep stacks | 2 | 133 / 570 / 585 | 328 / 1,573 / 1,573 |
| | 4 | 286 / 743 / 751 | 918 / 1,835 / 1,835 |
| | 8 | 443 / 767 / 782 | 1,311 / 1,835 / 2,097 |
| 5 channels | 2 | 2 / 7 / 12 | 7 / 14 / 25 |
| | 4 | 2 / 6 / 8 | 12 / 29 / 33 |
| | 8 | 5 / 14 / 21 | 25 / 49 / 57 |
| 6 print | 2 | 4 / 11 / 16 | 0 / 14 / 16 |
| | 4 | 9 / 14 / 15 | 8 / 16 / 20 |
| | 8 | 16 / 25 / 27 | 10 / 25 / 33 |

**G5, tail latency in mixed workloads** (`tools/schedbench.py`, `server_sim`; light requests' latency, from
release to end; `heavy` makes every 100th request about 20 ms):

| carriers | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| p99, light only | 655 µs | 655 µs | 262 µs | 655 µs |
| p99, with heavy | 14.7 ms | 2.1 ms | 66 µs | 82 µs |
| max, with heavy | 16.8 ms | 3.7 ms | 131 µs | 131 µs |

On one and two carriers the heavy requests hold carriers and light requests wait behind them. On four and
eight, the heavy runs come out faster than light-only: the heavy requests keep carriers awake, and in the
light-only runs most of the latency is carriers waking from sleep. That wake latency belongs to
[254](254-scheduler-performance.md); G5 is judged on one and two carriers until it is fixed.

**Found: ready work stranded for 1 s.** In `stop_latency`'s first version, a fiber spawned after the busy
ones did not start until 1,001 ms at three or more carriers: it waited in a busy carrier's queue while the
idle carriers slept, until their idle timeout (`rtSchedIdle`'s 1 s `futexWait`). A wake is missing when
work is queued behind a running fiber. Fixed as [235](235-scheduler-run-queues.md).9: a searcher that finds
work now wakes another when any carrier's queue holds more.

## Background: asynchronous preemption

Stopping a fiber at any instruction by a signal, as Go has done since 1.14. The ways it could work under a
moving collector, considered before the Architecture below was chosen:

- **(a) Maps at every instruction,** as .NET does: needs 194's candidate 3. The Architecture's fallback.
- **(b) Hijacking the return address:** works with call-site maps, but loops keep their polls; a result in
  flight needs its layout (notes from 252).
- **(c) Scanning the interrupted frame conservatively,** as Go does: unsound with copying stacks.
- **(d) A signal as a kick only,** setting the request word: lower latency than the monitor's tick; unneeded at
  a 1 ms slice.
- **(e) Keeping the polls and strip mining them** ([245](245-loop-strip-mining.md)): the choice.

## Dependents

- **[245](245-loop-strip-mining.md)** (strip mining) is a prerequisite, for G3.
- **[270](270-c-calls-as-stops.md)** (calls into C as stops) is a prerequisite, for G2 and G4.
- **[104](104-fiber-stack-strategy.md)**: its entry check is the function-entry stop.
- **[254](254-scheduler-performance.md)** (scheduler performance) waits on this task: the stop points and
  their checks change the hot paths it tunes.
- **[254](254-scheduler-performance.md).3, the deferred wake** (built, measured and set aside for now): a
  readying into the carrier's own slot owes a wake instead of making it, and the readier fires it at its next stop (a park drops it). It relies on a
  computing fiber reaching a stop soon, which loop polls give; function-entry stops close its gap in loop-free
  code. If the fallback ever removes loop polls, revert it to waking at once, Go's policy.
- **The benchmark against Go and Swift** (`horizon.md`): a workload mixing long computations with
  latency-sensitive work would measure this.

## Refs

`src/stdlib/runtime/scheduler.nomu` (`nomuSchedSafepoint`, `rtSchedPick`'s slice);
`src/llvmgen/SSAIRToLLVM.swift` (the loop-header poll); `src/llvmgen/LLVMGenRuntime.swift`
(`emitSafepointPoll`); `runtime.md` §6 (safepoints); 234.3's results; `tools/schedbench.py`.

## Architecture

**Strategy.** Follow .NET and HotSpot on the large runtime decisions: both reach top-tier compute with a precise,
moving collector. Nomu differentiates on the language, deployment, size and tooling.

- **Stops: cooperative.** Loop-header polls, as today, and a stop at function entry. Strip mining
  ([245](245-loop-strip-mining.md)) brings the loop polls toward G3. This is HotSpot's model, and it fits
  194's extended statepoints.
- **Detection: a monitor thread,** as Go's `sysmon`. It compares each carrier's running fiber against the slice
  and sets the request.
- **Delivery: through the stack limit at entry.** The runtime sets the carrier's stack limit so the next entry
  check fails, as Go does; the entry check is the entry stop at no added cost. Loop polls read the request
  flag. The entry stop skips frame-split wrappers (notes from 252).
- **Calls into C: one path for every call, the transition built into the stack switch.** The stub that runs a
  C call on the carrier's stack already saves the fiber's stack pointer in a carrier slot. That slot marks the
  fiber as in C: a collection scans the fiber from it without waiting. The stub's return checks one flag and
  parks if a collection or a handoff happened meanwhile. A per-carrier call counter lets the monitor see a
  carrier held by one call across two ticks, and hand that carrier's other work to another carrier. No call
  is classified short or blocking. Calls into C the toolchain compiled may skip the stack switch where their
  stack use is known to fit, or inline (130's F8).

**Fallback: loops with no polls, as .NET does.** Maps at every instruction in loop bodies, signals to stop a
running loop, return hijacking elsewhere. It removes loop polls entirely and needs 194 reopened for candidate 3
(Nomu's own machine-level frames). Taken only if 245's measurement on a set of compute kernels leaves the polls
above G3.

Why polls with strip mining are expected to match or beat it, given Nomu's other choices:

- **Its gain is confined to call-free, allocation-free loops,** and is what strip mining leaves there: near zero
  in a counted loop (the chunk bound folds into the loop bound), a decrement and compare per iteration in a
  general one, and a reload at each chunk boundary. Loops with calls or allocation stop at those already, in
  both designs.
- **Stopping the world by signal is slow.** On an M-series Mac, stopping 8 busy threads by `SIGURG` took 65 µs
  median and 446 µs at p99, against about 1 µs by flag: past P4's 100 µs. LXR ([127](127-lxr-collector.md))
  stops the world often, which multiplies this.
- **Interior pointers.** A stop anywhere in a loop can find only a pointer into an array, its base dead. .NET's
  collector finds the object from it; Immix would need an object-start table (a store on every allocation) or
  bases kept live (a register in the hot loop).
- **Copying stacks.** Frame addresses in registers must be described at every instruction too; .NET does not
  move stacks.
- **Function entry costs the same:** Nomu keeps the entry check for stack growth either way.

The larger gain candidate 3 offers is references and shaped values in registers across calls (243.1: 5–6% and
about 4%), separate from loop polls; [177](177-register-resident-gc-roots.md) measures how much candidate 1
recovers first. Replacing LLVM's statepoint pass with Nomu's own passes (194's candidate 2) stays open as a
later step and does not change this architecture.

**Rejected:**
- Stacks grown by page faults, with no checks: reverses 104 and breaks P5 (one page per fiber, 16 KiB on Apple
  Silicon).
- Extra carrier threads in place of preemption: loop polls stay for G2, and kernel switches cost microseconds.
- Go's signals with a conservative scan of the interrupted frame: unsound with a moving collector and copying
  stacks.

**Policy and mechanism details:**
- **A preempted fiber goes to the global queue,** as Go's does, so an idle carrier can take it.
- **The monitor preempts only when work waits:** a fiber past its slice is flagged only if its carrier has
  queued work. G1 needs no more, and pure compute is not switched for nothing.
- **A carrier held by one C call past a fixed threshold is handed off** (Go's is about 20 µs; the value is
  tuned under [258](258-runtime-policy-tuning.md)).
- **The monitor's period adapts:** short while carriers run long, backing off when idle, as Go's does.
- **One request word per carrier.** A stop-the-world sets every carrier's word; a preemption sets one. A loop
  poll is one load, and the common case is a poll that finds nothing.
- **Blocking syscalls take the single C-call path.** The eager handoff to an offload carrier before every call
  goes: a syscall that does not block pays nothing, and the monitor hands off the carrier of one that does.
- **The runtime's own code has no stops,** under the rule that its loops stay short, checked by a stress test
  (236.8). The stack move is the exception: it grows with the stack, as Go's copy does.
- **Strip mining ([245](245-loop-strip-mining.md)) is a prerequisite of this task,** for G3; the one path for
  calls into C is its own task, [270](270-c-calls-as-stops.md), also a prerequisite.
- **Callbacks from C into Nomu** re-enter while the fiber is marked in C; the marker must nest. Left to
  [130](130-ffi-c-abi.md).
- **The goals are measured inside this task:** G1 by `producer_fiber` and `mixed_fiber`; G2 against Go's time
  to stop all goroutines, measured on the same machine; G5 by a server workload mixing I/O and compute, built
  here on simulated I/O (fibers woken by timers or pipes standing in for requests), deterministic so it also
  serves as a test fixture. G5 is measured again on real sockets once [255](255-networking.md) lands.

## Notes from 252

- Large arguments pass through a frame-split wrapper by pointer, in a slot in an older frame whose references are not
  recorded (`LargeValues.cpp`). That is sound while the stack check's slow path cannot collect. A stop added at the
  check must skip wrappers, which the slow path can tell by a nonzero `need`, or record those slots. Done in 236.4:
  wrappers skip the stop, and only wrappers forward an arrived pointer.
- A return hijack stops a fiber with its result in flight, which the caller's map does not describe: in registers, or
  in the caller's slot for a large result. The stub would need the returning function's result layout.
