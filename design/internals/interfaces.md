# Interfaces

**Status:** authoritative spec — interfaces as built through **M5**. Documents the *implemented* language: declaration, requirements + defaults, conformance + extensions, computed properties, dispatch, existentials (`any I`) and opaque types (`some I`), `Self`-requirements + existential legality, and composition. Read this instead of the compiler. Generic bounds `<T: I>`, monomorphization, the `shared` bound, and the coherence/orphan rule live in `generics.md`; the concurrency angle of `shared` in `concurrency.md` §5. Rationale and rejected alternatives are §9; deferred surface is §8.

Scope note: everything below is committed and compiles today unless marked **Deferred**. Decision dates are kept as provenance.

**Terminology:** "interface" for the Swift-protocol / Rust-trait / Go-interface family. "Requirement" = a member the interface demands; "conformer" = a type that satisfies it.

---

## 1. Declaration, requirements, defaults

- **Keyword: `interface`.** — Decided (2026-07-16). No class inheritance; abstraction and reuse come from **interfaces + extensions**, not a base-class hierarchy (`types.md` §1).
- **Requirements are methods or properties.** A method requirement is a bare signature (`fun draw() -> String`). A property requirement is `var name: T { get }` (read-only) or `var name: T { get set }` (settable).
- **Overridable defaults.** A method requirement with a body in the interface is an **overridable default** — an *optional* requirement a conformer may skip and inherit. Defaults live in the interface body, never in an extension. A default may read a requirement by **bare name** (`count`, not just `self.count`), **write** a settable requirement (`self.count = v`), and call another requirement/default (`self.m()`).
- **Property requirements are accessor-shaped, never storage.** A `{ get }`/`{ get set }` requirement is a get (and set) **accessor** in the witness table — never a field offset. A conformer satisfies it with a **stored field** (auto-synthesizes trivial accessors) or a **computed property** (§3); the interface never dictates layout. This lets a default method operate on required state (`fun increment() { count = count + 1 }`) without state inheritance: multiple interfaces requiring `count` collapse to **one** field with shared accessors (no state diamond, §7.1), and it works through `any I` (an erased box has accessors, not offsets). — Decided (property requirements 2026-07-20).
- **Mutation:** a settable access on a value conformer (a `{ get set }` default that writes, or `d.prop = v`) needs a mutable (`var`) receiver — mutating-method semantics on value types. Read-only `{ get }` avoids this.

---

## 2. Conformance & extensions

- **Two conformance forms, one meaning.** `struct/enum/class T: I { … }` (an at-type clause) and a **conformance extension** `extension T: I { … }` both supply the requirement **witnesses** that make `T` conform to `I`. The at-type form is same-module sugar (always orphan-legal). A conformance extension may supply a **computed property** to satisfy a property requirement.
- **Plain extension** `extension T { … }` adds *new*, non-requirement methods — statically dispatched, not in the witness table, not seen through `any I`. Built for `struct`/`enum`/`class` (M4.12): no stored properties (an extension adds behavior, not layout); a method colliding on **name + nominal argument types** with one already on `T` is an error (first wins; differing arg types are distinct overloads); a mutating value-type extension method is inferred mutating and needs a `var` receiver. An **extension-merge pass** folds these methods into `T`'s member set before typechecking, so downstream passes see one ordinary type.
- **One witness per `(T, requirement)`, dispatched consistently however reached** — this removes Swift's default-vs-witness gotcha (§9). A **plain** extension method sharing a **requirement's** name is a compile error (it would silently shadow).
- **Coherence** — the global orphan rule (a conformance is legal only in `T`'s or `I`'s module); a third module wraps `T` in a newtype. Enforcement waits on modules; trivial under the single compilation unit. Full statement: `generics.md` §11.
- **Actor conformance — Deferred (parked).** Conformance covers `struct`/`enum`/`class`; an actor conforming to an interface is rejected with a targeted diagnostic. A synchronous `fun` requirement dispatched through `any I` — where the caller can't see the receiver is an actor — crosses an isolation boundary (deadlock/reentrancy questions), and it depends on actor instance methods, which don't exist yet. Revisit post-M5.

