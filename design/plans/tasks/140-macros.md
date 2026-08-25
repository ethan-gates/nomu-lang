# Macros (M13)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design · **Source:** roadmap M13

## What

Typed hygienic AST macros. Compile-time code generation over the typed AST, with hygiene (macro-
introduced names don't capture or collide with user names).

## Dependencies & triggers

- **Interacts with:** [identifier interning](144-frontend-perf.md) — hygiene carries `(symbol,
  hygiene-ctx)`, so the interning design must account for macro hygiene.
- **Adjacent:** [`comptime`](141-comptime.md) (compile-time evaluation) is a related but distinct
  compile-time feature.

## Refs

roadmap M13; deferred.md "Identifier interning" (hygiene interaction); [comptime](141-comptime.md).
