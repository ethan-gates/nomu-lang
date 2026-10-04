# Formal inference stage + post-inference interface generation

**Avenue:** Infra (compiler architecture) · **Type/Lifecycle:** `refactor · midend` · **Size:** L ·
**Status:** **done** (suite 94/94) — design settled in
[`internals/inference.md`](../../internals/inference.md). The independent infrastructure is built:
[166](166-points-to-graph.md) (points-to graph), [167](167-fact-store.md) (fact store),
[168](168-scc-fixpoint-engine.md) (SCC/fixpoint engine), [169](169-interprocedural-escape-summary.md)
(escape summary). This task was the **convergence**, a dependency chain of sub-phases: **164.1 done**
(fact-store Sema writers), **164.2 done** (inference-phase escape summary into the store) — both
behavior-preserving; **164.3 folded into 164.4**; **164.4.1 done** (store-sourced emit — mutating-ness
now crosses the boundary in the `.nmi`, the producer half of 100.4.3.5.2); **164.4.2 done** (sectioned `.nmi` with independent
ABI/perf hashes); **164.4.3 done** (per-definition erased-body escape summary in the perf section);
**164.6 done** (cross-module seeding — the published `.nmi` escape facts account for imported callees'
dispositions). **164.5 moved to [148](148-ssair-optimizer-tier.md) §148.1** — the lone codegen-consumption
phase, blocked on a placement decision (the addrspace-across-calls wall) that is optimizer-tier work, not
inference-stage work. Inference is now a first-class pipeline phase; the `.nmi` serializes its results.
Prerequisites:
[165](165-midend-pipeline-prefactor.md) (done), 166/167/168/169 (done).

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

**Prerequisites:** all the independent infrastructure is built — [165](165-midend-pipeline-prefactor.md)
(pipeline lift + escape analysis/transform separation), [166](166-points-to-graph.md) (points-to graph +
escape queries), [167](167-fact-store.md) (fact store), [168](168-scc-fixpoint-engine.md) (SCC engine +
mutating-ness ported onto it), [169](169-interprocedural-escape-summary.md) (escape summary). The
`ssair:gen` substrate question is resolved (raw SSA; see "Where the emit sits"). What remains is wiring
these into the real compile path, broken into the sub-phases below. The ordering is a dependency chain:
each assumes the ones before it.

### 164.1 — Fact store in the compile path, Sema writers — **done + green (behavior-preserving, 94/94)**

`collectFacts(_ module: NOIRModule) -> FactStore` (`frontend/sema/sources/passes/FactCollection.swift`)
writes mutating-ness into the store's ABI section, keyed `Type.method` (the per-definition convention the
mid-end + emit share). The driver (`compile`) builds the store after Sema and threads it into
`emitLLVMBinary(facts:)` — reserved at the inference interposition point for 164.2. **Behavior-preserving:**
the store is populated but unread, suite 94/94. Unit-tested in `tests/FactCollectionTests.swift`.

**Remaining 164.1 writers** (carry forward): type shareability + conditional conformance (needs the
`Shareability` predicate wired over the module's types), and the dependency compile path (`compileDependency`
→ `emitObject`) populating its own store symmetrically.

### 164.2 — Inference stage: escape summary into the store — **done + green (behavior-preserving, 94/94)**

At the interposition point [165](165-midend-pipeline-prefactor.md) opened (between `lowerToSSAIR` and
`emitObject` in `emitLLVMBinary`), the driver runs [169](169-interprocedural-escape-summary.md)'s
`computeEscapeSummaries` over the gen'd SSA and `writeEscapeSummaries` into the store's perf section,
wrapped in a `ssair`/`inference` timing phase (visible in the timing table, ~3 ms on a bare `main`). The
store is then threaded into `emitObject(facts:)` (reserved for 164.4/164.5). **Inference is now a real
pipeline phase** (gen → inference → emit → transforms); behavior-preserving (written, unconsumed), suite
94/94. The driver deps `//src/midend/ssairpasses`; `emitObject` deps `//src/facts`.

**Key-space note (the symbol-key alignment this surfaces):** the perf escape summary is keyed by
**post-mono SSA function name** — the per-instance summary the promotion path (164.5) reads, running on the
same functions — while 164.1's ABI facts are keyed **per-definition** (`Type.method`) for the `.nmi`
(164.4). The two consumers want different key spaces, so the store holds both; the per-definition
erased-body escape summary the `.nmi` needs is a 164.4 concern.

### 164.3 — Emit-relocation finding: the move is not independently behavior-preserving — **folded into 164.4**

The intended 165-style "move the emit, then change its inputs" does not factor cleanly here:

- The **entry path** (`compile`) already calls `buildInterface` *after* Sema (the `--nmi` branch), so the
  "run post-inference" position 164.3 wanted is already satisfied there.
