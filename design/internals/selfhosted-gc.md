# Self-Hosted GC

**Status:** design draft (task 150). Bringing the garbage collector up in Nomu itself, one mechanism per
rung, each rung diffed against the matching MMTk plan as a correctness oracle. This is the GC half of
self-hosting the runtime ([128](../plans/tasks/128-self-hosting-runtime.md)); the scheduler half stays
under 128, and [127 LXR](../plans/tasks/127-lxr-collector.md) is the final rung. Status tags:
**Decided**, **Leaning**, **Deferred**, **Open**.

**Scope of this draft.** The **ladder architecture + methodology**, the **shared substrate** that carries
across every rung, and **rung 1 (NoGC)** in depth — the build-now deliverable. Rungs 2–4 are specified at
sketch depth (the task card holds their ordering rationale); they deepen as each is reached.

**Rung 1 progress — slice A built.** The bump-allocator **policy** is written in Nomu over the 125 raw
surface, under 149's subset rules: a `RawPtr` control block holds `{ base, cursor, limit }` (metadata in
the arena — no globals, no heap object), `bumpNew` carves an off-heap OS block, `bumpAlloc` bumps
fixed-size chunks and returns null on overflow. It compiles under `--runtime-subset=bumpNew,bumpAlloc`
with no violations (the first real client exercising the 125↔149 interlock), and is byte-identical under
NoGC and Immix-evacuation (`examples/bump_alloc.nomu` + `tools/bump-alloc.sh`). **Slice B foundation built — the runtime prelude.** The allocator now lives in `src/stdlib/runtime.nomu`,
a second embedded prelude compiled into every program (beside `core.nomu`) and **runtime-subset by
default** — the proper "designated file" for 149, replacing the interim `--runtime-subset` flag. Its
functions (`rtArenaNew` / `rtBumpAlloc`) are auto-subset-checked (a violation injected into the prelude is
flagged with no flag given) and callable from user code with no import (`examples/rt_prelude.nomu` +
`tools/rt-prelude.sh`).

**Rung 1 complete — slice B built. The self-hosted allocator is a selectable plan.** Under
`NOMU_GC_PLAN=nomu` the codegen alloc seam (`__nomu_gc_alloc`, `LLVMGenRuntime.swift`) routes every managed
allocation at the Nomu bump allocator: the extern flag `__nomu_selfhosted_alloc` (a Rust `AtomicU8` set in
`nomu_gc_init`, mirroring `__nomu_barrier_active`) disables the MMTk-TLAB fast path and branches the slow
path to `__nomu_selfhost_alloc`, which lazily creates one arena (`rtArenaNew`) and bumps chunks
(`rtBumpAlloc`). The `addrspace(1)` object is produced at the seam via `ptrtoint`→`inttoptr` to `p1` — the
same integer→`p1` step the fast path uses, which `RewriteStatepointsForGC` accepts as a fresh GC base
(no `addrspacecast`, no `blessManaged` intrinsic, no FFI). MMTk is initialized NoGC and left idle as the
diff oracle. Type-id headers are stamped by codegen at the construction site (the existing contract),
so the allocator returns zeroed memory and never handles a `p1`. **Validated by the differential
(`tools/selfhost-gc.sh`):** class objects, closures, arrays, and a heavy allocation loop are byte-identical
under `NOMU_GC_PLAN=nogc` (MMTk) and `NOMU_GC_PLAN=nomu` (self-hosted); the full existing GC suite (through
GenImmix) is unaffected. **Known limits (first cut):** a single 256 MiB arena with no refill (overflow
returns null → a large-heap program would fault) and per-carrier state is process-global (single arena,
not per-carrier) — both are follow-ups before the heavier rungs. **Next: rung 2 (mark-verify).**

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
2. **Mark-verify** (diagnostic, no reclaim) — trace from roots, mark live, and emit an address-independent
   **fingerprint** of the marked set (§6); a separate MMTk run emits its own, and the two are diffed.
   Proves root scanning + tracing with zero reclamation or movement. A checkpoint; the heap still only
   grows.
3. **Immix** (non-generational) — the first real collector: line/block reclamation + evacuation (movement
   + pointer fixup) + region management. Diff against MMTk's non-generational Immix.
4. **GenImmix** — add the nursery, write barrier, remembered set. The one new variable is the
   generational layer, with self-hosted Immix as the reference. Diff against MMTk GenImmix.

Then [127 LXR](../plans/tasks/127-lxr-collector.md): swap reclamation to RC-primary; LXR uses Immix
backing, so rung 3's region machinery carries in.

