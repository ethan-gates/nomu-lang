# Interfaces

**Status:** working draft. The home for Nomu's interface/protocol design — conformance, dispatch, extensions, and (incoming) composition. Status tags: **Decided**, **Leaning**, **Open**.

**API scope:** no concrete syntax or keyword here is committed. The keyword itself (`interface` vs `protocol`) is open; `extension`, `any`, `&`, etc. are illustrative and Swift-shaped until we agree. What's being pinned down is the *model*, not the surface.

**Terminology:** this doc says "interface" for the Swift-protocol / Rust-trait / Go-interface family. "Requirement" = a member the interface demands; "conformer" = a type that satisfies it.

---

## 1. Model

- **Keyword: `interface`.** The declaration keyword is `interface`. — **Decided (2026-07-16).**
- **No class inheritance.** Abstraction and code reuse come from **interfaces + extensions**, not a base-class hierarchy. — **Decided** (`types.md` §1).
- **Requirements** are declared in the interface body; a conforming type must satisfy them. A requirement may carry an **overridable default in the body**, which makes it an *optional* requirement — a conformer may skip it and inherit the default. Defaults are dynamically dispatched and live in the interface body, never in an extension. (This is the tool for "this member is optional"; it avoids forcing an author to split off a second interface.) — **Decided (V1, 2026-07-16).**
- **Extensions are direct** — `extension I { … }` adds members to an interface in place, with no separate trait and no blanket-impl ceremony (Rust needs that only because of its coherence rules; we don't). The keyword `extension` is **tentative** — same shape as Swift but different semantics here, so the spelling may change. — **Decided (semantics); keyword tentative (2026-07-16).**
- **Extensions add *new*, non-requirement methods only; they cannot implement or override a requirement** (a default goes in the interface body instead — compile error otherwise). And because extension methods are **statically dispatched**, a conformer that declares a member with the **same name as a static extension method** is a compile error/warning — its version would not be called. — **Decided (2026-07-16).**
- **Existentials** — `any I` is the opt-in form for dynamic dispatch / heterogeneous storage. Generic constraints (`<T: I>`) are the other use. — **Decided** (existentials opt-in; see `types.md` §3 for generics).

---

## 2. Dispatch (static vs dynamic)

The split falls straight out of the model:

- **Requirements → dynamic dispatch** (witness table). The conformer's implementation is what runs, including through `any I` and through generic constraints.
- **Extension methods → static dispatch**, resolved on the static type.

This is deliberately cleaner than Swift, where an extension can *also* supply a requirement's default (making the same surface sometimes dynamic, sometimes static). Here the rule is uniform: **in the interface body = dynamic; in an extension = static.**

**Reference — how the incumbents dispatch:**

| | Static | Dynamic | Defaults |
|---|---|---|---|
| **Swift** | extension-only methods; specialized generics | requirements (witness table); `any P` | requirement-default = dynamic; extension-only = static (the gotcha we're removing) |
| **Rust** | `<T: Trait>` / `impl Trait` (monomorphized) | `dyn Trait` (vtable) | in-trait default methods; dynamic under `dyn`; no gotcha |
| **Go** | concrete calls | interfaces (itab), always | none |

**Connection to concurrency (the shareable bound).** A declared shareable bound is forced only where the concrete body is hidden — **dynamic dispatch**. So a **requirement** whose implementations may forward a *closure* (or generic) parameter to a task carries the bound **as part of that parameter's type**; a **static extension method** has a visible body, so its requirement is inferred. Concrete reference parameters need no marker (shareability comes from their own type), and the **keyword spelling is still open** (`shareable` is a placeholder). See `concurrency.md` §5 for the full share analysis.

---

## 3. Open questions

- **`extension` keyword** — kept for now, but not locked; the semantics differ from Swift's, so a different spelling may fit better. — **Open (tentative: `extension`).**
- **Generic checking model** — whether generic bodies are checked modularly against the interface bound (Rust-style; forces declared bounds even when monomorphized) or per-instantiation (C++-style; inferrable, worse errors, no separate compilation of generics). Ties to the unlocked generics design. — **Open.**

---

## 4. Composition

### 4.1 Interface inheritance (refinement) — Decided (2026-07-16)

Interface inheritance is **requirement aggregation + a subtype edge**, not implementation or state inheritance — so the class-inheritance hazards (state diamond, fragile base, super chains) don't arise, and multiple inheritance is unproblematic.

- **Syntax (illustrative):** `interface B: A`; multiple bases `interface C: A, B`.
- **Meaning:** conforming to `B` requires conforming to `A`; `B` *is-a* `A` — `any B` is usable where `any A` is expected, and a `<T: B>` generic may call `A`'s requirements.
- **Multiple inheritance is fine** — it's a union of requirement sets, no state to collide.
- **A refining interface's body may provide or override a default for an inherited requirement** (dynamic, overridable). Not in an extension (extension == static dispatch). This is also how `B` can turn a *mandatory* requirement of `A` into an *optional* one for `B`'s conformers, by supplying a default.

### 4.2 Name conflicts & overload identity — Decided (2026-07-16)

- **Overloading keys on nominal argument *types* only.**
- **The shareable marker is erased for overload identity:** two members equal after erasing shareable are the *same* member. (General principle: overload resolution ignores auto-derived markers — shareable is the only one today.)
- When two bases (`C: A, B`) declare a same-named member:
  - **Same argument types** → the same member; one implementation satisfies both.
  - **Same argument types but differing only in shareable** → a **conflict → compile error**; the author reconciles. (A contravariance-based auto-merge is technically possible but rejected for clarity.)
  - **Different argument types** → distinct overloads, both required.

### 4.3 Default resolution across bases — Decided (2026-07-16)

- **Most-specific default in the refinement graph wins.** A refining interface's default overrides a base's normally.
- **No unique most-specific** (two *incomparable* sibling defaults for the same member) → the defaults **cancel** → the member becomes **mandatory** for conformers.
- **One default + one mandatory** (a base with no default) is **not** a conflict — "mandatory" just means "no default here," so the other base's default applies.
- **No disambiguation syntax:** on cancellation, a conformer **reimplements** the member from scratch (or the authors reconcile by renaming / splitting conformance). A "pick one of the inherited defaults" escape hatch could be added later; not now.
- **Soundness:** cancellation only ever turns an ambiguity into a mandatory requirement, which is always well-defined.

### 4.4 Anonymous composition & existentials — Decided (2026-07-16)

- **`A & B` composes interface requirements at a use site** — *structural over existing conformances*: any type conforming to both `A` and `B` satisfies `A & B`, with no named declaration. Distinct from a named refinement (§4.1), which is nominal and has its own identity. (Doesn't decide whether *base* conformance is nominal or structural — separate question; `A & B` composes whatever exists.)
- **`&` semantics:** commutative, associative, `A & A = A`, and `A & B` collapses to `B` when `B: A` (set-union of requirements).
- **Existentials (`any I`)** are type-erased, heap-boxed, dynamically-dispatched values — the tool for **heterogeneity / type erasure**: mixed-type collections (`[any Shape]`), reassignable fields, returning varying concrete types. Generics/`some` cover the homogeneous static case; `any` is reached for only when concrete types must mix or be erased.
- **Multi-interface existentials `any A & B` are supported** (Swift-style: the box carries a witness table per interface — a heavier box, cost paid only under the opt-in `any`). This is what makes heterogeneous collections of composed types work. (Rust restricts `dyn` to one non-auto trait for representation reasons; we accept the heavier box for ergonomics.)
- **Interface-typed values must be explicit `any` or `some`** — no bare interface-as-type. `any` = existential (above); `some` = opaque/static (mechanics deferred with generics). Keeps the erasure cost visible in the source.
- **shareable composes under the same `&`** — `A & shareable` is a marker composition (adds requirements, no methods/vtable), mirroring Rust's `dyn A + Send`.
- **Generic bound form `<T: A & B>`** is the same operator applied in generics — deferred to the generics design, not constrained here.

### 4.5 Still TODO (all tied to generics)

- **Associated types / generic interfaces** — interfaces parameterized over types; highest-complexity area.
- **Conditional conformance** — a type conforms to `I` only when its parameter does.
- **`some` (opaque types) mechanics**, and the `<T: A & B>` bound.
- **Dispatch/shareable interaction** — mostly covered (§2, §4.2); revisit under generics.

---

## 5. Open questions rollup

- `extension` keyword (tentative).
- Generic checking: modular vs per-instantiation.
- Composition still open (§4.5), all tied to generics: associated types / generic interfaces, conditional conformance, `some` mechanics.