---

## 3. Computed properties & get/set accessors

A committed language feature (structs had stored fields only before M5). — Decided (2026-07-25).

- **Available on `struct`, `enum`, and `class`.** Only *stored* properties stay struct/class-only; enums get computed properties (typically a `get` over `match self`).
- **Accessor spelling:** `var area: Int { get { … } set(v) { … } }`. A **bare body is an implicit read-only get** — `var area: Int { radius * radius * 3 }` ≡ `{ get { … } }`. A setter **binds its incoming value explicitly** — `set(v) { radius = v / 3 }` — diverging from Swift's implicit `newValue` (no magic identifier).
- A settable computed property on a value type needs a mutable receiver (mutating-method semantics). A stored field auto-synthesizes trivial `get`/(`set`); the get/set lowering is one method pair regardless of the type kind.

---

## 4. Dispatch (static vs dynamic)

**Dispatch is a call-site property, not a property of where a member is written.** A call resolves **statically** wherever the concrete conformer type is known, and **dynamically** through the witness table only where the type is erased.

- **Requirements** — static on a concrete receiver, a `some I` value, or a specialized generic; dynamic through `any I` (or an unspecialized generic). The conformer's implementation runs in every case; erasure only changes how it's reached. **Guaranteed-static, specialization-independent sites are concrete types and `some I`** (`generics.md` §1).
- **Plain extension methods** — always static; not in the witness table, not seen through `any I`.
- **Property-requirement performance follows the same rule.** A `{ get }` on a stored-backed property **devirtualizes to a field load** wherever the concrete type is known (concrete / `some` / specialized generic); it's an indirect accessor call only through `any I` or an unspecialized generic. Computed properties add no cost to the stored path.

Because today's monomorphization specializes all generic code (`generics.md` §6), `<T: I>` is static in practice; the *guaranteed*-static levers remain concrete types and `some I`.

**How the incumbents dispatch (reference):**

| | Static | Dynamic | Defaults |
|---|---|---|---|
| **Swift** | extension-only methods; specialized generics | requirements (witness table); `any P` | requirement-default = dynamic; extension-only = static (the gotcha we remove) |
| **Rust** | `<T: Trait>` / `impl Trait` (monomorphized) | `dyn Trait` (vtable) | in-trait defaults; dynamic under `dyn`; no gotcha |
| **Go** | concrete calls | interfaces (itab), always | none |

---

## 5. Existentials (`any I`) & opaque types (`some I`)

**Interface-typed values must be explicit `any` or `some`** — there is no bare interface-as-type, so the erasure cost is always visible in the source.

### 5.1 `any I` — existential (dynamic, erased)

- A **type-erased, heap-boxed value** (`{ witness, payload }`), dynamically dispatched — the tool for **heterogeneity / erasure**: mixed-type collections (`[any Shape]`), reassignable fields, returning varying concrete types. Reach for it only when concrete types must mix or be erased; generics / `some` cover the homogeneous static case.
- **Composition `any A & B`** — supported (the box carries a witness table per interface). `&` is commutative, associative, `A & A = A`, and `A & B` collapses to `B` when `B: A`.
- **Upcast `any B` → `any A`** when `B: A` — the box re-boxes through a per-transitive-base pointer the witness carries (payload shared, overriding witness preserved). (Composition-source upcast, `any A & B` → `any A`, is **Deferred**, §8.)
- **Property set through `any I`** — `d.prop = v` dispatches to the witness set accessor; a get-only requirement is a clean local error.

### 5.2 `some I` — opaque (static, one hidden underlying)

