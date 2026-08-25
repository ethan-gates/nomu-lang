# Nomu Design

Design docs for **Nomu**, a systems language: *Swift's expressiveness, Go's ease and deployment, none of Rust's friction.* Design phase — these are working records.

**Name:** Nomu · **source extension:** `.nomu` · **function keyword:** `fun`.

## Layout

The docs are organized by **audience/fidelity**, mirroring the three sources of truth from cheapest-to-read to most-exact:

- **[`language/`](language/readme.md)** — the **contract**: what Nomu guarantees and aims for, programmer-facing, short. Distilled intent; source of the eventual public docs. *(Being authored, distilled from `internals/`.)*
- **[`internals/`](internals/readme.md)** — the **as-built design**: how the compiler and runtime actually work, accurate to the code, for a dev/LLM making a change. The detailed design + rationale + invariants.
- **code** — the exact source, most costly to read.
- **[`plans/`](plans/readme.md)** — ephemeral work-tracking (backlogs, milestone build-plans); not durable design.

Steering docs (`vision.md`, `roadmap.md`, this index) stay at the root. Docs cross-reference each other by name (`backend.md`), so the name resolves regardless of folder.

## Steering

- [vision.md](vision.md) — what Nomu is for: goals, performance profile, design principles, rejected directions, and the tiebreaker for future decisions.
- [roadmap.md](roadmap.md) — milestones (provisional, post-pivot).

## Internals (as-built design)

- [internals/memory-model.md](internals/memory-model.md) — the value/reference split, the GC (MMTk), immutability, escape analysis, the performance recipe, and every binding form's memory meaning.
- [internals/types.md](internals/types.md) — type system apart from interfaces: generics + dispatch, sum types + exhaustive matching, error handling.
- [internals/generics.md](internals/generics.md) — **authoritative as-built spec** for generics: parameters, inference, checking, witness-passing + monomorphization, generic types, the `shared` bound + conditional conformance, exhaustiveness, `Result`.
- [internals/interfaces.md](internals/interfaces.md) — conformance, dispatch, extensions, and composition.
- [internals/concurrency.md](internals/concurrency.md) — concurrency model, suspension primitive, share analysis, closures, continuations.
- [internals/syntax.md](internals/syntax.md) — surface-syntax principles (one canonical form per concept).
- [internals/loops.md](internals/loops.md) — Nomu's iteration construct (`while`) — syntax, semantics, lowering. The loop back-edge hosts the safepoint poll.
- [internals/macros.md](internals/macros.md) — typed hygienic AST macros; extension-only role.
- [internals/modules.md](internals/modules.md) — **stub**: modules / compilation units and access control (undesigned; reserved).
- [internals/runtime.md](internals/runtime.md) — the execution substrate: M:N scheduler, wakeup feeders, cross-thread resume, platform/syscall strategy, FFI-readiness.
- [internals/architecture.md](internals/architecture.md) — compiler architecture: the whole-flow pipeline, the interface/implementation module split, and the committed capabilities (debug info, incremental, query server).
- [internals/noir.md](internals/noir.md) — the typed structured mid-level IR (NOIR): altitude, the semantic pass, and the passes that run on it.
- [internals/backend.md](internals/backend.md) — LLVM codegen: backend strategy, the GC backend substrate (statepoints, seams, pass pipeline), and symbol mangling.
- [internals/tooling.md](internals/tooling.md) — the tooling-first / query architecture, the same engine as fine-grained incremental compilation.
- [internals/debugger.md](internals/debugger.md) — the debugger plan (emit DWARF, extend lldb): the tiered plan and pragmatics; fills in as it's built.
- [internals/ssair.md](internals/ssair.md) — the SSAIR optimizer tier (M7): IR shape + decisions, the pass framework + four passes (escape analysis with stack/scalar promotion, devirtualization, inlining, BCE), lowering to LLVM, and the GC-precision invariants (I1–I10) the transforms preserve.
- [internals/c-types.md](internals/c-types.md) — C-backed standard-library types (String, `Array<T>`, planned numeric primitives + spawn group): layout, the allocation/GC boundary, and the runtime contract, before they migrate into a Nomu-written stdlib.
- [internals/builtin.md](internals/builtin.md) — how-to: adding a C-backed builtin method / property / free function and wiring it through Sema, codegen, and the safepoint pass (no lexer/parser change).

## Plans (ephemeral)

- [plans/deferred.md](plans/deferred.md) — TODO backlog: feature work intentionally postponed, each with its un-park trigger.
- [plans/ssair-backlog.md](plans/ssair-backlog.md) — consolidated backlog of SSAIR-tier work (passes, analyses, IR/infra, validation).

**Retired milestone specs** — a spec is **deleted once done**: its durable design (and any directions not taken) folds into `language/` + `internals/`, and git + the code are the record.
- **M7 (optimizer tier — SSAIR) — done (2026-08-24).** SSAIR + the pass framework + precise escape analysis (stack + scalar promotion), devirtualization, inlining; the NOIR→LLVM path retired at M7.7, leaving SSAIR the sole egress. Durable design folded to `internals/ssair.md` (IR shape, decisions, the four passes, GC-precision invariants I1–I10 + `Tn` obligations) and `internals/memory-model.md` §6.1 (escape analysis as-built); tails in `plans/ssair-backlog.md`.
- **M9 (LLVM backend) — done (2026-08-03).** Design/rationale in `internals/backend.md` (backend, GC substrate); follow-ups in `plans/deferred.md` ("Post-M9 backlog").
- **M6 (real GC via MMTk) — done (2026-08-13).** Durable design folded to `internals/memory-model.md` §3, `internals/runtime.md` §6, `internals/backend.md`, `internals/concurrency.md` §9.

The full decision history once lived in a separate `early-design.md`; it has been dissolved into the per-subsystem docs, each of which now carries its own rationale and open questions.

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
- **Deterministic resource cleanup** — `defer` is Decided; linear / non-copyable types deferred to M8 (`memory-model.md` §6.2).
- **Error handling** — errors-as-values (no exceptions) Decided; the *form* (`Result`/tuple/other carrier, `?` operator, typed throws) is open (`types.md` §4).
- **Modules & access control** — undesigned; a stub reserves the topic (`modules.md`).
- **Keyword spellings** — `shareable`, `extension` (`syntax.md`, and their home docs).
- **Backend** — MLIR vs. plain LLVM; Cranelift for debug builds (`backend.md`).
- **Roadmap** — the milestone order is provisional post-pivot (`roadmap.md`).
