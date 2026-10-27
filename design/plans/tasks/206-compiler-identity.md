# Compiler identity — a hash of the `nomu` binary in every cache key

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** S · **Status:** ready-to-build ·
**Source:** [172](172-incremental-build-cache.md) open question 9, [190](190-explicit-module-builds.md)
190.6 F5. A prerequisite of 172.

## Problem

Cache keys name the compiler by the git commit it was built from (`BuildInfo.gitCommit`, `HostCache`). A
compiler built from uncommitted changes has the same identity as the committed one, so it reuses entries
the other wrote. 203 hit this: its new symbol names met `std` objects with the old ones until the cache was
cleared by hand.

## Decided

The identity is a hash of the `nomu` binary. It changes whenever compiled output can, at the cost of
invalidating every entry on each compiler rebuild (while working on the compiler, the language workspace
recompiles after each rebuild, a few seconds). Set aside: the commit plus a hash of uncommitted compiler
sources (exact only inside git), and manual format and ABI versions (miss any change nobody versioned).

## Work

- **206.1** Hash the running binary once per process (about 20 ms for 59 MB), remembered across runs by its
  inode, size and modification time so most runs read one small file. The remembered value lives in the
  host cache.
- **206.2** Every key that names the compiler uses it: the language workspace's key and the runtime
  archive's recipe today, 208's job keys later. `BuildInfo.gitCommit` stays for reporting (the binary's
  `__nomu_config` record, version output).
- **206.3** Tests: the identity holds across runs of one binary, changes when the binary changes (a copy
  with one byte altered), and a remembered value is ignored when the inode, size or time differ.

## Refs

`src/planner/sources/HostCache.swift` (`languageWorkspaceKey`, `runtimeArchiveKey`); `src/buildinfo`;
[199](199-cache-management.md) (the entries a changed identity leaves behind).