- An **opaque type**: one concrete underlying, fixed and compiler-known but **hidden from the caller**. Requirement calls **devirtualize** to direct calls / field loads — no box, static dispatch. This is why `some` is core (`generics.md` §1). — Decided (2026-07-23).
- **Positions:** return (`fun makeShape() -> some Drawable`), a `let`/`var: some I` **binding annotation**, and **`some A & B`** composition. Every `return` in a body must yield the *same* concrete type (else a clean error). Parameter-position `some` is **Deferred** — `<T: I>` expresses it (§8).
- **Per-function / per-binding identity** (Swift-style): each owner gets its own opaque identity, so two functions both returning `some Drawable` are **distinct types** even with the same underlying.
- **`-> Self` on a `some I` value yields the concrete underlying** (not a re-wrapped opaque), so `x.clone()` on a `some Cloneable` gives the concrete type back — enables chaining.
- **Limit:** a requirement *property read* on an opaque value needs the underlying known at check time (to pick field-load vs. getter); a forward reference to a later-declared producer emits a clear "declare the producer earlier" error. Method calls resolve fine (post-check).

---

## 6. `Self`-requirements & existential legality

A requirement may mention `Self`, standing for the conforming type (`fun clone() -> Self`, `fun combined(with: Self) -> Self`). In a `<T: I>` body and behind `some I`, `Self` binds to the one known/hidden concrete type. The interesting question is whether such an interface can be used as `any I`.