- The **dependency path** (`compileDependency`) calls `buildInterface` deliberately **before**
  `prependPrelude` + `mergeExtensions`, so it reads the module's own pre-prelude, pre-merge surface.
  Moving it to post-Sema is **not** behavior-preserving — it would fold in merged extension methods and
  change the emitted interface. (Note: the two paths already differ in this respect — the entry path's
  post-merge emit sees extensions, the dependency path's pre-merge emit does not. An existing
  inconsistency to resolve at 164.4, not here.)

So there is no clean standalone timing move to make; relocation only becomes coherent together with the
input change (AST → store + NOIR surface), where the prelude/merge filtering is handled deliberately.
164.3 is therefore **folded into 164.4**, which does the position + input change as one step.

### 164.4 — Post-inference, store-sourced emit (absorbs 164.3)

Switch the interface emit to assemble the `.nmi` from the fact store + the declaration surface, running
post-inference in both driver paths, carrying the inferred facts across the boundary and (eventually)
sectioning the file. Split into sub-phases.

#### 164.4.1 — Store-sourced emit; mutating-ness in the `.nmi` (producer half of 100.4.3.5.2) — **done + green (94/94)**

`buildInterface` takes a `FactStore` and sets `InterfaceFunc.isMutating` (new optional Codable field) from
it, keyed `Type.method`. The driver builds the store after Sema and passes it in both paths; the
dependency path relocated its `buildInterface` call to post-Sema, built from a **pre-merge own-surface
snapshot** so the emitted surface is unchanged but for the added facts (the folded-in 164.3 move, done
safely). Verified: a library `.nmi` now carries `isMutating: true` on a mutating method, `false` on a
pure one; suite 94/94 (incl. the `.nmi`-consuming module tests). `interface` deps `//src/facts`.
mutating-ness now crosses the boundary in the `.nmi`; the consumer-side use is [100](100-modules.md) §100.4.3.5.2.

#### 164.4.2 — Section the `.nmi` (ABI/soundness + perf) with independent hashes — **done + green (94/94)**

The `.nmi` is now an `NMIFile` — `{version, abi: ModuleInterface, perf: InterfacePerf, abiHash, perfHash}`
— each section FNV-hashed over its own canonical JSON, so `abiHash` is a function of the ABI section alone
(a perf-only change leaves it byte-identical, the §100.4.6 incremental-cache lever). `serialize` wraps +
hashes; `parseNMI` reads the full file (with a flat-`ModuleInterface` fallback for a stale file);
`parseInterface` still returns the ABI section, so every cross-module consumer is unchanged (suite 94/94).
`InterfacePerf` holds a per-definition `[String: EscapeSummary]`, empty until 164.4.3. Oracle:
`testAbiHashIndependentOfPerf` (perf-only change ⇒ equal `abiHash`, differing `perfHash`) +
`testSectionedRoundTrip`. Overlaps the on-disk format work in [162](162-interface-serialization-opt.md).

#### 164.4.3 — Per-definition erased-body escape summary in the perf section — **done + green (94/94)**

The `--emit-nmi` path now lowers the module's **erased/template** bodies — the pre-mono SSA — to SSA,
runs [169](169-interprocedural-escape-summary.md)'s `computeEscapeSummaries` over them (a generic
definition summarizes once over its erased body, verified: `firstOf<T>` and `Box<T>.get` each get one
summary, no post-mono duplication), re-keys the result to the per-definition convention
(`perDefinitionEscapeSummaries`: `m:Type:method` → `Type.method`, a free function keeps its bare name —
matching the ABI facts), projects it onto the public surface (only an exported definition carries a
summary, no private leak), and passes it as the `InterfacePerf` to `serialize`. Best-effort: a body that
fails to lower pre-mono simply carries no summary (read as "unknown"); lowering diagnostics are dropped
(an interface's perf facts are advisory). Verified: a library `.nmi` now carries an `escape` entry per
exported definition, keyed identically to its ABI facts. Driver glue + a pure re-keying helper in
`ssairpasses` (unit-tested, `testPerDefinitionReKeying`). The per-instance post-mono summary stays the
promotion input (164.5); this per-definition form is the cross-module one a dependent seeds from (164.6).

**Resolved by 164.6:** the whole-program build keeps dependency interfaces in memory (ABI via
`compileDependency` → `interfaces[m]`), and the `.nmi` file itself is produced only by the `--emit-nmi`
path. 164.6 carries the dependency perf summaries in a parallel in-memory map (`depEscape[m]`) filled as
each dependency compiles, rather than round-tripping them through an on-disk `.nmi` — so seeding needs no
representation change here. Reading a dependency's perf section back from an on-disk `.nmi` is the
separate incremental-build concern ([100](100-modules.md) §100.4.5/4.6), where a dependency is not
recompiled from source.

#### Deferred within 164.4

The entry path emits its post-merge surface (sees extensions); the dependency path emits its pre-merge
own-surface (does not). Unifying the prelude/merge filtering across both paths is carried forward (it
changes `.nmi` surface content, so it wants its own validation).

### 164.5 — Promotion reads the stored escape summary — **moved to [148](148-ssair-optimizer-tier.md) §148.1**

The one phase that consumes the summary in codegen rather than producing it. It is blocked on a placement
decision (the addrspace-across-calls wall + I4), which is a GC-root-model / allocation-model project, not
inference-stage work — so it lives with the optimizer tier under 148.1 "Interprocedural EA lift — promotion
reads the summary", alongside the route analysis (force-inline / bounded argument explosion / frame roots /
per-fiber `p1` region) and the runtime finding (per-carrier TLAB + migrating fibers). The wiring is thin
once a route lands: the per-instance summary shares `computeEscapeSummaries`'s `external:` parameter, so
promotion reads it the same way the `.nmi` producer does. With this moved out, **task 164 is done** — the
inference stage is a real pipeline phase, the fact store + SCC engine are the shared substrate, and the
`.nmi` carries mutating-ness plus a cross-module-accurate per-definition escape summary.

