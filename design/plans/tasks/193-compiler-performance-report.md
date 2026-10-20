# Compiler performance report

**Avenue:** Infra · **Type/Lifecycle:** `perf · needs-design` (driver reporting) · **Size:** M ·
**Status:** needs-design · **Source:** raised closing [190](190-explicit-module-builds.md) 190.6 (F9: the
timing report lost its byte and token counts when parsing moved into jobs).

## Deliverable

A compiler performance report that fits the explicit-module build: where a build's time goes across
planning, each module's job, the runtime archive and the link, and what the cache saved.

## Work

- **Format.** Today's report is one flat table per process, built when a build was one compile. Redesign it
  for a build of many jobs: per-job and per-phase totals, the planner's steps, and a form tools can read
  (as well as the terminal table).
- **Planner awareness.** Report the plan: its steps (workspaces, registry, listings, scan, resolve, plan)
  and their counts (directories listed, files scanned, modules).
- **Cache awareness.** Report which jobs compiled and which the cache served, and the time saved, for the
  per-host cache (190 D4) and the incremental cache ([172](172-incremental-build-cache.md)).
- **Inputs.** Bytes and tokens per job and in total (190's F9 restored the build-wide counts).

## Dependencies & triggers

- Depends on [172](172-incremental-build-cache.md): the cache it reports on.
- Interacts with [191](191-threaded-job-execution.md): with jobs in parallel, wall time and summed job time
  differ, and the report shows both.
