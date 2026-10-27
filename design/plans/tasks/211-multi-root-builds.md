# Several root modules per build

**Avenue:** Infra · **Type/Lifecycle:** `planner · driver · ready-to-build` · **Size:** M · **Status:**
ready-to-build · **Source:** [172](172-incremental-build-cache.md) part 1, [190](190-explicit-module-builds.md)
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

## Refs

`Plan`, `ModuleTable` (`src/planner`); `runBuild`, `testPackage` (`src/nomu-cli`, `src/driver`).
