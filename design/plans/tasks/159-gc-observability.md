# GC observability — one model for every collector: intervals, cycles, counters, heap snapshots

**Avenue:** Risk · **Type/Lifecycle:** `runtime · observability · needs-design` · **Size:** M ·
**Status:** built (159.1–159.6) ·
**Source:** grounded during 150.4.5.3 — debugging a minor-collector segfault and an STW deadlock, the only
signal was a single per-collection line and a native backtrace that could not unwind the collector's carrier
stack (frame #0 only). Ad-hoc `RawPtr.gcDbg` breadcrumbs localized both bugs, then were stripped.

Give the collector an observability surface designed once for every collector Nomu builds, for compiler
development: enough to debug a fault without hand-adding prints, to explain a footprint number, to tune the
collector, and to compare GenImmix with LXR on the same metrics. It is off unless a build turns it on.
Only GenImmix is instrumented here; LXR fills the same model when [127](127-lxr-collector.md) builds it.

## Why now

The collector runs on a carrier stack the native unwinder cannot walk, so a fault yields only frame #0. The
existing signal is thin: with `NOMU_GC_DEBUG_PRESSURE`, one `nomu-gc-sync: collection N (kind), R roots,
avail -> A, …` line per collection from the coordinator (`rt_gc_sync_thread`, `runtime.c`), and two debug
counters (`rt_dbg_last_drain`, `rt_dbg_barrier_slow`). During 150.4.5.3 that was not enough to see a
promotion-queue overflow (needed the promoted count) or an STW deadlock (needed to know which root-source
phase was live). The suite proves collections ran by counting that stderr line (`stderr_match`, `gc_log`).
MMTk's footprint report (`NOMU_GC_STATS`) went with MMTk ([197](197-retire-mmtk-and-c-scheduler.md)).

## The collectors it covers

Two shapes cover every collector on the plan.

- **Stop-the-world tracing:** GenImmix, non-generational Immix, mark-sweep ([158](158-gc-packaging.md) groups
  them on one STW coordinator). All collector work runs inside a pause; one collection is one pause; memory
  is reclaimed within it.
- **LXR** (Zhao, Blackburn, McKinley, PLDI 2022): deferred, coalesced reference counting through a
  field-logging write barrier; short STW pauses (RC epochs) apply increments and evacuate young survivors;
  decrements are processed concurrently after the pause, so memory is reclaimed incrementally while the
  mutator runs; a concurrent snapshot-at-the-beginning trace, spanning many epochs, collects cycles and
  picks mature blocks to defragment. Immix blocks and lines back it.

| | GenImmix | LXR |
|---|---|---|
| collector work runs | in pauses | in pauses and on concurrent threads |
| a collection | one pause | an RC epoch; separately, a trace over many epochs |
| reclamation | within the pause | incremental, while the mutator runs |
| mutator-side cost | remembered-set barrier | field-logging barrier, buffer flushes |
| heap layout | Immix spaces | Immix blocks and lines |

The model below is LXR's shape. GenImmix is its special case: every interval in a pause, one cycle per pause.

## Design

1. **Intervals.** Each piece of collector work is an interval: thread, phase name, start, duration, and
   whether it ran in a pause or concurrently. A pause is itself an interval on the coordinator, from the stop
   request to the world resuming, with time-to-safepoint (request to the last carrier's acknowledgement) as
   its first child. Phases nest inside it (root sources, remembered-set drain, evacuation, scan, sweep,
   reclaim; for LXR, increment and decrement processing, the SATB trace).
2. **Cycles.** A cycle is one logical collection: its kind (minor, major, defrag; for LXR, RC epoch or
   backup trace), its trigger source (from [158](158-gc-packaging.md)'s request), and the intervals it
   spans. GenImmix: one cycle, one pause. LXR: a backup trace's cycle spans many pauses and concurrent
   intervals.
3. **Counters.** A shared core every plan fills: roots scanned, bytes and objects allocated, reclaimed,
   evacuated; barrier slow-path calls. A per-plan extension: GenImmix's objects promoted, remembered-set
   entries drained, nursery occupancy before and after, mature availability, queue high-water; LXR's
   increments, decrements, buffer flushes (filled when LXR is built).
4. **Heap snapshots.** Per-space occupancy (nursery, mature Immix, large objects) and a block-state
   histogram, taken at cycle boundaries. Shared by both plans through the Immix backing; the seed for
   [139](139-memory-heap-introspection.md).
5. **Derived metrics, plan-neutral.** Computed from intervals and snapshots alone, so the GenImmix–LXR
   comparison reads neither plan's internals: pause distribution (count, p50, p99, max), minimum mutator
   utilization over window sizes, total GC CPU time (concurrent threads included), peak footprint, mutator
   time.
6. **Recording.** One recorder: a buffer per thread, written without locks, a timestamp and a few words per
   interval. Concurrent collector threads (LXR) register like any other. A writer fills a record before
   advancing its buffer's index, and every buffer is reachable from one global registry, so a reader that
   interrupts a writer sees only whole records. That lets [219](219-runtime-fault-handling.md)'s fault
   handler print each thread's last open interval as a phase breadcrumb, the durable form of the stripped
   `gcDbg` scaffold.
7. **Output.** Following [193](193-compiler-performance-report.md): one report file holding everything
   recorded and the derived metrics (what tools and the suite read), and a Chrome trace-event view of it,
   where collector intervals sit on their threads beside the carriers in Perfetto.
8. **Tests prove collections ran.** Every suite case that tests GC behavior asserts, from the report, that
   cycles of the kinds it targets (nursery, mature, evacuating) ran, with a minimum count. Today a GC case can
   pass with no collection at all: under default heap sizing the 176.5 reproduction never collects, and the
   shaped oracles use evacuation only, so they cannot see a missed reload.

## Open questions

1. **Gating.** Decided: off by default in every configuration, and compiled out when off. Its audience is
   compiler development, checking and tuning the collector's performance; observability for users' memory
   debugging is later work ([139](139-memory-heap-introspection.md)). The compile setting `gc.record`
   (one value per program) turns it on: `off` (the default), `limited` (intervals, cycles, counters kept on
   slow paths such as TLAB refill and large-object allocation, heap snapshots) or `full` (adds counters on
   the allocation fast path, which slows allocation). Suite cases that assert on collections select
   `limited` through their compile settings (159.5).
2. **Where a program writes its report.** Decided: `<binary>-gc-<time>.json`, named for the program, what
   the file is and when it ran, so runs never overwrite each other, with the trace view beside it as
   `<binary>-gc-<time>.trace.json`. `<time>` is the recorder's creation in UTC, ISO basic with milliseconds
   (`20261029T120405.123Z`). They go in the executable's directory by default; `NOMU_GC_REPORT_DIR` names
   another directory (its name to settle under [157](157-env-var-audit.md)), and the file name stays the
   runtime's. The runtime writes them when the scheduler has stopped (the end of `nomuSchedBoot`, after
   every carrier has exited, so no collection is running) and prints `nomu-gc: report <path>` on stderr. A
   program that ends another way (a trap, `exit`) writes no report.
3. **Clock.** Decided: `mach_absolute_time` on Darwin, the fastest ordered read measured (5 ns; 159.1),
   recording raw ticks and converting with `mach_timebase_info` when the report is written. Every target so
   far is darwin-arm64; Linux's clock is listed in [218](218-linux-support.md).
4. **Where the recorder lives.** Decided: in the Nomu runtime (runtime subset, [149](149-runtime-subset.md)),
   beside the collector's phases. The C coordinator records its handshake through exported Nomu functions, as
   it already calls `nomu_fn_*`; the goal is less C.
## Work

- **159.1** Inventory and cost: list today's signals; measure a timestamp plus a buffer write per interval and
  the length of today's pauses; settle open questions 1, 3 and 4.

  **Done.** Inventory: the coordinator's `nomu-gc-sync: collection N (kind), roots, avail, remembered, barrier slow
  calls` line under `NOMU_GC_DEBUG_PRESSURE` (the pressure poller and the two smoke drivers print their
  own); two C debug counters (`rt_dbg_last_drain`, `rt_dbg_barrier_slow`); 34 suite cases set `gc_log` and
  26 assert the collection line with a minimum count, plus `require_collections` on variants. A
  collection's phases are all in `runtime/collect.nomu` (minor: stack slots, remembered set, large-object space,
  Cheney scan, unmark and unlog, nursery reclaim; major: slot walk, then defrag); the pause handshake is in
  `runtime.c`.

  Cost on Apple arm64: `clock_gettime(CLOCK_MONOTONIC)` 18.3 ns,
  `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` 8.6 ns (`RawPtr.monotonicNanos` uses `clock_gettime_nsec_np`), `mach_absolute_time` 5.0 ns, `cntvct_el0` with `isb`
  8.0 ns (24 MHz ticks, 41.7 ns each); one interval record into a per-thread buffer (two clock reads, four
  words) 8.5 ns. With recording off by default, its cost is measured with the real recorder in 159.3
  instead of a temporary patch now.
- **159.2** The recorder: per-thread buffers, intervals, cycles, counters (shared core and the plan
  extension slot), heap snapshots.

  **Done.** `gc.record` (`off | limited | full`, compile, program granularity) reaches every module, the
  language workspace's included, and its cache keys. Two intrinsics: `RawPtr.gcRecordLevel()` folds to the
  setting's level (0, 1, 2) in sema, so recording code sits under a constant branch (`br i1 false` when
  off, removed by the optimizer; the runtime module compiles under `release`); `RawPtr.ticks()` reads
  `mach_absolute_time`. The recorder (`runtime/gcreport.nomu`) is one per recording
  thread, written without locks: chunks of 1024 48-byte records off the GC heap that never move, each
  record written whole before the counts advance; records are intervals (`rtRecOpen`/`rtRecClose`, nesting,
  pause or concurrent), cycles (`rtRecCycleBegin`/`rtRecCycleEnd`, numbering the intervals inside) and
  counters (`rtRecCounter`; heap snapshots are runs of them); `rtRecCount`/`rtRecAt` read them back;
  `rtRecOpenPhase` is the innermost open phase, the fault breadcrumb (six deep). The Immix space holds
  the coordinator's recorder at @152, null when off. Ids for phases, cycle kinds, triggers and counters
  are numbered in 159.3, where they are recorded. Tests: `gc-record` (the space's recorder; nesting,
  cycle numbers, the breadcrumb, records across chunks) and `gc-record-off` (the slot stays null).
- **159.3** GenImmix instrumented: the pause and time-to-safepoint, its phases, its counters, a snapshot at
  each cycle boundary; the recorder's cost per pause and per allocation measured at both levels.

  **Done** at `limited`. The collector calls hooks (`rtGcRecordRequest`, `rtGcRecordEntry`/`Exit`,
  `rtGcPhaseOpen`/`Close`, `rtGcCounter`, `rtGcRecordRefill`, `rtGcRecordLargeObject`), each empty unless
  `gc.record` is on; in a normal build with it off the release-built runtime has no call to any of them
  (checked in the disassembly; the recorder's own bodies stay in the binary, exported and uncalled). The
  ids are listed above the hooks in `runtime/gcreport.nomu`: cycle kinds (minor, major, forced), triggers (external
  driver, nursery full, mature floor, heap exhausted, allocation stress), 18 phases (time to safepoint,
  root walk, remembered-set drain, the minor's six, the major's seven, snapshot, collect) and counters
  (roots, promoted, remembered entries, defrag sources; a snapshot of blocks by state, large objects and
  heap blocks; blocks refilled and large objects allocated since the last cycle). The mutator that raises a
  collection records its trigger and time under the scheduler lock (`rtSelfhostOom`, `rtSelfhostMinorGc`
  and `rtGenCollect` now take the trigger); the coordinator's collector entry begins the cycle at that
  request, so time to safepoint is the request to the entry with every carrier stopped. Not recorded: the
  pause's tail after the collector returns (TLAB and mod-buffer resets, the wake), which is the C
  coordinator's and moves with [158](158-gc-packaging.md); the `full` level's fast-path counters.

  Cost (`gen_minor`, one-block nursery, 391 minors, release, best and median of 40): the first snapshot
  scanned all 8192 block states per snapshot, two snapshots per cycle, adding ~18 µs per cycle (+5%);
  reading only blocks below the never-used cursor brought it to ~0.5 ms over the run, ~1.5 µs per cycle,
  within run-to-run noise. Tests: `gc-record-minor`, `gc-record-major`, `gc-record-stress` read the space's
  recorder after real collections and check each cycle's phases, counters, trigger, and that every interval
  lies inside its cycle.
- **159.4** Output: the report file and its trace view; the derived metrics; open question 2.

  **Done.** Written in Nomu (`runtime/gcreport.nomu`, "The collector's report") over raw buffers, since the runtime
  subset calls no `String` method. Seven runtime-only intrinsics carry it: `RawPtr.wallNanos`,
  `RawPtr.timebase(info:)`, `RawPtr.getenv(name:)`, `RawPtr.executablePath(buf:size:)`,
  `RawPtr.createFile(path:mode:)`, `RawPtr.closeFd(fd:)`, and `RawPtr.copyLiteral(to:_:)`, which copies a
  string literal's bytes (the argument must be a literal). The report holds `version`, `binary`, `started`,
  `record` (the level), `dur`, `names` (every id by table: kinds, triggers, phases, counters), `cycles`
  (each with `n`, `kind`, `trigger`, `start`, `dur`, its phases as `[phase, start, dur, concurrent]` and
  its counters as `[counter, at, value]`) and `metrics`: cycle count, GC and mutator time, the pause
  distribution (p50, p90, p99, max), time to safepoint (p50, p99, max), minimum mutator utilization over
  1 ms to 1 s windows (those that fit the run), and the heap's peak blocks and bytes in use and peak large
  objects. Times are integer µs from the recorder's creation. The trace view puts the collector on one
  track, each cycle an event named for its kind with its phases nested, the counters as counter tracks.
  With recording off, the exit hook leaves no call (checked in the disassembly). Tests: the three
  cycle cases check the `nomu-gc: report` line; 159.5 reads the report itself.

  First reading (`gen_minor`, eight-block nursery, 48 minors): pauses p50 362 µs; of the first minor's
  1.1 ms collect, ~0.9 ms falls between the root walk and the remembered-set drain, where
  `nomuSchedStwCollectMinor` allocates its 8 MiB remembered-set buffer, which `rt_raw_alloc` zero-fills, on
  every minor ([221](221-minor-remembered-set-buffer.md)).
- **159.5** Tests prove collections ran: suite cases turn recording on and assert cycle counts by kind from
  the report; the collection-line pattern and `gc_log` retire.

  **Done.** A case or dimension value asserts `collections: [ { "kind": "minor", "min": 10 } ]` (any kind
  when `kind` is absent); the runner compiles it with `gc_record`, runs it with `NOMU_GC_REPORT_DIR` set to
  a directory of its own, and counts the report's cycles by kind name. All 41 collection checks moved:
  the 26 `nomu-gc-sync: collection` lines, the `(minor)`/`(major)` counts, the five pressure-driver lines,
  the three report-line checks, and the `gc` dimension's `require_collections`, which is retired with
  `gc_log`. The runtime's collection log is gone: the `nomu-gc-sync` and `nomu-gc-pressure` lines, the
  `NOMU_GC_DEBUG_PRESSURE` switch, and the two debug counters that fed the line (`rt_dbg_last_drain`, and
  `rt_dbg_barrier_slow`, an atomic add on every barrier slow path). Writing the report read records with a
  walk from the first chunk per record, quadratic over the stress cases' thousands of cycles (the fast
  suite went from 45 s to 89 s); the writer now indexes chunks directly (`rtRecChunks`/`rtRecIn`), and the
  fast suite runs in 49 s. Fast tier 326 passed, full tier 737 passed.
- **159.6** The `full` level: counters on the allocation fast path. `gc.record: full` is accepted and folds
  to 2, and the report names it, but it records what `limited` records. 159.3 asked for both levels and
  built only `limited`; this phase is the rest.

  **What it adds.** Objects and bytes allocated, counted per carrier on every allocation, added to each
  cycle's counters (since the last cycle) and to the report's metrics.

  **Why it is worth doing before LXR.** `limited` sees allocation only per block handed to a TLAB (32 KiB
  grain) and per large object, and counts promotions in objects with no allocation count beside them. So
  it cannot give GenImmix's survival rate (promoted over allocated, in objects or bytes), the allocation
  rate between cycles at object grain, or the mean object size. Those decide nursery sizing and the
  promotion policy now, and they are the mutator-side numbers the GenImmix–LXR comparison needs as well.
  Do it soon after 223.2.

  **What it touches.**
  - The allocation bump is generated into user code (`opt.inline_alloc`, `LLVMGenRuntime.swift`), so the
    counting is emitted by `llvmgen` when the program's level is 2: the egress needs the level, as it
    carries `inlineAlloc` today. The runtime's own path (`rtTlabAlloc`, `rtLosAlloc`) counts under the
    same constant.
  - The counts live per carrier in the TLAB (`allocObjects` and `allocBytes`, laid out by
    [223](223-retire-the-c-floor.md).2), so the bump stays lock-free; the coordinator sums the registered TLABs at each cycle's entry,
    walking 223.2's registry in Nomu.
  - Promoted bytes beside promoted objects, so survival can be read in bytes as well.
  - Cost measured at `full` against `limited` and `off`, on an allocation-bound program: this is the level
    that slows allocation, so the report should state by how much.

  **Depends on** [223](223-retire-the-c-floor.md).2: the TLABs move into Nomu first, with the counting fields in their
  layout and a registry the sum can walk. 158 reshapes the coordinator where the per-cycle sum is
  taken; doing 159.6 before 158 means moving that sum when 158 lands.

  **Built.**
  - Codegen counts on the inline hit path when the program's level is `full` (`LLVMGen.countsAllocations`,
    from `gc.record` through `emitObject`): one more object at the carrier record's +48 and the rounded
    size at +56, plain stores since only the owning carrier writes them. `rtTlabAlloc` counts every
    allocation it returns, small or large (`rtCountAllocation`), so the miss path, stress mode, and the
    large-object space are covered without double counting.
  - At each cycle's entry the collector sums and zeroes every carrier's counts (`rtCarriersAllocCounts`,
    over the carrier registry, with the world stopped) and records counters 33 (objects allocated) and 34
    (bytes allocated). Minor collections record counter 5 (bytes promoted) beside 2 at any level.
  - The report's metrics gain `promotion` (objects, bytes) at any level and, at `full`, `allocation`:
    objects, bytes, `meanObjectBytes`, and `minorSurvival` (promoted bytes over the bytes allocated since
    the previous cycle, summed over minors). The totals include the allocation after the last cycle,
    read at exit.
  - Checked by hand on `gc_record_full` (200,000 16-byte objects plus an array and its nine buffer
    growths): 200,009 objects and 3,204,216 bytes, the same with every allocation forced through the slow
    path (`NOMU_GC_STRESS`); mean 16.02 bytes.
  - **Cost**, release builds, 30 runs each: `alloc_live` 108.9 ms off, 109.7 ms `limited` (+0.7%), 130.9 ms
    `full` (+20%); `micro_alloc` is startup-bound (7.0 / 7.2 / 7.2 ms). `full` is the level that slows
    allocation, by about a fifth on an allocation-bound loop.
  - Tests: the suite checks the report's shape through a new manifest key, `report_metrics` (values under
    `metrics` by path: exact, a range, or absent). `gc-record-full` (carriers 1 and 4, a 4-block nursery)
    pins `allocation.objects` 200,009 and `allocation.bytes` 3,204,216 exactly, with ranges on promotion
    and survival; `gc-record-full-stress` pins the same totals with every allocation on the slow path;
    `gc-record-limited-shape` checks `allocation` is absent at `limited`. Removing the slow path's count
    fails both `full` cases (199,911 and 0 objects). The runner keeps `full` when a case also asserts
    collections (the `gc_record` config it adds would otherwise win).
  - Off costs nothing by construction: the counting is emitted only at `full`, and the runtime's guards fold
    (`Runtime.gcRecordLevel()` is a constant). Checked once on `alloc_live`: at `off` the generated code's
    instruction sequence is identical to `limited`'s, and `rtTlabAlloc` never touches the counters. The rule
    is written in `src/stdlib/runtime/README.md`.
    The full tier (758 passed), `--check-reproducible` (1741 identical), the 18 Bazel test targets.

Deterministic GC tests (suite cases that pass or fail by thread timing) moved to
[158](158-gc-packaging.md), whose trigger protocol their fixes go through. 159 comes first, so 158's
coordinator work is debugged with its intervals; the pause interval in `rt_gc_sync_thread`
moves when 158 reshapes the coordinator.

## Non-goals

- The collector packaging itself ([158](158-gc-packaging.md)): this observes plans; 158 structures them. The
  trigger source a cycle records comes from 158's request.
- LXR's instrumentation: its counters fill the extension slot when 127 builds it.
- Fault handling ([219](219-runtime-fault-handling.md)): the runtime has no signal handler yet; 219 adds one
  and prints the recorder's breadcrumbs from it.
- General program heap introspection ([139](139-memory-heap-introspection.md)): this is collector-internal,
  though its heap snapshots seed what 139 would surface to users.

## Refs

`rt_gc_sync_thread`, `rt_gc_pressure_thread`, `rt_dbg_last_drain`, `rt_dbg_barrier_slow`
(`src/runtime/embedded/runtime.c`); `nomuSchedStwCollectMinor`, `nomuSchedStwCollectDefrag`
(`src/stdlib/runtime/`); `collectionLogPattern` (`src/compiler-test/sources/Manifest.swift`).
[158 GC packaging](158-gc-packaging.md), [150 GC ladder](150-selfhosted-gc-ladder.md),
[127 LXR](127-lxr-collector.md), [193 compiler performance report](193-compiler-performance-report.md),
[157 env-var audit](157-env-var-audit.md), [155 integration-suite harness](155-integration-suite-harness.md),
[139 memory/heap introspection](139-memory-heap-introspection.md).
