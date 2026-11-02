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

## Dependents

- **[104](104-fiber-stack-strategy.md)**: its entry check is the natural place for a function-entry poll.
- **The benchmark against Go and Swift** (`horizon.md`): a workload mixing long computations with
  latency-sensitive work would measure this.

## Refs

`src/stdlib/runtime/scheduler.nomu` (`nomuSchedSafepoint`, `rtSchedPick`'s slice);
`src/llvmgen/SSAIRToLLVM.swift` (the loop-header poll); `src/llvmgen/LLVMGenRuntime.swift`
(`emitSafepointPoll`); `runtime.md` §6 (safepoints); 234.3's results; `tools/schedbench.py`.
