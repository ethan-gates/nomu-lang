# Inference

**Status:** working draft. The home for how Nomu *infers* memory and concurrency facts — the dimensions
it computes, the shared analysis substrate (points-to/reachability graph, interprocedural summaries,
dynamic-dispatch handling), and where each fact lives. This is design reference; the execution task that
builds the inference stage is [`plans/tasks/164-formal-inference-stage.md`](../plans/tasks/164-formal-inference-stage.md),
and the exploratory origin is [`inference-dimensions.md`](../../inference-dimensions.md). The guiding bet
(CLAUDE.md): an ownership model with precision comparable to explicit ownership systems, inferred from
program structure rather than annotated.

---

## Inference inventory

Every dimension Nomu infers (or plans to), with the attributes that drive the design. "Shape" is the
analysis kind; none requires SSA — the value-flow and path-sensitive kinds only want its reaching-def
encoding, which running after ssairgen supplies for free.

| Dimension | Stage computed | Soundness / Perf | Shape | In `.nmi`? | Status |
|---|---|---|---|---|---|
| Mutating-ness (self-ABI) | Sema | soundness | body scan + call-graph fixpoint | yes (ABI section) | built intra-module; not yet serialized |
| Type shareability | Sema | soundness | structural (fields, recursive) | yes | built (M5) |
| Shareable requirement (param forwarded to a task sink) | inference | soundness | value-flow + fixpoint | yes | leaning; explicit `<shared T>` ships first |
| Function/closure-type shareability | Sema/inference | soundness | structural over captures | yes | deferred (132) |
| Conditional conformance (`Box<T>` shareable iff `T`) | Sema | soundness | structural | yes | built |
| Escape (→ stack/scalar promotion) | inference | perf | value-flow (intra) | interproc summary only | intra-fn built; summary deferred (148) |
| Interprocedural escape summary | inference | perf | value-flow + fixpoint | yes (perf section) | deferred (148) |
| Fiber locality | inference | perf | value-flow + fixpoint | yes if interproc | future |
| Cross-fiber reachability | inference / runtime | perf (poss. soundness) | reachability + fixpoint | yes if a cross-module contract | future; GC scans all fibers today |
| Lives across suspension | inference | perf | liveness over the fiber CFG across `await`/yield points | yes if interproc (callee-may-suspend) | future; decides frame-held vs promoted placement across a yield |
| Inferred immutability | inference | perf (enables shareable) | value-flow (no write after construction) | yes | future; beyond the structural all-`let` rule type shareability uses |
| Transfer / handoff (single-owner move) | inference | perf | value-flow + reachability fixpoint | yes if interproc | future; the inferred form of the retired `send`/`consuming` annotation |
| Reference uniqueness / aliasing | inference | perf | liveness (form 1) + alias cardinality on points-to + a per-param retain/alias bit (form 2) | yes (retain/alias bit) | adopted as a perf fact (forms 1+2); form 1 first (liveness overlay), form 2 with the COW stdlib; form 3 (general may-alias) left to LLVM |
| Linear / use-exactly-once | Sema | soundness | path-sensitive CFG dataflow (storage) | type carries it | deferred (101/135) |
| Must-consume (deterministic cleanup) | Sema | soundness | path-sensitive CFG dataflow | consume obligation, if a contract | deferred (108) |
| Specialization bodies (`.bir`) | post-inference | perf | per-generic IR | yes (perf section, flag-gated) | future (100.5) |
| Fiber stack-depth bound | inference + call-graph | perf | call-graph fixpoint; local bound NOIR-computable | callee bound, if used | future (104); exact bytes need codegen |

Transforms, for contrast, are not inference and stay in stage 3: devirtualize, inline, stack promotion,
scalar promotion. Scalar promotion is the one genuine SSA consumer.

**Retired as source-level strategies / annotations.** The ARC-style bet — source-level reference counting
earned by isolation, region/uniqueness inference, the `send`/`consuming` and `weak`/`unowned` annotations
— is retired by the MMTk pivot (`memory-model.md`). Reference counting still runs *inside the collector*
(the LXR endgame is RC-primary + backup tracing), invisible to the language; the retirement is of RC as a
programmer-facing discipline. The compiler's own memory choice is placement (stack/frame promotion,
fiber-local allocation); the collector (MMTk — generational Immix now, LXR later) owns the heap and
reclaims cycles automatically, so cycle potential reserves no slot. Two retired items re-enter above as
*inferred, optimization-enabling perf facts*, the move escape makes: **transfer/handoff** (the inferred
form of `send`/`consuming`, enabling fiber-local allocation + a sync-free move) and **reference
uniqueness/aliasing** (enabling in-place mutation and copy elision, `memory-model.md` §6.3).

---

## Substrate design

