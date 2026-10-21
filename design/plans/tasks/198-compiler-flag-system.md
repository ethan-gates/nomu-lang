# Compiler flag system — every build and runtime setting a real flag

**Avenue:** Infra · **Type/Lifecycle:** `driver · runtime · design` · **Size:** L · **Status:** design not
started · **Source:** the 176.5.7 harness design, which needs GC and memory behavior varied per test run and
found it reachable only through environment variables.

## Deliverable

A designed and built flag system: every setting that changes what the compiler emits or how a built program
behaves (GC, memory, optimizer passes, diagnostics) is a named, documented flag with a defined user surface.
Ambient environment variables stop changing results.

## Goals

- **Every setting is a flag.** GC and memory tuning (collection stress, nursery size, mature floor, heap
  size), optimizer pass switches (inlining, escape analysis, scalar promotion, devirtualization), and debug
  output (collection logging, IR dumps) each have a name, a documented meaning and a documented home.
- **Each flag says what it acts on.** Compilation (`nomu compile`), the build (`nomu build`: planning,
  linking, the host cache), or the running program. A program setting is fixed at build time, passed at run
  time, or both, as the design decides.
- **Settings arrive only by flag.** The compiler, the driver and built programs stop reading stray `NOMU_*`
  environment variables. A setting in a developer's shell cannot change a build or a run unless the user
  passed it.
- **Outputs keyed by configuration.** Builds of one module under different flags land in different output
  locations, and the driver reports where the binary is. The harness uses the reported path. 176.5.7 ships a
  quick version of this; this task replaces it.
- **Flags are build inputs.** Every flag that changes compiled output is an input to the hashing that keys
  cached and incremental artifacts: the host cache (the embedded workspace's `outputOptions`) and any
  incremental reuse of module outputs. Changing a flag rebuilds what it affects and nothing else.
- **Parallel compiles of one module again.** 176.5.7's quick version gives each configuration its own binary
  by compiling configurations of the same fixture one after another and copying each binary out. Once
  outputs are placed by configuration, the harness compiles them in parallel again and drops the copy.
- **User surface.** The flag names, grouping and spelling users see, decided once for `build`, `run`,
  `test` and `compile`, including how a package or workspace sets defaults.

## Background

Today these settings are environment variables read in several places: optimizer switches in
`LLVMBridge.swift` (`NOMU_NO_INLINE`, `NOMU_NO_ESCAPE`, `NOMU_NO_SCALAR`), prelude and debug switches in the
driver and egress, and collector settings in the runtime at program start (`NOMU_GC_STRESS`,
`NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_GC_DEBUG_PRESSURE`). Which stage reads which variable is
undocumented, the host cache does not see the compile-time ones, and two builds of one module under
different settings write the same output path. The integration suite works around all of it by setting
variables per case.

## Relationships

- **176.5.7** (the shape matrix in the suite) needs per-configuration outputs now and builds a quick version;
  its harness names settings by meaning, so moving them from variables to flags changes the harness's
  translation and leaves the manifest as it is.
- **190** (explicit module builds) owns the driver, the plan and the host cache this task extends.
- **155** (the integration-suite harness) is the main consumer.
