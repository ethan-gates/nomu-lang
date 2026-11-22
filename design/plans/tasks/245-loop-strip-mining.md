# Loop strip mining: polls out of the loops the optimizer sees

**Avenue:** Risk (the performance thesis) · **Type/Lifecycle:** `perf · compiler · done` ·
**Size:** M · **Status:** done — loop polls as a placeholder the optimizer moves loads around, strip-mined out of call-free innermost loops before the vectorizer, expanded after optimization; counted loops reach the no-poll speed; loops that keep a bounds check moved to [117](117-loop-improvements.md).2, `bytes`' uninlined calls to [182](182-cross-module-inlining.md) · **Source:** [243](243-frame-mechanism-feasibility.md).1's
measurement; done as [236](236-fiber-preemption.md)'s phase 236.2

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
  against the gain. A chunk would also bound how late [254](254-scheduler-performance.md).3's deferred wake
  (set aside for now) fires when its readier keeps computing.
- **Interaction with the inner loop's exit:** the budget test adds a compare per iteration; check it does not
  cost back what the hoisting gains, and that LLVM removes it where it can bound the trip count.

## The kernel set

A set of compute kernels, call-free loops of the kinds the optimizer inlines into: `frames_loops` (sieve,
matrix product) plus an array scan, a hash probe, a sort's inner loop, byte and string processing, and a
numeric kernel (n-body or spectral-norm). Each built three ways: today's polls, strip-mined, and
`measure_no_loop_polls`. It measures this task, 236's G3 (polls and the stack check under 3% on a tight
loop), and 236.3's change to the poll's form. Built first.

### The kernel set's first results

Built: `benchmarks/loop_kernels` and `tools/loopbench.py`. Release, one carrier, median of 7, checksums equal
across builds:

| kernel | today | no loop polls |
|---|---|---|
| sieve | 71.2 ms | −11.9% |
| matmul | 70.5 ms | −41.7% |
| sum | 104.7 ms | −84.3% |
| count | 107.9 ms | −84.5% |
| probe | 6.1 ms | −8.1% |
| insertion | 44.6 ms | −20.3% |
| bytes | 137.3 ms | −10.4% |
| spectral | 3.4 ms | −6.9% |

The counted loops lose most: without the poll LLVM vectorizes `sum` and `count`, and hoists `matmul`'s loads.
The poll costs more than 243.1's 29% wherever a loop would vectorize.

## Built

Three parts, in LLVM's pipeline (`src/llvmpasses/LoopPolls.cpp`; `backend.md`, the loop poll):

1. **The placeholder.** Codegen emits each loop header's poll as `nomu.loop.poll(flag, slow)`, touching only
   memory the program cannot see, with a `deopt` bundle for the shaped roots live at the header (empty when
   none, so inlining merges a caller's into it). The optimizer keeps it in its loop and hoists the program's
   loads across it. Sound because a stop moves objects only through relocation, which the statepoint rewrite
   applies to every value live across the expanded poll, and rewrites shaped frame words only where they are
   read volatile (`loadReloading`); another fiber changes this fiber's memory only through atomics, actors and
   channels (`unsafe-memory.md` §6 states the rule for raw memory).
2. **Strip mining** (`nomu-strip-mine-loops`, at the vectorizer's start): each innermost loop whose only stop is
   its poll runs in chunks of up to 1,000 iterations (16,384 instructions a chunk at most), the poll in an
   outer loop between chunks. When the latch's exit count is known, each chunk runs
   `min(remaining, 1000)` iterations and the inner latch tests only its counter, so a counted loop keeps one
   countable exit and vectorizes; otherwise the latch's own test is `and`ed with the counter's. A loop with no
   preheader gets one.
3. **Expansion** (`nomu-expand-loop-polls`, after optimization, before the frame-address tracking and the
   statepoint rewrite): the placeholder becomes the stop-flag load and the slow-path call.

### Results

Release, one carrier, median of 7, checksums equal across builds (`tools/loopbench.py`):

| kernel | before | placeholder | strip-mined | no loop polls |
|---|---|---|---|---|
| sieve | 71.2 ms | 67.6 | 72.2 | −13% |
| matmul | 70.5 ms | 52.3 | 50.6 | −22% |
| sum | 104.7 ms | 56.8 | 16.1 | 0% |
| count | 107.9 ms | 56.8 | 16.0 | 0% |
| probe | 6.1 ms | 5.6 | 5.7 | −4% |
| insertion | 44.6 ms | 43.5 | 43.6 | −19% |
| bytes | 137.3 ms | 137.2 | 137.6 | −14% |
| spectral | 3.4 ms | 2.9 | 3.3 | −7% |

The last column is the no-poll build's change against the strip-mined one. Counted loops meet 236's G3.
The loops that keep a bounds check (`matmul`, `insertion`, `sieve`) reload their arrays in the chunk loop;
moved to [117](117-loop-improvements.md).2 with what was ruled out. `bytes` calls `String.byte` and
`String.count` across modules, uninlined, so its loop is not strip-mined: [182](182-cross-module-inlining.md).

Time to stop all fibers in call-free loops (`tools/stopbench.py`, µs p50 / p99 / max): 6 / 21 / 30 at 2
carriers, 10 / 23 / 42 at 4, 17 / 57 / 69 at 8 — under P4's 100 µs. The full suite passes (743 fast, 4,212
full tier).

## Done when

- The kernel set is under 236's G3 (3%) against `measure_no_loop_polls`; `frames_loops` recovers most of the 29% (`tools/frames-ceiling.py`, against the `measure_no_loop_polls`
  build), and the compute benchmarks show no regression.
- The time from a stop request to the fiber stopping, in a long-running loop, stays within the budget 236
  sets, measured.
- The suite passes, including the GC stress legs (a collection reaches every loop within a chunk).

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the array scans, which are call-free loops with a header poll.

## Refs

[243](243-frame-mechanism-feasibility.md) ("Results"); [236](236-fiber-preemption.md) (Architecture; a
prerequisite of it); `src/llvmgen/SSAIRToLLVM.swift` (`emitHeaderPoll`); `internals/loops.md` (the
back edge hosts the poll); `benchmarks/frames_loops`.
