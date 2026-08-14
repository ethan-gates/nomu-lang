# Macros

**Status:** working draft. The home for Nomu's macro system and the principle that governs it. Status tags: **Decided**, **Deferred**.

**API scope:** no macro syntax is committed; this doc pins the *model* and the *role*, not the surface.

---

## 1. The model

**Typed AST macros** (Nim / Swift-macro style): the macro sees the parsed tree, runs at compile time, emits a tree; **hygienic**. — **Decided in principle; built last.**

AST macros are the powerful, well-understood model. Hygiene keeps generated names from colliding with user names. Built last (roadmap M13, `roadmap.md`) — the core language is complete before macros arrive.

---

## 2. The role: extension only

**Macros are reserved for genuine user extension** — DSLs, boilerplate elimination, compile-time codegen — and are **never** the mechanism by which the core language reaches a capability. — **Decided (principle).**

This is the sharpest lesson from Nim. Nim's central fault is accretion: it makes everything expressible via pragmas/macros and lets the user assemble the language, so GC strategy, async, and calling conventions all live in pragma-land. That is why pragmas feel bolted on, why concurrency never cohered, and why the syntax has odd historical layers.

Nomu optimizes for the opposite axis — **coherence over expressiveness**. Concurrency, memory semantics, and interface conformance are **real syntax with real type-checker support**, never macro/pragma plumbing. A macro must never be the only way to reach a core capability.

Consider building some *standard-library* features as macros later to keep the core compiler small — but a macro stays an extension of a language that is already complete, never a substitute for a first-class concept.

---

## 3. Open questions

- **Surface syntax** — deferred with the rest of the macro work to M13 (`roadmap.md`).
- **Which stdlib features (if any) are macro-implemented** — decide when the core is stable and the compiler-size tradeoff is real.
