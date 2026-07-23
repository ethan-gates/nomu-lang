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
- **M4.10 — M5 prerequisites (enum construction + `let` fields) — DONE.** A short slice found by grounding M5's exit criteria against the code, the same way M4.9 was. Two of M5's headline deliverables can't run on the current compiler for non-generics reasons: **enum values can't be constructed** (the typechecker builds `struct`/`class`/`actor` only — `Option<T>`/`Result<T,E>` are enums that must be constructed), and **`let` fields don't exist** (only `var` fields — `Box<T> { let value: T }` and Phase C's deeply-immutable-class shareability need field-level immutability, `memory-model.md` §4). Both are small concrete features (the M4.9 pattern: build the concrete form; M5 layers generics on top). Also resolves M5 Phase A's iteration-demo criterion, which assumes loops/collections the language doesn't have yet. **Spec: `m4.10-spec.md`.**
- **M5 — generics + monomorphization:** interface constraints, exhaustiveness under generics, and the shareable bound on type parameters (`types.md`). Error handling final form (`Result` + `?`). Unlocks real collections and, later, the shared-mutable primitive. Also: complete the shareability checker — recognize deeply-immutable classes (all `let` fields, recursively) as shareable, which the M3 checker conservatively rejects. **Design + phased build plan: `generics.md` and `m5-spec.md`.** (Note: M5 also builds interfaces and computed properties, which the compiler lacks today; monomorphization is an optional accelerator, not the correctness baseline.)
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
