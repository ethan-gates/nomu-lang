# SSAIR tier — work backlog

Consolidated backlog of SSAIR-stage (mid-level optimizer tier) work: passes, analyses, IR/infra, and
validation. This is the **index + brainstorm surface** for the tier. The as-built design + decisions
live in `internals/ssair.md` + `internals/memory-model.md` §6.1 (the `m7-spec` build plan was
retired on M7 completion); cross-cutting language/feature deferrals live in `deferred.md`. The `[§7.x]`
tags are milestone-phase labels (shared vocabulary), not links to a live doc; `[new]` items were first
raised here.

**Tagging:** `[size · status]` — size ∈ {S, M, L}; status ∈ {shipped, next, deferred, evaluate}.

**Guiding principle (keep the backlog disciplined).** The tier earns its keep on **language-aware wins
LLVM cannot see**: un-heaping a GC allocation, devirtualizing a witness-table dispatch, eliminating a
Nomu bounds check, specializing on Nomu type info. Resist re-implementing LLVM's own scalar
optimizations (plain GVN/LICM/DCE/constant-folding) unless there is a language-aware reason LLVM can't
reach — otherwise it is duplicated maintenance for no marginal win. When in doubt, measure the residual
LLVM leaves (`NOMU_DUMP_LLVM` → `.post.ll`) before adding a pass.

---

## 1 · Escape analysis & promotion (§7.3)

- **Interprocedural EA lift** `[M · next]` `[§7.3]` — the conservative "any call argument escapes" rule
  is the broadest limiter. Lift via a **post-inline EA re-run** (cheapest — inline already runs; promote
  again after so EA/scalar-promotion reach across the inlined call boundary) or **per-function escape
  summaries**. Highest-reach EA item; compounds with scalar promotion (§7.3.1).
- **Scalar promotion — in-place field mutation of a φ value** `[M · deferred]` `[§7.3.1 A1]` — a
  loop-carried object *both* reassigned to fresh *and* mutated in place needs field-level joins (full
  per-field mem2reg). Rare pattern; bails to heap today (sound).
- **Scalar promotion — wider field types** `[S–L · deferred]` `[§7.3.1 A2]` — v1 threads scalar +
  class/actor-reference fields. **Reference-like fields** (`String` / existential `any I` / closure /
  array-handle) are each a single `p1` pointer → a safe `p1` φ like a class ref; widening to them is
  **S** once each representation is confirmed one managed pointer. **By-value struct/enum fields** are
  the hard case (an FCA φ across the safepoint, I10) — **L**, stays deferred. Guarded by
  `isFieldPromotable`.
- **Scalar promotion — trivial-param elimination** `[S · deferred]` `[§7.3.1 A3]` — a loop-invariant
  field φ (e.g. `y` in `carried`). LLVM folds it at `-O`; marginal extra root at `-O0`. Pairs with the
  shared-Braun-engine extraction (§6).
- **Closure-env promotion** `[M · deferred]` `[§7.3]` — a non-escaping closure env stays heap (the `p1`
  env-param addrspace wall; the env crosses a call boundary to the lifted `clo:N`, so it is not a simple
  loop-carried φ). Candidate approach: scalarize captures, or thread the env addr0.
- **Spawn-env promotion** `[M · deferred]` `[§7.3]` — unsound as built (crosses the fiber boundary as a
  runtime-held root); needs the egress to copy env into fiber-owned storage.
- **Array inline / small-buffer storage** `[L · deferred]` `[§7.3, deferred stdlib]` — the real
  array-allocation lever is smallvec-style inline stack capacity + heap spill on growth, a representation
  change to `Array` that belongs with the stdlib `Array` design, not a pass. Fixed-`arrayLit` promotion
  was assessed and dropped (catches almost nothing).
- **Loop-invariant allocation hoisting + capacity pre-sizing** `[M · evaluate]` `[§7.3]` — hoist an
  allocation that is loop-invariant; pre-size a buffer grown in a counted loop. Separate later wins.

## 2 · Devirtualization (§7.4)

- **Cross-function devirt** `[M · deferred]` `[§7.4]` — an `any I` arriving as a function *parameter* has
  no locally-visible conformer, so it stays `witness`. Largely subsumed once the caller inlines (§7.5);
  otherwise an interprocedural conformer analysis.

## 3 · Inlining & specialization (§7.5)

