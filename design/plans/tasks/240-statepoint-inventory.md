# Statepoint inventory: what Nomu relies on, and what it has cost

**Avenue:** Risk · **Type/Lifecycle:** `research` · **Size:** M · **Status:** done; second of
[194](194-gc-frame-metadata.md)'s children · **Source:** 194

## Deliverable

An inventory, file by file, of how Nomu's code generation and runtime use LLVM's statepoints and stack
maps today, and every problem they caused, each with its root cause. It tells 194 what a replacement must
provide, and which problems are the machinery's and which are Nomu's.

## Contents

- **What statepoints provide** to Nomu: relocation after a moving collection (`gc.relocate`), derived
  pointers, the rewriter's spilling of live references, the optimizer's view of `addrspace(1)` values, the
  deopt bundle carrying shaped roots, the stack-map section the walkers read. For each: where it is used
  (codegen, runtime, linker steps) and what building it ourselves would take.
- **Every problem hit,** from the task history and the code's comments: the link-time index and its
  ordinal collisions and dead functions (195); shaped roots and the stale `String` after a moving
  collection (176, 176.5); `musttail` (129); register-resident roots (177); the `addrspacecast` the
  rewriter rejects (the spawn environment parameter, interprocedural promotion); the optimizer coupling of
  `rtCollectRoots`; others found on the way. For each: the symptom, the root cause, and whether a
  replacement would remove it.

## Output

The inventory is [`internals/frames-statepoints.md`](../../internals/frames-statepoints.md), part 4 of 245's
series: 22 problems, 15 tracing wholly or partly to the machinery, each with its cause, owner, status and
whether a replacement removes it.

## Refs

[194](194-gc-frame-metadata.md); [176](176-shaped-gc-roots.md); [195](195-link-time-gc-frame-index.md);
[129](129-tail-call-optimization.md); [177](177-register-resident-gc-roots.md); `internals/backend.md`
("GC backend substrate"); `selfhosted-gc.md`.
