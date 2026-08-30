# Near-horizon — what's next, and why in this order

The current working order. Identity numbers point into [`tasks.md`](tasks.md); this doc carries only
the sequencing reasoning. The order is editable and separate from task identity.

**Frame.** The core bet is a runtime — GC and scheduler — written in Nomu itself
([128](tasks/128-self-hosting-runtime.md)): no Rust/MMTk, no C, a tiny binary, and runtime code that
inlines into user code through the same backend. This is the differentiator behind "faster and smaller
than Go and Swift," and it is built **now**. The earlier "build late" framing was written when Nomu had
no memory management at all; MMTk/GenImmix now exists as a reference implementation to diff against,
which is what makes an incremental self-host tractable. The collector algorithm
([127 LXR](tasks/127-lxr-collector.md)) is the final question we answer *inside* the self-hosted runtime,
reached after a self-hosted GenImmix works.

**Two axes, sequenced.** Self-hosting is a *location* change (MMTk/Rust → Nomu); LXR is an *algorithm*
change (GenImmix → RC-hybrid). Doing both at once multiplies two unknowns, so we hold the algorithm
constant while moving location, then hold location constant while changing the algorithm.

## Now — the self-hosting foundation

**Status:** 125 **built** (`RawPtr`/`Ptr<T>`), 149 **slice 1 built** (runtime-prelude "designated file" +
call-graph closure check; remaining: codegen barrier/poll guards, `nosplit`, module designation), 150
**150.1 (NoGC) complete** (self-hosted allocator is a selectable plan, `NOMU_GC_PLAN=nomu`, byte-identical
to MMTk NoGC) and **150.2 (mark-verify) substantially built** (150.2.1–150.2.8; the tracer, self-hosted
pcsp walk, and MMTk-side fingerprint oracle — full-runtime root-scanning integration handed to 128.3).
**128.3.1** (self-hosted parked-fiber walk + scheduler-root) built + oracle-checked. **150.3 (Immix) in
progress — 150.3.1–150.3.6 built** (region substrate + `RawPtr.toInt()`; region-structured allocator +
LOS; line marking + verifier + `RawPtr.gcSelfhostSpace()`; **sweep reclamation — the first functioning
self-hosted collector**, non-moving, hole-aware reuse; forwarding word + copy primitive, payload-word-0
guard clean); **150.3.7 (evacuation + pointer fixup) next.** Whole-program automatic collection at a real
STW is 128.3.2. Tests:
`tools/{raw-mem,typed-ptr,raw-struct,subset,bump-alloc,rt-prelude,selfhost-gc,mark-verify,mark-verify-oracle,walk-mark,walk-multiframe,walk-parked,sched-root,immix-region,immix-alloc,immix-los,immix-line-mark,immix-sweep,immix-forward}.sh`.

- [125 Unsafe raw memory](tasks/125-unsafe-raw-memory.md) — the raw-pointer / untyped-memory surface the
  collector and allocator manipulate. The first hard prerequisite. (Its earlier "byte buffer for
  String/Array" scope was a mis-bundling; the stdlib buffer machinery already exists in codegen. The real
  deliverable is the unsafe surface the runtime needs.)
- [149 Runtime-subset mechanism](tasks/149-runtime-subset.md) — the pragmas + checking that let runtime
  code avoid recursively invoking the services it implements (no implicit GC alloc, no write barrier, no
  unplanned safepoint, controlled stack growth). Go's `//go:nosplit` / `nowritebarrier` / `noescape`
  analog. Needed before any collector code can be written in Nomu.

## Next — the self-hosted GC, climbed as a ladder

[150](tasks/150-selfhosted-gc-ladder.md) brings the collector up one mechanism at a time, each rung
diffed against the matching MMTk plan as a correctness oracle (the NoGC→GenImmix ramp that worked for the
MMTk integration, one level down):

1. **NoGC** — **complete.** Bump allocator + all plumbing, in Nomu; a selectable plan (`NOMU_GC_PLAN=nomu`)
   handing out managed objects via `ptrtoint`→`inttoptr`, byte-identical to MMTk NoGC.
