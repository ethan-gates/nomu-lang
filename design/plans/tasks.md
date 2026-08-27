# Task index — outstanding work

The backlog as a **task index**. Each task has its own doc in [`tasks/`](tasks/) carrying
What / Why / Dependencies / How / Refs. This index is the scannable surface and the
tracking artifact; the per-task docs hold the detail.

- **Source.** `deferred.md` was dissolved into these task docs (2026-08-25); the remaining-work
  items from the former `roadmap.md` (M8, M10–M13, LXR, the "Ongoing" set) were mined into them too.
  `roadmap.md` was retired — near-term ordering is now `horizon.md`, the backlog is here,
  and shipped-milestone history lives in git + the per-subsystem `internals/` docs.
- **Not here.** Durable design lives in `../language/` + `../internals/`; this index is ephemeral
  work-tracking per `readme.md`. The SSAIR optimizer tier is task [148](tasks/148-ssair-optimizer-tier.md),
  which carries its sub-item backlog at `148.x` granularity.

## Two prioritization avenues

Work is prioritized against two avenues (a task can serve both; the table lists its primary):

- **Risk** — validate the risky bets Nomu rests on. Headline: the **self-hosted runtime** (GC +
  scheduler in Nomu, built now — the core bet), with the **LXR** RC-hybrid collector as the footprint
  endgame reached inside it. The concurrency-model completion and fiber-stack strategy feed the same
  "prove the hard thesis" goal.
- **Usability** — quality-of-life work that makes Nomu usable for programs larger than artificial
  benchmarks. The language surface, stdlib, tooling, and error/iteration ergonomics.
- **Infra** — cross-cutting compiler/architecture work underlying both avenues.

## Task identity numbers

