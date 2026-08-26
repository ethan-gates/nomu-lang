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

1. **NoGC** — bump allocator + all plumbing (unsafe memory, bootstrap, stack-map emission). Everything
   but collection.
2. **Mark-verify** — trace from roots, mark, compare the live set to MMTk's. Proves root scanning +
   tracing with no reclamation or movement. A checkpoint; the heap only grows.
3. **Immix (non-generational)** — first real collector: line/block reclamation + evacuation (movement +
   pointer fixup) + region management. Diff vs MMTk Immix.
4. **GenImmix** — add the nursery, write barrier, remembered set. Diff vs MMTk GenImmix.

- [127 LXR](tasks/127-lxr-collector.md) — the final rung: swap reclamation to RC-primary once self-hosted
  GenImmix is solid. LXR uses Immix backing, so rung 3's region machinery carries in; only the
  reclamation policy changes. The ladder doubles as the experiment — real footprint/throughput numbers
  for Immix and GenImmix in Nomu tell us whether LXR's extra complexity earns its keep.

## Later under self-hosting — the scheduler + bootstrap floor

- The M:N scheduler in Nomu and the per-arch **bootstrap assembly floor** (context switch, entry / TLS /
  stack setup) stay under [128](tasks/128-self-hosting-runtime.md). The GC ladder can run hosted alongside
  the existing runtime first; the bootstrap floor pairs with self-hosting the scheduler.
  [104 fiber stacks](tasks/104-fiber-stack-strategy.md) rides that later work.

## In parallel — frontend + stdlib, independent of the runtime work

Usability work, proceeding independently of the core bet:

- [117 `for … in`](tasks/117-for-in-iteration.md), [115 error handling `?`](tasks/115-error-handling.md),
  and cheap papercuts [114 grouping parens](tasks/114-grouping-parens.md),
  [143 parser recovery](tasks/143-parser-error-recovery.md),
  [119 float literals](tasks/119-float-exponent-literals.md).
- Real, extensible [120 Array](tasks/120-stdlib-core.md) / [121 String](tasks/121-string-utf8-model.md) as
  Nomu-source types. Today they are codegen intrinsics you cannot extend, and String leaks via immortal
  buffers; making them real Nomu types wants a *safe* language-level buffer type, tracked with the stdlib
  work. A secondary goal, separate from the runtime bet.

## Settle cheaply, regardless

- [142 IR hardening](tasks/142-ir-pipeline-hardening.md) — cheapest while SSAIR is young; underlies
  incremental compilation later.
