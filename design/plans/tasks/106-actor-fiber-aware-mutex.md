# Actor fiber-aware mutex

**Avenue:** Risk (runtime correctness/perf) · **Type/Lifecycle:** `perf · refactor · ready-to-build` ·
**Size:** M · **Status:** done — obsolete; the mailbox runtime replaced the mutex (closed by [261](261-actor-follow-ups.md).2) · **Source:** deferred.md
(C→LLVM checklist tail)

## Closed

Actors hold no mutex. An actor object is class-shaped with a mailbox in its last slot; a send pushes its
message lock-free and schedules the mailbox with a compare-and-swap on its `scheduled` word, so one mailbox
fiber at a time drains it (`nomuSchedActorSend`, `nomuSchedMailboxPop` in `runtime/scheduler.nomu`). A
handler runs on a pooled mailbox fiber; when it parks, that fiber parks, and the carrier takes another fiber
from the pool. Nothing in a handler blocks a carrier.

## What

Replace the `pthread_mutex_t` embedded in actor structs with a **fiber-aware (park/unpark) mutex**, so
a held handler doesn't block a carrier thread. Today an actor object is `{ header, fields…, mu }` and
its handlers lock a `pthread_mutex_t`; a blocked lock parks the OS thread rather than the fiber.

## Why deferred

The mutex-serialized actor scaffold shipped in M3 and the async actor runtime shipped in M6 §9; the
`pthread_mutex_t` remained as the carrier-blocking placeholder. Everything else on the C→LLVM
transition checklist retired with M9/M6 — this is the last open thread.

## Dependencies & triggers

- **Ready:** the M:N runtime provides park/unpark; the async actor runtime is built.
- **Feeds:** [concurrency hardening](105-concurrency-hardening.md) (the park protocol is what M12
  stress-tests).

## How

Swap the `pthread_mutex_t` for a fiber-aware mutex that parks the fiber (not the carrier) on
contention, integrating with the scheduler's park/unpark and the safepoint handshake.

## Refs

`concurrency.md` §9 (actor runtime), `runtime.md` (scheduler, park/unpark); deferred.md "C → LLVM
transition checklist — complete".
