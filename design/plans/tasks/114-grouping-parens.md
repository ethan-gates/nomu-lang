# Grouping parentheses as a primary expression

**Avenue:** Usability · **Type/Lifecycle:** `user-facing · ready-to-build` · **Size:** S ·
**Status:** ready-to-build · **Source:** deferred.md (2026-08 session)

## What

`(a + b) * c` does not parse today; `(` only opens a call/param list. Add a parenthesized-expression
case to `parsePrimary`. Small, self-contained (currently worked around in
`examples/benchmarks/hashmap.nomu`).

## Dependencies & triggers

None. Pick up anytime; complements the [operator surface](113-operator-surface.md) precedence work.

## Refs

`Parser.parsePrimary`; deferred.md "Grouping parentheses as a primary expression".
