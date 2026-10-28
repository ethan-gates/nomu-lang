# Link caching — a cached link for an unchanged binary

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** M · **Status:** ready-to-build ·
**Source:** [172](172-incremental-build-cache.md), whose cache covers the whole build: compiles and links. A
prerequisite of 172; needs [207](207-build-determinism.md).6 (path-independent binaries).

## What

A link is a job like a compile: it has a key over everything it reads, and a hit materializes the stored binary
instead of linking. A build whose modules all come from the cache and whose link inputs are unchanged runs no
compile and no link.

## The key's inputs

- The objects, in link order, by content hash (the target's object first).
- The runtime archive, by content hash.
- The settings object's values (the runtime globals, G14) and the configuration record (`__nomu_config`, G13).
- The link recipe: the linker command and flags, the frame-index and signing steps (`linkBinary`).
- The compiler identity (206) and the target.
- The binary's name, which its code signature takes as its identifier.

## Work

- **214.1** The link key, beside the job key (208), with its inputs named for `--explain` (212).
- **214.2** Link outputs in the store (209): the binary, and its dSYM where 207.6 writes one; a hit materializes
  them at the target's path. The `.lldbinit` stays per machine and is written on every build.
- **214.3** `--verify-cache` and `--explain` cover links: a cached binary that differs from a fresh link is an
  error, and a relink names the input that changed.
- **214.4** Tests: an unchanged build links nothing; a changed object, setting or runtime archive relinks; a cached
  binary runs and matches a clean link byte for byte; a cached binary from another checkout path is identical
  (207.6).

## Refs

`linkBinary`, `cachedRuntimeArchive` (`src/driver/sources/Driver.swift`); `JobKey`, `CacheVerification`,
`BuildRecord`.
