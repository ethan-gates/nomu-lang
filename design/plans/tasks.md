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
| 107 | [`init` — custom initializers](tasks/107-init.md) | Usability | M | needs-design (static-method factories shipped as the lighter path) |
| 108 | [`deinit` / finalization](tasks/108-deinit-finalization.md) | Usability | M | needs-design (► decide-early w/ M8) |
| 109 | [Tuples](tasks/109-tuples.md) | Usability | L | needs-design |
| 110 | [Pattern matching (full)](tasks/110-pattern-matching.md) | Usability | L | needs-design |
| 111 | [Operator overloading (user types)](tasks/111-operator-overloading.md) | Usability | M | needs-design |
| 112 | [Parameter labels + argument model](tasks/112-param-labels-args.md) | Usability | M | needs-design |
| 113 | [Operator surface (built-ins)](tasks/113-operator-surface.md) | Usability | M | partially-shipped |
| 114 | [Grouping parentheses](tasks/114-grouping-parens.md) | Usability | S | shipped |
| 115 | [Error handling — `?` + typed throws](tasks/115-error-handling.md) | Usability | M | needs-design |
| 116 | [Optional ergonomics](tasks/116-optional-ergonomics.md) | Usability | S | needs-design |
| 117 | [`for … in` + iteration protocol](tasks/117-for-in-iteration.md) | Usability | M | needs-design |
| 118 | [Associated types + where-clauses](tasks/118-associated-types.md) | Usability | L | needs-design |
| 119 | [Float-exponent literals](tasks/119-float-exponent-literals.md) | Usability | S | needs-design |
| 151 | [Methods on generic types](tasks/151-generic-type-methods.md) | Usability | M | shipped (instance + computed + static, all of struct/class/enum); tails: static type-arg inference, D6 by-value read |
| 170 | [Method-level generics (a method's own type params)](tasks/170-method-level-generics.md) | Usability | L | needs-design — unimplemented in-module and cross-module; owns the whole feature (frontend→inference→mono→codegen→module boundary) |
| 152 | [First-class functions & closures](tasks/152-first-class-functions.md) | Usability | L | needs-design — deferred; **not** built during self-hosting. Runtime met its need with the `RawPtr.ofFunc` primitive (128.1.2), which claims no user surface |

### Stdlib & memory model (Usability)

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 120 | [Standard library — core types + I/O](tasks/120-stdlib-core.md) | Usability | L | needs-design |
| 121 | [String / UTF-8 model](tasks/121-string-utf8-model.md) | Usability | M | designed — `StringBase`/`String` layering settled: `StringBase` is the internal bit-stealing 16-byte shaped value (the thin, possibly-non-Nomu magic bridge, four ops), `String` is a pure-Nomu `struct { let base: StringBase }` holding the whole surface, `Substring` deferred. [180 managed buffer](tasks/180-managed-buffer.md) is **done** (heap byte storage is a `ManagedBuffer<EmptyHeader, UInt8>` by descriptor). **Blocked on [176](tasks/176-shaped-gc-roots.md) 176.3** — a `String` held by value inside a `struct`/`enum` (and `struct String { let base: StringBase }` is itself one) is miscompiled across a moving GC until 176.3 frame-root placement lands; discovered when starting 121.1.1. Then: `StringBase` primitive + wrapper (121.1.1) → literal lowering (121.1.2) → heap path on the `ManagedBuffer` primitive (121.1.3) → migrate surface into Nomu `String` (121.1.4) → retire builtin `.string`/`strTy` (121.1.5) |
| 122 | [Numeric semantics + overflow](tasks/122-numeric-semantics.md) | Usability | M | needs-design |
| 123 | [Copy-on-write for value collections](tasks/123-copy-on-write.md) | Usability | M | needs-design |
| 124 | [Generic hash map](tasks/124-generic-hashmap.md) | Usability | M | blocked (D6 spill) |
| 125 | [Unsafe raw memory / raw pointers](tasks/125-unsafe-raw-memory.md) | Risk | L | built (minimal floor) — `RawPtr`/`Ptr<T>`, `internals/unsafe-memory.md`; first prereq of self-hosted runtime 128 |
| 126 | [SIMD](tasks/126-simd.md) | Usability | L | needs-design |
| 180 | [Managed tail-allocated buffer](tasks/180-managed-buffer.md) | Usability | L | done — 180.1–180.4 built + green (suite 125/125): the generalized buffer descriptor, header-aware geometry across all three collectors, the `ManagedBuffer<Header, Element>` type + tail-alloc primitive + typed reference accessors (`storeRef`/`ref`, `storeHeaderRef`/`headerRef`), and String's heap byte buffer re-keyed onto the shared buffer descriptor (180.4). Follow-ons tracked elsewhere: `Array`-buffer migration + ad-hoc kind-1 machinery retirement is [181](tasks/181-array-managed-buffer.md); the residual `stringStorageTypeId` / `__nomu_stringstorage_typeid` symbol retirement rides [121](tasks/121-string-utf8-model.md) 121.1.3 |
| 181 | [Array buffer onto `ManagedBuffer`](tasks/181-array-managed-buffer.md) | Infra | M | ready-to-build — migrate `Array`'s backing buffer onto `ManagedBuffer<EmptyHeader, T>` and retire the ad-hoc kind-1 machinery (`registerArrayMap` / `arrayBufTypeId` / `arrayElemStride`), leaving one buffer-descriptor path. Carries a real layout change (`Array<small-scalar>` 8-slot → packed stride) and its own differential baseline. Split out of [180](tasks/180-managed-buffer.md) 180.4; depends on 180 |

### Runtime perf & the risk bets

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 127 | [LXR collector (footprint endgame)](tasks/127-lxr-collector.md) | Risk | XL | final rung of the self-hosted GC ladder (after 150's GenImmix) |
| 128 | [Self-hosting the runtime](tasks/128-self-hosting-runtime.md) | Risk | XL | build now — core bet; decomposes into 125 → 149 → 150 → 127 |
| 149 | [Runtime-subset mechanism](tasks/149-runtime-subset.md) | Risk | M | in-progress — slice 1 built (runtime-prelude "designated file" + flag; call-graph closure check, `internals/runtime-subset.md`); remaining: codegen guards, `nosplit`, module designation |
| 150 | [Self-hosted GC bring-up ladder](tasks/150-selfhosted-gc-ladder.md) | Risk | XL | in-progress — **NoGC→mark-verify→Immix→GenImmix all complete**; GenImmix (150.4) generational on by default, full suite green single- and multi-carrier vs the MMTk GenImmix oracle; correctness-complete, unbenchmarked. Next: perf-benchmark vs MMTk (→ 158/159), then MMTk retirement, then 127 LXR |
| 158 | [GC packaging — self-contained collector plans behind one trigger protocol](tasks/158-gc-packaging.md) | Risk | L | needs-design (do with GC-benchmarking step) — package each GC as allocator+collector+coordinator+triggers; shared trigger→request protocol + "no trigger fires into a void" invariant, per-plan coordinator (STW shared among tracing plans, concurrent for LXR); removes the 150.4.5.3 interim gate; GC share of 157 lands here |
| 159 | [GC observability — structured collection tracing, stats, pause timing](tasks/159-gc-observability.md) | Risk | M | needs-design (pairs with GC-benchmarking step) — per-collection stats record, phase tracing (collector stack is not unwindable), pause distribution, space occupancy; one gated trace facility (not a knob per site); feeds step-3 benchmarking + 155 `--json`; durable form of the 150.4.5.3 debug scaffold |
| 129 | [Tail-call optimization](tasks/129-tail-call-optimization.md) | Usability | M | needs-design |
| 130 | [First-class FFI to the C ABI](tasks/130-ffi-c-abi.md) | Usability | L | needs-design |
| 131 | [Shared-mutable primitive](tasks/131-shared-mutable-primitive.md) | Risk | M | ongoing |
| 132 | [`shared` function-type / existential spellings](tasks/132-shared-spellings.md) | Infra | S | ready-to-build (trigger-gated) |
| 133 | [Fiber-pinned mutator cache](tasks/133-fiber-pinned-mutator-cache.md) | Infra | S | needs-grounding |
| 134 | [MLIR consideration](tasks/134-mlir-consideration.md) | Infra | S | evaluate |
| 148 | [SSAIR optimizer tier](tasks/148-ssair-optimizer-tier.md) | Risk | L | mostly-shipped (tails open) |
| 176 | [Shaped GC roots — value-conditional scanning + frame-root relocation](tasks/176-shaped-gc-roots.md) | Risk | L | in-progress — decouples rooting/placement from `addrspace(1)` so a managed pointer can be tag-discriminated or stack-placed. **On the strings critical path.** 176.1 conditional tracing + 176.2 relocation takeover **built + green** for a bare `String` (local and class/actor field). **Remaining: 176.3 — frame-root placement for value aggregates holding shaped content** (a `struct` with a `String` field, an `enum` with a `String` payload like `Option<String>`): a correctness gap today and a compiler law; strings rest on it (corrects the prior belief that strings needed only 176.1+176.2). Staged 176.3a (structs, codegen-only) → 176.3b (enums, descriptor + both-collector). 176.4 = the separate 148 §148.1/179 escape-promotion placement route. Both collectors in lockstep |
| 177 | [Register-resident GC roots](tasks/177-register-resident-gc-roots.md) | Risk | M | needs-evaluation (measurement-gated) — reduce the moving-GC root tax by keeping roots in registers across safepoints instead of spilling. 177.1 evaluate LLVM's `max-registers-for-gc-values` lever for ordinary `addrspace(1)` roots (baseline: current N=0 spill/reload) → 177.2 (gated on a win) extend register-residence to shaped roots (176). Independent of 176 landing; runs with the GC-benchmarking step (155/159) |
| 178 | [Runtime / GC performance](tasks/178-runtime-gc-performance.md) | Risk | L | open bucket — collector + mutator-runtime throughput line items (object scan/trace, root scan, reclamation; inlined alloc/barrier/poll), tuned against the GC-benchmarking step. The mid-end's 148 analog for the runtime floor; distinct from 150 (correctness), 158 (packaging), 159 (measurement), 177 (root-tax lever). Seed item 178.1: shaped-scan trace speed — the 176 enumerator must keep the kind-0 flat scan at current cost |
| 179 | [Value-level GC-pointer classification — GC residency off `addrspace`](tasks/179-value-level-gc-classification.md) | Risk | XL | direction chosen (option A of 4), **build not committed** — gated on move 1 (payoff measurement, net of 176's side path) + move 2 (RS4GC-fork spike). Takes GC-managedness off the `addrspace(1)` biconditional: repurpose `addrspace(1)`→"may be a managed reference, do not launder" (keep `ni`), move classification to a value-set fed to a forked `isGCManagedValue` predicate before RS4GC. Dissolves the conditionally-managed-pointer ABI wall and the addrspace-across-calls stack-promotion wall (owns 148 §148.1's placement mechanism; 179.5 closes that consumption). Broader alternative to [176](tasks/176-shaped-gc-roots.md) (the no-RS4GC-fork piggyback); beat B/C/D on runtime. Staged behind an equivalence oracle (179.1). Rides the done inference stack (169/166/168/164); both collectors |

### Tooling, modules, macros

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 100 | [Modules + multi-file compilation](tasks/100-modules.md) | Infra | XL | in-progress — the separate-compilation model: 100.1 (multi-file), 100.2 (multi-module surface), 100.4 (separate compilation + per-module objects + link + cross-module generics + GC type-ids) **done**; 100.5 (the `--mono` specialization dial) remaining. Spun out: packaging + driver CLI → 173, prelude-as-packages → 174, cross-module-generics residuals → 171, incremental build cache → 172, suite migration → 155. Contract in [`language/modules.md`](../language/modules.md); release threshold → 145 |
| 171 | [Modules cleanup — cross-module generics residuals](tasks/171-modules-cleanup.md) | Infra | M | ready-to-build (mixed) — home for §100.4.3's deferred edges: bounded field requirement dispatch on a generic class (171.1), bounded-dispatch conformer gaps (actor / covariant-`Self` / producer-exported witnesses, 171.2), erased-`T` GC typed-root corners (171.3), non-POD erased-field-write barrier (171.4), diagnostic clarifications (171.5), public-only erased-emission gate (171.6). Method-own type params stay in 170 |
| 173 | [Package model, manifest + driver CLI](tasks/173-package-model-driver-cli.md) | Infra | L | needs-design (partial) — pulled out of 100 §100.3.1–.6; JSON manifest + schema, package/workspace/identity, seal enforcement (+ cross-package `package` tier + qualifier), entry points / `bin` / init order, and the `compile`/`build`/`run`/`test`/`query` single-binary driver. A layer around the compiler; name-only manifest already loads. Deliverable: `nomuc build/run/test` on a multi-bin package |
| 174 | [Prelude as packages](tasks/174-prelude-as-packages.md) | Infra | L | needs-design — pulled out of 100 §100.3.7 + its Mini-horizon; `core`/`runtime`/`std` compiled once and referenced, retiring `prependPrelude` + the `WeakODR` per-object duplication (the 100.4.4 interim). Its three prerequisites (100.4.1/.3/.7) are now done; couples with 149 (runtime-subset by module membership). Reaches into resolution/codegen/linkage |
| 160 | [Resource embedding (compile-time embed + explicit manifest include)](tasks/160-resource-embedding.md) | Usability | M | needs-design — split from 100; native-embed model, explicit manifest `include` lean |
| 161 | [Test framework — case designation + runner](tasks/161-test-framework.md) | Usability | M | needs-design — module-level test identity settled in 100; `@test` case marking, runner, assertions open |
| 162 | [Interface / IR serialization format — optimization](tasks/162-interface-serialization-opt.md) | Infra | M | needs-design — v1 bespoke binary decided in 100; zero-copy/mmap, interning, varint, lazy reads deferred here |
| 163 | [Manifest format — JSON → YAML](tasks/163-manifest-yaml.md) | Usability | S | needs-design — JSON ships first (dependency-free in Swift); switch to a human-friendly YAML/StrictYAML/KDL later |
| 164 | [Formal inference stage + post-inference `.nmi`](tasks/164-formal-inference-stage.md) | Infra | L | **done** (94/94) — the **integration** task after the infra splits (166/167/168/169): 164.1 **done** (fact-store Sema writers, mutating-ness) → 164.2 **done** (inference-phase escape summary into the store, inference now a real pipeline phase) → 164.3 **folded into 164.4** → 164.4.1 **done** (store-sourced emit — mutating-ness in the `.nmi`, task B) → 164.4.2 **done** (sectioned `.nmi`, independent ABI/perf hashes) → 164.4.3 **done** (per-definition erased-body escape summary in the perf section) → 164.6 **done** (cross-module seeding — published `.nmi` escape facts account for imported callees via an `external:` provider seeded topologically through `depEscape`). 164.5 (promotion reads the summary in codegen) **moved to 148 §148.1** — blocked on the addrspace-across-calls placement decision, which is optimizer-tier work. Precedes the build cache (172). Prereqs: 165 (done), 166/167/168/169 (done) |
| 165 | [Mid-end pipeline prefactor](tasks/165-midend-pipeline-prefactor.md) | Infra | M | **done** (green 94/94, uncommitted) — pipeline lift out of `emitObject` into the driver (165.1) + escape analysis/transform separation (165.2); the behavior-preserving prerequisite that unblocks 164 |
| 166 | [Points-to / reachability graph builder](tasks/166-points-to-graph.md) | Infra | L | analysis complete — 166.1–166.3 done + green (graph + faithful escape query + differential validation, 94/94); 166.4 precise query built + subset-validated but its extra promotion is deferred to 148 (trips the I4 GC-precision contract) |
| 167 | [Fact store](tasks/167-fact-store.md) | Infra | M | **done** (green, uncommitted) — independent infra split out of 164; per-symbol sectioned records, deterministic independent ABI/perf hashing, two-writer API; property-tested standalone in `src/facts`. Design in [`internals/inference.md`](../internals/inference.md) ("Fact store") |
| 168 | [SCC / interprocedural fixpoint engine](tasks/168-scc-fixpoint-engine.md) | Infra | M | **done** (green, uncommitted) — stage/scope-agnostic SCC solver in `src/inference` (iterative Tarjan, lattice + transfer + provider); mutating-ness ported onto it, behavior-preserving (suite 94/94). Closed-world join + whole-program driver deferred. Design in [`internals/inference.md`](../internals/inference.md) |
| 169 | [Interprocedural escape summary](tasks/169-interprocedural-escape-summary.md) | Infra | L | **done** (green, uncommitted) — Level-1 floor: projects the 166 graph into a per-function escape summary + call-site compose via the 168 engine, written into 167's perf section (`InterprocEscape.swift`); summary-level oracle. intoReturn/intoParam + k≥2 field summary deferred. End-to-end consumption is 164/148 |
| 172 | [Incremental build cache (content-addressed, module-granular)](tasks/172-incremental-build-cache.md) | Infra | L | needs-design (wants real design time) — pulled out of 100 §100.4.5/.6; persistent content-addressed module-granular cache + stability/correctness harness. Spine is 164.4.2's ABI/perf hash split (body/perf edit → recompile self only; ABI edit → cascade). Store generalizes the content-addressed runtime archive. Foundation 136 builds on at finer granularity |
| 175 | [Inference summary observability](tasks/175-inference-observability.md) | Usability | M | needs-design (build-dir emit near ready) — surface the inferred per-function summaries (escape/placement, mutating-ness, shareability, cross-fiber reachability) the inference stack already computes: `--emit-inference` build-dir artifact + `dump-inference` first (175.1/.2), source-span keying (175.3) then LSP inlay-hints/hover (175.4, needs 137), differential golden (175.5). A window into the inferred, source-invisible memory/concurrency behavior. Rides 164/167/169 (done) |
| 136 | [Incremental compilation](tasks/136-incremental-compilation.md) | Infra | L | needs-design — fine-grained / query-based successor to the module-granular cache (172); recompute sub-module units + cached monomorphizations, feeds LSP; downstream of 142 |
| 137 | [Tooling — query server / LSP / formatter (M10)](tasks/137-tooling-lsp-formatter.md) | Usability | L | needs-design |
| 138 | [Debugger (M11)](tasks/138-debugger.md) | Usability | L | needs-design |
| 139 | [Memory debugging / heap introspection](tasks/139-memory-heap-introspection.md) | Usability | M | evaluate |
| 140 | [Macros (M13)](tasks/140-macros.md) | Usability | L | needs-design |
| 141 | [`comptime`](tasks/141-comptime.md) | Usability | L | needs-design |

### Compiler infra / hardening / perf

| # | Task | Avenue | Size | Status |
| --- | --- | --- | --- | --- |
| 142 | [IR + pipeline-boundary hardening](tasks/142-ir-pipeline-hardening.md) | Infra | M | needs-design (► decide-early: format w/ M7) |
| 143 | [Parser / frontend error recovery](tasks/143-parser-error-recovery.md) | Usability | M | shipped (continue-into-Sema tail → 137) |
| 144 | [Frontend perf (interning, lexer, streaming)](tasks/144-frontend-perf.md) | Infra | M | needs-grounding |
| 145 | [Monomorphization cost model](tasks/145-monomorphization-cost.md) | Infra | S | evaluate |
| 146 | [Author the `language/` contract tier](tasks/146-language-contract-tier.md) | Infra | M | in-progress |
| 147 | [Compiler cleanups (bucket)](tasks/147-compiler-cleanups.md) | Infra | S | ready-to-build |
| 153 | [Lexical scoping of locals in SSAIRGen](tasks/153-ssairgen-lexical-scoping.md) | Infra | M | ready-to-build — crash sub-case fixed (`bind` clears cross-kind); shadow-leak open |
| 154 | [Source-tree decomposition (large-file grokkability)](tasks/154-source-tree-decomposition.md) | Infra | L | in-progress — 154.1 Sema underway (3099→2002, 5 capabilities extracted, golden-verified); 154.2 SSAIRGen / 154.3 SSAIRToLLVM / 154.4 Parser pending |
| 155 | [Integration-suite harness (one entry, rich output, source-declared env)](tasks/155-integration-suite-harness.md) | Infra | L | Phase 1 (MVP) built + green — zero-dep Swift runner + central JSON manifest; later axes: release/debug mode, perf gate, and the **1 dir == 1 module suite migration** (folded in from the old 100.3.8); replaces 60+ ad-hoc `tools/*.sh` |
| 156 | [Differential stage-diffing (`nomuc-diff` vs a git-ref baseline)](tasks/156-differential-stage-diffing.md) | Infra | L | needs-design (build-soon) — every pipeline stage differentiable against a baseline ref; refactor-fearlessly proof; systematizes `tools/ir-golden.sh`; builds on 142 + 155 |
| 157 | [Env-var audit — collapse the `NOMU_*` surface](tasks/157-env-var-audit.md) | Infra | M | needs-design — ~2 dozen `NOMU_*` vars grew unchecked; internalize/remove nearly all, one product lever (`NOMU_RUNTIME`), codegen flags → `--flags`, test knobs → 155 fixtures; the GC-lever share lands in 158/159; ties to 155 + 150.4.5 |

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
