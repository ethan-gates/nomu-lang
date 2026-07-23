# Surface Syntax

**Status:** working draft. The home for Nomu's surface-syntax principles — the shape of the language as written. Status tags: **Decided**, **Open**.

**API scope:** concrete spellings here are Swift-shaped illustrations, not commitments. Syntax is the least consequential axis (below); the point of this doc is the *principles* that govern surface choices, not a locked grammar.

---

## 1. Principles

- **Swift-like surface** — trailing-closure syntax, `case .foo(let x)` matching, interfaces instead of `of`-style subclassing. — **Decided.**
- **One canonical way to write each thing.** Resist adding a second form for occasional convenience. — **Decided (principle).**

The author likes Swift's simple, elegant surface and dislikes Nim's accreted oddities. Every "convenient shorthand" is a future "why are there two closure syntaxes" complaint — so the discipline is one canonical form per concept. Syntax is the least consequential of the author's gripes; don't over-invest early, and don't let a shorthand earn its way in just because it saves a keystroke.

---

## 2. Layout rules

Nomu's grammar is mostly brace/keyword-delimited, not newline-significant — statements need no separators. There are two exceptions, both **inside a type body** (`struct`/`enum`/`class`/`actor`), where a declaration keyword must be the **first token on its line**:

- **`fun` members** — a method declaration begins its own line. (T3, 2026-07-23)
- **`var` fields** — a field declaration begins its own line: two fields may not share a line, and a field may not share the opening-brace line. (2026-07-23)

So this is invalid:

```
struct Point { var x: Int var y: Int }   // ✗ 'var' must begin a new line
```

and this is the canonical form:

```
struct Point {
    var x: Int
    var y: Int
}
```

Enforced in the parser via token line numbers (the lexer discards newlines). Enum `case` declarations and local `let`/`var` bindings inside function bodies are **not** subject to this rule.

**Status: Open / under discussion.** These two rules were introduced alongside T3. The broader question — whether Nomu adopts a general "one declaration (or statement) per line" layout discipline, and how far it reaches (cases, local bindings, statements) — is unsettled and wants a dedicated decision. Until then, keep line-start rules minimal and agreed, and don't extend them without agreement.

---

## 3. What is settled elsewhere

Surface decisions that belong to a subsystem live with that subsystem, so the syntax here stays a set of principles rather than a scattered grammar:

- **Bindings** (`let`/`var`, field-level immutability) — `memory-model.md` §4.
- **Types** (`struct`/`enum`/`class`, `switch`/`case` matching) — `types.md` §2, `memory-model.md` §2.
- **Interfaces** (`interface`, `extension`, `any`, `&`) — `interfaces.md`. Keyword spellings there are tentative.
- **Closures** (trailing-closure syntax, `$0`/`$1` shorthand, capture lists) — `concurrency.md` §6, surface **Decided (2026-07-16)**, Swift-shaped, frontend-adjustable without semantic impact.
- **Concurrency keywords** — the "shareable" spelling and actor/spawn surface are open (`concurrency.md`).

---

## 4. Open questions

- **Keyword spellings** — `shareable` (`concurrency.md`), `extension` (`interfaces.md`), the `interface` vs `protocol` choice (largely settled on `interface`), and the actor message-handler keyword. Tracked in their home docs; kept adjustable while the models settle.
- **TODO — hold a dedicated syntax discussion and write the grammar.** One deliberate pass over the surface: settle how far the line-start discipline extends (§2 — enum `case`, local bindings, statements), resolve the open keyword spellings above, and produce a full formal grammar. Several surface choices have accreted ad hoc (the `fun`/`var` line-start rules); this is the checkpoint to make them coherent rather than incremental. Deferred until the surface has proven out on real programs (roadmap M1, `roadmap.md`).
