# Formal inference stage + post-inference interface generation

**Avenue:** Infra (compiler architecture) · **Type/Lifecycle:** `refactor · midend` · **Size:** L ·
**Status:** build-soon — substrate design settled in [`internals/inference.md`](../../internals/inference.md);
behavior-preserving prerequisite is [165](165-midend-pipeline-prefactor.md).

## What

Make **inference a first-class compiler stage** rather than a set of per-pass add-ons, and move **module
interface (`.nmi`) generation to run after it**. Split the single mid-end IR stage into four roles with a
clean ordering, and emit the interface between inference and transforms:

```
gen (ssairgen)  →  inference (analyses → fact store)  →  emit .nmi  →  transforms  →  verify  →  lower (SSAIRToLLVM + LLVM)
```

That arrow is a **time** ordering. The **data** flow is a hub: inference's output is the in-memory fact
store, and two consumers read it independently.

```
deps' .nmi ─┐
            ▼
raw SSAIR ─► inference ─► fact store ─┬─► emit this module's .nmi   (leaf: dependents + cache)
                                      └─► transforms ─► verify ─► lower
```

Inference produces per-symbol **summaries** into the fact store; the `.nmi` is assembled once from that
store plus the declaration surface; transforms and lowering read the store, never the file. The `.nmi`
plays at both ends of the module boundary — a dependency's published summaries seed this module's
interprocedural fixpoint (input), and this module's summaries are published (output) — so within one
compilation it is boundary I/O, never an intermediary between inference and the transforms. Emit is
ordered ahead of the transforms so the published summary describes the raw, canonical body and stays
invariant to optimization level (the byte-stability the incremental cache needs).

## Why

Nomu's core bet is that meaningful facts about code — ownership, lifetime, fiber locality, sharing,
cross-fiber reachability, mutating-ness, escape — are *inferred* rather than annotated. The facts a
module must hand a consumer to compile correctly and fast are therefore the inferred ones. That makes
the `.nmi` a **serialization of inference results**, which forces two things:

- Interface generation is inherently **post-inference**. It runs on the AST today (`buildInterface`,
  pre-Sema), so it is upstream of every fact it needs to carry. That is the misalignment.
- Inference needs to be a real subsystem — a uniform engine with summaries and an interprocedural
  fixpoint — not a fact each optimization pass happens to discover as a byproduct. The clearest symptom:
  escape today exists only *as* the stack/scalar-promotion transforms, so the escape fact can't be had
  without running the optimizer.

Doing this now, before incremental caching ([100](100-modules.md) §100.4.5/4.6) pins the `.nmi` format
and the rebuild-on-changed-facts rule, is the cheap time. It unblocks the valuable remaining module
tracks: incremental compilation, and every inferred fact crossing the boundary.

## The `.nmi` as a one-way immutable channel

Pinned properties (agreed):

- **Produced once, complete, immutable.** Never a partially-built object threaded through stages and
  stamped. The in-flight mutable state is the internal fact store; the file is assembled once from it.
- **One file**, not a soundness file plus a perf file. Downstream reads a single artifact.
- **Content may vary by the source module's compiler flags** (e.g. `--mono=never` → no specialization
  section). Flags determine what is collected; the file is still produced once and complete for what
  this compilation computed (a full build writes ABI + perf; an interface-only compile writes ABI alone).
- **Sectioned with independent hashes.** An ABI/soundness section and a perf section. A body edit that
  changes perf facts but not the ABI must leave the ABI section byte-identical, so a debug dependent that
  consumed only the ABI stays cached (the 100.4.6 incrementality goal under one file).
- **Build-internal, not a distribution format.** Libraries are distributed as source, so the `.nmi` is
  only ever read within a single build; it evolves freely build to build and stays byte-stable within a
  build for the incremental cache (`internals/inference.md`, scope-agnostic engine).

## Where the emit sits, and why after ssairgen

Two facts decide the emit point:

