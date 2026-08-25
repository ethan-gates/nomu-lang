# Generics

**Status:** authoritative spec — generics as built through **M5**. This documents the *implemented* language: surface syntax, inference and its limits, checking, lowering (witness-passing + monomorphization), generic types, the `shared` bound + conditional conformance, exhaustiveness, and `Result`. Read this instead of the compiler. Interface *mechanics* (conformance, witness tables, dispatch, `some`/`any`, `Self`-requirements, computed properties) live in `interfaces.md`; the concurrency angle of `shared` lives in `concurrency.md` §5. Design rationale and rejected alternatives are collected at the end (§12); the deferred surface is §10.

Scope note: everything below is committed and compiles today unless marked **Deferred**. Historical decision dates are kept as provenance.

---

## 1. Model

- **Generic parameters** appear on `fun`, `struct`, `enum`, and `class`. A parameter may carry interface **bounds** (`<T: I>`). A body is written once against `T` and works for every type argument.
- **Invariant.** A generic type is neither co- nor contravariant in its parameters: even when `B` refines `A`, `Box<B>` is unrelated to `Box<A>` (no subtype edge lifts through a parameter). Sound by default and avoids variance inference; copies Swift/Rust. — Decided (2026-07-19).
- **Two-layer lowering.** *Witness-passing* (dictionary) is the semantic baseline: a generic body receives a **protocol witness** for each bound and dispatches requirement calls through it. **Monomorphization** is a specialization pass layered on top — and under the current single compilation unit it runs on **everything** (§6). So in practice all generic code is specialized to concrete copies; the witness path is the meaning it specializes *from*, and the fallback the model preserves for the future.
- **Static dispatch is a type-system property, not a monomorphization result.** — Decided (2026-07-20). A call resolves statically wherever the concrete type is known. **Concrete types** and **`some I`** guarantee static dispatch with zero dependence on specialization; `any I` is always dynamic; `<T: I>` is static exactly when specialized (today: always, since mono is whole-program). Because specialization could be re-scoped later (§6), authors reach for a concrete type or `some I` when they want the guarantee. `some` is therefore a core language lever, not a nicety (`interfaces.md`).

---

## 2. Surface syntax

- **Parameters + bounds — angle brackets, inline `:`.** `fun max<T: Comparable>(a: T, b: T) -> T`, `struct Box<T> { let value: T }`, `enum Option<T> { … }`. Composed bounds reuse `&`: `<T: Drawable & Shape>`. A bound must name an interface (else a clean error). Arity is checked at every application (`Box<Int>` with the wrong count is an error). — Decided (2026-07-20).
- **Applied generic types** appear in type position: `let b: Box<Int>`, `fun f(o: Option<Int>)`, `-> Result<Int, String>`. `>>` closes two parameter lists (`Box<Box<Int>>`).
- **`<` / `>` disambiguation — Swift model with speculative parse.** — Revised (2026-08-07; supersedes the 2026-07-25 "always comparison in expression position" rule). Angle brackets are generic in **declaration** position (`fun f<T>`, `struct Box<T>`), **type** position (`let b: Box<Int>`), and now in **construction** position (`Box<Int>(...)`, `Option<Int>.some(...)`). The parser, on seeing `Name<` in expression position, speculatively parses a type-argument list and commits **only** if it is well-formed and the closing `>` is immediately followed by `(` or `.` — otherwise it backtracks and `<` is the comparison operator. This is Swift's mechanism (a `canParseAsGenericArgumentList` backtrack keyed on the token after `>`). The one cost: a chained relational like `a < b > (c)` now reads as a generic application and must be parenthesized (`(a < b) > (c)`). Parser: `tryParseTypeArgs`.
- **No call-site type arguments on functions.** Explicit type arguments are a *construction* form only (generic struct/class/enum). `f<Int>(x)` for a generic **function** call still does not exist — function type parameters are inferred (§3). A `Name<Args>` where `Name` is not a generic type is a clean error.
- **Construction is inference-based, with explicit arguments as an option.** The type normally comes from the arguments and/or context: `Box(value: 3)` (a `Box<Int>`), `let s: Box<String> = Box(value: "hi")`, `Option.some(value: x)` / `.some(value: x)`. Explicit type arguments may also be written at the construction site — `Box<Int>(value: 3)`, `Option<Int>.some(value: 3)`, `Option<Int>.none` — and seed inference (the payload/fields are then unified against them, so a mismatch is a conflict error). This is the way to construct a payload-less case at a specific type without an annotation: `Option<Int>.none`.
- **`shared` bound — prefix modifier.** `fun send<shared T>(x: T)`, `<shared T: Comparable>` (capability prefix, interface bound after `:`). Contextual (like `any`/`some`), no reserved keyword needed. Requires the type argument to be shareable (§7). The *closure/existential* `shared` spellings (`shared (A)->B`, `shared any I`) are **Deferred** (§10). — Decided (2026-07-20).

