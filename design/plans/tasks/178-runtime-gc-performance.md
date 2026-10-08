# Runtime / GC performance

**Avenue:** Risk (the moving-collector + mutator throughput substrate) · **Type/Lifecycle:**
`perf · runtime · gc` · **Size:** L (bucket) · **Status:** open bucket — line items accrete from the
GC-benchmarking step · **Source:** the perf home for self-hosted collector + mutator-runtime throughput,
split from the correctness/packaging/measurement tasks that were absorbing it.

## What

The throughput bucket for the runtime and collector — the analog of
[148](148-ssair-optimizer-tier.md) for the mid-end, but for the runtime floor. It holds the performance
line items for the self-hosted collector's hot paths (object scan / trace, root scan, reclamation) and
the mutator-runtime fast paths (allocation bump path, write barrier, safepoint poll — emitted inline,
`internals/backend.md`), tuned against the GC-benchmarking step where self-hosted and MMTk run side by
side (horizon "after GenImmix"). Correctness lives in [150](150-selfhosted-gc-ladder.md); measurement in
[159](159-gc-observability.md); this is where the numbers turn into changes.

## Line items

- **178.1 — shaped-scan trace speed** `[next, with 176]`. The shared scan enumerator that folds kind 0/1/2
  and shaped fields ([176](176-shaped-gc-roots.md) Stage 5) must keep the common **kind-0 flat scan at its
  current cost** — no added indirection or per-word branch on the path every ordinary object and root takes.
  The kind-2 tag-decode (read the discriminant, select the case's offsets) is paid only by objects and roots
  that are actually shaped. Validate on the benchmark harness once 176 lands: trace throughput on a heap
  with no shaped objects must not regress against the pre-176 baseline, measured in both collectors.
- **mutator fast-path tuning** `[bucket]` — the inlined alloc bump path, write barrier, and safepoint poll
  (`internals/backend.md`, [150](150-selfhosted-gc-ladder.md)); benchmarking-driven, not re-specified here.
- **root-scan cost** `[bucket]` — couples with [177](177-register-resident-gc-roots.md) (register-resident
  roots) on the mutator side.

## Dependencies & relationships

- Driven by the **GC-benchmarking step** (horizon): self-hosted vs MMTk side by side, numbers from
  [159](159-gc-observability.md), harness from [155](155-integration-suite-harness.md).
- Distinct from [150](150-selfhosted-gc-ladder.md) (correctness bring-up), [158](158-gc-packaging.md)
  (packaging), [159](159-gc-observability.md) (measurement), [177](177-register-resident-gc-roots.md) (the
  root-tax lever).