- **No inference fact requires SSA.** SSA is a re-encoding of the CFG — it precomputes reaching
  definitions and makes merges explicit as φ, adding no information the CFG doesn't already determine.
  So "requires SSAIR" reduces to "needs reaching-definition information," a build-vs-reuse question.
  The only genuine SSA consumer is a *transform* (scalar promotion's φ-web decomposition), which lives in
  stage 3.
- **ssairgen's cost (≈60–80% of the stage) is largely that SSA/reaching-def construction**, which is
  exactly what the value-flow analyses consume. Running inference *before* ssairgen on NOIR would rebuild
  that structure, emit, then let ssairgen build it again — the expensive work twice for a marginally
  earlier emit. Running inference *after* ssairgen on raw, un-transformed SSA reuses the construction and
  pays once.

So: build SSA once (gen), run inference on the raw SSA (reusing its def-use), emit, then run the
transforms. Downstream unblocks at gen+inference-complete, just past the cost that was unavoidable.

**Standing invariant:** a *soundness* fact must never be computed later than the inference stage. Every
soundness fact today is end-of-Sema; every perf fact is end-of-inference; nothing an interface needs is
produced by `SSAIRToLLVM` or LLVM. If a future inference is both soundness-relevant and inherently later,
it breaks this model — name it before adopting it.

**Resolved — raw SSA is the substrate.** Measurement: `ssair:gen` is a fixed ≈98 ms (the prelude +
runtime prelude lowered; a bare `main` pays it in full, user code adds a few ms), ≈79% of mid-end wall
time (parse + noir + ssair). The sub-timing split the earlier note asked for turns out to be ill-posed:
the Braun SSA construction (`read`/`write`/`readRecursive`/`seal`/`newParam` in `FunctionLowerer`) is
interleaved into the single NOIR→SSA tree walk, so the def-use / reaching-def structure is a byproduct of
emitting each instruction — there are no two phases to time apart. That interleaving settles the
substrate: the reaching-def structure every value-flow analysis consumes is exactly what the walk
materializes into SSA, verified. Inference on NOIR would rebuild that structure, then ssairgen rebuilds
it; inference on raw post-ssairgen SSA reads it once. One analysis substrate also keeps any single
analysis in one place.

## The fact store

- **Per-symbol, structured summaries** keyed by a stable symbol id (mangled name is the natural
  candidate — already stable across producer and consumer). Not scalar flags: shareable-requirement is
  per-parameter, escape is per-param/return, stack-depth is per-function.
- **Two writers.** Cheap structural/scan facts (mutating-ness, type shareability) stay in Sema, where
  they already run, and write into the store. The inference stage adds the value-flow facts. The emit
  reads the whole store.
- **Interprocedural fixpoint.** Mutating-ness, shareable-requirement, and interprocedural escape are
  caller-relevant facts derived from bodies via a call-graph (SCC) fixpoint, **seeded by dependencies'
  summaries** read from their `.nmi`. The build stays topological. This is also the fixpoint the docs
  already flag as gating intra-module parallel body-checking (`types.md`, `concurrency.md §5`). The
  fixpoint is a **stage-agnostic engine**, driven at whichever altitude an analysis lives at — the Sema
  altitude for mutating-ness (over NOIR bodies), the inference-stage altitude for escape (over raw SSA).
  Each analysis stays single-homed; the engine and the fact store are what the altitudes share.
- **Per-definition, not per-instantiation.** Interface summaries describe definitions. For a public
  generic, summarize the erased/template body (the compiled-once form that already exists for the
  cross-module path, 100.4.3.3), so the `.nmi` carries one summary per definition, not one per mono
  instance.

## Design reference

The inference model and the analysis substrate this task builds live in
[`internals/inference.md`](../../internals/inference.md): the dimension inventory, the one-graph
points-to/reachability design, the k-limited summary, flow- and field-sensitivity, dynamic-dispatch
handling and the scope-agnostic (LTO) engine, uniqueness (forms 1+2), and the placement of each fact.
The sections below are the execution plan against that design.

## Build outline

**Prerequisite:** [165](165-midend-pipeline-prefactor.md) lands the behavior-preserving restructure — the
pipeline lift (so the driver sequences the stages and can interpose inference + emit) and the escape
analysis/transform separation. The steps below assume those are in place.

1. **Confirm the `ssair:gen` sub-timing split** — done; raw SSA is the substrate (see "Where the emit
   sits" and [`internals/inference.md`](../../internals/inference.md)).
2. **Introduce the fact store** — per-symbol structured summaries, stable-id keys, an **extensible,
   versioned record with independently-hashed sections** (so later dimensions are field additions, not
   format changes). Two writers: Sema for the cheap facts; the inference stage for value-flow.
3. **Build the interprocedural fixpoint engine** (SCC over the call graph, seeded by imported summaries)
   as a stage-agnostic, **scope-agnostic** solver (one module now, whole-program at a link later). First
   analysis through it: mutating-ness, driven at the Sema altitude so its early error checks stay in
   place — task B's correct form (mutating-ness in the `.nmi`), done as the first slice rather than a
   pre-Sema overlay.
4. **Stand up the points-to / reachability graph builder** over raw SSA — nodes, field-sensitive edges,
   the cross-fiber sink taxonomy (the substrate in `internals/inference.md`). The large new analysis.
5. **Relocate interface emission** from pre-Sema `buildInterface(AST)` to a single post-inference emit
   reading the store + surface. Section it (ABI / perf) with independent hashes.
6. **Migrate escape to a summary-producing analysis** on the graph; promotion (already separated by 165)
   reads the stored summary. The GC-stress fixtures are the regression tripwire.
7. Subsequent dimensions (uniqueness form 1, fiber locality, shareable-requirement, …) register as
   analyses into the same engine and `.nmi` sections.

## Relationship to existing tasks

- [165 mid-end pipeline prefactor](165-midend-pipeline-prefactor.md) — the behavior-preserving
  prerequisite (pipeline lift + escape analysis/transform separation).
- [`internals/inference.md`](../../internals/inference.md) — the design home for the model and substrate.
- [100 modules](100-modules.md) — §100.4.1 (`.nmi` generation) is reshaped by this; §100.4.5/4.6
  (incremental cache + byte-stable interface) depend on it; §100.4.3.5 task B (mutating-ness across the
  boundary) is this refactor's first slice; §100.5 (`.bir` / specialization) is the perf section's
  future content.
- [162 interface/IR serialization](162-interface-serialization-opt.md) — the on-disk format this emits.
- [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) — the stage-3 transforms (incl. the
  interprocedural-escape lift this consumes/produces).
- [101 linear types](101-defer-linear-types.md) / [108 deinit](108-deinit-finalization.md) — future
  soundness dimensions that register into the engine.
- [146 language contract tier](146-language-contract-tier.md) — the programmer-facing contract these
  inferred facts back.

## Sequencing

[165](165-midend-pipeline-prefactor.md) is the behavior-preserving prerequisite and lands first. Pause
module *feature* work at the current green checkpoint (100.4.3.5 increment A done). This refactor
precedes 100.4.5 and every inferred-fact-crossing-the-boundary track. Task B falls out of step 3 as the
first analysis through the engine. The erased-method path (100.4.3.5 C) is the one current item
independent of this and can be scheduled either side.
