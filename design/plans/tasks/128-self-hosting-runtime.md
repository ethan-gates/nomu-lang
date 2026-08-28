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
  ladder (the GC can run hosted alongside the existing runtime first). This task also inherits the GC's
  **full-runtime root-scanning integration** from [150](150-selfhosted-gc-ladder.md): invoking the
  self-hosted stack walk at a real stop-the-world over all live mutators, plus the parked-fiber
  (`scan_parked_fibers`) and scheduler-root (`rt_sched_head`) sources. The ladder proves collector policy
  hosted on the existing C scheduler; wiring the self-hosted walk into a real STW couples to the
  carrier/context machinery built here, so it lands with the scheduler.

## Subtasks

The parts this task owns directly (the delegated prerequisites 125/149/150/127 keep their own numbers):

- **128.1 — M:N scheduler in Nomu.** Replace the C/pthread scheduler (run queue, carriers, fibers,
  safepoints) with a self-hosted one under the 149 subset.
- **128.2 — Per-arch bootstrap assembly floor.** The irreducible asm: context switch, thread/TLS/stack
  setup, the entry sequence before collector + scheduler are live.
- **128.3 — Full-runtime root-scanning integration (inherited from 150).** The GC ladder proves the
  collector's marking/tracing/fingerprint and the current-stack pcsp walk hosted on the existing C
  scheduler (150.2, `selfhosted-gc.md` §9). The remaining root-scanning pieces couple to the
  scheduler/carrier machinery, so they land here:
  - **128.3.1 — Self-hosted parked-fiber walk + scheduler-root (both built).** The parked-fiber
    walk is built and oracle-checked: `rt_gc_parked_anchors` (C) hands Nomu each parked fiber's innermost
    Nomu-frame anchor as a `(sp, pc)` pair, and `rtWalkFrom` (Nomu — a copy of the current-stack walk's
    pcsp loop, parameterized by an explicit anchor; kept separate because `rtCollectRoots` must keep its
    own inline for the caller-spill constraint, `selfhosted-gc.md` §9) reads its root slots and steps
    between Nomu frames self-hosted. Recovers a parked
    worker's live set `{111, 222}` and excludes the dead object, matching the C `nomu_gc_scan_parked_fibers`
    libunwind oracle in one process (`examples/walk_parked.nomu` + `tools/walk-parked.sh`). The caller-spill
    constraint (`selfhosted-gc.md` §9) does not apply — a saved context's roots were already spilled at the
    park.
    - *Finding — crossing the C park frames stays in C for now.* The first plan (Nomu skips the park frames
      via a frame-pointer chain from the saved `ucontext`) does not work: Darwin's `swapcontext` is asm with
      no clean FP chain, so a raw FP-walk derives the wrong SP for the first Nomu frame (found it latched
      onto the right function but an SP off by 96 bytes). C frames also carry no pcsp table, so only CFI
      (`.eh_frame`/libunwind) can step out of them — the C runtime already has it. So C crosses the park
      frames and hands over a Nomu-frame anchor; the GC-relevant walk (Nomu frames) is self-hosted. A fully
      self-hosted entry needs the park to save a Nomu-frame anchor directly, which lands with the
      self-hosted context switch (**128.1**).
    - *Scheduler root (built).* `rt_sched_head` — the global scheduled-mailbox queue head, a single managed
      root that keeps every queued mailbox's pending work alive — is read self-hosted via `RawPtr.gcSchedHead()`
      (a direct load of the C global; `rtScanSchedRoot` reports it) and diffed in-process against a C oracle
      that reads the same global. The fixture sends one fire-and-forget `bump` and runs single-carrier
      (`NOMU_CARRIERS=1`, a new env knob on the carrier count) so the mailbox fiber cannot drain the head
      before `main` reads it (`examples/sched_root.nomu` + `tools/sched-root.sh`). With this, root scanning is
      complete for all three source shapes buildable now — live stack, saved/parked context, and global —
      leaving only 128.3.2 (STW-over-all-mutators integration, blocked on 128.1).
  - **128.3.2 — STW-over-all-mutators walk integration.** Drive the self-hosted walk at a real
    stop-the-world across every live mutator (each running carrier's saved safepoint context + carrier
    enumeration), standing in for the C libunwind walk the MMTk binding calls today. Needs 128.1.

## Refs

deferred.md "Self-hosting the runtime"; `runtime.md` (scheduler, safepoints, mutator);
`memory-model.md` §3 (`VMBinding`); `backend.md`; [LXR](127-lxr-collector.md),
[unsafe raw memory](125-unsafe-raw-memory.md).
