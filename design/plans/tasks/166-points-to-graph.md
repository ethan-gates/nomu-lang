# Points-to / reachability graph builder

**Avenue:** Infra (compiler analysis) · **Type/Lifecycle:** `analysis · midend` · **Size:** L ·
**Status:** analysis complete. 166.1 (graph + builder), 166.2 (faithful escape query), and 166.3
(differential validation) **done + green (94/94, both providers)**. 166.4 (precise query) is **built +
unit-validated as a sound subset**, but the extra promotion it enables trips the GC-precision contract
(I4) and needs the stage-3 transform/verifier work in [148](148-ssair-optimizer-tier.md) to consume;
`NOMU_PTG_PRECISE` is an experimental, default-off gate for that follow-up. Design settled in
[`internals/inference.md`](../../internals/inference.md); split out of
[164](164-formal-inference-stage.md) as its independent, upstream core. The interprocedural summary over
this graph is 164's work.

## What

Build the **points-to / reachability graph** over raw SSA — the one analysis the whole value-flow family
(escape, fiber-locality, cross-fiber reachability, transfer, shareable-requirement, uniqueness) queries.
Design is fixed in [`internals/inference.md`](../../internals/inference.md) ("Substrate design"); this
task implements the intraprocedural builder and its first query (escape), validated against today's
analysis. Interprocedural summaries, the fiber/uniqueness queries, and fact-store wiring stay in
[164](164-formal-inference-stage.md).

This is the largest self-contained piece of the inference work, and it is **upstream and independent**:
it needs no fact store, no interprocedural engine, no `.nmi` changes. SSA function in, graph + queries
out. That independence, plus a built-in differential oracle (below), is why it is its own task.

## 166.1 — The graph + builder over SSA — **done + green**

