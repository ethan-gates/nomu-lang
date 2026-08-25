# Float-exponent literals

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** S ·
**Status:** needs-design · **Source:** deferred.md (2026-08 session)

## What

Accept `1e9` / `2.5e-3`. A small lexer change plus syntax agreement; today only the decimal-point
form (`3.14`) lexes.

## Dependencies & triggers

None (small). Needs syntax sign-off (no new keywords; a literal-grammar extension).

## Refs

`Lexer` (number scanning); `syntax.md` (literal grammar); deferred.md "Language + compiler-perf work".
