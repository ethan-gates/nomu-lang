# Link caching — a cached link for an unchanged binary

**Avenue:** Infra · **Type/Lifecycle:** `driver · done` · **Size:** M · **Status:** done ·
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

## Done

- **214.1** `LinkInputs` and `JobKeyer.key(_: LinkInputs)` (`src/driver/sources/LinkKey.swift`). Inputs:
  `compiler`, `target`, `target.cpu`, `target.features`; `link.recipe` (the flags in `linkFlags` and the steps
  after the link); `link.debug-info-storage`; `binary.name`; `objects` (the order); `object:<path>` per object by
  content hash; `runtime-archive` by content hash; `config-record` (hash of the `__nomu_config` record);
  `runtime-global:<symbol>` per settings-object value. Each object enters by the path the binary's debug map
  records: relative to the workspace root, else absolute. The workspace root itself stays out.
- **214.2** Every link goes through the store. `linkBinary` links into a private scratch directory and returns its
  outputs' names: the binary, plus each file of `<binary>.dSYM` under `dsym`. A miss publishes them; a hit or a
  miss then materializes them at the binary's path (`materializeLink`), after removing any dSYM there and any
  directory where the binary goes. The store makes the directories a nested output name needs. The runtime archive
  is materialized once per build, before the links. The `.lldbinit` is written on every build, outside the store.
- **214.3** `--verify-cache` links every binary and compares it with the entry at its key (`link of <binary>:
  differs from its cache entry`, with the key's inputs). `BuildRecord.links` holds each binary's link key; the
  reasons add `object changed: <path>`, `object list changed`, `runtime archive changed`, `configuration record
  changed`, `link recipe changed`, `setting link.debug_info_storage: <old> → <new>` and `runtime setting <symbol>:
  <old> → <new>`. `--explain` prints `why each binary linked`; `--report-jobs` prints `linked <binary>`,
  `link-cached <binary>` and `reason link:<binary> <text>`.
- **214.4** `job_key_tests` (`LinkKeyTests`): each input changes the key and is named, the runtime archive
  included; the key is the same at another checkout path. `build_tests`: `testUnchangedBuildLinksNothing`,
  `testChangedInputsRelink` (an object edit and `link.debug_info_storage` each relink with their reason; reverting
  both serves the earlier link and removes the dSYM), `testVerifyCacheCoversLinks`,
  `testCachedBinaryServesAnotherCheckout` (binary and dSYM byte-identical). `store_tests`: an executable stays
  executable and a bundle's files materialize under their directories.
- **Found on the way (207.6):** `dsymutil` read the debug map's relative object paths from the current directory,
  so a `dsym` build run outside the workspace root wrote a dSYM with no debug info. It now runs with
  `--oso-prepend-path <workspace root>`, in the scratch directory, given the binary by name, so the dSYM's
  relocation map records the binary's name alone. `testDebugInfoStorage` checks the dSYM holds subprograms and that
  relocation map. The sweep now compares populated dSYMs: 891 outputs identical. Checked by hand: a `-c release` build run
  from `/tmp`, in lldb with the binary's `.lldbinit`, loads the dSYM, resolves a `main.nomu` line breakpoint, shows
  `main.nomu:8:11` in the backtrace and lists the source.

- **214.5** Toolchain identity (`Toolchain`, `src/driver/sources/Toolchain.swift`): each system tool the link and
  the runtime archive run enters their keys as `tool:<name>`. `cc`, `ld` and `dsymutil` by their version reports;
  `strip`, `ar`, `codesign` by content hash; the SDK by its `SDKSettings.json`'s. The answers live in the host
  cache's `toolchain.json` with the selected developer directory, `DEVELOPER_DIR`/`TOOLCHAINS`/`SDKROOT`/
  `MACOSX_DEPLOYMENT_TARGET`, and each resolved tool's size and modification time; while those hold a build runs
  no tool. `--explain` says `toolchain changed: <tool> (<old> → <new>)`. Tests: `ToolchainTests`,
  `testToolchainChangeRelinks`, and `tool:*` cases in `LinkKeyTests` and the runtime archive key's test. Interim
  until [216](216-embedded-toolchain.md) embeds the tools.

Open: every distinct binary stays in the store until [199](199-cache-management.md) evicts.

## Refs

`linkBinary`, `cachedRuntimeArchive` (`src/driver/sources/Driver.swift`); `JobKey`, `CacheVerification`,
`BuildRecord`.
