# `defer` + linear types

**Avenue:** Usability (resource cleanup) · **Type/Lifecycle:** `language-feature · needs-design` ·
**Size:** M · **Status:** cross-cutting; sequenced with the concurrency-completion work ([135](135-cancellation-continuations.md)) · **Source:** cross-cutting design note

**► Decide-early:** the resource-management story (this + [`deinit`/finalization](108-deinit-finalization.md))
is one problem space — decide the fork (GC-finalized `deinit` vs deterministic cleanup only through
linear/`defer`) alongside this. Design-ahead, not build-ahead.

## What

- **`defer`** — scoped cleanup that runs on scope exit. Wanted as soon as the language does I/O
  (a cross-cutting design note: wanted as soon as the language does I/O).
- **Linear types** — the type discipline behind resume-once (continuations) and resource cleanup
  (a resource must be consumed exactly once). First hard requirement is continuations ([135](135-cancellation-continuations.md)).

## Why deferred

Linear types' first concrete consumers are [continuations](135-cancellation-continuations.md)
(resume-once) and resource cleanup. `defer` is useful earlier but was parked with the resource story.

## Dependencies & triggers

- **Pairs with:** [cancellation + continuations](135-cancellation-continuations.md) (resume-once
  enforcement).
- **Gates:** the resource-management contract and the [`deinit`](108-deinit-finalization.md) fork.

## How

- `defer` lowers to scope-exit cleanup blocks (interacts with early return, cancellation, and
  continuation resume paths).
- Linear types: a use-exactly-once discipline enforced in Sema; define what is linear (continuations,
  resource handles) and the move/consume rules.

## Refs

Cross-cutting design (error handling / `defer` / linear types); `concurrency.md` §7.