---

## 3. Type-argument inference

Inference is **bidirectional** — from argument types and from return/context. Where inference can't resolve a parameter, the caller supplies **type context** (an annotation) or, at a construction site, **explicit type arguments** (`Box<Int>(...)`, `Option<Int>.none`; §2). Generic *function* calls have no explicit form — their parameters are always inferred.

- **From arguments.** A call to `fun describe<T: Drawable>(x: T)` infers `T` from the argument's type. Unification is **shallow but structural**: it destructures function types (`(T) -> U`) and applied generics (`Option<T>`) to bind nested parameters, and conflicts across arguments are a clean error (`conflicting types inferred for 'T'`).
- **From return / context.** Construction and return position infer from the expected type (`let b: Box<Int> = Box(value: 3)`; a function returning `-> Box<T>` in a specialized body).
- **Bounds are discharged after inference.** Each inferred type argument is checked to satisfy its parameter's bounds; a violation is a clean error (`type 'X' does not conform to 'I', required by type parameter 'T' of 'f'`).

**Inference limits (accurate today):**
- Inference through a container argument that does not *pin* the parameter is not done — e.g. `firstOr(Option.none, 0)` cannot infer `T` from a payload-less `.none`, and reports the ordinary `cannot infer type parameter 'T'`. Supply context: `let o: Option<Int> = .none; firstOr(o, 0)`. (Deeper nested-container inference is **Deferred**, §10.)
- Inference is over arguments + return only; there is no let-generalization or unification across separate statements.

---

## 4. Checking

- **Modular checking against declared bounds.** — Decided (2026-07-20). A generic body is checked **once** against exactly what its bounds promise, nothing about any particular instantiation. This is what keeps witness-passing, monomorphization, and future GC value-witness stenciling all reachable from one checked body (§12).
- **Bound satisfaction uses all checked conformances.** A `<T: I>` bound is satisfied by any type that conforms to `I` — including an `I` that is constraint-only (`Self`-mentioning). Such bounds compile because monomorphization specializes them to a concrete `T` (§6); no witness for a constraint-only interface is required. So `<T: Cloneable>` and `<T: Combinable>` both work. (Constraint-only / covariant-`Self` legality is defined in `interfaces.md`.)
- **Assignment/return/binding annotations are checked.** A `Box<Int>` is not assignable to a `Box<String>` binding/return/target; the mismatch is a clean local error (generic instantiations are distinct types even though they share one runtime representation pre-mono).

---

## 5. Generic types

- **Declared like concrete types, with a parameter list.** `struct Box<T> { let value: T }`, `enum Option<T> { case some(value: T)  case none }`, `enum Result<T, E> { case ok(value: T)  case err(error: E) }`, `struct Cell<T> { var value: T }`. Enum payloads must be **labelled** (`case some(value: T)`), so the API is `.some(value: x)` and `case .some(let v)`.
- **Distinct types per instantiation.** `Box<Int>` and `Box<String>` are unrelated (invariance, §1). Equality includes the arguments.
- **Uses:** construction, field read/write, and `match`/`switch` over a generic enum all work at concrete instantiations, and a generic function may **return** a generic type built over its own parameter (`fun wrap<T>(x: T) -> Box<T>`). A mutable generic field (`var value: T`) may be reassigned.
- **A generic type may be taken as a parameter** (`fun f(o: Option<T>)` inside a generic `<T>`): the abstract body is specialized to concrete by monomorphization before codegen, so it is sound. (This was rejected before mono; it is now allowed — inference *through* such a parameter still has the limit in §3.)
- **Deferred:** instance methods / computed properties **on** a generic type are rejected with a clean error (§10).

