# Stack-check elision: one check covers a call tree

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · compiler ·
needs-design` · **Size:** L · **Status:** after [104](104-fiber-stack-strategy.md)'s entry check is built and
its cost measured · **Source:** 104's design (moved out when the entry check was decided)

104 checks every non-runtime function on entry: a load, a compare and a branch on every call. This task
drops checks the program can prove unneeded. Its gain is measured against 104's every-function check, and
whether it is worth building follows from that cost.

## The reasoning

A check asks whether there is room *from where the stack pointer is now*, whatever the callers used. So:

- **A bound per call tree.** Inference gives each function `max_stack(f)`: its own frame plus the largest
  bound among its callees. It exists when the whole tree is known: no recursion, no calls through an
  interface or a function value, every callee's bound known (from other modules through their interface
  summaries).
- **One check covers the tree.** When `f` checks for `max_stack(f)` on entry, everything `f` calls has room
  by construction, so its callees skip their checks when called from `f`.
- **Two entries per function.** A function is compiled once and called from many places: a checked entry
  for callers that have not covered it (calls through an interface, unanalyzed code, a fiber's start), an
  unchecked one for callers whose check covered its tree. The bound belongs to the callee; each caller
  chooses the entry from what its own check covered.
- **Limits.** Recursion and dynamic calls keep per-call checks, though bounded trees below them are still
  covered. A tree whose bound is large is not folded into one check, which would grow small stacks for a
  rarely taken deep path; only trees under a threshold of a few KiB are.
- **Precedent.** Go keeps a guard zone of a few hundred bytes at the end of every stack, runs small
  `nosplit` functions with no check, and has its linker verify across the program that each chain of them
  fits in the zone: the same reasoning, for leaf code.

## Constraints

- **Bounds come only from analysed Nomu code.** A frame size is LLVM's reported one (104's verification);
  a call into code Nomu does not own runs on the carrier's stack and contributes nothing to a fiber's
  bound (104, calls into libc). No bound is ever assumed.
- **Preemption** ([236](236-fiber-preemption.md)) shares 104's check: a tree covered by one check reaches
  no further check, so a fiber in it is preempted only at the covering check or at a loop-header poll.
  Folding only small trees keeps that delay short.

## Refs

[104](104-fiber-stack-strategy.md) (the entry check, its measured cost); [236](236-fiber-preemption.md).
