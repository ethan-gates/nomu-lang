# Frame mechanism generality: what other LLVM languages could reuse

**Avenue:** Risk · **Type/Lifecycle:** `research` · **Size:** M · **Status:** not started; sixth of
[194](194-gc-frame-metadata.md)'s children (with 242 and 243) · **Source:** 194

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

The evaluation; the generality part of 245's series.

## Refs

[194](194-gc-frame-metadata.md); [239](239-frame-metadata-prior-art.md); [242](242-frame-mechanism-designs.md).
