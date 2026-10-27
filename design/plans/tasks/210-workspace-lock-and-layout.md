# Workspace lock and `build/` layout

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** M · **Status:** ready-to-build ·
**Source:** [172](172-incremental-build-cache.md) (the `build/` layout), [190](190-explicit-module-builds.md)
190.6 F3 and F6. A prerequisite of 172.

## Decided

- **One invocation per workspace.** A `nomu` that builds takes a lock in the workspace's `build/`. A second
  invocation waits, printing the pid holding the lock, as Bazel does; a lock whose pid is no longer running
  is taken over. This closes F3 (concurrent builds tearing reads and mixing configurations in shared
  directories). The lock covers `build`, `run` and `test`; `nomu compile` never takes it, since a build
  system such as Bazel runs many compiles at once ([192](192-bazel-friendliness.md)).
- **What `build/` shows, tentatively.** With 172, module outputs live in the store
  ([209](209-content-addressed-store.md)) and `build/` is a view of the last build. The linked binary stays a
  real file in `build/<module path>/`: its file name is its code signature's identifier and its debug map
  names the objects it was linked from. Objects and interfaces get no copies or links in `build/` at first.
  The interim `build/<configs>/` directories (198.5) go away, so `build/` shows the last configuration
  built.

Kept from the sketch in 172's doc, for when `build/` grows: hash-named files make `build/` a link farm that
each build rewrites and prunes; eviction must not remove what the last build links to; tools that need two
configurations at once use the paths a build reports.

## Work

- **210.1** The lock: take, wait with the holder's pid, take over a dead holder, release on exit and on
  signals.
- **210.2** The layout: the binary at `build/<module path>/<name>` for every configuration; outputs not yet
  in the store keep their unit directories until 172.
- **210.3** Stale layouts (F6): a file left by an older layout where the new one puts a directory, or the
  reverse, is detected, reported, and removed, instead of an opaque "File exists".
- **210.4** Tests: a second build waits and names the first's pid; a dead holder's lock is taken over; a
  stale layout is cleared.

## Refs

`build`, `linkBinary` (`src/driver/sources/Driver.swift`); `PlanOptions.outputConfig` (removed here);
`tools/escape-diff.sh`, `tools/perf-tier.py` (paths follow).
