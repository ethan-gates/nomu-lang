# Self-Hosted GC

**Status:** design draft (task 150). Bringing the garbage collector up in Nomu itself, one mechanism per
rung, each rung diffed against the matching MMTk plan as a correctness oracle. This is the GC half of
self-hosting the runtime ([128](../plans/tasks/128-self-hosting-runtime.md)); the scheduler half stays
under 128, and [127 LXR](../plans/tasks/127-lxr-collector.md) is the final rung. Status tags:
**Decided**, **Leaning**, **Deferred**, **Open**.

**Scope of this draft.** The **ladder architecture + methodology**, the **shared substrate** that carries
across every rung, **rung 1 (NoGC)** in depth (§3), **rung 2 (mark-verify)** built with a per-increment
log (§9), and **rung 3 (Immix)** in depth (§10) — the current build target. Rung 4 (GenImmix) stays at
sketch depth (§4) and deepens when reached, after the scheduler self-host (`horizon.md`).

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
  into GenImmix and LXR. Diff against MMTk Immix. **In depth: §10** (mark-verify built, so rung 3 is the
  current rung).
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

**150.2 (mark-verify) progress — 150.2.1–150.2.8 built. Single-thread root scanning + the cross-run
fingerprint diff are complete and oracle-checked.** ("Increment N" below = subtask 150.2.N.)
- **150.2.1 · side-table reachability (built).** The Nomu tracer reads the codegen-emitted per-type-id
  side tables (size, kind, stride, managed-pointer map; `c-types.md` §1/§3.2) through six `RawPtr.gcType*`
  accessors that lower to the existing runtime accessors — **no new runtime C**. Differentially validated:
  a Nomu-side table dump is byte-identical to the C `NOMU_GC_TYPEMAPS` dump in one process
  (`examples/mark_types.nomu` + `tools/mark-types.sh`).
- **150.2.2 · seed-based mark (built).** `rtMarkVerify` (runtime prelude, subset code) traces the
  transitive live set from a seed root and marks each object with a header mark bit (bit 32 of the header —
  the type-id occupies the low 32 bits, high bits zero, so marking leaves the type-id recoverable). No
  reclaim, no move. `addrOf(obj)` (a `ptrtoint` on the managed `p1`, codegen-only) supplies the seed.
  Validated on a graph exercising reachability, a shared child counted once (the mark bit), and a dead
  heap object excluded (`examples/mark_verify.nomu` + `tools/mark-verify.sh`).
- **150.2.3 · address-independent fingerprint (built).** Each live object contributes its type-id and
  its scalar (non-pointer) field words to a summed, order-independent fingerprint; every managed slot and
  the header are skipped, so no address enters it. Because it excludes addresses, it is byte-identical
  across the two GC plans (MMTk and the self-hosted allocator use different address ranges) — the sharp
  test that no pointer leaked in, and the precondition for the cross-run diff. Word-granularity for now
  (8-byte-aligned fields; sub-word scalars are a later refinement).
- **150.2.4 · array coverage (built).** `examples/mark_verify_arr.nomu` seeds from an `Array<Box>`
  handle, exercising the tracer's variable-size (`kind==1`) path in both the mark loop and the content hash:
  the handle's `bufptr` is followed into the buffer, each element slot scanned via the per-element pointer
  map, and every live Box marked. `TOTAL 5` (handle + buffer + 3 Boxes) tests buffer scanning; the
  fingerprint stays address-independent across plans (element pointers excluded, scalar words folded).
- **150.2.5 · stack-map access + parse (built).** Toward real roots: the `__llvm_stackmaps` (v3)
  section is reached from Nomu **libc-free** via the linker section-bracket symbols
  (`section$start$…`/`section$end$…`, `\01`-prefixed to skip Mach-O `_` mangling), exposed as
  `RawPtr.gcStackmapBase` / `gcStackmapSize` — no `getsectiondata`, no new runtime C. The v3 structure is
  parsed in Nomu (`rtStackmapEnd` + `rtU16`/`rtU32`/`rtAlign8` in the prelude), self-validated: the version
  byte is 3 and stepping every variable-length record lands the cursor exactly on the section size
  (`examples/stackmap_probe.nomu` + `tools/stackmap-probe.sh`). The existing stackmap already carries the
  `pcsp` data — per-function `StackSize` in its function records, SP/FP-relative slots in its statepoint
  records — so no new codegen root map is needed for the first cut.
