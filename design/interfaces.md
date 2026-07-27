# Interfaces

**Status:** working draft. The home for Nomu's interface/protocol design — conformance, dispatch, extensions, and (incoming) composition. Status tags: **Decided**, **Leaning**, **Open**.

**API scope:** no concrete syntax or keyword here is committed. The keyword itself (`interface` vs `protocol`) is open; `extension`, `any`, `&`, etc. are illustrative and Swift-shaped until we agree. What's being pinned down is the *model*, not the surface.

**Terminology:** this doc says "interface" for the Swift-protocol / Rust-trait / Go-interface family. "Requirement" = a member the interface demands; "conformer" = a type that satisfies it.

---

## 1. Model

- **Keyword: `interface`.** The declaration keyword is `interface`. — **Decided (2026-07-16).**
- **No class inheritance.** Abstraction and code reuse come from **interfaces + extensions**, not a base-class hierarchy. — **Decided** (`types.md` §1).
- **Requirements** are declared in the interface body; a conforming type must satisfy them. **Requirements are methods or properties** — a property requirement is `var name: T { get }` (read-only) or `var name: T { get set }` (settable); a method requirement is a signature. A requirement may carry an **overridable default in the body**, which makes it an *optional* requirement — a conformer may skip it and inherit the default. Defaults live in the interface body, never in an extension. (This is the tool for "this member is optional"; it avoids forcing an author to split off a second interface.) — **Decided (V1, 2026-07-16; property requirements 2026-07-20).**
  - **Property requirements are accessor-shaped, never storage.** A `{ get }`/`{ get set }` requirement is a get (and set) **accessor** in the witness table — never a field offset. A conformer satisfies it with a **stored field** (which auto-synthesizes trivial accessors) or a **computed property** (custom get/set bodies); the interface never dictates layout. This is what lets a default method operate on required state (`fun increment() { count = count + 1 }`) without reintroducing state inheritance: multiple interfaces requiring `count` collide into **one** field with shared accessors (no state diamond, §4.1), and it works through `any` (an erased box has accessors, not offsets). **Computed properties + get/set accessors are committed M5 language features** (structs have stored fields only today), not deferred — so both stored and computed satisfaction ship in M5.
  - **Mutation:** a `{ get set }` requirement whose default mutates it (or any settable access on a value conformer) needs a mutable (`var`) receiver — i.e. mutating-method semantics on value types, which M5 handles. Read-only `{ get }` avoids this.
