# Actor fiber-aware mutex

**Avenue:** Risk (runtime correctness/perf) · **Type/Lifecycle:** `perf · refactor · ready-to-build` ·
**Size:** M · **Status:** the one open thread from the C→LLVM transition · **Source:** deferred.md
(C→LLVM checklist tail)

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
