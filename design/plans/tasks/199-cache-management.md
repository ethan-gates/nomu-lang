# Cache management — size limits, LRU eviction, pools and `nomu cache`

**Avenue:** Infra · **Type/Lifecycle:** `driver · cli · needs-design` · **Size:** M · **Status:** needs-design
(199.1 done) · **Source:** 190.6 F5 and F10, and [172](172-incremental-build-cache.md): with every compile and
link in the store, the host cache grows with ordinary editing, and nothing bounds or reports it.

## Deliverable

The host cache stays under a size the user sets, evicting the least recently used entries as builds run, with
separate control over each kind of content; `nomu cache` shows what it holds and how well it serves builds.
Until then there is no eviction: the cache is managed by hand, in the directory the build reports.

## What the cache holds

At the cache root (199.1): `NOMU_CACHE_DIR`, else the entry workspace's `cache.root`, else
`~/Library/Caches/nomu/` (macOS) or `$XDG_CACHE_HOME/nomu/` / `~/.cache/nomu/` (Linux):
- `ac/<key>` and `cas/<digest>`: the store ([209](209-content-addressed-store.md)). An action result per compile
  job (by job key), per link (by link key) and for the runtime archive, each naming its output blobs, stored
  once by content.
- `checked/<digest>@<time>`: which blobs were hashed at which modification time (172.1).
- `toolchain.json`: the system tools' identities (214.5).
- `source/`: the on-disk copy of the embedded sources, for reporting (190.6 F10).
- Leftovers: `.tmp-*` in `ac/` and `cas/` (`ArtifactStore.leftovers()`), `.source-*` directories, roots of earlier
  layouts (`nomu/`, `modules/`, `runtime/`).

## Design

The store already treats a result whose blob is missing as a miss (the result is discarded and the job
rebuilt), so eviction deletes blobs on their own, with no reference counts. Materialized outputs under
`build/` are clones and survive eviction.

1. **Last use: the blob's modification time,** set on each hit (one `utimes` per materialized blob). The
   `checked/` marks move from the modification time to the inode and creation time (`st_birthtime`), stable
   because a blob is written once. (Alternative: an index file with size and last use per entry, written under a
   lock by every build.)
2. **Size: sharded counters,** as ccache keeps them. The CAS splits into 256 shards by digest prefix
   (`cas/ab/…`), each with a stats file holding its byte count (and hit and miss counts), updated under the
   shard's lock as a build publishes. (Alternative: walk the cache on demand.)
3. **Eviction during builds, bounded:** a shard past its share of the limit (limit / 256) evicts its least
   recently used blobs when a build publishes into it. `nomu cache trim` evicts to the limit at once.
   (Alternative: only on command, or in the background as Bazel's disk cache does.)
4. **Concurrent builds:** a blob evicted between a build's lookup and its materialization is a miss, and the job
   or link rebuilds, instead of failing the build.
5. **Pools,** each with its own limits and policy: `artifacts` (compiles, links, the runtime archive) now;
   `workspaces` (fetched external workspaces' sources) when external workspaces are fetched. Sources are
   expensive to fetch again, so that pool evicts by age or on command only. Bookkeeping (`toolchain.json`,
   `checked/`, `source/`) is outside the pools.
6. **Configuration:** per host, in a user configuration file (`~/Library/Application Support/nomu/config.yaml`,
   `~/.config/nomu/config.yaml`) read through the configuration system of [198](198-build-configuration.md):
   `cache.artifacts.max_size` (a default, as ccache's 5 GB), optionally `max_age`, a warning size; each with an
   environment override, as `NOMU_CACHE_DIR` is for the root.
7. **`nomu cache`:**
   - `stats`: size and entries per pool against the limit; oldest and newest entries; hits and misses since
     the last reset (from the shard stats); `--json` (`vision.md`, Audience).
   - `clean [--pool artifacts|workspaces] [--all]`: remove a pool or everything, with the leftovers
     (`.tmp-*`, orphaned `checked/` marks, results whose blobs are gone).
   - `trim`: evict to the limit now.
   - Safe while another build runs: a build in progress rebuilds what vanished (4).
8. **Warnings:** a build reports when the cache passes its warning size, and what it evicted.

## Work

- **199.1** The cache root as a setting. **Done:** `cache.root`, a build setting: any workspace's `cfg.yaml` may
  set it and only the entry workspace's applies (another workspace's is for its own builds; G18 now holds this
  for every program and build setting); a package or module file, or an `externals:` block, that sets it is an
  error. Absolute, `~/`-relative, or relative to the entry workspace; empty is the platform's directory.
  `NOMU_CACHE_DIR` takes precedence (tests and tools set it per invocation). The toolchain record follows the
  chosen root. Tests: `testCacheRoot` (planner), `testCacheRootSetting` and `testExternalCacheRootIsIgnored`
  (`build_tests`), `testProgramSettingInAnExternalIsIgnored` (config).
- **199.2** Last use and size: blob touches, the `checked/` marks on inode and creation time, the sharded CAS
  with stats files.
- **199.3** Eviction during builds and `trim`; a vanished blob is a miss.
- **199.4** The user configuration file and the `artifacts` pool's settings.
- **199.5** `nomu cache stats|clean|trim`, with `--json`.
- **199.6** The `workspaces` pool, with fetched external workspaces.
- **199.7** Tests: a cache over its limit evicts the least recently used blobs and the next build rebuilds them;
  a build concurrent with `trim` succeeds; stats match a walk of the cache; the sweep holds.

## Open questions

1. Whether `max_age` joins `max_size` for `artifacts`, as Go's build cache trims by age alone.
2. The default size.

## Relationships

- **172** made the store hold every module and link; **198** supplies settings; **193** (compiler performance
  report) reports per-build cache use, this task the cache's state; **217** splits actions, multiplying entries.
