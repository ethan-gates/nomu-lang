# Interprocedural escape summary

**Avenue:** Infra (compiler analysis) · **Type/Lifecycle:** `analysis · midend` · **Size:** L ·
**Status:** **done + green (Level-1 floor).** The summary projection, call-site compose, engine-driven
bottom-up composition, and fact-store write are built in `src/midend/ssairpasses/sources/InterprocEscape.swift`
and summary-level-tested. The Level-1 floor ships — the sole relaxation over intraprocedural faithful
escape is "an argument passed to a callee that does not escape it does not escape." The
intoReturn/intoParam threading and the k≥2 field-edge summary are deferred refinements (see below).
End-to-end promotion consuming the summary is 164/148. Design in
[`internals/inference.md`](../../internals/inference.md); sits on the complete
[166](166-points-to-graph.md) graph and rides the [168](168-scc-fixpoint-engine.md) engine.

## What

Build the **interprocedural escape summary**: project the per-function [166](166-points-to-graph.md)
points-to graph into a k-limited summary of what escapes through a function's parameters and return, then
compose those summaries bottom-up over the call graph (via the [168](168-scc-fixpoint-engine.md) engine)
so a caller's escape analysis survives a call instead of surrendering at the boundary. Design is fixed in
[`internals/inference.md`](../../internals/inference.md); this task builds the summary projection, the
call-site compose, and the k-limiting, and writes the result into the [167](167-fact-store.md) perf
section.

It sits directly on 166 (done) and composes through 168, and is independent of 164's emit relocation. It
is the content of 164's "migrate escape to a summary-producing analysis" step, lifted out so the summary
*computation* is built and validated before the integration wires it to the transforms and the `.nmi`.

## Why

Escape today is intraprocedural: at a call, every argument is assumed to escape (the conservative floor),
so a locally-allocated value passed to a function that does not actually leak it cannot be promoted. The
summary carries exactly the relationships that recover this — which parameters a callee escapes, whether
its return aliases a parameter or is fresh, and how a parameter's fields flow — so a caller can tell a
*recoverable* escape (into the return or another argument, still provably local) from a *terminal* one
(global / cross-fiber). This is the interprocedural precision the whole-program performance bet rests on,
and it is the second client of the shared fixpoint engine after mutating-ness.

## 169.1 — The per-function summary projection

Project the 166 graph reachable from the roots it already exposes (`paramObjects`, `returnValues`, global
sinks) into the summary record:

```
Summary(f):
  escape[param_i] : SinkKind     // the strongest sink param_i (or its fields) reaches in f
  return          : provenance   // return aliases param_i | fresh alloc | escaped
  fieldEdges      : (node, field) → node   // param_i.field flows to param_j / return / fresh
```

Reuse the graph's field-sensitive edges (keyed by source name) and sink taxonomy. **Level 1 is the
floor** — return-aliases-param and escapes-into-param are what let a caller survive the call.

## 169.2 — The call-site compose

At `y = f(a, b)`: instantiate the callee's param nodes to the actuals, apply `escape[param_i]` to each
actual, wire `return` provenance into `y`, and propagate `fieldEdges` into the caller's graph. A terminal
sink on a parameter escapes the actual; a recoverable one (into return / another parameter) leaves it for
the caller's own query to resolve. An absent or unknown callee summary (a dependency not yet seen, a
dynamic call) falls back to the conservative "all arguments escape" floor — so the compose only ever
tightens.

## 169.3 — Bottom-up composition via the engine

Register escape as a transfer function + lattice on the [168](168-scc-fixpoint-engine.md) engine:
summaries compose bottom-up over the call graph, SCCs (recursion) iterate to a fixpoint. The lattice is
finite because the summary is **k-limited** — k bounds parameter-reachable graph depth and is the
termination cap (a recursive type would otherwise nest unboundedly). Hardcode per mode: **debug k=1,
release k=2–3** (saturates most non-recursive types), an escape-hatch flag for bisecting. At a dynamic
call the summary slot lives on the interface method with the pluggable fill (168.2); conservative is the
floor.

## 169.4 — Write into the fact store

