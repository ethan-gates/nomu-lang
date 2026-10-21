# Cache management — clear, metrics and configuration for the build caches

**Avenue:** Infra · **Type/Lifecycle:** `driver · cli · needs-design` · **Size:** M · **Status:** needs-design
· **Source:** 190.6 F5 and F10: clearing the host cache by hand (`rm -rf ~/Library/Caches/nomu`) is the
remedy for stale entries, and nothing reports or bounds what the cache holds.

## Deliverable

A way for users to manage Nomu's build caches: clear them, see what they hold and how well they serve
builds, and configure their limits. Most likely a `nomu` subcommand; its shape is open.

## What the caches hold today

The per-host cache ([190](190-explicit-module-builds.md) D4) at `NOMU_CACHE_DIR`, else
`~/Library/Caches/nomu/` (macOS) or `$XDG_CACHE_HOME/nomu/` / `~/.cache/nomu/` (Linux):
- `runtime/` — the runtime archive, keyed by the runtime sources, architecture and recipe.
- `nomu/<key>/` — the language workspace's compiled modules (`core`, `runtime`, `std/*`), one directory per
  key (embedded sources, compiler identity, host target, options).
- `source/` — the one on-disk copy of the embedded sources, for reporting (190.6 F10).
- Leftovers: `.staging-*` and `.source-*` directories from interrupted builds.

Nothing evicts: every compiler or embedded-source change adds a `nomu/<key>/` entry, and old ones stay.
[172](172-incremental-build-cache.md) adds a module store with many more entries.

## Goals

- **Clear.** Remove everything, or one part (the module store, the language workspace's entries, the
  runtime archive, stale or leftover entries). Safe while another build runs: a build in progress keeps
  working or fails with a clear message, and never links a half-removed entry.
- **Metrics.** Size and entry count per part; age and last use of entries; hits and misses per build (with
  [193](193-compiler-performance-report.md), the compiler performance report); a machine-readable form for
  tooling.
- **Configuration.** Location, maximum size, warning size, and the eviction policy applied when the maximum
  is reached (least recently used is the likely default). Settings come through the configuration system of
  [198](198-build-configuration.md); `NOMU_CACHE_DIR` becomes one of its settings.
- **Warnings.** A build reports when the cache passes its warning size, and what it evicted when it passed
  the maximum.

## Open questions

1. The command's shape: `nomu cache clear|stats|config`, or flags on existing commands, or both.
2. Where cache settings live: user-level configuration, workspace, or both (with 198).
3. How last use is recorded cheaply (access times are unreliable on many file systems; a per-entry stamp
   or an index).
4. Eviction timing: during a build (bounded work) or only on command.
5. Whether `build/` outputs ([172](172-incremental-build-cache.md) may make them views onto the store) are
   in scope.

## Relationships

- **172** (incremental build cache) designs the store this manages; its open question on eviction and
  cache-size governance is shared with this task.
- **198** (build configuration) supplies the settings.
- **193** (compiler performance report) reports per-build cache use; this task reports the cache's state.
- **190** D4 defined the per-host cache; F5 (stale entries until 172 settles the compiler identity) and
  F10 (the source copy) are why clearing matters today.