- **150.2.6 · the pcsp walk + real-root integration (built).** `rtCollectRoots` (runtime prelude)
  recovers the live roots from the current stack, self-hosted and libc-free: anchor on the caller frame
  (its SP is `llvm.frameaddress` + 16, its PC is `llvm.returnaddress`), look the PC up in the parsed
  stackmap, read each `kind==3` root slot (`SP + offset`, or `SP + StackSize − 16 + offset` for the
  FP-relative slots), then step to the caller by `SP += StackSize` — no frame-pointer chain, no libunwind.
  Two anchor intrinsics (`RawPtr.gcFrameAddr`/`gcReturnAddr` → `llvm.frameaddress`/`returnaddress`) and a
  `noinline` mark on `rtCollectRoots` (so the frame intrinsics resolve to its own frame) are the only new
  codegen; no runtime C. End-to-end (`examples/walk_mark.nomu` + `tools/walk-mark.sh`): the walk recovers
  the handle of a live `Array<Box>`, hands it to the tracer, which marks the live set (handle + buffer + 2
  Boxes = 4) and emits a fingerprint **identical across both GC plans** — a stale/garbage root would fault
  or diverge, so the match proves the recovered root is real and the whole self-hosted chain (walk →
  tracer → fingerprint) is sound.
  - *Notes / limits:* the walk reads `kind==3` (stack-spilled) slots; `RewriteStatepointsForGC` spills GC
    roots to the stack, so `kind==1` (register) is not needed in practice (a later refinement if it
    appears). A root must be genuinely live at the walk's statepoint — an optimizer that drops a
    dead-after value legitimately records no root there (a fixture-design point, not a walk limit). arm64
    frame layout assumed (FP/LR pair at CFA-16); the per-arch constants generalize with the target.
  - *Constraint — the walk loop must stay in the frameaddress function (found the hard way).* The walk
    reads its caller's roots at the caller's call statepoint, and the caller only spills those roots there
    because the walk function reads memory through a pointer derived from `llvm.frameaddress` — that memory
    effect, appearing in the same function the caller calls, is what makes the optimizer keep the caller's
    live GC values spilled at the statepoint. Factoring the loop into an ordinary helper (anchor computed in
    `rtCollectRoots`, loop in a callee reading through an argument pointer) moves that effect out of the
    caller's direct callee: the caller stops spilling and its roots vanish from the statepoint (nloc drops
    to the 3 meta locations, zero roots recovered). `alwaysinline` on the helper did not fold it back
    reliably in the current pipeline. So `rtCollectRoots` keeps the frame-reading loop inline. This makes
    the current-stack walk sensitive to codegen changes; a parked-fiber or STW walk (which anchors on a
    *saved* context, where roots were already spilled at the park/safepoint) does not depend on this
    caller-spill effect, so it can factor the loop freely — the coupling is specific to reading the walk's
    own live caller.
- **150.2.7 · multi-frame walk, differential vs the C walk (built).** `examples/walk_multiframe.nomu`
  holds roots in two frames (inner: 33, 44; outer: 11, 22) and runs `rtCollectRoots` immediately before
  `sleep(0)`; under `NOMU_GC_SMOKE` the C libunwind walk runs at that same safepoint. The Nomu pcsp walk
  recovers `{33,44}` from inner and `{11,22}` from outer — stepping `inner → outer → main` and terminating
  cleanly at the C boundary — and its distinct root set matches the C walk exactly (`tools/walk-multiframe.sh`).
  This validates the frame-stepping (`SP += StackSize`, return address at `[CFA-8]`) against the proven
  oracle. Compiled with `NOMU_NO_ESCAPE=1` so the leaf `Box` roots are heap-allocated (else stack-promoted,
  the same requirement `gc-smoke` has). Single-thread root scanning is now complete and oracle-checked.
