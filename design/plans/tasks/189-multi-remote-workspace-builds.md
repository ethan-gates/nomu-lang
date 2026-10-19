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

## Decided — workspace identity

The goal: any two workspaces that are the same project are recognized as duplicates, whatever their version
or content hash and however they were fetched (git, tarball, local path, the same commit by two routes).

- **Identity is declared by the workspace: `scope` + `name`.** Both live in the workspace's own `nomu.yaml`,
  both follow the path-component rule `[a-z][a-z0-9_]*`, and both are required. Every route to a workspace
  reads the same two fields, so identity is independent of source, version and content. Two workspaces with
  one `scope`/`name` pair are the same project. A source-derived identity (Cargo's hash of name, version and
  source) was rejected: one project pinned by two routes gets two identities and links twice. A content
  hash was rejected: it differs across versions and changes on every edit. A generated ID was rejected:
  opaque wherever it is read.
- **The scope stays out of sight.** Consumers never type it: imports name packages, pins name sources, and
  the planner reads the scope from the producer. It appears in mangled symbols (`<scope>.<name>` as the
  workspace prefix), in `build/_external/<scope>.<name>/`, and in diagnostics only when two workspaces in a
  build share a `name`.
- **Choosing the scope.** `nomu init` proposes a default (e.g. the user's handle) and asks the owner to
  confirm it, stating the consequence: the scope is part of the project's identity, and changing it later
  makes the project a different one to every consumer (every symbol changes and old versions stop matching).
- **Aliases are local.** A consumer's alias for a workspace renames it only in that consumer's imports;
  identity and symbols never derive from an alias.
- **Only the root workspace pins by local path.** A root path pin is an override: it replaces every other
  route to that identity in the graph. A non-root workspace pins only remote sources.
- **Content hashes check integrity.** The lockfile records each pinned snapshot's hash; it confirms that a
  fetch delivered the expected bytes and plays no part in identity.
- **Uniqueness of scopes is unmanaged for now.** Two unrelated projects claiming one `scope`/`name` are
  indistinguishable from one project; the root's pins and lockfile decide which source is trusted for an
  identity. Who allocates scopes (a registry, or none) is decided with the registry question.

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
