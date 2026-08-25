# Associated types + where-clauses on generics

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L
(the heaviest of the frontend surface group) · **Status:** needs-design · **Source:** deferred.md
(frontend surface group)

## What

Associated types on interfaces (`associatedtype`) and `where` clauses on generic bounds.

Relatively frontend/sema-focused (type-checking + witness layout), though associated types add real
type-system depth: existentials carrying associated types, path-dependent types.

## Roadmap assessment (three-head)

**One-liner pointer (leaning yes)** — type-system depth; frontend-focused but architecturally real
for the generics model.

## Dependencies & triggers

- **Depends on:** the M5 generics + interfaces model (present).
- **Enables:** richer stdlib interfaces (e.g. an iterator/sequence with an associated element type —
  ties to [`for … in`](117-for-in-iteration.md) and [stdlib-core](120-stdlib-core.md)).

## Refs

deferred.md "Frontend surface features"; `generics.md`, `interfaces.md`.
