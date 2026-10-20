# Retire MMTk and the C scheduler

**Avenue:** Risk · **Type/Lifecycle:** `runtime · infra · ready-to-build` · **Size:** M–L ·
**Status:** ready-to-build · **Source:** the decision to drop the GenImmix-vs-MMTk benchmark and benchmark
against Go and Swift instead, raised while [176](176-shaped-gc-roots.md) 176.5 found MMTk-only bugs.

## Deliverable

One runtime: the Nomu scheduler and the Nomu collector, written in Nomu. MMTk, the Rust GC binding and the C
scheduler are deleted, along with the oracle overrides that selected them. The suite runs on the Nomu runtime
only, with collection-forcing legs that exercise it.

## Why

- **The benchmark it was kept for no longer exists.** MMTk was to stay live until a GenImmix-vs-MMTk
  benchmark confirmed the self-hosted collector, then retire. Retirement is decided regardless of that
  result, so the benchmark would only measure distance. The benchmarks that decide anything compare Nomu
  with Go and Swift, once the language is complete.
- **Two runtimes double the work and the thinking.** Every GC change has an MMTk side (the lockstep duty in
  176.5.3, 176.5.6's shadow-stack walk), every test names a collector, and every bug starts with "which
  runtime". 176.5 found MMTk-only bugs that cost work and protected nothing the Nomu runtime ships.
- **No path needs a non-Nomu runtime back.** A runtime component the Nomu compiler cannot make fast enough
  can drop to a C or assembly leaf; nothing requires a second scheduler or collector. The last commit with
  MMTk stays in history (worth tagging) if that judgment proves wrong.

## Current state

- **The Nomu runtime already passes the C-only suite.** All 111 suite cases with an expected stdout that run
  only on the C scheduler and MMTk pass under `NOMU_RUNTIME=selfhost` unchanged: actors, timers, the
  poller, TLS, locks, multi-carrier, fibers, futex, atomics, the module and generic cases.
- **Collection knobs that are MMTk's own** do nothing on the Nomu runtime, so cases using them pass there
  without collecting: `NOMU_GC_STRESS` (27 cases), `NOMU_GC_HEAP` (1), `NOMU_GC_PLAN=immix`/`genimmix`
  (most of the 82 `NOMU_GC_PLAN` uses). The Nomu collector's own knobs are `NOMU_GC_PRESSURE`,
  `NOMU_GC_TRIGGER_RESERVE`, `NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_STW_COLLECT`.
- **MMTk-side oracles:** the mark-verify fingerprint (`NOMU_GC_MARKVERIFY`, `MMTK-FP`, `mv_obj_hash`) and
  the `-evac` legs that diff against MMTk Immix.
- **Pieces:** `src/runtime/gcbinding/` (Rust, MMTk binding), `src/runtime/gcembed/` (embeds the archive in
  `nomuc`), the `rules_rust`/`crate_universe` MMTk setup in `MODULE.bazel`, the C scheduler and its
  carrier/fiber code in `src/runtime/embedded/runtime.c`, the runtime selector in `main` (including the
  scheduler/collector pairing guard), and the driver's archive extraction and link.
- **Shared, kept:** the GC descriptor format and its C accessors (`nomu_gc_live_offsets` and the
  `nomu_gc_type*` functions) that the Nomu collector reads, `rt_alloc`'s self-hosted path, the write
  barrier's self-hosted path.

## Phases

- **197.1 — the Nomu runtime is the default.** `NOMU_RUNTIME` unset means the Nomu scheduler and collector;
  the suite's default cases run there. Measure compile and run time of the suite before and after.
- **197.2 — suite legs that collect.** Every case that set an MMTk knob gets a Nomu-collector leg that
  actually collects (pressure, nursery reserve, forced evacuation), replacing `NOMU_GC_STRESS` and the
  `immix`/`genimmix` plans; the `-evac` oracles keep their captured golden values. A case whose purpose was
  an MMTk mechanism (the MMTk-only `immix_*` probes, the fingerprint diff) is retired or rewritten against the
  Nomu collector. The shape matrix's GenImmix leg moves to a Nomu collector leg.
- **197.3 — delete.** The Rust binding, `gcembed`, the MMTk crates and Rust toolchain in `MODULE.bazel`, the
  C scheduler and fiber code, the selector and pairing guard, the driver's archive handling, and the oracle
  overrides (`NOMU_SCHED`, `NOMU_GC_PLAN` except a NoGC mode if it is still useful, `NOMU_GC_STRESS`,
  `NOMU_GC_HEAP`, `NOMU_GC_MARKVERIFY`). Check that nothing else links them.
- **197.4 — docs.** The horizon, `selfhosted-gc.md`, `selfhosted-scheduler.md`, `runtime.md`, and the task
  specs that name MMTk as the reference or the benchmark baseline ([150](150-selfhosted-gc-ladder.md),
  [128](128-self-hosting-runtime.md), [157](157-env-var-audit.md), [158](158-gc-packaging.md),
  [176](176-shaped-gc-roots.md) 176.5.6) say the Nomu runtime is the only runtime. MMTk-only findings in
  176.5 close as moot.

## Risks

- **The differential oracle goes.** Bugs shared by the compiler and the Nomu runtime lose their
  cross-check. [159](159-gc-observability.md)'s correctness matrix (collections proven to run, across
  features and pipelines) and the 176.5 shape matrix carry that role.
- **Build and suite time.** The Nomu runtime is compiled into each program; measure the suite before and
  after 197.1 so a slowdown is seen, not guessed.

## Dependencies & triggers

- First in the horizon order: the rest of [176](176-shaped-gc-roots.md) 176.5 is built and tested against one
  runtime. 176.5.6 reduces to the Nomu runtime, where `xmod_erased` already passes.
- Replaces the GenImmix-vs-MMTk benchmark step of [150](150-selfhosted-gc-ladder.md); the benchmark against
  Go and Swift comes when the language is complete.