- **Extensions are direct** — `extension I { … }` adds members to an interface in place, with no separate trait and no blanket-impl ceremony (Rust needs that only because of its coherence rules; we don't). — **Decided (semantics 2026-07-16; keyword `extension` locked 2026-07-23).**
- **Two extension forms.** A **plain extension** `extension T { … }` adds *new*, non-requirement methods — **statically dispatched**, resolved on the static type, and **visible only where the declaring module is imported**. A **conformance extension** `extension T: I { … }` supplies the requirement **witnesses** that make `T` conform to `I`; those witnesses populate the witness table, reached dynamically only through `any I` and statically everywhere the concrete type is known (dispatch is a call-site property — §2 — not a property of where the member is written). This **revises** the earlier rule that extensions could never implement a requirement. Invariants held: **one witness per `(T, requirement)`**, dispatched consistently however reached (removes Swift's default-vs-witness gotcha); a **plain** extension method sharing a **requirement's** name is a compile error (it would silently shadow); a requirement's overridable **default** still lives in the interface body, never an extension. **Coherence:** a conformance extension is legal only in `T`'s module or `I`'s module (global orphan rule — `generics.md` §1); a third module needing `T`-as-`I` conforms a **newtype** it owns. — **Decided (2026-07-20, revises 2026-07-16).**
  - **Plain form as built (M4.12).** `extension T { fun … }` on a `struct`/`enum`/`class` (`actor` deferred until actor instance methods exist). An **extension merge pass** folds the methods into `T`'s member set before typechecking, so every downstream pass sees an ordinary type with all its methods and needs no extension-awareness — the decl-to-type member merge M5 Phase A's conformance form reuses. Rules: **no stored properties** (Swift's rule — an extension adds behavior, not layout; computed properties become legal in extension bodies once they ship in M5 Phase A); **collision keyed on name + nominal argument types** (a method duplicating one already on `T`, from the body or an earlier extension, is a compile error; the first declaration wins; differing argument types are distinct overloads); a mutating extension method on a value type is **inferred mutating** and needs a `var` receiver, exactly like a body method (M4.11). **Module-scoped visibility is deferred** with the module system — under the single compilation unit an extension method is visible program-wide, like every other top-level declaration. The conformance form (`extension T: I`) is rejected pre-M5 with a targeted diagnostic.
  - **Actor conformance — parked (post-M5 design).** Conformance in M5 covers **struct/enum/class only**; an actor conforming to an interface (`extension SomeActor: I`, or an at-type clause on an `actor`) is rejected with a targeted diagnostic, mirroring the plain-extension deferral above. This is a deliberate parked decision, not merely unimplemented: actors expose `on` handlers (message-send, blocking-until-return, isolated, non-reentrant — `concurrency.md` §213/§229), so an interface's synchronous `fun` requirement dispatched through `any I` — where the caller can't see the receiver is an actor — crosses an isolation boundary and raises real deadlock/reentrancy questions. It also depends on actor instance methods existing first (still deferred). Revisit after M5 alongside actor instance methods and the sync-over-isolation dispatch semantics.
- **Existentials** — `any I` is the opt-in form for dynamic dispatch / heterogeneous storage. Generic constraints (`<T: I>`) are the other use. — **Decided** (existentials opt-in; see `types.md` §3 for generics).

---

## 2. Dispatch (static vs dynamic)

**Dispatch is a call-site property, not a property of where a member is written.** A call resolves **statically** (inlinable) wherever the concrete conformer type is known, and **dynamically** through the witness table only where the type is erased. So:

- **Requirements** — statically dispatched on a concrete receiver or a specialized generic; dynamically through `any I` (or an unspecialized generic). The conformer's implementation runs in every case; erasure only changes how it is reached. Guaranteed-static, specialization-independent sites are **concrete types** and **`some I`** opaque types (`generics.md` §1).
- **Plain extension (free) methods** — always **static**, resolved on the static type; they do not enter the witness table and are not seen through `any I`.

This is cleaner than Swift, where an extension supplying a requirement's default dispatches statically while the same surface through `any P` dispatches dynamically to a possibly-different method. Nomu removes that gotcha with a representational invariant instead of a location rule: **one witness per `(type, requirement)`, dispatched consistently however reached** (§1, §4.2). A conformance may be supplied in the type's body or in a conformance extension (`extension T: I`, §1); either way it is the single witness.

**Property-requirement performance follows the same call-site rule.** A `{ get }` accessor on a stored-backed property **devirtualizes to a field load** wherever the concrete type is statically known — a concrete receiver, a `some I` value (one hidden underlying type), or a specialized generic — because the requirement is not dynamic there (the compiler resolves it to the known conformer's accessor, no witness lookup, and folds the trivial getter to the load). It is a genuine indirect accessor call only where the type is erased — `any I`, or an unspecialized dictionary-passing generic (which can't do a direct field load anyway, having no known layout). So value-heavy hot code stays a field load by staying on concrete types / `some`; the indirect call is confined to the opt-in dynamic surface. Supporting computed properties adds no cost to the stored path — a stored property is resolved and lowered as storage regardless.

**Reference — how the incumbents dispatch:**

| | Static | Dynamic | Defaults |
|---|---|---|---|
| **Swift** | extension-only methods; specialized generics | requirements (witness table); `any P` | requirement-default = dynamic; extension-only = static (the gotcha we're removing) |
| **Rust** | `<T: Trait>` / `impl Trait` (monomorphized) | `dyn Trait` (vtable) | in-trait default methods; dynamic under `dyn`; no gotcha |
| **Go** | concrete calls | interfaces (itab), always | none |

**Connection to concurrency (the shareable bound).** A declared shareable bound is forced only where the concrete body is hidden — **dynamic dispatch**. So a **requirement** whose implementations may forward a *closure* (or generic) parameter to a task carries the bound **as part of that parameter's type**; a **static extension method** has a visible body, so its requirement is inferred. Concrete reference parameters need no marker (shareability comes from their own type), and the **keyword spelling is still open** (`shareable` is a placeholder). See `concurrency.md` §5 for the full share analysis.

---

## 3. Open questions

- **`extension` keyword** — **locked (2026-07-23).** Kept as `extension`; the plain (non-conformance) form shipped in M4.12 (§1, plain form as built).
- **Generic checking model** — modular checking against declared bounds (Rust-style). — **Decided** (`generics.md` §1).

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
- **Interface-typed values must be explicit `any` or `some`** — no bare interface-as-type. `any` = existential (above); `some` = opaque/static. Keeps the erasure cost visible in the source.
- **`Self`-type requirements are constraint-only. — Decided (2026-07-23).** A requirement may mention `Self` (`fun clone() -> Self`, `fun combined(with: Self) -> Self`). An interface that mentions `Self` **anywhere** in a requirement is **constraint-only**: usable as a generic bound `<T: I>` and as `some I` (where `Self` binds to the one known/hidden concrete type), but **rejected as `any I`** — a type-erased box can't guarantee two `Self` values share a concrete type. This blanket rule is the sound baseline (M5 Phase A2). **Covariant-`Self` existential erasure** — where an interface whose `Self` occurrences are all covariant (return position) regains `any I` use, with `-> Self` erasing to `-> any I` at the box boundary — is **scheduled as the last M5 item (`m5-spec.md` 5.6, Phase F)**, not deferred out. An interface with any contravariant/invariant `Self` (parameter, or a `Self`-typed `{ get set }`) stays constraint-only even after Phase F. The property is computed at interface declaration and propagates through refinement (`B: A` is constraint-only if `A` is). Diagnosed at type formation (an `any I` annotation), not at call sites.
- **`some I` opaque types — return-position, one underlying type, static. — Decided (2026-07-23).** `some I` is allowed in **return position** (`fun makeShape() -> some Drawable`); every `return` must yield the *same* concrete type; the caller sees an opaque type with identity conforming to `I` but with hidden concrete identity. Lowering is **no box, static dispatch** — the concrete type is compiler-known (only hidden from the caller), so requirement calls devirtualize to direct calls / field loads (this is why `some` is core, `generics.md` §1). Parameter-position `some` (anonymous-generic sugar for `<T: I>`) is **deferred** — `<T: I>` covers it. Build plan: `m5-spec.md` Phase A3.
- **shareable is a prefix modifier `shared`, not an `&`-composed marker** (revised 2026-07-20). Unlike an interface requirement, the "can cross a task boundary" capability is spelled as a prefix type modifier joining `any`/`some`: `shared any Shape`, `shared (Int) -> Bool`, and the declared generic bound `<shared T>`. It is orthogonal to `&` interface composition — a value that is both `A` and shareable is `shared any A`, and a bound that is both `Comparable` and shareable is `<shared T: Comparable>`. (This diverges from Rust's `dyn A + Send` bound-list spelling; the prefix was chosen because it also spells shareable *closure/function* types, which a bare function type can't express as an `&`-composition. Full rationale in `generics.md` §3a.)
- **Generic bound form `<T: A & B>`** is the same operator applied in generics — deferred to the generics design, not constrained here.

### 4.5 Still TODO (all tied to generics)

(M5 staging and the deferred-generics list — operators, coherence, `some` — live in `generics.md`.)

- **Associated types / generic interfaces** — interfaces parameterized over types; highest-complexity area.
- **Conditional conformance** — a type conforms to `I` only when its parameter does.
- **The `<T: A & B>` bound** (deferred to the generics design).
- **Dispatch/shareable interaction** — mostly covered (§2, §4.2); revisit under generics.

(`some` opaque-type mechanics and `Self`-requirement existential legality are now **Decided** — §4.4.)

---

## 5. Open questions rollup

- Generic checking: modular vs per-instantiation. *(Resolved in `generics.md` §1 — modular, locked.)*
- Composition still open (§4.5), tied to generics: associated types / generic interfaces, conditional conformance, the `<T: A & B>` bound. *(`some` mechanics and `Self`-requirement existential legality now Decided — §4.4.)*
