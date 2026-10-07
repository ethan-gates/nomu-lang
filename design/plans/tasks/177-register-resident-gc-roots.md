# Register-resident GC roots — reducing the moving-GC root tax

**Avenue:** Risk (mutator-performance substrate) · **Type/Lifecycle:** `perf · codegen · gc` · **Size:** M
· **Status:** needs-evaluation (measurement-gated) · **Source:** split out of the
[176](176-shaped-gc-roots.md) cost-model discussion — an independent perf lever on the moving-GC root
tax, not required to land 176.

## What

Find out whether GC roots can live in **registers across a safepoint** instead of round-tripping through
a stack slot (spill before, `gc.relocate` reload after), which is LLVM's default statepoint lowering
today. Two ordered, independent investigations:

- **177.1 — the LLVM lever for ordinary roots.** Statepoint lowering has `max-registers-for-gc-values`
  (default 0 → spill every live GC pointer). Raising it lets up to N live `addrspace(1)` pointers stay in
  registers across a statepoint, recorded as register locations the collector updates in the saved
  register context. Turn it on and measure: does it improve mutator throughput on root-heavy workloads
  (pointer-chasing / loops holding references live across safepoints), and at what N. Baseline is the
  current N=0 spill/reload — captured first as a `.post.ll` + asm dump of a managed pointer held across a
  GC-capable call.
- **177.2 — the same for shaped roots (gated on 177.1 being a win).** A shaped `word1`
  ([176](176-shaped-gc-roots.md)) is deliberately not `addrspace(1)`, so LLVM's statepoint regalloc never
  places or records it in a register. If 177.1 shows register-residence pays, ask whether a shaped root
  can share it — which means owning the placement/recording ourselves (a shaped descriptor naming a
  register plus the companion tag location, the walker updating the saved register conditionally). Likely
  expensive relative to the win; 177.1's result decides whether it is worth looking at all.

## Why

The moving-GC root tax — a live pointer held in a stack slot around each safepoint — is the standing
mutator cost of precise relocation. Non-GC codegen can keep a value live across a call in a callee-saved
register (amortized save/restore, no per-call traffic); the default statepoint lowering forgoes that for
GC pointers. If the lever recovers it cheaply, it is a broad mutator win independent of any one type.
Strings underpin everything, so if it helps ordinary roots it is worth knowing whether the shaped String
can share it.

## Dependencies & relationships

- **Measurement-gated.** 177.1 wants a benchmark harness ([155](155-integration-suite-harness.md)) and the
  throughput/pause numbers from GC observability ([159](159-gc-observability.md)); it runs naturally with
  the GC-benchmarking step. The baseline dump is the starting artifact and also validates
  [176](176-shaped-gc-roots.md)'s stack-slot behavior.
- **Independent of [176](176-shaped-gc-roots.md).** 176 ships on the stack-slot (deopt/pinned) form; 177
  is a later optimization layered on top, and 177.2 depends on 176 existing.
- **Correctness rests on register-recovery in both stack walkers.** The stackmap parser keeps register-kind
  locations, but the walk currently derives a stack address from `(base + off)`
  (`nomu_gc_walk_context` in `runtime.c`); handling true register-kind roots — recovering and updating a
  callee-saved register per frame — is part of 177.1, and the self-hosted `rtWalkFrom` (`runtime.nomu`)
  must match.
