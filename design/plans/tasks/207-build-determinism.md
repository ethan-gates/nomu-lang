# Build determinism — identical inputs give byte-identical outputs

**Avenue:** Infra · **Type/Lifecycle:** `driver · codegen · done` · **Size:** M–L · **Status:**
done · **Source:** [172](172-incremental-build-cache.md) (Determinism). A prerequisite of 172's
early cutoff; shared with [156](156-differential-stage-diffing.md) and [192](192-bazel-friendliness.md).

## Why

172 keys a job on the bytes it reads, its dependencies' `.nmi` and `.bir` among them. A hit is sound
whether or not outputs are deterministic, but a dependent is reused after a dependency recompiles only when
the dependency's outputs come out byte-identical. Non-deterministic outputs cost rebuilds, never
correctness. Differential stage-diffing (156) and Bazel's caching (192) need the same property.

## Work

- **207.1** A check: build every suite fixture twice from clean and compare every output byte for byte
  (objects, `.nmi`, `.bir`, binaries, the runtime archive). Report each difference by file and offset.
- **207.2** Fix what it finds. Likely sources: dictionary and set iteration order in emitted tables and
  symbol order, address-derived names, timestamps, scratch paths in the link (`.link-<pid>-…` staging names
  reach the binary through the linker), and the code signature.
- **207.3** Path independence: the same sources at two checkout paths give identical objects, through
  relative paths in debug info (a prefix map, as `-fdebug-prefix-map` does) and reporting paths (190.6 F10's
  source copy).
- **207.4** The sweep, run on request (`compiler-test --check-reproducible`), so it costs nothing in the fast
  and full tiers: every fixture across two clean rounds at two checkout and cache paths.
- **207.5** A cache-verify mode, `nomu build --verify-cache`: a build compiles every job, taking nothing
  from the cache, and fails when an entry already under a job's key differs from its compile. On a mismatch it
  reports the module, the file and the entry's recorded key inputs (208), which have to be ruled out first. A
  missing input is one that is absent from that list.
  - **Telling the two failures apart.** A mismatch has two causes. Non-determinism: the same inputs give
    different bytes on each run. Unhermetic input: the compile reads something its key leaves out. The
    sweep (`compiler-test --check-reproducible`) answers the first: when it passes, the mismatch points at an
    input outside the key.
  - Covers the language workspace's entries now and every module once 172.1 stores them.

- **207.6** Binaries; a prerequisite of [214](214-link-caching.md) (link caching), and so of 172. A binary's
  debug map (`N_OSO`) named each object by absolute path, so binaries were path-dependent, and a cached link
  must not be. The split follows Xcode and Bazel: development links keep a debug map, with relative paths;
  `release` writes a dSYM, since `dsymutil` costs O(all debug info) per link.

## Progress

- **207.1 audit, by script so far.** Every suite fixture (140, with each case's compile settings as configs)
  under `debug` and `release`, built in two rounds, each a fresh `build/` and host cache at the same paths,
  every build its own `nomu` process; 904 outputs compared (objects, `.nmi`, `.bir`, binaries, the runtime
  archive, entry manifests). The permanent check is 207.4's.
- **207.2 fixes.** Three sources found, all fixed; six rounds since are byte-identical.
  - `.bir` declaration order followed `Dictionary` and `Set` iteration (`shippedTemplates`); it now follows
    declaration order.
  - The link's debug map (`N_OSO`) recorded each object's modification time, which reached the binary's
    UUID and code signature; the link runs with `ZERO_AR_DATE=1`.
  - The runtime archive recorded member times; `ar` runs with `ZERO_AR_DATE=1`, as part of the recipe, so the
    archive's key changed with it.
- **207.4 and 207.5 done.** `nomu build --verify-cache`
  (`CacheVerification`): every job compiles once and nothing is taken from the host cache. A job whose key
  already has an entry is compared with it, file by file; a difference is an error naming the module, the
  first differing file and byte, and every input the entry's manifest records for the key (the inputs to rule
  out first). The entry is left in place, and the build fails before the link. Telling non-determinism from an
  input missing from the key is the sweep's job: a sweep that passes points at a missing input. Today only
  the language workspace's modules have entries; 172.1 brings every module in.
  Recording values outside the key (working directory, environment, tool versions) beside each entry was set
  aside: an input outside the key is a defect in the key, and once suspected it joins the key.
- `compiler-test --check-reproducible` (`ReproducibilitySweep.swift`): every selected compile configuration
  (expect-error cases aside), two clean rounds, the second from a copy of the sources and a host cache at
  other, longer paths; compares every file under each `build/` and the host cache's `ac/` and `cas/`, binaries and
  `.lldbinit` aside. Fast tier: 165 configurations, 381 outputs, about 6 s; full tier: 497
  outputs. Both identical.
- **207.3 path independence: done for every cached output.** Debug info records `/nomu-src/<workspace>/<path>`
  (`DebugPaths`; the language workspace is `nomu.nomu`), set per file as the job's `debugPaths`, separate from
  the reported path diagnostics show. Package keys are workspace-relative. A binary's link writes
  `<binary>.lldbinit`, mapping each prefix to the workspace's root (the language workspace's to the source copy),
  loaded with `lldb -s`. Job keys name files by their recorded paths, so no key input is an absolute path. The
  audit with a second checkout and host-cache path (`DET_PATHS=1`): every object, `.nmi`, `.bir` and manifest
  matches.
  - Binaries stay path-dependent: the debug map's `N_OSO` entries name each object by absolute path, which
    lldb follows to the DWARF. Binaries are not cached; making them path-independent (`-oso_prefix`, or a
    dSYM) is Bazel's concern ([192](192-bazel-friendliness.md)).
  - Checked by hand: lldb, given the `.lldbinit`, lists source for a user module and a `std` module.

- **207.6 done.** The setting `link.debug_info_storage: objects | dsym` (build target,
  program granularity; `release` sets `dsym`). `objects`: the link passes `-oso_prefix <workspace root>/`, so the
  debug map names `build/…` paths; every object a link reads is under `build/` since 209.4. `dsym`: after the
  frame index, `dsymutil` writes `<binary>.dSYM` and `strip -S` removes the debug map, then the binary is signed;
  the dSYM shares the binary's UUID and moves into place beside it, and a later `objects` build removes it.
  Neither form holds an absolute path. The sweep now compares binaries and dSYMs (563 outputs identical across
  two checkout and cache paths); `build_tests` (`testDebugInfoStorage`) checks both forms. Checked by hand: lldb
  lists source through the relative debug map, from the workspace and from another directory, and through the
  dSYM.

## Refs

`.nmi` is already deterministic (name-sorted, body-free, 100.4.1); `src/driver/sources/Driver.swift`
(`linkBinary`); `LanguageSourceCopy`.
