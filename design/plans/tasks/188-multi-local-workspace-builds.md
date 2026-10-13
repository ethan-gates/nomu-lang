# Multi–local-workspace builds — cross-workspace linkage by local path

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · needs-design` (build orchestration + a mangling/
`.nmi` identity touch) · **Size:** M–L · **Status:** not-started · **Source:** split out of
[187](187-multi-package-builds.md) §187.5 — the deferred external-workspace half, sliced to the part that
sidesteps dependency management.

## Deliverable

One workspace consuming **another workspace by local filesystem path** — no registry, no version
resolution, no fetching. `nomu build/run/test` on a workspace whose `nomu.yaml` pins an external workspace
at a local path, with that workspace's products imported, its objects linked, and its symbols carrying
**its own** workspace name.

## Why its own task (out of 187)

187 delivers multi-package builds **within one workspace**, where every module shares one workspace name, so
the workspace-name segment of a symbol's canonical id is a constant the consumer recomputes locally
([187](187-multi-package-builds.md) §187.3). Crossing a workspace boundary is the first time a consumer
references symbols mangled under a **foreign** workspace name — which forces the one piece 187.3 deliberately
left undone: **the `.nmi` must carry each module's full canonical identity** (workspace name + workspace-
relative path), and the driver must thread a **per-module** workspace identity rather than the single
build-wide name it assumes today. A local path source exercises all of that **without** the dependency-
management problem (registries, version/dep resolution, lockfiles) — that is [189](189-multi-remote-workspace-builds.md).

## Scope

- **`nomu.yaml` local-path external pins.** A workspace declares `name → local path` for each external
  workspace it consumes. Rides the YAML move ([163](163-manifest-yaml.md)); until then, a minimal reader
  (extending the `name:` line-read already in the driver). No version/source beyond a path.
- **`.external(name)` resolution.** The 187.2 resolver's deferred `.external` branch resolves to the pinned
  workspace's package registry (`scanWorkspacePackages` over that workspace's tree), then to a product
  module — the same product gate and allow-list as in-workspace, now across the boundary.
- **Per-module workspace identity (the `.nmi` piece from 187.3).** A module's `ModuleHome`/identity carries
  its owning workspace name; `mangleOrigin` uses the **producer's** workspace name (read from the external
  workspace's `nomu.yaml`, and persisted into the `.nmi` so a separately-compiled external links identically).
  This is what makes "workspace name always present so a workspace's objects link into another as an
  external" ([187](187-multi-package-builds.md) §187.3) actually load-bearing.
- **External-workspace aliasing.** A consumer may bind an external under a local alias, so two unrelated
  external workspaces sharing a `name` coexist without a flat-namespace clash (prior art: Cargo `package =`
  rename, Swift `moduleAliases`). The alias rewrites only the local import root; identity stays the
  producer's own name.
- **Separate-compilation discipline.** A local external is a natural point to honor the 187 evolution
  invariant (producer→consumer handoff is disk-only `.nmi`/`.bir`/`.o`): an external workspace may already be
  compiled, so the consumer reads its outputs, not its source. (Full subprocess/CAS split is its own effort.)

## Non-goals (→ [189](189-multi-remote-workspace-builds.md))

Registries, git/tarball sources, version constraints + dependency resolution, a lockfile, fetch/cache +
integrity. A local path is a single, already-present workspace, so none of that applies.

## Dependencies & triggers

- **Rides:** [187](187-multi-package-builds.md) (in-workspace multi-package: the resolver, the graph span,
  the mangling, the visibility boundary), [163](163-manifest-yaml.md) (the pin schema in YAML),
  the `.nmi` sectioned interface (164.4, extended to carry full identity).
- **Feeds:** [189](189-multi-remote-workspace-builds.md) (remote sources reuse the cross-workspace linkage
  mechanics; they add only fetching + version resolution on top).

## Refs

[187](187-multi-package-builds.md) §187.3 (workspace-relative identity; the deferred full-`.nmi`-identity
note), §187.5 (the deferral rationale); `src/modules/sources/WorkspacePackages.swift` (the resolver, the
`.external` branch); `src/driver/sources/Driver.swift` (`mangleOrigin`, `ModuleHome`, `resolveImport`).