- **150.2.8 · the MMTk-side fingerprint, cross-run diff (built).** MMTk now emits the **same** summed,
  address-independent fingerprint over **its** authoritative live set that the Nomu tracer emits over the
  roots it walks — the independent oracle. `mv_obj_hash` in the Rust binding (`gcbinding/lib.rs`) ports
  `rtObjHash` term-for-term (wrapping i64, prime 1099511628211, header + managed slots skipped);
  `scan_object` (once per live object during the trace) folds it into a global sum under
  `NOMU_GC_MARKVERIFY`, reset at GC start (`stop_all_mutators`) and printed as `MMTK-FP <sum>` at GC end
  (`resume_mutators`). A Nomu fixture drives one deterministic collection through a new `RawPtr.gcForceCollect()`
  intrinsic (Sema + SSAIRToLLVM → C `rt_gc_force_collect` → Rust `nomu_gc_force_collect(mutator)` →
  `handle_user_collection_request`, using the C thread-local `rt_mutator`). Under **immix** + `NOMU_GC_MARKVERIFY`
  the fixture forces a GC (→ B), then runs the self-hosted pcsp walk + tracer over the same real stack roots
  (→ A), and asserts A == B in one run (`examples/mark_verify_oracle.nomu` + `tools/mark-verify-oracle.sh`,
  live set = Array<Box> handle + buffer + 3 Boxes = 5). Apples-to-apples now that both trace real roots: a
  missed live object or a wrongly-marked dead one moves one sum and not the other. The tracer runs *after*
  the GC, so it reads objects at their post-collection locations — fine, the fingerprint excludes addresses;
  MMTk's mark bits are side metadata, so the Nomu header bit 32 never collides.
