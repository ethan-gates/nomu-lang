# Multi–remote-workspace builds — real dependency management

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · needs-design` (a whole dependency-management
subsystem) · **Size:** XL · **Status:** not-started (design-early) · **Source:** split out of
[187](187-multi-package-builds.md) §187.5 — the full external-workspace / ecosystem half.

## Deliverable

External workspaces pulled from **remote sources** — a consumer declares a dependency on another workspace
by name + version + source, and `nomu` resolves, fetches, pins, caches, and links it. The package-management
layer: registries, version resolution, a lockfile.

## Why its own task (out of 187 / 188)

[188](188-multi-local-workspace-builds.md) builds the cross-workspace **linkage** mechanics (foreign
workspace name in symbols, `.external` resolution, per-module identity, aliasing) against a local path — no
fetching, no versioning. This task adds the **dependency-management** layer on top: where an external
workspace comes from, which version, and how that is made reproducible. That is a large, design-heavy
subsystem (the Cargo/Go-modules/Bazel-external problem) and deliberately the **last** rung — the language
and in-workspace builds do not depend on it.

## Scope (design-early — to be fleshed out when taken on)

- **Source kinds.** Registry, git (rev/tag), tarball/URL, with integrity (content hash) on each.
- **Version + dependency resolution.** Constraints per external workspace, resolved to one version — the
  **single-version rule** decided in [187](187-multi-package-builds.md) (one version per external workspace
  across the whole build; the diamond is a resolve error, the Bazel stance), so resolution is selection, not
  per-consumer duplication.
- **Lockfile.** A resolved, hashed pin set, committed for reproducibility; `nomu.yaml` carries the
  constraints, the lockfile carries the resolution.
- **Fetch + cache.** A content-addressed local cache of fetched workspaces (a natural fit with the planned
  mini-Bazel CAS); offline/vendored mode.
- **Trust / integrity / supply chain.** Hash pinning, and whatever verification the ecosystem needs.

## Non-goals

A package **registry service** itself (publishing, hosting, search) is separate infrastructure, not this
compiler task — this task is the client side (consume + resolve + verify).

## Dependencies & triggers

- **Rides:** [188](188-multi-local-workspace-builds.md) (the cross-workspace linkage mechanics it reuses
  wholesale), [163](163-manifest-yaml.md) (YAML for constraints + lockfile), the mini-Bazel build-cache work
  (the fetch cache is the same CAS).
- **Interacts with:** [172](172-incremental-build-cache.md) (a fetched workspace is a cache unit),
  [161](161-test-framework.md) (test-only dependencies).

## Refs

[187](187-multi-package-builds.md) §187.5 (the deferral + the single-version rule),
[188](188-multi-local-workspace-builds.md) (the linkage layer this builds on).
