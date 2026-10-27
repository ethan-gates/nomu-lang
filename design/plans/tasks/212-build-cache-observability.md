# Build-cache observability — what was cached, what was not, and why

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** M · **Status:** ready-to-build ·
**Source:** [172](172-incremental-build-cache.md). A prerequisite of 172; needs [208](208-job-keys.md) and
[210](210-workspace-lock-and-layout.md).

## Why

A cache that serves a stale object is wrong silently. Reporting why each module recompiled, and that every
other came from the cache, is how a cascade can be checked against what the edit should cause: a body edit
that changes a function's escape facts should recompile its consumers, and one that changes nothing they read
should recompile nothing above it. The report is a soundness tool as much as a convenience.

## What a build reports

- **A summary:** modules compiled, modules from the cache, and time spent compiling.
- **A reason per recompiled module:** the first input that differs from the key the module's previous build
  used: its own source (by file), a setting (by name, old and new value), the compiler, the target, or a
  dependency's interface.
- **For a dependency, the part that changed:** its ABI, its perf facts, or its `.bir` bodies, and within perf
  facts the definition whose facts changed (164.4.3's per-definition perf hashes). A cascade reads as a chain
  back to the edit:

```
compiled 3, cached 41 (2.1 s compiling)
  app/util     source changed: util.nomu
  app/server   dependency app/util: perf facts changed (escape summary of `parse`)
  app/cli      dependency app/util: perf facts changed (escape summary of `parse`)
```

A module compiled for the first time reports that it had no previous entry.

## Work

- **212.1** Section-level hashes in the key's named inputs (208.2): each dependency's ABI, perf and `.bir`
  hashes beside the whole-file hash the key uses, and the per-definition perf hashes. The key itself is
  unchanged (it covers the bytes, 172's decision).
- **212.2** The last-build record: module → the key its last build used, kept in the workspace beside
  210's `build/` view, written when a build finishes. The key's named inputs go in it only when the reasons
  are asked for, as Bazel writes its execution log only on request (208.2); a rebuild after a build that did
  not record them reports that the key changed, without the input.
- **212.3** The report: the summary on every build (one line), the per-module reasons under a flag, and
  machine-readable lines under `--report-jobs` for tests and the harness.
- **212.4** Tests: a body edit that changes a function's escape facts reports the chain to each consumer; a
  body edit that changes nothing a consumer reads reports every consumer cached; a setting change names the
  setting; a fresh workspace reports no previous entries.

Totals across builds (hit rates over time, store size) are [199](199-cache-management.md)'s.

## Refs

`ModuleInterface.abiHash`/`perfHash` and the per-definition perf section
(`src/interface/sources/ModuleInterface.swift`, 164.4.3); `--report-jobs` (`src/nomu-cli`).
