# M6 — Implementation Spec (Real GC via MMTk)

**Status:** working draft — the ordered work plan for M6, derived from `memory-model.md`
(§3 GC, §6 escape analysis / cleanup, §8 performance profile), `compiler.md` (§6 C→LLVM
transition checklist, §7 GC binding), and the runtime facts in `runtime.md`. It pins the
build sequence; the *design* lives in those docs and the two decisions stamped in 6.0.5 (the open
forks are the 6.0.6 register).
**Design is still opening** — several phase approaches are `Open`; this spec records the
sequence and the question each phase must close, not a settled plan.

> Authoring conventions per `lang-project/milestone-doc-guide.md` (numbering, status markers,
> front matter, slice records, exit criteria).

**Build status (2026-07-30):** **not started.** M6 is **hard-gated on M8** (LLVM backend +
precise stack maps), reordered *before* M6 (`roadmap.md`; 6.0.5). Design-opening: the two
cross-cutting decisions (LLVM-first; mainline-GenImmix sourcing) are locked (6.0.5); the open
approaches — mutator mapping, runtime/binding boundary, safepoint poll form + density,
parked-fiber scanning, actor teardown, `String`-as-GC, witness-table scanning — are tracked as a
numbered register in 6.0.6.

**Framing correction:** the roadmap names M6 "real GC (MMTk)," but the bar is **not** "it
collects" — it is **validating the performance thesis**: a *moving* collector at ~1.1–1.3×
live-set footprint with competitive throughput (`memory-model.md` §8). A non-moving mark-sweep
prototype would clear "it collects" while validating none of the doubted bet — hence the
moving-Immix target and the M8-first reorder.

---

## 6.0 · Front matter

### 6.0.1 · Scope

**Ships in M6:**
- MMTk linked via a Rust `VMBinding`; the allocation seam routed to a mutator fast path;
  **mainline GenImmix** (moving, generational).
- A **scannable object model** — GC header + codegen-emitted per-type pointer maps covering
  every heap shape (`class`/`actor`, `Closure`, `String`, `any` box, witness table, generic
  instance).
- **Precise root scanning** — LLVM stack maps for carrier frames + globals + **parked fiber
  stacks** (a live-fiber registry).
- **Safepoints + stop-the-world handshake** across carriers and fibers; **per-carrier mutators**.
- The **generational write barrier**; GC-driven **actor teardown**; removal of the vestigial
  `refcount` header and the `rt_str_concat` header pointer-arithmetic hack.

**Deferred** (design ref):
- **LXR-style RC-hybrid collector** — the footprint endgame; a later *owned* reimplementation
  behind the same binding, never a dependency on the stalled upstream branch
  (`memory-model.md` §3; 6.0.5).
- **Escape analysis** — a perf pass (stack allocation / scalar replacement); descopable to the
  M6 tail or a follow-on (`memory-model.md` §6.1; phase 6.5).
- **User-visible finalizers** — none planned; internal actor teardown only (phase 6.4).

### 6.0.2 · Prerequisites

Grounding M6 against the current compiler (M5; C backend; bump-and-leak `rt_alloc`; vestigial
`ObjectHeader { refcount }`; M:N `ucontext` fiber scheduler):
- **M8 — LLVM backend + statepoints (the hard gate).** A moving collector needs precise roots
  via compiler-emitted stack maps the C backend cannot produce (`compiler.md` §6). M8 lands
  the LLVM path, the lower CFG/SSA IR, and statepoint stack maps; M6 rests on them. Reordered
  before M6 (decided 2026-07-30, `roadmap.md`). **8.4 (the GC substrate) is done (2026-08-03):**
  `addrspace(1)` roots, statepoint stack maps, the parser + single-stack root walk, and the three
  inert alloc/barrier/poll seams all ship — see **6.0.10** for the concrete carry-over M6 builds on.
- **Held invariants (through M5), no pre-slice needed** — single allocation seam (`rt_alloc`)
  and an explicit scannable object model (`compiler.md` §7). They already exist.

### 6.0.3 · Compiler surface touched

Post-M8 pipeline: `… → typed IR → lower CFG/SSA IR → LLVM (statepoints, barriers) → native`.
M6 touches:
- **Codegen (LLVM)** — GC header on every heap object; per-type **pointer maps** as static
  tables keyed by a header type-id; **statepoint** safepoints (maps at calls / loop back-edges
  / alloc slow path); **write-barrier** inlining on reference-field stores; inlined alloc
  fast path.
- **Runtime (C + Rust binding)** — the MMTk `VMBinding` (`scan_object`, `scan_roots`,
  `block_for_gc`, resume); a **live-fiber registry**; the STW handshake; per-carrier `Mutator`.
- **IR / Sema** — the escape-analysis pass on the CFG/SSA level (6.5).

### 6.0.4 · Dependencies

```
M8 (LLVM backend + statepoints)              [hard prerequisite]
└─ 6.1 (MMTk binding + object model, NoGC)
   └─ 6.2 (precise roots + safepoints + moving Immix)
      ├─ 6.3 (GenImmix + write barrier)
      └─ 6.4 (actor teardown / finalization)
6.5 (escape analysis)   [perf tail; needs M8 IR; descopable]
```
6.1 gates all collection. 6.2 is the correctness+moving core. 6.3 and 6.4 are independent of
each other. 6.5 is sequenced last and descopable.

### 6.0.5 · Cross-cutting decisions

Closed forks (the open ones live in 6.0.6):
- **LLVM before GC — Decided (2026-07-30).** M6 validates the moving-collector performance
  thesis, which needs precise roots. The C-path bridges were rejected: conservative-pinned
  scanning degrades the footprint metric under test; a codegen shadow stack is precise but
  throwaway. So M8 lands first and the collector rests on statepoint stack maps
  (`roadmap.md`; `compiler.md` §7). Corollary: **precise roots, never conservative.**
