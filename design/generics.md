# Generics

**Status:** working draft — M5 focus. The home for Nomu's generics design as it is worked out for M5: interface constraints (`<T: I>`), monomorphization, the shareable bound on type parameters, and exhaustiveness under generics. The model overview still lives in `types.md` §3; interface mechanics (conformance, dispatch, composition) live in `interfaces.md`. Status tags: **Decided**, **Leaning**, **Deferred**, **Open**.

**API scope:** no concrete syntax or keyword here is committed. `<T: I>`, `some`, `any`, and bound spellings are illustrative and Swift-shaped until we agree. What is pinned is the *model*.

**Phased build plan:** `m5-spec.md` (the ordered implementation sequence this design feeds).

---

## 1. Decided / leaning (M5 direction)

- **Variance — invariant generics.** — **Decided (2026-07-19).** A generic type is neither co- nor contravariant in its parameters. Even when `B` refines `A` (so `any B` is usable where `any A` is expected), `Box<B>` is **not** usable where `Box<A>` is expected — the two are unrelated types. The subtype edges that come from interface refinement (`B: A`) and existentials (`any B` → `any A`) do not lift through a type parameter. This copies Swift and Rust, is sound by default (a mutable `Box<B>` seen as `Box<A>` would admit an `A` that is not a `B`), and avoids the read/write-position analysis that variance inference needs. Revisit only if a concrete need appears.

- **Associated types — reserve room, defer the surface.** — **Decided (staging, 2026-07-19).** The first cut of M5 ships without associated types, but the witness-table layout carries a **type-witness slot** and the constraint solver can model a projected type (`T.Element`) from the start, so adding them mid-M5 is wiring rather than a redesign. Planned within M5; out of the first cut. (Full complexity notes in `interfaces.md` §4.5.)

- **Dispatch / checking — lock the checking model, keep the lowering open.** — **Decided (2026-07-20).** The invariant to hold is **modular checking against declared bounds** (Rust-style): a generic body is checked once against what `T: I` promises and nothing else. That single abstract contract keeps all three lowerings reachable — monomorphization (stencil per concrete type), dictionary-passing (one shared body + a witness table), and GC value-witness stenciling (one shared body over a uniform representation carrying size/copy/destroy/trace). Per-instantiation (C++ template) checking is what would foreclose the latter two, so it is rejected. Plan: build witness tables for `any I` (needed regardless), lower the generic path through the **same** witnesses first, then add monomorphization as a specialization pass. This delivers the monomorphization the roadmap names while leaving dictionary-passing and stenciling as future options rather than rewrites. Two things to hold so the choice stays reversible: (1) the generic path reuses the `any` conformance representation instead of a monomorphization-only one; (2) the M6 object model exposes per-type trace metadata as runtime-reachable data (a value witness), not baked solely into specialized code.

- **Coherence — global coherence (Rust orphan rule).** — **Decided (2026-07-20); enforcement blocked on modules.** A conformance (`extension T: I`, `interfaces.md` §1) may be declared only in the module that owns `T` or the module that owns `I`; it is then global and unique across the program. This delivers **no invisible behavior on import** — an unrelated module cannot author a conformance, so importing it can never inject one, and A's view of a foreign type comes only from modules A already depends on to name the type or the interface. Global uniqueness also means **one witness program-wide**, so no witness travels into a scope expecting a different one (the scoped-conformance hazard is avoided by prohibition, not scoping). A third module needing `T`-as-`I` wraps `T` in a **distinct nominal type it owns** (not a transparent `typealias`, which is the *same* type as `T` and cannot carry a separate conformance) and conforms the wrapper — the exact newtype/alias mechanism is design-deferred (§2), and the coherence model needs only that *some* such escape will exist. The rule can't be *enforced* until the module system exists (`modules.md`); under M5's single compilation unit uniqueness is trivially satisfied. This is the target model, not a temporary scaffold.

- **Static dispatch is a type-system property, not a monomorphization result.** — **Decided (2026-07-20).** Dispatch is a call-site property (`interfaces.md` §2): a call resolves statically wherever the concrete type is known, and dynamically only where it is erased. Two site shapes guarantee static dispatch with **zero dependence on specialization** — **concrete types** and **`some I` opaque types** (a single hidden underlying type). `<T: I>` generics are static *iff* specialized and dynamic otherwise, so the base witness-passing lowering makes them dynamic by default; `any I` is always dynamic. Because specialization may be relaxed or partially removed, authors reach for concrete types or `some` to *guarantee* static dispatch; monomorphization stays a pure accelerator nothing depends on. Consequence: **`some` (opaque types) is in M5's core**, not deferred — it is the language lever for mono-independent static dispatch. (Associated types stay staged per the bullet above.)

- **Error handling — `Result<T, E>` sum type + explicit `match`.** — **Decided for M5 (2026-07-19).** The carrier is a generic `Result<T, E>` sum type, handled by explicit `match`. No `?` operator and no typed throws in M5. Depends on generic enums working first (M5 Phase B). Propagation sugar is a later design item (§2).

---

## 2. Deferred generics

Intentionally out of M5's first cut, to revisit. Deferring these does not lock in anything that contradicts adding them later.

