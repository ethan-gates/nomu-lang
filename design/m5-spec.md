# M5 — Implementation Spec (Generics + Interfaces)

**Status:** working draft — the ordered work plan for M5, derived from the design decisions in `generics.md`, `interfaces.md`, `types.md` §3–4, and `concurrency.md` §5. This is the document code planning reads from. Status of the *design* is settled (see those docs); this pins the *build sequence*.

**Framing correction:** the roadmap calls M5 "generics + monomorphization," but the compiler has **no interfaces today** (concrete `struct`/`enum`/`class`/`actor`/`fun` only) and **no computed properties**. So M5 stacks three features — interfaces, computed properties, generics — plus error handling. Monomorphization is an *optional accelerator*, not the correctness baseline (see §5).

**Prerequisites:** grounding the exit criteria below against the code found concrete features M5 assumes and the compiler lacked, each shipped as a short pre-M5 slice:
- **Enum value construction** (needed for `Option<T>` in Phase B and `Result<T,E>` in Phase E) and **`let` fields** (needed for `Box<T> { let value: T }` in Phase B and Phase C's deeply-immutable-class shareability) — **M4.10** (`types.md` §2, `memory-model.md` §4).
- **Mutating value-type methods**, needed by Phase A's `{ get set }` setters and computed-property setters — **M4.11** (`types.md` §3).
- **Plain extensions** `extension T { … }` (non-conformance), the parse/member-merge path Phase A's conformance extensions reuse — **M4.12** (`interfaces.md` §1, plain form as built). The compiler had no `extension` construct at all.
- **Nomu prelude mechanism** (the home for Phase B/E's `Option`/`Result`/`Box`, compiled alongside user code) plus the C-source split — **M4.13** (roadmap; `src/stdlib/`, `src/runtime/`). There is no stdlib/prelude path today; hard-gates Phase B.

The Phase A iteration demo (below) is also resolved — it assumes loops/collections the language doesn't have yet.

---

## 1. Scope

**Ships in M5:**
- Interfaces: declaration, requirements (method + property), overridable defaults, refinement (`B: A`), `&` composition.
- Conformance via `extension T: I { … }` (the conformance form; the plain form `extension T { … }` shipped in **M4.12**) and `struct T: I { … }` at-type sugar; witness tables.
- `Self`-type in requirements + the existential-legality rule: constraint-only baseline in Phase A (a `Self`-mentioning interface is usable as `<T: I>` / `some I`, not `any I`), relaxed in **Phase F (M5.1)** to a position-sensitive rule so covariant-`Self` (`-> Self`) interfaces regain `any I` via erasure.
- Existentials `any I`; opaque types `some I` (return-position, one underlying type, statically dispatched).
- Computed properties + get/set accessors (language feature).
- Generic parameters + interface bounds `<T: I>`; modular checking; type-argument inference; witness-passing lowering.
- Exhaustiveness under generics.
- The `shared` bound + conditional conformance; complete the M3 shareability checker (deeply-immutable classes).
- `Result<T, E>` + explicit `match` error handling.

**Deferred (recorded in `generics.md` §2):** operators-as-requirements, associated types (staged — witness layout reserves a type-witness slot), `?`-sugar / typed throws, the newtype/typealias mechanism, monomorphization if it slips (§5).

---

## 2. Compiler surface touched

Current pipeline (Swift, post-M4.9): `Lexer → Parser → AST → Typechecker (POD + let/var) → Sema (typed IR) → exhaustiveness pass → CodegenIR (emit C) → cc`. M5 touches every stage.

- **Lexer** — keywords `interface`, `extension`, `some`, `any`, `shared`, `get`, `set`; disambiguate `<`/`>` as generic brackets vs. comparison; `&` type composition.
- **AST** — `InterfaceDecl`, `ExtensionDecl`, generic parameter lists on decls, `TypeRef` carrying generic arguments + modifiers (`any`/`some`/`shared`), property declarations with accessor bodies, conformance clauses.
- **Semantic pass (`Sema`)** — the bulk: conformance checking, witness resolution, modular generic checking against bounds, constraint solving, type-arg inference, exhaustiveness under generics, conditional conformance, `shared` propagation. (The `Type` model and symbol tables it extends were built in M4.9; `compiler.md` §1.)
- **Codegen** — witness-table emission in C, witness-passing generic lowering, `any` boxing, `some`/concrete devirtualization to direct calls, accessor lowering (stored → field load), `Result` layout.

---

## 3. Phased plan

Phases are ordered by dependency. Each has an exit criterion expressed as programs that compile and run.

### Phase A — Interfaces + computed properties + `some`
The prerequisite feature; everything else builds on witness tables. Split into three coherent sub-parts.

**A1 — interface core.**
- Parse/typecheck `interface I { … }`: method requirements, property requirements (`var x: T { get }` / `{ get set }`), overridable defaults.
- Computed properties + get/set accessors as a language feature (structs gain accessors; stored fields auto-synthesize trivial ones). Mutating setters on value types.
- Conformance: `extension T: I { … }` (extends M4.12's plain extension with a conformance clause + witness generation) and `struct T: I { … }` sugar. Witness-table generation (accessor-shaped property slots — never offsets — plus method slots; reserve an unused type-witness slot for future associated types).
- Refinement `B: A` (requirement aggregation + subtype edge; most-specific default wins, incomparable sibling defaults **cancel → mandatory**, `interfaces.md` §4.3); `&` composition.

**A2 — `Self`-type requirements + existential legality.**
- Allow `Self` in requirement signatures (`fun clone() -> Self`, `fun combined(with: Self) -> Self`). In a generic body `<T: I>` and behind `some I`, `Self` binds to the one known/hidden concrete type, so witness calls are well-typed.
- **Existential restriction (interim, tightened in Phase F):** an interface that mentions `Self` anywhere in a requirement is **constraint-only** — legal as a generic bound and as `some I`, **rejected as `any I`** with a local error (a heterogeneous box can't guarantee two `Self`s are the same type). This blanket rule is the sound baseline; **Phase F (M5.1)** relaxes it to a position-sensitive one so covariant-`Self` interfaces regain `any I`.
- The check is a property of the interface computed at declaration; refinement propagates it (`B: A` is constraint-only if `A` is).

**A3 — `some I` opaque types.**
- Parse/typecheck `some I` in **return position** (`fun makeShape() -> some Drawable`). Parameter-position `some` (anonymous-generic sugar for `<T: I>`) is **deferred** — Phase B's `<T: I>` already covers it (decision below).
- **One underlying type:** every `return` in the body must yield the *same* concrete type; the caller sees an opaque type with identity that conforms to `I` but whose concrete identity is hidden.
- **Lowering — no box, static dispatch.** The concrete type is fixed and compiler-known (only *hidden from the caller*), so requirement calls on a `some I` value devirtualize to direct calls / field loads — mono-independent static dispatch (`generics.md` §1, the reason `some` is core rather than deferred). Contrast `any I`, which boxes and dispatches through the witness.

**Dispatch (all of A):** call-site property — direct/devirtualized on a concrete receiver and on `some I`; witness lookup through `any I`.

**Exit:**
- An `interface Drawable` with a default method and a `{ get }` property; two concrete conformers; individual `any Drawable` values dispatched dynamically; a stored-backed `get` verified to lower to a field load on a concrete call. (A collection of `[any Drawable]` iterated in a loop is the natural demo but assumes loops + a collection type the language lacks — dispatch on individual `any Drawable` values instead, or pull minimal iteration forward; the interface feature needs neither.)
- A `fun makeShape() -> some Drawable` returns a hidden concrete type; the caller calls a requirement on it and the emitted C shows a **direct call, no witness indirection**; a body returning two different concrete types is a clean local error.
- An interface with a `Self` requirement is usable as `some I` / a generic bound and **rejected** as `any I` with a clear message.

### Phase B — Generic parameters + constraints
- Parse/typecheck `<T: I>`, `<T: I & J>` on `fun` and on types (`struct Box<T>`).
- **Modular checking** against declared bounds (the locked invariant — bodies checked once against what the bound promises).
- Type-argument inference (bidirectional: from arguments and return position; explicit `f<Int>(…)` fallback).
- Lowering: **witness-passing** (dictionary) — the correctness baseline; a generic body receives witness tables for its bounds. Reuses the exact `any` conformance representation.
- Exhaustiveness under generics — checked on the generic enum definition; instantiation adds no cases.
- **Exit:** `Option<T>`, `Box<T>`, a generic `fun map<T, U>(…)` over closures, and `fun describe<T: Drawable>(x: T)` all compile and run; a bound violation is a clean local error.

### Phase C — `shared` bound + conditional conformance
- The `shared` prefix modifier: declared bound `<shared T>`, shareable closure/function types `shared (A) -> B`, `shared any I`.
- Conditional conformance: `Box<T>` is shareable iff `T` is — the same mechanism the `shared` bound needs; auto-derived structurally for the marker (`concurrency.md` §5).
- Complete the M3 shareability checker: recognize deeply-immutable classes (all `let`, recursively) as shareable — the case M3 conservatively rejects.
- **Exit:** sending a `Box<Int>` across a task boundary type-checks; sending a `Box<SomeClass>` (non-shareable) is rejected with a local error; a deeply-immutable class is accepted where M3 rejected it.

### Phase D — Monomorphization (accelerator, descopable)
- A specialization pass over Phase B's witness path: stamp concrete copies, devirtualize requirement calls, inline trivial accessors to loads.
- Polymorphic-recursion termination: detect infinite specialization (`f<Box<T>>()`) and error.
- Architectural note: this is where the **typed mid-level IR** (`compiler.md` §1, built in M4.9) earns its place — monomorphization is a specialization pass over it. **Nothing depends on this phase for correctness** (goal 3) — it's the performance lever, and it may slip past M5's core without blocking the milestone.
- **Exit:** a specialized `Box<Int>` shows no witness indirection in the emitted C on the hot path; benchmark parity target noted, not required.

### Phase E — Error handling
- `Result<T, E>` as a generic enum in the stdlib — a `stdlib/*.nomu` prelude citizen (the mechanism ships in M4.13; depends on Phase B generic enums).
- Explicit `match` handling; no `?` operator, no typed throws (deferred).
- **Exit:** a failable function returns `Result`, and a caller handles both cases via `match`.

### Phase F — Covariant-`Self` existential erasure (M5.1, last)
Sequenced last in M5; relaxes Phase A2's blanket constraint-only rule. Depends only on Phase A (existentials + `Self`-requirements), not on B–E, but scheduled after them as the closing M5 item.
- **Position analysis on `Self`.** Classify each `Self` occurrence in a requirement as **covariant** (return position) or **contravariant/invariant** (parameter position; a `Self`-typed `{ get set }` property; `Self` nested under a mutable/`&`-composed slot).
- **Refined existential rule.** An interface whose `Self` occurrences are **all covariant** becomes usable as `any I` again: a `-> Self` requirement **erases to `-> any I`** at the existential boundary (the box hands back another existential, which is sound — the caller never asserts two boxes share a concrete type). An interface with any contravariant/invariant `Self` stays **constraint-only** (the Phase A2 rule).
- **Lowering.** Through `any I`, a covariant-`Self` requirement's witness returns the concrete `Self`, re-boxed as `any I` at the call boundary; concrete and `some I` sites are unaffected (they already know the type).
- **Exit:** `interface Cloneable { fun clone() -> Self }` is usable as `any Cloneable` and `c.clone()` yields an `any Cloneable`; `interface Combinable { fun combined(with: Self) -> Self }` (contravariant `Self`) remains rejected as `any I` with the Phase A2 message; both stay usable as `<T: I>` / `some I`.

---

## 4. Dependencies

```
A (interfaces + computed properties + Self-reqs + some)
├─ B (generics: params, constraints, witness-passing)
│  ├─ C (shared bound + conditional conformance)
│  ├─ D (monomorphization)          [accelerator, descopable]
│  └─ E (Result / error handling)
└─ F (covariant-Self existential erasure)   [M5.1, sequenced last]
```

A gates everything (witness tables). B gates C/D/E. C, D, E are independent of each other. F depends only on A but is sequenced last, closing M5.

---

## 5. Cross-cutting decisions (from the design docs)

- **Checking model — modular, locked.** Generic bodies checked once against declared bounds. Keeps monomorphization, dictionary-passing, and GC value-witness stenciling all reachable (`generics.md` §1).
- **Lowering — witness-first.** Dictionary-passing is the correctness baseline (Phase B); monomorphization (Phase D) is a pure accelerator layered on top. Static dispatch that the language *guarantees* comes from concrete types and `some`, not from specialization (`generics.md` §1, goal 3).
- **Witness representation — one shared form** for `any` and generics; accessor-shaped property slots (never offsets); a reserved type-witness slot for future associated types (`interfaces.md` §1–§2).
- **Coherence — global (Rust orphan).** Enforcement waits on modules; under M5's single compilation unit uniqueness is trivial (`generics.md` §1).
- **C-backend implications** — witness tables become emitted C structs of function pointers; `any` is a boxed `{ witness*, payload }`; the transition checklist for the LLVM move is unchanged (`compiler.md` §6).

---

## 5a. Runtime / GC posture (Decided 2026-07-21)

M5 is a front-end + codegen milestone; the M4 scheduler (`runtime.md` §8 — fibers, carriers, poller, timer, actors) is **not touched**. The runtime-language question (keep the runtime in C vs. move it to Rust for MMTk) and the MMTk-binding approach are **deferred to M6**. Rationale: codegen target and runtime language are independent axes; MMTk exposes a C ABI so C callers are fine; the alloc fast path and write barriers are codegen-inlined regardless of runtime language; and the scheduler barely touches the GC (only safepoints + stack scanning). The larger lever is **codegen precision** — a moving collector needs precise stack maps, which the C backend can't emit, so real MMTk may couple to LLVM (M8) more than the M6-before-M8 order implies (shadow stack / conservative roots on C are the alternatives). This sequencing is an open roadmap item, not an M5 blocker.

**Two invariants M5 must hold** so every M6 option stays open (both are good hygiene regardless):
1. **Single allocation seam.** Every heap allocation goes through one codegen-controlled call (`rt_alloc` today) so the allocator can be swapped for MMTk's later with a localized change.
2. **Explicit, scannable object model.** New M5 object shapes — `any` boxes, witness tables, generic instances — have a clear header and discoverable pointer layout, so a C or Rust binding (and later LLVM-emitted barriers/maps) can scan them precisely. Drop the `rt_alloc` header pointer-arithmetic hack (`compiler.md` §6); do not bake in representation tricks that assume conservative-only scanning.

## 6. Risks / watch items

- **Monomorphization is descopable.** Phase D runs on the typed IR (built in M4.9); keep it a pure accelerator so it can slip past M5's core without blocking the milestone (goal 3).
- **Angle-bracket ambiguity.** `<`/`>` as generic brackets vs. comparison needs careful parser handling (the classic C++/Rust turbofish territory) — decide the disambiguation rule in Phase B.
- **Mutating setters on value types.** New semantics in Phase A; keep read-only `{ get }` requirements the common path.
- **Type-argument inference scope.** Bidirectional inference can sprawl; keep M5's inference to arguments + return position, explicit args otherwise.
- **`some I` underlying-type unification.** The "all returns yield one concrete type" check is the delicate part of opaque types; without generic parameters in Phase A it is a straight equality over the return expressions' concrete types, but keep it a distinct pass so Phase B/D can extend it to specialized bodies.
- **`Self`-requirement / existential split.** Once an interface is constraint-only, `any I` uses must be diagnosed early (at type-formation) rather than at call sites; keep read-only, `Self`-free interfaces the common existential path.

---

## 7. Deferred cleanups (parked, decide later)

Cleanups spotted while doing adjacent work (M4.13 onward) but intentionally **not** done there, to keep those diffs behavior-preserving. Parked here to decide/schedule deliberately.

- **Symbol mangling — DONE (M4.15).** Generated identifiers are `nomu_`-prefixed + z-encoded via `src/codegen/sources/Mangle.swift`, so Nomu names can't collide with libc. Design: `compiler.md` §2a. **M5 note:** when generics land, extend `Mangle` to encode type arguments for monomorphized instances (and arg types if overloading is wired).
- **Parallelism knob (pre-existing, now in `src/runtime/runtime.c`).** Carrier count is hardcoded `ncarriers = 4`; the `GOMAXPROCS`-equivalent is unwired (`runtime.md` §... poller/knob). Untouched by M4.13.
- **`rt_alloc` header pointer-arithmetic hack** — already tracked in §5a invariant 2; drop it with the M5 object-model work.