2. **Mark-verify** — **next.** Trace from roots, mark, and diff a live-set fingerprint against MMTk across
   separate runs (clean-separation method, `selfhosted-gc.md` §1/§6). Proves root scanning + tracing with
   no reclamation or movement. A checkpoint; the heap only grows.
3. **Immix (non-generational)** — first real collector: line/block reclamation + evacuation (movement +
   pointer fixup) + region management. Diff vs MMTk Immix.
4. **GenImmix** — add the nursery, write barrier, remembered set. Diff vs MMTk GenImmix.

- [127 LXR](tasks/127-lxr-collector.md) — the final rung: swap reclamation to RC-primary once self-hosted
  GenImmix is solid. LXR uses Immix backing, so rung 3's region machinery carries in; only the
  reclamation policy changes. The ladder doubles as the experiment — real footprint/throughput numbers
  for Immix and GenImmix in Nomu tell us whether LXR's extra complexity earns its keep.

**The ladder pauses at Immix, and the scheduler self-host is interleaved before GenImmix.** Rung 3 Immix
is a real functioning collector — it reclaims and moves — so it is a natural resting point. At that point
the work turns to the scheduler half (128.1), for two reasons that make the interleave the right order:
GenImmix's stop-the-world over all mutators (128.3.2) reads every running carrier's saved safepoint
context, which is the self-hosted scheduler's machinery; and the generational write barrier co-designs
with the mutator/carrier path. So the order is **Immix (150.3) → scheduler self-host (128.1) → GenImmix
(150.4) → retire MMTk → LXR (127)**. Immix runs hosted on the existing C scheduler in the meantime;
GenImmix lands on the self-hosted one.

## Later under self-hosting — the scheduler + bootstrap floor

- The M:N scheduler in Nomu and the per-arch **bootstrap assembly floor** (context switch, entry / TLS /
  stack setup) stay under [128](tasks/128-self-hosting-runtime.md), and now come **after Immix, before
  GenImmix** (the interleave above). The GC ladder runs hosted alongside the existing runtime through
  Immix; the bootstrap floor pairs with self-hosting the scheduler.
  [104 fiber stacks](tasks/104-fiber-stack-strategy.md) rides that later work.
- **MMTk retires after self-hosted GenImmix.** With GenImmix reclaiming + moving generationally in Nomu
  and matching the MMTk GenImmix oracle, the MMTk/Rust collector is removed as the production path (kept as
  a test oracle is a separate open question, `selfhosted-gc.md` §7). LXR (127) then proceeds inside the
  self-hosted runtime.

## In parallel — frontend + stdlib, independent of the runtime work

Usability work, proceeding independently of the core bet:

- [117 `for … in`](tasks/117-for-in-iteration.md), [115 error handling `?`](tasks/115-error-handling.md),
  and cheap papercut [119 float literals](tasks/119-float-exponent-literals.md).
  [114 grouping parens](tasks/114-grouping-parens.md) and [143 parser recovery](tasks/143-parser-error-recovery.md)
  are shipped (143's continue-into-Sema tail rides [137](tasks/137-tooling-lsp-formatter.md)).
- [151 methods on generic types](tasks/151-generic-type-methods.md) — **shipped.** Instance methods, computed
  properties, and `static fun` now work on generic structs/classes/enums (the frontend fed the mono+codegen
  halves that already handled them). This unblocks the two items below and the real-iterables form of 117.
  Tails: type-arg inference for generic statics, and the D6 by-value read limit.
- Real, extensible [120 Array](tasks/120-stdlib-core.md) / [121 String](tasks/121-string-utf8-model.md) as
  Nomu-source types. Today they are codegen intrinsics you cannot extend, and String leaks via immortal
  buffers; making them real Nomu types wants a *safe* language-level buffer type, tracked with the stdlib
  work. **Rides [151](tasks/151-generic-type-methods.md)** (a real `Array<T>` needs methods on a generic type).

## Settle cheaply, regardless

- [142 IR hardening](tasks/142-ir-pipeline-hardening.md) — cheapest while SSAIR is young; underlies
  incremental compilation later.
