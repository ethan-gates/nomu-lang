# Buildscan — a local build history

**Avenue:** Infra · **Type/Lifecycle:** `driver reporting · tooling` · **Size:** L · **Status:** in progress
(233.1 done) · **Source:** the build report page ([193](193-compiler-performance-report.md)) shows only the last
build; the goal is a Gradle-buildscan-like history that ships inside `nomu` with no setup.

## Goal

A user builds with `nomu` and finds a page for that build and for every earlier one: status, performance and
other metadata, filterable and searchable. It is local and needs no setup: the user downloads only `nomu`. A
version that gathers builds across many users may come later.

## Today

The build writes `build/_perf/report.json`, `trace.json` and `index.html` (the report embedded in the page),
replaced by each build. A build that stops before taking the workspace's lock writes none. One build of
`bundle_plain` (24 units, 600 spans): report 53 KB, trace 80 KB, page 68 KB. The trace is derived from the
report's units and spans, and the report's totals and critical path from its units; spans are 50 KB of the
report.

## Design

- **A backend apart from the build.** The build sends one payload per build and never reads the history; the
  backend owns intake, storage and the pages. Today the send is a function call inside `nomu`; the payload is a
  versioned schema, so a later shared service can take the same payload.
- **The payload holds facts only.** The command and its arguments, package, entry module, workspace, nomu
  version, host (CPU, cores, OS), git commit, branch and whether the tree had changes, status, exit code, start
  time, wall time, the first diagnostics of a failed build; each unit's kind, name, outcome, reason, cost,
  dependencies, bytes, tokens and spans; each binary's path and size. Totals, the critical path and the trace
  are derived by the backend.
- **Intake writes a record and a summary line.** The record is loaded only when one build is opened. The
  summary line holds everything the list page shows, filters on or searches, so the list never loads records;
  the list's features decide its fields. Intake derives them from the payload. When the summary's format
  changes, the backend rebuilds the summaries from the records.
- **Files on disk, no server.** A page opened from disk cannot fetch a neighbouring file but can load a script,
  so the summaries are a script of appended lines (`H.push({...});`), one line per build, and a record is a
  script loaded on demand. A printed link works whenever it is clicked, with no process to run. A local server
  started on demand would give live progress and queries over every record, but a link printed earlier stops
  working once it shuts down; it is left for later, serving the same files.
- **A compact record.** Spans as `[stage, start, dur]` with the phase and stage names in one table: about 12 KB
  for the build above, against 200 KB written today. Plain JSON; gzip would bring it to 3–4 KB but needs
  base64 inside a script and leaves the files unreadable to tools.
- **Retention.** A window of 30 days and a size cap, whichever is reached first, pruned as each build is added.
  Expect about 1,000 builds in a window, since agents build often. Larger projects grow a record with their
  module count (500 modules: about 250 KB); tiering, keeping only summaries and per-module totals for older
  builds, if the cap proves tight.
- **Search and filters.** Filters on status, command, package, branch, workspace, nomu version, optimized, and
  a date range. Search over the summary's fields plus the modules each build recompiled or failed (a clean
  build is marked clean instead of listing every module).
- **Comparing two builds.** Module by module: time, cache outcome and recompile reason, from fields the report
  already has.
- **Where it lives.** One history per user, across every workspace and clone on the machine:
  `~/Library/Application Support/nomu/history` on macOS (the system does not clear it as it may a cache),
  `$XDG_STATE_HOME/nomu/history` or `~/.local/state/nomu/history` elsewhere, `NOMU_HISTORY_DIR` over both.
  A list per workspace would split one person's builds across every clone.

## Work

- **233.1** A minimal history, one per user: every build that writes its report adds a line to `history.js` and
  its report page under `builds/<id>.html`, under a file lock (builds in other workspaces write at the same time);
  `index.html` lists the builds, newest first, with entry module, start time, duration and a link to the build's
  page (the workspace as the entry's tooltip), and each build's page links back to the list. Thirty days and 1,000
  builds, pruned as each build is added. The build prints only the report's link; the list is reached from the
  report page. The list shows 50 builds a page (`#page=N`), and an open list page reloads `history.js` every two
  seconds while visible to show new builds. The suite's builds pass the hidden `--no-history`, as does its
  reproducibility check; the driver's tests record into a history of their own (`NOMU_HISTORY_DIR`). *Done:*
  `BuildHistory.swift`; the report gains `entry`; tested in `build_tests` (`testBuildHistory`).
- **233.2** The payload and the backend's intake: the facts above, the compact record, the summary line
  derived at intake, rebuild on a format change.
- **233.3** The list page: filters, search, a wall-time trend.
- **233.4** The build page over a record, the trace produced in the browser (a download, or opened in
  Perfetto).
- **233.5** Comparing two builds.
- **233.6** Failed builds that stop before the workspace's lock recorded too.
- **233.7** Later: the suite harness sending its runs (pass and fail per case); a local server serving the same
  files.

The filters and search wait until there is more than one workspace and branch to tell apart; today there is
one of each and the nomu version changes with every compiler build.

## Refs

`src/driver/sources/BuildHistory.swift`, `PerfReport.swift`, `ReportPage.swift`, `TraceFile.swift`,
`Timings.swift`; [193 compiler performance report](193-compiler-performance-report.md).