- **Handed to [128](../plans/tasks/128-self-hosting-runtime.md) — full-runtime root-scanning integration
  (128.3).** The **parked-fiber + scheduler-root sources** (`scan_parked_fibers`, `rt_sched_head`; task
  **128.3.1**) are now built and oracle-checked there: the parked-fiber pcsp walk over a saved context, and
  the scheduler root read self-hosted via `RawPtr.gcSchedHead()` (a direct load of the C global, diffed in
  one process against a C read; `examples/sched_root.nomu`). With those, root scanning is self-hosted for all
  three source shapes buildable now — live stack, saved/parked context, and global. The one remaining piece,
  **STW-over-all-mutators integration** (invoking the self-hosted walk at a real STW safepoint over all live
  mutators; task **128.3.2**), reuses the proven saved-context walk (`rtWalkFrom`) but couples to the
  scheduler/carrier machinery (each running carrier's saved safepoint context, carrier enumeration), which is
  the scheduler half under 128 (needs 128.1).
  The collector-policy ladder proves marking/tracing/fingerprint hosted on the existing C scheduler; wiring
  the self-hosted walk into a real STW lands with the scheduler, so this slice moves to 128, and rung 3
  proceeds while it waits. The single-frame walk here uses the C libunwind walk as its in-process oracle (the
  cross-run fingerprint diff cannot serve, since a concurrent program's two runs may reach different heaps).
- **Next on the collector-policy ladder:** rung 3 (Immix) — reclaim + move (line/block reclamation,
  evacuation + pointer fixup, region management), driven off the existing C STW handshake while hosted.

## 10. Rung 3 — Immix, in depth

**Ladder placement (Decided).** Immix is where the self-hosted collector first reclaims and moves, so it
is a real functioning GC and the ladder's pause point: after it the work turns to the scheduler half
(128.1), then GenImmix (150.4) lands on the self-hosted scheduler, then MMTk retires (`horizon.md`, the
150 card). Rung 3 runs **hosted on the existing C runtime** — the C STW handshake and, where the
self-hosted STW-over-all-mutators walk is still absent (128.3.2, blocked on the scheduler), the proven
root walk over stopped/deterministic contexts. It reuses the rung-2 tracer (`rtMarkVerify`) for liveness,
so a rung-3 bug localizes to one of three added mechanisms: reclaim, move, or region management. The
oracle is MMTk's non-generational Immix, through the existing byte-identical-under-evacuation harness
(`arr-gc` / `gc-stress`) with the self-hosted plan as the collecting leg.

**What rung 3 adds over mark-verify.** Mark-verify traced, marked, and fingerprinted on a monotonically
growing heap. Rung 3 turns the heap into reclaimable, defragmenting regions and adds three mechanisms:
region-structured allocation (§10.2–10.3), line/block reclamation (§10.5), and evacuation with pointer
fixup (§10.6–10.7). The object model, the tracer's slot-walk, the pcsp root walk, and the header mark bit
carry in unchanged.

### 10.1 Match MMTk's Immix geometry (Decided)

The self-hosted Immix uses the same region constants as MMTk's Immix so the differential is
apples-to-apples and a divergence points at policy, keeping geometry out of the variable set:
- **Block** — 32 KiB, the unit acquired from and returned to the block pool.
- **Line** — 256 bytes, the unit of reclamation inside a block (128 lines per block).
- **Large-object threshold** — read from the same `__nomu_max_non_los` the codegen fast path already
  publishes (`gcbinding/lib.rs`): objects above it go to a separate non-moving large-object space (LOS),
  since the copy allocator cannot evacuate an object larger than the line/block bound. The self-hosted LOS
  is a coarse page-granular free list at first (§10.3).

Blocks come from the 125 off-heap surface (`RawPtr.alloc`), the same source rung 1 uses for its arena;
Immix carves them into lines rather than one linear bump region.

### 10.2 Region metadata (Decided: side tables in Nomu)

Immix needs per-line and per-block state: line mark marks (live/free), block state (free / recyclable /
unavailable), and per-block free-line bookkeeping. Two placements were considered:
- **In-band block headers** — reserve the first line(s) of each block for its metadata. Keeps metadata
  next to the data (cache-local on sweep) and costs a slice of every block.
- **Side tables keyed by block/line index** — a separate metadata region indexed by `(addr − heapBase) /
  lineSize`, mirroring MMTk's side-metadata layout.

**Decided: side tables**, because it matches MMTk's structure (easing the diff), keeps object layout
identical to rung 1/2 (the tracer and fingerprint stay untouched), and generalizes to the mark/forwarding
side metadata GenImmix and LXR add. The line mark table is one byte per 256-byte line (0.4% overhead);
the block table is one entry per 32 KiB. Both are allocated once over 125 raw memory at heap init, sized
to the reserved address range.

### 10.3 Allocation into recyclable space

The bump path becomes a **hole-aware bump**: allocate linearly inside a run of contiguous free lines (a
hole), and when the hole is exhausted find the next hole in the current recyclable block, or acquire a
fresh block from the pool. This is the standard Immix allocator shape:
- **Small objects (≤ line)** — the normal allocator: bump within the current hole, advance to the next
  hole / block on overflow.
- **Medium objects (> line, ≤ threshold)** — an **overflow allocator** that goes straight to fresh
  (fully empty) blocks, so a large object never has to fit in the small gaps of a recyclable block.
- **Large objects (> `__nomu_max_non_los`)** — the LOS: allocate whole pages, never moved, marked in
  place, reclaimed as whole allocations.

The per-carrier state rung 1 established (cursor/limit) generalizes to per-carrier `(cursor, limit,
currentBlock, currentHole)`; the no-hoist-across-safepoint contract on the cursor/limit load
(`runtime.md` §6) is unchanged. First cut may run single-carrier (as rung 1 did) and generalize with the
scheduler work.

### 10.4 Marking and line marking

Object marking already exists — the rung-2 tracer sets header bit 32 and walks slots through the type-id
tables (`rtMarkVerify`). Rung 3 adds **line marking**: as each live object is marked, mark the line(s) it
occupies in the line mark table. The object's exact bounds are known (start address + size from the
type-id tables), so lines are marked precisely; Immix's conservative "mark one extra line" convention (to
cover an object that abuts the next line) is available as a fallback if a precise-bounds edge case
appears. A block with no marked lines after tracing is wholly dead; a block with some marked and some free
lines is **recyclable**; a block with all lines marked is **unavailable** this cycle.

### 10.5 Reclamation (sweep)

After tracing, sweep the line mark table per block:
- **Free lines** (unmarked) rejoin their block's holes for the next allocation cycle.
- **Free blocks** (no marked line) return to the block pool for reuse; returning empty blocks to the OS
  (madvise/decommit) is a footprint follow-up (§7, Open).