- **Cost model** `[M · deferred]` `[§7.5]` — a real size/hotness heuristic beyond the fixed inst caps.
- **Value / constant specialization** `[M · deferred]` `[§7.5]` — clone a callee specialized to a
  known-value argument (the "specialization" axis mono doesn't cover — it specializes on types).
- **Dead-callee DCE** `[S · deferred]` `[§7.5]` — remove a function once all its calls inline (LLVM DCEs
  dead allocas, but the SSAIR-level dead function lingers).
- **Debug info through inlining** `[M · evaluate]` `[§7.0.6]` — inline-site DWARF records, or defer.

## 4 · Bounds-check elimination (§7.5 residual)

- **Dominating-redundant + constant-fold BCE** `[M · deferred]` `[§7.5]` — the retained residual:
  redundant-with-a-dominating-check (RMW / repeated same `(array, index)`), and `a[k]` with `k`+length
  statically known. Needs a dominator tree (§6) + light value-numbering, no loop reasoning. The
  loop-bound case is descoped in favor of `for … in` bounds-check-free-by-construction (`deferred.md`).

## 5 · Classic SSA optimizations (only where language-aware)

Screen each against the guiding principle above — most plain scalar opts are LLVM's job.

- **Self-tail-call → loop** `[S · evaluate]` `[deferred.md TCO]` — rewrite a function's tail call to
  itself into a back-edge with parameter reassignment (tail recursion → a loop). High-value, contained,
  the common TCO case; the tier is its natural home. (Guarantee-vs-best-effort decision is in
  `deferred.md`.)
- **Sparse conditional constant propagation (SCCP)** `[M · evaluate]` — fold constants + prune dead
  branches. Language-aware payoff is as an *enabler*: a known enum tag / constant unlocks devirt and EA
  where LLVM's later run is too late to feed the tier. Measure the enabling win before building.
- **GVN / value numbering** `[M · evaluate]` — scope narrowly to what BCE's dominating-redundant needs;
  general GVN is LLVM's job.
- **LICM (language-aware)** `[M · evaluate]` — LLVM does scalar LICM; the tier-only case is hoisting a
  loop-invariant *allocation* or barrier (overlaps §1). Evaluate against LLVM's residual.

## 6 · Analysis framework & infrastructure

- **Dominator tree** `[M · next-when-needed]` — a prerequisite for BCE (dominating-redundant), LICM, and
  general dominance queries. Not yet built; the first consumer (BCE) pulls it in.
- **Analysis pass kind (side tables + explicit invalidation)** `[M · deferred]` `[§7.3]` — the pass
  manager runs transforms; the analysis-with-invalidation machinery formalizes when a second analysis
  consumer appears (EA is intraprocedural per-run today). Side tables match the M6 conservative-EA shape.
- **Alias / effect model** `[L · evaluate]` `[§7.0.6]` — added only when a pass's precision demands it;
  cost-vs-win open.
- **Shared SSA-construction (Braun) engine** `[S–M · deferred]` `[§7.3.1]` — `ScalarPromotion`
  reimplements the field-level Braun read/seal logic that `SSAIRGen` owns privately. Extract a shared,
  variable-keyed engine into `ssair` (like `remapOperands`) once a second consumer justifies it; unlocks
  trivial-param cleanup (§1) reuse.

## 7 · Verifier & correctness (§7.6.2)

- **Dedicated I9/I10 static checks** `[S · deferred]` `[§7.6.2]` — I9 safepoint coverage after
  block-merge/unroll; I10 no managed value sunk into an FCA across a safepoint. Sound-by-construction
  today (T6 exercises I9 at runtime); belt-and-suspenders for future loop-structure transforms.
- **Release-gate `verifySSAIR`** `[S · deferred]` `[§7.6.2]` — debug/assert-on, release-off (the LLVM
  `-verify` model), so `-O` compiles stop paying the per-compile self-check cost.
- **Scalar-promotion verifier checks** `[S · evaluate]` `[§7.3.1]` — an explicit check for the
  scalarized form (currently rests on I1/I3 + the `scalar-carried` GC gate).

## 8 · IR format, tooling, observability

- **IR hardening — versioned round-trippable SSAIR format + per-stage I/O** `[M–L · decide-early]`
  `[deferred.md]` — a durable text format + a `--start-from` counterpart to `--stop`, enabling per-stage
  unit tests and stage-as-invariant (golden IR in → expected IR out). Cheapest to set while SSAIR is
  young; flagged decide-early for M7.
- **Per-pass firing counts** `[S · deferred]` `[deferred.md, §7.6.1]` — each pass reports how many sites
  it rewrote, alongside per-pass timing (the timing table already groups by phase). Gate the whole timing
  table behind a flag rather than always-on stderr.
- **CFG / SSAIR dump improvements** `[S · evaluate]` — a graph view or richer annotations beyond the flat
  textual dump; folds into IR hardening.

## 9 · Perf validation & benchmarks

- **Broaden `perf-tier.py` as passes land** `[S · ongoing]` `[§7.6.1]` — `micro_carried` covers
  loop-carried scalar promotion; add isolating workloads for interprocedural EA, BCE, and specialization
  when built.
- **Randomized differential (T7)** `[L · M12]` `[§7.0.5 T7]` — a generated-program fuzzer, tier-on vs off
  under forced GC — the systematic version of the T1–T3 oracles. Lightweight seed now, full harness with
  M12 concurrency hardening.

## 10 · Terminal — retire the NOIR oracle (§7.7)

- **Delete `NOIRToLLVM` + forwarders + the mid-NOIR `EscapeAnalysis.swift`** `[M · terminal]` `[§7.7]` —
  the last M7 action, once every tail with differential coverage is done and the differential is green.
  `NOMU_EGRESS` and `tools/egress-diff.sh` retire with it. Nothing that still wants differential coverage
  may be outstanding when this lands.
