# Frames: moving collection and copying stacks on LLVM

The design documents of task [194](../plans/tasks/194-gc-frame-metadata.md): how Nomu describes its frames to
the runtime so a moving collector and copying fiber stacks are both sound on LLVM.

- [Prior art](frames-prior-art.md): how other implementations move heap objects and grow stacks (239).
- [What Nomu built on statepoints, and where it fell short](frames-statepoints.md): the inventory (240).
- [The contract](frames-contract.md): what must hold wherever a fiber can stop (241).
- [The designs](frames-designs.md): the candidates and the leading one (242); its evidence is
  [243](../plans/tasks/243-frame-mechanism-feasibility.md)'s results.
- [Limits and generality](frames-generality.md): what another LLVM language could reuse (244).