- **Recyclable blocks** (mixed) are queued for the hole-aware allocator to fill next cycle.
Reclamation is the mechanism that distinguishes a leak (a marked-live line never freed) from an
early-free (a reachable object's line swept), and those fail distinguishably against the oracle: a leak
grows the heap past MMTk's, an early-free corrupts a live object the fingerprint/output then catches.

### 10.6 Evacuation (defragmentation)

Immix copies to defragment when fragmentation warrants it. The self-hosted scheme mirrors MMTk's
forward-during-trace:
1. **Select source blocks.** Before tracing, choose fragmented blocks (few live lines, many holes) as
   evacuation candidates, budgeted against available free blocks (evacuate only what fresh blocks can
   absorb — the `__nomu_max_non_los`/copy-reserve bound the binding already respects).
2. **Copy on first visit.** When the tracer reaches a live object in a candidate block that is not yet
   copied, allocate a fresh slot (the copy allocator, into non-candidate blocks), `memcpy` the object,
   and install a **forwarding record** in the original (§10.8).
3. **Fix up pointers.** The referring slot the tracer came through is rewritten to the new address; every
   later reference to the same object reads the forwarding record and is rewritten too. Because the
   self-hosted tracer already walks every managed slot (`rtMarkVerify`), the evacuating variant writes the
   forwarded address back into each slot as it visits it — one store added to the existing slot walk.

Non-candidate blocks are marked in place exactly as §10.4–10.5; only objects in candidate blocks move.
This is the "opportunistic evacuation" that makes Immix a mostly-non-moving collector with defragmentation
when needed.

### 10.7 Pointer fixup — one store on the existing slot walk

The tracer's slot walk (fixed-object managed-offset map; array-buffer per-element map) is the exact place
fixup happens: for each managed slot, read the child, follow its forwarding record if forwarded, mark the
target, and store the (possibly updated) pointer back. Roots are fixed the same way — the pcsp walk
(`rtWalkFrom` / `rtCollectRoots`) already yields the address of each root slot, so a forwarded root's slot
is rewritten in place. This keeps fixup as a small delta on machinery rung 2 built, rather than a new pass.

### 10.8 Forwarding record — where it lives (Decided: pointer in payload word 0, state in header high bits)

Evacuation needs, per object, a forwarding state (not-forwarded / being-forwarded / forwarded) and, once
forwarded, the new address. The header's low 32 bits hold the type-id and bit 32 holds the mark; the
remaining high bits are free but too few for a full pointer. Options:
- **Forwarding pointer in the original's first payload word, 2 state bits in the header high bits.** The
  object is copied before the original is clobbered, so overwriting payload word 0 of the *stale* copy is
  safe; the tracer reads the state bits, and if forwarded, reads word 0 for the target. Matches the
  classic Immix/MMTk forwarding-word approach.
- **Forwarding pointer in a side table** keyed by object address. Keeps the object bytes untouched
  (simpler to reason about) at the cost of a second side structure and a lookup per reference.

**Decided: pointer-in-payload-word-0 + 2 header state bits** — it needs no new side structure, the state
bits sit in already-free header space, and it matches the oracle's layout. Single-threaded first cut needs
no atomics on the state bits; the being-forwarded state and a CAS are added when the collector runs
concurrently (post-scheduler). The one guard is a build-time check that no managed type is smaller than
one payload word (150.3.6 verifies this against the type tables; header + ≥1 field holds for every managed
type today).

### 10.9 STW and the collection driver (Decided: hosted on the C handshake)

Rung 3 does not bring up its own stop-the-world. It runs the collection body between the existing C
`nomu_gc_stop_the_world` and `resume_the_world` (`gcbinding/lib.rs`, `runtime.c`), the handshake M6 built
and `gc-smoke-stw` validates. The self-hosted collection is: stop → collect roots (the pcsp walk over each
stopped context; single-thread/deterministic fixtures first, since STW-over-all-mutators self-hosted
scanning is 128.3.2, blocked on 128.1) → trace + mark + line-mark + evacuate → sweep → resume. When the
self-hosted scheduler lands, the same collection body drives off the self-hosted STW with no change to the
collector logic — the driver swaps, the policy holds.

### 10.10 Relationship to 125 and 149 — the moving-heap gate opens here

Rung 3 is where 125 §3.3 (interior raw pointers into a moving heap) first bites: evacuation holds raw
pointers into the from-space and to-space across the copy, and the sweep holds raw line/block pointers
across reclamation. The guarantee that makes this valid is the **`noSafepoint` region** (149): the
collection body runs with no safepoint, so no other party moves the heap under these raw pointers. Rung 3
closes 125's deferred moving-heap gate by being its first real client, the way rung 1 was 149's first
client. The collector stays subset code: it allocates through 125 (block pool, side tables), never through
`__nomu_gc_alloc`, and takes no compiler-inserted safepoint on the collection path.

### 10.11 Testing — the differential, now with a collecting leg

- **Byte-identical under evacuation.** `arr-gc` / `gc-stress` run under `NOMU_GC_PLAN=nomu` (self-hosted
  Immix) and MMTk Immix; output must match byte-for-byte, and the heap must shrink after collection rather
  than grow monotonically (the rung-1/2 invariant inverts here — reclamation is now expected).
- **A fragmentation fixture.** A program that allocates, drops interleaved objects to fragment blocks,
  then forces a collection (`RawPtr.gcForceCollect()`, built at 150.2.8) — asserting live objects survive
  at new addresses (evacuation happened), dead lines/blocks were reclaimed (heap shrank), and output
  matches the MMTk Immix leg.
- **Fingerprint still holds.** The rung-2 address-independent fingerprint (§6) is invariant under
  evacuation by construction (it excludes addresses), so it stays a live check that evacuation moved
  bytes faithfully and fixed up every pointer — a missed fixup dangles and diverges the fingerprint or
  faults.
- **Unit level.** Line marking, hole finding, block state transitions, and the forwarding record are each
  testable in isolation over a `RawPtr` block, independent of a full collection.

### 10.12 What rung 3 excludes

No nursery, no write barrier, no remembered set — the generational layer is rung 4 (GenImmix), which lands
after the scheduler self-host. The `__nomu_write_barrier` hook stays inert through rung 3 (Immix is
non-generational, `c-types.md`). Returning empty blocks to the OS is a footprint follow-up (§7). Concurrent
/ parallel collection (multiple GC workers, atomic forwarding) is out of scope; the first cut collects on
one worker under STW, and the concurrency comes with the scheduler.

### 10.13 First-cut scope (Decided) and remaining tuning

**First-cut scope, locked:** single-carrier allocator + collection (generalize per-carrier with the
scheduler, 128.1); force-evacuate all candidate blocks for a deterministic diff before tuning a
fragmentation trigger; collection driven by `RawPtr.gcForceCollect()` on single-thread/deterministic
fixtures (STW-over-all-mutators is 128.3.2, blocked on the scheduler); forwarding record as §10.8. These
match the rung-1/rung-2 discipline (single-arena first, deterministic force-collect) and keep every
increment diffable against MMTk Immix.

Remaining tuning, deferred inside rung 3 (each with the MMTk Immix oracle):
- **Copy reserve / evacuation budget** — how many blocks to hold back so evacuation never runs out of
  to-space mid-collection (MMTk reserves a fraction; pick and validate). Addressed at 150.3.8.
- **Defragmentation trigger** — the fragmentation threshold and block-selection order that replace
  force-all. Addressed at 150.3.8.
- **LOS reclamation granularity** — page-granular free list first; coalescing only if large-object churn
  in the fixtures demands it.

### 10.14 Increment ladder (150.3.1–150.3.8)

Rung 3 comes up in eight increments, each one mechanism with an oracle, mirroring the rung-2 ladder
(150.2.1–150.2.8). Canonical list + status in the 150 card's **## Subtasks**; the shape:
1. **150.3.1 — region substrate. Built.** Block pool over 125 + side metadata tables (line marks, block
   state), unit-tested (carve, index math, state transitions); no allocation change yet. Prelude
   `rtImmixNew` / `rtBlockAddr` / `rtBlockIndexOf` / `rtLineIndexOf` / `rtBlockState` / `rtSetBlockState` /
   `rtLineMarked` / `rtMarkLine` / `rtClearLine` / `rtAcquireBlock`; byte-per-entry line/block tables over
   zero-filled 125 memory; one new intrinsic `RawPtr.toInt()` (ptrtoint) for addr→index math.
   `examples/immix_region.nomu` + `tools/immix-region.sh`.
2. **150.3.2 — region-structured allocator. Built.** `rtImmixAlloc`: 8-align, bump within the current
   32 KiB block, refill a fresh block from the pool on overflow; routed behind the codegen
   self-hosted-alloc seam under `NOMU_GC_PLAN=nomu` (`nomuSelfhostAlloc`, 8192-block / 256 MiB space).
   Non-collecting, heap grows. Byte-identical to MMTk NoGC across `selfhost-gc` (classes/closures/arrays/
   heavy) and a 3-block-crossing fixture (`examples/immix_alloc.nomu` + `tools/immix-alloc.sh`). Hole
   reuse *within* swept blocks (line-granular hole scan) is not needed until recyclable blocks exist, so it
   lands with reclamation (150.3.5); objects larger than a block need the LOS (150.3.3).
3. **150.3.3 — large-object space (LOS). Built.** `rtLosAlloc`: an object larger than a block is allocated
   whole off-heap with an 8-byte link word ahead of it, linked off the space's `losHead` for later
   reclamation, never moved; `rtImmixAlloc` routes `need > 32768` there. First-cut LOS threshold is the
   block size (32 KiB) — objects that cannot fit a block; aligning it with MMTk's `__nomu_max_non_los` (so
   near-block objects also skip blocks) is an evacuation-efficiency tuning item (150.3.7), and the
   medium-object *overflow allocator* (routing >line objects to fresh blocks to avoid small holes) only
   matters once swept recyclable blocks exist, so it folds into 150.3.5. Validated by a large `Array<Int>`
   whose buffer grows past a block into the LOS (`examples/immix_los.nomu` + `tools/immix-los.sh`),
   byte-identical to MMTk NoGC.