- **Position analysis (conservative).** — Decided (2026-07-30). `Self` is **covariant** in a bare method return (`-> Self`) and in a `{ get }`-only `Self` property. It is **non-covariant** in a parameter, a `{ get set }` `Self` property, or **nested inside a function type** (either side — the full sign-flipping variance calculus is Deferred, §8).
- **Covariant-only `Self` → existential-legal.** An interface whose `Self` occurrences are all covariant is usable as `any I`: a `-> Self` requirement **erases to `-> any I` at the box boundary** — the witness returns the concrete `Self` and **re-boxes** it as another existential, which is sound because the caller never asserts two boxes share a concrete type. `c.clone()` on `c: any B` yields `any B` (the receiver's own existential type).
- **Any non-covariant `Self` → constraint-only.** The interface is usable as a generic bound `<T: I>` and as `some I`, but **rejected as `any I`** (diagnosed at type formation, not at call sites) — a type-erased box can't guarantee two `Self` values share a concrete type, and a *consuming* `Self` (parameter position) genuinely can't be erased. This is a fundamental limit, not an implementation gap.
- **Both kinds are usable as `<T: I>`.** A `Self`-mentioning bound compiles because monomorphization specializes it to a concrete `T` where `-> Self` is a direct call — no witness needed (`generics.md` §4).
- The property is computed at interface declaration and **propagates through refinement** (`B: A` is constraint-only if `A` is).

### 6.1 Static requirements — also constraint-only

- **`static fun` requirements.** An interface may declare `static fun name(…) -> …` requirements (e.g. `static fun zero() -> Self` for a `Zeroable`/`Numeric`-style protocol). A conformer satisfies one with a matching `static fun`; a static requirement and an instance method never cross-satisfy. `Self` in the requirement binds to the conformer.
- **Constraint-only, for a stronger reason than non-covariant `Self`.** A static method has **no receiver**, so there is no value to carry a witness and no concrete type to name behind `any I`. An interface with any static requirement is usable as `<T: I>` / `some I` and **rejected as `any I`** (diagnosed at type formation). It emits no witness table. This is the same fundamental limit as trait-object safety (Rust) / existential restrictions (Swift): a requirement with no `Self` receiver can't be dispatched through erasure.
- **Dispatch** is through the bound only: `T.zero()` where `T: Zeroable` lowers to a `.staticCall(onType: T, …)` node that **monomorphization resolves** to the concrete conformer's static method (`Conformer.zero`, the static free function), rewriting it to a direct call. Under whole-program mono every such `T` is specialized to a concrete type, so no witness slot for statics is needed. Property propagates through refinement.

---

## 7. Composition & refinement

### 7.1 Refinement (`B: A`) — Decided (2026-07-16)

Interface inheritance is **requirement aggregation + a subtype edge**, not implementation or state inheritance — so state-diamond / fragile-base / super-chain hazards don't arise and multiple inheritance is unproblematic.

- **Syntax:** `interface B: A`; multiple bases `interface C: A, B`.
- **Meaning:** conforming to `B` requires conforming to `A`; `B` *is-a* `A` — `any B` is usable where `any A` is expected, and a `<T: B>` generic may call `A`'s requirements.
- A refining interface's body may provide or override a default for an inherited requirement (dynamic, overridable) — also how `B` turns a mandatory `A`-requirement into an optional one for `B`'s conformers.

### 7.2 Name conflicts & overload identity — Decided (2026-07-16)

- **Overloading keys on nominal argument *types* only.**
- **The `shared` marker is erased for overload identity** — two members equal after erasing `shared` are the same member (overload resolution ignores auto-derived markers).
- Two bases (`C: A, B`) declaring a same-named member: **same arg types** → one member, one impl satisfies both; **same arg types differing only in `shared`** → a conflict (compile error, author reconciles); **different arg types** → distinct overloads, both required.

### 7.3 Default resolution across bases — Decided (2026-07-16)

- **Most-specific default in the refinement graph wins.**
- **No unique most-specific** (two incomparable sibling defaults for the same member) → the defaults **cancel** → the member becomes **mandatory** for conformers.
- **One default + one mandatory** (a base with no default) is not a conflict — the default applies.
- **No disambiguation syntax:** on cancellation a conformer reimplements the member. Cancellation only ever turns ambiguity into a mandatory requirement, which is always well-defined.

### 7.4 Anonymous composition `A & B` — Decided (2026-07-16)

`A & B` composes interface requirements **at a use site, structurally** over existing conformances: any type conforming to both satisfies `A & B`, with no named declaration. Distinct from named refinement (§7.1), which is nominal with its own identity. Used as `any A & B` (§5.1) and `some A & B` (§5.2); the generic bound form `<T: A & B>` is the same operator (`generics.md` §2).

---

## 8. Deferred

- **Associated types / generic interfaces** — interfaces parameterized over types (the highest-complexity area); the witness layout reserves a **type-witness slot** so adding them is wiring, not redesign. (`generics.md` §10.)
- **Explicit conditional conformance** — user-declared `extension Box<T>: I where T: I`. (The `shared` marker's conditional conformance is *auto-derived* structurally and shipped — `generics.md` §7.)
- **Actor conformance** — parked (§2).
- **Composition existential upcast** — `any A & B` → `any A` / a sub-composition (single-interface upcast shipped, §5.1).
- **Parameter-position `some`** — subsumed by `<T: I>`.
- **Full variance calculus for `Self`** — classifying `Self` nested in a function type by sign-flipping (a `(Self) -> Bool` parameter is technically covariant); the conservative rule keeps it constraint-only (§6).
- **Operators as interface requirements** — `==`/`<`/`+` are built into the checker on `Int`/`Bool`, not requirements (`generics.md` §10).

---

## 9. Rationale & rejected alternatives

- **One witness per `(type, requirement)`, dispatched consistently** — a representational invariant that removes **Swift's default-vs-witness gotcha** (an extension supplying a default dispatches statically while the same surface through `any P` dispatches dynamically to a possibly-different method). Nomu uses the invariant, not a location rule; a conformance is a single witness whether written in the type body or a conformance extension.
- **Constraint-only is a real limit, not conservatism** — a contravariant (consuming) `Self` cannot be erased: two `any I` boxes can hold different concrete types, so `a.combined(with: b)` is genuinely ill-typed under erasure. No compiler cleverness recovers it (that would only downgrade a static guarantee to a runtime trap). Covariant `Self` *can* be erased, which is why §6 admits exactly that case and no more.
- **Multi-interface `any A & B`** accepts a heavier box (a witness per interface) for ergonomics — Rust restricts `dyn` to one non-auto trait for representation reasons; we take the box.
- **`shared` as a prefix capability modifier**, not an `&`-composed marker interface — it also spells shareable closure/function types, which a bare function type can't express as an `&`-composition (`generics.md` §2, §12).
