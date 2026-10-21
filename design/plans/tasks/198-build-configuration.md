# Build configuration — every build and runtime setting part of one configuration system

**Avenue:** Infra · **Type/Lifecycle:** `driver · runtime · design` · **Size:** L · **Status:** design not
started · **Source:** the 176.5.7 harness design, which needs GC and memory behavior varied per test run and
found it reachable only through environment variables; [190](190-explicit-module-builds.md) 190.6 F4
(build options reach only the entry workspace).

## Deliverable

A designed and built configuration system. A **setting** is one knob that changes what the compiler emits or
how a built program behaves (GC, memory, optimizer passes, diagnostics). A **configuration** is the full set
of settings in force for one module's compile, one link or one run. Configurations come from named modes
with defaults (for example `debug` and `release`), from package and workspace defaults, and from what the
user passes; a command-line flag is one source of a setting among these. Ambient environment variables stop
changing results.

## Goals

- **Every setting has a name.** GC and memory tuning (collection stress, nursery size, mature floor, heap
  size), optimizer pass switches (inlining, escape analysis, scalar promotion, devirtualization), and debug
  output (collection logging, IR dumps) each have a name, a documented meaning and a documented home.
- **Named modes with defaults.** A mode (`debug`, `release`, possibly others) fixes a coherent set of
  defaults; individual settings override it. A mode need not be an explicit flag: a build may get one by
  default, and a workspace may get a different default from the entry (see the next goal).
- **Every workspace gets a configuration.** The entry workspace, pinned external workspaces and the
  language workspace each compile under a defined configuration. Today only the entry workspace sees the
  build's options (F4 below). One likely rule: external workspaces and the language workspace default to
  `release` whatever the entry's mode, since their code is not under development; the design settles which
  settings follow the entry and which follow the workspace's default.
- **Each setting says what it acts on.** Compilation (`nomu compile`), the build (`nomu build`: planning,
  linking, the host cache), or the running program. A program setting is fixed at build time, passed at run
  time, or both, as the design decides.
- **Settings arrive only through the configuration.** The compiler, the driver and built programs stop
  reading stray `NOMU_*` environment variables. A setting in a developer's shell cannot change a build or a
  run unless the configuration names it.
- **Outputs keyed by configuration.** Builds of one module under different configurations land in different
  output locations, and the driver reports where the binary is. The harness uses the reported path. 176.5.7
  ships a quick version of this; this task replaces it.
- **The configuration is a cache-key input.** Each setting that changes compiled output has a canonical form
  that enters the hashing that keys cached and incremental artifacts: the host cache (the language
  workspace's key, today `PlanOptions.outputOptions`, never filled) and [172](172-incremental-build-cache.md)'s
  module cache. Settings that compile identically hash identically (`-O` and `-O --mono=all` resolve to one
  key). Changing a setting rebuilds what it affects and nothing else. 172's key design depends on this one.
- **Parallel compiles of one module again.** 176.5.7's quick version gives each configuration its own binary
  by compiling configurations of the same fixture one after another and copying each binary out. Once
  outputs are placed by configuration, the harness compiles them in parallel again and drops the copy.
- **User surface.** The mode names, setting names, grouping and spelling users see, decided once for
  `build`, `run`, `test` and `compile`, including how a package or workspace sets defaults.

## Background

Today these settings are environment variables read in several places: optimizer switches in
`LLVMBridge.swift` (`NOMU_NO_INLINE`, `NOMU_NO_ESCAPE`, `NOMU_NO_SCALAR`), prelude and debug switches in the
driver and egress, and collector settings in the runtime at program start (`NOMU_GC_STRESS`,
`NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_GC_DEBUG_PRESSURE`). Which stage reads which variable is
undocumented, the host cache does not see the compile-time ones, and two builds of one module under
different settings write the same output path. The integration suite works around all of it by setting
variables per case.

**Options reach only the entry workspace (190.6 F4).** The driver gives a job the build's `EmitOptions`
only when its module is in the entry workspace; every other job gets defaults (`Driver.swift`, the job loop
in `compile`). So `-O` builds the program at O2 over a debug-compiled `std`, `core` and `runtime`, and
`--mono` reaches the entry workspace only. `EmitOptions` mixes settings of three kinds, which the design
separates: output-affecting for every job (`optimize`, `mono` as `effectiveMono`), entry-scoped
(`allowCoreImport`, `subsetFuncs`, the `--emit-*` dumps, `stopAt`), and per job (`compilingPrelude`).
Accepted until this task:
- No correctness hazard. Optimization and the mono dial change performance only, and modules built under
  different settings interoperate by design; the frame index keeps only the records of the copy the linker
  kept (195). The language workspace is always built one way, so its cache entry is never stale, and no
  module under `build/` is reused across invocations (only host-cache jobs are).
- Every release performance figure so far includes a debug `std`, `perf-tier.py` results included.
- A release program over a release `std` has never been built; it needs a full-tier run when this lands.

## Relationships

- **176.5.7** (the shape matrix in the suite) needs per-configuration outputs now and builds a quick version;
  its harness names settings by meaning, so moving them from variables to the configuration changes the
  harness's translation and leaves the manifest as it is.
- **190** (explicit module builds) owns the driver, the plan and the host cache this task extends; its F4
  moved here.
- **172** (incremental build cache) depends on this task: its key takes the configuration's canonical form.
- **155** (the integration-suite harness) is the main consumer.
