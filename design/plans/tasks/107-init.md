# `init` — custom initializers

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

## What

Custom initializers beyond today's synthesized memberwise `T(field:)`. Opens:
- init-body validation / normalization,
- multiple inits + overload resolution,
- failable init (`init?` → `Option`/`Result`),
- designated-vs-convenience (if any),
- default field values.

## Why deferred

The memberwise-only form is a placeholder that works for now; custom init reshapes the construction
contract and was parked for a dedicated design pass.

## Roadmap assessment (three-head)

**One-liner pointer.** Reshapes the construction contract (programmer-expectation) but rides the
existing type-system track. The memberwise-only form is provisional.

## Dependencies & triggers

Rides the type-system track. Interacts with [default arguments](112-param-labels-args.md) (default field
values ~ default args) and [error handling](115-error-handling.md) (`init?` → `Option`/`Result`).

## Refs

`types.md` (construction), deferred.md "User-level language surface".
