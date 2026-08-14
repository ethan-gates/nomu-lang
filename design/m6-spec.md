# M6 — Implementation Spec (Real GC via MMTk)

**Status:** working draft — the ordered work plan for M6, derived from `memory-model.md`
(§3 GC, §6 escape analysis / cleanup, §8 performance profile), `compiler.md` (§6 C→LLVM
transition checklist, §7 GC binding), and the runtime facts in `runtime.md`. It pins the
build sequence; the *design* lives in those docs and the two decisions stamped in 6.0.5 (the open
forks are the 6.0.6 register).
**Design is settled** — all eight design forks are closed (the 6.0.6 register); the two locked
cross-cutting decisions live in 6.0.5.

> Authoring conventions per `lang-project/milestone-doc-guide.md` (numbering, status markers,
> front matter, slice records, exit criteria).

**Build status (2026-08-11):** **6.2 complete (Immix flip + evacuation) and 6.3.1 built + green** — the
generational write barrier fills the `__nomu_write_barrier` seam and the default plan is **GenImmix**
(see 6.3). **6.3.2 done (2026-08-11):** the profiling blocker was root-caused to **two binding bugs** and fixed — GenImmix now collects a retained live set at tight heaps and the footprint thesis is met (**~1.05x** live-set footprint on the churn benchmark, see 6.3). Footprint tooling (`NOMU_GC_STATS`) is in place, and the **write barrier is now inlined** (GenImmix's barrier-saturated microbench 0.71 s → 0.047 s, ~15×; see 6.3). 6.3.2's remaining polish (nursery tuning, opt-level, a wider footprint sweep) is deferred. **6.4 done (2026-08-12):** the async actor runtime (mailbox + message-send + pooled handler fibers) + structural teardown replaced the M3.4 mutex scaffold; see §6.4. Escape analysis (§6.5) is the open M6 item: a conservative pass on the structured NOIR (the
precise CFG/SSA form is deferred to M7, the optimizer tier). Historical bring-up status below.

**Build status (2026-08-04):** **6.1 (MMTk NoGC bring-up) substantially built + green.** 6.1.0–6.1.3
✅ (Rust `VMBinding` + MMTk NoGC linked via `crate_universe`; `rt_alloc` → per-carrier mutator; the
type-id header replacing `refcount`; per-type pointer maps + `scan_object` for every currently-managed
shape). 6.1.4 partial: the `gc-leaf` re-audit landed; **`String`-as-GC-object is blocked on
heap-boxing** (the `{p1,i64}` value hits `RewriteStatepointsForGC`'s FCA limit) and is deferred to
6.2. The M5 corpus (29 programs) compiles + runs green under NoGC. Design forks all closed (6.0.6);
LXR is a scheduled successor gated on a benchmark-scale stdlib (`roadmap.md`, 6.0.5). Working tree is
uncommitted across `nomu-lang/{src,design,.bazelrc,MODULE.bazel}` — you do the commits.

**Framing correction:** the roadmap names M6 "real GC (MMTk)," but the bar is **not** "it
collects" — it is **validating the performance thesis**: a *moving* collector at ~1.1–1.3×
live-set footprint with competitive throughput (`memory-model.md` §8). A non-moving mark-sweep
prototype would clear "it collects" while validating none of the doubted bet — hence the
moving-Immix target and the M9-first reorder.

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
- **Escape analysis** — a perf pass (stack allocation / scalar replacement); conservative form in the
  M6 tail, precise form needs the M7 optimizer tier (CFG/SSA NOIR) (`memory-model.md` §6.1; phase 6.5).
- **User-visible finalizers** — none planned; internal actor teardown only (phase 6.4).

### 6.0.2 · Prerequisites

Grounding M6 against the current compiler (M5; C backend; bump-and-leak `rt_alloc`; vestigial
`ObjectHeader { refcount }`; M:N `ucontext` fiber scheduler):
- **M9 — LLVM backend + statepoints (the hard gate).** A moving collector needs precise roots
  via compiler-emitted stack maps the C backend cannot produce (`compiler.md` §6). M9 lands
  the LLVM path and statepoint stack maps; M6 rests on them. (Structured NOIR lowers straight to LLVM —
  there is no separate lower IR; the CFG/SSA optimizer tier is the later M7.) Reordered
  before M6 (decided 2026-07-30, `roadmap.md`). **8.4 (the GC substrate) is done (2026-08-03):**
  `addrspace(1)` roots, statepoint stack maps, the parser + single-stack root walk, and the three
  inert alloc/barrier/poll seams all ship — see **6.0.10** for the concrete carry-over M6 builds on.
- **Held invariants (through M5), no pre-slice needed** — single allocation seam (`rt_alloc`)
  and an explicit scannable object model (`compiler.md` §7). They already exist.

### 6.0.3 · Compiler surface touched

Post-M9 pipeline: `… → typed IR (NOIR, structured) → LLVM (statepoints, barriers) → native`. (The
lower CFG/SSA optimizer tier is the later M7; not yet inserted.)
M6 touches:
- **Codegen (LLVM)** — GC header on every heap object; per-type **pointer maps** as static
  tables keyed by a header type-id; **statepoint** safepoints (maps at calls / loop back-edges
  / alloc slow path); **write-barrier** inlining on reference-field stores; inlined alloc
  fast path.
- **Runtime (C + Rust binding)** — the MMTk `VMBinding` (`scan_object`, `scan_roots`,
  `block_for_gc`, resume); a **live-fiber registry**; the STW handshake; per-carrier `Mutator`.
- **IR / Sema** — the escape-analysis pass (6.5): conservative on the structured NOIR in M6, precise
  on the M7 optimizer tier (CFG/SSA NOIR).

### 6.0.4 · Dependencies

```
M9 (LLVM backend + statepoints)              [hard prerequisite]
└─ 6.1 (MMTk binding + object model, NoGC)
   └─ 6.2 (precise roots + safepoints + moving Immix)
      ├─ 6.3 (GenImmix + write barrier)
      └─ 6.4 (actor runtime + teardown)
6.5 (escape analysis)   [perf tail; conservative in M6, precise is M7 (optimizer tier)]
```
6.1 gates all collection. 6.2 is the correctness+moving core. 6.3 and 6.4 are independent of
each other. 6.5 is sequenced last: a conservative pass on the structured NOIR ships in M6, the
precise pass waits on the M7 optimizer tier, the CFG/SSA NOIR IR (the LLVM backend, now M9, is already done; §6.5).

### 6.0.5 · Cross-cutting decisions

Closed forks (the open ones live in 6.0.6):
- **LLVM before GC — Decided (2026-07-30).** M6 validates the moving-collector performance
  thesis, which needs precise roots. The C-path bridges were rejected: conservative-pinned
  scanning degrades the footprint metric under test; a codegen shadow stack is precise but
  throwaway. So M9 lands first and the collector rests on statepoint stack maps
  (`roadmap.md`; `compiler.md` §7). Corollary: **precise roots, never conservative.**
- **Collector sourcing: mainline GenImmix; LXR planned & owned — Decided (2026-07-30; sequenced
  2026-08-04).** MMTk's value is a live borrow; mainline GenImmix is that. The LXR branch is stalled,
  so the RC-hybrid endgame is a clean *owned* reimplementation behind the same interface — nothing in
  M6 assumes LXR (`memory-model.md` §3). **Sequencing intent (2026-08-04):** LXR is a scheduled
  successor, not open-ended — targeted after M8 + the M11 debugger, gated on a **benchmark-scale
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
  one crate. Settled context, not reopened here: codegen emits LLVM IR (M9); the two held invariants
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
- **Actor teardown: purely structural collection — Revised (2026-08-12; was "structural + weak-handle",
  2026-08-04, Q5).** The 2026-08-04 decision assumed a **dedicated per-actor handler fiber** whose stack
  (`RT_STACK_SIZE` `mmap`) + live-fiber-registry slot was the one non-GC resource, released through a
  weak reference (MMTk `ReferenceGlue`) + a runtime `munmap` free-queue. The actor implementation model
  settled 2026-08-12 (`concurrency.md` §9) **removes that resource**: handler fibers are **pooled and
  borrowed on demand**, so an idle actor holds no fiber and no mutex. Actor state and mailbox are
  ordinary GC objects; pending messages root the actor (drain-then-collect); an unreferenced idle actor
  therefore has **nothing non-GC to release** and is reclaimed structurally like any object — no weak
  handle, no `ReferenceGlue`, no per-actor finalizer, no free-queue, no moving-GC pinning. Actor↔actor
  cycles with drained mailboxes collect together in one cycle. Explicit `shutdown` (drain-then-collect)
  is a separate surface path (`concurrency.md` §9). The pool's fiber stacks are runtime-lifetime, not
  per-actor. **Built at §6.4 (2026-08-12):** the async actor runtime (mailbox + pooled handler fibers +
  message-send lowering) replaced the M3.4 mutex scaffold, and teardown is purely structural as above.
  - *Scoped fallback — **internal finalizer for a specific stubborn resource.*** Structural collection
    covers actors now that they own no non-GC resource. If some future actor runtime resource ever needs
    ordered imperative teardown, give that resource an internal GC finalizer (or a weak-cleared
    free-queue via `ReferenceGlue`) — without making the whole actor finalizable. Internal only; stays
    consistent with "no user-visible finalizers" (`memory-model.md` §2). `ReferenceGlue` in the binding
    stays `unimplemented!()` until such a resource or user-visible finalizers appear.
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
  - **`String` must be heap-boxed — a `p1` to `{ header, len, bytes… }`, not a `{ p1, i64 }` value.**
    ~~The D6 note claimed the String value stays register-resident (category A) with no spill.~~
    **Corrected (2026-08-04, 6.1.4):** making `data` a `p1` was rejected by `RewriteStatepointsForGC`
    ("FCA unimplemented") — a `{ p1, i64 }` value live across a statepoint is a first-class aggregate
    carrying a GC pointer, the same limit that heap-boxed closures/any. So Q6 requires heap-boxing
    `String`. `rt_str_concat` (allocates) is off `gc-leaf`; `rt_str_lit` (wraps a static pointer) stays
    leaf. The heap-box + immortal/large-object routing lands with 6.2 (see 6.1.4).
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
  owned LXR-hybrid is a **scheduled successor** regardless (post-M8 + M11 debugger, gated on a
  benchmark-scale stdlib; `roadmap.md`, 6.0.5); a GenImmix footprint miss only pulls it earlier.
- **MMTk API churn** — pin a version; the binding is the blast-radius boundary.
- **Runtime-instantiated witness tables (Q7 reopen trigger)** — witness tables are static/non-scanned
  today (the any-box map skips `witness`). A future move to runtime-built dictionaries would make the
  table a heap object needing tracing. Monomorphization keeps tables static; watch any retreat from it.
- **Fixed (6.3.1): local slots were `alloca`'d in loop bodies -> fiber-stack overflow.** A `let`/temp/
  `match`-binding/`enum`/`spawn`-handle slot was built with `LLVMBuildAlloca` at the *current*
  insertion point, so a binding inside a loop became a **dynamic** stack allocation (`sub sp, sp, #N`
  every iteration) instead of a fixed frame slot. Over enough iterations the stack grew past the
  128 KB fiber stack and overflowed, corrupting whatever it hit (any live root read back garbage/`0`,
  or a crash when a clobbered pointer field was dereferenced). It looked GC/root-related (a live class
  value across an allocating loop) but was neither: it reproduced under **NoGC**, was triggered by the
  *allocation* not the loop count (a no-alloc loop of the same size was fine), corrupted *every* live
  root, and `-O2` hid it (LICM/DCE hoist the dead alloca -- only the debug pipeline's `mem2reg`/`sroa`
  left it in the loop). **Fix:** `IRToLLVM.entryAlloca` builds every local/temporary slot in the
  function **entry block** (the standard LLVM rule), reusing one slot across iterations -- safe because
  locals are dead at the back-edge and closures snapshot captures by value (`allocAndFillEnv`).
  Verified: the repro prints correctly through 500 K iterations, the loop body emits no `mov sp`, and
  the 35-program corpus + GC scripts stay green. (Debug facility added alongside: `NOMU_DUMP_LLVM`
  writes `<obj>.pre.ll`/`.post.ll` around the pass pipeline.)

### 6.0.9 · Deferred cleanups / feature work

- LXR-style RC-hybrid (owned reimplementation) — footprint endgame.
- Barrier elision for deeply-immutable types (can't form new cross-generation pointers by
  mutation) — a perf pass (`memory-model.md` §4).
- Precise (CFG/SSA) escape analysis — needs the M7 optimizer tier, the CFG/SSA NOIR IR (6.5); the
  conservative form ships in M6. (The LLVM backend, now M9, is done; NOIR lowers straight to LLVM.)
- Profile-guided perf follow-ups from the closed design questions (6.0.5): Q3-B faulting-page poll,
  Q4 counted-loop poll elision, Q1-C fiber-pinned TLAB locality, and Q8 live-fiber-registry data
  structure (profile insert/remove + STW iteration under fiber churn vs. the lock-guarded intrusive
  DLL baseline; explore sharded / lock-free / epoch alternatives, change only on a measured win).

### 6.0.10 · M9 / 8.4 carry-over — the substrate M6 builds on

M9 · 8.4 (the GC substrate) is **implemented and green** (2026-08-03). The dedicated 8.4 spec was
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

## 6.1 · MMTk binding + scannable object model (NoGC) 🔨

One-line intent: stand up the binding and a scannable object model with **zero collection** —
prove allocation routes through MMTk and every heap shape is walkable before any GC runs.
Depends on M9. **Approach:** MMTk plan **NoGC**; a Rust `VMBinding` crate; C runtime calls in,
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
- **6.1.1 ✅ built + green (2026-08-04)** — grow `src/gcbinding` (6.1.0) into the **thin** Rust `VMBinding` crate (Q2 —
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
    green. Two follow-ups: (a) **binary size — addressed.** A Nomu program now genuinely links MMTk's
    reachable subset; `hello` was **15.6 MB**, cut to **2.78 MB** by `-Wl,-dead_strip -x` on the
    emitted-program link (drops MMTk plan/scheduler code unreachable on the NoGC alloc path) + Rust
    `-Copt-level=z` for the whole graph (persisted in `.bazelrc`, Rust-only so LLVM/Swift stay cached).
    Tradeoff noted: `z` trades speed for size — revisit the collector hot-path opt-level at 6.3
    (throughput). Further levers if needed: LTO, `panic=abort` (needs build-std), slim `regex`/
    `sysinfo`. (b) **stderr log noise — fixed.** MMTk's default `builtin_env_logger` feature
    auto-inits `env_logger` at INFO and printed a line per run; disabled via `default_features = False`
    on the `crate.spec` (MODULE.bazel). Bonus: dropped `env_logger`+its `regex` → `hello` 2.78 → 2.73 MB.
    (Lost the other default `log/release_max_level_off` — unusable from a downstream spec; revisit at
    6.3.) Corpus + frontend green.
  - **Scaffolding retired.** `nomu_gc_probe`/`nomu_gc_alloc_probe`/`dummy_tls` + the `--gc-probe`/
    `--gc-alloc-probe` flags removed; `nomu_gc` stays a `nomuc` dep only to give `-sectcreate` the
    archive path (no symbols linked). The kept mechanism: `nomu_gc_init`/`bind_mutator`/`alloc`, the
    section embed + `gcembed` reader, `-dead_strip`, `.bazelrc` `opt-level=z`, and `NOMU_GC_ARCHIVE`
    as a dev override.
- **6.1.2 ✅ built + green (2026-08-04)** — GC **header** design. The in-object header is one 8-byte
  word, `ObjectHeader { uint32_t type_id; uint32_t reserved; }` (runtime.h) — `type_id` (codegen-
  assigned) keys the 6.1.3 pointer map; the word is 8 bytes only for field alignment, so 32 bits are
  reserved for future in-object GC metadata (`scan_object` reads the low 32). The 8-byte slot is
  unchanged so class/actor field offsets (index +1) and the String-buffer prefix are undisturbed.
  (Footprint lever for 6.3: move the type-id to MMTk side metadata and drop the header entirely — 8
  bytes/object — trading a header load for a side-metadata lookup.) **`refcount` dropped** (was written `=1` at `rt_alloc`, never
  read — no retain/release path existed); `rt_alloc`'s `memset` zeroes the slot, and codegen populates
  the real id at **6.1.3** (nothing reads it under NoGC). **Mark/log/forwarding bits are MMTk side
  metadata** (the object model's `*_SPEC` are `side_first`/`side_after`), not in-object — so the log
  bit the 6.3.1 write barrier tests lives in side metadata, reached without an in-object GEP.
  Finalizable objects will register in a **side table** (Q5), not a header bit — nothing to build under
  NoGC. Corpus + frontend green; output unchanged.
- **6.1.3 ✅ built + green (2026-08-04)** — codegen-emitted **per-type pointer maps** (static tables keyed by type-id),
  `scan_object` dispatches through the map. Covers every currently-managed heap shape (class/actor/
  closure/any); `String` waits on Q6. Map-walk self-check (`NOMU_GC_TYPEMAPS`) passes.
  - **Part A done (2026-08-04) — codegen foundation (class/actor).** Each class/actor heap type gets a
    type-id (`Lowering.swift`), written into the object header at its alloc site (6.1.2 slot); the
    per-type map = byte offsets of managed (`p1`) fields, computed by walking the layout (recurses into
    inline value structs; skips String buffers (Q6) and enum payloads (none exist, D6)). Emitted as
    flat tables `nomu_gc_typemap_data` (per-id `[count, off…]`), `_index[id]`, `_count` — confirmed
    present in emitted objects; `-dead_strip` removes them from final binaries until part B references
    them. Corpus 29/29 green (type-ids inert under NoGC — nothing reads them yet).
  - **Part B done (2026-08-04) — accessor + self-check + `scan_object`.** `runtime.c` exposes
    `nomu_gc_typemap(id, *count)` over the codegen tables; a `NOMU_GC_TYPEMAPS` self-check dumps every
    type's map. Verified correct: a `{ Node{v:Int}, Pair{a:Node, b:Int} }` program yields `type 0: []`,
    `type 1: [8]` (managed ref at byte 8, header slot 0 and `Int` skipped), and an actor yields no
    `mu`. The binding's `scan_object` now reads the header type-id and reports each managed slot via
    the accessor (compiles; inert under NoGC, exercised at 6.2). Corpus 29/29 + frontend green.
  - **Part C done (2026-08-04) — headers on closures + any-boxes.** Both gained an `i64` header slot
    at offset 0 (shifting `fn`/captures and `witness`/`payload` by one), so every managed heap object
    now carries a type-id `scan_object` can read. **Closure** `{ header, fn, caps… }` gets a per-shape
    map (managed captures scanned, `fn` skipped) — verified: a closure capturing a class ref yields
    `[16]` (byte 16 = slot 2). **any-box** `{ header, witness, payload }` shares one map `[16]` (scan
    `payload`, skip the static `witness`, Q7) — verified on `upcast`/`composition`. Corpus 29/29 +
    frontend green; outputs unchanged. Shapes covered: `class`/`actor` (part A), `Closure`, `any`;
    **generic instances** are monomorphized to concrete classes/structs, so the class path covers them.
  - **Deferred to Q6/6.1.4 — `String`.** Its buffer is `addrspace(0)` (runtime-owned), never scanned
    by MMTk, so it needs no type-id until Q6 makes `String` a GC byte-array (`data` → `p1`, buffer →
    large-object/immortal space). No header needed under the current representation.
- **6.1.4 🔨 partly done — String-as-GC-object blocked on heap-boxing (6.2).**
  - **Done — `gc-leaf` re-audit.** `rt_str_concat` allocates, so it can trigger GC → moved **off
    `gc-leaf`** (its call sites are now statepoints that record the caller's roots). `rt_str_lit` still
    only wraps a static pointer (no alloc), so it stays leaf. Corpus + frontend green.
  - **Finding — the naive Q6 fails; String must be heap-boxed.** Making `String.data` a managed `p1`
    (so buffers are traced) was tried and **rejected by `RewriteStatepointsForGC`: "support for FCA
    unimplemented"** — the `{ p1, i64 }` String value, live across the now-statepoint `rt_str_concat`,
    is a first-class aggregate carrying a GC pointer, the exact limit that heap-boxed closures/any
    (§6.0.10). So the D6 note's "String stays register-resident, no spill" is **wrong**: full Q6
    needs `String` **heap-boxed** — a single `p1` to a `{ header, len, bytes… }` object — a
    representational change (String becomes a reference in the value model). Deferred to **6.2**: under
    NoGC nothing collects, so the current runtime-owned `addr0` buffer is correct until tracing turns
    on; the immortal-space (literals) and large-object-space (big strings) routing also belong there.
  - **Update (2026-08-05): heap-boxing deferred past the flip; the flip uses the immortal interim.**
    Heap-boxing was implemented + reverted — it makes every struct/enum with a String field a
    category-3 aggregate (FCA-across-statepoint), so full Q6 needs the D6 spill seam first. The Immix
    flip instead keeps `String` as `{ addr0, i64 }` and routes its buffers to immortal space. See the
    6.2.4 slice record for the finding and the sequencing.

**Exit:** the full M5 suite compiles and runs under MMTk NoGC (allocates, never collects);
every heap shape has a pointer map `scan_object` walks without error (a map-walk self-check
passes); no `refcount` field remains.

## 6.2 · Precise roots, safepoints & the moving collector (Immix) 🔨

One-line intent: the correctness+moving core — objects relocate, roots are precise, collection
reclaims memory including cycles. Depends on 6.1 + M9 statepoints. **Approach:** MMTk plain
**Immix** (moving; no generational barrier yet — validates evacuation + maps barrier-free).

- **6.2.1 🔨 pipeline wired (inert until the plan flips) — consume LLVM stack maps; MMTk `scan_roots`
  over carrier frames + globals.**
  - **Fixed a latent correctness bug first: `-dead_strip` was stripping `__llvm_stackmaps`.** The
    6.1.1 emitted-program `-Wl,-dead_strip` (added for binary size) was discarding the whole stackmap
    section — it carries no symbol reference (the runtime finds it by name via `getsectiondata` at
    load), and its anchor `__LLVM_StackMaps` is a *local* symbol, so nothing pinned it. This silently
    defeated the precise root walk from 6.1.1 onward; unnoticed because `gc_smoke` is env-gated and
    off the corpus regression. Fix: codegen appends a module-level `.no_dead_strip __LLVM_StackMaps`
    directive (`LLVMBridge.swift`) — marks that one atom non-strippable while dead-strip still drops
    the unreachable MMTk closure (binary stays ~2.7 MB). Needed `LLVMInitializeNativeAsmParser` (the
    object streamer assembles module inline asm) + the `AllTargetsAsmParsers` LLVM dep. A boundary
    `section$start$…` symbol was tried first and rejected (keeps the section header, not the content
    atom); `-Wl,-u` too (local symbol). *Watch item:* dead-strip and the by-name stackmap section
    conflict — any change to the link or to how the section is anchored must preserve this.
  - **Walk refactored to take a saved context.** `nomu_gc_walk_current` split into
    `nomu_gc_walk_context(unw_context_t*, …)` (the shared core) + the current-stack wrapper, plus
    `nomu_gc_walk_carrier(carrier_tls, …)` — the stopped-carrier walk the binding drives. The carrier
    context source (`gc_carrier_context`) is the **6.2.3 STW seam** (returns NULL until the handshake
    saves each carrier's context at its safepoint), so no carrier is walked yet.
  - **Binding `scan_roots_in_mutator_thread` wired (`gcbinding/lib.rs`).** Extracts the carrier tls
    from the MMTk `Mutator`, drives `nomu_gc_walk_carrier` with a C-ABI visitor that collects each
    root **slot** (the stack location, updatable) as a `SimpleSlot`, and hands them to
    `factory.create_process_roots_work` — precise, not conservative. `scan_vm_specific_roots` is empty
    (no mutable globals today; parked-fiber stacks are 6.2.2). Inert under NoGC (`scan_roots` is never
    called); exercised when the plan flips to Immix.
  - **`gc_smoke` fixture/assertions updated** for the 6.1.3 closure-header shift (offset 8 is now
    `fn`, not the captured 444) — the walk recovers the 5 live roots {111×2, 222, 333, closure} across
    two frames, dead 999 excluded; `tools/gc-smoke.sh` green again.
- **6.2.2 🔨 built + validated (inert until the plan flips) — global live-fiber registry + parked
  fiber stack scanning.**
  - **Registry (Q8).** `Fiber` gained `rt_prev/rt_next`; a global `rt_fiber_list` guarded by
    `rt_queue_mu` (spawn/complete already hold it — off the hot path). O(1) insert at
    `fiber_spawn`, O(1) remove at completion (`runtime.c`). A new `FIBER_RUNNING` status marks an
    on-CPU fiber (set by the scheduler at schedule-in): it is scanned through its carrier (6.2.1) and
    skipped by the registry scan, so its stale saved `ctx` is never walked.
  - **Parked-stack walk.** `nomu_gc_walk_fiber` fabricates a `unw_context_t` from a fiber's saved
    `ucontext` and drives the 6.2.1 `nomu_gc_walk_context`. On arm64 libunwind's register file is
    x0–x28, fp, lr, sp, pc — same order as the saved `arm_thread_state64`, so they copy 1:1.
    **Finding: Darwin `getcontext`/`swapcontext` saves no PC** (resume is via LR); seed the unwind
    with LR (the return address just past the fiber's `swapcontext`, inside the gc-leaf park frame) so
    it steps out to the Nomu frames. `nomu_gc_scan_parked_fibers` iterates the registry and walks only
    PARKED fibers (a woken fiber stays PARKED until scheduled; RUNNABLE is the never-run state with no
    roots; RUNNING goes via its carrier) — the binding's `scan_vm_specific_roots` reports the slots to MMTk
    (`gcbinding/lib.rs`). Taking `rt_queue_mu` at STW is safe: a carrier stopped at a safepoint is
    never inside a scheduler critical section (6.2.3 quiesce guarantees it).
  - **Blocking-syscall fibers.** No separate offload carrier exists in the M4 runtime — all blocking
    (`sleep`, `read`) goes through `park()` (swapcontext to the scheduler), so a blocked fiber is
    already PARKED with a saved context the registry scan covers. The "checkpoint-and-present-as-
    parked" handling applies if/when a true syscall-offload carrier is added.
  - **Validation (the highest-risk item, done).** `examples/gc_smoke_parked.nomu` +
    `tools/gc-smoke-parked.sh`: a `worker` fiber holds two class roots live across its `sleep(200)`
    park while `main`'s safepoint waits for it to park, then walks its saved context via the registry
    — recovers exactly {111, 222}, excludes the dead 999. Deterministic (10/10); concurrency corpus
    race-free under repeat runs. The 6.2.1 current-stack smoke still passes.
- **6.2.3 🔨 built + validated (runtime handshake done; MMTk `Collection` wrappers await the flip) —
  STW handshake.**
  - **Poll lowered (Q3 branch-on-flag).** `__nomu_poll` (`Lowering.swift`) now loads the process
    stop-world flag `@__nomu_stop_world`; unset → fall through (bare volatile load + test + branch, no
    statepoint); set → call `__nomu_gc_poll_slow`, which is **not** `gc-leaf`, so that call is a
    statepoint whose stack map records the loop's live roots. Added `always-inline` to the debug pass
    pipeline (`LLVMBridge.swift`) so the seam's fast path collapses into the loop and only the cold
    slow path carries statepoint cost (Q4 cheap poll). `-O2` already inlines; the volatile load + the
    external `__nomu_gc_poll_slow` call are non-removable / non-hoistable, so **O2 keeps the loop's
    safepoint** (Q4 `-O` coverage rule — verified on a release build of the bare-loop fixture).
  - **Runtime handshake (`runtime.c`).** `nomu_gc_stop_the_world` raises the flag, kicks idle carriers
    out of their scheduler wait, and waits until every carrier has parked; `nomu_gc_resume_the_world`
    clears it and wakes them. A running carrier parks in `__nomu_gc_poll_slow` (captures its context
    via `unw_getcontext` — the walk unwinds through the poll frame to the loop roots, filling the
    6.2.1 `gc_carrier_context` seam); an idle/dispatching carrier parks at the scheduler loop top with
    no context (no roots). A per-carrier control block (`CarrierCB`, registered on scheduler entry)
    holds the parked flag + saved context. **Flag granularity:** a single read-mostly global rather
    than the Q3 per-carrier flag — identical correctness for a full STW; per-carrier is a deferred
    perf refinement (noted in the code).
  - **Validation.** `examples/gc_smoke_stw.nomu` + `tools/gc-smoke-stw.sh`: a background thread stops
    the world while a compute fiber spins (root 777, held across its back-edge poll) and a fiber is
    parked (root 888), scans both, and resumes. Recovers the running root via the carrier's saved poll
    context (6.2.1) and the parked root via the registry (6.2.2), and the program runs to completion —
    proving quiesce + resume. Deterministic 5/5 (debug) + green under `-O2`.
  - **Deferred to the flip:** the MMTk `Collection` wrappers (`stop_all_mutators` → the runtime stop +
    per-mutator visit, `resume_mutators`, `block_for_gc`, `spawn_gc_thread`) and `ActivePlan::mutators`
    — they need MMTk mutator enumeration and a collecting plan to fire (`gcbinding/lib.rs`).
- **6.2.4 ✅ — the NoGC→Immix flip (collection first runs) + evacuation correctness.** The convergence
  step: it wired the currently-`unimplemented!()` MMTk callbacks and switched the plan, so tracing +
  evacuation now run. Built (all in `gcbinding/lib.rs` unless noted):
  - **Per-object size table** (`get_current_size` / `get_size_when_copied`). Codegen emits
    `nomu_gc_typemap_sizes` parallel to the 6.1.3 pointer maps (`Lowering.swift` `registerMap` now
    takes a byte size; class = `(1+Σslots)·8`, actor = `+1` for the mutex slot, closure =
    `(2+Σcaptures)·8`, any-box = 24). The runtime exposes `nomu_gc_typesize(type_id)` (`runtime.c`);
    `get_current_size` reads it via the header type-id. No header change. The `NOMU_GC_TYPEMAPS`
    self-check dump now prints sizes too.
  - **`ObjectModel` copy paths** — `copy` (evacuate: `alloc_copy` + flat byte move + `post_copy`),
    `copy_to` (overlap-safe, for a future compacting plan), `get_reference_when_copied_to`, and a
    constant 8-byte alignment. Size drives the byte move; the header rides along, managed fields are
    updated separately by `scan_object`.
  - **MMTk `Collection` + `ActivePlan`** — a **mutator registry** (`MUTATORS`, pushed at
    `nomu_gc_bind_mutator`) backs `number_of_mutators`/`mutator`/`mutators`. `stop_all_mutators` wraps
    `nomu_gc_stop_the_world` then visits each mutator; `resume_mutators` wraps the resume;
    `spawn_gc_thread` runs a worker on its own OS thread via `start_worker`. `nomu_gc_init` sets
    `threads=1` and calls `initialize_collection`. Also filled the reachable `Scanning` hooks
    (`notify_initial_thread_scan_complete` no-op, `supports_return_barrier` false).
  - **`block_for_gc` — new runtime coordination (`runtime.c`).** A carrier that triggers GC inside
    `nomu_gc_alloc` (not at a Nomu poll) calls `nomu_gc_block_for_gc`: it `unw_getcontext`s itself,
    marks its `CarrierCB` parked + saves the context (so its roots scan like any stopped carrier), sets
    the new `rt_gc_wanted` flag, and blocks until `nomu_gc_resume_the_world` clears it. `rt_gc_wanted`
    (not `__nomu_stop_world`, which the GC worker raises a moment later) is the wait predicate — that
    closes the ordering race where the initiator parks before the stop flag is up. The alloc call is a
    statepoint (`rt_alloc`/`nomu_gc_alloc` stay non-`gc-leaf`), so the walk from the saved context finds
    the caller's roots.
  - **`post_alloc` now called** (`alloc_semantic` helper) after every alloc — initializes the VO/log/mark
    metadata a collecting plan needs; a no-op under NoGC, so this was latent-correct before the flip.
  - **String → immortal space** (the interim below). New `nomu_gc_alloc_immortal` (semantics
    `Immortal`, non-moving/non-collected) + `rt_alloc_immortal` (`runtime.c`); `rt_str_concat`
    (`core.c`) and `rt_read_line` (`runtime.c`) route their buffers there so `{ addr0, i64 }` survives
    moving GC. `rt_str_lit` already wraps rodata.
  - **`PlanSelector` NoGC → Immix**, default. `NOMU_GC_PLAN=nogc` keeps the pre-flip plan for
    differential debugging; `NOMU_GC_STRESS=<bytes>` sets `stress_factor` + `precise_stress` +
    `immix_always_defrag` (a precise collect every N bytes that *evacuates* every cycle, so the copy
    paths actually run — Immix only moves on defrag).
  - **Validation.** Corpus green under Immix (default). Under `NOMU_GC_STRESS=1024` (collect + evacuate
    constantly) all 34 corpus programs are **byte-identical** to their baseline output — covering
    classes, actors, closures, any-boxes, enums, generics. `examples/gc_stress.nomu` (dedicated
    evacuation fixture: live roots + managed interior refs relocated across ~hundreds of GCs, garbage
    reclaimed) matches NoGC. All three 6.2.x smokes still pass under Immix. Deviation from the plan:
    validated by the stress/differential corpus rather than a separate bounded-memory loop or an added
    mutation-freeze counter — the byte-identical corpus under constant evacuation is the stronger test.

  **String decision (2026-08-05): immortal interim, not heap-boxing (yet).** Heap-boxing `String` (Q6:
  a `p1` to `{ header, len, bytes }`) was implemented and **reverted**. It works for scalar strings
  (`hello`/`strings` green) but makes every **struct/enum with a String field** a *category-3* value
  aggregate — values mixed with a GC pointer — which `RewriteStatepointsForGC` cannot relocate across a
  statepoint ("FCA unimplemented"). The 6.0.10 audit found zero category-3 sites precisely because
  String was not a reference; heap-boxing creates them everywhere (any `struct T: I` with a `String`
  field, wherever it crosses a call — method `self` by value, struct params/returns, `boxPayload`). Full
  Q6 therefore needs the **D6 category-3 spill seam first** (pass ref-carrying value aggregates by
  memory + a runtime root-slot scan), a pervasive lowering change. To reach a running moving collector
  without that slice, keep `String` as `{ addr0, i64 }` and route its buffers to immortal space (above):
  no category-3, strings simply never move/collect (they leak) until heap-boxed later. **Follow-up:**
  the D6 spill seam + real Q6 heap-boxing (making strings collectable) after the flip.

**Exit:** allocate-in-a-loop runs in **bounded memory**; cycle-forming and graph-heavy
programs are collected (tracing beats the retired RC); objects survive relocation intact; M5
suite green under Immix; a "collect on every allocation" stress mode passes.

## 6.3 · Generational collection (GenImmix) + write barrier ✅ (6.3.1 + 6.3.2; tuning polish remains)

One-line intent: the footprint/throughput target plan. Depends on 6.2. **Approach:** MMTk
**GenImmix** — nursery + generational barrier.

- **6.3.1 ✅ built + green (2026-08-11)** — the **generational write barrier** filling the inert
  `__nomu_write_barrier` seam, plan flipped Immix→**GenImmix**. As built:
  - **Plan.** `nomu_gc_init` defaults to `PlanSelector::GenImmix` (a copying nursery over an Immix
    mature space); `NOMU_GC_PLAN` selects `nogc` / `immix` / `genimmix` for differential debugging
    (`gcbinding/lib.rs`). MMTk's `GLOBAL_LOG_BIT_SPEC` (already `side_first`) + `post_alloc` (6.2.4)
    supply the object log bit the barrier tests.
  - **Barrier = object-remembering post-write** (GenImmix's `ACTIVE_BARRIER = ObjectBarrier`). The
    codegen seam (`Lowering.swift` `nomuWriteBarrier`) stores `val` into `*slot`, then calls the
    runtime `rt_gc_write_barrier(obj, slot, val)` (`runtime.c`), which forwards to the binding
    `nomu_gc_write_barrier_post` → `memory_manager::object_reference_write_post` on the current
    carrier's mutator. Under GenImmix that remembers `obj` on the first mutation of a mature object;
    under NoGC/Immix the mutator barrier is `NoBarrier`, so the same unconditional call is a no-op —
    **collector-agnostic** (LXR refills the same seam later, 6.0.5). The seam stays `gc-leaf`
    (remembering never triggers GC or moves objects), so no new statepoints — the corpus stays
    structurally identical.
  - **Array stores routed through the barrier.** `Array` element stores + the buffer-publish store
    (`lowerArrayLit`/`lowerArraySet`/`lowerArrayAppend`, via `storeField` with the buffer/handle as
    the source object) now barrier managed elements — the previously-unbarriered
    `Array.append`-into-a-mature-buffer store (6.0.8 watch item) is closed. A value-typed element
    stays a plain store.
  - **Out-of-line first; inline fast path deferred.** The barrier is an out-of-line `gc-leaf` call
    (like the still-out-of-line alloc TLAB fast path, 6.0.10). The inlined fast path — test the log
    bit in side metadata, call a slow path only on first mutation — is a **deferred perf follow-up**
    (6.3.2 / 6.0.9), not a correctness item.
  - **Validation.** `examples/gc_gen.nomu` + `tools/gc-gen.sh` (new): a mature object is mutated to
    point at a fresh nursery object, then nursery GCs run (small `NOMU_GC_HEAP`) — byte-identical to
    NoGC across repeated runs proves the post-promotion cross-generation store is remembered and the
    young objects relocate. The 35-program corpus is byte-identical under default GenImmix vs. NoGC;
    the three 6.2 gc-smoke scripts and the (now Immix-pinned) gc-stress/arr-gc evacuation
    differentials stay green.
- **6.3.2 done + footprint measured (2026-08-11).**
  - **Footprint tooling.** `NOMU_GC_STATS` samples `used_bytes` at each GC end (cheap page counts) and
    reports min/max heap footprint; `NOMU_GC_STATS_LIVE` also enables MMTk's `count_live_bytes_in_gc`
    for a precise per-space `used/live` breakdown (`gcbinding/lib.rs` `sample_footprint` /
    `nomu_gc_report_stats`; runtime prints at exit). Bench: `examples/benchmarks/gc_footprint.nomu` (a
    retained `Array<Box>` live set + garbage churn).
  - **Two binding bugs found by disciplined profiling; both fixed.** The profiling blocker (GenImmix
    livelocking/crashing whenever it had to evacuate a retained live set) was *not* the opt-level
    (rebuilt at `-O3`, no change) and *not* the 6.3.1 non-carrier guard. lldb `thread backtrace all` on
    the hung process (correcting an earlier sampled guess) showed the GC worker stuck **inside MMTk**,
    not in `block_for_gc`, in the space-reservation path. Two root causes:
    1. **`ActivePlan::is_mutator` was a stub returning `true` for every thread.** `Space::acquire` gates
       `should_poll` on `is_mutator(tls)`; a collector must return `false`. With the stub, the GC
       worker's evacuation copy-allocation polled the GC trigger during collection → the infinite
       `calculate_reserved_pages`/`is_emergency_collection` reserve→poll loop. Fix: match the tls
       against the registered mutator carriers (the worker matches none).
    2. **All allocations used `AllocationSemantics::Default`; objects larger than
       `max_non_los_default_alloc_bytes` (~16 KiB, `Block::BYTES>>1`) must use `Los`.** A variable-size
       `Array` buffer over ~16 KiB landed in the moving Immix space, which cannot evacuate an object
       that large, so the copy allocator grew the space without bound (→ stack-overflow crash). Fix:
       `nomu_gc_alloc` routes `size > MAX_NON_LOS` to the large-object space. This is scale-triggered
       (N=2000 buffer ~16 KiB survived; N=5000 ~64 KiB crashed) and plan-agnostic (Immix + always-defrag
       hit it too). LOS objects stay ordinary GC objects (same header, pointer-map/leaf scan), so this
       is transparent to tracing.
  - **Result: healthy collection at tight heaps + the thesis met.** The `gc_footprint` bench (N=500 000,
    live set ~11.9 MiB) now runs from a **24 MiB heap** (≈2x live) with 7 GCs, sub-second, correct.
    Precise steady-state footprint: **peak-live 11 908 KiB, used 12 556 KiB → 1.05x** (consistent across
    24/32/48 MiB heaps). Comfortably inside the ~1.1–1.3x thesis. *Caveat:* ~4 MiB of the live set is the
    array buffer in exact-fit LOS, which dilutes the blended ratio; the Immix small-object portion alone
    is ~1.08x — still within target. The same fix also resolved the **sub-viable-heap livelock** (gc_gen
    now completes at 200–300 KiB) and the **`NOMU_GC_STRESS`+GenImmix** nested-GC (same `is_mutator`
    cause), so those can be un-pinned from Immix later.
  - **Inlined write-barrier fast path — done (2026-08-12).** The barrier was fully out-of-line (a
    C→Rust FFI call + a `dyn Barrier` virtual dispatch + the log-bit load — ~20 ns/store). Two steps,
    each measured on `examples/benchmarks/gc_barrier.nomu` (20M managed stores into a mature object, so
    every store after the first hits the already-logged fast path; `-O2`):
    - *Step A — monomorphize.* The binding checks the unlog bit directly (no virtual dispatch) and an
      exported `__nomu_barrier_active` flag short-circuits NoGC/Immix (their log-bit metadata is
      unmapped). GenImmix **0.71 s → 0.33 s**; NoGC/Immix 0.30 s → 0.10 s (the flag skips the old
      no-op virtual call).
    - *Step B — inline into codegen.* `Lowering.swift` emits the fast path in IR: load
      `__nomu_barrier_active`; compute the unlog-bit address from the binding-published layout
      (`__nomu_logbit_base` + `__nomu_logbit_log_region`, so no hardcoded MMTk constants — 1 bit/region:
      `region = addr>>logR; byte = *(base+(region>>3)); bit = (byte>>(region&7))&1`); call the
      out-of-line `rt_gc_write_barrier` slow path only when the bit is set (first mutation). GenImmix
      **0.33 s → 0.047 s** (≈15× vs the original barrier), now within ~15 % of Immix's 0.040 s — a
      ~0.35 ns/store log-bit-load tax. Correctness held throughout (gc-gen's cross-gen remembering,
      arr_gc, gc_footprint's 1.05×, all gc-smokes, corpus 35/35). `gc-leaf` + `alwaysinline` unchanged;
      `-O2` LICM hoists the loop-invariant flag/base/region loads.
  - **Remaining 6.3.2 polish (not blockers):** nursery sizing / promotion tuning; a footprint sweep over
    more workload shapes; and the collector hot-path `opt-level` (currently `z` for size, 6.1.1).

**Validation-harness notes (6.3.1).** Forcing heavy collection on the small fixtures runs into two
resource-edge behaviors, neither a barrier bug (the barrier is correct under real GC + the corpus
differential):
- **`NOMU_GC_STRESS` is an Immix tool, not GenImmix.** Under an aggressive byte-trigger the
  generational collector's own evacuation (copy) allocations re-trip the stress trigger → a *nested*
  GC the single worker (`threads=1`) can't service. `nomu_gc_block_for_gc` now guards against a
  non-carrier (GC-worker) thread blocking there (it would deadlock the collector); the residual is
  that aggressive stress + GenImmix makes no useful progress, so the gc-stress/arr-gc evacuation
  differentials pin `NOMU_GC_PLAN=immix` and GenImmix is validated by real heap-pressure GC
  (`gc-gen.sh`, small `NOMU_GC_HEAP`).
- **Sub-viable heaps livelock — FIXED (6.3.2).** This was the same `is_mutator` bug as the evacuation livelock: a too-small `NOMU_GC_HEAP` spun in `calculate_reserved_pages`/`get_reserved_pages` instead of collecting. With `is_mutator` correct (and large `Array` buffers in LOS) it is gone — gc_gen completes at 200–300 KiB now. A genuinely-too-small heap should raise a clean OOM (MMTk's `not_acquiring` asserts the copy plan reserved headroom); verifying that clean-OOM path is a follow-up.

**Exit:** GenImmix green on the M5 suite + stress tests; measured steady-state footprint near
the live set on the bounded-memory benchmarks (the thesis metric). *(6.3.1 cleared the suite +
generational barrier; **6.3.2 met the footprint thesis — ~1.05x live set on the churn benchmark,
after the `is_mutator` + LOS-routing fixes.** Remaining: nursery/opt tuning, inlined barrier, wider
workload sweep — polish, not exit blockers.)*

## 6.4 · Actor runtime + teardown ✅ (built 2026-08-12)

One-line intent: the decided async actor model (`concurrency.md` §9) on the real runtime, with
GC-driven lifetime. Doing 6.4 required building the runtime the shipped M3.4 mutex scaffold never
had — a mailbox, message-send, and pooled handler fibers — so this phase is the actor runtime *and*
its teardown, which turned out to be one body of work. (The scaffold was an object
`{ header, fields…, mu }` whose handlers locked a `pthread_mutex_t` and ran on the caller's fiber:
same observable behavior for a plain blocking call, but no mailbox, no handler fiber, and a leaked
mutex.) LLVM backend only; the C backend keeps the scaffold.

- **6.4.1 ✅ — async actor runtime.** Each actor object carries a **mailbox** (a GC object,
  `{ header, mb_head, mb_tail, scheduled, sched_next }`); an `on`-handler call lowers to a
  **fire-and-forget message-send** — build a GC message `{ header, next, thunk, self, args… }`,
  `rt_actor_send` enqueues it and returns (the sender never waits, §9 revised 2026-08-12). A scheduled
  mailbox joins a **global scheduled-mailbox queue** (intrusive via `sched_next`); a **capped pool of
  mailbox fibers** pulls mailboxes off it and drains each to completion. The `scheduled` flag gives the
  single-drain invariant → serial, non-reentrant, per-sender FIFO. The drain *loop* is codegen
  (`nomu_actor_drain`) so the mailbox/message stay tracked `addrspace(1)` roots across handler
  safepoints; the C runtime provides `rt_mailbox_pop`. **The scheduled-queue head is a GC root**
  (reported by `nomu_gc_scan_parked_fibers`, `sched_next` traced through the pointer map), so a
  scheduled mailbox whose actor is otherwise unreferenced — fire-and-forget outstanding work — stays
  live until drained. The pool cap (`RT_MAX_MAILBOX_FIBERS`) bounds fiber-stack growth under a churn of
  many concurrently-busy actors (excess mailboxes wait in the queue); this is the "grows to a cap" the
  pool always specified — the first build was uncapped and overran the run queue at ~1,900 fibers under
  the teardown churn, root-caused and fixed 2026-08-13. The mutex is gone.
  - *Fire-and-forget simplification (done 2026-08-12):* the first build had blocking value handlers —
    the message carried `sender`/`reply` and `rt_actor_call` parked the caller until the handler wrote
    the reply. **Actors are now send-only** (`concurrency.md` §9): no value handlers (sema rejects a
    non-void `on` handler), no caller parking, no reply slot, no `rt_mailbox_wake`; `rt_actor_call` →
    `rt_actor_send`. There is no reply/ask/request-reply of any kind — fire-and-forget is the only
    actor operation (§9); values come from `spawn let` results or channels, not actors. Also added
    **drain-to-quiescence** at program exit (`rt_active_drains`): the
    scheduler exits only when no user fibers *and* no outstanding actor drains remain, so fire-and-forget
    work isn't dropped at exit (a self-sustaining actor keeps the program alive — a live server).
- **6.4.2 ✅ — structural teardown.** Actor state + mailbox are ordinary GC objects; pending messages
  root the actor (drain-then-collect). An unreferenced idle actor owns **no non-GC resource** — no
  fiber (returned to the pool), no mutex — so it is reclaimed structurally with the cycle it dies in;
  actor↔actor cycles collect together. No weak handle, no `ReferenceGlue`, no free-queue (the
  2026-08-04 fiber-stack weak-handle plan is retired — §6.0.5). The vestigial refcount actor-release
  path was already gone (`ObjectHeader` replaced it). Pool fiber stacks are runtime-lifetime.
- **Park-protocol hardening (built alongside).** Heavy fiber parking surfaced a latent M:N race (a
  fiber re-queued before `swapcontext` finished saving its context → SIGBUS / lost-wakeup deadlock).
  Fixed with a lock-handoff park protocol: the single scheduler lock is held across every
  fiber↔scheduler switch, applied to spawn/join, timer sleep, I/O poller, and pool rental — hardening
  the pre-existing park sites too. (Found via the blocking actor↔actor calls of the first build; the
  fix stands regardless of the fire-and-forget simplification.)

**Exit (met):** `examples/actor.nomu` (6/6) and `examples/actor_relay.nomu` (actor↔actor, 400/400/400)
run on the model; byte-identical under NoGC and GenImmix; stable under tight-heap GC over hundreds of
runs; the corpus differential and GC tools stay green. **Teardown proven:** `tools/gc-actor-teardown.sh`
churns 200k short-lived actors and completes under GenImmix at a 4 MB heap where NoGC runs out of
memory — the dead actors + mailboxes are actually reclaimed, not merely plausibly-so, and the capped
mailbox-fiber pool + scheduled-queue rooting hold under the churn. No per-actor non-GC resource remains.

## 6.5 · Escape analysis (perf tail) — conservative phase ✅ (2026-08-13); precise pass is M7

One-line intent: recover the stack-allocation win — keep provably-non-escaping reference
allocations off the GC heap (`memory-model.md` §6.1). Best-effort: the fallback is always
heap-allocate, so precision affects speed only, correctness always holds.

**Sequencing (decided 2026-08-13).** Escape analysis ships in two phases. A **conservative pass on
the structured NOIR** (the current typed IR; artifact extension `.noir`, `--emit-noir`) lands in M6 —
it captures the deep case (a reference allocation in a hot loop, used locally, discarded each
iteration) with no new IR. The **precise pass** needs def-use chains and a CFG to follow pointers
across control flow, which the structured NOIR does not have. NOIR lowers straight to LLVM (the LLVM
backend, now M9, is done — there is no separate Nomu-level CFG/SSA tier, and the "CFG/SSA IR" in that
roadmap line turned out to *be* LLVM IR). Precise analysis is therefore blocked on the **M7 optimizer
tier** — the CFG/SSA NOIR IR (scheduled 2026-08-13) — built alongside its other tenants
(devirtualization, bounds-check elimination, inlining, specialization), not for escape analysis alone.
The conservative analysis front-end is replaced when the precise one lands; the 6.5.2 codegen half is
reused unchanged.

Reference allocations targeted (the `__nomu_gc_alloc` sites): class instances, `any`-boxes, closure
environments, array buffers. Structs and enums are already value types on the stack, so they are out
of scope. The conservative pass targets **class instances and closure environments** first; `any`-boxes
usually escape and array buffers have dynamic size (stack-eligible only when statically bounded), so
both are deferred to 6.5.3 (doable now on the structured NOIR, not gated on new IR).

**Design — conservative pass.**

- **Result carrier.** The analysis writes non-escaping allocation sites to a **side table** keyed by
  allocation-site identity, consumed by codegen. NOIR node types stay unchanged, so the table is
  additive and a future CFG/SSA tier can ignore or replace it — the optimization adds no coupling to the IR.
- **Escape predicate (conservative, intra-procedural).** An allocation escapes if its value is:
  returned from the function; stored into a heap object's field or a global; captured by a closure
  that itself escapes; passed as a call argument; or bound to a variable that is reassigned or
  address-taken. Every remaining allocation is stack-eligible. Any call argument is treated as
  escaping (no interprocedural summary in this phase).
- **Codegen + GC interaction (the part that earns the doc).** An annotated site lowers to an `alloca`
  (or scalar-replaced fields) in place of `__nomu_gc_alloc`. A stack-allocated object whose fields
  hold `addrspace(1)` pointers stays part of the GC's world: those fields are scanned as roots through
  the frame's stack map, so stack allocation changes only where the collector finds the object, and
  its contents still trace. Stores into a stack slot elide the generational write barrier (a stack
  slot is a location the barrier has no reason to track). The lowering stays collector-agnostic — it
  assumes neither a moving nor a non-moving collector.

- **6.5.1 ✅ (built 2026-08-13)** — conservative escape-analysis pass on the structured NOIR
  (`src/frontend/sources/EscapeAnalysis.swift`); `analyzeEscapes(module) -> EscapeResult`, a side
  table of non-escaping `AllocSite`s (class-instance and closure, keyed by span+kind). Intra-procedural
  single-walk analyzer: a local `let` bound to an allocation stays non-escaping while it is only read
  (field access, or invoked as a call target) and never returned, stored, passed to a call, spawned,
  reassigned, or captured by a closure. Not yet wired into the pipeline — 6.5.2 is its first consumer.
  Verified by `EscapeAnalysisTests` (8 cases, incl. the gc_smoke shape); full frontend suite green.
- **6.5.2 ✅ (built 2026-08-13, classes + closures)** — codegen consumes the side table:
  - A non-escaping **class instance** lowers to an entry-block `alloca` (addrspace 0) in place of
    `__nomu_gc_alloc`; the value flows as an addrspace(0) pointer that escape analysis proved feeds only
    field access, so the layout is unchanged (field GEPs untouched) and field stores are plain (a stack
    slot is not a heap location the write barrier tracks). The first cut restricted this to leaf
    (managed-free) classes; **6.5.3 lifted that**. `Lowering.swift`: `lowerConstruct` class branch.
  - A non-escaping **closure** whose captures are all scalar leaves (`Int`/`Double`/`Bool`) gets a stack
    env: `lowerClosure` `alloca`s the fused `{header, fn, caps…}` object and generates the impl's env
    param as addrspace(0); the call site (`lowerCall`) types the env argument from the closure value's
    actual address space, so the two match. A non-escaping closure is only ever invoked locally, so the
    addrspace(0) env never crosses a boundary that expects the managed form. `isScalarLeaf` gates it.
  - Shared: the `let`-binding slot types from the produced value (so a stack object/closure flows as an
    addrspace(0) pointer); wired in `emitObject` (`analyzeEscapes` on the post-mono module), gated by
    `NOMU_NO_ESCAPE` (the disable flag). Non-leaf objects, non-scalar-capture closures, `any`-boxes, and
    arrays stay on the heap — see 6.5.3/6.5.4 for why each waits.
- **6.5.3 (partly built 2026-08-13 — codegen coverage, no new IR)** — extend the stack-allocation
  action to more site kinds on the *current* structured NOIR:
  - **Non-leaf classes ✅** — the leaf restriction is lifted: any non-escaping class stack-allocates,
    including fields that hold managed pointers. The object pointer only feeds local field GEPs (escape
    analysis guarantees no escape), so SROA scalar-replaces the alloca and each managed field becomes an
    addrspace(1) SSA value the statepoint rewriter roots and relocates — the same mechanism every
    class-typed local uses, so no interior stack-map scanning. A managed store into a stack object skips
    the write barrier (`storeField` gates on an addrspace(1) base — a stack slot is a root, not a
    remembered-set entry). Soundness rests on SROA fully promoting the object, which holds for this
    pattern (single-def, address never taken past field GEPs; the debug pipeline runs `sroa`). Verified
    under the moving collector: `examples/escape_nonleaf.nomu` + `tools/escape-nonleaf.sh` — a stack
    `Holder`'s interior heap pointer survives and relocates across Immix evacuation, byte-identical to
    NoGC. (Surfaced + fixed the barrier-on-stack-object ABI mismatch that broke `gc_gen` under escape-on.)
  The three items below are **Deferred** (direction understood, work intentionally postponed — they
  don't clear the current-phase perf triage in `deferred.md`). Tracked here for now; to be moved to
  `deferred.md` later.
  - **Non-scalar closure captures — Deferred.** The whole-object-alloca path is unsound here: the env's
    address is passed to the impl function, defeating SROA, so a managed capture would sit unscanned in
    the stack env. Needs the stack-map scanning path (or closure inlining). Closures stay scalar-leaf
    (`isScalarLeaf`) until then.
  - **`any`-boxes — Deferred.** Same SROA-root mechanism as non-leaf classes (a box has a p1 payload); a
    non-escaping box could stack-allocate. Cheap to add, but rarely fires (boxing usually escapes), so
    parked until a workload wants it.
  - **Arrays — Deferred.** A dynamic-size buffer can't stack-allocate in general (only a
    statically-bounded literal), and the handle+buffer split needs its own handling.
- **6.5.4 ⬜ (blocked on M7)** — precise, flow-sensitive analysis (pointers through
  conditionals/aliasing). Needs def-use chains + a CFG, i.e. the **M7 optimizer tier** (CFG/SSA NOIR);
  the structured NOIR can't express it. (The LLVM backend, now M9, is done; it lowers structured NOIR
  straight to LLVM.) Replaces 6.5.1, reuses 6.5.2/6.5.3. Lands with M7's co-tenants (devirt, BCE,
  inlining, specialization), not for escape analysis alone.

**Exit (conservative phase, classes + closures — met):** `examples/escape.nomu` + `tools/escape.sh`
— a leaf class in a hot loop is stack-allocated: the emitted object references no `rt_alloc` with the
pass on, references it with `NOMU_NO_ESCAPE=1`, and prints identically either way (a scalar-capture
closure behaves the same). Corpus differential byte-identical on vs off across all examples (1 stdin
skip); the seven GC tools stay green (they pin `NOMU_NO_ESCAPE=1` internally, since escape analysis
legitimately removes leaf heap roots the collector tests assert on); frontend suite green incl.
`EscapeAnalysisTests`.

## 6.6 · Inline allocation fast path ✅ (built 2026-08-13; the deferred alloc-seam inlining, 6.0.10)

One-line intent: replace the `__nomu_gc_alloc` seam's out-of-line `rt_alloc` tail-call with the inline
bump-pointer TLAB fast path — the matching half of the mutator-seam inlining (the write barrier was
inlined in 6.3.2). Originally assigned to 6.1.1 / 6.2, deferred, picked up 2026-08-13.

**Research findings (MMTk 0.32, verified against its source).**
- **One uniform fast path across all our plans.** MMTk's own `mock_test_allocator_info` confirms NoGC,
  Immix, and GenImmix all use a bump-pointer fast path. `memory_manager::get_allocator_mapping(mmtk,
  AllocationSemantics::Default)` → a selector; `AllocatorInfo::new::<NomuVM>(selector)` →
  `BumpPointer { bump_pointer_offset }`. The `BumpPointer` is `{ cursor: Address, limit: Address }`
  (cursor at +0, limit at +8) sitting at `mutator + bump_pointer_offset`.
- **The offset is runtime, not compile-time.** The plan is chosen at runtime (`NOMU_GC_PLAN`), so
  codegen can't bake the offset; the binding publishes it at init (like `MAX_NON_LOS`) and the inline
  path reads mutator memory at `mutator + offset`.
- **`post_alloc` is a no-op** for our config. `post_alloc` → `space.initialize_object_metadata`, which
  is empty for Immix and (for the GenImmix nursery CopySpace) only does work under the `vo_bit`
  feature, which we do not enable. The generational unlog bit is set at *promotion* during GC, not at
  alloc. So the inline path skips `post_alloc` entirely.
- **Alignment is free** — sizes are multiples of 8 and align is 8, so the cursor stays 8-aligned; no
  alignment arithmetic in the inline path.
- **Zeroing must be preserved** — MMTk returns raw memory; `rt_alloc` memsets to keep Nomu's
  zero-initialized-fields contract. The inline path emits the zero-fill.
- **Hoist contract (6.0.3).** The cursor/limit loads and the cursor store must not be hoisted or
  cached across a safepoint (a GC resets the TLAB). The fast path is call-free, so it is safe
  internally; the risk is a loop with a back-edge poll caching the cursor. Statepoints clobber memory,
  which should block the hoist — verify in the emitted IR, and make the accesses opaque if needed.

**Plan.**
- **6.6.1 ✅ (2026-08-13) — binding publishes the offset.** `nomu_gc_init` computes the Default-semantics
  `bump_pointer_offset` (`get_allocator_mapping` → `AllocatorInfo::new`) and the LOS threshold, and
  stores them in the exported globals `__nomu_bump_offset` / `__nomu_max_non_los` (`usize::MAX` = no
  fast path). `rt_mutator` is now exported (non-`static`) so the inline path can read the per-carrier
  mutator as a thread-local. Verified: both globals present in a linked binary; corpus still runs.
- **6.6.2 ✅ (2026-08-13) — codegen inline fast path.** `nomuGcAlloc` now emits: read the thread-local
  `rt_mutator` and `__nomu_bump_offset`/`__nomu_max_non_los`; fast path only when the offset is
  published, the mutator is bound, and the size is not LOS (else `rt_alloc`); load `{cursor, limit}`,
  align the cursor to 8, `new = aligned + size`; if `new <= limit` → store the cursor, zero via `memset`
  (now `gc-leaf`), return the object; else → tail-call `rt_alloc` (the statepoint). `alwaysinline`
  collapses it into each site. Cross-module TLS access to `rt_mutator` works on LLVM 23 / macOS (a
  `_tlv_get_addr` call on Darwin — the fast path is not fully call-free here, but drops the statepoint +
  MMTk overhead).

**Exit (met):** compiles/verifies/links and runs correctly under NoGC / Immix / GenImmix; the seven GC
tools stay green (they exercise the inline path under real + moving GC, including 200k-actor churn and
evacuate-every-cycle stress — byte-identical, which also proves the cursor load is not hoisted across a
safepoint); the emitted IR shows the bump inlined into `main` with `rt_alloc` only on the cold path;
`escape-diff` byte-identical on vs off; frontend suite green.

**Measured win (2026-08-13).** A/B on an alloc-dominated loop (10M heap `Box`es, NoGC, macOS arm64;
inline path toggled off with `NOMU_NO_INLINE_ALLOC`, identical output both ways): **~4.8× at debug
(0.24s → 0.05s), ~7× at -O2 (0.25s → 0.03s).** Confirms the win holds on Darwin despite the tlv call —
the fiber-pinned mutator cache (`deferred.md`) would push it further by removing the `_tlv_get_addr`
read. This is the alloc-path speedup in isolation; whole-program wins scale with allocation density.
`NOMU_NO_INLINE_ALLOC` is retained as the A/B knob and a correctness fallback.