Write the summary into [167](167-fact-store.md)'s perf section, extending its `escapingParams` k=0 floor
to the full k-limited summary (per-definition, one record for a public generic's erased body). This is the
record 164's emit serializes into the `.nmi` perf section and that a dependency's build reads back to seed
169.3.

## What shipped vs deferred

The implementation (`InterprocEscape.swift`) is the Level-1 floor, scoped deliberately for soundness and
tractability:

- **`EscapeSummary`** (in [`facts`](167-fact-store.md)) is per-parameter `ParamDisposition`
  (`noEscape` | `escapes`) + a `ReturnProvenance` (`fresh` | `escaped`). `escapes` folds in every
  conservative case; `noEscape` is the recoverable win. The `FactSummary` lattice conformance lives on a
  wrapper (`EscapeFact`) in `ssairpasses`, keeping `facts` dependency-free.
- **The transfer** is the faithful escape query with one change: a direct-call argument escapes only when
  the callee's current summary escapes that parameter. An in-graph callee not yet computed reads as
  optimistic `noEscape` (the engine starts at `bottom` and widens), so a recursive SCC converges to the
  precise answer rather than the conservative all-escape; an external direct callee and every
  witness/indirect call stay conservative.
- **`computeEscapeSummaries`** builds the direct-call graph and solves via the 168 engine;
  **`writeEscapeSummaries`** writes into the perf section keyed by mangled name.
- **Deferred refinements** (the k≥2 richness, explicitly not shipped): `intoReturn`/`intoParam`
  dispositions (threading a callee's return/argument aliasing back so a factory-style escape is
  recoverable, not collapsed to `escapes`), and the field-edge summary. The current floor collapses those
  to the conservative `escapes`, which is sound and loses only precision on nested/aliasing flows.

## Oracle (property + differential)

- **Leaf agreement** — for a function that calls nothing, the summary's `escape[param_i]` projection must
  match the intraprocedural faithful escape ([166.2](166-points-to-graph.md)) restricted to the
  parameters: the summary of a leaf is just its own graph.
- **Conservative floor reproduced** — with every callee summary forced absent/top, the composed caller
  escape must equal today's "all call arguments escape" result — composition with no information is the
  current behaviour.
- **Tightening is sound** — with a known callee summary that escapes none of its parameters, a value
  passed only to it and otherwise local is reported non-escaping; validated as a subset of the
  conservative result over constructed call graphs (leaf, chain, recursion through a 168 SCC).

End-to-end promotion consuming the interprocedural result is 164's wiring (and the stored summary feeding
`StackPromotion`); this task's oracle is at the summary/compose level.

## Build notes (decided)

- **Reuses 166 wholesale** — the graph's param/return/global roots, field-sensitive edges, and sink
  taxonomy are the summary's inputs; no new graph machinery.
- **k-limiting lives in the summary layer** — the per-function graph build is k-independent (166); k
  scales only this summary projection and the compose, bounded by the type's actual nesting depth.
- **Location** — with the 168 engine (`src/midend/inference` / `src/inference`); escape is its second
  client.
- **Scope out** — the emit relocation and the promotion rewire (164), the on-disk `.nmi` format (162),
  the whole-program closed-world join (a later release tier).

## Relationship to existing tasks

- [166 points-to graph](166-points-to-graph.md) — the substrate; this projects its graph into a summary.
  Done.
- [168 SCC / fixpoint engine](168-scc-fixpoint-engine.md) — composes these summaries bottom-up; escape is
  its second client.
- [167 fact store](167-fact-store.md) — holds the summary (perf section); 169.4 extends the escape field.
- [164 formal inference stage](164-formal-inference-stage.md) — wires the summary to the transforms and
  the `.nmi` emit; this is its escape-migration step, lifted out.
- [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) — the transforms that consume the richer escape
  (interprocedural + the 166.4 precise query).
- [`internals/inference.md`](../../internals/inference.md) — the design home.

## Sequencing

Follows [166](166-points-to-graph.md) (done) and rides the [168](168-scc-fixpoint-engine.md) engine (its
second client, after mutating-ness). Independent of 167's internals (writes into its perf section through
the public API). 164 integrates: drives the composition at the inference altitude, seeds it across the
module boundary, and feeds the stored summary to promotion.