**The method is the differential oracle — with clean collector separation.** Each rung runs the same
program two ways — under the new self-hosted plan and under the matching MMTk plan — and compares the two
runs. One variable enters per rung, with the previous rung (and MMTk) as the oracle, so a regression
bisects to the one mechanism just added. This is the harness `tools/arr-gc.sh` / `tools/gc-stress.sh`
already run (NoGC-vs-Immix differential); the self-hosted plan slots in as a third selector beside
`nogc` / `immix` (§6).

**One collector per process — never co-resident.** A run binds exactly one plan at init (one heap, one
allocator, one collector); MMTk and the self-hosted collector are both linked but mutually exclusive, so
two collectors never manage one heap. Comparison is always **across two separate runs**, including for
mark-verify: each side emits an address-independent fingerprint of its live set and the fingerprints are
diffed (§6), which keeps the collectors decoupled in every live process. The one case a fingerprint diff across runs cannot serve
is a **nondeterministic (concurrent) program**, whose two runs may legitimately reach different heap
states — so mark-verify runs on the deterministic single-threaded fixtures (as the GC fixtures already
are). Co-running as a passenger is held as a deferred fallback *only* for validating liveness under real
concurrency (§7); the ladder does not use it.

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

**As built (slice B):** the self-hosted plan disables the inline fast path entirely and routes every
allocation through the seam's slow path to the Nomu allocator, producing `p1` via `ptrtoint`→`inttoptr`
at the seam. Keeping the inline fast path and having the Nomu allocator populate its cursor/limit (the
speed win described below) is a **perf follow-up** — correctness rung 1 takes the simpler slow-path-only
route. The rest of this section is the design intent for that follow-up.

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
  the type-id side tables (`nomu_gc_typemap`, kind/stride) to scan objects and mark the transitive live
  set, then emits an **address-independent fingerprint** of that set (§6). A separate MMTk run emits its
  own from its authoritative liveness; the two fingerprints are diffed across runs (clean separation, §1
  — no passenger tracer). Proves root scanning + object-model tracing in Nomu with no reclamation or
  movement. The object-model accessors (size, per-element pointer map) move into Nomu here, reading the
  same static tables the Rust binding reads today. The root-source mechanism — how the Nomu tracer
  reaches roots — is pinned in §9 (one `pcsp`-shaped frame-pointer-free stack walk, a single route across
  native targets); rung 2 comes up first on the existing C walk as scaffolding, then swaps in the Nomu walk.
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
- **Rung 2 — the live-set fingerprint.** Mark-verify compares liveness across two separate runs (clean
  separation, §1), so the comparison is over an **address-independent fingerprint** rather than raw object
  identity: at a forced GC point each side, from its own authoritative live set, emits (a) per-type live
  object counts / live bytes (MMTk already computes live bytes via `count_live_bytes_in_gc`) and (b) a
  canonical-order content hash over each live object's `(type-id, scalar field bytes)`, walking from roots
  in a deterministic order. Matching fingerprints prove the self-hosted tracer marked exactly the
  reachable set — catching both a missed live object and a wrongly-marked dead one (dead objects sit on
  the NoGC-growth heap, so a false mark shows up in the hash). Fixtures are deterministic single-threaded
  programs so the two runs reach the same heap state.
- **Rung 3+.** Immix / GenImmix reuse the arr-gc / gc-stress byte-identical-under-evacuation checks, now
  with the self-hosted plan as the collecting leg.
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
- **Passenger co-running for concurrent liveness.** The ladder keeps the collectors cleanly separated —
  one per process, compared across runs (§1). The single case a cross-run fingerprint diff cannot serve is
  validating liveness under a **nondeterministic (concurrent) program**, whose two runs may reach
  different heap states. Running the self-hosted tracer as a read-only passenger inside an MMTk process
  (same-instant heap, per-object diff) is held as a fallback for that case only; the ladder does not use
  it, and mark-verify stays on deterministic fixtures. — **Deferred.**

## 8. Open questions

- **Per-carrier state access** — the exact intrinsic shape Nomu uses to reach the current carrier's bump
  state (149 allowlist), and how it composes with the no-hoist-across-safepoint contract.