The value-flow family — escape, fiber-locality, cross-fiber reachability, transfer/handoff,
shareable-requirement — is one analysis, not several. Every decision below is settled.

### One graph, many reachability queries

Build a **points-to / reachability graph** once per function over the raw SSA, then answer each fact as a
reachability query on that fixed graph with a fact-specific set of terminal nodes (sinks).

- **Nodes** — abstract objects (allocation sites, plus a phantom object per incoming parameter) and the
  reference-typed SSA values / fields that point at them.
- **Edges** — points-to (value → object), field (object.field → object, from `fieldAddr`/`store`/`load`),
  value-flow (φ, calls).
- **Sink tags** on use sites — return, global-store, spawn-capture, channel-send, actor-store, and
  call-arg-to-callee-param-i.

Each fact is reachability to a terminal set:

| Fact | Terminal (sink) set |
|---|---|
| Escape (frame) | return ∪ global ∪ all cross-fiber sinks ∪ call-args the callee escapes |
| Cross-fiber reachable | spawn-capture ∪ send ∪ actor-store ∪ global-store |
| Fiber-local | complement of cross-fiber |
| Shareable-requirement | forward: a parameter reaches any cross-fiber sink |
| Transfer / handoff | reaches exactly one cross-fiber sink **and** source dead after (liveness overlay) |

The **cross-fiber sink taxonomy** (spawn captures, channel send, actor message args + field stores,
global stores) is the single definition that drives fiber-locality, cross-fiber reachability, transfer,
and shareable-requirement together. A reference embedded in a shareable value type handed across a
boundary counts, through the object's field edges.

### Flow sensitivity, per fact

Choose sensitivity per fact. A **flow-insensitive** points-to base is sound and cheap for the "ever
reaches a sink" facts (escape, fiber-locality, cross-fiber, shareable-requirement). A thin **liveness /
temporal overlay** serves only the facts that need ordering (transfer/handoff, lives-across-suspension,
point-wise uniqueness). The base graph is built once; the overlay rides the CFG only where a consuming
fact asks for it.

### Summary and composition

The summary abstracts the graph reachable from parameters, return, and globals — the Choi / Whaley-Rinard
shape. Baseline content (k-limited; see "Summary richness" below):

```
Summary(f):
  escape[param_i] : SinkKind     // strongest sink param_i (or its fields) reaches in f
  return          : provenance   // return aliases param_i | fresh alloc | escaped
  fieldEdges      : (node, field) → node   // param_i.field flows to param_j / return / fresh
```

At `y = f(a, b)`: instantiate the param nodes to the actuals, apply `escape`, wire `return` into y,
propagate `fieldEdges`. Compose bottom-up over the call graph; SCCs iterate to a fixpoint. This is the
object the `.nmi` perf section serializes (one per definition; the erased body for generics). The
analysis runs over the whole body and reads two projections off the one graph: **local facts** keyed to
the function's own SSA values (consumed by this function's transforms — stack/scalar promotion, in-place
mutation) and the **summary** (consumed by callers and serialized). Local facts are ephemeral; the
summary persists. The dataflow is the hub drawn in 164's "What".

### Soundness direction

These are perf facts: start optimistic (NoEscape / fiber-local), widen toward the conservative state only
as evidence forces it, and at any cut (FFI, an unresolved dynamic call) assume the conservative sink.
Shareable-requirement is the one soundness fact; the explicit `<shared T>` bound ships first, so the
inferred form is a tightening that falls back to the annotation when unsure and never rejects on
uncertainty.

### Dynamic dispatch

At a witness call — `any I`, a cross-module erased generic in release, an indirect closure call — the
callee is unknown, so there is no single summary. These are perf facts over an open world (separate
compilation lets a later module add a conformer), so the assumed summary must be a sound upper bound over
all conformers, present and future. The summary slot therefore lives on the **interface method (and
function type)**, read at the call site, with a pluggable fill:

