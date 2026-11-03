# Loop strip mining: polls out of the loops the optimizer sees

**Avenue:** Risk (the performance thesis) · **Type/Lifecycle:** `perf · compiler · ready-to-design` ·
**Size:** M · **Status:** not started · **Source:** [243](243-frame-mechanism-feasibility.md).1's
measurement

## The cost

A loop that reaches no other safepoint gets a poll at its header: a load of the stop flag and a branch to a
slow path that calls into the runtime. The slow path is a call that may write memory, so LLVM must assume
anything loaded from memory may have changed after it, and the relocation after it makes every reference
used in the loop a phi of itself and its moved copy. In 243.1's call-free array loops (`frames_loops`: a
sieve and a matrix product) the polls cost 29%: with them, each array's count and buffer pointer are reloaded
every iteration; without them, those loads are hoisted out of the loop. Elsewhere the polls cost nothing
measurable. A poll is also a barrier to hoisting a read-only call out of a loop (243.1's artifact).

## The transformation

Run each such loop in chunks of up to `K` iterations, with the poll only between chunks:

```
while cond {                 // outer: polls once per chunk
    var budget = K
    while cond && budget > 0 {   // inner: no poll
        body
        budget = budget - 1
    }
}
```

The inner loop has no safepoint, so LLVM hoists loads, rematerializes addresses and, where bounds checks
allow, unrolls and vectorizes it as any ordinary loop; references are relocated only at chunk boundaries.
The budget counter works for any `while` loop, counted or not. HotSpot's C2 does the same for its loops'
safepoint polls (about 1,000 iterations per strip by default).

## To decide

- **Where:** in SSAIR, where loops and the header poll (`emitHeaderPoll`) are explicit, or as a step of the
  egress when it emits the poll.
- **Which loops:** those whose only stop is the header poll; nested loops get it at the innermost poll-only
  level. A loop with a call that can stop gains nothing (the call is the barrier) and is left alone.
- **`K`:** a constant, or chosen per loop from the body's size, so a chunk's time stays within the
  stop-the-world and preemption latency budgets ([236](236-fiber-preemption.md)). Measure the latency
  against the gain.
- **Interaction with the inner loop's exit:** the budget test adds a compare per iteration; check it does not
  cost back what the hoisting gains, and that LLVM removes it where it can bound the trip count.

## Done when

- `frames_loops` recovers most of the 29% (`tools/frames-ceiling.py`, against the `measure_no_loop_polls`
  build), and the compute benchmarks show no regression.
- The time from a stop request to the fiber stopping, in a long-running loop, stays within the budget 236
  sets, measured.
- The suite passes, including the GC stress legs (a collection reaches every loop within a chunk).

## Refs

[243](243-frame-mechanism-feasibility.md) ("Results"); [236](236-fiber-preemption.md) ("Asynchronous
preemption", option (e)); `src/llvmgen/SSAIRToLLVM.swift` (`emitHeaderPoll`); `internals/loops.md` (the
back edge hosts the poll); `benchmarks/frames_loops`.