- **Collector sourcing: mainline GenImmix; LXR planned & owned — Decided (2026-07-30; sequenced
  2026-08-04).** MMTk's value is a live borrow; mainline GenImmix is that. The LXR branch is stalled,
  so the RC-hybrid endgame is a clean *owned* reimplementation behind the same interface — nothing in
  M6 assumes LXR (`memory-model.md` §3). **Sequencing intent (2026-08-04):** LXR is a scheduled
  successor, not open-ended — targeted after M7 + the M10 debugger, gated on a **benchmark-scale
  stdlib** (LXR is the footprint endgame; validating it against Immix needs large real programs to
  measure). This raises the payoff of the Q2 swappable-binding discipline (the swap is exercised on a
  real timeline) and of keeping `__nomu_write_barrier`'s shape collector-agnostic (GenImmix fills it as
  a generational logging barrier at 6.3.1; LXR refills the same seam as the RC barrier). M6 stays the
  substrate LXR reuses — GenImmix is not throwaway.
- **Mutator granularity: per-carrier thread — Decided (2026-08-04, was Q1).** One MMTk `Mutator`
  (TLAB + allocators) per carrier, bound at carrier init. Every allocation reads the *current*
  carrier's cursor/limit fresh, bumps, and overflows to `rt_alloc` on that same carrier; a fiber
  that migrates between two allocations just reads whichever carrier it now runs on. Fits MMTk's
  one-mutator-per-thread model and bounds TLAB count to the carrier count (~4–16), versus one TLAB
  per fiber under a per-fiber scheme — a footprint hit that would undercut the ~1.1–1.3× thesis.
  **Codegen contract:** the fast-path TLAB cursor/limit load must not be hoisted or cached across a
  safepoint / suspend (an allocation completes within one on-CPU slice; the 8.4 lowering already
  re-loads per alloc). Blocking-syscall fibers allocate against the offload carrier's mutator, same
  rule. Implemented at 6.1.1.
  - *Alternative not explored (possible later optimization on A, never a replacement):* **C —
    per-carrier but pin the fiber to its carrier while it holds allocation state.** The one place C
    could beat A: a fiber that allocates many objects and then reads/writes them: pinning keeps that
    fiber's allocations contiguous in the carrier's TLAB, so the objects land on fewer cache pages
    and the later access pattern is tighter. Under A, interleaved fibers on one carrier scatter each
    fiber's objects across the buffer. C is strictly an optimization over A (same footprint bound,
    added scheduler cost from constrained migration), so A first loses nothing; revisit only if
    allocate-then-traverse locality shows up as a measured cost.
- **Runtime / binding boundary: thin Rust binding, runtime stays C — Decided (2026-08-04, was Q2).**
  MMTk is Rust; its `VMBinding` trait is an irreducible Rust crate. Only that crate is Rust — a thin
  shim whose trait methods FFI back into the existing C runtime (`nomu_gc_walk_current` for roots, C
  accessors for the object model, C hooks for STW stop/resume); Rust holds ~no state. This leaves the
  built, verified M4 M:N scheduler and the C stack-map walk untouched and keeps the blast radius to
  one crate. Settled context, not reopened here: codegen emits LLVM IR (M8); the two held invariants
  (single alloc seam; explicit scannable object model, `compiler.md` §7) keep the boundary movable.
  Cost accepted: `scan_object` and per-frame root reporting cross Rust→C on the trace hot path, and
  the header + pointer-map layout is a two-language contract. Stood up in 6.1.1.
  - *Escape hatch if that FFI shows up as a measured throughput cost — **C: scheduler stays C,
    GC-facing pieces go Rust-native.*** Pull the hot callbacks into the binding crate — `scan_object`
    reads the codegen-emitted pointer maps directly (they are static data, no per-object FFI needed),
    and the libunwind root walk is reimplemented in Rust — while the C scheduler exposes a small
    coarse C ABI for STW coordination + parked-fiber-stack enumeration (called O(carriers)/O(fibers)
    once per GC, not per object). Migration needs only the pointer-map layout and a saved-context
    view, both already available, and does not touch the scheduler.
  - *Rejected: **B — move the whole runtime to Rust.*** Rewrites the working, off-critical-path M4
    scheduler (`ucontext`, poller, timer, work-stealing); does not remove the mutator-seam boundary
    (codegen emits C-ABI calls to runtime symbols regardless — B moves it, not removes it); `ucontext`
    stack-switching is `unsafe` in Rust anyway, so the safety win lands mostly on code MMTk owns.
    Over-scoped for M6.
- **Safepoint poll form: branch-on-flag — Decided (2026-08-04, was Q3).** `__nomu_poll` (emitted only
  at the header of call-and-alloc-free loops) lowers to: load a **per-carrier** stop-requested flag
  (thread-local, no cross-carrier cache contention), test, branch-not-taken past a call to
  `__nomu_gc_poll_slow` that parks the thread. The STW initiator sets every carrier's flag. Chosen
  because the slow-path **call is a statepoint** → it gets a stackmap at its return address → the
  poll frame is precisely scannable through the existing call-keyed walker, with no new machinery.
  A GC pointer can be live across the back-edge of a call/alloc-free loop (e.g. a linked-list
  traversal), so the poll site genuinely needs precise roots. Implemented at 6.2.3 (STW handshake).
  - *Deferred, for later profile-guided optimization — **B: protected-page faulting load.*** A poll
    load from a page the STW initiator `mprotect`s unreadable; a `SIGSEGV` / Mach-exception handler
    parks the faulting thread. Fast path is a single load (this is what the JVM ships — per-thread
    poll pointer since JDK 10). Not free for us: precise roots need a stackmap at the *poll PC*, which
    our call-keyed `RewriteStatepointsForGC` pipeline does not emit (the JVM's JIT records a GC map at
    every poll site; we would have to add poll-site maps), plus the arm64/Mach-O signal path. Pull it
    in only if profiling shows the per-iteration load+test+branch in tight call/alloc-free loops is a
    measured throughput cost.
