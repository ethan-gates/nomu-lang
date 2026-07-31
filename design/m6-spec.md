# M6 — Implementation Spec (Real GC via MMTk)

**Status:** working draft — the ordered work plan for M6, derived from `memory-model.md`
(§3 GC, §6 escape analysis / cleanup, §8 performance profile), `compiler.md` (§6 C→LLVM
transition checklist, §7 GC binding), and the runtime facts in `runtime.md`. It pins the
build sequence; the *design* lives in those docs and the two decisions stamped in 6.0.4.
**Design is still opening** — several phase approaches are `Open`; this spec records the
sequence and the question each phase must close, not a settled plan.

> Authoring conventions per `lang-project/milestone-doc-guide.md` (numbering, status markers,
> front matter, slice records, exit criteria).

**Build status (2026-07-30):** **not started.** M6 is **hard-gated on M8** (LLVM backend +
precise stack maps), reordered *before* M6 (`roadmap.md`; 6.0.4). Design-opening: the two
cross-cutting decisions (LLVM-first; mainline-GenImmix sourcing) are locked; the per-phase
approaches (parked-fiber scanning, mutator mapping, safepoint density, actor teardown) are
`Open`.

**Framing correction:** the roadmap names M6 "real GC (MMTk)," but the bar is **not** "it
collects" — it is **validating the performance thesis**: a *moving* collector at ~1.1–1.3×
live-set footprint with competitive throughput (`memory-model.md` §8). A non-moving mark-sweep
prototype would clear "it collects" while validating none of the doubted bet — hence the
moving-Immix target and the M8-first reorder.

**Prerequisites** — grounding M6 against the current compiler (M5; C backend; bump-and-leak
`rt_alloc`; vestigial `ObjectHeader { refcount }`; M:N `ucontext` fiber scheduler):
- **M8 — LLVM backend + statepoints (the hard gate).** A moving collector needs precise roots
  via compiler-emitted stack maps the C backend cannot produce (`compiler.md` §6). M8 lands
  the LLVM path, the lower CFG/SSA IR, and statepoint stack maps; M6 rests on them. Reordered
  before M6 (decided 2026-07-30, `roadmap.md`).
- **Held invariants (through M5), no pre-slice needed** — single allocation seam (`rt_alloc`)
  and an explicit scannable object model (`compiler.md` §7). They already exist.

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
  (`memory-model.md` §3; 6.0.4).
- **Escape analysis** — a perf pass (stack allocation / scalar replacement); descopable to the
  M6 tail or a follow-on (`memory-model.md` §6.1; phase 6.5).
- **User-visible finalizers** — none planned; internal actor teardown only (phase 6.4).

### 6.0.2 · Compiler surface touched

Post-M8 pipeline: `… → typed IR → lower CFG/SSA IR → LLVM (statepoints, barriers) → native`.
M6 touches:
- **Codegen (LLVM)** — GC header on every heap object; per-type **pointer maps** as static
  tables keyed by a header type-id; **statepoint** safepoints (maps at calls / loop back-edges
  / alloc slow path); **write-barrier** inlining on reference-field stores; inlined alloc
  fast path.
- **Runtime (C + Rust binding)** — the MMTk `VMBinding` (`scan_object`, `scan_roots`,
  `block_for_gc`, resume); a **live-fiber registry**; the STW handshake; per-carrier `Mutator`.
- **IR / Sema** — the escape-analysis pass on the CFG/SSA level (6.5).

### 6.0.3 · Dependencies

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

### 6.0.4 · Cross-cutting decisions

- **LLVM before GC — Decided (2026-07-30).** M6 validates the moving-collector performance
  thesis, which needs precise roots. The C-path bridges were rejected: conservative-pinned
  scanning degrades the footprint metric under test; a codegen shadow stack is precise but
  throwaway. So M8 lands first and the collector rests on statepoint stack maps
  (`roadmap.md`; `compiler.md` §7). Corollary: **precise roots, never conservative.**
- **Collector sourcing: mainline GenImmix; LXR later & owned — Decided (2026-07-30).** MMTk's
  value is a live borrow; mainline GenImmix is that. The LXR branch is stalled, so the
  RC-hybrid endgame is a clean *owned* reimplementation behind the same interface — nothing in
  M6 assumes LXR (`memory-model.md` §3).
- **Mutator per carrier thread — Leaning.** Allocation always runs on a carrier; TLABs belong
  to the physical thread; a fiber must not hold a mutator across a suspend. Avoids per-fiber
  buffer bloat. (Open until 6.1.)
- **Runtime stays C + thin Rust `VMBinding` — Leaning.** Codegen target stays C→LLVM; the
  binding surface is kept swappable so owning/replacing the collector is localized. Revisit
  "runtime to Rust" only on binding friction.

### 6.0.5 · Runtime / GC posture

MMTk **GenImmix**, moving, generational; **precise** roots via LLVM statepoints; **per-carrier
mutators**; the M:N `ucontext` fiber scheduler (multiple carriers, migrating fibers, per-fiber
stacks) scanned via a live-fiber registry. GC governs memory only — races are the shareability
rule (`concurrency.md` §7), resources are `defer` (`memory-model.md` §6.2); M6 conflates
neither. **No new surface syntax.**

