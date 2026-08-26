# Self-Hosted GC

**Status:** design draft (task 150). Bringing the garbage collector up in Nomu itself, one mechanism per
rung, each rung diffed against the matching MMTk plan as a correctness oracle. This is the GC half of
self-hosting the runtime ([128](../plans/tasks/128-self-hosting-runtime.md)); the scheduler half stays
under 128, and [127 LXR](../plans/tasks/127-lxr-collector.md) is the final rung. Status tags:
**Decided**, **Leaning**, **Deferred**, **Open**.

**Scope of this draft.** The **ladder architecture + methodology**, the **shared substrate** that carries
across every rung, and **rung 1 (NoGC)** in depth — the build-now deliverable. Rungs 2–4 are specified at
sketch depth (the task card holds their ordering rationale); they deepen as each is reached.

**Frame.** The collector is written in the 125 raw-memory primitives, under the 149 subset rules. It runs
hosted alongside the existing runtime first; the per-arch bootstrap floor (under 128) pairs with
self-hosting the scheduler, later. Ordering: `horizon.md`.

**Siblings:** the object model + address spaces the collector scans are `memory-model.md` §3 and
`c-types.md` §1–§3.2 (the type-id side tables, the variable-size array object); the allocation entry
point, statepoints, stack maps, and the inline alloc/barrier/poll hooks are `backend.md` ("GC backend
substrate"); the raw primitives the collector is built from are `unsafe-memory.md` (125); the subset
rules it is written under are `runtime-subset.md` (149); the per-carrier mutator + safepoint machinery is
`runtime.md` §6.

---

## 1. The ladder and its method

GenImmix is high on the complexity scale for a first collector — Immix regions/lines + marking +
evacuation, plus the generational nursery / write-barrier / remembered-set layer — so the collector comes
up one mechanism per rung, mirroring the NoGC→GenImmix ramp that worked for the MMTk integration, one
level down:

1. **NoGC** — bump allocator + all plumbing (the 125 raw surface, the bootstrap path, stack-map
   emission). Everything but collection. The heap only grows.
2. **Mark-verify** (diagnostic, no reclaim) — trace from roots, mark live, compare the live set against
   MMTk's. Proves root scanning + tracing with zero reclamation or movement. A checkpoint; the heap still
   only grows.
3. **Immix** (non-generational) — the first real collector: line/block reclamation + evacuation (movement
   + pointer fixup) + region management. Diff against MMTk's non-generational Immix.
4. **GenImmix** — add the nursery, write barrier, remembered set. The one new variable is the
   generational layer, with self-hosted Immix as the reference. Diff against MMTk GenImmix.

Then [127 LXR](../plans/tasks/127-lxr-collector.md): swap reclamation to RC-primary; LXR uses Immix
backing, so rung 3's region machinery carries in.

**The method is the differential oracle.** Each rung runs the same program two ways — under the new
self-hosted plan and under the matching MMTk plan — and requires **byte-identical output**. One variable
enters per rung, with the previous rung (and MMTk) as the oracle, so a regression bisects to the one
mechanism just added. This is the harness `tools/arr-gc.sh` / `tools/gc-stress.sh` already run
(NoGC-vs-Immix differential); the self-hosted plan slots in as a third selector beside `nogc` / `immix`
(§6).

## 2. The shared substrate — reused unchanged across rungs

The GC integration (M6) built machinery that is collector-independent by design; the self-hosted rungs
reuse it rather than rebuild it. What carries across every rung:

- **Precise roots via LLVM statepoints.** `addrspace(1)` GC pointers + `RewriteStatepointsForGC` → stack
  maps read as precise roots (`backend.md`). Rung 1 keeps emitting these even though NoGC never reads
  them, so the plumbing is validated before rung 2 traces through it.
- **The single allocation entry point.** Every managed allocation goes through `__nomu_gc_alloc(size)
  -> ptr addrspace(1)` (`backend.md`, "single allocation" invariant), an inline entry with the
  per-carrier bump fast path inline and a slow-path call. This is the one point the ladder re-implements
  behind; the contract above it is fixed.
- **The explicit, scannable object model.** The 8-byte header carries a type-id (low 32 bits); codegen
  emits per-type-id side tables — the managed-pointer map (`nomu_gc_typemap`), fixed size
  (`nomu_gc_typesize`), and the variable-size kind + stride (`nomu_gc_typekind` / `nomu_gc_typestride`)
  (`c-types.md` §1, §3.2, `memory-model.md` §3). The self-hosted tracer (rung 2+) reads these same static
  tables from Nomu.
- **The inline barrier / poll hooks.** `__nomu_write_barrier` and `__nomu_poll` (`backend.md`) stay
  compiler-emitted; rungs fill their *policy*, not their placement.

So self-hosting moves the collector's **policy** (allocate, trace, reclaim, move) into Nomu while the
**codegen contract** (address spaces, statepoints, header, entry points) holds fixed. MMTk stays linked
as the differential oracle across the whole ladder.

## 3. Rung 1 — NoGC, in depth

**Goal.** Replace the allocator behind the single allocation entry point with a Nomu-written bump
allocator over OS memory, keep every other piece of plumbing intact, and never collect. The heap grows
monotonically; blocks are acquired from the OS and never returned. This proves the 125 surface, the 149
subset discipline, header stamping, per-carrier allocation state, and stack-map emission all work
end-to-end in Nomu, before any tracing lands.

### 3.1 Division of labor at the allocation entry point

The allocation path splits into a compiler-emitted part and a Nomu-written part:

- **Backend keeps (unchanged):** the inline fast path (load the current carrier's cursor/limit, bump,
  produce the result as `addrspace(1)`), statepoint insertion, stack-map emission, and the type-id side
  tables. The `addrspace(1)` production stays where it is already solved — a Nomu bump path cannot
  manufacture an `addrspace(1)` base without tripping `RewriteStatepointsForGC` (which rejects a GC base
  from a differing-addrspace cast, `memory-model.md` §3).
- **Nomu owns (new — subset code from 149, built on 125):** OS memory acquisition, carving raw blocks
  into bump regions, per-carrier state initialization, the **slow-path refill** (the call target the
  inline fast path branches to when the bump region is exhausted), and **header stamping** (writing the
  type-id into the 8-byte header of each fresh object).

The move re-points the slow path from MMTk's Rust into Nomu, and hands the inline fast path its
cursor/limit from Nomu-managed per-carrier state. The policy (where memory comes from, how blocks are
carved, when to refill) is Nomu; the `addrspace(1)`-producing arithmetic stays compiler-emitted. — the
**Leaning** division for rung 1; §7 records the held-back alternative (a raw-to-managed intrinsic exposed
to Nomu).

### 3.2 Memory source and layout

- **OS blocks via 125.** The allocator acquires large blocks through the 125 off-heap surface
  (`RawPtr.alloc(bytes:align:)`, an `mmap`-class entry). These are `addrspace(0)` raw memory the collector
  never scans as a heap object — they *are* the heap's backing store. NoGC never frees them.
- **Bump regions.** A block is carved into a linear bump region: a cursor and a limit. Allocation is
  cursor += size, check against limit, refill on exhaustion by carving the next block. This is the
  per-carrier TLAB shape MMTk provided, now in Nomu.
- **Header stamping.** Each object is `{ i64 header, payload… }`; the allocator writes the type-id (passed
  from the allocation site, or read from `nomu_gc_typesize` by the same id) into the header low 32 bits so
  the object is describable to the tracer at rung 2. Zero-initialization is preserved (fresh OS pages are
  zero; the bump region hands out zeroed memory).

### 3.3 Per-carrier allocation state

The allocator maintains **per-carrier** bump state (cursor, limit, current block), mirroring the
per-carrier MMTk `Mutator` (`runtime.md` §6) — one set per carrier thread (~4–16), bound at carrier init,
which bounds region count and protects the footprint thesis. Nomu code reaches the current carrier's
state through a blessed runtime intrinsic (on the 149 allowlist); the codegen contract that the fast-path
cursor/limit load is not hoisted or cached across a safepoint/suspend (`runtime.md` §6) holds unchanged.

### 3.4 Bootstrap

The allocator needs memory before the managed heap exists, so bootstrap runs entirely in the 125 raw
surface: at runtime init, acquire the first OS block via `RawPtr.alloc`; at carrier init, initialize that
carrier's bump state over a carved region. All bootstrap code is subset code (149) — it allocates nothing
through itself and takes no barrier or safepoint.

### 3.5 Subset compliance — rung 1 is 149's first real client

The allocator is the archetypal subset function: it must not allocate through itself (it uses `RawPtr`,
not `__nomu_gc_alloc`), emits no write barrier, and takes no compiler-inserted safepoint on the bump
path. 149's call-graph closure check validates exactly this, and the 125 primitives are the allowlisted
leaves that let it do real work (`runtime-subset.md` §5). The NoGC bump path leans on 149 lightly — it
avoids the forbidden emissions by construction, working over `addrspace(0)` memory — so the two can land
close together; the check is what keeps that discipline from silently regressing as later rungs add code.

### 3.6 What rung 1 excludes

No tracing, no marking, no reclamation, no movement, no barrier logic. The statepoint roots are emitted
but unread; the barrier and poll hooks stay in their inert/compiler-emitted form. The heap only grows.
Rung 1 is a checkpoint that isolates *allocation + all plumbing* from *collection*, so a bug here is an
allocation, header, or per-carrier-state bug, with nothing else in scope.

## 4. Rungs 2–4 — sketch

- **Rung 2 · Mark-verify.** The Nomu tracer reads statepoint roots (the plumbing rung 1 validated) and
  the type-id side tables (`nomu_gc_typemap`, kind/stride) to scan objects, marks the transitive live
  set, and diffs it against MMTk's live set. Proves root scanning + object-model tracing in Nomu with no
  reclamation or movement. The object-model accessors (size, per-element pointer map) move into Nomu here,
  reading the same static tables the Rust binding reads today.
- **Rung 3 · Immix (non-generational).** The first collector that reclaims and moves: line/block
  reclamation, evacuation (copy + pointer fixup), region management. With liveness trusted from rung 2, a
  bug localizes to reclaim / move / region. The region machinery is the large reusable piece — it carries
  into GenImmix and LXR. Diff against MMTk Immix.
- **Rung 4 · GenImmix.** Add the nursery, the write barrier (fill `__nomu_write_barrier` with Nomu
  logging logic — the header's logged bit is already co-designed for a one-GEP reach, `backend.md`), and
  the remembered set. Self-hosted Immix is the reference; the only new variable is the generational
  layer. Diff against MMTk GenImmix.

## 5. Relationship to 125 and 149

- **125 (unsafe raw memory).** The collector is written in `RawPtr` / `Ptr<T>`: OS blocks, header
  load/store, cursor arithmetic (`advanced(by:)`), and — at rung 2+ — reading object headers and side
  tables. Rung 1 is the first real consumer, so the 125 method surface (currently Leaning,
  `unsafe-memory.md` §4) gets pinned here against actual allocator use.
- **149 (runtime-subset).** The collector is written under the subset rules; rung 1 is 149's first client
  (§3.5). 125 §3.3 (interior-of-moving-heap raw pointers) first bites at rung 3, where evacuation holds
  raw pointers into the moving heap across relocation — the `noSafepoint` region (149) is the guarantee
  that makes that valid, closing 125's deferred gate.

## 6. Testing — the differential harness

Rung 1 extends the existing pattern (a `.nomu` example + a `tools/*.sh` asserting stdout, differentially
across GC plans; `tools/arr-gc.sh`, `tools/gc-stress.sh`):

- **Plan selector.** Add a self-hosted plan beside `nogc` / `immix` (a `NOMU_GC_PLAN=nomu`-style
  selector) that routes the allocation entry point at the Nomu allocator.
- **Rung 1 invariant.** Same program under `NOMU_GC_PLAN=nogc` (MMTk NoGC) and the self-hosted plan →
  **byte-identical output**, plus a monotonically growing heap with no corruption. This checks allocation,
  header stamping, and per-carrier state; there is no collection to diff yet.
- **Rung 2+.** The oracle sharpens: mark-verify diffs the live *set* against MMTk; Immix / GenImmix reuse
  the arr-gc / gc-stress byte-identical-under-evacuation checks, now with the self-hosted plan as the
  collecting leg.
- **Unit level.** The allocator's block carve, refill, and header stamp are testable in isolation over a
  `RawPtr` block, independent of the collector.

## 7. Held back / deferred

- **Raw-to-managed intrinsic exposed to Nomu.** An alternative to §3.1: expose a blessed
  `blessManaged(RawPtr, typeid) -> T` producing an `addrspace(1)` value at the allocation site, so the
  bump fast path itself moves into Nomu. More of the allocator in Nomu, but it puts the delicate
  statepoint-base production in front of hand-written code. Rung 1 keeps that production compiler-emitted;
  revisit if a later rung needs the fast path in Nomu. — **Deferred.**
- **Returning OS memory.** NoGC never frees blocks; whether the mature collector returns empty blocks to
  the OS (madvise/decommit) is a rung 3+ footprint question. — **Open.**
- **MMTk retirement.** MMTk stays linked as the differential oracle across the ladder. When the
  self-hosted collector fully replaces it (and whether the `VMBinding` is kept as a permanent test
  oracle) settles at/after LXR. — **Open.**

## 8. Open questions

- **Per-carrier state access** — the exact intrinsic shape Nomu uses to reach the current carrier's bump
  state (149 allowlist), and how it composes with the no-hoist-across-safepoint contract.
- **`addrspace(1)` production** — whether it stays compiler-emitted (§3.1) or moves to a Nomu intrinsic
  (§7) as later rungs need more of the path in Nomu.
- **Side-table reachability** — confirming the codegen-emitted static tables (`nomu_gc_typemap`, …) are
  addressable from Nomu at rung 2 (static symbols reached as `RawPtr`), and whether the accessor is a
  language intrinsic or plain raw reads.
- **Hosted vs. bootstrap split** — the ladder runs hosted alongside the existing runtime; which pieces
  need the per-arch bootstrap floor (128) and when, versus staying hosted through rung 4.