- **Safepoint density: the 8.4 placement is the invariant — Decided (2026-08-04, was Q4).** Safepoints
  stay at non-leaf call returns + call-and-alloc-free loop back-edges + the alloc slow path. This
  already gives the cooperative guarantee — every loop iteration reaches a safepoint, so time-to-
  safepoint is bounded by one loop-body execution — and the polls are cheap (Q3 branch-on-flag) and
  elided wherever a call/alloc supplies the safepoint. The real deliverable is a **pass-pipeline rule:
  `-O` transforms (unrolling, LICM, inlining, block merging) must not delete the last safepoint from a
  loop or create an arbitrarily long safepoint-free region.** Scheduler fairness/preemption is a
  separate signal-based mechanism (`loops.md`), not the GC poll, so there is no fairness motive to go
  denser. Implemented at 6.2.3.
  - *Deferred, profile-guided — **counted-loop poll elision.*** Drop the back-edge poll from loops the
    compiler proves terminate in a bounded small trip count (rely on the post-loop safepoint), keeping
    the poll for large/unknown counts. Removes poll overhead from tight numeric kernels; needs trip-
    count analysis + an unbounded-count fallback. Pairs with the Q3-B faulting-page work on hot loops.
  - *Skipped — **denser (bound basic-block size / poll in long straight-line regions).*** Only a
    pathological giant call/alloc-free straight-line block motivates it; time-to-safepoint there is
    already finite. Revisit only if such a block appears in real code.
