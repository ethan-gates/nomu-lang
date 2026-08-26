# Self-hosting the runtime: GC + scheduler in Nomu, bootstrapped in assembly

**Avenue:** Risk (author north-star, the core bet) · **Type/Lifecycle:** `perf · refactor · needs-design`
(runtime + language subset + compiler + GC) · **Size:** XL · **Status:** build now — core bet;
decomposes into 125 → 149 → 150 → 127 · **Source:** deferred.md (2026-08-18)

## What

Rewrite the runtime — the GC and the M:N scheduler — in Nomu itself, compiled by the Nomu compiler,
with a small per-architecture assembly floor to bootstrap (context switch, entry / TLS / stack setup,
the pre-runtime moment). The model is Go's: a runtime in the language plus arch-specific asm stubs.
Replaces MMTk (Rust, ~26 MB link archive) and the C runtime (`runtime.c` / `core.c`).

## Three goals (author's framing)

1. **Remove Rust and C** — a pure Nomu + assembly runtime; no foreign-language dependency in produced
   binaries.
2. **Performance** — the runtime compiles through the same optimizing backend (SSAIR + LLVM), so
   runtime ops (alloc fast path, write barriers, scheduler hooks) inline into user code across the
   former runtime/user boundary, the way Go's in-language runtime does.
3. **Binary-size ceiling < 999 KB** — with GC/scheduler present and essential (no reliance on
   dead-stripping them out), the whole self-contained runtime still fits a tiny footprint. Removing
   the 26 MB MMTk archive is the enabler; monomorphization + DCE keep only the runtime paths a
   program uses.

## Why it's architecturally enormous

- **A runtime-Nomu subset.** GC/scheduler code must avoid recursively invoking the services it
  implements: no implicit GC alloc, no write barrier, no unplanned safepoint, controlled stack growth.
  Needs a mechanism analogous to Go's runtime pragmas (`//go:nosplit`, `//go:nowritebarrier`,
  `//go:noescape`) — new surface + new checking.
- **Bootstrap floor.** The irreducible per-arch assembly (context switch, thread/TLS/stack setup,
  entry sequence before collector + scheduler are live).
- **Collector replacement + [LXR](127-lxr-collector.md) overlap.** The collector in Nomu may be one effort
  with LXR — decide whether to fold.
- **Compiler support.** Emitting code that satisfies the runtime-subset constraints, the
  asm-interfacing calling convention, and the bootstrap linkage.

## Base prerequisites

- **[125 unsafe raw memory](125-unsafe-raw-memory.md)** — a hard floor (the collector + allocator
  manipulate untyped memory).
- **[149 runtime-subset mechanism](149-runtime-subset.md)** — the pragmas + checking for runtime code.

## Sequencing

**Build now — the core bet, not a late-stage task.** The earlier "design early, build late"
call was made when Nomu had no memory management at all; it deferred the whole effort on the reasoning
that a Nomu-compiled runtime only pays off once the backend is mature. That reasoning applied to the
*final* performance/size numbers, not to the runtime's architecture — the unsafe surface, the
runtime-subset mechanism, the bootstrap floor, the calling convention. Those are independent of backend
maturity, and discovering them late is the real risk. MMTk/GenImmix now exists as a reference to diff
against, which is what makes an incremental self-host tractable. So we build now, and expect early
perf/size numbers to firm up as the backend matures.

**Self-host first, then evolve the collector.** Self-hosting is a location change (MMTk/Rust → Nomu);
[LXR](127-lxr-collector.md) is an algorithm change (GenImmix → RC-hybrid). Hold the algorithm constant
while moving location, then change the algorithm inside the self-hosted runtime — one unknown at a time.

**Decomposition:**
- [125 unsafe raw memory](125-unsafe-raw-memory.md) — the raw-memory surface the collector/allocator need.
- [149 runtime-subset mechanism](149-runtime-subset.md) — the pragmas + checking for runtime code.
- [150 self-hosted GC ladder](150-selfhosted-gc-ladder.md) — NoGC → mark-verify → Immix → GenImmix, each
  diffed against the matching MMTk plan.
- [127 LXR](127-lxr-collector.md) — the final collector rung, an algorithm swap inside the self-hosted GC.
- The M:N scheduler + per-arch bootstrap assembly floor stay under this task, sequenced after the GC
  ladder (the GC can run hosted alongside the existing runtime first).

## Refs

deferred.md "Self-hosting the runtime"; `runtime.md` (scheduler, safepoints, mutator);
`memory-model.md` §3 (`VMBinding`); `backend.md`; [LXR](127-lxr-collector.md),
[unsafe raw memory](125-unsafe-raw-memory.md).
