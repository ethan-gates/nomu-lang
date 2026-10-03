# Mid-end pipeline prefactor — explicit stages + analysis/transform separation

**Avenue:** Infra (compiler architecture) · **Type/Lifecycle:** `refactor · midend` · **Size:** M ·
**Status:** done — **165.1 + 165.2 landed** (green 94/94, uncommitted). Unblocks
[164](164-formal-inference-stage.md).

## What

Two behavior-preserving restructurings of the existing mid-end, with no new data model and no new
analysis. The suite stays **94/94 green at every step** — this moves code, it does not change behavior.
Together they shrink [164](164-formal-inference-stage.md) to its new-work core (the fact store, the
points-to engine, the summary, the `.nmi` sectioning) by lifting the surrounding plumbing out first.

The work is tracked as two independent sub-tasks, **165.1** (pipeline lift) and **165.2** (escape
analysis/transform separation), each with its own numbered steps.

## Why

[164](164-formal-inference-stage.md) interposes a new inference stage between `ssairgen` and the
transforms, and turns escape into a store-backed analysis the promotion transform consumes. Neither is
possible while the pipeline is welded inside `LLVMBridge.emitObject` and escape is computed inline by the
transform. These two prerequisites are pure refactors, so they are separated here to carry no design risk
and to keep 164 focused on the engine.

## 165.1 — Lift the pass pipeline out of `emitObject` into the driver — done

Landed (green 94/94, uncommitted): `emitObject` now takes a gen'd `SSAModule` + the source `NOIRModule`
and lowers it; the driver gens the SSA (`lowerToSSAIR`) and sequences gen → `emitObject`, with the
inference + `.nmi`-emit interposition point now sitting between them in both the entry (`emitLLVMBinary`)
and dependency (`compileDependency`) paths. 165.1.1–165.1.3 below are all covered.

Today `LLVMBridge.emitObject` welds together `lowerToSSAIR` → the `PassPipeline` → `SSAIRToLLVM` → object
emission. Make those discrete stages the driver sequences, so the driver owns the ordering and can later
interpose the inference stage and `.nmi` emit between gen and transforms. `emitObject` shrinks to "take
post-inference SSA and lower it to an object."

- **165.1.1 — Stage the entry path.** Lift gen → passes → egress → object emit out of `emitObject` so the
  driver (`emitLLVMBinary`) sequences them; `emitObject` reduces to lowering post-transform SSA. The
  `--emit-ssair` debug path (already calling `lowerToSSAIR` in the driver) is the partial precedent this
  generalizes.
- **165.1.2 — Stage the dependency path.** Apply the identical restructure to `compileDependency`, which
  calls `emitObject` directly, so both compile paths sequence the stages the same way.
- **165.1.3 — Preserve timing.** The `ssair`/`llvm` sub-stage `StageSink` records continue to report up
  (`Timings`), now from the driver's sequencing rather than from inside `emitObject`.

Exit: gen, passes, egress, and object emit run in the same order with the same inputs — only the
orchestration site moves — and the suite is green `-c opt`.

## 165.2 — Separate the escape analysis from the promotion transform — done

Landed (green 94/94, uncommitted). `escapingValues` + its helpers stay in `EscapeAnalysis.swift` as the
analysis; the `StackPromotion` transform moved to its own `StackPromotion.swift` and now consumes an
injected escape provider instead of calling the analysis itself.

- **165.2.1 — escape has a standalone home.** `EscapeAnalysis.swift` is the analysis only
  (`escapingValues`, `escapingUses`, `escapingTermUses`); the transform no longer shares its file.
- **165.2.2 — `StackPromotion` is a consumer.** It holds an `escaping: (SSAFunction) -> Set<Int>`
  provider (default: the standalone `escapingValues`), so the fact is injected rather than computed
  inline. Task 164 passes a store-backed provider here with the transform body unchanged. `ScalarPromotion`
  keeps its own φ-web-local escape (a transform-internal notion over web members, not the shared
  `escapingValues` fact), so it is out of this split.

Exit met: escape feeds stack promotion → GC root precision; built `-c opt`, suite 94/94 green including
the GC-stress fixtures, with no change to the promoted set. The `ssairpasses` unit tests pass.

## Standing invariant

Each sub-task lands green on its own. No functional change to reason about — the suite is the guard, and
the `nomuc` md5 before/after a pure-refactor commit is a sanity check (behavior-identical object for an
unchanged input is the goal, though timing/orchestration changes may perturb it; the suite is the real
gate).

## Relationship to existing tasks

- [164 formal inference stage](164-formal-inference-stage.md) — the consumer. **165.1** is its
  build-outline pipeline-lift prerequisite; **165.2** is the separation half of its escape migration
  (step 6). Both move here.
- [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) — owns the stage-3 transforms whose escape
  input 165.2 cleans up.
- Inference design home: [`internals/inference.md`](../../internals/inference.md).

## Sequencing

Precedes [164](164-formal-inference-stage.md). **165.1** and **165.2** are independent and can land in
either order; 165.1 is the larger plumbing change, 165.2 the smaller but regression-sensitive one.
