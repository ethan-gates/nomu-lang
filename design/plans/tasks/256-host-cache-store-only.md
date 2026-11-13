# Host cache: the store and nothing else

**Avenue:** Infra · **Type/Lifecycle:** `driver · store · ready` · **Size:** M · **Status:** not started ·
**Source:** an audit of the host cache after 207.7. A user cache had grown to 13 GB with millions of blobs before
it was cleared by hand; a fresh one held 76,694 `checked/` marks for 69 blobs.

## Why

The host cache holds the store ([209](209-content-addressed-store.md): `ac/` and `cas/`) beside bookkeeping
that each has its own lifecycle, and none of it is ever removed:
- `checked/<digest>@<mtime>`: an empty file per blob hashed at a given modification time, so a lookup can skip
  hashing a blob again. Marks outlive their blobs.
- `costs/<key>`: what producing an entry took, one file per action result. `discard` leaves it behind.
- `source/`: one copy per host of the compiler's embedded sources, for debug info and diagnostics. Each compiler
  with other sources replaces it, so a binary can point at another compiler's sources, and `ensure` leaves a
  moment between its two renames where `source/` is missing.
- `toolchain.json`: the system tools' identities. Bounded and overwritten in place; it stays until the tools
  are embedded in the compiler, as Zig does.

The store itself has three more issues: `ac/` and `cas/` are flat directories that reach millions of entries;
keys and digests are 64-bit FNV-1a, whose collision odds grow with the cache and whose collision serves a wrong
output silently; and every lookup hashes blobs to rule out damage, which is what `checked/` exists to make
cheap.

## Decided

- **Follow Bazel's local disk cache** (`DiskCacheClient`), eviction aside:
  - A blob is written to a temporary file, fsynced, and renamed into place, which covers a crash between the
    rename and the data reaching the disk.
  - A lookup trusts a blob that exists: a content-addressed file has the right content if it is there. The store
    checks its size, which is cheap; `--verify-cache` remains the full check. `checked/` goes away.
  - The cost of producing an entry lives in its action result, as Bazel's `ActionResult` carries
    `execution_metadata`. Action results are then no longer byte-identical across runs; the sweep compares them
    without it.
- **Sharded directories:** `ac/<first two hex digits>/<key>` and `cas/<first two hex digits>/<digest>`.
- **SHA-256 for keys and blob digests**, settling [172](172-incremental-build-cache.md) open question 1 for the
  cache. Throughput is measured against today's FNV-1a first; a hardware-accelerated path may need a small C
  shim. The YAML parser's duplicate-key hash ([204](204-yaml-parser-upgrades.md) 204.2) has other needs (short
  keys, a per-parse seed) and keeps its own question.
- **No remote cache or remote execution, ever.** Bazel provides those ([192](192-bazel-friendliness.md)). This
  may reopen the hash choice later; it does not change it now.
- **The source copy leaves the host cache.** A build writes the embedded sources into its `build/` when a job
  of the language workspace needs reported paths. Showing source in a debugger takes the compiler that built
  the binary, which can write its sources again; a better experience waits until others use Nomu.
- **No migration.** The old layout is cleared by hand.
- **Eviction, its policy and recency tracking stay in [199](199-cache-management.md).** Removing `checked/`
  frees blob modification times for it.

## Work

- **256.1** Writes and lookups as Bazel's: fsync before each rename into `cas/` and `ac/`; lookups check sizes
  only; `checked/` removed. `store_tests` and `build_tests` cover a truncated blob as a miss; the tests that alter
  a blob's contents at its size move to `--verify-cache`.
- **256.2** Costs in the action result (`ActionResult` gains metadata outside the key); `costs/` removed. The
  sweep and `--verify-cache` ignore the metadata.
- **256.3** Sharded `ac/` and `cas/`; `leftovers()` and the sweep's comparison walk the shards.
- **256.4** SHA-256: a throughput measurement against `Hasher64` on objects, binaries and key inputs; then
  `ContentHash` and job and link keys move to it. Digests and keys grow from 16 to 64 hex digits.
- **256.5** The source copy written into `build/` from the embedded sources; `.lldbinit` and diagnostics name it
  there; `source/` and its staging directories are removed from the host cache.
- **256.6** Checked by `bazel test //src/...`, the full tier, `--check-reproducible`, and a listing of a cache
  after a full suite run holding only `ac/`, `cas/` and `toolchain.json`.

## Refs

Bazel's `DiskCacheClient` (`src/main/java/com/google/devtools/build/lib/remote/disk/DiskCacheClient.java`);
`ArtifactStore` (`src/store`), `ContentHash`, `Hasher64`, `LanguageSourceCopy`, `JobKey`;
[209](209-content-addressed-store.md), [199](199-cache-management.md), [172](172-incremental-build-cache.md),
[207](207-build-determinism.md).
