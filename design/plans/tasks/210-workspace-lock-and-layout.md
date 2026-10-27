# Workspace lock and `build/` layout

**Avenue:** Infra · **Type/Lifecycle:** `driver · done` · **Size:** M · **Status:** done ·
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

## Two shapes of repository

- **A Nomu source repository** follows Bazel: one workspace root, one building invocation at a time. Many
  targets go to one `nomu build` ([211](211-multi-root-builds.md)) and compile in parallel under the driver's
  scheduler ([191](191-threaded-job-execution.md)); many test targets go to one `nomu test`, run in parallel with
  scheduling aware of resource use, so test lanes are not starved (not yet a task).
- **The compiler repository** holds Nomu sources too: the suite's fixtures, all in the one project workspace.
  Its long-term test shape (Bazel-run unit tests, `swift_test`) is [213](213-compiler-unit-tests.md)'s. Until
  `nomu build` and `nomu test` run work in parallel, the suite runner builds in per-lane copies of the workspace
  (`WorkspaceLanes`), each with its own lock and sharing the host cache, which keeps its compile phase parallel.

## Done

- **210.1** `WorkspaceLock`: an `flock` on `build/.nomu-lock`, taken by `build`, `run` and `test` once planning
  succeeds (a planning error still writes nothing) and held until the build returns; `run` releases it before
  the program starts. A second invocation prints `nomu: waiting for another nomu (pid N) building in workspace
  '…'` and waits. The kernel releases an `flock` when its holder exits, so a dead holder never blocks;
  the pid in the file is only for the message. `nomu compile` never takes it.
- **210.2** `build/` shows the last build: `PlanOptions.outputConfig` and the `build/<configs>/` level are
  gone. Binaries at `build/<module path>/<leaf>`; externals under `build/_external/<scope>.<name>/`, the language
  workspace under `build/_external/nomu.nomu/` and the runtime archive under `build/_runtime/`, materialized from
  the host cache (209.4). User modules are not yet in the store and compile every build, as before; 172.1
  brings them in.
- **210.3** `Layout`: a file where a directory goes (the directory or an ancestor, within `build/`) and a
  directory where the binary goes are reported (`nomu: removed '…', a file left by an earlier build …`) and
  removed. Old `build/<configs>/` directories are not recognized as stale; they stay until `build/` is deleted.
- **210.4** `build_tests`: a second build waits while the test holds the lock and names its pid; a lock file
  naming a dead pid does not delay a build; a stale file and a stale directory are cleared. The suite runner's
  lanes keep both tiers' times within a few seconds of before (fast 42.6 s, full 121.6 s).
- `tools/escape-diff.sh` reads one binary path per example; its builds take turns and its runs stay parallel.

## Refs

`build`, `linkBinary` (`src/driver/sources/Driver.swift`); `PlanOptions.outputConfig` (removed here);
`tools/escape-diff.sh`, `tools/perf-tier.py` (paths follow).
