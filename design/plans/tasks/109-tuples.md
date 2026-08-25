# Tuples

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

## What

Anonymous structural product types: multiple return values, destructuring.

## Ripple

- Structural aggregates in a nominal type system.
- The multi-value return ABI + cost model.
- Pattern-match integration (pairs with [pattern matching](110-pattern-matching.md)).
- Whole-aggregate value reads — the category-3 FCA / D6 spill (`c-types.md` §3.4); shared with the
  [generic hash map](124-generic-hashmap.md) blocker.

## Roadmap assessment (three-head)

**Yes (or strong one-liner).** Structural types plus a multi-return calling convention are
type-system and ABI foundations later features design around; pairs with pattern matching.

## Dependencies & triggers

- **Blocked-adjacent:** whole-aggregate value reads hit the D6 spill (`c-types.md` §3.4).
- **Pairs with:** [pattern matching](110-pattern-matching.md).

## Refs

deferred.md "User-level language surface"; `c-types.md` §3.4 (FCA / D6 spill); `types.md`.
