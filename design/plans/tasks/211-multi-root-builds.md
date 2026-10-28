# Several root modules per build

**Avenue:** Infra · **Type/Lifecycle:** `planner · driver · done` · **Size:** M · **Status:**
done · **Source:** [172](172-incremental-build-cache.md) part 1, [190](190-explicit-module-builds.md)
190.6 F22. A prerequisite of 172.

## What

`nomu build a b` builds each target as its own build today: two plans, two passes over shared modules, two
runtime-archive checks. This task plans one graph over every target, so a module the targets share compiles
once, their jobs run in one pass, and work every build needs (the runtime archive, the language workspace)
is planned once. `test` gains the same for a package's declared tests.

With [210](210-workspace-lock-and-layout.md)'s lock, one invocation per workspace, a multi-root build is
how several things in one workspace build together.

## Work

- **211.1** The planner takes several entry modules: one module table and one job list, each target
  linked from it (a binary per executable target).
- **211.2** `build` and `test` pass every target to one plan; the report lists each target's binary.
- **211.3** Configuration resolves once for the build, over every target's modules (198).
- **211.4** Tests: two roots sharing a module compile it once; a planning error in one target stops the
  build before any compile; each binary matches its single-target build.

## Done

- **211.1** `ModuleTable(workspaces:roots:)` resolves from every root (`roots`; `entry` is the first, whose
  workspace is the build's). A target outside the build's workspace is a planning error (one invocation per
  workspace, 210); the same target twice is one root. A binary root that another module of the build imports is
  a planning error ("build them separately"): its object owns the program-wide definitions. `Plan(roots:)` gives
  every root a binary job and its own `LinkJob`: the root's object, then the objects of the modules it reaches
  and of the implicit roots (the `runtime` package), so a target links only what it uses.
- **211.2** `build(targets:)` in the driver: one plan, one pass over the jobs, the runtime archive once, then one
  link per target; debug views (`--emit-*`) for each target. `nomu build a b` makes one call and
  `--report-jobs` prints a `binary` line per target. `nomu test` takes several declared test modules
  (`testPackages`), builds them as one plan and runs each binary in turn. Running jobs in parallel is
  [191](191-threaded-job-execution.md)'s.
- **211.3** Configuration resolves once, as before: program and build settings come from the entry workspace,
  which every target shares.
- **211.4** `planner_tests`: two roots share a module as one job, each link holds only what its root reaches, a
  repeated target is one root, and an imported root and a root outside the workspace are errors.
  `build_tests`: two fixtures in one build compile each module once, and each binary is byte-identical to its
  single-target build; a planning error in one target stops the build before any compile.

## Refs

`Plan`, `ModuleTable` (`src/planner`); `runBuild`, `testPackage` (`src/nomu-cli`, `src/driver`).
