# Frames: moving collection and copying stacks on LLVM

An explanatory series for engineers who know compilers in general but not collector internals: why a
moving collector and copying fiber stacks are hard to support in an LLVM-compiled language, what others
did, and how Nomu solves it. It is written alongside task 194's children
([194](../plans/tasks/194-gc-frame-metadata.md), [245](../plans/tasks/245-frame-literature.md)), each part
when its step finishes, so the explanation and the evidence agree.

## Parts

1. The problem (not yet written).
2. Background: safepoints, stack maps, statepoints (not yet written).
3. [Prior art](frames-prior-art.md): how other implementations move heap objects and grow stacks, and why none of
   their conditions holds for Nomu.
4. [What Nomu built on statepoints, and where it fell short](frames-statepoints.md): the inventory from 240.
5. [The contract](frames-contract.md): what must hold wherever a fiber can stop, from 241.
6. The design and its evidence: [the candidates and the leading design](frames-designs.md), from 242; the
   evidence, from 243, not yet written.
7. Limits and generality (from 244; not yet written).
