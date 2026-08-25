# Optional ergonomics

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** S ·
**Status:** needs-design · **Source:** deferred.md (frontend surface group)

## What

`if let` / `guard let` binding forms and optional chaining `?.` over `Option<T>`. Frontend
desugaring.

## Roadmap assessment (three-head)

**Deferred-only / fold into [pattern matching](110-pattern-matching.md)** — ergonomic sugar, low ripple.
The binding forms *are* patterns.

## Dependencies & triggers

- **Overlaps:** [pattern matching](110-pattern-matching.md) (binding forms), [error handling](115-error-handling.md).

## Refs

deferred.md "Frontend surface features"; `Option<T>`.
