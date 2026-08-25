# Operator overloading for user types

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

Two forks, decided separately:

## 1. Closed-set overloading via interface conformance

User types implement the built-in operators (`==`, `<`, `+`, …) as interface requirements
(`generics.md` §10, operators-as-requirements). Today `String` uses `.eq(...)` and aggregates have no
comparison. Extends the [operator surface](113-operator-surface.md) item.

**Roadmap: one-liner pointer** — interface/generics maturity; programmer-expectation ripple (writing
`a + b` / `a == b`).

## 2. User-defined custom operators (new tokens + precedence)

**Decided 2026-08-18: hold closed.** Custom operators pull on parser architecture
(precedence/ambiguity) and cut against `syntax.md` §1 ("one canonical way; resist a second form").
Kept out unless a concrete need reopens it. Roadmap: none.

## Dependencies & triggers

- **Depends on:** interface/generics maturity (present since M5); the operator-as-requirement
  interfaces (`generics.md` §10).
- **Extends:** [operator surface (built-ins)](113-operator-surface.md).

## Refs

`generics.md` §10 (operators-as-requirements); `syntax.md` §1; deferred.md "User-level language
surface".
