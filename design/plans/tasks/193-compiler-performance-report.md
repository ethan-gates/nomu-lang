# Compiler performance report

**Avenue:** Infra · **Type/Lifecycle:** `perf · driver reporting` · **Size:** M · **Status:** done
(193.1–193.8) · **Source:** raised closing [190](190-explicit-module-builds.md) 190.6 (F9: the timing report lost
its byte and token counts when parsing moved into jobs); widened as the prerequisite of
[217](217-build-graph-granularity.md) 217.1, whose measurement needs per-module timings.

## Deliverable

A performance report for the explicit-module build, written as files on every build, with a one-line
summary and the report's link printed in place of today's timing table. The report answers:

1. **Per module:** where each module's compile spends its time, down to individual stages (each SSAIR pass,
   each LLVM sub-stage), with its bytes and tokens. The planner and the link are no modules and are left
   out of this view.
2. **The whole build:** each stage summed over every module (devirt's total against the other SSAIR
   passes), plus the planner's steps and counts, the runtime archive and the links.
3. **The critical path:** the longest chain of units through the plan's dependency graph, each weighed by
   what building it costs whether or not the cache served it: the build's time on unlimited cores with
   nothing cached. Beside it, the summed cost and this build's wall time.
4. **The cache:** which modules and links compiled and which the cache served, per module and as a hit rate,
   and why each one compiled (in finer detail under `--explain`).

## Today

`Timings` (`src/driver/sources/Timings.swift`) is one recorder per process. Every job's stages append to one
list of `(phase, name, seconds)`, without a start time or the job they belong to, and `report()` prints
them grouped by phase to stderr on every build. Nothing reads the table's text; tests read the build's
result (`compiled`, `cached`).

## Design

- **One recorder per job.** Each job (and the planner, the runtime archive, each link) records spans:
  phase, name, start offset from the build's start, duration. Stages timed inside the SSAIR pass pipeline
  and the LLVM bridge report through the existing stage sink and are placed by their end time less their
  duration. The build gathers the recorders at the end, so jobs running on threads (191, 217.5) record
  without sharing state. Per job, it also keeps bytes, tokens, whether the cache served it, and the
  `--explain` reason when there is one.
- **Critical path.** Longest path over the plan's job graph, each unit weighed by its cost: what building it
  takes, independent of the cache. A unit that compiled costs its own time; a cache hit costs what its
  entry's build recorded (`costs/<key>` beside the store, host bookkeeping like `checked/`, kept out of the
  action results, which hold only what the outputs determine). The key covers the compiler and every input,
  so the recorded cost is that of this exact compile. Reported with its units, its length, the summed cost
  and this build's wall time. When 217 splits each module into an interface action and an object action, the same
  computation runs over actions.
- **Terminal output.** Every build prints one line, e.g. `built app in 1.72 s · 6 modules: 1 compiled, 5
  cached · link cached`, then the path to the report's `index.html`, to open from the terminal. Today's
  table is retired.
- **The report, always on.** Every build writes `build/_perf/` (underscored, like `_external` and
  `_runtime`, so no module's output directory can take its place), replaced on every build as `build/`
  holds the last build. A build that fails before it takes the workspace's lock (a configuration or
  planning error) writes none and removes the last build's, so a tool never reads it as this build's. There is no option to turn it off: recording costs well under 0.1% of a compile, and the
  last build's report is always there to look at. Three files, each written from the build's gathered
  data:
  - `report.json` — the complete data: every span with its start and duration, per-module totals, stage
    totals, planner counts, cache outcomes and reasons, the critical path. The other two files are
    derivable from it. Read by scripts and the suite runner.
  - `index.html` — a view of `report.json`, which it embeds (a page opened from disk cannot fetch a
    neighbouring file): the summary, the module table, stage totals, the critical path and the cache
    summary. Self-contained, no network. Opens from the terminal link.
  - `trace.json` — the timeline in the Chrome trace-event format (Bazel's `--profile`, Clang's
    `-ftime-trace`): one track per job, spans nested by phase, per-job facts (cache outcome, bytes) as event
    arguments. Independent of `report.json`; it leaves out the derived summaries, which Perfetto can compute.
    Opens in Perfetto (ui.perfetto.dev) or `chrome://tracing`.

