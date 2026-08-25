# Operator surface (built-ins)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · partially-shipped` · **Size:** M ·
**Status:** partially-shipped · **Source:** deferred.md (2026-08 session)

## Shipped (2026-08-20)

Bitwise `& | ^`, shift `<< >>`, and prefix `- ! ~` (Int + UInt8; `- ! ~` desugar to binary forms in
`Sema.checkUnary`). Overflow is raw wrapping arithmetic, no panics (decided 2026-08-20). Comparison
type-checking rejects non-numeric `== != < >` with a clean error (`Sema.binaryResult`).

**Precedence — decided 2026-08-20 (Go-style, revisit-able).** Loosest→tightest: comparison
(`== != < > <= >=`) < `|` < `^` < `&` < shift (`<< >>`) < additive (`+ -`) < multiplicative
(`* / %`) < prefix (`- ! ~`) < postfix. Bitwise/shift bind tighter than comparison, so
`x & mask == 0` reads as `(x & mask) == 0` (drops the classic C footgun). Prefix ops share one
right-associative level. Chain lives in `Parser` (`parseComparison` → `parseBitOr` → … →
`parseUnary` → `parsePostfix`); mirrored in `syntax.md` §3.

**Two parse-context notes.** `&` is bitwise-and in expression position and interface composition
(`any A & B`) in type position (resolved by parser context; precedent: `<`). `<<`/`>>` are recombined
in the parser from two adjacent `<`/`>` tokens (adjacency required), so a bare `>` still closes a
generic list and `Box<Box<Int>>` is unaffected.

## Still open

- Equality/relational on non-numerics (`String` uses `.eq(...)`; aggregates have none) — folds into
  [operator overloading](111-operator-overloading.md) closed-set conformance.
- The overload/requirement story (`generics.md` §10, operators-as-requirements).
- [Grouping parentheses](114-grouping-parens.md) (own item).
- Where `&&`/`||` sit once they exist (Go: `&&` above `||`, both below comparison); whether to keep
  Go's table or flatten if it surprises on real programs.

## Refs

`syntax.md` §3; `generics.md` §10; `Sema.checkUnary` / `Sema.binaryResult`; deferred.md "Language +
compiler-perf work".
