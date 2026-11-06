# Channels

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** designed direction, unbuilt; the base of the concurrency surface ([250](250-fiber-task-surface.md)) · **Source:** `concurrency.md` §4 (channels as a deferred library)

## What

The channels library — typed communication between fibers/tasks on the M:N runtime. Part of the concurrency-completion set.

## Why now

`Task` is written over a one-shot channel, and stop signals are closed channels (`concurrency.md` §7, §8),
so channels come first in the concurrency surface. Channels implement the iteration protocol
([117](117-for-in-iteration.md)).

## Dependencies & triggers

- **Ready:** M:N scheduler, poller, park/unpark, async actor runtime.
- **Interacts with:** `select`, intended to cover poller-backed reads and timers as well (`concurrency.md`
  §7), and shareability (values crossing a channel are a task boundary — the
  shareability rule applies).

## How

- Build on park/unpark for blocking send/receive on the colorless model.
- Enforce shareability at the channel boundary (values sent must be shareable, `concurrency.md` §5).

## Refs

`concurrency.md` §5 (shareability), §9 (actor runtime); `runtime.md` (scheduler,
park/unpark).
