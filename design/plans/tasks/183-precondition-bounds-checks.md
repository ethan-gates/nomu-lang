# `precondition` primitive + bounds-check insertion / removal

**Avenue:** Usability (safety surface) + Risk (the perf of checked access) · **Type/Lifecycle:**
`language-feature · frontend · midend` · **Size:** M · **Status:** not started — the `precondition` source
surface + its lowering to the existing SSAIR check op is the near-term piece; analysis-based removal is
[148](148-ssair-optimizer-tier.md) §148.4's residual; forced omission (`-Ounchecked`-style) is deferred for a
long time (explicit decision below) · **Source:** split from [121](121-string-utf8-model.md) 121.1.4, where
`String.byte(at:)` became an unchecked Nomu load and left the checked-access story unowned.

## What

A general runtime-check primitive and the full lifecycle of the checks it inserts:

- **`precondition(_ cond: Bool)` — the source surface.** The one general abort-on-false primitive (Swift's
  `_precondition`, Rust's `panic`, Go's panic, C's `abort`). It aborts cleanly with a diagnostic rather than
  letting a bad index read invalid memory. The author writes an ordinary comparison inside it
  (`precondition(i >= 0 && i < count)`); nothing is spelled as a "bounds check". This is the primitive the
  byte layer, assertions, `fatalError`, and any future checked indexing share.
- **Lowering to a recognizable check op.** `precondition(cond)` lowers to a mid-end check the optimizer can
  reason about. For the `index < length` shape that is the existing SSAIR `.boundscheck(index, length)` op
  (which already lowers to `index UGE length → rt_bounds_trap → unreachable`); the general form is a
  cond-fail op over an arbitrary boolean.
- **Analysis-based removal (release).** The BCE pass deletes a check it proves redundant — the
  dominating-redundant + constant-fold residual already scoped in [148](148-ssair-optimizer-tier.md) §148.4,
  growing into a `prove`-style dominator fact pass (§148.6 dominator tree + a relation store,
  cf. [167](167-fact-store.md)). Checks it cannot prove stay and run. Correctness never depends on the pass.
- **Forced omission (deferred, long).** An `-Ounchecked`-style mode that stops *inserting* the checks
  globally (distinct from eliminating them by proof). Explicitly deferred for a long time — the safe default
  is check-always, remove-where-proven.

## Why

- `String.byte(at:)` is an unchecked raw load today (121.1.4) — an out-of-range offset reads invalid memory
  instead of trapping. Restoring the Swift-style property (a clean "index out of range" trap) needs a source
  primitive to express the check and a removal path so the check costs nothing in the provable cases.
- The primitive is used far beyond String: assertions, `fatalError`, and — if collection element access is
  ever self-hosted — `Array`/`Dictionary` subscripts written in Nomu each express their own check through it.

## Design decisions (settled)

- **General `precondition`/trap, not a named `boundsCheck(index, length)` surface.** Mainstream languages
  expose ordinary comparisons plus one trap primitive; the index/length check op stays internal to the IR.
  This is what keeps the Nomu surface minimal and permanent — no transitional primitive to retire when
  subscript syntax arrives.
- **Removal lives in SSAIR**, our Nomu-specific optimizer tier, where the index-to-length relationship is
  intact. Relying on LLVM's CVP/SCEV/IRCE alone is what pushed Rust toward iterators and Swift toward a SIL
  pass; LLVM stays a free baseline for the simple affine cases that survive to it. (SSAIR stays the optimizer
  tier — this does not pull SIL's single-IR abstraction into one of our IRs: NOIR resolves, SSAIR optimizes.)
- **`for … in` is the primary bounds-check-free path.** [117](117-for-in-iteration.md) fuses the bound into
  iteration, so sequential access has no per-element check to eliminate. `precondition` + BCE is the
  random-access fallback (a parser computing an arbitrary offset).
- **Trap, not a catchable exception** — a precondition failure aborts the process, matching Swift.

## Open design

- Signature of the primitive — whether it carries a message; a paired `assert` (debug-only) vs `precondition`
  (all modes) split, following Swift.
- Whether the frontend pattern-recognizes `precondition(i < len)` into the index/length `.boundscheck` op
  (the small first step) or the BCE pass is generalized to arbitrary cond-fail conditions (the broader §148
  range-analysis investment).

## Dependencies

- **Feeds / shares with:** [148](148-ssair-optimizer-tier.md) §148.4 (the removal pass — the analysis half is
  already scoped there) and §148.6 (dominator tree + analysis-with-invalidation infra);
  [167](167-fact-store.md) (the integer-relation store a `prove`-style pass needs).
- **Complements:** [117](117-for-in-iteration.md) — the structural fast path; this task is the random-access
  fallback.
- **Motivated by / unblocks:** [121](121-string-utf8-model.md) — restores a checked `String.byte(at:)`; and
  any future user-facing checked indexing or self-hosted collection accessor.
- **Rests on:** [125](125-unsafe-raw-memory.md) — the unchecked `RawPtr` load the check guards.

## Refs

[121 String/UTF-8 model](121-string-utf8-model.md) 121.1.4 (the unchecked `byte(at:)` that motivated this);
[148 SSAIR optimizer tier](148-ssair-optimizer-tier.md) §148.4 / §148.6; SSAIR `.boundscheck` op +
`EgressArrays.emitBoundscheck` + `rt_bounds_trap` (the existing array bounds-check machinery this reuses).
