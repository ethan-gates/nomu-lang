# Frame literature: explaining the problem and the solution

**Avenue:** Risk · **Type/Lifecycle:** `docs` · **Size:** M · **Status:** in progress (parts 3–5 and the design half of 6 written); written alongside
[194](194-gc-frame-metadata.md)'s children, each part as its step finishes · **Source:** 194

## Deliverable

A short series in `internals/`, indexed by [`frames.md`](../../internals/frames.md), for engineers and compiler engineers who know compilers
in general but not collector internals, explaining why moving collection and copying stacks are hard on
LLVM, and how Nomu solves it.

## Parts

1. **The problem:** what a moving collector and a copying stack each need from compiled code, and why an
   optimizing backend like LLVM makes it hard.
2. **Background:** safepoints, stack maps, statepoints, from scratch.
3. **Prior art** ([239](239-frame-metadata-prior-art.md)): written, [`frames-prior-art.md`](../../internals/frames-prior-art.md).
4. **What Nomu had and why it fell short** ([240](240-statepoint-inventory.md)): written, [`frames-statepoints.md`](../../internals/frames-statepoints.md).
5. **The contract** ([241](241-frame-contract.md)): written, [`frames-contract.md`](../../internals/frames-contract.md).
6. **The design and its evidence** ([242](242-frame-mechanism-designs.md), [243](243-frame-mechanism-feasibility.md)).
7. **Limits and generality** ([244](244-frame-mechanism-generality.md)).

Each part is written when its step is done, from that step's output, so the explanation and the evidence
agree. If the result is new, the series is the start of a paper or a public write-up.

## Refs

[194](194-gc-frame-metadata.md) and its children.
