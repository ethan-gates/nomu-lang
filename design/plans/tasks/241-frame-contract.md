# The frame contract: what must hold at every point a fiber can stop

**Avenue:** Risk · **Type/Lifecycle:** `design` · **Size:** M · **Status:** done; third of
[194](194-gc-frame-metadata.md)'s children (after 239 and 240) · **Source:** 194

## Deliverable

The requirements any frame mechanism must meet, precise enough to test. It owns the contract 194 states in
summary:

> At every point where the runtime can stop a fiber (every call that can reach a safepoint or a stack
> check), every live value the runtime must find is in a location it can locate, and the code reads it
> back from there afterwards.

## Priorities

Soundness is required: a mechanism that can leave a stale reference or a stale stack address is rejected,
however rare the case. Among sound mechanisms, run-time performance and predictability come first (the
mutator's cost at and between stopping points, no performance cliffs from small edits); implementation and
maintenance cost come after. Writing Nomu's own LLVM passes, run after the statepoint rewrite or replacing
an LLVM pass, is in scope where LLVM's ordering causes friction.

## To make precise

- **The stopping points:** which calls and polls, and what holds at each (frames below all at calls).
- **The values:** live heap references (including derived and interior pointers, and shaped values whose
  managed-ness is dynamic, 176); live addresses into the fiber's stack (stack-promoted objects,
  struct-return and by-reference slots, any address computed from a frame); arguments in registers at a
  stack check; the frame-pointer chain.
- **The users:** the moving collector, the stack copier, interprocedural stack promotion; what each reads,
  updates, and relies on.
- **What the frontend guarantees:** no heap pointer into a stack (escape analysis), no foreign code holding
  stack addresses (libc runs on the carrier's stack, 104), the runtime's own code exempt (the runtime
  subset).
- **What the linker and loader must preserve:** dead stripping, folding, multiple images (194's table).
- **How each requirement is tested:** the stress modes (a collection at every safepoint, a stack moved at
  every check, the old stack made inaccessible) and what a violation looks like.

## Output

The requirements document is [`internals/frames-contract.md`](../../internals/frames-contract.md), part 5 of
245's series: stopping points, value kinds (H1–H3, S1–S2, S3, R), requirements R1–R8, guarantees G1–G4,
toolchain T1–T3, the tests, and a measurement of today's generated code. Found on the way: task
[246](246-raw-pointers-into-managed-memory.md), a live bug (`String.eq` reading a moved buffer).

## Refs

[194](194-gc-frame-metadata.md); [104](104-fiber-stack-strategy.md); [176](176-shaped-gc-roots.md);
[148](148-ssair-optimizer-tier.md) §148.1; 239 and 240's outputs.