### 6.0.6 · Risks / watch items

- **Parked-fiber-stack scanning (highest).** No runtime precedent: needs a live-fiber registry
  plus recovering each parked fiber's saved SP/PC from its `ucontext` to drive precise
  frame-map walks. Suspension points must be safepoints.
- **Blocking-syscall fibers** — not polling at STW; must present as parked (stack scannable, no
  on-CPU roots). Interacts with `runtime.md`'s syscall offload.
- **Safepoint density vs. cost** — enough for prompt STW, few enough to stay cheap.
- **Footprint target** — if GenImmix can't reach the thesis footprint, the LXR-hybrid
  (deferred, owned) may be pulled forward.
- **MMTk API churn** — pin a version; the binding is the blast-radius boundary.

### 6.0.7 · Deferred cleanups / feature work

- LXR-style RC-hybrid (owned reimplementation) — footprint endgame.
- Barrier elision for deeply-immutable types (can't form new cross-generation pointers by
  mutation) — a perf pass (`memory-model.md` §4).
- Escape analysis if it slips past M6 (6.5).

---

## 6.1 · MMTk binding + scannable object model (NoGC) ⬜

One-line intent: stand up the binding and a scannable object model with **zero collection** —
prove allocation routes through MMTk and every heap shape is walkable before any GC runs.
Depends on M8. **Approach:** MMTk plan **NoGC**; a Rust `VMBinding` crate; C runtime calls in,
MMTk calls back for `scan_object`.

- **6.1.1 ⬜** — Rust `VMBinding` crate + build integration (bazel); MMTk NoGC linked;
  `rt_alloc` → mutator alloc; per-carrier `Mutator` init.
- **6.1.2 ⬜** — GC **header** design (mark/log bits in side metadata; in-object **type-id**);
  drop the vestigial `refcount` field.
- **6.1.3 ⬜** — codegen-emitted **per-type pointer maps** (static tables keyed by type-id)
  covering `class`/`actor`, `Closure` (`env`), `String` (leaf), `any` box, witness table
  (static / non-scanned?), generic instance (boxed field); `scan_object` dispatches through
  the map.
- **6.1.4 ⬜** — replace the `rt_str_concat` header pointer-arithmetic hack with a proper
  alloc/access API; normalize interior-pointer / alignment to MMTk `ObjectReference`.

**Exit:** the full M5 suite compiles and runs under MMTk NoGC (allocates, never collects);
every heap shape has a pointer map `scan_object` walks without error (a map-walk self-check
passes); no `refcount` field remains.

## 6.2 · Precise roots, safepoints & the moving collector (Immix) ⬜

One-line intent: the correctness+moving core — objects relocate, roots are precise, collection
reclaims memory including cycles. Depends on 6.1 + M8 statepoints. **Approach:** MMTk plain
**Immix** (moving; no generational barrier yet — validates evacuation + maps barrier-free).

- **6.2.1 ⬜** — consume LLVM **stack maps** at statepoints; MMTk `scan_roots` over live
  carrier frames + globals.
- **6.2.2 ⬜** — **live-fiber registry**; scan **parked fiber stacks** (recover saved SP/PC
  from `ucontext`, walk frames via maps); suspension points made safepoints.
- **6.2.3 ⬜** — **STW handshake**: per-carrier stop-requested flag + cooperative polling at
  safepoints; parked/blocked fibers already safe.
- **6.2.4 ⬜** — evacuation correctness: references updated on relocation; no stale interior
  pointers; pinning (if any) honored.

**Exit:** allocate-in-a-loop runs in **bounded memory**; cycle-forming and graph-heavy
programs are collected (tracing beats the retired RC); objects survive relocation intact; M5
suite green under Immix; a "collect on every allocation" stress mode passes.

## 6.3 · Generational collection (GenImmix) + write barrier ⬜

One-line intent: the footprint/throughput target plan. Depends on 6.2. **Approach:** MMTk
**GenImmix** — nursery + generational barrier.

- **6.3.1 ⬜** — LLVM-inlined **generational write barrier** (field-logging / remembered-set)
  on every reference-field store.
- **6.3.2 ⬜** — nursery sizing / promotion tuning; footprint measurement vs. the ~1.1–1.3×
  target.

**Exit:** GenImmix green on the M5 suite + stress tests; measured steady-state footprint near
the live set on the bounded-memory benchmarks (the thesis metric).

## 6.4 · Actor teardown / finalization ⬜

One-line intent: GC-driven actor lifetime, replacing the retired refcount actor-release path.
Depends on 6.2. **Approach (Open):** structural teardown vs. a GC finalization callback for
actor runtime state (fiber, mailbox).

- **6.4.1 ⬜** — remove the vestigial refcount actor-release path; drive actor collection from
  GC liveness ("unreferenced-and-idle," `memory-model.md` §2).
- **6.4.2 ⬜** — actor runtime-state teardown on collection (mechanism per 6.4's decision); no
  user-visible finalizers.

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
