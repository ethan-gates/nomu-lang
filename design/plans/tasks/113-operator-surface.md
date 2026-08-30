# Operator surface (built-ins)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · partially-shipped` · **Size:** M ·
**Status:** partially-shipped · **Source:** deferred.md (2026-08 session)

## Shipped (2026-08-20)

Bitwise `& | ^`, shift `<< >>`, and prefix `- ! ~` (Int + UInt8; `- ! ~` desugar to binary forms in
`Sema.checkUnary`). Overflow is raw wrapping arithmetic, no panics (decided 2026-08-20). Comparison
type-checking rejects non-numeric `== != < >` with a clean error (`Sema.binaryResult`).

Logical `&&` / `||` (short-circuit). Both operands `Bool`, result `Bool` (`Sema.binaryResult`). They
lower to branches in SSAIRgen (`lowerShortCircuit`) — the right operand is evaluated only on the path
that needs it — modelled as `var r = <skip>; if <takes-rhs> { r = rhs }`, so the merge phi falls out of
the existing SSA construction. No eager logical op reaches the egress. `BinOp.and`/`.or` carry them;
tokens `&&`/`||` lex as `.ampAmp`/`.pipePipe`.

**Precedence — decided 2026-08-20 (Go-style, revisit-able).** Loosest→tightest: `||` < `&&` <
comparison (`== != < > <= >=`) < `|` < `^` < `&` < shift (`<< >>`) < additive (`+ -`) <
multiplicative (`* / %`) < prefix (`- ! ~`) < postfix. Logical `||`/`&&` are the loosest (below
comparison), so `a == b && c` reads as `(a == b) && c` and `a && b || c` as `(a && b) || c`.
Bitwise/shift bind tighter than comparison, so `x & mask == 0` reads as `(x & mask) == 0` (drops the
classic C footgun). Prefix ops share one right-associative level. Chain lives in `Parser`
(`parseLogicalOr` → `parseLogicalAnd` → `parseComparison` → `parseBitOr` → … → `parseUnary` →
`parsePostfix`); mirrored in `syntax.md` §3.

**Two parse-context notes.** `&` is bitwise-and in expression position and interface composition
(`any A & B`) in type position (resolved by parser context; precedent: `<`). `<<`/`>>` are recombined
in the parser from two adjacent `<`/`>` tokens (adjacency required), so a bare `>` still closes a
generic list and `Box<Box<Int>>` is unaffected.

## Still open

- Equality/relational on non-numerics (`String` uses `.eq(...)`; aggregates have none) — folds into
  [operator overloading](111-operator-overloading.md) closed-set conformance.
- The overload/requirement story (`generics.md` §10, operators-as-requirements).
- [Grouping parentheses](114-grouping-parens.md) — shipped (own item).

## Refs

`syntax.md` §3; `generics.md` §10; `Sema.checkUnary` / `Sema.binaryResult`; deferred.md "Language +
compiler-perf work".