4. **150.3.4 — line marking (diagnostic). Built.** `rtMarkVerifyImmix` traces as rung 2 and additionally
   marks each live *in-heap* object's lines (`rtMarkObjLines`; LOS objects header-marked only). A new
   intrinsic `RawPtr.gcSelfhostSpace()` reaches the space the objects live in. `rtLineMarkCheck`
   independently re-derives the line set (unmark-walk) and confirms completeness (every live object on
   marked lines) + soundness (marked-line count == live footprint), returning 0. No reclaim — a checkpoint
   like mark-verify; object marking + fingerprint are the rung-2 logic (checked cross-plan by `mark-verify`).
   `examples/immix_line_mark.nomu` + `tools/immix-line-mark.sh` (Array<Box>, 52 live, LINECHECK 0).
5. **150.3.5 — sweep reclamation (non-moving). Built — the first functioning self-hosted collector.**
   `rtImmixCollect` = clear line marks → mark live (header + line marks) → reclaim by block
   (`rtImmixSweepBlocks`: dead block → free list, mixed → recyclable, full → unavailable) → reclaim the LOS
   by whole chunk (`rtImmixSweepLos`) → unmark → reset the allocator. The allocator became hole-aware
   (`rtNextHole` scans free-line runs; `rtNextAllocBlock` draws reclaimed-free → recyclable → never-used),
   so reclaimed + recyclable space is reused and the heap does not grow when garbage was collected.
   Validated by `examples/immix_sweep.nomu` + `tools/immix-sweep.sh`: two equal garbage batches bracket a
   collection; blocks are reclaimed, the heap does not grow across the second batch, the live set survives
   (non-moving). Driven explicitly on a deterministic single-thread root set (as mark-verify drove the
   tracer); driving it automatically at a real STW so whole programs (`arr-gc`/`gc-stress`) collect
   end-to-end under `NOMU_GC_PLAN=nomu` is the driver-coupled integration (128.3.2, blocked on the
   scheduler, §10.9). The medium-object overflow allocator (§10.3) folds in here as a later refinement; the
   first cut skips holes too small for the request.
6. **150.3.6 — forwarding word + copy primitive. Built.** Header bit 33 = forwarded, new address in payload
   word 0 (§10.8). `rtCopyObject` (size read → fresh slot → `rtCopyWords` → `rtSetForwarded`),
   `rtIsForwarded` / `rtForwardingPointer`, `rtObjSize`. `rtCheckPayloadWord` confirmed **0** types lack a
   payload word (the §10.8 assumption holds for every managed type). Unit-tested in isolation (copy, forward,
   read back): `examples/immix_forward.nomu` + `tools/immix-forward.sh`.
7. **150.3.7 — evacuation + pointer fixup.** Forward-during-trace (force-all candidates), rewrite slots
   and roots. Fragmentation fixture; diff under evacuation; fingerprint invariant catches a missed fixup.
8. **150.3.8 — copy reserve + defrag trigger.** Make evacuation safe against to-space exhaustion, then
   replace force-all with a fragmentation threshold. `gc-stress` under pressure, diff vs MMTk Immix.

Then rung 3 is complete as a hosted collector; the multi-mutator STW that drives it in a real concurrent
program is 128.3.2, after the scheduler (128.1).
