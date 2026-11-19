# Fiber preemption: a running fiber keeps its carrier until it parks

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · issue defined`
· **Size:** M–L · **Status:** 236.1 done (baselines below); 236.2 (245) next · **Source:** [234](234-scheduler-wake-and-pool.md).3's
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
- **236.2 Strip mining: task [245](245-loop-strip-mining.md).** Its kernel set first, then the transformation.
  After 236.1, so the baselines are taken before loops stop differently; before 236.3, which checks the poll's
  new form on the kernel set. Carries G3.
- **236.3 One request word.** The request word is the running fiber's stack limit: a stop-the-world or a
  preemption poisons it, as Go does its stack guard, and switching a fiber in restores it. The loop poll
  becomes the entry check's compare (SP against the limit, one load through x28), and `rtStopWorld` goes.
  Poll cost checked on 245's kernel set.
- **236.4 Stops at function entry.** The entry check's slow path tells an overflow from a request and parks
  on a request; a frame-split wrapper (a nonzero `need`) skips the stop (notes from 252). Closes the
  stop-the-world gap in recursion and straight-line code; G2 re-measured.
- **236.5 The monitor and preemption.** An adaptive monitor thread. Each carrier counts its switches; a count
  unchanged across two ticks means a fiber has run past its slice, as Go's `sysmon` sees it, with no clock
  read on the switch path. It preempts only when that carrier has queued work, and the preempted fiber goes
  to the global queue. 254.3's deferred wake checked against it; G1 re-measured.
- **236.6 Calls into C as stops: task [270](270-c-calls-as-stops.md).** The in-C record, collection without
  waiting, carrier handoff, the eager syscall offload retired. Needs 236.3 and 236.5. Carries G2's C-call
  part and G4.
- **236.7 The runtime's own code.** A stress test that stops the world while fibers are in runtime loops,
  holding G2 under the rule that those loops stay short. Any time after 236.4.
- **236.8 Verify and fold.** G1–G5 against 236.1's baselines. The design folds into `runtime.md` §6 and
  `concurrency.md`.

Phases run in number order. 236.2 and 236.6 are tasks of their own, done as phases of this one.

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
- **The runtime's own code has no stops,** under the rule that its loops stay short, checked by a stress test.
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
  check must skip wrappers, which the slow path can tell by a nonzero `need`, or record those slots.
- A return hijack stops a fiber with its result in flight, which the caller's map does not describe: in registers, or
  in the caller's slot for a large result. The stub would need the returning function's result layout.
