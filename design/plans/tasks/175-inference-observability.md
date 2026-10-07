# Inference summary observability

**Avenue:** Usability · **Type/Lifecycle:** `tooling · observability · needs-design` · **Size:** M
(build-dir emit is small; the IDE phase is the larger half) · **Status:** needs-design (the build-dir
emit is close to ready — the facts already exist) · **Source:** surfacing the per-function inference
summaries the inference stack already computes.

## What

Make the compiler's **inferred per-function / per-binding summaries** visible to the developer: escape
class + placement (stack / frame promotion / fiber-local / heap), mutating-ness, shareability, cross-fiber
reachability, and lifetime/fiber-locality as those land. At minimum, emit them as a deterministic
build-directory artifact alongside the `.nmi` / `.o`. Beyond that, make them IDE-observable over LSP
(inlay hints / hover) once the LSP exists.

This is a reader over facts the inference stage already produces ([164](164-formal-inference-stage.md) /
[169](169-interprocedural-escape-summary.md), stored in the [167](167-fact-store.md) fact store) — a
formatting + surfacing feature, not new analysis.

## Why it matters for Nomu specifically

Nomu's whole premise is that memory and concurrency behavior — ownership, lifetime, placement, fiber
locality, sharing, cross-fiber reachability — is **compiler-inferred and absent from the source**. A
developer cannot read placement or sharing off the code, by design (no ownership annotations). Without a
tool, that inferred behavior is opaque: a programmer who sees an unexpected heap allocation, a missed
stack promotion, or a value treated as shared has no window into *why*. Surfacing the summaries gives that
window — for understanding performance, debugging placement, and building trust in the inference that the
core hypothesis rests on. The more the language hides, the more the tooling has to show.

## Phases

- 175.1 — **Build-directory emit.** A deterministic dump of the per-symbol inferred summaries from the
  fact store: escape class + placement, mutating-ness, shareability, cross-fiber reachability (plus
  lifetime / fiber-locality as they land). Human-readable primary form; an optional machine-readable
  (JSON) twin for tooling. Wire a `--emit-inference` flag writing `build/<stem>.inference`, consistent
  with the existing `--emit-noir` / `--emit-nmi` / `--emit-llvm` side-artifact pattern. Deterministic
  (name-sorted, no timestamps), like the `.nmi`.
- 175.2 — **Inspection surface.** A `dump-inference` view / `query` integration in the driver, mirroring
  the existing `dump-interface`, so the summaries are inspectable without hunting in `build/`. Ties to the
  driver CLI ([173](173-package-model-driver-cli.md)).
- 175.3 — **Source-span keying.** The fact store keys facts by symbol (post-mono function name); IDE
  surfacing needs facts mapped back to **source spans** (the binding / expression a placement or escape
  decision is about). Build the span ↔ fact mapping. This is the real work of the IDE half and a
  prerequisite for 175.4.
- 175.4 — **LSP observability.** Inlay hints / hover showing the inferred placement / escape / sharing at
  the relevant source span. Integrates with the LSP ([137](137-tooling-lsp-formatter.md)); gated on it
  existing.
- 175.5 — **Differential golden.** The deterministic dump anchors inference-regression tests: a body edit
  that silently changes a placement or escape class shows up as a dump diff. Folds into the differential
  stage-diffing harness ([156](156-differential-stage-diffing.md)) — a low-cost guard against silent
  inference drift.

## Dependencies & triggers

- **Rides (all done):** [164](164-formal-inference-stage.md) (the inference stage), [167](167-fact-store.md)
  (the store the facts live in), [169](169-interprocedural-escape-summary.md) /
  [166](166-points-to-graph.md) (the escape / points-to summaries). 175.1/175.2 need only these.
- **Feeds / integrates:** [137](137-tooling-lsp-formatter.md) (the LSP phase), [156](156-differential-stage-diffing.md)
  (the dump as a golden).
- **Interacts with:** [148](148-ssair-optimizer-tier.md) §148.1 (promotion reads the same summaries — the
  dump is the natural way to debug a placement decision there); [159](159-gc-observability.md) (the GC
  sibling of this — runtime-side observability, where this is compile-time-inference-side); the
  specialization observability discussed under [100](100-modules.md) §100.5 (the "a specialization I
  needed ended up in the binary anyway" remark is a sibling compiler-decision surface and could share this
  task's reporting shape).

## Refs

[`../../internals/inference.md`](../../internals/inference.md) (the inference model + fact-store sections);
`src/facts` (the fact store); `InterprocEscape.swift` (169); the `--emit-*` driver pattern
(`src/driver/sources/Driver.swift`).
