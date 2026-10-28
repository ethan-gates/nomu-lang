# One inference phase per module — one lowering, one module inference

**Avenue:** Infra · **Type/Lifecycle:** `infra · perf · needs-design` (driver + mid-end) · **Size:** M ·
**Status:** done (202.1–202.4) · **Source:** [190](190-explicit-module-builds.md) 190.6 F20 (the cost
of every library job writing its `.nmi`), measured and moved here.

Terms are those of [`inference.md` §Terms](../../internals/inference.md#terms): module inference, inference
results, a declaration's results, escape result, dependency results, published results, local results.

## Deliverable

Each module is lowered once, and module inference runs once over that lowering, seeded with its
dependency results. Its inference results go into the fact store; stack promotion (later, 148.1) and the
`.nmi` both read them from there, as `inference.md` §Fact store already describes.

## Before 202.2

A library job (every module except the entry) lowers its module to SSA twice and computes escape results
twice:

1. **For the `.nmi`** (`escapePerfSection`, `CompileSupport.swift`): lowers the pre-monomorphization module,
   computes escape results seeded with dependency results (the `external` parameter of
   `computeEscapeSummaries`), converts them to one result per definition (`perDefinitionEscapeSummaries`)
   and keeps the public surface's. These are the published results.
2. **For codegen** (`CompileJob.swift`, the `ssair/inference` timing): lowers the monomorphized module and
   computes escape results again, without dependency results, into the fact store. Nothing reads them:
   `StackPromotion` uses the intraprocedural `escapingValues`, and reading the stored results is 148.1.

The `--emit-nmi` debug path runs (1) as well. Binary jobs run only (2).

**Measured** (`std_module_import`, cold host cache, `-c opt` compiler, three runs): the `.nmi` escape step
of the `runtime` module (163 KB of source) takes 165–176 ms, about 20% of an 850 ms build; each `std`
module's takes 0.04–0.35 ms; serializing and writing a `.nmi` takes under 1 ms. The `interface` timings
(`escape`, `serialize`, `write`) stay in the build's timing table to measure this task.

## Work

- **202.1 — what the one lowering must provide.** Two questions decide the shape:
  - Does the monomorphized lowering give a non-generic surface function the same escape result as the
    pre-monomorphization lowering gives? If so, its published result reads straight from the store.
  - A public generic's published result is computed over its erased body, which the monomorphized
    lowering does not contain. What is the least work that yields it: lowering only the public generics
    in erased form, or deriving it from what the one lowering already holds? Count how many generics the
    `runtime` and `std` surfaces export, to size this.

  **Findings.**
  - The monomorphized lowering already holds every public generic in erased form. `monomorphize` emits each
    exported generic function erased under its bare symbol, and each generic type's template with its
    methods, which lower erased. So both kinds of published result can come from the one lowering, with no
    separate erased lowering.
  - On the fast suite (321 cases, every library job), the published results from the monomorphized lowering,
    seeded with the same dependency results, equal today's on every surface declaration: 115 of 115, 38 of
    them generic. No declaration was present in one and absent from the other.
  - `std` exports two generics (`Option`, `Result`), both without methods, so no generic escape result.
    `runtime` exports nothing: its `.nmi` perf section is empty, so its escape step (~170 ms, ~20% of a cold
    build) publishes no result. Its functions are reached by bare name from compiler-inserted calls, which
    no published result keys.
  - The cost of one lowering is ordering. Today the `.nmi` is written after sema, before mono. Read from
    the monomorphized lowering, the published results are ready only after mono, the lowering and module
    inference. This sets 217's interface boundary (its open question 1).

  **Shapes considered.**
  - *A: publish from the monomorphized lowering.* Codegen's lowering and module inference, now seeded
    with dependency results, write the store; the `.nmi` perf section reads it. One lowering, one inference.
    The `.nmi` is written after inference.
  - *B: keep the pre-mono lowering for publishing and drop codegen's inference.* Removes the duplicate
    inference today, but 148.1 needs results over the monomorphized lowering, which brings the second
    lowering back.
  - *C: shape A, with the `.nmi` written in two parts:* the ABI section and the `.bir` after sema as today
    (what a consumer's sema and mono read), and the perf section after inference (what a consumer's
    inference reads). A consumer's front end can then start before its dependency's lowering finishes. This
    is a 217 decision (one artifact with sections that become ready at different times); 202 needs only A's
    single source of results.

  **Decision: A.** B only defers the second lowering, which 148.1 brings back. Codegen needs the
  monomorphized lowering, so a pre-mono lowering cannot be the only one, and computing escape results from
  NOIR would mean a second analysis to keep in step with the SSA one. C refines A and is left to 217.

- **202.2 — one lowering, one module inference.** Lower once; run module inference once, seeded with
  dependency results, writing escape results into the fact store; assemble the published results from the
  store. Remove the separate `.nmi` lowering (`escapePerfSection`) and codegen's second escape
  computation. The `--emit-nmi` debug path uses the same results.

  **Done.** Codegen's module inference is seeded with the dependency results; the `.nmi` is written after
  it, its perf section read from the fact store (`escapePerfSection(_:from:)`); the pre-mono lowering is
  gone. The `.bir` is still written after sema. `--emit-nmi` now runs through mono and the lowering before
  it stops. Checked: fast suite (321) green; `build_tests`, `job_key_tests`, `interface_tests`,
  `ssairpasses_tests`, `planner_tests` green; `--check-reproducible` 1427 outputs identical; every suite
  fixture built with the old and the new compiler gives byte-identical `.nmi` files (83 files, 135
  published results). On a cold `std_module_import` build the `interface` phase went from ~180 ms to
  ~2 ms and the build from ~1.9 s to ~1.7 s; `runtime`'s module inference itself is ~3 ms, so the cost
  removed was the second lowering.
- **202.3 — names.** Rename the code to the terms: the `external` parameter, `externalEscape()`,
  `externalEscapeKeys`, `deps.escape`, `escapePerfSection`, `perDefinitionEscapeSummaries`, and the
  `ssair/inference` and `interface/escape` timing labels. Update `inference.md`'s older "summary" text.

  **Done.** `computeEscapeSummaries(dependencyResults:)`, `dependencyResults()`,
  `publishedResultsByCallName`, `deps.publishedResults`, `publishedResults(_:from:)`,
  `perDefinitionEscapeResults`; the timing label `inference/module` (`interface/escape` went with 202.2).
  `inference.md` says "escape result" where it meant one declaration's summary and keeps "summary" for the
  technique and the section names other docs link to. `EscapeSummary`, `computeEscapeSummaries` and
  `writeEscapeSummaries` keep their names.
- **202.4 — verify.** Full suite and unit tests green, plan goldens unchanged, published results
  byte-identical to today's on the suite's `.nmi` files (or each difference explained), and the `runtime`
  module's escape cost gone from the `interface` timings.

  **Done.** Full suite (732) and fast suite (321) green; `build_tests`, `job_key_tests`, `interface_tests`,
  `ssairpasses_tests` green; `planner_tests` green, so plan goldens unchanged; `--check-reproducible` 1427
  outputs identical; `.nmi` files byte-identical to the old compiler's on every suite fixture (202.2); the
  `interface` phase fell from ~180 ms to ~2 ms on a cold build.

## Depends on / dependents

- **148 §148.1** (promotion reads the escape result) depends on this: its wiring becomes passing a
  store-backed provider to `StackPromotion`.
- **[217](217-build-graph-granularity.md)** (interface and object actions) depends on this: the one lowering
  fixes where the interface boundary sits.
- Parametric results (`inference.md` §Terms) stay out of scope; they change the escape result's shape,
  not the phase structure.

## Refs

`inference.md` §Terms, §Summary and composition, §Fact store; [164](164-formal-inference-stage.md)
(the inference stage and `.nmi` perf section), [169](169-interprocedural-escape-summary.md) (escape
summary), [167](167-fact-store.md) (fact store); `src/driver/sources/CompileJob.swift` (library publish
block, codegen inference step), `src/driver/sources/CompileSupport.swift` (`escapePerfSection`,
`externalEscapeKeys`), `src/midend/ssairpasses/sources/InterprocEscape.swift`.
