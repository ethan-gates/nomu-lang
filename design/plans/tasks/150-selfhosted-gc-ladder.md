# Self-hosted GC bring-up ladder (NoGC → mark-verify → Immix → GenImmix)

**Avenue:** Risk (the core bet) · **Type/Lifecycle:** `runtime · in-progress` (runtime + GC + backend) ·
**Size:** XL · **Status:** 150.2 (mark-verify) substantially built (tracer + cross-run fingerprint diff,
150.2.1–150.2.8); collector-policy ladder continues at 150.3 (Immix); full-runtime root-scanning
integration handed to [128](128-self-hosting-runtime.md) (128.3) ·
**Source:** distilled from [128 self-hosting](128-self-hosting-runtime.md), 2026-08-25

The ladder's rungs are the subtasks: **150.1** NoGC, **150.2** mark-verify, **150.3** Immix, **150.4**
GenImmix (canonical list in ## Subtasks). "Rung N" stays as the ladder metaphor in prose; 150.N is the
tracking reference.

**► 150.1 (NoGC) · slice A built.** The bump-allocator policy written in Nomu over 125 raw memory, under 149's
subset rules: a `RawPtr` control block `{ base, cursor, limit }`, `bumpNew` (carve an off-heap block),
`bumpAlloc` (bump + overflow→null). Compiles under `--runtime-subset=bumpNew,bumpAlloc` (first real
125↔149 client); byte-identical under NoGC and Immix-evacuation. `examples/bump_alloc.nomu` +
`tools/bump-alloc.sh`; design `internals/selfhosted-gc.md` §3.

**► Slice B foundation built — the runtime prelude.** The allocator now lives in `src/stdlib/runtime.nomu`
(embedded, compiled into every program, runtime-subset by default — the 149 "designated file"). Auto-subset
verified, callable from user code (`examples/rt_prelude.nomu` + `tools/rt-prelude.sh`). The
`addrspace(1)`-production question is **resolved**: the allocator returns a `RawPtr`, the seam does
`ptrtoint`→`inttoptr` to `p1` (the fast path's existing integer→`p1` step) — no `addrspacecast`, no
intrinsic.

**► Slice B built — 150.1 complete.** `NOMU_GC_PLAN=nomu` routes every managed allocation at the Nomu
allocator: an extern flag (`__nomu_selfhosted_alloc`, Rust `AtomicU8` set in `nomu_gc_init`) disables the
MMTk fast path and branches the seam's slow path to `__nomu_selfhost_alloc` (lazy arena + `rtBumpAlloc`,
`ptrtoint`→`inttoptr` to `p1`); MMTk runs NoGC-idle as the diff oracle. Class objects, closures, arrays,
and heavy allocation are byte-identical under `nogc` vs `nomu` (`examples/selfhost_gc.nomu` +
`tools/selfhost-gc.sh`); the full GC suite (through GenImmix) is unaffected. First-cut limits: single
256 MiB arena, no refill; single (not per-carrier) arena.

**► 150.2 (mark-verify) substantially built — tracer + cross-run fingerprint diff (150.2.1–150.2.8).** In
Nomu (`src/stdlib/runtime.nomu`), Sema, and codegen, with `runtime.c` untouched except one force-collect
wrapper. The Nomu tracer reads the codegen type tables, marks the transitive live set from a root (header
mark bit), and folds an address-independent content fingerprint; a self-hosted `pcsp` stack walk
(`rtCollectRoots`, frame-pointer-free, libc-free) recovers real roots, validated against the C libunwind
walk across multiple frames. The independent oracle now closes the loop: MMTk emits the **same** summed
fingerprint over **its** authoritative live set (`mv_obj_hash` + `scan_object` hook under
`NOMU_GC_MARKVERIFY`), and a fixture forces one GC (via a new `RawPtr.gcForceCollect()` intrinsic) then
runs the Nomu tracer over the same real roots — asserting the two fingerprints match in one run
(`examples/mark_verify_oracle.nomu` + `tools/mark-verify-oracle.sh`). Per-increment log (150.2.1–150.2.8):
`selfhosted-gc.md` §9. **Remaining root-scanning work is handed to [128](128-self-hosting-runtime.md) (128.3)**
— the full-runtime root-scanning integration (self-hosted STW over all mutators = 128.3.2, parked-fiber +
scheduler-root sources = 128.3.1) couples to the scheduler/carrier machinery, so it lands there.
**Collector-policy ladder continues at 150.3 (Immix):** reclaim + move.

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

1. **150.1 · NoGC** — bump allocator + all plumbing (the [125](125-unsafe-raw-memory.md) unsafe surface, the
   bootstrap path, stack-map emission). Everything but collection.
2. **150.2 · Mark-verify (diagnostic, no reclaim)** — trace from roots, mark live, compare the live set against
   MMTk's. Proves root scanning + tracing with zero reclamation or movement machinery. A checkpoint like
   NoGC; the heap only grows. Cheap — it adds no allocator work.
3. **150.3 · Immix, non-generational** — the first real collector: line/block reclamation + evacuation (movement
   + pointer fixup) + region management. With liveness already trusted from 150.2, a bug here localizes
   to reclaim / move / region — and those fail distinguishably (reclaim leaks or frees early, move leaves
   a stale pointer). Diff against MMTk's non-generational Immix.
4. **150.4 · GenImmix** — add the nursery, write barrier, remembered set. The only new variable is the
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

## Subtasks

The ladder rungs, as tracking references. 150.2's increments are logged per-increment in
`internals/selfhosted-gc.md` §9.

- **150.1 — NoGC.** Self-hosted bump allocator + all plumbing. **Complete.**
- **150.2 — Mark-verify.** Tracer + address-independent live-set fingerprint, self-hosted root walk, and the
  MMTk-side fingerprint oracle. **Substantially built** (150.2.1–150.2.8):
  - 150.2.1 — side-table reachability (Nomu reads the codegen type tables).
  - 150.2.2 — seed-based mark (transitive live set, header mark bit).
  - 150.2.3 — address-independent content fingerprint.
  - 150.2.4 — array (variable-size) coverage.
  - 150.2.5 — `__llvm_stackmaps` access + v3 parse, libc-free.
  - 150.2.6 — the pcsp current-stack walk (`rtCollectRoots`) + real-root integration.
  - 150.2.7 — multi-frame walk, differential vs the C libunwind walk.
  - 150.2.8 — MMTk-side fingerprint + cross-run diff (the independent oracle; `RawPtr.gcForceCollect()`).
  - *Handed off:* full-runtime root-scanning integration (parked-fiber/scheduler-root walk, STW over all
    mutators) → [128.3](128-self-hosting-runtime.md) (128.3.1 / 128.3.2).
- **150.3 — Immix (non-generational).** First collector that reclaims + moves. **Next.**
- **150.4 — GenImmix.** Nursery + write barrier + remembered set.
- Then [127 LXR](127-lxr-collector.md): reclamation swapped to RC-primary, on 150.3's region machinery.

## Refs

[128 self-hosting](128-self-hosting-runtime.md); [127 LXR](127-lxr-collector.md);
[125 unsafe raw memory](125-unsafe-raw-memory.md); `memory-model.md` §3 (object model / VMBinding);
`runtime.md` (mutator, safepoints); `backend.md` (barriers).
