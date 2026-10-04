# Fact store

**Avenue:** Infra (compiler architecture) · **Type/Lifecycle:** `infra · cross-cutting` · **Size:** M ·
**Status:** build-ready — design in [`internals/inference.md`](../../internals/inference.md) ("Fact
store"); split out of [164](164-formal-inference-stage.md) as its independent, upstream infrastructure.

## What

Build the **fact store** — the in-memory hub the whole inference stage writes into and the transforms +
interface emit read from. Design is fixed in [`internals/inference.md`](../../internals/inference.md);
this task implements the schema, the deterministic independently-hashed sections, and the two-writer API,
unit-tested on its own.

It is **upstream and independent**, like [166](166-points-to-graph.md): it needs no SCC engine
([168](168-scc-fixpoint-engine.md)), no escape summary ([169](169-interprocedural-escape-summary.md)),
no analysis, and no `.nmi` format ([162](162-interface-serialization-opt.md)). A schema plus a hash plus
an API, in; a unit-tested container, out. That independence, plus a property-based oracle (below), is why
it is its own task.

## Why

Nomu's core bet is that the facts a module must hand a consumer — ownership, lifetime, sharing,
mutating-ness, escape — are *inferred*. Those facts need a single structured home so that producing a
fact is decoupled from consuming it (the escape analysis writes a summary; the promotion transform and
the `.nmi` emit each read it independently), and so that the interface a consumer compiles against is a
*serialization of inference results* rather than a thing each pass rediscovers. The store is that home.
Building it first, with a clean API and the independent-section-hash property proven in isolation,
de-risks everything in 164 that plugs into it.

## 167.1 — The record schema

Per-symbol records keyed by a stable `SymbolID` (the mangled name; per-definition, so a public generic is
one record over its erased body). Each record splits into two sections of typed, optional fields:

- **ABI / soundness section** — facts a consumer must see to compile correctly: mutating-ness (per-method
  bit), type shareability (per-type bit), conditional conformance.
- **Perf section** — optimization facts: the per-parameter escape bits (the k=0 floor of the escape
  summary — [169](169-interprocedural-escape-summary.md) extends it to the k-limited summary),
  stack-depth bound, later uniqueness / fiber facts.

Fields are optional and populated per symbol kind (a function symbol carries mutating-ness; a type symbol
carries shareability). Adding a dimension is a **field addition**, not a format change; the store carries
a schema version.

## 167.2 — Deterministic, independent section hashing

Each section hashes independently to a stable digest over a **canonical encoding** (fields in fixed
order; sets/maps sorted by key), so the digest is insensitive to insertion order and stable across runs
(Swift's `Hasher` is per-process randomized and cannot be used — a small FNV-1a over the canonical bytes).
The property that matters: an edit touching only perf facts leaves the **ABI digest byte-identical**
(and vice versa). This is the incremental-cache lever (100.4.6) proven at the unit level, ahead of the
`.nmi` format that will serialize it.

## 167.3 — The two-writer API

An upsert API both altitudes drive: Sema writes the cheap structural facts (mutating-ness, shareability),
the inference stage writes the value-flow facts. They touch **disjoint fields**, so writing is
order-independent — Sema-then-inference and inference-then-Sema produce the identical store. A reader API
exposes a symbol's facts and each section's digest; a whole-store per-section digest (sorted by
`SymbolID`) backs the cache check.

## Oracle (property tests, no differential baseline)

The store is new infrastructure with no existing counterpart to diff against, so the oracle is its
properties, unit-tested standalone:

- **Order independence** — two writers in either order yield identical records and digests.
- **Section independence** — a perf-only edit leaves the ABI digest fixed and moves the perf digest; an
  ABI-only edit the reverse.
- **Determinism** — inserting symbols in different orders yields the same whole-store per-section digest;
  the digest is reproducible across process runs.

## Build notes (decided)

- **Location** — a new top-level module `src/facts` (`module_name: facts`), depending only on
  `//src/support`. It must be depended on by `frontend/sema` (writer), the inference stage (writer), and
  `interface` (emit), so it sits below all three. Nothing depends on it yet — this task is additive, wired
  up in 164.
- **Key** — `SymbolID` wrapping the mangled name (`String`); a thin struct, not a bare typealias, to keep
  the key type-safe.
- **Hash** — FNV-1a 64-bit over a canonical byte encoding; a small `CanonicalEncoder` appends fields in a
  fixed order and sorts set/map keys. Deterministic, dependency-free, sufficient for a cache key within a
  build.
- **Scope out** — no Sema/inference write wiring (164), no SCC engine (168), no full escape-summary schema
  (169), no on-disk `.nmi` (162). This task is the in-memory container + hashing + API only.

## Relationship to existing tasks

- [164 formal inference stage](164-formal-inference-stage.md) — the integration that wires the real
  writers (Sema + inference), relocates the interface emit to read the store, and sections the `.nmi`.
- [168 SCC / fixpoint engine](168-scc-fixpoint-engine.md) — fills the store with interprocedural facts;
  built beside this, independent of it.
- [169 interprocedural escape summary](169-interprocedural-escape-summary.md) — extends the perf section's
  escape field to the k-limited summary.
- [162 interface/IR serialization](162-interface-serialization-opt.md) — the on-disk format the `.nmi`
  emit serializes the store into; this task's canonical encoding is upstream of it.
- [`internals/inference.md`](../../internals/inference.md) — the design home ("Fact store").

## Sequencing

Independent of 166/168/169 and of 164's engine and emit — can land in parallel with any of them. Precedes
164's integration, which assumes the store exists. The in-memory scope here is the floor; the on-disk
`.nmi` serialization (162) and the real write wiring (164) ride on top.
