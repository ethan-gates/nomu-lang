# Threaded job execution — parallel in-process build jobs

**Avenue:** Infra · **Type/Lifecycle:** `perf · needs-design` (driver + build orchestration) · **Size:** M–L ·
**Status:** needs-design · **Source:** split from [190](190-explicit-module-builds.md) D1, which runs jobs
in-process and sequentially to start.

## Deliverable

The driver runs independent build-plan jobs in parallel on threads within one process. A job starts once
all of its dependencies finish. Output is identical to the sequential schedule.

## Why

190 makes each module one job with explicit inputs and outputs. Jobs with no path between them in the plan
can run at the same time. Threads avoid the per-job spawn and the disk round trip of a subprocess model.

## Work

- **Thread-safe job state.** Today's `compile()` is one large function with nested funcs over captured
  state. Each job needs its own state, and any state shared across jobs (interned names, type-id tables,
  the embedded sources, diagnostics) needs a defined owner and synchronization.
- **Scheduler.** A ready queue over the plan's dependency graph with a worker pool sized to the machine.
- **Deterministic output.** Diagnostics ordering, timings reports and artifacts stay identical regardless
  of completion order.
- **Tests.** The parallel schedule produces byte-identical artifacts to the sequential one across the suite.

## Dependencies & triggers

- Needs 190 (jobs, the plan, single-module `compile()`).
- Interacts with [172](172-incremental-build-cache.md): cache lookups happen per job, possibly concurrently.

## Refs

- `src/driver/sources/Driver.swift` — `compile()`, `compileModule`.