- **Tools read files.** The terminal is for people: the summary line, diagnostics, the binary's and the
  report's paths. A tool reads what a build did from `build/_perf/report.json`. `--report-jobs` (stdout lines
  read by `build_tests` and the suite runner) is retired in 193.3; `report.json` carries each module's and
  link's outcome and reason and the binaries it produced.
- **Scale (later).** Recording and the summaries grow with the span count and stay small (an estimate for
  100k modules at ~50 spans each: ~0.25 s of recording spread over every core, ~100–150 MB in memory). Writing
  every span does not: at that size `report.json` and `trace.json` reach hundreds of MB and seconds to
  write, and `index.html` must show summaries (top modules, top stages) to stay openable. Dealt with when
  builds that large exist: a summary-only default with full spans on request, a compressed trace (Bazel
  writes one on every build), or writing while the link runs.

## Work

- **193.1 — per-job recorder.** Spans with start offsets, one recorder per job, gathered by the build;
  stage-sink stages placed by end time; per-job bytes, tokens and cache outcome. The planner's steps with
  their counts (directories listed, files scanned, modules).

  **Done.** `Timings` (`Timings.swift`) is one unit's recorder of `TimedSpan`s (phase, name, start from the
  build's start, duration) with its bytes and tokens. `BuildProfile` holds a `Track` per unit — the build's
  own work, each module job, the runtime archive, each link — with its begin and end, outcome (compiled,
  cached, failed), reason, and dependencies (a module's visible dependencies; a link's modules
  and the archive), plus the planner's `PlanTimings` (exclusive step times and counts). New spans in a
  `cache` phase: key, lookup, publish, materialize, per job, archive and link. The timing table is printed
  from the profile until 193.2 retires it. The profile's data is tested through `report.json` (193.3, 193.7):
  `build_tests` drive `nomu` as a subprocess.

  Seen on the first build against an empty cache root: the toolchain identities (`Toolchain.identities`,
  which runs the system tools' version queries) took ~900 ms, about half of that build; they are cached
  under the cache root after that. 216 (the embedded toolchain) removes the queries.
- **193.2 — terminal summary.** The one-line summary and the report's path on every build; the table
  retired.

  **Done.** `BuildProfile.report(_:)` prints one line to stderr, e.g. `built app in 652 ms · 6 modules: 6
  compiled, 0 cached · linked`; `stopped after …` for a debug stop, `build failed after … · … 1 failed` on an
  error; several links read `2 links: 1 linked, 1 cached`. The timing table is gone. The report's path joins
  the summary with 193.6.
- **193.3 — report data and `report.json`.** Per-module spans and totals, stage totals over the build,
  planner, archive and link totals, cache outcome per module and link with the hit rate, `--explain`
  reasons, the binaries. `build_tests` and the suite runner read it; `--report-jobs` removed.

  **Done.** `PerfReport` (`PerfReport.swift`) writes `build/_perf/report.json` (compact, sorted keys, replaced
  by one rename): status, package, optimize, the build's start (`started`, ISO 8601) and wall time, bytes,
  tokens, module and link counts with hit rates, binaries, the planner's steps and counts, phase and stage
  totals over every unit, and per unit its kind, name, outcome, reason, start, duration, dependencies,
  bytes, tokens, phase totals and spans. Times are integer microseconds as `start` (from `started`) and
  `dur`, the Chrome trace format's complete-event form: totals are sums of `dur`, and `trace.json` maps
  across directly. Each unit's
  reason is recorded on every build. Readers moved to it: `build_tests`, the suite runner (`builtBinary`),
  `tools/perf-tier.py`; `--report-jobs` is gone. The reproducibility sweep skips `build/_perf/`, whose
  timings differ by run. `std_module_import`'s cold report is 15 KB.
- **193.4 — critical path.** Over the plan's job graph; in `report.json` with wall and summed time.

  **Done.** `PerfReport.criticalPath`: each unit's `cost` (µs; absent when no build recorded it) and
  `criticalPath` with `dur`, `units` (first to last), `setup` (the build's own work before the first unit),
  `summed` (every unit's cost), `wall` (this build, first unit's start to last unit's end) and `unrecorded`
  (units weighed by their duration for want of a recorded cost). A unit's dependencies: a module's visible
  dependencies; a link's modules and the runtime archive. On `module_link_diamond` the path is `runtime` →
  the link (~635 ms of ~925 ms summed), the same when every unit is cached (wall 8 ms). Tested in
  `build_tests` (`testReportCriticalPath`).
- **193.5 — `trace.json`.** Chrome trace events, one track per job; checked to load in Perfetto.

  **Done.** `TraceFile` (`TraceFile.swift`) writes `build/_perf/trace.json` beside `report.json`, from the same
  data: a named track per unit; on it the unit's complete event (its outcome, cost, reason, bytes, tokens,
  dependencies and whether it is on the critical path as `args`), one event per run of consecutive stages in a
  phase, and one per stage; `otherData` holds the start, status, critical path and wall time. Stages are
  placed one after another inside their unit, so every event nests (a stage reported through a `StageSink`
  as it ends lands a microsecond late). Two sources of overlap fixed on the way: the SSAIR pipeline now
  reports each post-pass verification as its own `ssair/verify` stage (it reported one sum, which no
  timeline can place), and a span's µs duration is its rounded end less its rounded start, so touching spans
  still touch. Tested in `build_tests` (`testReportTraceNests`). Loading in Perfetto is checked by hand.
- **193.6 — `index.html`.** The self-contained page over the same data.

  **Done.** `ReportPage` (`ReportPage.swift`): one page, a fixed template with `report.json` embedded and
  rendered by an inline script (light and dark, no network). The wall time as the headline, then the summary
  and the other numbers (critical path, binary size, summed cost, setup, source read); the modules, sortable by
  plan order, time or cost, critical-path modules marked, and the archive and link steps in their own table (a
  link with its binary's size, from the report's `binaryBytes`); a click opens
  a row's breakdown in a side panel (its facts and reason, then phase → stage times with bars, as the old
  timing table showed them, or for a cached module its recorded cost); the stage totals over the build, each
  phase's stages collapsed under it until its row is clicked; the
  planner's steps and counts; the critical path. Times under a second show whole milliseconds. The
  build prints the page's `file://` link under the summary line. Checked by running the page's script over a
  stand-in DOM (every panel renders) and in `build_tests` (the page embeds the report).
- **193.7 — tests.** Every build writes the three files; `report.json` lists every planned module with
  its cache outcome; a cached rebuild reports every module cached; the critical path of a chain fixture is
  the chain; the summary line's counts match the build result; the build's total time
  measured against a build with the report's writing skipped, on `std_module_import`.

  **Done.** In `build_tests`: `testReportListsEveryModule` (the three files; each module once with its
  outcome; counts agree with the units; the summary line's counts and the page's link on stderr),
  `testEarlyFailureRemovesTheLastReport`, `testReportCriticalPath`, `testReportTraceNests`, and every other
  build test reads what a build did from the report. Measured against a `nomu` with the report's writing
  removed, on `std_module_import`: a fully cached build 24.7 ms against 21.3 ms (median of 40; +3.4 ms,
  ~16%), a cold build 953.5 ms against 947.6 ms (median of 8; +5.9 ms, ~0.6%). The cost is mostly fixed per
  build, so it weighs most on a small cached build; 193.8 cut it to ~1 ms.

- **193.8 — report cost on small builds.** Find where the ~3.4 ms goes on a cached build (encoding the two
  JSON files, building the page, the writes and renames, formatter setup) and cut the fixed part.

  **Done.** Measured on a cached `std_module_import`: `JSONSerialization` for the trace ~1.4 ms, an
  `ISO8601DateFormatter`'s setup most of ~0.95 ms, three writes ~0.2 ms each, `report.json`'s encoding
  ~0.2 ms, the page ~0.15 ms. The trace is now `Codable` events through `JSONEncoder`, like the report; the
  start time is formatted from `gmtime_r`; files are written with `open`/`write`/`rename`. The report now
  costs ~1 ms on a cached build (22.7 ms against 21.7 ms, median of 40), from ~3.4 ms.

## Dependencies & triggers

- Depends on [172](172-incremental-build-cache.md): the cache it reports on (done).
- Prerequisite of [217](217-build-graph-granularity.md) 217.1 (its per-module measurement).
- Interacts with [191](191-threaded-job-execution.md) and 217.5: with jobs in parallel, wall time and summed
  job time differ, and the trace shows the overlap.
