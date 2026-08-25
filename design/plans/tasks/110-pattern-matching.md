# Pattern matching (full)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L
("the big one") · **Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

## What

Generalize today's enum-case `switch` + exhaustiveness IR pass into real patterns:
- nested / tuple / struct destructuring,
- value and range patterns,
- wildcard `_`,
- guards,
- or-patterns,
- binding forms (`if let` / `guard let` — overlaps [optional ergonomics](116-optional-ergonomics.md)).

## Roadmap assessment (three-head)

**Yes — milestone-scale.** The match compiler (decision-tree / automaton lowering + generalized
exhaustiveness) is a compiler subsystem; patterns are a core reasoning surface; match-compilation
quality is a perf lever.

## Dependencies & triggers

- **Depends on:** [tuples](109-tuples.md) / enums.
- **Overlaps:** [optional ergonomics](116-optional-ergonomics.md) (binding forms are patterns),
  [error handling](115-error-handling.md).

## How

A match compiler lowering patterns to a decision tree / automaton, with generalized exhaustiveness
checking (generalizing the current enum-case exhaustiveness IR pass).

## Refs

deferred.md "User-level language surface"; `types.md` §2 (exhaustiveness); today's `switch` +
exhaustiveness IR pass.
