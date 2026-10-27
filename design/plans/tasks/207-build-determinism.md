# Build determinism — identical inputs give byte-identical outputs

**Avenue:** Infra · **Type/Lifecycle:** `driver · codegen · needs-audit` · **Size:** M–L · **Status:**
needs-audit · **Source:** [172](172-incremental-build-cache.md) (Determinism). A prerequisite of 172's
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
- **207.4** The check runs with the suite, so a regression fails a test.

## Refs

`.nmi` is already deterministic (name-sorted, body-free, 100.4.1); `src/driver/sources/Driver.swift`
(`linkBinary`); `LanguageSourceCopy`.
