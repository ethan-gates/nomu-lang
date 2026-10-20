# Retire MMTk and the C scheduler

**Avenue:** Risk · **Type/Lifecycle:** `runtime · infra · ready-to-build` · **Size:** M–L ·
**Status:** done — 197.1–197.6 · **Source:** the decision to drop the GenImmix-vs-MMTk benchmark and benchmark
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

## Built

- **197.1 — done.** The Nomu runtime became the default ahead of the deletion. Suite before/after: 69.1 s → 72.2 s
  wall, user CPU 108 s → 101 s, summed run time 255 s both ways; no case slowed outside load noise
  (`scheduler-tls` swings 20–55 s in the parallel run but is 0.03 s alone on either runtime).
- **197.2 — done.**
  - **Allocation stress on the Nomu collector.** `NOMU_GC_STRESS=<bytes>` now means a collection every N
    bytes a carrier allocates. Under it the TLAB's inline limit stays 0 (the hole end moves to a new
    TLAB word), so every allocation reaches `rtTlabAlloc`, which counts bytes and requests a collection at
    the allocation's anchor: a minor, or a major when `NOMU_MATURE_FLOOR` says mature headroom is short
    (`rtGenCollect`, shared with the nursery-full trigger).
  - **A scheduler bug the stress knob found.** `rtSchedStwParkCarrier` waited for the request flag (+136)
    to clear. A carrier still waking from one stop could see the next stop's request already set, keep
    waiting without acking it, and the coordinator (which reset the ack count at resume) waited forever.
    It now reads the stw generation (+152) before acking and waits for it to change.
  - **Suite legs.** `-evac` legs run `NOMU_GC_STRESS` on the Nomu collector and assert a collection fired;
    plain legs run with no knob; redundant selector knobs are gone. 14 `-evac` legs whose fixtures do
    almost no managed allocation were retired: they never collected under MMTk either (MMTk's stats
    reported no GC), so each duplicated its plain leg. The `-self` duplicates of `immix-alloc`,
    `immix-los` and `selfhost-alloc` were retired. `gc-gen-self` (an MMTk small-heap leg) became
    `gc-gen-evac` on a one-block nursery.
  - **Tail scripts ported.** `gc-actor`, `gc-oom`, `gen-multicarrier`, `mark-verify`, `walk-mark`,
    `walk-multiframe`, `stw-selfhost` and `escape` became suite cases (with fixed expectations in place of
    their MMTk/C oracles); the T6 inlined-loop safepoint check became `stw-inlined-loop` under
    `NOMU_STW_SELFHOST`.
  - **Shape matrix.** `run.sh` legs: default, a 64-block nursery, stress-minor, stress-major.
- **197.3 — done.** Deleted: `src/runtime/gcbinding/` (Rust/MMTk), `src/runtime/gcembed/`, `rules_rust` and
  the MMTk crates in `MODULE.bazel` and `.bazelrc`, the `nomu` binary's embedded archive and the driver's
  extraction/link of it, and in `runtime.c` the C scheduler, timer heap, kqueue poller, C actor mailbox,
  libunwind root walker, C STW handshake, the C GC smokes and the runtime selector. Removed intrinsics:
  `gcForceCollect`, `gcParkedAnchors`, `gcSchedHead` (with `rtScanParkedFibers` / `rtScanSchedRoot`).
  Retired examples and scripts that only exercised the C scheduler or MMTk: `sched_root`, `walk_parked`,
  `mark_verify_oracle`, `gc_smoke`, `gc_smoke_parked`, `gc_smoke_stw`, and `gc-smoke*.sh`,
  `gc-t6-stw.sh`, `sched-integration.sh`, `selfhost-gc.sh`, `gc-corpus-matrix.sh`,
  `gc-actor-teardown.sh`, `mark-verify-oracle.sh`. The write-barrier globals moved to `runtime.c`; the
  allocation seam forwards to `__nomu_selfhost_alloc`, and `NOMU_NO_INLINE_ALLOC` now disables its inline
  TLAB bump. A program binary went from about 3 MB to 190 KB (`escape_nonleaf`).
- **197.4 — done.** The horizon, task index, `selfhosted-gc.md`, `selfhosted-scheduler.md`, `runtime.md`,
  `memory-model.md`, `c-types.md`, `shaped-roots.md`, `tests/README.md`, `tools/README.md` and specs 128,
  150, 157, 158, 159 and 176 say the Nomu runtime is the only runtime; build logs that name MMTk oracles
  stay as history.
- **197.5 — done: the stale tool scripts.** Seven scripts called `nomuc` and single-file example paths that no
  longer existed (true before 197).
  - **Fixed:** `escape-diff.sh` (the corpus differential, escape analysis on vs off: 85 examples identical;
    runs on one carrier, since multi-carrier `print` interleaving made `gc_actor` differ run to run) and
    `perf-tier.py` (the optimizer-pass perf matrix).
  - **Folded into the suite:** `subset.sh` (`subset-bad-call` adds the second expected error) and
    `subset-poll.sh` (`subset-poll` asserts runtime-subset code references no `__nomu_gc_poll_slow`;
    `escape-stack` is the control). This adds `object_references` (`nm -u`) to the manifest schema.
  - **Retired:** `mark-types.sh` with `examples/mark_types` and the `NOMU_GC_TYPEMAPS` dump (the dump printed
    shaped descriptors as flat offsets, and every collecting case reads the tables), `stackmap-probe.sh`
    with `examples/stackmap_probe` (an early bring-up step; every collecting case walks stackmaps through
    the frame index), and `ir-golden.sh` (task 156 replaces it).
- **197.6 — done: I/O readiness on the Nomu scheduler.** The C kqueue poller left with the C scheduler, and
  `readLine` was unusable from source (its builtin returned a legacy `String` type that did not bind to the
  prelude `String`). Now:
  - **Surface.** `readLine()` lowers like a string literal: the runtime's `StringBase` wrapped into the
    surface `String` (`NOIRGen`); the stale prototype is gone.
  - **Lines.** `rt_read_line` reads stdin through one buffer and returns one line per call without its
    newline; at end of input, the unterminated remainder, then empty strings. (The old C version returned
    whatever one `read(2)` produced.)
  - **Parking.** With no line buffered and stdin not readable (`poll(2)`), the fiber joins a stdin waiter
    list and parks (`nomuSchedParkLocked`, the `nomuSchedSleep` lock handoff); a poller thread started on
    first use blocks in `kevent(2)` on one shared one-shot read event and unparks every waiter
    (`rtSchedUnpark`). One shared registration fixes a bug the C poller had: kqueue keys events by
    (fd, filter), so arming per fiber overwrote the earlier waiter's wake-up.
  - **Suite.** `stdin_file` / `stdin_delay_ms` feed a case's stdin late. `read-line` (a ticker fiber runs
    while `main` waits, on 1 and 4 carriers; line splitting; end of input), `read-line-readers` (three
    concurrent readers), `read-line-gc` (stress collections while `main` is parked holding heap values).
  - **Harness fd leak.** `posix_spawn` children inherited every open fd of the harness, including the pipe
    ends of cases running alongside, so a case's output readers (and a fed stdin's end of input) waited on
    unrelated processes. `POSIX_SPAWN_CLOEXEC_DEFAULT` closes them. The suite went from 97 s to 55 s
    (`stw-collect` 60 s → 12 s); the per-case swings 197.1 put down to load were this leak.
  - **Scope.** stdin only (readLine's one source); general fd readiness (sockets, files) belongs with the
    I/O stdlib.

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
