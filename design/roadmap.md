# Roadmap & Milestones

**Status:** working draft — **provisional**. Restaged 2026-07-16 after the concurrency model was designed; the order is a working plan, not fixed. Status tags: **Provisional**.

---

## MVP strategy

Drive scope by what is genuinely doubted, and borrow what is proven.

- **Doubted (validate early):** the **concurrency model** — the shareability rule (race-free by construction) and whether colorless + actors + structured concurrency feel right (`concurrency.md`); and the **surface feel** — the Swift-shaped value/reference split and sum types + exhaustive `match` (`types.md`, `syntax.md`).
- **Proven (stub or defer):** the **GC** (MMTk is borrowed), the **performance recipe** (C#-with-structs), and the **M:N stackful scheduler** (Go proves it — engineering, not research risk).

So the early milestones prove the concurrency model and the surface on the *cheapest runtime that exercises them* — real OS threads, a trivial allocator, concrete types — and only then make it real (M:N, generics, GC, LLVM). The existing Swift-hosted front-end + hand-written runtime survive as scaffolding; the target changes.

---

## Provisional order (not fixed)

Each milestone is meant to be small and independently meaningful.

- **M1 — walking skeleton ("it runs"):** the thinnest end-to-end slice — lex → parse → trivial typecheck → **emit C** → `cc` → a native binary that computes and prints. Surface: `fun`, `Int`/`Bool`, arithmetic/comparison, `let`/`var`, `if`, `print`. **No heap → no GC**, no user types, no concurrency. Proves the pipeline, emit-C, and native execution end to end.
- **M2 — type surface:** `struct`/`enum`/`class`, exhaustive `match`, closures, the value/reference split. Introduces the heap → a **trivial bump-and-leak allocator** (still no real GC). Validates whether the surface feels right (doubted bet b).
- **M3 — concurrency belief:** actors (message-send, drain), structured spawn/scope, colorless blocking, and the **shareability checker** — on **real OS threads (1:1)**, built-in collections, concrete types. Validates the concurrency-safety model and its ergonomics (doubted bet a). This is the milestone the whole design points at.
- **M4 — M:N stackful runtime:** the fiber scheduler (stack switching, work-stealing, parallelism knob), poller, timer heap, syscall offload (`runtime.md`). Replaces OS threads with the real runtime; the substrate for continuations, cancellation, and channels.
- **M4.9 — real typechecker / semantic analysis (M5 prerequisite) — DONE.** Stood up a genuine semantic-analysis pass — an internal `Type` model (replacing the string-typing), name/member/method resolution, expression typing, call/argument checking, symbol tables, and collected diagnostics — producing the typed mid-level IR that codegen consumes instead of re-deriving types in `typeOf`. Landed **instance methods on `struct`/`enum`/`class`** (read-only; a prerequisite for interface method requirements) and **exhaustiveness as an IR pass**. Inserted because M5's interfaces/generics need real type information the codegen-embedded type tracking couldn't provide. Architecture in `compiler.md` §1; the type-system surface it added is in `types.md` (§3 methods, §2 exhaustiveness).
- **M4.10 — M5 prerequisites (enum construction + `let` fields) — DONE.** A short slice found by grounding M5's exit criteria against the code, the same way M4.9 was. Two of M5's headline deliverables can't run on the current compiler for non-generics reasons: **enum values can't be constructed** (the typechecker builds `struct`/`class`/`actor` only — `Option<T>`/`Result<T,E>` are enums that must be constructed), and **`let` fields don't exist** (only `var` fields — `Box<T> { let value: T }` and Phase C's deeply-immutable-class shareability need field-level immutability, `memory-model.md` §4). Both are small concrete features (the M4.9 pattern: build the concrete form; M5 layers generics on top). Also resolves M5 Phase A's iteration-demo criterion, which assumes loops/collections the language doesn't have yet. Design: `types.md` §2 (enum construction), `memory-model.md` §4 (`let` fields).
- **M4.11 — mutating methods on value types (inferred) — DONE.** The last pre-M5 prerequisite from the audit (M5 Phase A's `{ get set }` requirements and computed-property setters need a settable `var` receiver). Method mutating-ness is **inferred** from the body (writes a field of `self`, or calls a mutating method on `self` — transitive), with no `mutating` keyword yet; explicit can layer on later. A mutating value-type method takes `self` by reference (direct field access, so nested self-calls compose) and can only be called on a `var` receiver; classes are exempt (reference semantics). The inferred bit is part of the method's exported contract (`modules.md` §1). Design: `types.md` §3.
- **M4.12 — plain extensions (M5 prerequisite) — DONE.** `extension T { … }` adding non-conformance instance methods to `struct`/`enum`/`class` — statically dispatched, member-merged into the type. The compiler had no `extension` construct; this builds the plain form (the parse + member-merge path M5 Phase A's conformance extensions reuse) and forbids stored properties in extensions (Swift's rule). A dedicated merge pass folds extension methods into the target type before typechecking, so downstream passes need no extension-awareness; the M4.11 mutation rules apply unchanged. Conformance extensions (`extension T: I`), generic-type extensions, and module-scoped visibility are M5 / later. Design: `interfaces.md` §1 (plain form as built); pipeline seam: `compiler.md` §1.
- **M4.13 — C-source split + Nomu prelude (M5-adjacent) — DONE.** Move the emitted C runtime out of an embedded Swift string into real `.c`/`.h` files (a privileged `runtime` and the stdlib's C `core` floor for `String` + primitive ops), and add a **prelude-compilation mechanism** so a Nomu-written standard library compiles alongside user code (prepended decls under the single CU). No new syntax. The standard library is written in Nomu and recompiled each build (dogfooding + front-loads LLVM test surface); `String` stays a C primitive until the buffer primitive exists (post-M5, with collections). Packaging: embed-and-emit, so `nomuc` stays a single relocatable binary. Hard-gates M5 Phase B (the home for `Result`/`Option`); recommended before Phase A. Code: `src/runtime/`, `src/stdlib/`.
- **M4.14 — output root + additive emit/stop — DONE.** Every compiler output lands under `<project-root>/build/`, mirroring the source's relative path (`examples/actor.nomu` → `build/examples/{actor, actor.c, runtime.c, core.c, runtime.h}`); outputs persist (no temp dir). Project root is the nearest ancestor with a `nomu.yaml` marker (else the source's own directory); the marker is existence-only for now, config later. Runtime files renamed to bare `runtime.c`/`core.c`/`runtime.h`. Also: **emit flags are additive and file-based** — `--emit-ast`/`--emit-typedir`/`--emit-c` each write an artifact under `build/` (`<name>.ast`/`.typedir`/`.c`), report its path, and still build the binary — with a **`--stop=[ast|typedir|binary]`** pipeline gate (default `binary`), replacing the old exclusive emit-mode enum. Deferred: binary/intermediates split, a single central `runtime.c`, per-arch/platform splits, explicit output-root override, more stop stages.
- **M4.15 — symbol mangling — DONE.** Generated C identifiers are `nomu_`-prefixed + z-encoded so Nomu names can't collide with libc; single swap point `src/codegen/sources/Mangle.swift`. Design: `compiler.md` §2a.
- **M5 — generics + interfaces — DONE.** Shipped: interfaces (declaration, conformance, witness tables, refinement, `&` composition, `any`/`some`, `Self`-requirements + covariant-`Self` erasure), computed properties, generics (parameters, inference, modular checking, witness-passing + **whole-program monomorphization**), the `<shared T>` bound + conditional conformance + the completed shareability checker (deeply-immutable classes, `String`), exhaustiveness under generics, and `Result<T, E>` error handling (`?` operator / typed throws deferred). As-built specs: **`generics.md`** (generics), **`interfaces.md`** (interfaces), `concurrency.md` §5 (shareability), `types.md` §5 (errors). Unlocks real collections and, later, the shared-mutable primitive.
- **M6 — real GC (MMTk):** the binding — precise stack maps, safepoints, write barriers, object model; generational Immix; the escape-analysis pass (`memory-model.md`, `compiler.md`). Replaces bump-and-leak.
- **M7 — cancellation, continuations, resources:** safepoint-automatic cancellation (on M6 safepoints), the checked one-shot continuation, `defer` + linear types (resume-once and resource cleanup), and the channels library.
- **M8 — real backend (LLVM):** mid-level IR → LLVM release path; debug info through the IR; incremental compilation + cached monomorphizations (`compiler.md`).
- **M9 — tooling:** query-based compiler server, LSP, formatter.
- **M10 — debugger:** DWARF variant parts, data formatters, GC-aware stepping, runtime-aware plugin (DAP).
- **M11 — macros:** typed hygienic AST macros.
- **Ongoing:** LXR-style collector for footprint (`memory-model.md` §3), the shared-mutable primitive design (needs M5 generics), FFI (foreign-thread attach + pinning, `runtime.md` §5), MLIR consideration (`compiler.md`).

**Cross-cutting** (thread through several milestones rather than sitting in one): error handling (`Result` + `?`, expressible once M2 has enums, finalized in M5), `defer` (scoped cleanup, wanted as soon as M3 does I/O), and linear types (first hard requirement at M7 for continuations and resource cleanup).

---

## The discipline (unchanged)

Build the part you doubt first; prototype the belief, not the surface. M1 is the minimal substrate needed to run anything; M2 and M3 then go straight for the doubted bets rather than polishing surface. Memory and the M:N scheduler are solved, borrowed components brought in once the model validates.

---

## Open questions

- **Roadmap shape itself** — still provisional; the M4+ ordering (M:N, generics, GC, LLVM) can reshuffle as M3 teaches us what matters. The MVP framing (M1–M3) is the firm part.
