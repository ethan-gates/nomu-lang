# Incremental build cache (content-addressed, module-granular)

**Avenue:** Infra · **Type/Lifecycle:** `perf · driver` · **Size:** M (the wiring; the parts are their own
tasks) · **Status:** design settled; waits on [206](206-compiler-identity.md)–[212](212-build-cache-observability.md) ·
**Source:** pulled out of [100](100-modules.md) §100.4.5 (driver incremental cache) + §100.4.6 (incremental /
stability tests).

## What

A persistent cache at **module granularity**: a build recompiles only the modules whose inputs changed and
reuses the stored outputs (`.o`, `.nmi`, `.bir`) of every other. The output of an incremental build is
bit-for-bit the output of a clean build.

The parts are prerequisite tasks, each verified on its own; 172 itself connects them:

| task | what it provides |
|---|---|
| [206](206-compiler-identity.md) compiler identity | the commit plus uncommitted changes, baked into `nomu`, in every key, so a changed compiler never reuses stale entries |
| [207](207-build-determinism.md) build determinism | byte-identical outputs for identical inputs, so a recompiled dependency with unchanged outputs leaves its dependents' keys unchanged (early cutoff) |
| [208](208-job-keys.md) job keys | a key per job over everything the compile reads, with its inputs recorded for "why did this rebuild" |
| [209](209-content-addressed-store.md) content-addressed store | one store, staged and atomically published, for the runtime archive, the language workspace and now every module |
| [210](210-workspace-lock-and-layout.md) workspace lock and `build/` layout | one invocation per workspace (a second waits, naming the holder's pid), the binary as a real file in `build/` |
| [211](211-multi-root-builds.md) several root modules per build | one plan over several targets, so shared modules compile once |
| [212](212-build-cache-observability.md) build-cache observability | how many modules compiled and came from the cache, and why each recompiled, down to the dependency section (ABI, perf facts, `.bir`) and definition; the way soundness is checked |

**Boundary with [136](136-incremental-compilation.md) (Incremental compilation).** 172 is the **coarse,
persistent, module-granular build cache**. 136 is the **fine-grained, in-process, query-based** incremental
story (sub-module units, cached monomorphizations, LSP responsiveness), downstream of
[142](142-ir-pipeline-hardening.md), reusing 172's keys and store.

## Decided

- **Keys cover the bytes a compile reads** ([208](208-job-keys.md)). A dependency contributes its `.nmi` and
  `.bir` bytes, since a dependent reads its perf facts (escape summaries) and, under `opt.mono`, its bodies,
  as well as its ABI. Keying on the ABI hash alone would serve stale objects. Early cutoff comes from
  determinism (207): a body edit that leaves a dependency's outputs byte-identical rebuilds nothing above
  it. This settles how the `opt.mono` dial and `.bir` bodies reach dependents, and which dependency
  interfaces enter a key (190.6 F15): each mode's key covers what that mode's compile reads.
- **The compiler's identity is its commit plus a hash of uncommitted changes, baked in at build time**
  ([206](206-compiler-identity.md)); 190.6 F5.
- **Entries live in the host cache, `build/` shows the last build** (tentative; [209](209-content-addressed-store.md),
  [210](210-workspace-lock-and-layout.md)).
- **One invocation per workspace**, a second waiting with the holder's pid ([210](210-workspace-lock-and-layout.md));
  190.6 F3.
- **Clearing, eviction and size limits** are [199](199-cache-management.md)'s.
- **The cache belongs to `build`, `run` and `test`.** `nomu compile` stays a pure function of its job file
  and does no caching; under Bazel, Bazel's action cache does that job ([192](192-bazel-friendliness.md)).

## Work

- **172.1** The build looks up each job's key (208) in the store (209): a hit takes the entry's outputs and
  skips the compile, a miss compiles into a staging entry and publishes it. User and external modules join
  the language workspace in the store; `--report-jobs` reports hits as `cached`.
- **172.2** Externals and the language workspace default to `release` when nothing is selected
  (`CompilerSettings.externalDefault`), as 198's design intends; 198 kept them on `debug` until optimized
  externals stop recompiling on every build.
- **172.3** Tests:
  - a body edit that leaves interfaces byte-identical reuses every dependent's entry (counted by
    `--report-jobs`, not just equal output);
  - an interface edit recompiles its dependents;
  - incremental output equals a clean build's, byte for byte, across the suite's fixtures;
  - concurrent builds of two workspaces sharing one cache produce correct, uncorrupted entries;
  - each case's 212 report matches the edit: the reasons name what the edit changed, and nothing else
    recompiles.

## Deferred until after 172

Explicitly out of 172's scope; each is picked up after it lands. Added to as the work goes.

- **A shared cache layer, remote caching and remote execution** — Bazel's ([192](192-bazel-friendliness.md)).
- **Granularity below the module** — [136](136-incremental-compilation.md).
- **Eviction, size limits, clearing and totals across builds** — [199](199-cache-management.md).
- **Replacing the key hash** — open question 1; 64-bit FNV-1a stays behind one function.
- **More of `build/`:** objects and interfaces linked or listed there, and tools reading two configurations
  through it ([210](210-workspace-lock-and-layout.md) keeps only the binary).

## Open questions

1. **The key hash** ([190](190-explicit-module-builds.md) 190.6 F16). Today 64-bit FNV-1a (`Hasher64`),
   behind one function. A replacement must have no dependencies (implementable in Swift and later Nomu,
   ideally under 20 KB and 1000 lines), throughput at least FNV-1a's, nothing egregious on small inputs, and
   collision odds like 64-bit FNV-1a or better (about N²/2⁶⁵ for N entries). Candidates: FNV-1a at 128 bits,
   an in-tree XXH3. The YAML parser ([204](204-yaml-parser-upgrades.md) 204.2) shares it and adds needs:
   latency on 8–16-byte keys, a full final mix, a per-parse seed.

## Dependencies & triggers

- **Depends on:** [206](206-compiler-identity.md)–[212](212-build-cache-observability.md);
  [198](198-build-configuration.md) (done: every setting that changes an object is in the job's `settings`).
- **Rides:** [164](164-formal-inference-stage.md) §164.4.2 (sectioned `.nmi`); [100](100-modules.md)
  §100.4.1/.2 (`.nmi` + per-module objects).
- **Feeds:** [136](136-incremental-compilation.md), [137](137-tooling-lsp-formatter.md) LSP responsiveness,
  [192](192-bazel-friendliness.md).
- **Interacts with:** [145](145-monomorphization-cost.md) (cached monomorphizations),
  [142](142-ir-pipeline-hardening.md) (versioned stage formats, so a cached artifact is never misread),
  [156](156-differential-stage-diffing.md) (shares determinism).

## Refs

[100](100-modules.md) §100.4.5/.6, §100.5 (dial); `ModuleInterface.abiHash`/`perfHash`
(`src/interface/sources/ModuleInterface.swift`); `cachedRuntimeArchive`, `HostCache`.
