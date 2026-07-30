# M5 — Implementation Spec (Generics + Interfaces)

**Status:** working draft — the ordered work plan for M5, derived from the design decisions in `generics.md`, `interfaces.md`, `types.md` §3–4, and `concurrency.md` §5. This pins the *build sequence*; the *design* is settled in those docs.

> Authoring conventions (numbering, status markers, front-matter sections, decision/slice records, exit criteria) live in `lang-project/milestone-doc-guide.md`. This doc's `5.x` numbering and `✅/🔨/⬜` markers follow it.

**Build status (2026-07-28):** **5.1 ✅ complete**; **5.2 ✅ complete** — 5.2.1 (parse + type model), 5.2.2 (generic functions + witness-passing), 5.2.3 (generic *types* + reabstraction thunk for `map`-over-closures; `examples/generic-types.nomu`, `examples/generic-hof.nomu`), 5.2.4 (prelude citizen `Option<T>`). **5.3 ✅ complete** — 5.3.1 ✅ (structural shareability: recursive fields, conditional conformance for generics, deeply-immutable classes, `String` shareable; `examples/shared-bound.nomu`), 5.3.2 ✅ (the `<shared T>` bound: parse, discharge at call sites, shared `T` shareable in-body; `examples/shared-param.nomu`); 5.3.3 **deferred** (explicit `shared` function-type / existential spellings — no M5 consumer; tracked in `design/deferred.md`). **5.4 ✅ complete** — whole-program monomorphization (Swift/WMO model): specializes every generic instantiation to concrete decls via an IR→IR pass, devirtualizing requirement calls and removing the 5.2.3 box-and-leak; `any I` stays dynamic; polymorphic recursion is a clean error (`src/frontend/sources/Monomorphize.swift`). **5.5 ✅ complete** — `Result<T, E>` (`ok`/`err`) is a prelude citizen in `src/stdlib/core.nomu`; explicit `switch` handling (`examples/result.nomu`). **Next: 5.6 (covariant-Self existential erasure) — the closing M5 item.**

**Framing correction:** the roadmap calls M5 "generics + monomorphization," but the compiler has **no interfaces today** (concrete `struct`/`enum`/`class`/`actor`/`fun` only) and **no computed properties**. So M5 stacks three features — interfaces, computed properties, generics — plus error handling. Monomorphization is an *optional accelerator*, not the correctness baseline (see 5.0.4).