- **Operators as interface requirements.** — **Deferred.** Generic code that compares or hashes an unknown `T` (`max`/`min`/`sort` needing `Comparable`, `Set`/`Dictionary` needing `Equatable`/`Hashable`) needs the built-in operators (`==`, `<`, `+`, …) to be interface requirements dispatched through a witness table. Today those operators are built into the typechecker/codegen on `Int`/`Bool`. Generics work without them — structural containers (`Option<T>`, `Result<T, E>`, `List<T>`, `Box<T>`) and higher-order functions over closures need no comparison. Real design work on operators comes later. Two guardrails so the deferral stays free:
  1. **Keep the operator syntax reserved and parsing unchanged**, so turning `a < b` into a desugared requirement call later is a lowering change, not a surface change. There must be **no other** way to compare a generic `T` in the interim, so there is nothing to migrate later.
  2. When operators do become requirements, **built-in conformances lower to primitive machine ops** (`Int: Comparable` compiles to a machine compare, not a vtable call), the way Swift and Rust special-case it. That work is owed whenever operators land; deferring adds nothing to it.
  - Cost paid in M5: no `sort`, no `Set`/`Dictionary`, no generic `max`/`min`. Array-like and structural generics are unaffected.

- **Error-handling sugar — `?` propagation and typed throws.** — **Deferred.** M5 ships the `Result<T, E>` carrier with explicit `match` (§1). A propagation operator and whether error types appear in signatures are later design work (`types.md` §4).

- **Newtype / type-alias mechanism.** — **Design deferred; isolated.** The distinct-nominal-type wrapper that lets a third module escape the orphan rule (§1 coherence) — plus the transparent `typealias` it must be distinguished from — is left undesigned pending a real tradeoff discussion. It is not M5-blocking: the escape hatch only matters across modules, and M5 has no modules, so the orphan rule isn't enforced yet. The coherence model depends only on *some* distinct-nominal escape existing later, not on its spelling or semantics, so the design decouples cleanly.

---

## 3a. Committed surface syntax (M5)

Spellings agreed as we walk the surface. Semantics live in §1–§2; this pins the concrete form.

- **Generic parameters + interface bounds — angle brackets, inline `:`.** — **Decided (2026-07-20).** `fun max<T: Comparable>(a: T, b: T) -> T`, `struct Box<T> { let value: T }`. Composed bounds reuse `&` (`interfaces.md` §4.4): `<T: Drawable & Shape>`. Consistent with the conformance/refinement `:`. A `where`-clause form is a possible additive extension later if bounds get long; not in M5.
- **Shareable — prefix modifier `shared`**, joining `any`/`some` in position. — **Decided (2026-07-20).** Declared bound on a type param: `fun send<shared T>(x: T)`. Also marks shareable existentials and closure/function types, which the interface-bound form spells awkwardly: `[shared any Shape]`, `shared (Int) -> Bool`. `shared` is an **orthogonal capability modifier, not an `&`-composed marker interface** (revises `interfaces.md` §4.4) — a param that is both `Comparable` and shareable reads `<shared T: Comparable>` (capability in prefix, interface bound after `:`). Resolves the open closure-marker spelling in `concurrency.md` §5–6. Adds `shared` to the keyword set (agreed), consistent with `any`/`some` already being keywords.
- **Conformance — `extension T: I { … }`**, with `struct/enum/class T: I { … }` at the type as sugar for the same-module case (always orphan-legal there). — **Decided (2026-07-20).**
- **`some I` — return-position only in M5. — Decided (2026-07-23).** `some I` is allowed in return position (`fun makeShape() -> some Drawable`); all `return`s must yield one concrete type; it lowers unboxed with static dispatch (the reason `some` is core, §1). Parameter-position `some` (anonymous-generic sugar) is **deferred** — `<T: I>` already expresses it. `Self`-mentioning interfaces are **constraint-only** — usable as `<T: I>` / `some I`, rejected as `any I` (`interfaces.md` §4.4). Build plan: `m5-spec.md` Phase A3.
- **Interface body — Swift-shaped.** A bare signature is a requirement (`fun draw() -> String`); a signature with a body is an overridable default. **Property requirements**: `var name: T { get }` / `{ get set }`, **accessor-shaped** in the witness (never a field offset), satisfiable by a stored field (synthesized accessors) or a computed property (custom get/set) — both ship in M5. **Computed properties + get/set accessors are committed M5 language features** (structs have stored fields only today), so this is M5 build work, not a mere prerequisite. Performance: a stored-backed `get` **devirtualizes to a field load** at concrete / `some` / specialized sites, and is an indirect call only through `any` or an unspecialized generic (`interfaces.md` §1–§2). — **Decided (2026-07-21).**

## 3. In M5 (not deferred) — pointers

For completeness, so the boundary is clear. These are M5 work, detailed elsewhere or in the forthcoming M5 spec:

- Interface declaration, conformance (via `extension T: I`, `interfaces.md` §1), requirements + defaults, witness-table generation, `any I` existentials, `some I` opaque types (static, mono-independent), refinement (`B: A`), `&` composition — the interface feature itself, which the compiler does not have yet (`interfaces.md`).
- Generic parameters + constraints `<T: I>`, modular checking, type-argument inference, witness-passing lowering, monomorphization pass.
- Exhaustiveness under generics — checked on the generic enum definition; instantiation adds no cases.
- The **shareable bound** `<T: shareable>` and **conditional conformance** (`Box<T>` is shareable iff `T` is — the same mechanism), plus completing the M3 checker's deeply-immutable-class case (`concurrency.md` §5, roadmap M5).
