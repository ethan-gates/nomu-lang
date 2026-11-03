# Frame mechanism generality: what other LLVM languages could reuse

**Avenue:** Risk · **Type/Lifecycle:** `research` · **Size:** M · **Status:** in progress, open until the
passes are tested on another target (x86-64 at least); sixth of [194](194-gc-frame-metadata.md)'s children (with 242 and 243) · **Source:** 194

## Deliverable

An evaluation of how general 194's solution is: whether language implementers who want a moving collector
with copying stacks on LLVM could use it, and what they would need.

## Questions

- **What depends on Nomu's frontend:** escape analysis keeping the heap from pointing into stacks, no
  foreign code holding stack addresses, the runtime subset, Nomu's own IR (SSAIR) placing values.
- **What depends only on LLVM:** the mechanism itself, the frame-table format, the stack copier's rules.
- **Preconditions** another language must meet, and which common language features break them (C
  interoperation passing stack addresses, unrestricted address-taking, threads with native stacks).
- **Packaging:** a library over LLVM, a pass others can add, or a proposal upstream; what each would take.

## Output

The evaluation, [`internals/frames-generality.md`](../../internals/frames-generality.md).

## Results

The evaluation is [`internals/frames-generality.md`](../../internals/frames-generality.md). In short: the
two passes (K2 and the tracking, about 500 lines of C++) depend only on LLVM; the rest rests on seven
guarantees from Nomu's frontend and runtime (stack addresses only flow down, none in frame memory across a
stop, possibly-stack pointers marked, none into the heap's interior, foreign code and the runtime hold none
across a stop, frame pointers kept). Packaging as a library is close to what exists (the tracking is now a named pass in Nomu's pipeline); upstreaming needs an
intrinsic in place of the inline-asm marker, x86-64 testing and a second user.

## Refs

[194](194-gc-frame-metadata.md); [239](239-frame-metadata-prior-art.md); [242](242-frame-mechanism-designs.md).
