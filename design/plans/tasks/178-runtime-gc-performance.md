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
- **178.2 — shaped-root load-volatile narrowing** `[from 176.3a]`. The shaped-root egress emits every
  `String`-typed load volatile (invariant I11a) so a value relocated across a safepoint observes the
  collector's writeback. Applied to *every* `String` load it blocks LLVM from forwarding, coalescing, or
  hoisting any `String` read — a mutator tax that scales with String use ([121](121-string-utf8-model.md)).
  Narrow volatile to the loads that actually reload across a safepoint; non-safepoint `String` reads recover
  stock load optimization. Validate that a String-heavy benchmark regains load forwarding with the relocation
  oracle still green.
- **178.3 — shaped-aggregate frame cost: Option A vs. Option B** `[from 176.3, P1.2]`. The shipped Option A
  records the slot base + aggregate shape ordinal, pinning the whole aggregate across a safepoint — dead
  stores to non-shaped fields stay live, growing frame and stackmap size (an SROA spike confirmed GVN still
  forwards non-shaped field *reads* across the safepoint, so the cost is frame/stackmap size, not reload
  traffic). Option B gives shaped content a separate home so the aggregate is not pinned. Measurement-gated:
  measure Option A's frame/stackmap bloat under real String traffic, then build Option B only if it pays.
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
