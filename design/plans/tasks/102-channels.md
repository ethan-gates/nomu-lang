# Channels

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** designed direction, unbuilt · **Source:** `concurrency.md` §4 (channels as a deferred library)

## What

The channels library — typed communication between fibers/tasks on the M:N runtime. Part of the concurrency-completion set.

## Why deferred

Sits on the M:N runtime (M4) and the async actor runtime (M6 §9); sequenced with the rest of
the concurrency surface. Actors + structured spawn already cover the common cases, so channels
waited.

## Dependencies & triggers

- **Ready:** M:N scheduler, poller, park/unpark, async actor runtime.
- **Interacts with:** [cancellation](135-cancellation-continuations.md) (a blocked channel op must be
  cancellable at a safepoint) and shareability (values crossing a channel are a task boundary — the
  shareability rule applies).

## How

- Build on park/unpark for blocking send/receive on the colorless model.
- Enforce shareability at the channel boundary (values sent must be shareable, `concurrency.md` §5).

## Refs

`concurrency.md` §5 (shareability), §9 (actor runtime); `runtime.md` (scheduler,
park/unpark).
