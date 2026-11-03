# Fiber preemption: a running fiber keeps its carrier until it parks

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · issue defined`
· **Size:** M–L · **Status:** issue defined; the fix open · **Source:** [234](234-scheduler-wake-and-pool.md).3's
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

## Asynchronous preemption

Stopping a fiber at an arbitrary instruction, by a signal to its carrier, as Go has done since 1.14.

**When Nomu needs it.** Go added it because its loops had no polls: a call-free loop could hold a goroutine
and stall a collection indefinitely. Nomu polls at every loop header that reaches no other safepoint, and
104's entry check covers recursion, so every fiber reaches a stop within a bounded number of instructions
without signals. Two cases remain:

- **Performance:** the polls cost a load and a branch per iteration in a tight loop. Signals let the polls
  go. 243.1 measures what removing them is worth.
- **Code with no stops by design:** the runtime subset (no polls) and calls into C, which run on the
  carrier's stack. Neither needs signals: runtime loops must be short, and a fiber in a long C call is
  treated as Go treats a goroutine in a system call (its carrier is handed off, the fiber counts as stopped).

So it is an optimization, gated on 243.1, and a constraint on the frame mechanism: whichever 194 chooses
decides whether it is possible.

**How, under a moving collector.** A signal stops a fiber between stops, where call-site maps do not
describe its innermost frame. The options:

- **(a) Maps at every instruction** ("fully interruptible" code, as in .NET): the interrupted frame is
  described wherever it stopped. Needs 194's candidate 3 (Nomu's machine-level frames); statepoints record
  only calls.
- **(b) Hijack the return:** the signal handler replaces the interrupted function's return address with a
  runtime stub, so the fiber stops when that function returns, at its caller's call site, which has a map.
  .NET uses this for code without per-instruction maps. Works with call-site maps (candidates 1 and 2), but
  a function in a loop does not return soon, so loops keep their polls. It removes polls only from the
  entry check, and the entry check stays for stack growth.
- **(c) Scan the interrupted frame conservatively** and pin what it might reference, as Go treats its
  innermost frame (Go's collector does not move objects). Under Nomu's moving collector the pinned objects
  stay put for that collection. Unsound for a stack copier, which must know which words are addresses, so
  the stack cannot move while a fiber is stopped this way.
- **(d) A signal as a kick only:** the handler sets the fiber's preemption flag and returns, and the fiber
  stops at its next poll. Lower latency than waiting for a monitor's check, and keeps the polls.
- **(e) Keep the polls, make them cheap: loop strip mining.** 243.1 measured the polls at 29% of a call-free
  array loop, almost all of it lost hoisting: the poll's slow path is a call that may write memory, so
  array counts and buffer pointers are reloaded every iteration. Running the loop in chunks of about a
  thousand iterations, with the poll only between chunks, lets the optimizer hoist within each chunk and
  bounds the delay to a stop by the chunk's length (HotSpot's C2 does this). It needs no signals and no new
  frame mechanism, so it works with every candidate. Task [247](247-loop-strip-mining.md).

Only (a) removes loop polls with a moving collector and copying stacks, and (e) removes most of their cost
without removing them; it is the third of candidate 3's
advantages in 194's comparison ([`internals/frames-designs.md`](../../internals/frames-designs.md)).

## Dependents

- **[104](104-fiber-stack-strategy.md)**: its entry check is the natural place for a function-entry poll.
- **The benchmark against Go and Swift** (`horizon.md`): a workload mixing long computations with
  latency-sensitive work would measure this.

## Refs

`src/stdlib/runtime/scheduler.nomu` (`nomuSchedSafepoint`, `rtSchedPick`'s slice);
`src/llvmgen/SSAIRToLLVM.swift` (the loop-header poll); `src/llvmgen/LLVMGenRuntime.swift`
(`emitSafepointPoll`); `runtime.md` §6 (safepoints); 234.3's results; `tools/schedbench.py`.
