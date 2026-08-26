# Error handling — `?` operator + typed throws

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design (M5 shipped `Result`; `?` / typed throws deferred) · **Source:** deferred.md
(frontend surface group) + cross-cutting

## What

The `?` propagation operator and typed throws over the existing `Result<T, E>` (M5 shipped `Result`;
`?` / typed throws deferred, `types.md` §5).

Mostly frontend: `?` desugars to `switch` / early-return on `Result`. The error-return ABI is the one
midend/backend touch.

## Roadmap assessment (three-head)

**One-liner pointer** — a programmer-expectation contract (how errors propagate), frontend-focused.

## Dependencies & triggers

- **Ready:** `Result<T, E>` (M5).
- **Interacts with:** [pattern matching](110-pattern-matching.md) / [optional ergonomics](116-optional-ergonomics.md)
  (binding + early-return forms), the error-return ABI.

## Refs

`types.md` §5 (errors); cross-cutting design (error handling); deferred.md "Frontend surface
features".