**Prerequisites:** grounding the exit criteria below against the code found concrete features M5 assumes and the compiler lacked, each shipped as a short pre-M5 slice:
- **Enum value construction** (needed for `Option<T>` in 5.2 and `Result<T,E>` in 5.5) and **`let` fields** (needed for `Box<T> { let value: T }` in 5.2 and 5.3's deeply-immutable-class shareability) — **M4.10** (`types.md` §2, `memory-model.md` §4).
- **Mutating value-type methods**, needed by 5.1's `{ get set }` setters and computed-property setters — **M4.11** (`types.md` §3).
- **Plain extensions** `extension T { … }` (non-conformance), the parse/member-merge path 5.1's conformance extensions reuse — **M4.12** (`interfaces.md` §1, plain form as built). The compiler had no `extension` construct at all.
- **Nomu prelude mechanism** (the home for 5.2/5.5's `Option`/`Result`, compiled alongside user code) plus the C-source split — **M4.13** (roadmap; `src/stdlib/`, `src/runtime/`). There is no stdlib/prelude path today; hard-gates 5.2.

The 5.1 iteration demo (below) is also resolved — it assumes loops/collections the language doesn't have yet.

---

## 5.0 · Front matter — scope, surface, dependencies, decisions, deferrals

The non-build context the plan rests on: what ships (5.0.1), the compiler surface touched (5.0.2), the phase dependency order (5.0.3), cross-cutting decisions and runtime posture (5.0.4–5.0.5), and the risk / deferred lists (5.0.6–5.0.8).

### 5.0.1 · Scope

**Ships in M5:**
- Interfaces: declaration, requirements (method + property), overridable defaults, refinement (`B: A`), `&` composition.
- Conformance via `extension T: I { … }` (the conformance form; the plain form `extension T { … }` shipped in **M4.12**) and `struct T: I { … }` at-type sugar; witness tables.
- `Self`-type in requirements + the existential-legality rule: constraint-only baseline in 5.1 (a `Self`-mentioning interface is usable as `<T: I>` / `some I`, not `any I`), relaxed in **5.6** to a position-sensitive rule so covariant-`Self` (`-> Self`) interfaces regain `any I` via erasure.
- Existentials `any I`; opaque types `some I` (return-position, one underlying type, statically dispatched).
- Computed properties + get/set accessors (language feature).
- Generic parameters + interface bounds `<T: I>`; modular checking; type-argument inference; witness-passing lowering.
- Exhaustiveness under generics.
- The `shared` bound + conditional conformance; complete the M3 shareability checker (deeply-immutable classes).
- `Result<T, E>` + explicit `match` error handling.

**Deferred (recorded in `generics.md` §2):** operators-as-requirements, associated types (staged — witness layout reserves a type-witness slot), `?`-sugar / typed throws, the newtype/typealias mechanism, monomorphization if it slips (5.0.4).

---

### 5.0.2 · Compiler surface touched

Current pipeline (Swift, post-M4.9): `Lexer → Parser → AST → Typechecker (POD + let/var) → Sema (typed IR) → exhaustiveness pass → CodegenIR (emit C) → cc`. M5 touches every stage.

- **Lexer** — keywords `interface`, `extension`, `some`, `any`, `shared`, `get`, `set`; disambiguate `<`/`>` as generic brackets vs. comparison; `&` type composition.
- **AST** — `InterfaceDecl`, `ExtensionDecl`, generic parameter lists on decls, `TypeRef` carrying generic arguments + modifiers (`any`/`some`/`shared`), property declarations with accessor bodies, conformance clauses.
- **Semantic pass (`Sema`)** — the bulk: conformance checking, witness resolution, modular generic checking against bounds, constraint solving, type-arg inference, exhaustiveness under generics, conditional conformance, `shared` propagation. (The `Type` model and symbol tables it extends were built in M4.9; `compiler.md` §1.)
- **Codegen** — witness-table emission in C, witness-passing generic lowering, `any` boxing, `some`/concrete devirtualization to direct calls, accessor lowering (stored → field load), `Result` layout.

---

### 5.0.3 · Dependencies

```
5.1 (interfaces + computed properties + Self-reqs + some)
├─ 5.2 (generics: params, constraints, witness-passing)
│  ├─ 5.3 (shared bound + conditional conformance)
│  ├─ 5.4 (monomorphization)          [accelerator, descopable]
│  └─ 5.5 (Result / error handling)
└─ 5.6 (covariant-Self existential erasure)   [sequenced last]
```

5.1 gates everything (witness tables). 5.2 gates 5.3/5.4/5.5. 5.3, 5.4, 5.5 are independent of each other. 5.6 depends only on 5.1 but is sequenced last, closing M5.

---

### 5.0.4 · Cross-cutting decisions (from the design docs)

- **Checking model — modular, locked.** Generic bodies checked once against declared bounds. Keeps monomorphization, dictionary-passing, and GC value-witness stenciling all reachable (`generics.md` §1).
- **Lowering — witness-first.** Dictionary-passing is the correctness baseline (5.2); monomorphization (5.4) is a pure accelerator layered on top. Static dispatch that the language *guarantees* comes from concrete types and `some`, not from specialization (`generics.md` §1, goal 3).
- **Witness representation — one shared form** for `any` and generics; accessor-shaped property slots (never offsets); a reserved type-witness slot for future associated types (`interfaces.md` §1–§2).
- **Coherence — global (Rust orphan).** Enforcement waits on modules; under M5's single compilation unit uniqueness is trivial (`generics.md` §1).
- **C-backend implications** — witness tables become emitted C structs of function pointers; `any` is a boxed `{ witness*, payload }`; the transition checklist for the LLVM move is unchanged (`compiler.md` §6).

---

### 5.0.5 · Runtime / GC posture (Decided 2026-07-21)

M5 is a front-end + codegen milestone; the M4 scheduler (`runtime.md` §8 — fibers, carriers, poller, timer, actors) is **not touched**. The runtime-language question (keep the runtime in C vs. move it to Rust for MMTk) and the MMTk-binding approach are **deferred to M6**. Rationale: codegen target and runtime language are independent axes; MMTk exposes a C ABI so C callers are fine; the alloc fast path and write barriers are codegen-inlined regardless of runtime language; and the scheduler barely touches the GC (only safepoints + stack scanning). The larger lever is **codegen precision** — a moving collector needs precise stack maps, which the C backend can't emit, so real MMTk may couple to LLVM (M8) more than the M6-before-M8 order implies (shadow stack / conservative roots on C are the alternatives). This sequencing is an open roadmap item, not an M5 blocker.

**Two invariants M5 must hold** so every M6 option stays open (both are good hygiene regardless):
1. **Single allocation seam.** Every heap allocation goes through one codegen-controlled call (`rt_alloc` today) so the allocator can be swapped for MMTk's later with a localized change.
2. **Explicit, scannable object model.** New M5 object shapes — `any` boxes, witness tables, generic instances — have a clear header and discoverable pointer layout, so a C or Rust binding (and later LLVM-emitted barriers/maps) can scan them precisely. Drop the `rt_alloc` header pointer-arithmetic hack (`compiler.md` §6); do not bake in representation tricks that assume conservative-only scanning.

---

### 5.0.6 · Risks / watch items

- **Monomorphization is descopable.** 5.4 runs on the typed IR (built in M4.9); keep it a pure accelerator so it can slip past M5's core without blocking the milestone (goal 3).
- **Angle-bracket ambiguity — resolved (2026-07-25): Swift model.** `<`/`>` are generic brackets only in **declaration position** (`fun f<T>`, `struct Box<T>`) and **type position** (annotations like `let b: Box<Int>`), both unambiguous; in **expression position `<` is always comparison**. There is no explicit call-site type-argument form (`f<Int>(x)` does not exist) — inference plus type context cover it. Generic construction stays inference-based (`Box(3)` with the type from context/annotation), so generic brackets never appear in expression position and the parser needs no lookahead/backtracking. Turbofish rejected (new syntax); a whitespace-significance rule rejected (would make whitespace semantically significant across all expressions to buy a feature inference already covers). The whitespace rule stays available as a future escape hatch if explicit call-site type args are ever genuinely needed, since type/decl positions are already unambiguous. (`generics.md` §3a.)
- **Mutating setters on value types.** New semantics in 5.1; keep read-only `{ get }` requirements the common path.
- **Type-argument inference scope.** Bidirectional inference can sprawl; keep M5's inference to arguments + return position, explicit args otherwise.
- **`some I` underlying-type unification.** The "all returns yield one concrete type" check is the delicate part of opaque types; without generic parameters in 5.1 it is a straight equality over the return expressions' concrete types, but keep it a distinct pass so 5.2/5.4 can extend it to specialized bodies.
- **`Self`-requirement / existential split.** Once an interface is constraint-only, `any I` uses must be diagnosed early (at type-formation) rather than at call sites; keep read-only, `Self`-free interfaces the common existential path.

---

### 5.0.7 · Deferred cleanups (parked, decide later)

Cleanups spotted while doing adjacent work (M4.13 onward) but intentionally **not** done there, to keep those diffs behavior-preserving. Parked here to decide/schedule deliberately.

- **Symbol mangling — DONE (M4.15).** Generated identifiers are `nomu_`-prefixed + z-encoded via `src/codegen/sources/Mangle.swift`, so Nomu names can't collide with libc. Design: `compiler.md` §2a. **M5 note:** when generics land, extend `Mangle` to encode type arguments for monomorphized instances (and arg types if overloading is wired).
- **Parallelism knob (pre-existing, now in `src/runtime/runtime.c`).** Carrier count is hardcoded `ncarriers = 4`; the `GOMAXPROCS`-equivalent is unwired (`runtime.md` §... poller/knob). Untouched by M4.13.
- **`rt_alloc` header pointer-arithmetic hack** — already tracked in 5.0.5 invariant 2; drop it with the M5 object-model work.
- **General assignment type-checking (pre-existing).** The plain-assign path (`x = expr`) type-checks the rhs but does not verify it is *assignable* to the target's type — a general `Sema` hygiene gap, not phase-specific. Closing it also enforces per-function opaque identity (5.1.3) for free, and lets an `any I`/`some I` binding target coerce on assignment as it already does on `let`.

---

### 5.0.8 · Deferred feature work

Feature gaps around the phases, grouped by the phase that owns the fix.

**Shipped (2026-07-27) — 5.1 completion (example: `examples/upcast.nomu`):**
- **`any`→`any` existential upcast** — `let a: any A = someAnyB` where B refines A; the witness carries a `base_A` pointer per transitive base, so the box re-boxes through it (payload shared, overriding witness preserved). Composition source/target still deferred. *(5.1.1)*
- **Property *set* through `any I`** — `d.prop = v` on an existential dispatches to the witness `_set` slot; a get-only requirement is a clean local error. *(5.1.1)*
- **Default-body enrichments** — a default may read a requirement by **bare name** (`name`, not just `self.name`) and **write** a settable requirement (`self.count = v`); default-calling-default (`self.m()`) already worked. *(5.1.1)*
- **Extension computed properties** — a computed property in a conformance extension now satisfies a property requirement (parsed + merged into the target). *(5.1.1)*
- **Opaque forward-reference member access** — a `some I` property read no longer needs the underlying known in Sema; codegen resolves field-load vs getter, so a later-declared producer works. *(5.1.3)*
- **`let x: some I = <another opaque>`** — an opaque binding/return may look through another opaque of a known underlying. *(5.1.3)*

**Still open here:**
- **Per-function opaque identity is a caveat, not a gap:** distinct owners give distinct types (`==`), but the only checker that would observe it is general assignment type-checking — a **pre-existing no-op** tracked in **5.0.7**. Enforcement comes for free once that lands.
- **Composition existential upcast** (`any A & B` → `any A`, or → a composition) — the single-interface upcast above shipped; the composite-witness case is still deferred.

**Owned by later phases (tracked there; listed for cross-reference):**
- **Parameter-position `some`** (`fun f(x: some I)`) → **5.2** — the `<T: I>` sugar; no separate mechanism.
- **Covariant-`Self` existential erasure** → **5.6** — a scheduled phase, fully specified there; the 5.1.2 blanket constraint-only rule is its baseline.

**Parked past M5 (design question):**
- **Actor conformance** — `interfaces.md` §1: a sync `fun` requirement over actor message-send/isolation is a real design question and depends on actor instance methods (which don't exist yet). Currently rejected with a located error.

---

*The phased build plan (**5.1–5.6**). Phases are ordered by dependency; each has an exit criterion expressed as programs that compile and run.*

## 5.1 · Interfaces + computed properties + `some` ✅

The prerequisite feature; everything else builds on witness tables. Split into three coherent sub-parts.

### 5.1.1 · interface core ✅
- Parse/typecheck `interface I { … }`: method requirements, property requirements (`var x: T { get }` / `{ get set }`), overridable defaults.
- Computed properties + get/set accessors as a language feature on **all three type kinds — struct, enum, and class** (resolved 2026-07-25, matching Swift: only *stored* properties are struct/class-only; enums get computed properties, typically a `get` over `match self`). Stored fields auto-synthesize trivial accessors; the get/set lowering is one method pair regardless of kind, and stored-field auto-synthesis is already handled per-kind (M4.9 methods, M4.10 `let`/`var` fields, M4.11 mutating value-type receivers). Mutating setters on value types. **Accessor spelling** (`generics.md` §3a): `var area: Int { get { … } set(v) { … } }`; a bare body is an implicit read-only get; the setter binds its incoming value explicitly as `set(name)` (not Swift's implicit `newValue`).
- Conformance: `extension T: I { … }` (extends M4.12's plain extension with a conformance clause + witness generation) and `struct T: I { … }` sugar. Witness-table generation (accessor-shaped property slots — never offsets — plus method slots; reserve an unused type-witness slot for future associated types).
- Refinement `B: A` (requirement aggregation + subtype edge; most-specific default wins, incomparable sibling defaults **cancel → mandatory**, `interfaces.md` §4.3); `&` composition.

### 5.1.2 · `Self`-type requirements + existential legality ✅
- Allow `Self` in requirement signatures (`fun clone() -> Self`, `fun combined(with: Self) -> Self`). In a generic body `<T: I>` and behind `some I`, `Self` binds to the one known/hidden concrete type, so witness calls are well-typed.
- **Existential restriction (interim, tightened in 5.6):** an interface that mentions `Self` anywhere in a requirement is **constraint-only** — legal as a generic bound and as `some I`, **rejected as `any I`** with a local error (a heterogeneous box can't guarantee two `Self`s are the same type). This blanket rule is the sound baseline; **5.6** relaxes it to a position-sensitive one so covariant-`Self` interfaces regain `any I`.
- The check is a property of the interface computed at declaration; refinement propagates it (`B: A` is constraint-only if `A` is).

### 5.1.3 · `some I` opaque types ✅
- Parse/typecheck `some I` in **return position** (`fun makeShape() -> some Drawable`). Parameter-position `some` (anonymous-generic sugar for `<T: I>`) is **deferred** — 5.2's `<T: I>` already covers it (decision below).
- **One underlying type:** every `return` in the body must yield the *same* concrete type; the caller sees an opaque type with identity that conforms to `I` but whose concrete identity is hidden.
- **Lowering — no box, static dispatch.** The concrete type is fixed and compiler-known (only *hidden from the caller*), so requirement calls on a `some I` value devirtualize to direct calls / field loads — mono-independent static dispatch (`generics.md` §1, the reason `some` is core rather than deferred). Contrast `any I`, which boxes and dispatches through the witness.
- **Decisions taken while building (2026-07-26):**
  - **Scope broadened past return-position-only:** also accepts `let`/`var: some I` **local binding annotations** (each binding gets its own opaque identity, underlying = the initializer's concrete type) and **`some A & B` composition** (structural over declared conformances, like `any A & B`). Parameter-position `some` stays deferred to `<T: I>`.
  - **Per-function opaque identity (Swift-style):** the opaque type carries an `owner` key (`fn:name`, `m:Type.method`, or `let:N`), so two functions returning `some D` are **distinct types** even with the same underlying. Represented via `Type.opaque(interfaces:, owner:)`; the owner→underlying map rides on `IRModule.opaqueUnderlyings` for codegen. (Enforcement of the distinction only bites once general assignment type-checking lands; the plain-assign path is a pre-existing no-op — see 5.0.8.)
  - **`-> Self` on a `some I` value yields the concrete underlying** (not a re-wrapped opaque): `x.clone()` on `some Cloneable` gives the concrete type back — enables chaining; a minor opacity leak that is sound within the single compilation unit. Constraint-only (`Self`-mentioning) interfaces are usable as `some I` (they're rejected only as `any I`), verified against a conformance-fact table (`allConformsTo`) that records every checked conformance including the witness-less constraint-only ones.
  - **Limit noted:** a requirement call / property read on an opaque value whose underlying isn't resolved yet (a forward reference to a later-declared producer) — method calls still work (codegen resolves the underlying post-Sema); a `some`-property *read* needs the underlying known at check time (to pick field-load vs getter) and otherwise emits a clear "declare the producer earlier" error.

**Dispatch (all of A):** call-site property — direct/devirtualized on a concrete receiver and on `some I`; witness lookup through `any I`.

**Exit:**
- An `interface Drawable` with a default method and a `{ get }` property; two concrete conformers; individual `any Drawable` values dispatched dynamically; a stored-backed `get` verified to lower to a field load on a concrete call. (A collection of `[any Drawable]` iterated in a loop is the natural demo but assumes loops + a collection type the language lacks — dispatch on individual `any Drawable` values instead, or pull minimal iteration forward; the interface feature needs neither.)
- A `fun makeShape() -> some Drawable` returns a hidden concrete type; the caller calls a requirement on it and the emitted C shows a **direct call, no witness indirection**; a body returning two different concrete types is a clean local error.
- An interface with a `Self` requirement is usable as `some I` / a generic bound and **rejected** as `any I` with a clear message.

## 5.2 · Generic parameters + constraints ✅
- Parse/typecheck `<T: I>`, `<T: I & J>` on `fun` and on types (`struct Box<T>`).
- **Subsumes parameter-position `some`** (`fun f(x: some I)`) — anonymous-generic sugar for `<T: I>`, deferred here from 5.1.3; no separate mechanism.
- **Representation — Swift route (Decided 2026-07-27).** Witness-passing baseline: a generic body receives a **value witness** (size + copy/move/destroy, ARC-aware) for each type parameter and a **protocol witness** for each bound, and works unspecialized over any `T`. Generic values are held uniformly (boxed / by reference), so a generic type's layout is fixed regardless of `T`. Monomorphization (specialization to concrete copies, Rust-style) stays a **later, optional** optimization (5.4) — nothing in 5.2 depends on it. **Scope note (2026-07-27):** the *value-witness* half of this baseline is **not built in M5** — its only live use is ARC copy/destroy, which LXR GC (M6) replaces, so 5.2.3 holds generic values boxed and **leaks** reference payloads until the GC reclaims them; the value witness returns in M6 as runtime-reachable **trace** metadata (guardrail 2 below). Only the *protocol* witness ships in 5.2. Rust-style mono was weighed (simpler C output in a single CU, zero-cost value generics) but declined to keep specialization optional and the future ABI / GC-precision doors open.
- Slices: **5.2.1 ✅ built** — parse + type model; **5.2.2 ✅ built** — generic functions + bounds + witness-passing + arg inference; **5.2.3 ✅ built** generic types (`Box<T>` fixture, `enum Option<T>`) — uniform boxed layout, **no value witnesses** (deferred to M6/LXR, see below); plus generic higher-order functions (`map<T,U>` over closures) via reabstraction thunk; **5.2.4 ✅ built** prelude citizen `Option<T>` in `src/stdlib/core.nomu` (`Result<T,E>` lands in 5.5). `Box<T>` is a compiler test fixture (single-field generic *struct* path), not a stdlib citizen.
  - **5.2.1 (2026-07-27):** `<T>` / `<T: I & J>` parameter lists on `fun`/`struct`/`enum`/`class`; `Box<Int>` generic arguments in type position (angle brackets unambiguous per 5.0.6, `>>` closes as two `>`). `Type.typeParam` / `Type.generic(base:, args:)`; a bound must name an interface; arity-checked application. Generic *types* parse + resolve signatures but emit no IR (deferred to 5.2.3).
  - **5.2.2 (2026-07-27):** generic **functions** lowered by **witness-passing** (`examples/generics.nomu`). A `fun describe<T: Drawable>(x: T)` compiles once to `describe(void* x, const Drawable_witness* wt_T_Drawable)`; a requirement call on a `.typeParam` receiver dispatches through the witness param (`wt_T_Drawable->draw(x)`). Call sites **infer** type arguments from the arguments (shallow unification, conflict-checked), verify each inferred type conforms to the bounds (a witness must exist), then box value args (a pointer; value types copied via `rt_alloc`) and append the witness instances. `-> T` return reads the `void*` back as the inferred concrete type. **Value witnesses (size/copy/destroy) not needed yet** — a function passes `T` by pointer and calls through it; they arrive with generic *types* in 5.2.3. **Deferred:** a **constraint-only bound** (`<T: Cloneable>`) needs a `Self`-carrying witness — rejected with a clear message for now; nested type-argument inference (`f(Box<Int>)`).
  - **5.2.3 (decisions locked 2026-07-27) — generic types.** Calls made to unblock implementation:
    - **C representation — one shape, compiled once.** A generic type lowers to a single C struct/enum per base (`nomu_main_Box`), regardless of `T`. A `T`-typed field is `void*` (uniform), **boxed on the heap at construction**, where the concrete `T` is statically known (`rt_alloc(sizeof(T))` at the call site). `cType(.generic(base, args))` resolves to the base's C type (value struct/enum by value; class by pointer) — replaces today's `preconditionFailure` trap at `CodegenIR.swift` `cType(.generic)`.
    - **Type identity / mangling.** Sema keeps `Box<Int>` and `Box<String>` distinct (`.generic` equality already includes args). Codegen mangles to the **base name only** (one body); angle-bracket/arg mangling arrives with monomorphization (5.4), matching the reserved note in `Mangle.swift`.
    - **Generic enum construction + match.** A payload `T` is held as `void*`, boxed at `.some(x)`; `.none` carries the tag only. A `match` arm reads the payload back to its concrete type at the site (the same read-back as 5.2.2's `-> T` return). Exhaustiveness is checked on the generic definition; instantiation adds no cases.
    - **No value witness in 5.2.3 (decided with Ethan — avoid throwaway work).** Under always-box + shallow copy, `size` is known at construction and copy is a pointer copy; the only remaining witness use is `destroy` = ARC retain/release, which **LXR GC (M6) replaces** — so building it now is throwaway. Generic-held references **leak** in 5.2.3; LXR GC reclaims them in M6, where the value witness returns as runtime-reachable **trace** metadata (`generics.md` guardrail 2, line 17), not as ARC ops. The exit examples (`Option`/`Box`/`map`) have immutable (`let`) payloads, so shallow sharing is sound. This resolves the earlier "store-in-instance vs thread-as-param" question by removing the witness from this slice entirely.
    - **Built 2026-07-27 — green.** `bazel test //...` passes; `examples/generic-types.nomu` compiles + runs (`Box<Int>`/`Box<String>` construction + field read, `Option<Int>`/`Option<String>` `.some`/`.none` construction + `switch`). Bound violations on generic construction are a clean local error. IR seams landed as planned (`generics` on `IRStruct`/`IREnum`/`IRClass`; `lowerGenericDecl`; `cType(.generic)`; box at construction / unbox at field-read + match). `boxGenericValue`/read-back were generalized to primitives (`Int`/`Bool`/`String`) — the 5.2.2 path only exercised struct type args.
    - **Reabstraction thunk — built (closes the `map`-over-closures exit).** A generic function with a closure parameter mentioning a type parameter (`fun map<T,U>(x: T, f: (T) -> U) -> U`) is bridged by a **box/unbox thunk generated at the call site** (`CodegenIR.emitReabstraction`), where the type arguments are concrete. The generic body invokes the closure through a boxed ABI (a `T` position is `void*`); the thunk presents that ABI, unboxes each `T`-position argument to its concrete type, calls the real closure, and boxes a `T`-position result. A concrete position (e.g. `-> Int`) passes through. `unify` destructures `.function`/`.generic` params so inference resolves `T`/`U`. Verified over one/two-arg closures, `Int`/`String` type args, and concrete returns (`examples/generic-hof.nomu`).
    - **Review hardening (2026-07-27).** Closing review of 5.2.3 found and fixed: (1) a **binding/return/assignment annotation mismatch was unchecked** — for generics it passed *silently* (all instantiations share one C layout), for scalars/structs it leaked a C-compiler error; now `Sema.checkAssignable` reports `Box<Int>`↛`Box<String>`, `Int`↛`String`, etc. as clean local errors. (2) **Mutable `T` fields** (`struct Cell<T> { var value: T }`) — the assign path didn't resolve a generic field's type (`fieldType` now handles `.generic`), `let`-field rejection covers generic bases, and codegen **re-boxes the slot on write** (works for value and reference `T`; old box leaks → M6 GC). (3) A **double-box** when a generic type is built over an abstract `T` inside a generic body (`fun wrap<T>(x: T) -> Box<T>`) printed garbage — `boxGenericValue` now passes a `.typeParam` value (already a `void*` box) through instead of re-boxing. **Return-position** generic construction (`-> Box<T>` / `-> Option<T>`) is sound and tested.
    - **Deferred:** a type parameter **nested in a generic-type *parameter*** (`fun f(o: Option<T>)`, `map<T,U>(o: Option<T>, …)`) — the body destructures/rebuilds an abstract container, which segfaults/misinfers without a value witness; **rejected with a clean error** (`typeParamUnderGeneric` in Sema) rather than miscompiled. (Return position is fine — it only moves a boxed value out.) Also (unchanged from 5.2.2): constraint-only bounds (need a `Self`-witness), generic-type instance methods / computed properties (rejected), monomorphization (5.4).
    - **Seams touched (actual).** `IR.swift` — `generics: [IRGenericParam]` added to `IRStruct`/`IREnum`/`IRClass` (parallel to `IRFunc`). `Sema.swift` — `checkGenericType` → `lowerGenericDecl` (emits IR); `checkGenericConstruct` / `buildGenericEnumInit` / `genericMemberType`; `unify` destructures `.function`/`.generic`; `checkAssignable` (binding/return/assign); `fieldType` + `rejectLetFieldTarget` handle `.generic`; `typeParamUnderGeneric` guard. `CodegenIR.swift` — `cType(.generic)`; `box`/`unbox`/`rawMemberAccess`; construction/enum/match/field-write boxing; `emitReabstraction`. `Mutation.swift` — carry `generics` through the mutating-inference rebuild (a generic type decl would otherwise lose its type parameters after this pass). `Exhaustiveness.swift` — `.generic` enum subjects. **`Mangle.swift` needed no change** — base-only mangling fell out, since `cType(.generic)` calls `Mangle.type(base)` and the type arguments never reach the mangler (the planned "`Mangle.type` seam" was a no-op). Reinstall `bin/nomuc` after compiler changes.
  - **5.2.4 ✅ built (2026-07-27) — prelude citizen `Option<T>`.** Put `Option<T>` in the prelude so it's usable with no definition. **Prerequisite met:** the prelude mechanism shipped in M4.13 — `src/stdlib/core.nomu` is embedded into `nomuc` (runtime genrule → `EmbeddedSources.preludeSource`) and `Driver.prependPrelude` prepends its decls to every program; it already carries `abs`/`max`/`min`, and its own comment reserves the generic citizens for M5. **Shape:** `enum Option<T> { case some(value: T)  case none }` — payloads must be labelled (unlabelled `case some(T)` doesn't parse; no syntax change without agreement), so the API is `Option.some(value: x)` / `.some(value: x)` and `case .some(let v)`. **Collision:** examples that define their own `Option<T>` (only `examples/generic-types.nomu`) drop the local definition once it's a prelude citizen; the sema-test helper doesn't prepend the prelude, so inline `Option` in unit tests is unaffected. **Usable within 5.2.3 limits:** construct/match at concrete sites and return `Option<T>` from a generic function; *taking* `Option<T>` as a generic parameter stays rejected (needs value witnesses). `Result<T,E>` is **not** here — it lands in 5.5 (5.5). **Exit:** a program uses `Option<T>` (construct + `switch`) with no local definition and no import. **Built + green:** `enum Option<T>` added to `src/stdlib/core.nomu`; `examples/generic-types.nomu` dropped its local copy; `examples/stdlib.nomu` uses the prelude `Option`. Full suite + all 23 examples pass (the prelude is prepended to every program, so this is exercised everywhere).
- **Modular checking** against declared bounds (the locked invariant — bodies checked once against what the bound promises).
- Type-argument inference (bidirectional: from arguments and return position). No explicit call-site type args (Swift model, 5.0.6); where inference can't resolve `T`, the caller supplies type context (an annotation), not a `f<Int>(…)` form.
- Lowering: **witness-passing** (dictionary) — the correctness baseline; a generic body receives witness tables for its bounds. Reuses the exact `any` conformance representation.
- Exhaustiveness under generics — checked on the generic enum definition; instantiation adds no cases.
- **Exit:** `Option<T>`, `Box<T>`, a generic `fun map<T, U>(…)` over closures, and `fun describe<T: Drawable>(x: T)` all compile and run; a bound violation is a clean local error.

## 5.3 · `shared` bound + conditional conformance ✅
Completes the M3 shareability rule under generics, then adds the `shared` surface modifier. Depends on 5.2 (generic types + witness-passing). Shipped as two slices: the structural checker (5.3.1, delivers all three exit criteria) then the `<shared T>` bound (5.3.2). The remaining `shared` type-spellings (5.3.3) are **deferred** — no M5 consumer (see below).

**Decided (2026-07-28):** **`String` is shareable** — an immutable value; deeply-immutable classes may hold `String` fields and a bare string crosses a task boundary. (Matches the "immutable ⇒ shareable" principle; M3 conservatively excluded it.)

### 5.3.1 · structural shareability + conditional conformance ✅
- Auto-derived structurally, no annotation (`concurrency.md` §5). Conditional conformance (`Box<T>` shareable iff `T` is) is the same structural mechanism.
- Complete the M3 checker: deeply-immutable classes (every field `let`, recursively, and itself shareable) become shareable — the case M3 rejected.

**5.3.1 (2026-07-28):** The share-analysis predicate (`CodegenIR.isShareable`, consulted by the `spawn`-capture check) was **shallow** — structs/enums/actors unconditionally shareable, classes/strings/`.generic` never — and is now **structural + recursive**:
- primitives, **`String`** (now shareable), and actor handles are always shareable;
- a **struct / enum** is shareable iff every stored field (across all enum cases) is — tightened from "always" (a struct holding a non-shareable field is now correctly rejected);
- a **class** is shareable only when **deeply immutable**: no `var` field (`IRField.isMutable`, pre-added in 5.2 for this) and every field shareable;
- a **generic instance** `Box<T>` substitutes the base decl's type params → args (`substitute`), then checks the base's fields — **conditional conformance**, so `Box<Int>` is shareable and `Box<Counter>` is not.
- A `visiting` set (keyed by type name / generic description) breaks cycles on recursive types (a back-edge is assumed shareable; the decision falls to the other fields).
- **Kept in codegen** (the existing `spawn` seam, smallest diff). **5.3.2 note:** the `shared`-bound check at generic call sites needs this predicate in **Sema**; factor a shared `Shareability` helper in the frontend module then and have codegen delegate.
- **Seam touched:** `CodegenIR.swift` — `isShareable(_:visiting:)` rewritten; `genericShareable` / `fieldsShareable` / `casesShareable` / `substitute` added. No IR/Sema/parser change. Example: `examples/shared-bound.nomu` (`Box<Int>` + deeply-immutable `Config` cross a boundary; the commented block shows `Box<Counter>` rejected). `bazel test //...` green; all 26 examples compile.
- **Deferred to 5.3.2:** a bare `.typeParam` `T` is not known shareable (→ rejected) until a `<shared T>` bound records the capability.

### 5.3.2 · the `<shared T>` bound ✅
- Parse the `shared` prefix on a generic parameter (`<shared T>`, `<shared T: I>`); Sema discharges the bound at call sites (the inferred type argument must be shareable); inside the body a `shared T` counts as shareable so it can forward across a task boundary.

**5.3.2 (2026-07-28):** The primary `shared` mechanism — a bound on a type parameter (concurrency.md §5: shareability "surfaces only as a bound on the concurrency APIs"). `shared` is a **contextual prefix** (no lexer keyword — matches how `any`/`some` are actually implemented, contra the "add to keyword set" note in `generics.md` §3a; the reserved word isn't needed since the position is unambiguous).
- **Shared predicate factored out.** 5.3.1's structural check moved to a frontend `Shareability` helper (`src/frontend/sources/Shareability.swift`) that takes a `lookup: (String) -> Decl?`; **Sema** builds it from AST decls (fields resolved under each decl's own generic scope) and **codegen** from IR decls, so the two consumers share one algorithm. Codegen's 5.3.1 duplicate (`genericShareable`/`fieldsShareable`/`casesShareable`/`substitute`) was deleted.
- **Discharge at call sites** (`Sema.checkGenericCall`): after bound-conformance, a `shared` param whose inferred arg isn't shareable is a clean local error (`type 'X' is not shareable, but type parameter 'T' of 'f' is declared 'shared'`).
- **In-body shareability:** a bare `.typeParam` `T` is shareable iff `T` is a `<shared T>` param in scope — tracked by `Sema.sharedParams` (call sites) and `IRGenericParam.isShared` consumed by codegen's `isShareable` (the `spawn`-capture check), so a `shared T` value crosses a `spawn` inside the body and satisfies a further `shared` bound.
- **Seams touched:** `AST.GenericParam.isShared` + parser; `IR.IRGenericParam.isShared` + both Sema build sites; `Sema` — `Shareability` table (`buildShareChecker`/`resolveFields`), `isShareable`, `sharedParams`, discharge in `checkGenericCall`; `CodegenIR` — `shareChecker` built in init, `isShareable` delegates + honors `shared` typeParam. Example `examples/shared-param.nomu`; five `SemaTests` (accept Int/immutable-class/struct, reject non-shareable arg, forward shared→shared, reject plain-`T`→shared). `bazel test //...` green; all 27 examples compile.
- **Discovered pre-existing limit (not 5.3.2):** forwarding a bare type-parameter value as an argument to *another* generic function (`fun outer<T>(x:T){ inner(x) }`) **segfaults at runtime** — a 5.2.2/5.2.3 boxing gap (passing `.typeParam` as a generic call arg), independent of `shared` (reproduces with plain `<T>`). The `shared`-bound *check* is correct regardless; the example avoids the shape. Should become a clean error or be fixed alongside the 5.2.3 `typeParamUnderGeneric` family — parked here.

### 5.3.3 · `shared` on function-type / existential spellings ⬜ deferred (no M5 consumer)
**Deferred — Decided (2026-07-28).** The explicit `shared (A) -> B` and `shared any I` spellings (`generics.md` §3a) have **no M5 consumer** — shareability is auto-derived structurally (5.3.1), and the explicit marker is only needed on a closure/generic parameter forwarded to a task across a **hidden body** (interface requirements, later modules), which M5 doesn't exercise. The `<shared T>` bound (5.3.2) already covers the annotation the concurrency APIs need. Full record — why, the un-park trigger, how to build it, and the inference alternative — in **`design/deferred.md`**.

**Exit (5.3):** sending a `Box<Int>` across a task boundary type-checks; sending a `Box<SomeClass>` (non-shareable) is rejected with a local error; a deeply-immutable class is accepted where M3 rejected it. *(5.3.1 — met, `examples/shared-bound.nomu`.)* The `<shared T>` bound accepts/rejects type arguments by shareability. *(5.3.2 — met, `examples/shared-param.nomu`.)*

## 5.4 · Monomorphization ✅

**Decided (2026-07-30, with Ethan) — whole-program mono, on in all cases.** Nomu takes the **Swift route** (witness baseline + mono as accelerator, stable-ABI-capable), *not* Rust's always-mono. But under today's **single compilation unit** there is **no ABI boundary to preserve**, so specializing every generic instantiation is exactly Swift's whole-module optimization (WMO) — pure upside, no cost. So mono runs **everywhere** now; the policy is **revisited when multi-file/module builds land** (scope to within-module; cross-module specialization becomes opt-in per the `@inlinable` analog, preserving the stable-ABI default at module edges). Beyond speed, whole-program mono also **removes the 5.2.3 box-and-leak** (a specialized `Box<Int>` stores a real `Int`, no `void*`, nothing to leak), **lifts the value-witness restrictions** (`typeParamUnderGeneric` — specialized code is fully concrete), and **fixes the generic→generic runtime segfault** noted in 5.3.2 (an unspecialized `.typeParam`-as-arg boxing bug). `some`/concrete stay the *guaranteed* static-dispatch levers (`generics.md` §1); mono makes `<T: I>` fast **by default** so users needn't reach for them.

**Architecture — an IR→IR pass (`Monomorphize`), after Sema/exhaustiveness, before codegen.** Confirmed against the code: codegen's witness-dispatch (`wt_T_I->slot`), generic-value boxing, and one-shape `.generic` struct emission **all branch on a type being `.typeParam`/`.generic`**; the `.typeParam` requirement-call branch (`CodegenIR` ~779) simply isn't taken once the receiver is concrete. So the pass **substitutes type parameters → concrete types and clones generic decls**, producing a **fully-concrete `IRModule`** (no `.typeParam`, no `.generic`, no witness params in specialized decls); codegen then emits direct calls / inline fields / no boxing through its **existing** concrete paths — devirtualization and unboxing fall out of the substitution, not from new codegen. **`any I` is untouched** (inherently dynamic — the explicit erasure opt-in; its witness tables stay). Nothing depends on this pass for correctness (`generics.md` §1, goal 3); it stays layered on the witness baseline so the module-time policy change is localized.

### Slices
- **5.4.1 ✅ — pass + generic functions.** `Monomorphize` walks from roots (non-generic funcs, `main`), collects generic call instantiations (`.call` `typeArgs`) to a worklist/fixpoint, clones each `(func, typeArgs)` with typeParam→concrete substitution, `generics: []`, a specialized name; rewrites call sites to the specialized symbol with empty `typeArgs`. Devirtualization falls out (concrete receiver → codegen's direct-call branch). Polymorphic-recursion termination via a nesting-depth cap → clean error.
- **5.4.2 ✅ — generic types.** Specialize `Box<T>` / `Option<T>` etc.: one concrete struct/enum per instantiation (`.generic(base,args)` → a fresh `.named` decl with concrete fields, no `void*`); construction / field access / enum init+match rewritten. `Mangle` encodes the type-argument brackets (`<`→`92`, `>`→`93`, `,`→`94`) so instances get distinct C symbols.

**5.4 (2026-07-30) — built + green.** Built as a single IR→IR pass `src/frontend/sources/Monomorphize.swift` (final-class, worklist to fixpoint), wired into `Driver` between exhaustiveness and codegen. **Zero codegen changes** — the pass produces a fully-concrete `IRModule` and codegen's existing paths do the rest:
- **Functions:** a generic call `describe(Circle(…))` rewrites to `.call(varRef("describe<Circle>"), …, typeArgs: [])`; the cloned `describe<Circle>` has `generics: []`, so codegen takes the plain-call path (no witness args) and the requirement call `x.draw()` — now a `.methodCall` with a **concrete** receiver — skips codegen's `.typeParam` witness branch and emits a **direct** `nomu_main_Circle_draw(...)`. Verified: `examples/generics.nomu` emits `describe<Circle>`/`describe<Square>` with **0** `wt_` indirection.
- **Types:** `Box<Int>` / `Box<String>` / `Option<Int>` / `Option<String>` become distinct C structs/enums with **real fields** (`int64_t value;`), no `void*` — so the **5.2.3 box-and-leak is gone** (`examples/generic-types.nomu`, `void*` count drops to the lone `AnyBox` typedef).
- **Naming:** specialized IR decl name is `base<argKey,…>` (`typeKey` gives a mangling-safe key; function/existential args render `fn<…>`/`any_I`); `Mangle.encode` turns the brackets into digit codes.
- **Restriction lifted:** the 5.2.3 `typeParamUnderGeneric` guard (a `Option<T>` *parameter*) is **removed** — mono specializes the abstract body to concrete before codegen, so it's sound; inference *through* the container stays shallow (a `.none` arg can't pin `T` → the ordinary "cannot infer" error). `SemaTests.testGenericTypeParameterUnderGenericAccepted` flipped from reject to accept.
- **Fixes the 5.3.2 segfault:** generic→generic forwarding (`outer<T>{ inner(x) }`) now specializes to concrete and runs (was an unspecialized `.typeParam`-as-arg boxing bug).
- **Guardrail held:** `any I` is untouched — `examples/interfaces.nomu` / `upcast.nomu` still box + dispatch through witnesses.
- **Polymorphic recursion:** `f<T>{ f(Box(value: x)) }` → depth-cap → clean local error, no hang.
- **Deferred:** nested type-argument *inference* (pin `T` through an `Option<T>` arg without an annotation) — unchanged from 5.2.3; monomorphization doesn't help inference. When multi-file/module builds land, rescope the "specialize everything" policy to within-module (cross-module opt-in) — see `design/deferred.md`.
- **Seams:** `Monomorphize.swift` (new); `Driver.swift` (+mono call); `Mangle.swift` (+`<>,` codes); `Sema.swift` (drop `typeParamUnderGeneric` call-site guard). Codegen tests `testMonoDevirtualizesRequirementCall` / `testMonoUnboxesGenericType` (a `genMono` helper runs the pass). `bazel test //...` green; all examples compile (except the pre-existing loops file).

**Exit — met:** a specialized `Box<Int>` shows no witness indirection and no `void*` boxing; `describe<T: Drawable>` devirtualizes to a direct call; the 5.3.2 generic→generic case runs; polymorphic recursion is a clean local error; `any I` still dispatches through the witness.

## 5.5 · Error handling ⬜

## 5.5 · Error handling ✅
- `Result<T, E>` as a generic enum in the stdlib — a `stdlib/*.nomu` prelude citizen (the mechanism ships in M4.13; depends on 5.2 generic enums).
- Explicit `match` handling; no `?` operator, no typed throws (deferred).

**5.5 (2026-07-30) — built + green.** The generic-enum machinery (5.2 + 5.4 mono) already handled a **two-type-parameter** enum end-to-end, so this was pure library work: added `enum Result<T, E> { case ok(value: T)  case err(error: E) }` to `src/stdlib/core.nomu` (the second generic prelude citizen after `Option`). **Case names decided (2026-07-30):** `ok`/`err` with labelled payloads `value:`/`error:` — matches `Option`'s short-name style; unlabelled payloads don't parse (no syntax change). Easy to rename to `success`/`failure` if preferred — it's library API, not surface syntax. Error handling is explicit `switch` over `.ok`/`.err`; no `?` operator, no typed throws (deferred, `generics.md` §2). The template is generic, so mono **drops it** for programs that don't use it (prepended to every program, instantiated only on use). **Exit — met:** `examples/result.nomu` — a failable `divide(a, b) -> Result<Int, String>` returns `.ok`/`.err` with no local definition or import, and `main` handles both via `switch` (prints `5`, `divide by zero`). Full suite + all 28 examples green.

**Exit:** a failable function returns `Result`, and a caller handles both cases via `match`.

## 5.6 · Covariant-`Self` existential erasure (closing item) ⬜
Sequenced last in M5; relaxes 5.1.2's blanket constraint-only rule. Depends only on 5.1 (existentials + `Self`-requirements), not on 5.2–5.5, but scheduled after them as the closing M5 item.
- **Position analysis on `Self`.** Classify each `Self` occurrence in a requirement as **covariant** (return position) or **contravariant/invariant** (parameter position; a `Self`-typed `{ get set }` property; `Self` nested under a mutable/`&`-composed slot).
- **Refined existential rule.** An interface whose `Self` occurrences are **all covariant** becomes usable as `any I` again: a `-> Self` requirement **erases to `-> any I`** at the existential boundary (the box hands back another existential, which is sound — the caller never asserts two boxes share a concrete type). An interface with any contravariant/invariant `Self` stays **constraint-only** (the 5.1.2 rule).
- **Lowering.** Through `any I`, a covariant-`Self` requirement's witness returns the concrete `Self`, re-boxed as `any I` at the call boundary; concrete and `some I` sites are unaffected (they already know the type).
- **Exit:** `interface Cloneable { fun clone() -> Self }` is usable as `any Cloneable` and `c.clone()` yields an `any Cloneable`; `interface Combinable { fun combined(with: Self) -> Self }` (contravariant `Self`) remains rejected as `any I` with the 5.1.2 message; both stay usable as `<T: I>` / `some I`.