Each task has a **stable identity number** starting at **100**; the doc is named `1NN-slug.md`
(e.g. `tasks/100-modules.md`). The number is **identity only** — it carries no priority or ordering
(task 34 may be worked before 56; the 100+ range signals "identity tracker, not a prioritized
list"). It never changes once assigned; a new task takes the next free integer. Ordering, when it
matters, lives in the horizon (`horizon.md`), not here. Drill-down inside a task uses the number —
`100.2.5.1` — via that task's own section headings.

## Status vocabulary

`needs-design` · `needs-grounding` · `ready-to-build` · `blocked` · `in-progress` · `evaluate` ·
`ongoing`. Size ∈ {S, M, L, XL}.

## Tasks

### Concurrency & runtime completion (M8 + hardening)

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 135 | [Cancellation + one-shot continuations](tasks/135-cancellation-continuations.md) | Risk | L | needs-design |
| 101 | [`defer` + linear types](tasks/101-defer-linear-types.md) | Usability | M | needs-design (► decide-early w/ M8) |
| 102 | [Channels](tasks/102-channels.md) | Usability | M | needs-design |
| 103 | [Dynamic fan-out spawn group](tasks/103-dynamic-spawn-group.md) | Risk | M | needs-design |
| 104 | [Fiber stack strategy](tasks/104-fiber-stack-strategy.md) | Risk | L | build deferred; direction decided (guard-page lean) |
| 105 | [Concurrency hardening (M12)](tasks/105-concurrency-hardening.md) | Risk | L | evaluate |
| 106 | [Actor fiber-aware mutex](tasks/106-actor-fiber-aware-mutex.md) | Risk | M | ready-to-build |

### Language surface (Usability)

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 107 | [`init` — custom initializers](tasks/107-init.md) | Usability | M | needs-design |
| 108 | [`deinit` / finalization](tasks/108-deinit-finalization.md) | Usability | M | needs-design (► decide-early w/ M8) |
| 109 | [Tuples](tasks/109-tuples.md) | Usability | L | needs-design |
| 110 | [Pattern matching (full)](tasks/110-pattern-matching.md) | Usability | L | needs-design |
| 111 | [Operator overloading (user types)](tasks/111-operator-overloading.md) | Usability | M | needs-design |
| 112 | [Parameter labels + argument model](tasks/112-param-labels-args.md) | Usability | M | needs-design |
| 113 | [Operator surface (built-ins)](tasks/113-operator-surface.md) | Usability | M | partially-shipped |
| 114 | [Grouping parentheses](tasks/114-grouping-parens.md) | Usability | S | ready-to-build |
| 115 | [Error handling — `?` + typed throws](tasks/115-error-handling.md) | Usability | M | needs-design |
| 116 | [Optional ergonomics](tasks/116-optional-ergonomics.md) | Usability | S | needs-design |
| 117 | [`for … in` + iteration protocol](tasks/117-for-in-iteration.md) | Usability | M | needs-design |
| 118 | [Associated types + where-clauses](tasks/118-associated-types.md) | Usability | L | needs-design |
| 119 | [Float-exponent literals](tasks/119-float-exponent-literals.md) | Usability | S | needs-design |

### Stdlib & memory model (Usability)

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 120 | [Standard library — core types + I/O](tasks/120-stdlib-core.md) | Usability | L | needs-design |
| 121 | [String / UTF-8 model](tasks/121-string-utf8-model.md) | Usability | M | needs-design |
| 122 | [Numeric semantics + overflow](tasks/122-numeric-semantics.md) | Usability | M | needs-design |
| 123 | [Copy-on-write for value collections](tasks/123-copy-on-write.md) | Usability | M | needs-design |
| 124 | [Generic hash map](tasks/124-generic-hashmap.md) | Usability | M | blocked (D6 spill) |
| 125 | [Unsafe raw memory / raw pointers](tasks/125-unsafe-raw-memory.md) | Risk | L | built (minimal floor) — `RawPtr`/`Ptr<T>`, `internals/unsafe-memory.md`; first prereq of self-hosted runtime 128 |
| 126 | [SIMD](tasks/126-simd.md) | Usability | L | needs-design |

### Runtime perf & the risk bets

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 127 | [LXR collector (footprint endgame)](tasks/127-lxr-collector.md) | Risk | XL | final rung of the self-hosted GC ladder (after 150's GenImmix) |
| 128 | [Self-hosting the runtime](tasks/128-self-hosting-runtime.md) | Risk | XL | build now — core bet; decomposes into 125 → 149 → 150 → 127 |
| 149 | [Runtime-subset mechanism](tasks/149-runtime-subset.md) | Risk | M | in-progress — slice 1 built (runtime-prelude "designated file" + flag; call-graph closure check, `internals/runtime-subset.md`); remaining: codegen guards, `nosplit`, module designation |
| 150 | [Self-hosted GC bring-up ladder](tasks/150-selfhosted-gc-ladder.md) | Risk | XL | in-progress — **rung 1 complete**: self-hosted allocator is a selectable plan (`NOMU_GC_PLAN=nomu`), byte-identical to MMTk NoGC across GC fixtures (`tools/selfhost-gc.sh`); next rung 2 (mark-verify) |
| 129 | [Tail-call optimization](tasks/129-tail-call-optimization.md) | Usability | M | needs-design |
| 130 | [First-class FFI to the C ABI](tasks/130-ffi-c-abi.md) | Usability | L | needs-design |
| 131 | [Shared-mutable primitive](tasks/131-shared-mutable-primitive.md) | Risk | M | ongoing |
| 132 | [`shared` function-type / existential spellings](tasks/132-shared-spellings.md) | Infra | S | ready-to-build (trigger-gated) |
| 133 | [Fiber-pinned mutator cache](tasks/133-fiber-pinned-mutator-cache.md) | Infra | S | needs-grounding |
| 134 | [MLIR consideration](tasks/134-mlir-consideration.md) | Infra | S | evaluate |
| 148 | [SSAIR optimizer tier](tasks/148-ssair-optimizer-tier.md) | Risk | L | mostly-shipped (tails open) |

### Tooling, modules, macros

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 100 | [Modules + multi-file compilation](tasks/100-modules.md) | Infra | XL | needs-design (► decide-early: model fork before M10) |
| 136 | [Incremental compilation](tasks/136-incremental-compilation.md) | Infra | L | needs-design |
| 137 | [Tooling — query server / LSP / formatter (M10)](tasks/137-tooling-lsp-formatter.md) | Usability | L | needs-design |
| 138 | [Debugger (M11)](tasks/138-debugger.md) | Usability | L | needs-design |
| 139 | [Memory debugging / heap introspection](tasks/139-memory-heap-introspection.md) | Usability | M | evaluate |
| 140 | [Macros (M13)](tasks/140-macros.md) | Usability | L | needs-design |
| 141 | [`comptime`](tasks/141-comptime.md) | Usability | L | needs-design |

### Compiler infra / hardening / perf

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 142 | [IR + pipeline-boundary hardening](tasks/142-ir-pipeline-hardening.md) | Infra | M | needs-design (► decide-early: format w/ M7) |
| 143 | [Parser / frontend error recovery](tasks/143-parser-error-recovery.md) | Usability | M | ready-to-build |
| 144 | [Frontend perf (interning, lexer, streaming)](tasks/144-frontend-perf.md) | Infra | M | needs-grounding |
| 145 | [Monomorphization cost model](tasks/145-monomorphization-cost.md) | Infra | S | evaluate |
| 146 | [Author the `language/` contract tier](tasks/146-language-contract-tier.md) | Infra | M | in-progress |
| 147 | [Compiler cleanups (bucket)](tasks/147-compiler-cleanups.md) | Infra | S | ready-to-build |

## ► Decide-early flags (carried from `deferred.md`)

Design decisions to settle ahead of their build so later choices don't foreclose them:

1. [`deinit` / finalization](tasks/108-deinit-finalization.md) — the finalization-vs-deterministic-cleanup fork,
   alongside M8's [`defer` + linear types](tasks/101-defer-linear-types.md).
2. [Fiber stack strategy](tasks/104-fiber-stack-strategy.md) — ✓ resolved 2026-08-25: build deferred, guard-page lean.
3. [IR + pipeline hardening](tasks/142-ir-pipeline-hardening.md) — IR text-format discipline while SSAIR is young (M7).
4. [Modules](tasks/100-modules.md) — the separate-compilation-vs-whole-program-mono fork, before M10.
5. [Unsafe raw memory](tasks/125-unsafe-raw-memory.md) — the unsafe surface; now build-now as the first
   prerequisite of the self-hosted runtime (was "before the stdlib track"; rescoped).

[Self-hosting the runtime](tasks/128-self-hosting-runtime.md) is now **build now — the core bet** (no
longer "build late"); it decomposes into [125](tasks/125-unsafe-raw-memory.md) →
[149 runtime-subset](tasks/149-runtime-subset.md) → [150 GC ladder](tasks/150-selfhosted-gc-ladder.md) →
[127 LXR](tasks/127-lxr-collector.md). Still design-early: [tail-call optimization](tasks/129-tail-call-optimization.md)
(guarantee-vs-best-effort).
