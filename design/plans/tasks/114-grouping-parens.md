# Grouping parentheses as a primary expression

**Avenue:** Usability · **Type/Lifecycle:** `user-facing · shipped` · **Size:** S ·
**Status:** shipped · **Source:** deferred.md (2026-08 session)

## What

`(a + b) * c` did not parse; `(` only opened a call/param list. A `.lParen` case was added to
`parsePrimary` that parses the inner expression with `parseExpr` (full precedence falls out of the
recursion) and expects `.rParen`. Grouping is transparent — no AST node; the inner expression is
returned as-is, so a trailing call / member / subscript attaches via `parsePostfix`. Unclosed
parens report a clean `expected rParen` diagnostic rather than trapping.

Tests: `ParserTests.testGroupingParens` (precedence inversion) and `testGroupedExprTakesPostfix`
(postfix off a group).

## Dependencies & triggers

None. Pick up anytime; complements the [operator surface](113-operator-surface.md) precedence work.

## Refs

`Parser.parsePrimary`; deferred.md "Grouping parentheses as a primary expression".