---

## 6. Lowering — witness-passing + monomorphization

**Witness-passing (the baseline).** A generic function compiles once; each bound contributes a protocol-witness parameter, and a requirement call on a type-parameter receiver dispatches through it. A generic *type* holds its parameter uniformly (by reference). This is the meaning of the code and the representation `any I` shares (`interfaces.md`).

**Monomorphization (`Monomorphize`, an IR→IR pass) — whole-program, always on.** — Decided (2026-07-30).
- Under the **single compilation unit** there is no ABI boundary to preserve, so the pass specializes **every** generic instantiation reached from the program roots (this is exactly Swift's whole-module optimization). It clones each generic decl with its type parameters replaced by concrete types, producing fully-concrete code: **direct calls** (a requirement call on a now-concrete receiver devirtualizes), **inline fields** (a `Box<Int>` stores a real `Int`, no boxing), and no witness parameters.
- **`any I` is untouched** — it is the explicit dynamic/erased form and keeps its witness dispatch. Monomorphization only ever specializes `<T: I>` / generic-type instantiations.
- **Polymorphic recursion** (an instantiation that specializes into an ever-larger type, e.g. `f<T>` calling `f<Box<T>>`) is detected and reported as a clean local error rather than looping.
- **Observable effect:** specialized generic code has the performance of hand-written concrete code (no witness indirection, no boxing). The specialized instantiation names are an internal detail (mangled); they are not part of the surface.
- **Guarantee vs. accelerator.** Nothing depends on monomorphization for *correctness* — it sits on the witness baseline (`interfaces.md` shares the witness representation), so the choice stays reversible. When multi-file / module builds land, the "specialize everything" policy is **re-scoped to within-module** (cross-module specialization becomes opt-in), preserving a stable-ABI default at module edges. Until then, `<T: I>` is static in practice; the *guaranteed*-static levers remain concrete types and `some I` (§1).

---

## 7. The `shared` bound + conditional conformance

Shareability decides what may cross a task boundary (design: `concurrency.md` §5). It is **auto-derived structurally**, so most code needs no annotation.

- **Structural rule.** Primitives and `String` (immutable) are shareable; a value type (`struct`/`enum`) is shareable iff every stored field is; a **class is shareable only when deeply immutable** — every field `let`, recursively, and itself shareable; an actor handle is shareable. — Decided (2026-07-28, incl. `String` shareable).
- **Conditional conformance.** A generic instance is shareable iff its type arguments make it so: `Box<Int>` is shareable, `Box<SomeMutableClass>` is not — derived by substituting the arguments into the base's fields (the same structural check).
- **The `<shared T>` bound** requires the type argument to be shareable; a violation at a call site is a clean error (`type 'X' is not shareable, but type parameter 'T' … is declared 'shared'`). Inside the body a `shared T` counts as shareable, so it may be forwarded across a task boundary. The bound is the primary `shared` surface; the closure/existential spellings are Deferred (§10).

---

## 8. Exhaustiveness under generics

Exhaustiveness is checked on the **generic enum definition**; instantiation adds no cases. A `match`/`switch` that covers every case of `enum Option<T>` is exhaustive for `Option<Int>`, `Option<String>`, and every other instantiation.

---

## 9. Error handling — `Result<T, E>`

- **Carrier.** A generic sum type `enum Result<T, E> { case ok(value: T)  case err(error: E) }`, a prelude citizen in `src/stdlib/core.nomu` (usable with no import, like `Option`). — Decided (2026-07-19); built M5.
- **Handling is explicit `match`/`switch`** over `.ok`/`.err`. There is **no `?` operator and no typed throws** (Deferred, §10). Full error-model context: `types.md` §4.

---

## 10. Deferred

Intentionally out; none of these locks anything that contradicts adding them later.

- **Operators as interface requirements.** Generic code can't yet compare/hash/add an unknown `T` (`==`, `<`, `+` are built into the checker on `Int`/`Bool`, not interface requirements). Cost: no generic `max`/`min`/`sort`, no `Set`/`Dictionary`. Structural containers and higher-order functions over closures are unaffected. Guardrails when it lands: keep operator syntax reserved (so `a < b` becomes a desugared requirement call, not a surface change), and lower built-in conformances to primitive machine ops (`Int: Comparable` → a machine compare).
- **Associated types.** Out of the first cut, but the witness layout reserves a **type-witness slot** and the checker can model a projected type, so adding them is wiring not redesign (`interfaces.md` §8).
- **Nested type-argument inference.** Pinning `T` *through* a container argument that doesn't determine it (a `.none`) — supply an annotation for now (§3).
- **Instance methods / computed properties on a generic type** — rejected with a clean error.
- **Parameter-position `some`** (`fun f(x: some I)`) — subsumed by `<T: I>`, which expresses the same thing.
- **`shared` on closure/function types and existentials** (`shared (A) -> B`, `shared any I`) — no consumer under a single compilation unit; the real trigger is interface requirements forwarding closures, or modules. Tracked in `plans/tasks/132-shared-spellings.md`.
- **Error-handling sugar** — `?` propagation and typed throws (`types.md` §4).
- **Newtype / type-alias mechanism** — the distinct-nominal wrapper that lets a third module escape the orphan rule (§11), left undesigned; not blocking (no modules yet).
- **Monomorphization cross-module policy** — re-scoping "specialize everything" to within-module + opt-in cross-module specialization, when modules land (§6).

---

## 11. Coherence (global orphan rule)

A conformance (`extension T: I`, `interfaces.md`) may be declared only in the module that owns `T` or the module that owns `I`; it is then global and unique across the program — **no invisible behavior on import**, and **one witness program-wide**. A third module needing `T`-as-`I` wraps `T` in a distinct nominal type it owns (the newtype mechanism, §10) and conforms the wrapper. — Decided (2026-07-20); **enforcement blocked on modules** (`modules.md`). Under M5's single compilation unit uniqueness is trivial; this is the target model, not scaffolding.

---

## 12. Rationale & rejected alternatives

The durable *why*, kept so future changes have the tiebreaker.

- **Witness-first, monomorphization second (not Rust's always-mono baseline).** Checking modularly against bounds — not per-instantiation (C++ templates) — keeps witness-passing, monomorphization, and GC value-witness stenciling all reachable from one checked body. Building the witness path first and layering mono on top (rather than making mono the only path) keeps the door open to a **stable ABI for generics** at future module boundaries (Swift's position), which Rust's always-monomorphize model forecloses. Two reversibility guardrails held: the generic path reuses the `any` conformance representation (not a mono-only one), and the M6 object model must expose per-type trace metadata as runtime-reachable data (a value witness), not baked solely into specialized code. — Decided (2026-07-20).
- **Construction-site type arguments via speculative parse (backtracking chosen).** — Revised (2026-08-07; supersedes the 2026-07-25 "no expression-position type arguments" decision). Explicit type arguments are allowed when constructing a generic type (`Box<Int>(...)`, `Option<Int>.some(...)`, `Option<Int>.none`); the parser commits `Name<…>` to type arguments only when the closing `>` is followed by `(` or `.`, else backtracks to comparison (§2). Two alternatives were rejected: **turbofish** (`f::<Int>(x)`) adds a `::` sigil and a second spelling for angle brackets; a **whitespace-significance rule** (space around `<` = comparison) makes spacing meaningful across every expression *and* conflicts with breaking a generic list across newlines — since Nomu's lexer discards newlines, a multi-line list carries interior whitespace that the rule would misread, forcing a narrower, more surprising form. Backtracking keeps one natural angle-bracket spelling everywhere, at the cost of a speculative parse and a rare `a < b > (c)` needing parentheses. Generic *function* call-site arguments (`f<Int>(x)`) remain unsupported — function parameters are inferred.
- **Invariant generics** over variance inference — sound by default, no read/write-position analysis (§1).
- **`shared` as an orthogonal capability prefix**, not an `&`-composed marker interface — a param that is both `Comparable` and shareable reads `<shared T: Comparable>` (`interfaces.md` §9).
- **Whole-program mono now** because a single compilation unit has no ABI boundary to protect, so specializing everything is pure upside (fast by default; removes pre-mono boxing/leaks; lifts abstract-container restrictions); the policy is revisited, not the mechanism, when modules arrive (§6).