- **Conservative** — worst case; always sound; the default for an open public interface.
- **Closed-world inferred join** — the bound is the join over a provably-closed conformer set; no
  annotation, no rejection; sound because the set is closed. **Free for visibility-closed interfaces** (a
  non-public interface cannot be conformed from outside its scope, so its conformer set is complete at
  that scope's compile). A `sealed`-style construct would extend this to a public-but-closed interface, a
  language-surface decision, deferred.
- **Declared contract** — the bound is declared on the interface and each conformer is checked at its own
  compile (can reject); sound even open-world; an annotation confined to an abstraction boundary. The
  alternative to `sealed` for the public case, also deferred.

The concrete path keeps full precision: the interface bound applies only on the dynamic path, and a
conformer called directly uses its own exact summary. The "verify conformer ≤ bound" step is vacuous for
an inferred join (the join is an upper bound of its members by construction) and real only for a declared
contract.

### Scope-agnostic engine + the whole-program (LTO) avenue

At a final link the conformer world is closed, so the open-public precision problem dissolves — the same
closed-world join applies to everything. The engine is therefore built **scope-agnostic**: it takes a
call graph + a conformer set + a summary source and is indifferent to whether the scope is one module
(boundary open, conservative fills) or the whole build (boundary closed, precise joins). A per-module run
and a whole-program link-time run are the same engine under two drivers — the ThinLTO /
whole-program-devirtualization architecture.

Libraries are **distributed as source**, so the whole program's source is present at every build and the
world is always closable. There is no third-party-IR-distribution blocker, and the choice between open
(incremental) and closed (whole-program precise) is a build-mode decision. The `.nmi` is a
**build-internal** incremental-cache + interface artifact (summaries now; bodies-as-IR can ride later for
a link tier to re-optimize), never a distribution format, so it evolves freely build to build while
staying byte-stable within a build for the incremental cache.

Sequencing: build the **per-module floor first** — precise static, free closed-world join where
visibility closes the set, conservative at open dynamic sites. Add the **whole-program link-time
closure** as a release tier when open-public dynamic dispatch measurably costs performance; it is then a
new driver over the existing engine plus an IR-carrying output, rather than new analysis. Keeping the
engine scope-agnostic and the format IR-extensible now holds the avenue open at no cost.

### Summary richness — k-limiting

The summary is **k-limited**: k bounds the depth of the parameter-reachable graph it keeps, interpolating
the precision span (k=0 escape bits only, k=1 the baseline relationships above, k=∞ the full reachable
sub-graph). **Level 1 is the floor.** The relationships it carries — return-aliases-param,
escapes-into-param — are what let a caller's escape/uniqueness analysis survive a call rather than
surrender at the boundary, by distinguishing a *recoverable* escape (into the return or another argument,
which the caller can still prove local) from a *terminal* one (global / cross-fiber). Below Level 1,
analysis is effectively intraprocedural.

k is both a precision dial and a **termination cap**: a recursive type produces unbounded object nesting,
so a finite k is what keeps the summary graph — and thus the interprocedural fixpoint's lattice — finite
and convergent. Some finite k is required regardless.

Cost. The per-function points-to graph build is **k-independent** (always full-fidelity for the body's
own transforms; O(function size), the bulk of the work). k scales only the summary layer on top — summary
size, per-call-site compose, and `.nmi` size — at worst O(P · b^k) in parameter count P and reference
fan-out b, but **bounded by the type's actual nesting depth**, so it saturates at small k for shallow
non-recursive types and adds nothing beyond. The real k-cost lands on deep / recursive / cyclic
structures, where each level unrolls one more layer at diminishing precision returns, and compounds at
the whole-program tier (b^k against the whole build's call graph).

Setting: hardcode per mode, not a prominent user knob. **Debug k=1**, **release k=2–3** (saturates most
non-recursive types for free), an escape-hatch flag for tuning/bisecting, and the highest k reserved for
the whole-program release tier where its cost is already budgeted. The schema stays k-extensible, so none
of these are format changes.

### Field sensitivity

The live choice is binary. "Fully field-sensitive" is unreachable — a field whose offset is hidden behind
a witness cannot be named — so any sensitive analysis is the hybrid, and the real options are
field-insensitive (collapse an object's fields to one node) against **field-sensitive as far as the IR
allows**. Resolved: the latter.

- **Sensitive on named struct/class fields**, keyed by `(object, field)` from `fieldAddr` (which already
  carries the static index; today's escape pass keys interior pointers on the base alone, so this is a
  key change, not new machinery). **Insensitive on array elements** (`elementAddr` indexes by a runtime
  value, so all elements collapse to one node) and on **opaque-witness `T`** (one node for the hidden
  layout).
- **Cost folds into k.** Field sensitivity *is* the fan-out b in the summary's O(P · b^k): sensitive sets
  b ≈ field count, insensitive sets b = 1. k already caps the resulting growth, so field sensitivity adds
  no new knob.
- **Sound for free in safe code** — no address arithmetic and static `fieldAddr` indices mean a field
  cannot be touched without naming it; the opaque fallback is the only conservative merge. The unsafe
  raw-memory surface (task 125) opts out separately.
- **Key fields by source name, not physical offset**, so layout reordering leaves the summary hash
  stable (adding/removing a field is an ABI change already).

Two deferred ways exceed this baseline, both additive: a witness contract that publishes per-field escape
for `T` (recovering sensitivity through an erased boundary per-module), and the whole-program tier (the
concrete type behind the witness is known at a closed link, so sensitivity returns with no extra
mechanism).

### Uniqueness / aliasing — forms 1 + 2

Uniqueness is a **perf fact** under the collector — it has nothing to do with safety or reclamation,
which the collector owns (`memory-model.md` §6.3). Its job is in-place mutation / copy elision for COW
value types (`Array`, `String`, `Dict`), move-instead-of-copy for a uniquely-held value dead after its
last use, and write-barrier elision for an unaliased object escape alone can't clear. It is the lever
that lets value semantics over heap-backed collections avoid copying on every mutation, which is where a
value-semantics language otherwise bleeds.

**Soundness asymmetry.** Concluding "unique" wrongly and mutating in place corrupts a value another holder
can see — a wrong-answer bug, not a dangling pointer. So the analysis **assumes aliased unless it proves
unique**, and takes the in-place path only on a proof (an elided check must be backed by a static proof,
since nothing checks at runtime).

**Collector interaction.** LXR carries a refcount, so a runtime `isUniquelyReferenced` check is the cheap
dynamic fallback and static uniqueness *elides* it. Tracing (GenImmix) has no cheap refcount, so static
uniqueness is the *primary* lever there. The fact matters under both, more under the one shipped first.

Two forms, both riding the substrate:

- **Form 1 — last-use / move.** When a value is passed or assigned and the source is dead after, the copy
  becomes a move. A liveness fact on the **liveness overlay already in the substrate**, so nearly free;
  overlaps transfer/handoff. Build first — it pays off immediately, independent of the collection work.
- **Form 2 — buffer uniqueness for in-place mutation (the COW lever).** A value type's heap buffer is
  unique at a mutation point when it is unpublished (escape) **and** no second live reference was created
  (a duplication check on the points-to graph). Across calls it adds **one summary bit per parameter** —
  "does this function retain or alias param i" — carried in the `.nmi` (a bounded k-summary extension).
  Design now; build alongside the COW stdlib types that consume it.

**Form 3 — general may-alias / must-alias** is left to LLVM rather than rebuilt.

Dependency: Form 2's payoff lands when the COW collection types are built to consume the fact (mutate in
place when told unique, copy otherwise) — the deferred `Array` representation (`memory-model.md` §6.1).
The inference is designable now; its value is realized when those consumers exist.

---

## Analysis vs transform vs lowering

Keep the three roles distinct across the whole mid-end and backend:

- **Analysis** — produces summaries into the store. The escape *fact* lives here, separate from the
  promotion *transform* that consumes it.
- **Transform** — consumes facts, rewrites IR (stage 3). Promotion becomes a consumer of the escape fact
  rather than its producer.
- **Lowering** — `SSAIRToLLVM` + LLVM; consumes facts and IR, produces nothing that crosses a boundary.

---

## Placement

The substrate is **raw SSA** for value-flow inference, and **no current analysis relocates** — each stays
single-homed at the altitude where its inputs and its consumers already live. The 164 refactor adds
shared infrastructure: one fact store both altitudes write to, and one SCC fixpoint engine both altitudes
drive.

- **Soundness / error-producing checks run as early as they can — at Sema, on NOIR.** Writing a `let`
  field, reassigning `self`, a mutating call on an immutable receiver, a non-exhaustive `switch`: these
  surface before lowering, where AST spans are sharp and the user's var/let distinction is still present
  (SSA erases locals to values). Mutating-ness and its caller check therefore stay in Sema.
- **Structural type facts stay with the type system** — shareability + conditional conformance
  (`gen/Shareability.swift`), exhaustiveness (`passes/Exhaustiveness.swift`). They read declarations
  rather than bodies, so SSA offers them nothing.
- **Value-flow facts live on SSA** — escape (`ssairpasses/EscapeAnalysis.swift`), and later
  fiber-locality, cross-fiber reachability, shareable-requirement. These consume the materialized def-use
  the raw-SSA substrate supplies.
- **The SCC fixpoint is a stage-agnostic engine, not a stage.** Driven at the Sema altitude for
  mutating-ness (over NOIR bodies + imported summaries) and at the inference-stage altitude for escape
  (over raw SSA). Each analysis plugs in at one altitude; the engine and the fact store are shared.

Current homes: mutating-ness `passes/Mutation.swift` (run from `Sema.check`, bundled with its soundness
diagnostics and the caller mutable-receiver check); shareability + conditional conformance
`gen/Shareability.swift`; exhaustiveness `passes/Exhaustiveness.swift`; runtime-subset
`passes/RuntimeSubset.swift`; escape `ssairpasses/EscapeAnalysis.swift` (today intraprocedural + inline to
`StackPromotion`; the interprocedural-summary lift is tracked in 164, the analysis/transform separation in
[165](../plans/tasks/165-midend-pipeline-prefactor.md)).
