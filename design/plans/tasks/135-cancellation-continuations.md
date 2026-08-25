# Cancellation + one-shot continuations

**Avenue:** Risk (concurrency thesis) · **Type/Lifecycle:** `language-feature · needs-design` ·
**Size:** L · **Status:** designed in `concurrency.md`, unbuilt · **Source:** roadmap M8

## What

The M8 concurrency-completion core:
- **Safepoint-automatic cancellation** — cancellation that propagates on the M6 safepoints already
  emitted, reaching parked children (structured-scope cancellation propagation).
- **The checked one-shot continuation** — a resume-once suspension primitive. Resume-once is
  enforced by linear types (see [`defer` + linear types](101-defer-linear-types.md)).

These two are tightly coupled — the continuation's resume-once discipline and cancellation both ride
the structured-concurrency model — so they share one task.

## Why deferred

The M:N runtime (M4) and the async actor runtime (M6 §9) are the substrate; cancellation and
continuations sit on top and were sequenced into M8. The safepoint infrastructure they need
(precise stack maps + parked-fiber scan) landed with M9/M6.

## Dependencies & triggers

- **Ready:** M6 safepoints, the async actor runtime, structured spawn/scope, M9 statepoints.
- **Needs:** linear types (resume-once + resource cleanup) — the [`defer` + linear types](101-defer-linear-types.md)
  task is the first hard requirement for linear types and pairs with this.
- **Feeds:** the [dynamic spawn group](103-dynamic-spawn-group.md) rides this cancellation model for its
  fail-fast error mode (decided 2026-08-10).

## How

- Cancellation checks at existing safepoints; propagate a cancel flag down the structured scope to
  parked children; define the cancellation semantics precisely (owed to M12 hardening).
- The continuation as a checked one-shot: linear typing makes double-resume a compile error.

## Refs

`concurrency.md` §7 (cancellation), §8 (structured scope), §9 (actor runtime); `runtime.md` §6
(safepoints, parked-fiber scan); roadmap M8.