- **`addrspace(1)` production** — **Resolved.** The Nomu allocator returns a `RawPtr`; the seam produces
  the managed object with `ptrtoint`→`inttoptr` to `p1` (the fast path's existing integer→`p1` step), which
  `RewriteStatepointsForGC` treats as a fresh GC base — no `addrspacecast`, no `blessManaged` intrinsic
  (§7), no FFI. The production stays compiler-emitted at the seam; the allocator never handles a `p1`.
- **Side-table reachability** — confirming the codegen-emitted static tables (`nomu_gc_typemap`, …) are
  addressable from Nomu at rung 2 (static symbols reached as `RawPtr`), and whether the accessor is a
  language intrinsic or plain raw reads.
- **Root-source mechanism** — **Resolved (§9).** GC root scanning is a frame-pointer-free `pcsp`-shaped
  stack walk over a PC-keyed root map, one route across the native targets; rung 2 brings the tracer up on
  the existing C walk first, then swaps in the Nomu walk under the fingerprint-diff guard. wasm uses a
  shadow stack (deferred, §9).
- **Hosted vs. bootstrap split** — the ladder runs hosted alongside the existing runtime; which pieces
  need the per-arch bootstrap floor (128) and when, versus staying hosted through rung 4.

## 9. Root scanning — the walk mechanism (rung 2 root source)

**Decided.** GC root scanning is a **stack walk**: from each safepoint it reconstructs the live Nomu
frames and reads their pointer slots. It runs at every collection, on the pause path, so the walk is the
performance-sensitive case — separate from exception unwinding and debugger backtraces, which are rare and
tolerate a slow, full-featured mechanism. The walk mechanism is pinned below.

**Two things the walk needs per frame:** (a) the frame boundary + return address, to step to the caller;
(b) which slots hold live pointers — the roots. Part (b) is the precise stackmap, inherent to precise GC
and already emitted (`__llvm_stackmaps` v3; the per-statepoint slot records the C walker reads at
`runtime.c`). Part (a) is where the mechanism choice lives.

**Three candidate mechanisms for (a):**
- **CFI / DWARF interpreter** (what libunwind does). General — any frame, any PC, full register recovery —
  and the standard tables external debuggers/profilers consume. A per-frame bytecode interpreter (slow)
  and a runtime library dependency; ill-suited to the GC's frequent walk.
- **Frame-pointer chain.** Two loads per frame via a reserved FP register. Fast to walk, and carries an
  always-on cost on ordinary execution (the reserved register + prologue save/restore — ~1–2% on x86-64
  where registers are scarce), and is wrong at arbitrary PCs (mid-prologue / async).
- **Per-PC frame-size table (Go `pcsp` shape).** Read the frame size from a PC-keyed table, step by it.
  Fast to walk, reserves no register, correct at arbitrary PCs. The frame-size data it needs is already in
  the stackmap (per-function `StackSize` in the v3 function records, read at `runtime.c`).

**Pin — one `pcsp`-shaped route for all native targets.** The root map is PC-keyed, with SP-relative slot
offsets and a per-function frame size. The GC walk is frame-pointer-free: read the current SP/PC, look up
the record, read the roots, add the frame size, repeat — stopping at the first return address with no
record (the Nomu→C boundary; roots live only in Nomu frames because safepoints are inserted only in Nomu
code). A single compiler/runtime path across arm64, x86-64, and RISC-V. Rationale by target:
- **x86-64:** frame-pointer-free reclaims a general register — the axis the performance thesis cares about
  — while keeping the fast walk.
- **macOS/arm64:** the ABI mandates the frame pointer regardless, so `pcsp` reclaims nothing and costs
  nothing there. Measured on the GC fixtures, the whole stackmap is 0.02–0.13% of the binary, and `pcsp`
  adds no data beyond it (frame sizes already present) and no extra per-frame lookup (the record is looked
  up for slots anyway). The mandated frame pointer stays available as a free assist for debugger backtraces.
- **`.eh_frame` / compact-unwind stays emitted on every target.** External debuggers (lldb/gdb) and
  profilers read it, and it is the fallback for stepping through foreign frames under an FFI build.
  Emitting it costs binary size only, nothing at runtime.

**Frame pointers are a per-target knob, not a mechanism requirement.** Mandated where the ABI requires
(arm64), dropped where it costs a register (x86-64). The `pcsp` route works either way.

**Dependency — fixed-size frames.** A per-PC frame size assumes the frame size at a PC is a compile-time
constant. A frame doing dynamic stack allocation (`alloca` / variable-length stack storage) has no
constant size and would need a frame pointer for that frame. Nomu's stack strategy (104) keeps frames
fixed-size, which keeps the `pcsp` walk total; revisit if dynamic stack storage is ever added.

**Trajectory.** The PC-keyed table is the first of a `pcsp`/`funcdata` family. When a sampling profiler or
async preemption arrives (arbitrary-PC stops), extend the same table with per-PC register-recovery columns
rather than adopting a general DWARF interpreter — Go runs its profiler and `defer`-on-panic off exactly
such tables while keeping consumption fast. The rung-2 root map is shaped (keyed by return address, per
PC) so those columns add without a reformat.

**wasm — a separate root scheme. Deferred.** WebAssembly exposes no addressable native call stack, so
neither a frame-pointer chain nor a `pcsp` walk applies. Precise roots on wasm come from an explicit
shadow stack (or WasmGC / host GC). The root-source interface is shaped so a shadow-stack implementation
replaces the stack walk without disturbing the tracer. — **Deferred.**

**lldb is decoupled from this choice.** External debuggers unwind with their own machinery over the
`.eh_frame` / DWARF the backend emits, not the runtime walker, so they keep the full feature set (register
recovery, inline frames, variable inspection) regardless of the GC's `pcsp` walk. Keeping frame pointers
where the ABI has them and continuing to emit standard unwind + debug info is what keeps lldb working;
preserving debug locations through `RewriteStatepointsForGC` keeps its source view accurate (a test
obligation). The built-in per-fiber backtrace rides the same `pcsp` walk for the frame list + line numbers;
register/variable inspection is left to lldb over the emitted DWARF.

**Rung 2 sequencing — building the tracer before the walk (revised).** Rather than borrow the C stack
walk as throwaway scaffolding, rung 2 builds the tracer, marking, and fingerprint first in Nomu **seeded
from an explicit root**, on single-root-reachable fixtures diffed against MMTk. This removes root discovery
as a variable while the tracer is validated, keeps every new line in Nomu (no runtime.c growth), and lands
the reusable collector code first. Root discovery then follows as its own step — the `pcsp` root map +
frame-pointer-free Nomu walk — swapping the seed for real stack roots under the fingerprint-diff guard.

**Rung 2 progress — increments 1–2 built.**
- **Increment 1 · side-table reachability (built).** The Nomu tracer reads the codegen-emitted per-type-id
  side tables (size, kind, stride, managed-pointer map; `c-types.md` §1/§3.2) through six `RawPtr.gcType*`
  accessors that lower to the existing runtime accessors — **no new runtime C**. Differentially validated:
  a Nomu-side table dump is byte-identical to the C `NOMU_GC_TYPEMAPS` dump in one process
  (`examples/mark_types.nomu` + `tools/mark-types.sh`).
- **Increment 2 · seed-based mark (built).** `rtMarkVerify` (runtime prelude, subset code) traces the
  transitive live set from a seed root and marks each object with a header mark bit (bit 32 of the header —
  the type-id occupies the low 32 bits, high bits zero, so marking leaves the type-id recoverable). No
  reclaim, no move. `addrOf(obj)` (a `ptrtoint` on the managed `p1`, codegen-only) supplies the seed.
  Validated on a graph exercising reachability, a shared child counted once (the mark bit), and a dead
  heap object excluded (`examples/mark_verify.nomu` + `tools/mark-verify.sh`).
- **Increment 3 · address-independent fingerprint (built).** Each live object contributes its type-id and
  its scalar (non-pointer) field words to a summed, order-independent fingerprint; every managed slot and
  the header are skipped, so no address enters it. Because it excludes addresses, it is byte-identical
  across the two GC plans (MMTk and the self-hosted allocator use different address ranges) — the sharp
  test that no pointer leaked in, and the precondition for the cross-run diff. Word-granularity for now
  (8-byte-aligned fields; sub-word scalars are a later refinement).
- **Increment 4 · array coverage (built).** `examples/mark_verify_arr.nomu` seeds from an `Array<Box>`
  handle, exercising the tracer's variable-size (`kind==1`) path in both the mark loop and the content hash:
  the handle's `bufptr` is followed into the buffer, each element slot scanned via the per-element pointer
  map, and every live Box marked. `TOTAL 5` (handle + buffer + 3 Boxes) tests buffer scanning; the
  fingerprint stays address-independent across plans (element pointers excluded, scalar words folded).
- **Remaining (later increments):** the **MMTk-side fingerprint** in the same summed form + a
  `tools/mark-verify` cross-run diff (the differential oracle replacing the fixture's known live set);
  then the `pcsp` root map + frame-pointer-free Nomu walk to replace the seed with real stack roots.
