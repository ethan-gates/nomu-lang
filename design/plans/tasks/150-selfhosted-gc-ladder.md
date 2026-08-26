# Self-hosted GC bring-up ladder (NoGC → mark-verify → Immix → GenImmix)

**Avenue:** Risk (the core bet) · **Type/Lifecycle:** `runtime · design-drafted` (runtime + GC + backend) ·
**Size:** XL · **Status:** design-drafted (ladder + rung 1) — build now · **Source:** distilled from
[128 self-hosting](128-self-hosting-runtime.md), 2026-08-25

**► Design:** [`internals/selfhosted-gc.md`](../../internals/selfhosted-gc.md) — the ladder architecture +
differential-oracle method, the shared substrate reused across rungs (statepoints, the single allocation
entry point, the type-id object model), and **rung 1 (NoGC)** in depth: a Nomu bump allocator over 125
off-heap OS blocks behind the existing `__nomu_gc_alloc` entry, with the `addrspace(1)` production kept
compiler-emitted and the policy (memory source, refill, header stamping, per-carrier state) in Nomu under
149's subset rules. Rungs 2–4 at sketch depth; deepen as reached. Rung 1 ready to build.

## What

Bring the garbage collector up in Nomu itself, one mechanism per rung, each rung diffed against the
matching MMTk plan as a correctness oracle. This is the GC half of self-hosting the runtime
([128](128-self-hosting-runtime.md)); the scheduler half stays under 128. [127 LXR](127-lxr-collector.md)
is the final rung.

## The ladder

Mirrors the NoGC→GenImmix ramp that worked for the MMTk integration, one level down. GenImmix is high on
the complexity scale for a first collector — Immix regions/lines + marking + evacuation, *plus* the
generational write-barrier / nursery / remembered-set layer — so we do not jump straight to it. Each rung
adds one hard mechanism with the previous as an oracle:

1. **NoGC** — bump allocator + all plumbing (the [125](125-unsafe-raw-memory.md) unsafe surface, the
   bootstrap path, stack-map emission). Everything but collection.
2. **Mark-verify (diagnostic, no reclaim)** — trace from roots, mark live, compare the live set against
   MMTk's. Proves root scanning + tracing with zero reclamation or movement machinery. A checkpoint like
   NoGC; the heap only grows. Cheap — it adds no allocator work.
3. **Immix, non-generational** — the first real collector: line/block reclamation + evacuation (movement
   + pointer fixup) + region management. With liveness already trusted from rung 2, a bug here localizes
   to reclaim / move / region — and those fail distinguishably (reclaim leaks or frees early, move leaves
   a stale pointer). Diff against MMTk's non-generational Immix.
4. **GenImmix** — add the nursery, write barrier, remembered set. The only new variable is the
   generational layer, with self-hosted Immix as the reference. Diff against MMTk GenImmix.

Then [127 LXR](127-lxr-collector.md): swap reclamation to RC-primary. LXR uses Immix backing, so rung 3's
region machinery carries in.

## Why this shape

- **One variable per rung, each with an oracle.** A direct NoGC→GenImmix jump debugs ~five independent
  mechanisms at once with no way to bisect them.
- **Small throwaway, large reuse.** The Immix region/mark/evacuate machinery (rung 3) carries into
  GenImmix and LXR. The only disposable piece is mark-verify's diagnostic path, and it buys the single
  most valuable checkpoint: liveness correct before anything moves. A non-moving mark-sweep rung with its
  own free-list allocator was considered and dropped as pure throwaway; drop it in between rungs 2–3 only
  if Immix bring-up proves it necessary.
- **The ladder is also the experiment.** The real question is which algorithm serves best. Rungs 3–4
  produce real footprint/throughput numbers for Immix and GenImmix in Nomu, on real programs, before
  committing to LXR's extra complexity.

## Dependencies

- [125 unsafe raw memory](125-unsafe-raw-memory.md) and [149 runtime-subset](149-runtime-subset.md) — both
  hard prerequisites (the collector is written *in* the unsafe primitives, *under* the subset rules).
- Runs hosted alongside the existing runtime first; the per-arch bootstrap floor (under
  [128](128-self-hosting-runtime.md)) pairs with self-hosting the scheduler, later.

## Open / to verify

- **Immix backing shared with LXR.** The assumption that rung 3's region machinery carries into LXR
  (making the LXR rung mostly a reclamation-policy change) comes from the collector literature + MMTk
  structure, not from anything built here. Pressure-test before committing the ladder's tail.

## Refs

[128 self-hosting](128-self-hosting-runtime.md); [127 LXR](127-lxr-collector.md);
[125 unsafe raw memory](125-unsafe-raw-memory.md); `memory-model.md` §3 (object model / VMBinding);
`runtime.md` (mutator, safepoints); `backend.md` (barriers).
