# Fiber stack strategy: growth, overflow, high-fiber-count throughput

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design`
(runtime + compiler architecture) · **Size:** L · **Status:** evaluate · **Source:** deferred.md
(2026-08-18) + roadmap M8

**► Decide-early: before M8.** M8 scopes growable fiber stacks; the fixed-vs-dynamic decision must
precede that build. Runtime + codegen shape depend on it. Design-ahead, not build-ahead.

## What

Decide how fibers get their stacks so Nomu runs very high fiber counts at throughput beating Go/Swift.
Today: fixed `RT_STACK_SIZE` = 128 KiB per fiber (`runtime.c`), no stack-overflow detection/recovery,
no compile-time bound analysis. The space to evaluate:
- **Fixed stacks** (current) — free prologues, high memory floor.
- **Guard-page + lazy commit** — reserve large virtual, fault in physical pages. Mostly a runtime
  change (mmap layout + fault handler); codegen/ABI largely untouched. Lowest ripple; costs virtual
  address space, hard to shrink.
- **Copy-on-grow / movable stacks** — relocate on overflow, fixing interior pointers via precise
  stack maps. Highest ripple (codegen prologue check / fault trampoline, calling convention, GC
  pointer fix-up); matches Go's proven high-fiber model.
- **Segmented stacks** — rejected historically by Go (hot-split).
- **Compile-time stack-depth analysis** — bound per call-graph; size statically or flag unbounded
  recursion. A new whole-program pass (recursion + indirect/witness calls are the hard cases);
  complements either runtime scheme.

The answer is likely a hybrid.

## Why it's open — the tensions

- **Memory floor per fiber** sets the max fiber count in RAM (128 KiB × millions is the ceiling); a
  smaller default + growth unlocks massive fan-out (the [dynamic spawn group](103-dynamic-spawn-group.md)
  workload).
- **Context-switch + call cost.** Fixed stacks keep prologues check-free; Go-style growth adds a
  per-call `morestack` check (a throughput tax); guard-page recovery keeps prologues free but pays on
  the fault.
- **GC coupling.** Moving a stack relocates every root + interior pointer — enabled by M9 statepoints
  + the M6 parked-fiber precise scan; copy-on-grow reuses that walk.

## Dependencies & triggers

- **Trigger:** roadmap M8 (growable stacks + syscall-free switch, riding the dynamic spawn group).
  Bring the *decision* ahead of the build.
- **Couples with:** [TCO](129-tail-call-optimization.md) (lowers stack depth, eases the memory floor),
  GC statepoints, the dynamic spawn group.

## How

Quantify what each option forces to be rewritten (blast radius), so the choice is made with ripple
known. Likely hybrid: a runtime scheme (guard-page or copy-on-grow) plus optional compile-time bound
analysis.

## Refs

`runtime.md` §6 (safepoints, parked-fiber scan, mutator); roadmap M8; `runtime.c` `RT_STACK_SIZE` +
`swapcontext`.
