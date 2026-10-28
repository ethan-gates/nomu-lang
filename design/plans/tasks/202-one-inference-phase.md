# One inference phase per module — one lowering, one module inference

**Avenue:** Infra · **Type/Lifecycle:** `infra · perf · needs-design` (driver + mid-end) · **Size:** M ·
**Status:** needs-design (202.1) · **Source:** [190](190-explicit-module-builds.md) 190.6 F20 (the cost
of every library job writing its `.nmi`), measured and moved here.

Terms are those of [`inference.md` §Terms](../../internals/inference.md#terms): module inference, inference
results, a declaration's results, escape result, dependency results, published results, local results.

## Deliverable

Each module is lowered once, and module inference runs once over that lowering, seeded with its
dependency results. Its inference results go into the fact store; stack promotion (later, 148.1) and the
`.nmi` both read them from there, as `inference.md` §Fact store already describes.

## Today

A library job (every module except the entry) lowers its module to SSA twice and computes escape results
twice:

1. **For the `.nmi`** (`escapePerfSection`, `Driver.swift`): lowers the pre-monomorphization module,
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
- **202.2 — one lowering, one module inference.** Lower once; run module inference once, seeded with
  dependency results, writing escape results into the fact store; assemble the published results from the
  store. Remove the separate `.nmi` lowering (`escapePerfSection`) and codegen's second escape
  computation. The `--emit-nmi` debug path uses the same results.
- **202.3 — names.** Rename the code to the terms: the `external` parameter, `externalEscape()`,
  `externalEscapeKeys`, `deps.escape`, `escapePerfSection`, `perDefinitionEscapeSummaries`, and the
  `ssair/inference` and `interface/escape` timing labels. Update `inference.md`'s older "summary" text.
- **202.4 — verify.** Full suite and unit tests green, plan goldens unchanged, published results
  byte-identical to today's on the suite's `.nmi` files (or each difference explained), and the `runtime`
  module's escape cost gone from the `interface` timings.

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
block, codegen inference step), `src/driver/sources/Driver.swift` (`escapePerfSection`,
`externalEscapeKeys`), `src/midend/ssairpasses/sources/InterprocEscape.swift`.