- **Actor teardown: structural collection + weak-handle resource release — Decided (2026-08-04, was
  Q5).** Actor fields + mailbox are ordinary GC objects, reclaimed structurally with the cycle in the
  same GC cycle they die. The one non-GC resource — the fiber stack (`RT_STACK_SIZE` `mmap`) + the
  live-fiber-registry slot — is held through a **weak reference** (MMTk `ReferenceGlue`); reference
  processing clears it on death and enqueues the raw stack pointer onto a runtime free-queue that
  `munmap`s it. No per-actor finalizer, no resurrection, no extra-cycle retention, no moving-GC
  pinning of a finalizable object. Rests on invariants that leave nothing imperative to do at
  collection: an unreferenced-and-idle actor's handler fiber is parked on its own mailbox (off every
  run queue / external wait-list, a self-cycle tracing handles), and its structured-scope children
  have already drained (a live child holds a back-reference, so the actor isn't garbage until they
  finish). Explicit `shutdown` (drain-then-collect) is a separate surface path (`concurrency.md` §9).
  Both correctness (actor↔actor cycle collection with no finalizer ordering hazard) and performance
  (same-cycle reclamation vs. B's ≥1 extra cycle holding the whole reachable subgraph) point here.
  Implemented at 6.4 (6.4.1 structural; 6.4.2 weak-handle release + invariant assertions).
  - *Scoped fallback — **internal finalizer for a specific stubborn resource.*** If some actor runtime
    resource ever needs ordered imperative teardown a weak-cleared free-queue can't express, give that
    resource an internal GC finalizer — without making the whole actor finalizable. Internal only;
    stays consistent with "no user-visible finalizers" (`memory-model.md` §2). Cheaper to reach if the
    finalizer machinery already exists for other reasons (see the open user-finalizer question).
  - *Object-model requirement:* A's weak-reference (`ReferenceGlue`) path and any general finalizer
    queue must coexist cleanly in the binding — relevant if user-visible finalizers are later adopted.
- **`String` is a GC object — Decided (2026-08-04, was Q6).** The `String` value stays two words
  `{ data, i64 len }`, but `data` becomes `addrspace(1)`, pointing at a GC-managed **pointer-free
  byte array** (a leaf object; its pointer map scans no fields). Strings are collected like all heap
  data — no separate lifetime. The rejected alternative (keep the buffer runtime-owned, `addrspace(0)`)
  has no reclamation story without ownership Nomu lacks: it collapses to leaking or to refcounting the
  buffer, and since `String` is **shareable** that refcount must be **atomic** on every copy/drop —
  the exact retain/release traffic a tracing GC avoids (`memory-model.md` §8). Refinements this forces:
  - **Large strings → MMTk large-object space** (non-moving, size-thresholded), so GenImmix doesn't
    memcpy big pointer-free buffers on evacuation for no benefit; small strings live in the moving space.
  - **Literals → immortal space** (static bytes, never moved/collected) so `data` stays uniformly
    `addrspace(1)` with no per-use copy.
  - **`rt_str_lit` / `rt_str_concat` re-audited off `gc-leaf`** — they now allocate GC objects, so they
    are non-leaf (statepoints). The `String` value is a 16-byte ref+value aggregate, still register-
    resident (D6 category A), so no root-slot spill seam is needed.
  - Precedent: Go and the JVM both make strings GC objects (Go non-moving, JVM moving with large-object
    handling — the reason for the LOS refinement); Rust keeps strings off the GC only via ownership.
    Implemented at 6.1.3.
- **Witness tables are static / non-scanned — Decided (2026-08-04, was Q7).** The `any I` box is
  `{ witness, payload }`; its pointer map scans **`payload` only** (always `addrspace(1)` — a ref
  conformer's object, or a boxed value conformer — with the boxed value carrying its own map) and
  **skips `witness`**. A witness table holds only function pointers + pointers to other static tables
  + a reserved static type-metadata slot — no GC-heap pointer in its contents — and is emitted once
  per `(type, interface)` conformance / monomorphized instance to a static, immortal (never-moved,
  never-scanned) location. So the `witness` word targets static memory and is never a root. Stays true
  under monomorphized associated types (`generics.md` §10). Implemented at 6.1.3.
  - *Reopen trigger (watch item, 6.0.8):* a future shift to **runtime-instantiated witness tables /
    dictionary passing** (dynamically-composed or reflectively-created conformances) would make the
    table a heap object; `witness` would then need tracing to keep it alive — even though its contents
    stay non-GC. Monomorphization is what keeps tables static; any retreat from it reopens this.
- **Parked-fiber stack scanning: global live-fiber registry + present-as-parked syscalls — Decided
  (2026-08-04, was Q8).** Enabling invariant: every suspension goes through `park()` (a non-leaf
  runtime call → statepoint), so a parked fiber's top Nomu frame sits at a return address with a
  stackmap and its stack is precisely walkable; the existing `nomu_gc_walk_current` is seeded from the
  saved `ucontext` (build a `unw_context_t` from the fiber's saved registers; libunwind unwinds out
  through the gc-leaf `park`/`swapcontext` C frames to the Nomu frames). Two mechanisms:
  - **Fiber enumeration — global live-fiber registry (chose A over gather-from-wait-lists).** An
    intrusive doubly-linked list (`Fiber` carries `prev/next`), lock-guarded, O(1) insert on spawn /
    remove on completion (spawn already holds `rt_queue_mu`, so it is off the hot path); STW iterates
    it. One source of truth — a fiber is scannable wherever it waits. Rejected B (walk every run
    queue + wait-list at STW): every new wait-list type would have to opt into GC enumeration, and a
    missed list = missed roots = silent corruption.
  - **Blocking-syscall fibers — checkpoint and present as parked (chose A over wait-for-return).** The
    offload path records the fiber's scannable context at the handoff statepoint and marks it
    "parked-in-syscall"; the GC scans from that context and **STW does not wait for the offload carrier**
    (it holds no Nomu roots — gc-leaf C/kernel land). Rejected B (STW waits for the syscall): unbounded
    STW hostage to an arbitrary blocking syscall.
  - **Invariants to assert:** all suspension is via `park()` (no ad-hoc `swapcontext`); STW quiesces
    (carriers stop at safepoints) before the registry is iterated, so no fiber is mid-migration; the
    saved `ucontext` captures the full callee-saved set (arm64 x19–x28) — register-resident roots must
    be recovered per frame, not just stack slots.
  - **Validation (highest-risk item):** extend `tools/gc-smoke.sh` to a *parked* fiber holding a live
    managed ref across `park()` — recover the exact live set including a callee-saved-register root and
    a stack-slot root, exclude a dead-on-stack object; then the same for a parked-in-syscall fiber.
    Implemented at 6.2.2.
  - *Deferred, profile-guided — **registry data-structure exploration.*** The lock-guarded intrusive
    doubly-linked list is the baseline. Once collection is on, profile registry insert/remove and STW
    iteration under fiber-churny workloads, and explore whether a different structure or mechanism wins
    — e.g. per-carrier sharded lists (less spawn/complete contention, merged at STW), a lock-free/RCU
    intrusive list, an epoch/generation scheme, or a concurrent bag. Change only on a measured win over
    the baseline; correctness (single source of truth, stable during STW) is the constraint.

### 6.0.6 · Open design questions

The forks, one per line, resolved by stamping the choice as a decision in 6.0.5 and marking it closed
here. **All eight are now closed (2026-08-04)**; two carry deferred/profile-guided follow-ups (Q3-B
faulting page, Q8 registry structure) and one surfaced an unopened follow-on (Q5 user finalizers).

- **Q1 · Mutator granularity — Closed (2026-08-04): per-carrier thread.** Decision + the C
  alternative (deferred locality optimization) recorded in 6.0.5.
- **Q2 · Runtime / binding boundary — Closed (2026-08-04): thin Rust binding, runtime stays C.**
  Decision + escape hatch (option C, Rust-native GC-facing pieces) and rejected option B recorded
  in 6.0.5.
- **Q3 · Safepoint poll form (`__nomu_poll`) — Closed (2026-08-04): branch-on-flag.** Decision +
  the deferred faulting-page form (option B, profile-guided) recorded in 6.0.5.
- **Q4 · Safepoint density — Closed (2026-08-04): the 8.4 placement is the invariant.** Decision +
  the `-O` coverage-preservation rule, deferred counted-loop elision, and skipped denser option
  recorded in 6.0.5.
- **Q5 · Actor teardown mechanism — Closed (2026-08-04): structural + weak-handle release.**
  Decision + the scoped internal-finalizer fallback and the coexistence requirement recorded in
  6.0.5. Surfaced a possible follow-on: user-visible finalizers vs. `defer`/linear-only (not opened).
- **Q6 · `String` as a GC object — Closed (2026-08-04): yes, a GC pointer-free byte array.**
  Decision + the large-object-space / immortal-literal / `gc-leaf`-re-audit refinements recorded in
  6.0.5.
- **Q7 · Witness-table scanning — Closed (2026-08-04): static / non-scanned.** Any-box map scans
  `payload` only; reopen trigger (runtime-instantiated witness tables) recorded in 6.0.5 / 6.0.8.
- **Q8 · Parked-fiber stack scanning — Closed (2026-08-04): global live-fiber registry + present-as-
  parked syscalls.** Decision + invariants, the parked-fiber validation plan, and a deferred profile-
  guided exploration of the registry data structure recorded in 6.0.5.

### 6.0.7 · Runtime / GC posture

MMTk **GenImmix**, moving, generational; **precise** roots via LLVM statepoints; **per-carrier
mutators**; the M:N `ucontext` fiber scheduler (multiple carriers, migrating fibers, per-fiber
stacks) scanned via a live-fiber registry. GC governs memory only — races are the shareability
rule (`concurrency.md` §7), resources are `defer` (`memory-model.md` §6.2); M6 conflates
neither. **No new surface syntax.**

### 6.0.8 · Risks / watch items

- **Parked-fiber-stack scanning (highest).** No runtime precedent: needs a live-fiber registry
  plus recovering each parked fiber's saved SP/PC from its `ucontext` to drive precise
  frame-map walks. Suspension points must be safepoints.
- **Blocking-syscall fibers** — not polling at STW; must present as parked (stack scannable, no
  on-CPU roots). Interacts with `runtime.md`'s syscall offload.
- **Safepoint density vs. cost** — enough for prompt STW, few enough to stay cheap.
- **Footprint target** — GenImmix must reach the thesis footprint (~1.1–1.3× live set). The
  owned LXR-hybrid is a **scheduled successor** regardless (post-M7 + M10 debugger, gated on a
  benchmark-scale stdlib; `roadmap.md`, 6.0.5); a GenImmix footprint miss only pulls it earlier.
- **MMTk API churn** — pin a version; the binding is the blast-radius boundary.
- **Runtime-instantiated witness tables (Q7 reopen trigger)** — witness tables are static/non-scanned
  today (the any-box map skips `witness`). A future move to runtime-built dictionaries would make the
  table a heap object needing tracing. Monomorphization keeps tables static; watch any retreat from it.

### 6.0.9 · Deferred cleanups / feature work

- LXR-style RC-hybrid (owned reimplementation) — footprint endgame.
- Barrier elision for deeply-immutable types (can't form new cross-generation pointers by
  mutation) — a perf pass (`memory-model.md` §4).
- Escape analysis if it slips past M6 (6.5).
- Profile-guided perf follow-ups from the closed design questions (6.0.5): Q3-B faulting-page poll,
  Q4 counted-loop poll elision, Q1-C fiber-pinned TLAB locality, and Q8 live-fiber-registry data
  structure (profile insert/remove + STW iteration under fiber churn vs. the lock-guarded intrusive
  DLL baseline; explore sharded / lock-free / epoch alternatives, change only on a measured win).

### 6.0.10 · M8 / 8.4 carry-over — the substrate M6 builds on

M8 · 8.4 (the GC substrate) is **implemented and green** (2026-08-03). The dedicated 8.4 spec was
retired once it shipped; this section is its carry-over. The compiler now emits statepoint-based
safepoints, parseable stack maps, and three
inline-shaped mutator seams — all **inert** (corpus byte-identical to 8.2). M6 fills the seams,
turns on collection, and reuses the root walk. Concrete facts M6 rests on:

- **Three inert seams to fill** (all `internal alwaysinline`, in `Lowering.swift`; M6 replaces the
  body and `alwaysinline` collapses the call sites):
  - `__nomu_gc_alloc(i64 size) -> ptr addrspace(1)` — at every managed allocation. Inert body
    tail-calls `rt_alloc`; **not** `gc-leaf` (it stays a statepoint). M6 fills the bump-pointer TLAB
    fast path (load per-carrier cursor/limit, bump, branch to `rt_alloc` slow path). → **6.1.1 / 6.2**.
  - `__nomu_write_barrier(ptr addrspace(1) obj, ptr addrspace(1) slot, ptr addrspace(1) val)` —
    `gc-leaf`, at every managed-reference field write. Inert body is `store val, slot` (obj ignored).
    M6 fills the barrier fast path: GEP the header from `obj`, test the logged/mark bit, log on first
    mutation. `obj` is already passed for exactly this. → **6.3.1** (generational) / LXR later.
  - `__nomu_poll()` — `gc-leaf`, no-op, emitted at the header of loops that reach no other safepoint
    (loops with a non-leaf call or allocation are elided). M6 fills the poll; **form is still open**
    (protected-page load vs. branch-on-flag — decide by microbenchmark + `SIGSEGV`/`ucontext`
    viability). → **6.2.3** STW handshake.
- **Address-space model.** `addrspace(1)` = a managed (GC-heap) reference; `addrspace(0)` = code /
  static / C-owned memory. **`rt_alloc` is declared to return `ptr addrspace(1)` directly** — do
  *not* reintroduce an `addrspacecast (0→1)` at alloc sites: `RewriteStatepointsForGC` rejects a GC
  base introduced by a differing-addrspace cast. Only `1→0` casts exist, at C-ABI boundaries
  (`fiber_spawn` env, spawn-box return, struct-mutating thunk `self`). Managed set: class/actor
  objects, closure boxes, any-boxes, spawn boxes, and their interior GEPs. `String`'s char buffer is
  still `addrspace(0)` (runtime-owned) — whether it becomes a GC object is an M6 object-model call.
- **Existentials and closures are heap-boxed reference values** (forced by the pass's "no GC pointer
  in a by-value first-class aggregate" limit). A closure value is a `p1` pointer to a **fused**
  heap object `{ ptr fn (addr0), cap0, cap1, … }` (one allocation; captures inline after the fn
  pointer; the impl takes the object as its first arg and reads captures from fields 1…N). An `any I`
  value is a `p1` pointer to a heap `{ ptr witness (addr0, static), ptr addrspace(1) payload }`.
  **6.1.3's pointer maps must cover these exact shapes** (closure: scan captures, skip `fn`; any-box:
  scan `payload`, skip `witness`), not the old by-value `{fn,env}`/`{witness,payload}` layout.
- **Object header** is still the vestigial `i64` (`ObjectHeader{refcount}`); class/actor objects are
  `{ i64 header, fields… }`, actor adds a trailing `i8* mu`. **6.1.2** subdivides the header (mark /
  log bits + type-id) and drops `refcount`; the write-barrier's logged bit must sit where an
  `addrspace(1)`-interior GEP from `obj` reaches it in one step (header ↔ barrier co-designed).
- **Stack-map parser + single-stack root walk already ship in `runtime.c`** (`runtime.h` API):
  `nomu_gc_stackmap_init` parses `__llvm_stackmaps` (v3) via `getsectiondata(&_mh_execute_header,…)`
  into a *return-address → distinct-GC-slot* index; `nomu_gc_walk_current(visitor)` drives a
  **libunwind** cursor (our frames omit the FP but carry compact-unwind info) and reports each live
  root at `frame-register + offset` (slots are **SP-relative**, DWARF reg 31; reg 29/FP handled).
  It is **precise** (excludes dead-but-on-stack objects) — verified by `examples/gc_smoke.nomu` +
  `tools/gc-smoke.sh` (env `NOMU_GC_SMOKE`), which recovers the exact live set across two frames and
  two managed kinds. **6.2.1/6.2.2:** the walk takes a cursor, so a parked fiber's saved `ucontext`
  is walked the same way — build a `unw_context_t` from the fiber's registers and pass it.
- **`gc-leaf` runtime classification** (callers skip the statepoint): leaf = `printf`, `rt_str_lit`,
  `rt_str_concat`, `rt_mutex_new`, `rt_mutex_unlock`; non-leaf (statepoint) = `rt_alloc`,
  `fiber_spawn`, `spawn_join`, `rt_sleep_ms`, `rt_read_line`, `rt_mutex_lock`. **Re-audit in M6:**
  `rt_str_*` are leaf only while `String` is runtime-owned; if M6 makes `String` a GC object they
  become non-leaf. Every emitted function carries `gc "statepoint-example"`.
- **Pass pipeline** (`LLVMBridge.swift`): `function(mem2reg,sroa),rewrite-statepoints-for-gc` before
  codegen. `mem2reg`/`sroa` is a **correctness** prerequisite, not just perf — our lowering puts
  every local in an alloca, and the rewrite tracks only SSA-value GC pointers, so promotion must run
  first or almost no roots are found. M6's full `-O` pipeline slots before the rewrite (8.5).
- **Roots-in-stack-memory (D6) — A covers the current surface; the B spill seam is deferred.**
  Reference-carrying value aggregates are kept register-resident (A): small ones are passed by value
  and promoted; closures/existentials are heap-boxed (their refs are heap-object fields, traced by
  the object map, never stack roots); class/actor refs are scalar `p1`. An audit found **zero
  category-3 sites** (no reference-carrying enum payload; no large ref-mixing struct) in the current
  language, so no explicit per-frame root-slot spill seam is emitted. M6 adds the B spill seam +
  its runtime root-slot scan when a *large* (>16-byte) value aggregate mixing values with references
  first crosses a non-inlined call (or a non-hoistable mutating ref-receiver arises).

---

## 6.1 · MMTk binding + scannable object model (NoGC) ⬜

One-line intent: stand up the binding and a scannable object model with **zero collection** —
prove allocation routes through MMTk and every heap shape is walkable before any GC runs.
Depends on M8. **Approach:** MMTk plan **NoGC**; a Rust `VMBinding` crate; C runtime calls in,
MMTk calls back for `scan_object`.

- **6.1.0 ✅ built + green (2026-08-04)** — **toolchain bring-up (no MMTk, no binding logic).** A
  trivial Rust crate (`src/gcbinding/`, `rust_static_library` → `libnomu_gc.a`, `rules_rust` 0.72,
  edition 2024) exposing one throwaway C-ABI probe (`nomu_gc_probe` → sentinel `0x4E4F4D555F474300`).
  All three link paths verified on arm64/Mach-O: **(a)** crate builds; **(b)** links into the
  **`nomuc` build** (dep of `//src/nomu-cli:nomuc`, bound via `@_silgen_name`; `nomuc --gc-probe`
  prints the sentinel); **(c)** links into a **`nomuc`-emitted program** — the driver appends a
  provided GC archive + `-u _nomu_gc_probe` to the output link (`hello` binary carries defined
  `T _nomu_gc_probe`, runs correctly, default no-archive path unaffected).
  - **Distribution — solved, `nomuc` stays a single atomic file (proven, not proposed).** The
    embed-as-*source* model does not extend to Rust (the staticlib is **17 MB** — bundled Rust std —
    so a Swift string literal is impractical). Instead the archive is embedded as a **Mach-O
    section**: `nomuc`'s link carries `-Wl,-sectcreate,__DATA,__nomu_gc,libnomu_gc.a` (`nomuc` grew
    242→259 MB), and at emitted-program link time the driver reads its own section via
    `getsectiondata` (`src/gcembed`, the same API `runtime.c` uses for `__llvm_stackmaps`) and
    extracts it once to a temp cache (`$TMPDIR/nomu-gc-<size>.a`, reused thereafter) to hand `cc` a
    path. Verified: compiling with **no** `NOMU_GC_ARCHIVE` extracts from the embedded section and
    links. `NOMU_GC_ARCHIVE` stays a dev override. (Levers to shrink the payload later: `opt-level=z`,
    `panic=abort`, LTO, strip.)
  - **Per-emitted-binary size — archive size is not the floor, but the force-link was a trap.** A
    static archive pulls only members that resolve *referenced* symbols. But an early `-u
    _nomu_gc_probe` (added to prove the emitted-program link) force-resolved the probe, whose Rust
    codegen unit also holds the whole `VMBinding` + `mmtk_init`/`alloc` — so the linker dragged the
    entire MMTk closure (mmtk core + `regex` + `aho-corasick` + `sysinfo` + `objc2`) into **every**
    binary: `strings` ballooned 56 KB → **6.8 MB** while making zero GC calls. Force-link removed; the
    archive is still handed to `cc` but pulls nothing until referenced, so binaries are back to 56 KB.
    Real floor arrives when `rt_alloc` routes through MMTk (below): programs then pull MMTk's reachable
    subset — a legitimate few-MB increase (a GC'd program carries its GC), to be measured and trimmed
    (`regex`/`sysinfo` are heavy MMTk deps; + `opt-level=z`/`panic=abort`/LTO/strip).
  - The probe symbol, `--gc-probe`, and the `NOMU_GC_ARCHIVE` override are throwaway — retired when
    6.1.1 swaps in the real MMTk archive.
- **6.1.1 🔨 in progress** — grow `src/gcbinding` (6.1.0) into the **thin** Rust `VMBinding` crate (Q2 —
  forwards to the C runtime, holds ~no state); MMTk NoGC linked; `rt_alloc` → mutator alloc; **one
  `Mutator` per carrier** bound at carrier init (Q1), every alloc reading the current carrier's
  cursor/limit fresh — the codegen fast-path load must not be cached across a safepoint (6.0.5).
  Reuse the **section-embed distribution mechanism proven in 6.1.0** (`-sectcreate __DATA,__nomu_gc`
  + `getsectiondata` extract-to-cache — `nomuc` stays atomic): swap the probe archive for the real
  MMTk-linked archive, measure the emitted-binary size delta once allocation routes through MMTk, and
  retire the `nomu_gc_probe` symbol, `--gc-probe` flag, and `NOMU_GC_ARCHIVE` override.
  - **Done so far — MMTk dependency bring-up (green).** `mmtk = 0.32.0` (pinned, §6.0.8) fetched via
    `crate_universe` (`crate` extension in `MODULE.bazel`); its full transitive graph (267 files +
    deps) compiles under `rules_rust` and links into `libnomu_gc.a` (17 → 34 MB), which embeds in
    `nomuc` (277 MB) and reaches emitted programs through the 6.1.0 section pipeline. `gcbinding`
    references `mmtk::util::Address` to force the link (`nomu_gc_mmtk_probe`). **Gotcha recorded:**
    MMTk's build script uses the `built` crate, which `.expect()`s the descriptive `CARGO_PKG_*` env
    vars (AUTHORS/DESCRIPTION/HOMEPAGE/REPOSITORY/LICENSE) that `crate_universe` doesn't propagate —
    injected via `crate.annotation(build_script_env=…)` or the build panics one var at a time.
  - **Done — `VMBinding` + MMTk NoGC init + allocation (green).** `src/gcbinding/lib.rs` implements
    `NomuVM: VMBinding` (all five assoc traits) — adapted from mmtk-core's DummyVM binding at the
    v0.32.0 tag; the collection-side callbacks and `ObjectModel` copy paths are `unimplemented!()`
    (never hit under NoGC). `nomu_gc_init` builds MMTk with `PlanSelector::NoGC` + a fixed heap;
    `nomu_gc_alloc_probe` binds a mutator and allocates. Verified in-process (`nomuc --gc-alloc-probe`
    → `Initialized MMTk with NoGC` + a live address), and the MMTk-containing archive (now 34 MB)
    rides the section embed into emitted programs, which link and run green across a corpus sample.
    Two findings: (1) **MMTk 0.32's default plan is GenImmix** (our eventual target, §6.0.4) — NoGC is
    set explicitly. (2) **MMTk's deps pull macOS frameworks:** `sysinfo` (host memory sizing) →
    CoreFoundation/IOKit/`objc`; the emitted-program `cc` link now names `-framework CoreFoundation
    -framework IOKit -lobjc` (nomuc gets them from the Swift toolchain; a plain link does not). A
    later slim-deps pass could drop `sysinfo`.
  - **Done — `rt_alloc` → per-carrier mutator; M5 corpus green under NoGC.** `runtime.c` calls
    `nomu_gc_init(1 GiB)` at `main` entry; `rt_alloc` binds one MMTk mutator per carrier lazily
    (`_Thread_local rt_mutator`, `pthread_self` as the opaque TLS — a migrating fiber allocates on its
    current carrier, so thread-local storage gives the per-carrier split, Q1) and bump-allocates via
    `nomu_gc_alloc`; MMTk returns raw memory, so `rt_alloc` `memset`s it to keep the old `calloc`
    zero-init contract (the vestigial `refcount` write stays until 6.1.2). **All 29 corpus programs
    compile + run correctly through MMTk NoGC** (`stdin`/`speed`/`gc_smoke` excluded); frontend tests
    green. Two follow-ups: (a) a Nomu program now genuinely links MMTk's reachable subset — `hello`
    **56 KB → 15.6 MB** (debug); the real GC'd floor, to be cut with `opt-level=z`/LTO/strip/
    `panic=abort` + slimming `regex`/`sysinfo`. (b) MMTk prints an INFO init line to **stderr** each
    run (stdout oracle unaffected) — suppress its logger for user programs.
  - **Left in 6.1.1:** retire the 6.1.0/probe scaffolding (`nomu_gc_probe`, `--gc-probe`,
    `--gc-alloc-probe`, `nomu_gc_alloc_probe`) once no longer needed for bring-up checks.
- **6.1.2 ⬜** — GC **header** design (mark/log bits in side metadata; in-object **type-id**);
  drop the vestigial `refcount` field. Co-design the log bit so a `write_barrier` interior-GEP
  from `obj` reaches it in one step (6.0.10). Register finalizable objects in a **side table**,
  not a header bit (leaves finalizer headroom, Q5 coexistence).
- **6.1.3 ⬜** — codegen-emitted **per-type pointer maps** (static tables keyed by type-id),
  `scan_object` dispatches through the map. Shapes:
  - `class`/`actor` — scalar `p1` fields per the map (actor's trailing `mu` is `addr0`, skipped);
  - `Closure` — heap-boxed `{ fn (addr0, skip), caps… }`: scan captures (6.0.10);
  - `any` box — `{ witness, payload }`: **scan `payload` only, skip `witness`** (Q7 — witness
    tables are static / non-scanned);
  - `String` — the value is `{ data: p1, len: i64 }`; `data` points at a **GC pointer-free byte
    array** (Q6, a leaf object scanning no fields); large buffers → large-object space, literals
    → immortal space;
  - generic instance — boxed field per its monomorphized map.
- **6.1.4 ⬜** — replace the `rt_str_concat` header pointer-arithmetic hack with the GC
  byte-array alloc/access API (Q6); re-audit `rt_str_lit`/`rt_str_concat` **off `gc-leaf`**
  (they now allocate GC objects → non-leaf/statepoints, 6.0.5); normalize interior-pointer /
  alignment to MMTk `ObjectReference`.

**Exit:** the full M5 suite compiles and runs under MMTk NoGC (allocates, never collects);
every heap shape has a pointer map `scan_object` walks without error (a map-walk self-check
passes); no `refcount` field remains.

## 6.2 · Precise roots, safepoints & the moving collector (Immix) ⬜

One-line intent: the correctness+moving core — objects relocate, roots are precise, collection
reclaims memory including cycles. Depends on 6.1 + M8 statepoints. **Approach:** MMTk plain
**Immix** (moving; no generational barrier yet — validates evacuation + maps barrier-free).

- **6.2.1 ⬜** — consume LLVM **stack maps** at statepoints; MMTk `scan_roots` over live
  carrier frames + globals.
- **6.2.2 ⬜** — **global live-fiber registry** (Q8 — intrusive doubly-linked list, lock-guarded,
  O(1) insert/remove at spawn/complete); scan **parked fiber stacks** by seeding the existing
  `nomu_gc_walk_current` from the saved `ucontext` (build a `unw_context_t` from the fiber's saved
  registers). Blocking-syscall fibers **checkpoint at the offload statepoint and present as parked**
  (STW does not wait for the offload carrier). Invariants: all suspension via `park()` (statepoint);
  STW quiesces before iterating the registry; the saved context carries callee-saved roots (x19–x28).
  Validate via a parked-fiber `tools/gc-smoke.sh` case (6.0.5).
- **6.2.3 ⬜** — **STW handshake**: per-carrier stop-requested flag; `__nomu_poll` lowered to
  **branch-on-flag** → `__nomu_gc_poll_slow` statepoint call (Q3); density stays the 8.4 placement
  with the **`-O` safepoint-coverage-preservation rule** (Q4); parked/blocked fibers already safe.
- **6.2.4 ⬜** — evacuation correctness: references updated on relocation; no stale interior
  pointers; pinning (if any) honored.

**Exit:** allocate-in-a-loop runs in **bounded memory**; cycle-forming and graph-heavy
programs are collected (tracing beats the retired RC); objects survive relocation intact; M5
suite green under Immix; a "collect on every allocation" stress mode passes.

## 6.3 · Generational collection (GenImmix) + write barrier ⬜

One-line intent: the footprint/throughput target plan. Depends on 6.2. **Approach:** MMTk
**GenImmix** — nursery + generational barrier.

- **6.3.1 ⬜** — LLVM-inlined **generational write barrier** (field-logging / remembered-set)
  on every reference-field store, filling the inert `__nomu_write_barrier` seam. Keep the seam
  shape **collector-agnostic** — GenImmix fills it as a logging barrier now; the planned LXR
  RC-hybrid refills the *same* seam as its RC barrier later (6.0.5), so bake in no GenImmix-only
  ABI assumption.
- **6.3.2 ⬜** — nursery sizing / promotion tuning; footprint measurement vs. the ~1.1–1.3×
  target.

**Exit:** GenImmix green on the M5 suite + stress tests; measured steady-state footprint near
the live set on the bounded-memory benchmarks (the thesis metric).

## 6.4 · Actor teardown / finalization ⬜

One-line intent: GC-driven actor lifetime, replacing the retired refcount actor-release path.
Depends on 6.2. **Approach (Q5 — decided):** structural collection of actor fields + mailbox
(ordinary GC objects), with the one non-GC resource released via a **weak handle**, not a
per-actor finalizer.

- **6.4.1 ⬜** — remove the vestigial refcount actor-release path; drive actor collection from
  GC liveness ("unreferenced-and-idle," `memory-model.md` §2); actor fields + mailbox are
  structurally reclaimed with the cycle.
- **6.4.2 ⬜** — hold the fiber stack (`RT_STACK_SIZE` `mmap`) + live-fiber-registry slot through
  a **weak reference** (`ReferenceGlue`); reference processing clears it on death → runtime
  free-queue `munmap`s the stack. Assert the enabling invariants (fiber parked on its own mailbox;
  structured-scope children already drained). No user-visible finalizers; the scoped internal-
  finalizer fallback stays unused unless a resource needs ordered imperative teardown (6.0.5).

**Exit:** an unreferenced idle actor's memory *and* runtime state are reclaimed; actor↔actor
cycles collected; no dangling handle; the refcount path is gone.

## 6.5 · Escape analysis (perf tail; descopable) ⬜

One-line intent: recover the stack-allocation win — keep provably-non-escaping objects off the
GC heap (`memory-model.md` §6.1). Depends on M8's CFG/SSA IR; independent of 6.2–6.4;
**descopable** to a follow-on. **Approach:** best-effort analysis on the lower IR; fallback is
always "heap-allocate," so precision affects speed only, never correctness.

- **6.5.1 ⬜** — escape-analysis pass on the CFG/SSA IR; annotate non-escaping allocations.
- **6.5.2 ⬜** — stack allocation / scalar replacement in codegen for annotated sites.

**Exit:** a set of known-non-escaping allocations (microbenchmarks) touch neither the collector
nor the heap; correctness unchanged when the pass is disabled.
