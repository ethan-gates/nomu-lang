# SCC / interprocedural fixpoint engine

**Avenue:** Infra (compiler architecture) · **Type/Lifecycle:** `infra · cross-cutting` · **Size:** M ·
**Status:** **done + green.** The generic solver (168.1) and the conservative dynamic-dispatch plug-in
point (168.2) are built in `src/inference`; mutating-ness (168.3) is ported onto it and behavior-preserving
(full suite 94/94, the differential oracle). The closed-world join and whole-program driver (168.2's later
tiers) remain deferred. Design in [`internals/inference.md`](../../internals/inference.md)
("Scope-agnostic engine + the whole-program (LTO) avenue", "Summary and composition"); split out of
[164](164-formal-inference-stage.md).

## What

Build the **interprocedural fixpoint engine** — the stage-agnostic, scope-agnostic solver every
caller-relevant inferred fact (mutating-ness, shareable-requirement, interprocedural escape) runs through.
It condenses a call graph into strongly-connected components (Tarjan), orders them bottom-up, and iterates
each SCC to a fixpoint over an abstract lattice via an analysis-supplied transfer function, seeded by a
summary provider. Design is fixed in [`internals/inference.md`](../../internals/inference.md); this task
implements the generic solver and ports mutating-ness onto it as the first client.

It is **upstream and independent**, like [166](166-points-to-graph.md) and [167](167-fact-store.md): it
needs no fact store, no points-to graph, and no `.nmi`. A call graph + a lattice + a transfer function +
a summary provider, in; a fixpoint solution, out. That independence, plus the mutating-ness differential
oracle (below), is why it is its own task.

## Why

Mutating-ness, shareable-requirement, and interprocedural escape are all the same shape: a fact about a
function derived from its body *and* from what it calls, so it needs a call-graph fixpoint seeded by
callees' summaries, iterating over recursion. Today the only instance is the bespoke intra-type
mutating-ness fixpoint in `passes/Mutation.swift` (same-type calls on `self` only) — a special case of the
general solver. Factoring the solver out once, generic over the lattice, means escape and
shareable-requirement register as transfer functions rather than each growing its own fixpoint, and the
whole-program (LTO) tier is a second *driver* over the same engine rather than new analysis.

## 168.1 — The generic solver — **done + green**

Built in `src/inference/sources/FixpointSolver.swift`: `FactSummary` (the lattice protocol) + `BoolFact`
(the disjunctive-bool lattice), `CallGraph<Node>` (insertion-ordered, deterministic; edges may point at
external nodes), and `FixpointSolver<Node, S>` — iterative Tarjan SCC (so a deep chain cannot overflow the
Swift stack), callees-first, one transfer evaluation per acyclic node and a join-fixpoint per recursive
SCC. Property tests in `tests/FixpointSolverTests.swift` (chain, diamond, unmarked leaf, self-recursion,
mutual recursion, external callee via provider, SCC ordering/partition, insertion-order determinism).

A solver generic over an abstract summary lattice:

- **Input** — a call graph (nodes = function symbols, edges = call sites), a bottom (optimistic) element,
  a join, and a **transfer function** `(node, callees' current summaries) -> node's summary`.
- **SCC condensation** — Tarjan's algorithm over the call graph; process SCCs in reverse-topological
  (callees before callers) order.
- **Fixpoint** — a single-node SCC is one transfer evaluation; a multi-node SCC (recursion / mutual
  recursion) iterates its members to a fixpoint under join. A monotone transfer + finite lattice height
  guarantees termination (the k-limit in [169](169-interprocedural-escape-summary.md) is what bounds the
  escape lattice).
- **Seeding** — unknown callees (a dependency, an unresolved dynamic call) read from a **summary
  provider**: an abstract source returning an already-known summary (an imported one, or a conservative
  top). The engine is indifferent to where it comes from.

## 168.2 — Scope-agnostic + the dynamic-dispatch fill

The engine takes a **conformer set + a summary source** and is indifferent to scope: one module (boundary
open — unknown callees and open dynamic sites fill conservative) or the whole build (boundary closed —
precise joins). A per-module run and a whole-program link-time run are the same engine under two drivers
(the ThinLTO / whole-program-devirtualization architecture). At a witness / indirect call the fill is
pluggable — **conservative** (the open-public default), **closed-world inferred join** (free where
visibility closes the conformer set), or **declared contract** — per
[`internals/inference.md`](../../internals/inference.md) ("Dynamic dispatch"). This task builds the
conservative fill (the floor) and the plug-in point; the closed-world join and the whole-program driver
are later tiers over the same engine.

## 168.3 — First client: mutating-ness, ported onto the engine — **done + green**

`passes/Mutation.swift`'s inline `while changed` fixpoint is replaced by a `CallGraph` build + a
`FixpointSolver` with a `BoolFact` lattice and the transfer "direct `self`-field write, or any mutating
same-type callee"; the scanning, `fieldMut`, and the `let`/`self` error diagnostics are untouched and stay
in Sema. Behavior-preserving — the full suite is 94/94 (mutating-ness drives ABI/codegen, so an unchanged
suite is the differential oracle that the engine reproduces today's mutating set). `frontend/sema` now
deps `//src/inference`; no cycle (the engine deps nothing).

## Oracle (differential + property)

- **Mutating-ness differential** — the ported analysis must produce the **identical mutating set** as
  today's `analyzeMutation` across the whole test suite. Same rule, same result; the engine is correct
  when the port changes nothing (the 166.3-style unchanged-output oracle).
- **Solver property tests** — a toy lattice over synthetic call graphs: a chain, a diamond (join order
  irrelevant), self-recursion, and mutual recursion (a 2-node SCC) each reach the expected fixpoint; a
  monotone transfer terminates.

## Build notes (decided)

- **Location** — a new module `src/midend/inference` (or `src/inference`), depending on `//src/support`
  and whatever carries the call graph; the mutating-ness client bridges at the Sema altitude over NOIR.
  Finalize the module boundary when the first two clients (mutating-ness here, escape in
  [169](169-interprocedural-escape-summary.md)) are both wired.
- **Call graph** — reuse the direct-call structure already available (NOIR bodies at the Sema altitude,
  SSA `call` sites at the inference altitude); the engine takes the graph as input, it does not own call
  resolution.
- **Scope out** — no fact store wiring (164), no escape summary (that is 169's transfer function), no
  whole-program driver and no closed-world join (later release tiers), no `.nmi` seeding (164).

## Relationship to existing tasks

- [164 formal inference stage](164-formal-inference-stage.md) — the integration: drives this engine at
  both altitudes, seeds it from imported `.nmi` summaries, and writes results into the store.
- [167 fact store](167-fact-store.md) — holds the summaries this engine produces and consumes; built
  beside it, independent.
- [169 interprocedural escape summary](169-interprocedural-escape-summary.md) — the escape transfer
  function + lattice that plugs into this engine, composing the [166](166-points-to-graph.md) graph's
  summaries bottom-up.
- `passes/Mutation.swift` — the bespoke intra-type fixpoint this generalizes; its result is the
  differential oracle.
- [`internals/inference.md`](../../internals/inference.md) — the design home.

## Sequencing

Independent of 166/167/169 — lands in parallel. Mutating-ness (168.3) is the first client and the oracle;
escape (169) is the second, composing the 166 graph's summaries through this engine. 164 then drives it at
both altitudes and seeds it across the module boundary.
