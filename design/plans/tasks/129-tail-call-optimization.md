# Tail-call optimization

**Avenue:** Usability (the guarantee) / Perf (the optimization) · **Type/Lifecycle:** `perf ·
needs-design` (the guarantee question is `language-feature`) · **Size:** M · **Status:** needs-design
· **Source:** deferred.md (2026-08-18)

## What

Reuse the caller's frame for a call in tail position, so tail recursion (and mutual recursion) runs in
constant stack space.

## Two scopes

- **Self-tail-call → loop** — a small SSAIR pass. Rewrite a function's tail call to itself into a
  back-edge to entry with parameter reassignment (tail-recursive function → loop). High value,
  self-contained, the common case. (In `../ssair-backlog.md` §5.)
- **General proper tail calls** (to any function, mutual recursion, trampoline/CPS) — larger. Needs
  the frontend/backend to emit LLVM `musttail`, a uniform calling convention across the tail edge, and
  care around the moving GC (`musttail` + statepoints have known friction; the safepoint/stack-map
  story must hold when the frame is replaced).

## The real fork — guarantee vs best-effort

Is TCO a **language guarantee** (unbounded tail recursion always safe, Scheme-style) or a
**best-effort optimization** (applied when it can be, Swift/Go-style)?
- *Guaranteed* is a programmer-expectation contract; forces the general-proper-tail-call machinery;
  interacts with the [fiber stack strategy](104-fiber-stack-strategy.md) and GC statepoints.
- *Best-effort* is a pure optimization; the self-tail-loop pass covers most of the real-world win.

## Roadmap assessment

**One-liner pointer — for the guarantee decision only.** The optimization is deferred-only (an
SSAIR/LLVM pass). The guarantee couples with the stack-strategy item. **Default lean:** best-effort
self-tail-loop first; revisit a guarantee if a functional style or the self-hosting runtime wants it.

## Refs

deferred.md "Tail call optimization"; `../ssair-backlog.md` §5; [fiber stack strategy](104-fiber-stack-strategy.md).