### 164.6 — Seed the engine across the module boundary — **done + green (94/94)**

`computeEscapeSummaries` gained an `external:` provider — a dependency's published per-definition
summaries, keyed by the call names a consumer's SSA emits for them (a free function `foo` → `origin@foo`,
a method `Type.method` → `m:origin@Type:method`, via `externalEscapeKeys` + the new public
`ssaMethodSymbol`). A direct call to a non-in-module callee reads that summary instead of the conservative
floor (`argEscapes` prefers `external` over the in-graph lookup). The driver fills it topologically:
`compileDependency` computes its own per-definition summary seeded by its visible dependencies'
(`externalEscape(of:)`) and returns it into `depEscape[m]`; the entry's `--emit-nmi` seeds the same way.
Verified on a two-module fixture: a function passing its param to an imported no-escape callee publishes
`noEscape`, one passing to an imported param-returning callee publishes `escapes` — where the pre-164.6
floor marked both `escapes`. Unit-tested (`testExternalSummarySeedsImportedCall`). This makes the published
analysis genuinely cross-module.

**Scoped to the `.nmi` producer.** The per-definition (`--emit-nmi` / `compileDependency`) path is seeded;
the per-instance post-mono summary 164.2 computes for promotion shares the same `external:` parameter, so
seeding it is a one-line follow-on once promotion (164.5) has a consumer. Depends on 164.4 (the `.nmi`
carries the summaries).

**Beyond 164:** subsequent dimensions (uniqueness form 1, fiber locality, shareable-requirement, …)
register as analyses into the same engine and `.nmi` sections — the pattern this task establishes, not
further 164 sub-phases.

## Relationship to existing tasks

- [165 mid-end pipeline prefactor](165-midend-pipeline-prefactor.md) — the behavior-preserving
  prerequisite (pipeline lift + escape analysis/transform separation). Done.
- [166 points-to / reachability graph](166-points-to-graph.md) — the upstream analysis core (the graph
  every value-flow fact queries); 164.5's promotion wiring consumes its summary.
- [`internals/inference.md`](../../internals/inference.md) — the design home for the model and substrate.
- [100 modules](100-modules.md) — §100.4.1 (`.nmi` generation) is reshaped by this; §100.4.5/4.6
  (incremental cache + byte-stable interface) depend on it; §100.4.3.5.2 (a mutating value method across
  the boundary) consumes the mutating-ness this carries; §100.5 (`.bir` / specialization) is the perf
  section's future content.
- [162 interface/IR serialization](162-interface-serialization-opt.md) — the on-disk format this emits.
- [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) — the stage-3 transforms (incl. the
  interprocedural-escape lift this consumes/produces).
- [101 linear types](101-defer-linear-types.md) / [108 deinit](108-deinit-finalization.md) — future
  soundness dimensions that register into the engine.
- [146 language contract tier](146-language-contract-tier.md) — the programmer-facing contract these
  inferred facts back.

## Sequencing

[165](165-midend-pipeline-prefactor.md) (done) is the behavior-preserving prerequisite; the graph builder
[166](166-points-to-graph.md) is the upstream analysis core and lands beside the engine (step 5's escape
migration consumes it). Pause module *feature* work at the current green checkpoint (100.4.3.5.1
done). This refactor precedes 100.4.5 and every inferred-fact-crossing-the-boundary track. 100.4.3.5.2's
producer half falls out of step 3 as the first analysis through the engine. The erased-method path (100.4.3.5.3) is the one
current item independent of this and can be scheduled either side.
