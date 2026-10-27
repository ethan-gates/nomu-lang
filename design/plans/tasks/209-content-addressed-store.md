# Content-addressed store — one store for every cached artifact

**Avenue:** Infra · **Type/Lifecycle:** `driver · done` · **Size:** M · **Status:** done ·
**Source:** [172](172-incremental-build-cache.md) (Artifact store). A prerequisite of 172.

## What

The host cache had two hand-written caches, each with its own staging and publish: the runtime archive
(`cachedRuntimeArchive`) and the language workspace's module directories (the job loop in `build`). This task
makes one store they both use, which 172 then gives to every module.

The store is split as Bazel's remote and disk caches are:
- **An action cache,** `ac/<key>`: a job's action result, its outputs by name with each one's size and content
  digest, written whole by one atomic rename.
- **A content-addressed store,** `cas/<digest>`: each output's bytes under the digest of its content, stored once
  however many results name it.

A build materializes a hit's outputs at the paths it reads them from, under the workspace's `build/`, by cloning
each blob (APFS `clonefile`: no copy and no extra space until a file changes; elsewhere a copy, never a hard link,
since the compiler rewrites an object in place). A lookup checks every blob a result names against its digest,
and a result naming a missing or altered blob is discarded and rebuilt, never served.

Location: the per-host cache (`NOMU_CACHE_DIR`, else the platform cache directory). Tentative, like the rest of
172's layout.

## Work

- **209.1** The store: look up a key, stage, publish, verify against the manifest, discard.
- **209.2** The runtime archive and the language workspace move onto it, with no change in what a build
  does or produces.
- **209.3** Tests: publish and look up; a concurrent publish of one key; an entry with a missing or altered
  file is discarded and rebuilt; leftovers of an interrupted publish are ignored (and listed for
  [199](199-cache-management.md) to clear).
- **209.4** The action cache and content-addressed store split, with outputs materialized under `build/`, in
  place of one directory per key that builds read from directly.

Clearing, eviction and size limits stay with 199.

## Done

- **209.1–209.3** built one directory per key with a manifest, staged and published by rename; 209.4 replaced
  that layout.
- **209.4.** `ArtifactStore` (`src/store`): `lookup` (reads `ac/<key>`, checks each blob's size and digest,
  discards the result on a failure), `materialize` (clones each blob to a temporary name beside its target, then
  renames), `publish` (each output into the CAS by clone and rename, skipped when its blob is already present;
  then the result by rename), `discard` (the result only; blobs stay), `leftovers` (`.tmp-*` in `ac/` and `cas/`).
  `ActionResult` holds the files and the key (`inputs: ["key": …]`; named inputs are computed on request, 208.2).
  `ContentHash` names blobs; `Hasher64` is the one hash function.
  - Layout: language-workspace modules under `build/_external/nomu.nomu/<path>`, as any other workspace's;
    the runtime archive under `build/_runtime/` (210 removed the `<configs>/` level). `HostCache.store(cacheRoot:)`;
    `ModuleJob.hostCacheKey` and `RuntimeArchiveJob.key` are the keys.
  - A cached job that misses compiles into a private scratch directory, publishes, and is materialized into
    `build/`; materializing renames each file into place, so a concurrent build of the same workspace never
    reads a half-written output (compiling in place into `build/` raced, failing 45 full-tier cases on a cold
    cache). The runtime archive builds in scratch the same way.
  - `--verify-cache` compares a fresh compile with the result's blobs, and the sweep compares `ac/` and `cas/`.
  - Tests: `store_tests` covers publish, look up and materialize; a materialized output changed in place
    leaving its blob; identical outputs sharing one blob; 16 concurrent publishes of one key; a missing blob, an
    altered blob and an unreadable result each discarding the result; interrupted writes ignored and listed.
    `build_tests` damages the `std/prelude` object's blob and the runtime archive's, each rebuilt alone.
  - The old roots (`nomu/`, `modules/`, `runtime/`) are left for 199 to clear.

## Refs

`cachedRuntimeArchive`, the language workspace's staging and publish (`src/driver/sources/Driver.swift`);
`HostCache` (`src/planner/sources/HostCache.swift`); 190.6 F22 (the archive publish race).
