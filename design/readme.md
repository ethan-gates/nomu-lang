# Nomu Design

Design docs for **Nomu**, a systems language: *Swift's expressiveness, Go's ease and deployment, none of Rust's friction.* Design phase — these are working records, not specs.

**Name:** Nomu · **source extension:** `.nomu` · **function keyword:** `fun`.

## Contents

- [vision.md](vision.md) — what Nomu is for: goals, performance profile, design principles, rejected directions, and the tiebreaker for future decisions.
- [memory-model.md](memory-model.md) — the value/reference split, the GC (MMTk), immutability, escape analysis, the performance recipe, and every binding form's memory meaning.
- [types.md](types.md) — type system apart from interfaces: generics + dispatch, sum types + exhaustive matching, error handling.
- [generics.md](generics.md) — **authoritative as-built spec** for generics: parameters, inference, checking, witness-passing + monomorphization, generic types, the `shared` bound + conditional conformance, exhaustiveness, `Result`.
- [interfaces.md](interfaces.md) — conformance, dispatch, extensions, and composition.
- [modules.md](modules.md) — **stub**: modules / compilation units and access control (undesigned; reserved).
- [concurrency.md](concurrency.md) — concurrency model, suspension primitive, share analysis, closures, continuations.
- [runtime.md](runtime.md) — the execution substrate: M:N scheduler, wakeup feeders, cross-thread resume, platform/syscall strategy, FFI-readiness.
- [syntax.md](syntax.md) — surface-syntax principles (one canonical form per concept).
- [macros.md](macros.md) — typed hygienic AST macros; extension-only role.
- [compiler.md](compiler.md) — compiler architecture, mid-level IR, backend strategy, tooling, debugger.
- [m8-spec.md](m8-spec.md) — **working draft**: M8 implementation spec for the LLVM backend — IR production (C++ shim), DWARF, the GC/cancellation/preemption safepoint substrate, runtime-as-library. The next build milestone (precedes M6). Forks decided in 8.0.4; phased plan 8.1–8.5.
- [m8.1-spec.md](m8.1-spec.md) — **working draft (design-opening)**: M8 phase 8.1 expanded — LLVM toolchain bring-up (Swift↔C++ shim, LLVM-in-bazel, object emission, native hello-world). The riskiest M8 plumbing; binding-strategy + LLVM-acquisition forks open in 8.1.0.4.
- [m6-spec.md](m6-spec.md) — **working draft**: M6 implementation spec (build plan) for the real GC (MMTk) — binding, object model, precise roots, safepoints/barriers, moving GenImmix. Gated on M8 (LLVM). Follows `lang-project/milestone-doc-guide.md`.
- [roadmap.md](roadmap.md) — milestones (provisional, post-pivot).
- [deferred.md](deferred.md) — TODO backlog: feature work intentionally postponed, each with its un-park trigger.

The full decision history and rationale used to live in a separate `early-design.md`; it has been dissolved into the per-subsystem docs above, each of which now carries its own rationale and open questions.

## Reading the status tags

Each decision carries a status. The vocabulary across docs:

- **Decided / Locked** — committed unless a strong reason emerges.
- **Leaning** — a direction is favored but not yet committed.
- **Deferred** — the direction is chosen, the work intentionally postponed.
- **Open / TODO** — genuinely undecided; noted so it isn't forgotten.

Docs also carry an **API scope** note where relevant: no concrete keyword or API is committed until explicitly agreed, and each will be pinned as *language* or *standard library* at that point. What's pinned early is the *model*, not the surface.

## Open questions across the design

Each doc owns its own rollup; the cross-cutting highlights:

- **Generics** — **built through M5** and specified as-built in `generics.md` (parameters, inference, checking, witness-passing + monomorphization, generic types, `shared` bound, exhaustiveness, `Result`). Remaining open items are the deferred surface listed there (§10): operators-as-requirements, associated types, `?`/typed-throws, the newtype mechanism.
- **Concurrency** — the model is essentially complete (`concurrency.md`): the shareability rule (§1), suspension core (§2), continuations (§3, §6), channels as a deferred library (§4), share analysis (§5), the **cancellation model** (§7), the **scope surface** (§8), and the **actor surface** (§9) are all decided. The **shared-mutable primitive** is decided-deferred (§10 — reserved fourth shareable category). Remaining: the **spelling batch** and the shared-mutable design when generics land.
- **Runtime/scheduler** — work-stealing internals, stack growth, task-locals, remote-wake primitive, platform/syscall (no-libc) strategy, and deferred FFI attach/pinning (`runtime.md` §7).
- **Deterministic resource cleanup** — `defer` is Decided; linear / non-copyable types deferred to M7 (`memory-model.md` §6.2).
- **Error handling** — errors-as-values (no exceptions) Decided; the *form* (`Result`/tuple/other carrier, `?` operator, typed throws) is open (`types.md` §4).
- **Modules & access control** — undesigned; a stub reserves the topic (`modules.md`).
- **Keyword spellings** — `shareable`, `extension` (`syntax.md`, and their home docs).
- **Backend** — MLIR vs. plain LLVM; Cranelift for debug builds (`compiler.md` §5).
- **Roadmap** — the milestone order is provisional post-pivot (`roadmap.md`).
