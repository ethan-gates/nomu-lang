# Dynamic fan-out spawn group

**Avenue:** Risk (high-concurrency thesis) · **Type/Lifecycle:** `language-feature · needs-design` ·
**Size:** M · **Status:** designed (`concurrency.md` §8), sequenced after cancellation ·
**Source:** `concurrency.md` §8 (dynamic spawn group)

## What

The dynamic fan-out spawn group (`concurrency.md` §8) — runtime-sized structured concurrency (spawn
an unbounded/data-driven number of children), beyond today's static `spawn let` fan-out.

## Why deferred

Sequenced after [cancellation](135-cancellation-continuations.md) (decided 2026-08-10): it rides the
structured-cancellation model for its fail-fast error mode. Its motivating use — benchmarking highly
concurrent workloads — can wait, and static `spawn let` fan-out already ships.

## Dependencies & triggers

- **Depends on:** cancellation (fail-fast error mode).
- **Carries:** [growable fiber stacks + syscall-free context switch](104-fiber-stack-strategy.md) ride on
  this (decided 2026-08-14). Fixed 128 KiB stacks and `swapcontext`'s per-switch signal-mask syscall
  only bite under massive fan-out — which this group is what creates. The GC-precision prerequisite
  is already met (M9 statepoints + M6 parked-fiber scan). So those are perf-tail engineering gated on
  this *workload*, measurable on this group's own benchmark the day they land.

## How

Per `concurrency.md` §8; fail-fast on first child error via the cancellation model.

## Refs

`concurrency.md` §8 (dynamic spawn group), §7 (cancellation);
[fiber-stack-strategy](104-fiber-stack-strategy.md).
