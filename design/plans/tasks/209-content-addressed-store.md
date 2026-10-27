# Content-addressed store — one store for every cached artifact

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** M · **Status:** ready-to-build ·
**Source:** [172](172-incremental-build-cache.md) (Artifact store). A prerequisite of 172.

## What

The host cache has two hand-written caches today, each with its own staging and publish: the runtime
archive (`cachedRuntimeArchive`) and the language workspace's module directories (the job loop in
`build`). This task makes one store they both use, which 172 then gives to every module.

An entry is a directory under its key. A writer fills a staging directory and publishes it by one atomic
rename, so a crash or a concurrent writer never leaves a partial entry at a key; two writers of one key
produce the same bytes, so whichever rename wins is right. An entry carries a small manifest (its files and
their hashes, and 208's key inputs when it holds a job's outputs), and a reader that finds an entry
missing a file or failing its manifest discards it and rebuilds, never serving it.

Location: the per-host cache (`NOMU_CACHE_DIR`, else the platform cache directory), under one root per kind
(`modules/`, `runtime/`). Tentative, like the rest of 172's layout.

## Work

- **209.1** The store: look up a key, stage, publish, verify against the manifest, discard.
- **209.2** The runtime archive and the language workspace move onto it, with no change in what a build
  does or produces.
- **209.3** Tests: publish and look up; a concurrent publish of one key; an entry with a missing or altered
  file is discarded and rebuilt; leftovers of an interrupted publish are ignored (and listed for
  [199](199-cache-management.md) to clear).

Clearing, eviction and size limits stay with 199.

## Refs

`cachedRuntimeArchive`, the language workspace's staging and publish (`src/driver/sources/Driver.swift`);
`HostCache` (`src/planner/sources/HostCache.swift`); 190.6 F22 (the archive publish race).
