# Shared-mutable primitive

**Avenue:** Risk (concurrency model) · **Type/Lifecycle:** `language-feature · ongoing` · **Size:** M ·
**Status:** design ongoing (M5 generics unblocked it) · **Source:** roadmap ("Ongoing")

## What

The shared-mutable primitive — the escape hatch for genuinely shared mutable state under the
race-free-by-construction concurrency model. The design needs M5 generics (now present), so it can
proceed.

## Why deferred

Listed "Ongoing" on the roadmap; it needed the M5 generics + the completed shareability checker
(deeply-immutable classes, `String`, `<shared T>` bound) as a foundation. Those shipped.

## Dependencies & triggers

- **Ready:** M5 generics + shareability checker.
- **Interacts with:** the shareability rule (`concurrency.md` §5), the value/reference split.

## Refs

roadmap "Ongoing" (shared-mutable primitive design); `concurrency.md` §5 (shareability); `generics.md`
§7 (`<shared T>`).
