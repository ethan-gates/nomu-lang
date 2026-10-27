# Compiler identity — the commit plus uncommitted changes, baked into the binary

**Avenue:** Infra · **Type/Lifecycle:** `build · done` · **Size:** S · **Status:** done ·
**Source:** [172](172-incremental-build-cache.md) open question 9, [190](190-explicit-module-builds.md)
190.6 F5. A prerequisite of 172.

## Problem

Cache keys name the compiler by the git commit it was built from (`BuildInfo.gitCommit`, `HostCache`). A
compiler built from uncommitted changes has the same identity as the committed one, so it reuses entries
the other wrote. 203 hit this: its new symbol names met `std` objects with the old ones until the cache was
cleare## Decided

The identity is a constant baked into `nomu` at build time, read like any other symbol: the git commit, plus
a hash of uncommitted changes to the paths that build it (`src`, `MODULE.bazel`, its lock, `.bazelrc`, the
root `BUILD.bazel`), tracked edits and untracked files both. A clean checkout's identity is the commit alone.
Compiler developers are a small share of users, but they are the ones whose builds would meet stale
entries, and the dirty-tree hash covers them at almost no cost.

Set aside: the commit alone (a dirty tree reuses the committed build's entries, which is how 203 met stale
`std` objects); a hash of the binary observed at run time (exact, but read after the binary is sealed, with
a file read per run and a remembered record per build; built first, then replaced); a Bazel-computed hash
of every compiler source (exact without git, but misses toolchain changes unless they are listed too).

## Done

- `tools/workspace_status.sh` writes `STABLE_NOMU_COMPILER_IDENTITY`: the commit, and `-<hash>` of
  `git diff HEAD` plus the untracked files under those paths when there are any. `unstamped` outside git.
- `src/buildinfo` bakes it as `BuildInfo.compilerIdentity`, beside `gitCommit`. Both are computed
  properties, so a new stamp changes `buildinfo`'s code and not its interface: a stamp change costs 6 Bazel
  actions (the genrule, `buildinfo`, the link), and no module that imports `buildinfo` recompiles.
- The driver passes it as `PlanOptions.compilerIdentity`, so the language workspace's key changes with any
  compiler change, committed or not.
- Checked: an edit under `src` changes the identity and reverting it restores it; a doc edit leaves it; a
  second build reuses the language workspace's entry. The runtime archive keeps its key, which already
  hashes the sources it builds from.

ent.md)'s.

## Refs

`tools/workspace_status.sh`; `src/buildinfo/BUILD.bazel`; `src/planner/sources/HostCache.swift`
(`languageWorkspaceKey`); [199](199-cache-management.md) (the entries a changed identity leaves behind).