Built in `src/midend/ssairpasses/sources/PointsToGraph.swift` (`PointsToGraph` + `buildPointsToGraph`),
beside `EscapeAnalysis.swift`; structural unit tests in `tests/PointsToGraphTests.swift` (ssairpasses
suite green, 31 tests). Node identity reuses SSA value ids; field edges keyed by `(value-id, PTGField)`
with `PTGField.field` carrying the **source name** (resolved from the module aggregates, collapsing to
`.opaque` when the layout is absent) so 164's summary hash stays layout-stable. The sink taxonomy
(`PTGSink`) mirrors `EscapeAnalysis.escapingUses`/`escapingTermUses` operand by operand, so 166.2's
faithful query is "a value carrying any sink tag escapes" + the interior→base fixpoint. Roots for 164 —
`paramObjects` (per-index phantoms), `returnValues`, and field edges — are first-class on the graph; the
points-to / field / flow structure is built but unconsumed until 166.3/164. The graph is a plain value
returned by the builder, not an `SSAPass` (it is analysis input, wired into the `StackPromotion` provider
in 166.2's query step).

Per-function, built once over the raw (pre-transform) SSA, as specified in `internals/inference.md`:

- **Nodes** — abstract objects (allocation sites, plus a phantom object per incoming parameter) and the
  reference-typed SSA values / fields that point at them.
- **Edges** — points-to (value → object), **field-sensitive** field edges keyed by `(object, field)`
  from `fieldAddr` (array elements and opaque-witness `T` collapse to one node), and value-flow (φ,
  calls).
- **Sink tags** on use sites — return, global-store, and the cross-fiber sink taxonomy (spawn-capture,
  channel-send, actor message args + field stores), plus call-arg-to-callee-param-i.

Flow-insensitive base (the "ever reaches a sink" shape). The liveness/temporal overlay and the
interprocedural summary are out of scope here.

## 166.2 — The escape query (faithful) — **done + green**

Built in `src/midend/ssairpasses/sources/EscapeQuery.swift`: `PointsToGraph.faithfulEscaping()` (the
query) and `graphEscaping(_:aggregates:)` (build + query, the drop-in `escaping:` provider). The query is
`Set(sinks.keys)` (any value carrying a publishing-sink tag) + the interior→base fixpoint over the
`interior` map — reproducing `EscapeAnalysis.escapingValues` by construction, since the builder tags
exactly the operands the legacy `escapingUses`/`escapingTermUses` publish. Unit differential tests in
`tests/EscapeQueryTests.swift` assert `graphEscaping(f) == escapingValues(f)` across local/returned
allocs, interior-pointer (incl. chained) escape, store-into-local, call args, composite publishing sites
(closure/box/actorSend/spawn), and edge args — the unit-level form of 166.3's suite-wide oracle.

Reachability to the escape terminal set, computed as a query on the graph rather than a bespoke walk.
**Faithful first:** this first query reproduces today's `EscapeAnalysis.escapingValues` *exactly*,
including its blunt rules — a value used at a sink escapes, and an interior pointer escaping marks its
base escaping (the container-insensitive legacy behaviour). The richer points-to / field edges the graph
builds are present but unconsumed by this query, so the graph swaps in with zero behaviour change. The
added precision the graph enables is 166.4. Keep the soundness direction (over-approximate: unsure ⇒
escapes).

## 166.3 — Differential validation through the 165.2 injection point — **done + green**

`LLVMBridge.emitObject` gates the escape provider on `NOMU_PTG_ESCAPE`: set, `StackPromotion` consumes
`{ graphEscaping($0, aggregates: ssaModule.aggregates) }` instead of the default `escapingValues`
(sibling gate to `NOMU_NO_ESCAPE`/`NOMU_NO_SCALAR`). Built `-c opt`; the suite is **94/94 both ways** —
legacy baseline and `NOMU_PTG_ESCAPE=1` — including the GC-stress evac legs (`*-evac`), where a wrong
escape set miscompiles under evacuation. Faithful ⇒ the promoted set is identical by construction (the
graph tags exactly the legacy publishing operands); the unchanged suite under the gate is the oracle. The
gate stays in to bisect 166.4's precision flip.

[165.2](165-midend-pipeline-prefactor.md) made `StackPromotion` consume an injected
`escaping: (SSAFunction) -> Set<Int>` provider. Supply a graph-backed provider and run the suite with it:
the promoted set, and the 94/94 result, must match the current `escapingValues` provider. That makes the
existing suite a differential oracle for the graph's escape query — the graph is correct when swapping
providers changes nothing. An A/B env gate (graph vs legacy provider) stays available for bisecting.

Exit: graph-backed escape provider green `-c opt` (94/94), promoted set unchanged versus the legacy
provider (faithful ⇒ identical, by construction).

## 166.4 — Turn on the graph's precision — **query built + unit-validated; end-to-end promotion deferred to the transform tier (148)**

The precise query is built (`PointsToGraph.preciseEscaping()`, `graphEscaping(…, precise: true)`, gated by
`NOMU_PTG_PRECISE` inside `NOMU_PTG_ESCAPE`). It relaxes two faithful rules to the graph's
container/field-sensitive ones: a value written into a non-escaping local **class** object's field
escapes only if that object does, and a block argument escapes only if the target parameter does. Every
other container (object construction — `box`/closure/aggregate — a parameter, or an unresolved base) stays
unconditionally escaping, so the result is a **subset of `faithfulEscaping()` by construction**. Unit
tests in `tests/EscapeQueryTests.swift` assert the headline win (store into a non-escaping local stays
local), the escaping-container propagation, the preserved box-payload boundary, the parameter fallback,
and the edge-arg relaxation — each also asserting `precise ⊆ faithful`.

**Finding — the extra promotion is blocked at the transform/verifier tier, not the analysis.** Running the
suite with `NOMU_PTG_PRECISE=1` fails 6 cases (escape-nonleaf(-evac), gen-major, gen-minor,
scalar-carried(-evac)) at **SSAIR verify**, not at runtime: `I4: stack-promoted %N of T escapes its
frame`. I4 (`SSAIRVerify.swift`) reuses faithful `escapingValues` as the GC-precision contract — a
reference-type `stackAlloc` must be faithful-non-escaping. The precise query promotes objects in
`faithful \ precise` (the intended extra promotion), which trips I4 by design. The contract is a real
backend invariant: stack-promoting an object stored into a managed field makes an `addrspace(1)` field
point at an `addrspace(0)` stack slot, which the statepoint rewriter then relocates as heap and corrupts
(the `p1` env-param addrspace wall, generalized). So consuming the extra precision needs the backend to
lower a promoted-and-stored object (SROA of nested promoted objects / `addrspace` handling) and I4 to
track the precise contract — the stage-3 transform work in [148](148-ssair-optimizer-tier.md), downstream
of this analysis. The precise *analysis* is correct and sound (subset-validated); it is the promotion
*transform* that is not yet ready to consume it.

`NOMU_PTG_PRECISE` therefore stays an **experimental, default-off** gate (the harness for 148's transform
work); `NOMU_PTG_ESCAPE` alone (faithful) and the default build stay 94/94. Keep both gates so a precision
regression bisects precise → faithful → legacy.

Original intent (for 148): flip the escape query to the graph's container/field-sensitive rules so a value
stored into a non-escaping local object stays local and a field escaping leaves sibling fields and the
container's own promotability intact. Validated by the GC-stress suite as a soundness oracle — 94/94 green
including the evac legs, promoted set a superset of legacy — once the transform consumes it.

## Build notes (decided)

- **Node identity** — reuse SSA value ids as node ids, with field edges keyed by `(value-id, field)`,
  extending today's `derivedFrom` map, rather than a separate abstract-object id space.
- **Sink taxonomy coverage today** — spawn env, `actorSend`, `store`/`box`/`ret`/edge-args are
  structurally taggable now. A module-global store (today's escape tags none — confirm whether SSAIR has a
  global-store form) and channel-send (a deferred library type, so a send is an ordinary `call`) are not;
  the escape query treats all call args as escaping, so neither blocks this task. They refine with the
  fiber-locality query in 164 when those features exist.
- **Location** — a new file in `ssairpasses` beside `EscapeAnalysis.swift`; 164's engine decides whether
  to promote it to a dedicated `inference` module.

## Relationship to existing tasks

- [164 formal inference stage](164-formal-inference-stage.md) — the consumer. 164's escape-migration step
  reads this graph to produce the interprocedural summary into the fact store; its fiber/uniqueness
  analyses are further queries on it. Built beside 164's store/engine, upstream of 164's escape step.
- [165 mid-end pipeline prefactor](165-midend-pipeline-prefactor.md) — 165.2's injected escape provider
  is this task's validation harness.
- [`internals/inference.md`](../../internals/inference.md) — the fixed design (graph, sinks, field
  sensitivity, queries).
- [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) — the transforms consuming the escape fact.

## Sequencing

Independent of 164's fact store and interprocedural engine — can land beside them. Precedes 164's
escape-migration step (which consumes the graph) and every fiber/uniqueness query. The intraprocedural
scope here is the floor; the interprocedural summary over the same graph is 164's work.
