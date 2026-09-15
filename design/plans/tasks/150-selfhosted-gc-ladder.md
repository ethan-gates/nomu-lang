# Self-hosted GC bring-up ladder (NoGC → mark-verify → Immix → GenImmix)

**Avenue:** Risk (the core bet) · **Type/Lifecycle:** `runtime · in-progress` (runtime + GC + backend) ·
**Size:** XL · **Status:** 150.3 (Immix) complete as a hosted collector (150.3.1–150.3.8: substrate,
allocator, LOS, line marking, sweep, forwarding, evacuation + fixup, copy-reserve/defrag trigger); the
ladder pauses here for the scheduler self-host (128.1) before GenImmix (150.4). Full-runtime root-scanning
integration (multi-mutator STW) handed to [128](128-self-hosting-runtime.md) (128.3) ·
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

**Sequencing — the ladder pauses at 150.3, and 128.1 (scheduler self-host) is interleaved before 150.4.**
Immix is a real functioning collector (reclaims + moves), so it is a natural pause point. The work then
turns to the scheduler half ([128.1](128-self-hosting-runtime.md)) before GenImmix, because GenImmix's
STW-over-all-mutators root scan ([128.3.2](128-self-hosting-runtime.md)) reads every carrier's saved
safepoint context (the self-hosted scheduler's machinery) and the generational barrier co-designs with the
carrier path. Order: **150.3 → 128.1 → 150.4 → retire MMTk → 127**. Immix runs hosted on the existing C
scheduler; GenImmix lands on the self-hosted one. MMTk retires as the production collector once self-hosted
GenImmix matches its oracle (kept as a test oracle: `selfhosted-gc.md` §7, Open).

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
- **150.3 — Immix (non-generational). Complete as a hosted collector (150.3.1–150.3.8).** First collector
  that reclaims + moves: region substrate, allocator, LOS, line marking, sweep, forwarding, evacuation +
  pointer fixup, and the copy-reserve/defrag trigger, each diffed against the MMTk Immix oracle. Design
  `selfhosted-gc.md` §10. The ladder now pauses here (per `horizon.md`): the multi-mutator STW that drives it
  in a real concurrent program is [128.3.2](128-self-hosting-runtime.md), after the scheduler self-host
  ([128.1](128-self-hosting-runtime.md)); GenImmix is 150.4. Eight increments, each with the MMTk Immix
  oracle:
  - 150.3.1 — region substrate: block pool over 125 + side metadata tables (line marks, block state).
    **Built.** Prelude `rtImmix*` (space descriptor, block pool, addr↔index math, byte-per-entry line/block
    tables), one new intrinsic `RawPtr.toInt()` (ptrtoint) for addr→index math. `examples/immix_region.nomu`
    + `tools/immix-region.sh` (adjacency, index round-trip, state transitions, pool exhaustion;
    byte-identical NoGC vs Immix, auto-subset).
  - 150.3.2 — region-structured allocator (`rtImmixAlloc`: bump within block, refill fresh block on
    overflow), routed behind the self-hosted-alloc seam (`NOMU_GC_PLAN=nomu`, 256 MiB space), non-collecting.
    **Built.** Byte-identical to MMTk NoGC on `selfhost-gc` + a 3-block-crossing fixture
    (`examples/immix_alloc.nomu` + `tools/immix-alloc.sh`). Line-granular hole reuse lands with sweep (150.3.5).
  - 150.3.3 — large-object space (`rtLosAlloc`: objects larger than a block allocated whole off-heap,
    linked off `losHead`, never moved), non-collecting. **Built.** Diff vs MMTk NoGC on a large `Array<Int>`
    (`examples/immix_los.nomu` + `tools/immix-los.sh`). First-cut LOS threshold = block size; the
    medium-object overflow allocator folds into 150.3.5.
  - 150.3.4 — line marking in the tracer (diagnostic, no reclaim). **Built.** `rtMarkVerifyImmix` marks
    each live in-heap object's lines; `rtLineMarkCheck` verifies completeness + soundness (returns 0); new
    `RawPtr.gcSelfhostSpace()` intrinsic. `examples/immix_line_mark.nomu` + `tools/immix-line-mark.sh`.
  - 150.3.5 — sweep reclamation (non-moving). **Built — first functioning self-hosted collector.**
    `rtImmixCollect` (clear lines → mark → reclaim by block + LOS → unmark → reset); hole-aware allocator
    (`rtNextHole`/`rtNextAllocBlock`) reuses reclaimed + recyclable space. `examples/immix_sweep.nomu` +
    `tools/immix-sweep.sh` (reclamation + reuse + live survival). Driven explicitly on a deterministic root
    set; automatic collection at a real STW (whole-program `arr-gc`/`gc-stress` under `nomu`) is 128.3.2.
  - 150.3.6 — forwarding word (header bit 33 + new address in payload word 0) + copy primitive
    (`rtCopyObject`/`rtIsForwarded`/`rtForwardingPointer`). **Built.** `rtCheckPayloadWord` = 0 (assumption
    holds). `examples/immix_forward.nomu` + `tools/immix-forward.sh`.
  - 150.3.7 — evacuation forward-during-trace + pointer fixup (slots + roots). **Built — the moving
    collector.** `rtImmixEvacCollect` (returns the new root) snapshots `freeCursor` as a from-space boundary
    (force-all), points the copy allocator at fresh to-space only, then `rtImmixEvacMark`/`rtEvacuate` copy
    each candidate on first visit (§10.8 forwarding record) and rewrite each managed slot + the root to the
    survivor as the trace visits it; the 150.3.5 sweep reclaims the emptied from-space. LOS never moves;
    shared/cyclic refs resolve once via the forwarded-/mark-bit guards. `noSafepoint` (149) closes 125 §3.3's
    moving-heap gate. `rtImmixCollect` (non-moving) stays separate; unifying behind a defrag trigger is
    150.3.8. `examples/immix_evac.nomu` + `tools/immix-evac.sh` (root + Box moved, value reads back through
    the fixed-up slot, fingerprint invariant, from-space reclaimed).
  - 150.3.8 — copy reserve + defrag trigger. **Built — rung 3 complete as a hosted collector.**
    `rtImmixCollectDefrag` is the general collector: `rtSelectDefragSources` reads a new per-block
    `defragTable` histogram (each block's live-line count from the last sweep) and marks a block
    DEFRAG_SOURCE (state 3) iff it is sparsely live (`0 < count ≤ 64`), capped at the copy-reserve budget
    (available empty blocks − 1/16, floor 1) so to-space never runs out — each source needs ≤ 1 to-space
    block, and budget 0 makes the collection non-moving. `rtEvacuate` keys off state 3, so one trace body
    (`rtImmixEvacMark`) serves non-moving (0 sources), force-all (all used blocks sources,
    `rtImmixEvacCollect`), and the fragmentation-selected middle. The first collection has no histogram, so
    it never moves and only seeds `defragTable`. Descriptor grew to 120 bytes (`defragTable@112`).
    `examples/immix_defrag.nomu` + `tools/immix-defrag.sh` (first collection non-moving, second compacts the
    fragmented blocks' survivors, fingerprint invariant, sources reclaimed). Remaining policy knobs (the
    threshold value, a spill-based selection order) ride on the histogram.
  - *First cut is single-carrier + `gcForceCollect`-driven on deterministic fixtures;* multi-mutator STW
    that drives it in a concurrent program is [128.3.2](128-self-hosting-runtime.md), after the scheduler.
  - 150.3.9 — whole-program moving collection on the self-hosted scheduler. **Built (forced trigger,
    single-carrier).** The bridge from [128.3.2](128-self-hosting-runtime.md) (STW + self-hosted root
    recovery) to a collecting GC: the STW walk now emits root **slot** addresses (`rtWalkFrom` gained an
    `emitSlots` mode; `nomuSchedWalkSlots`), and `rtImmixCollectRoots` runs the evacuator over that slot set
    — the multi-root generalisation of `rtImmixEvacCollect`, force-all, rewriting each slot in place with its
    survivor's forwarded address (the moving fixup on the stopped mutator stacks). Shared subgraphs and
    duplicate slots resolve through the `rtEvacuate` forwarded-bit guard. Driven by the forced-collect
    coordinator (`NOMU_STW_COLLECT`) at the 128.3.2 STW, over the self-hosted Immix space
    (`RawPtr.gcSelfhostSpace()`, requires `NOMU_GC_PLAN=nomu` + `NOMU_SCHED=nomu`). Proof is transparency: a
    force-all move relocates every live object, so a wrong slot fixup would resume the mutator on a stale
    pointer into reclaimed space; instead the program prints the MMTk/NoGC value.
    `examples/stw_collect.nomu` + `tools/stw-collect.sh` (a live Box relocated across the collection, its
    stack slot fixed up, the worker resumes and reads it → 111, output-identical to MMTk over 15 runs). This
    is the first time the Nomu collector reclaims memory at a whole-program STW on the Nomu scheduler.
    - *Heap-pressure auto-trigger.* **Built.** A GC thread (`NOMU_GC_PRESSURE`) polls the self-hosted heap's
      free-block count (`nomuGcSpaceAvail`) and, when it drops below the reserve, drives a **defrag**
      collection (`rtImmixCollectRootsDefrag` / `nomuSchedStwCollectDefrag`) at the same STW handshake —
      defrag, not force-all, because a near-full heap has no free to-space, and defrag is non-moving when
      full. The mutator stops at its next back-edge safepoint poll (a clean user statepoint), so collection
      lands between allocations and the roots are walkable. `examples/gc_pressure.nomu` +
      `tools/gc-pressure.sh`: a fiber allocates 640 MiB (a 100-Box sliding window live, the rest garbage) on
      the 256 MiB heap and survives via repeated collections, checksum-identical to MMTk NoGC — which also
      exercises internal-pointer fixup (the array buffer's element pointers relocate). Trigger reserve
      defaults to 1/8 of the heap (`NOMU_GC_TRIGGER_RESERVE` overrides).
  - 150.3.10 — multi-carrier-safe self-hosted allocator (per-carrier TLABs). **Built** (150.3.10.1 + 150.3.10.2). The current
    self-hosted allocator bumps the shared Immix space cursor (`allocCursor`/`allocLimit`, descriptor @48/@56)
    with no synchronisation, so concurrent carriers race — 150.3.9 runs single-carrier for this reason. The fix
    mirrors Go's mcache/mcentral (and MMTk's per-mutator TLABs): move the per-hole bump state
    (`allocCursor`/`allocLimit`/`allocBlock`/`allocLine`) out of the shared descriptor into a per-carrier TLAB;
    keep the block pool (`freeCursor`/`freeList`/`scanBlock`/`losHead`) shared behind a space lock. Lands after
    [128.4](128-self-hosting-runtime.md) (one carrier-boot path), so the TLAB binds off a single self-hosted
    carrier boot. Two sub-phases so a correctness bug and a codegen-perf bug can't hide in one change:
    - 150.3.10.1 — *call-through correctness split.* **Built.** Per-carrier 32-byte TLAB
      `{ allocCursor@0, allocLimit@8, allocBlock@16, allocLine@24 }`, bound `_Thread_local` per carrier in the
      C runtime (`rt_self_tlab_get`, shaped like the MMTk `rt_mutator` lazy bind) and registered in a table.
      `rtTlabAlloc` bumps privately; `rtImmixRefill` pulls a whole block from the shared pool under a new space
      lock (descriptor @120, the `rtSchedMutexLockAt` futex mutex); LOS shares that lock. The descriptor's
      `allocCursor/allocLimit/allocBlock/allocLine` (@48/@56/@72/@80) become the collector's single-threaded
      copy-allocator state. The collector resets every registered TLAB at end-of-collection (`rt_tlab_reset_all`
      in the C STW coordinators, since evacuation may relocate a carrier's current block). The seam
      (`__nomu_selfhost_alloc`) loads the TLAB and calls `rtTlabAlloc` (still a call — inline bump is 150.3.10.2).
      Also closed a latent race the split exposed: the seam's lazy creation of the process-singleton Immix space
      (`__nomu_selfhost_space`) was unguarded, so concurrent carriers each built their own 256 MiB heap — now
      double-checked locking around the create (`rt_selfhost_space_lock_*` + an acquire/release global). Proof:
      `tools/gc-concurrent.sh` (`examples/gc_concurrent.nomu`) runs four fibers allocating concurrently on 2/4/8
      carriers, checksum-identical to MMTk NoGC; `gc-pressure.sh` and `stw-collect.sh` extended to 1/2/4 carriers
      (single allocating fiber) exercise the TLAB reset. All 28 drivers green. With 150.3.13 landed,
      `gc-concurrent.sh` runs the collecting form — four fibers over-allocating 384 MiB on the 256 MiB heap,
      allocating concurrently through repeated collections, checksum-identical to MMTk.
    - 150.3.10.2 — *inlined bump fast path.* **Built.** The TLAB bump is emitted inline in the
      `__nomu_selfhost_alloc` IR (`LLVMGenRuntime.swift` `nomuSelfhostAlloc`): load cursor/limit (@0/@8),
      `need = (size+7)&~7`, `newCur = cur+need`, compare `newCur <= limit`, store the cursor, and form the
      object as `heapBaseInt(@40) + cur` via inttoptr→p1 (a fresh GC base). Only the overflow edge calls
      `rtTlabAlloc` (which refills under the space lock or routes to LOS). A hole never spans more than one
      32 KiB block, so a large-object request can never pass the `newCur <= limit` test — it takes the miss
      edge and LOS is handled there, needing no inline check. Disassembly confirms ~10 instructions (the
      cursor/limit load fuses to one `ldp`), a call only on miss — the self-hosted analogue of the MMTk fast
      path. The self-hosted analogue of the MMTk-side [133](133-fiber-pinned-mutator-cache.md) mutator-cache
      perf work. Verified against MMTk (all 28 drivers green; `gc-concurrent` at 2/4/8 carriers, with and
      without collection, 0 mismatches across heavy stress).
  - 150.3.11 — pressure trigger as the default/production path. **Built.** Collection is now the default
    self-hosted trigger, fired synchronously when an allocating mutator hits true OOM (rtImmixRefill finds no
    block), no `NOMU_GC_PRESSURE` needed. The refill's block-exhaustion path calls `rtSelfhostOom`, which
    parks the mutator at its alloc-site anchor and drives a collection, then retries the refill; it returns
    false (genuine OOM) only when a full collection leaves the heap with zero free blocks. The anchor is
    captured in the alloc seam (`__nomu_selfhost_alloc`, the immediate callee of user code) via
    `llvm.returnaddress`/`frameaddress`+16 — the RT_USER_ANCHOR convention — and threaded through
    `rtTlabAlloc`→`rtImmixRefill`→`rtSelfhostOom`, so the STW walk finds the in-flight allocation's roots.
    The park mirrors `nomuSchedSafepoint` exactly (under the scheduler lock: set anchor + state, switch to the
    carrier context; the carrier acks the STW and resumes off the stw-gen bump) — reusing the proven poll-site
    ack/state/stack machinery rather than an ad-hoc in-place block, which is what makes concurrent OOM correct.
    The OOM'ing carrier *initiates* the STW: the first into OOM sets stw-request (sched+136) under the lock and
    signals a dedicated GC coordinator pthread (`rt_gc_sync_thread`, sched+168 gc-request) which runs the same
    handshake + defrag collection as the poller; concurrent OOMs coalesce (only the first initiates). Started
    by default whenever the self-hosted allocator is active and no explicit GC-driver knob is set; the polling
    `NOMU_GC_PRESSURE` collector and the `NOMU_STW_COLLECT` smoke survive as oracle overrides. New driver
    `tools/gc-oom.sh` proves it: an over-allocating program (and the four-fiber concurrent allocator) survives
    at 1/2/4/8 carriers, checksum-identical to MMTk, with collections firing only at true OOM. All 29 drivers +
    unit tests green.
  - 150.3.12 — broader root coverage. **Built** (150.3.12.1–.3). Beyond stack roots + fiber-result boxes,
    general programs (actors, strings, `any I` value boxes) now survive a real collection: the actor
    scheduled-mailbox queue is rooted, String immortal buffers hold across a collection, and value-payload
    boxes carry a real header + map. Drivers `tools/gc-actor.sh`, `gc-string.sh`, `gc-anybox.sh`.
    - 150.3.12.1 — actor scheduled-mailbox queue root. **Built.** Under the self-hosted scheduler the
      scheduled-mailbox queue lives in the Nomu `Sched` (head at `sched+80`, tail at `sched+88`), not the C
      `rt_sched_head` that `rtScanSchedRoot` reads — so a collection mid-drain reclaimed/moved every queued
      mailbox and each message's `self` receiver + args. `nomuSchedWalkRoots` now roots the queue: it emits the
      head (object in value mode, `&sched+80` in slot mode) and, in slot mode, the off-heap tail slot
      `&sched+88`. Mailbox and message objects carry real type-id pointer maps (`mailboxTypeIdValue`:
      mb_head/mb_tail/sched_next; the per-handler message type-id: next/self/args), so rooting the head
      propagates the evacuation + slot fixup through the whole chain; the tail slot is fixed because it is
      Sched state reached through no object's pointer map. Verified by `tools/gc-actor.sh`.
    - 150.3.12.2 — immortal-space / String buffers. **Built (interim path confirmed).** String data buffers
      (`rt_alloc_immortal` → `rt_str_concat` / `rt_read_line`) are non-moving. The interim MMTk-immortal path
      holds under `NOMU_RUNTIME=selfhost`: the buffers live off-heap relative to the self-hosted Immix space,
      so `rtEvacuate`'s off-heap guard (addr < base / ≥ heapEnd → return unchanged) leaves them in place and
      the sweep never touches them — a String reads back intact across a collection. `tools/gc-string.sh`
      (`examples/gc_string.nomu`): a String-heavy program folds a content hash identical to MMTk NoGC while
      collections fire at true OOM, single- and multi-carrier. Routing immortal allocations to the self-hosted
      LOS is deferred to the MMTk-retirement pass (a self-host-purity item, not a correctness gap now).
    - 150.3.12.3 — header + pointer map for witness value-payload boxes (the 150.3.13 follow-up folded here).
      **Built.** `boxPayload` (`LLVMGenWitness.swift`) allocated `any I` value payloads header-less
      (`rtAllocManaged`, value at offset 0), so a moving collection read the value's first word as a bogus
      type-id and mis-copied/mis-scanned the payload (an out-of-range id clamps to size 0 → a 0-byte copy; a
      small in-range id copies the wrong size or scans wrong offsets). The fix applies the 150.3.13 pattern:
      the payload is now `{ header, value }` — a real type-id (`spawnBoxTypeId`, the `{header, value}` shape)
      with the value's managed-pointer map, value at offset 8. The witness ABI's offset-0 `self` contract was
      the wrinkle: the three value-payload readers now reach the value at payload+8 via a `payloadValue`
      helper — `bridgeThunkSelf` (by-value load and the by-pointer `toUnmanaged`), `propThunk`'s stored-field
      GEP. Class/actor payloads (already headered objects) are unchanged. `tools/gc-anybox.sh`
      (`examples/gc_anybox.nomu`): 64 boxed value structs survive collections under default block-on-OOM and
      force-all evacuation, read back identical to MMTk (10432); pre-fix the same program crashed/emptied
      under a moving collection. The witness suite (interfaces/composition/opaque/refinement/extensions) is
      output-unchanged. *Adjacent limitation left in place:* a value type with a managed field boxed as
      `any I` trips `RewriteStatepointsForGC` ("FCA unimplemented") — a GC pointer nested in a first-class
      aggregate crossing a statepoint — a pre-existing constraint (the `makeAnyBox` comment names it), not
      introduced here; the test uses plain-scalar value structs to stay clear of it.
  - 150.3.13 — fiber-result-box roots. **Built** (correctness bug found verifying 150.3.10.1: multi-fiber
    programs corrupted under collection). `spawn let a = worker()` compiles the fiber body to box its result in
    a managed GC object at `fib+216` (off-heap scheduler memory). The bug had two layers. (1) *Rooting:* that
    slot was never a GC root — the STW walk (`nomuSchedWalkRoots`) scans fiber *stacks* via anchors, and
    `rtSchedFiberMain` dropped the fiber from the live-fiber registry on completion — so between a fiber
    completing and its joiner reading the result, the box had no root and a collection (driven by sibling
    fibers allocating) reclaimed/moved it. (2) *Typing:* the result box (`lowerSpawn`) was allocated header-less
    (`rtAllocManaged(slots*8)`, result at offset 0), so once rooted the moving collector read the result value
    as a bogus type-id and mis-evacuated it whenever the box landed in a defrag-source block (the residual
    flake). The fix addresses both: the fiber stays in the registry after completion and the walk emits
    `fib+216` as a root slot (rooted + fixed-up in place); a per-result-type `spawnBoxTypeId` gives the box a
    real header + pointer map (`{ header, result }`, result at offset 8), so the collector relocates it and
    scans a managed result too; and a `final` flag on `spawnJoin` (the structured scope-exit join) drops the
    fiber from the registry once the box is no longer read (`rtSchedRegRemove` made idempotent; intermediate
    reads leave it registered). Repro that now passes: four `spawn let` workers over-allocating 384 MiB under
    `NOMU_GC_PRESSURE` at 1/2/4/8 carriers, checksum-identical to MMTk across the previously-flaky trigger
    reserves (`tools/gc-concurrent.sh`, now the collecting form). All 28 drivers + unit tests green.
    Follow-up (resolved in 150.3.12.3): value-payload boxes in the witness path (`boxPayload`,
    `LLVMGenWitness.swift`) were header-less the same way and mis-evacuated under a moving collection.
- **150.4 — GenImmix.** Nursery + write barrier + remembered set. **After the scheduler self-host (128.1),
  on the 150.3.9 whole-program collector.**
- Then [127 LXR](127-lxr-collector.md): reclamation swapped to RC-primary, on 150.3's region machinery.

## Refs

[128 self-hosting](128-self-hosting-runtime.md); [127 LXR](127-lxr-collector.md);
[125 unsafe raw memory](125-unsafe-raw-memory.md); `memory-model.md` §3 (object model / VMBinding);
`runtime.md` (mutator, safepoints); `backend.md` (barriers).
