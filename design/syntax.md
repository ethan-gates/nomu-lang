# Surface Syntax

**Status:** working draft. The home for Nomu's surface-syntax principles — the shape of the language as written. Status tags: **Decided**, **Open**.

**API scope:** concrete spellings here are Swift-shaped illustrations, not commitments. Syntax is the least consequential axis (below); the point of this doc is the *principles* that govern surface choices, not a locked grammar.

---

## 1. Principles

- **Swift-like surface** — trailing-closure syntax, `case .foo(let x)` matching, interfaces instead of `of`-style subclassing. — **Decided.**
- **One canonical way to write each thing.** Resist adding a second form for occasional convenience. — **Decided (principle).**

The author likes Swift's simple, elegant surface and dislikes Nim's accreted oddities. Every "convenient shorthand" is a future "why are there two closure syntaxes" complaint — so the discipline is one canonical form per concept. Syntax is the least consequential of the author's gripes; don't over-invest early, and don't let a shorthand earn its way in just because it saves a keystroke.

---

## 2. What is settled elsewhere

Surface decisions that belong to a subsystem live with that subsystem, so the syntax here stays a set of principles rather than a scattered grammar:

- **Bindings** (`let`/`var`, field-level immutability) — `memory-model.md` §4.
- **Types** (`struct`/`enum`/`class`, `switch`/`case` matching) — `types.md` §2, `memory-model.md` §2.
- **Interfaces** (`interface`, `extension`, `any`, `&`) — `interfaces.md`. Keyword spellings there are tentative.
- **Closures** (trailing-closure syntax, `$0`/`$1` shorthand, capture lists) — `concurrency.md` §6, surface **Decided (2026-07-16)**, Swift-shaped, frontend-adjustable without semantic impact.
- **Concurrency keywords** — the "shareable" spelling and actor/spawn surface are open (`concurrency.md`).

---

## 3. Open questions

- **Keyword spellings** — `shareable` (`concurrency.md`), `extension` (`interfaces.md`), the `interface` vs `protocol` choice (largely settled on `interface`), and the actor message-handler keyword. Tracked in their home docs; kept adjustable while the models settle.
- **A full grammar** — deferred until the surface has proven out on real programs (roadmap M1, `roadmap.md`).
