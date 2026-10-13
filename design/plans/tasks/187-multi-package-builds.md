# Multi-package builds — external dependencies, cross-package linkage + seal enforcement

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · needs-design` (build orchestration + a thin
Sema/interface/mangler touch) · **Size:** L · **Status:** in-progress — 187.1 (manifest `dependencies` schema) done; 187.2 (external-import
resolution) next · **Source:** spun out
of [173](173-package-model-driver-cli.md) (the single-package driver + model, built) and
[100](100-modules.md) §100.2.5 (the single-package visibility guard, whose cross-package half lives here).

Task 173 built the package model, manifest, and the `nomu` driver for a **single package**: one `pkg.json`,
`pkg/…` first-party imports resolving by directory, separate compilation per module, link. This task is the
step to **more than one package in a build** — external dependencies, resolving a non-`pkg/` import to
another package's modules, linking across the package boundary, and the visibility machinery that only has
meaning at that boundary (sealing, the `package` tier, package identity in mangled symbols).

## Why its own task (out of 173)

Everything here needs a second package to exist, be reachable, and be testable. In a single-package build
there is no package boundary: an external import never resolves, a sealed module has no outside to be denied
to, and `package`-tier visibility is identical to visible-everywhere. Building the enforcement before the
boundary exists would be unexercisable code. 173 carries the readiness (the manifest schema has `sealed` and
would carry `dependencies`; the mangler has a package-identity slot from 100.4); this task consumes it.

## Deliverable

`nomu build`/`run`/`test` on a package that depends on another package, with the dependency's public API
imported, its objects linked, its sealed modules hidden, and its `package`-tier symbols denied across the
boundary.

## Phases

- 187.1 — **Manifest dependencies.** **Done** (`src/modules:modules_tests` green). The schema carries a
  `"dependencies"` **list of package names** (`Manifest.dependencies` in `src/modules/sources/Manifest.swift`)
  — the allow-list of packages this package's modules may import from, each the dependency's **own package
  name** (the import root token; no aliasing). **No paths or versions in `pkg.json`:** an in-workspace
  dependency is found by its `pkg.json` marker in the workspace tree, and an external dependency's workspace
  is pinned in `nomu.yaml`. The section defaults to empty, so a name-only manifest stays valid
  (dependency-free JSON, as 173.1); a non-string entry (e.g. an object with a path) is a malformed-manifest
  decode error. **Unconsumed until 187.2** resolves imports against it; the name↔target-name match and the
  one-name-one-location consistency check ride the multi-package view (187.2/187.3).
- 187.2 — **Cross-package import resolution (in-workspace).** Resolve a `.package_(name)` import (today
  dropped by `resolvePkgImportDir`, which returns nil for non-`pkg/`): check `name` is in the importer's
  `pkg.json` `dependencies` allow-list (strict), look it up in the workspace's **name→package-dir map** (built
  by scanning the tree for `pkg.json` markers — a divergent/duplicate name is a consistency error), then pick
  the module inside it (its `default-module` for a bare package name, a submodule by path) — the cross-package
  analogue of `pkg/…` resolution. A module graph now spans packages; each node carries its owning package
  identity. Needs a minimal workspace-root + marker scan (couples with 187.5). External-workspace resolution
  (a no-marker dependency name → a `nomu.yaml` pin) is the deferred increment; until then such a name errors.
- 187.3 — **Cross-package linkage.** Compile a dependency package's modules to objects + `.nmi` (separate
  compilation, already per-module), then compile the consumer against the dependency's interfaces and link
  the dependency objects in. Package identity enters mangling here — fold it into the `Mangle.qualifier`
  (the package-identity slot carried forward from 100.4), so two packages exporting the same module/symbol
  name stay distinct. Build order is the package dependency DAG (acyclic; a cycle is an error).
- 187.4 — **Seal enforcement + the `package` tier across the boundary** (from 173.3 / the multi-package half
  of 100.2.5). A sealed module (manifest `sealed`) is importable only from within its own package — a
  foreign import is rejected with a clear diagnostic. `package`-tier visibility reaches siblings in the same
  package but not a foreign package: emit `package` symbols into the `.nmi` **tagged with their visibility**,
  and have a consumer admit a `package` (or sealed-module) symbol only when it shares the producer's package.
  The single-package signature-consistency guard (100.2.5) already stands; this closes the cross-boundary
  half. (White-box `test import` already widens to internal/package within a build — 173.5.4; its
  interaction with a foreign package's sealing is defined here.)
- 187.5 — **Workspace section** (deferred from 173.2). The repo-root `nomu.yaml` gains contents: the
  **external dependency pins** — one version + source per external *workspace*, workspace-wide. In-workspace
  packages are **not** listed (discovered by markers, 187.2); `nomu.yaml`'s job is the external registry (and
  possibly the build/test root set). Today it is a bare marker. The minimal workspace-root resolution to
  anchor the marker scan is pulled forward into 187.2; this phase adds the external-pin schema when
  external resolution lands.
- 187.6 (tests) — A two-package fixture: consumer imports a dependency, builds, links, runs; a sealed
  dependency module is import-rejected; a `package`-tier symbol is denied across the boundary and admitted
  within; same-named symbols in two packages coexist (mangler identity). These are the cases 173.7 could not
  construct without a second package.

## Design decisions

**Package role (decided).** The **workspace** is the unit of versioning + external consumption; the
**package** is encapsulation + identity only. A package's reason to exist is the mid-tier `package`
visibility (share internals among a library's modules while hiding them from the world) — the thing a
module (too small, would leak) and the workspace (too big, no encapsulation) cannot provide. It is not a
versioning or distribution unit; a repo is consumed as a whole workspace.

**Dependency format (decided).**

- **`pkg.json` is the per-package allow-list.** A `dependencies` **list of package names**: the packages
  this package's modules may import from. Imports are **strict / non-transitive** — a module may import only
  packages its `pkg.json` declares; a dependency's own dependencies are invisible unless re-declared.
- **Entries are package names.** Each name is the depended-on package's canonical `name`, which is the root
  token at the import site (`import libfoo/bar`). No per-importer aliasing — identity is workspace-unique.
- **No paths or versions in `pkg.json`.** An in-workspace dependency is **discovered**, not declared: the
  workspace finds the package whose `pkg.json` marker has that name (scan the tree → name→dir map, like
  Bazel discovering in-repo packages by their BUILD files). A divergent name (two subtrees, same name) is a
  workspace consistency error.
- **Versions + external sources are workspace-wide, in `nomu.yaml` only.** The unit of external consumption
  is another repo's **workspace**, pinned to one version + source there; one version per external workspace
  across the whole workspace (single-version — avoids the diamond problem; the Bazel stance). A consumed
  external workspace is self-describing (its own `nomu.yaml` + markers define its packages). In-workspace
  packages are at repo HEAD, so they carry no version.
- **Near-term scope.** In-workspace dependencies (marker discovery) first; external-workspace resolution,
  registry/git sources, and the lockfile ride later (fold with 163 YAML).

**Linkage + visibility (to settle in build).**

- **Package identity in the mangler.** Reuse the 100.4 `Mangle.qualifier` package-identity slot rather than
  inventing a new scheme; the module-path home-qualifier stays, now prefixed by package identity.
- **`sealed` semantics.** Sealing is module-level and manifest-declared (like test identity), gating only
  the cross-package import — within the package a sealed module is a normal module.

## Dependencies & triggers

- **Rides:** [173](173-package-model-driver-cli.md) (the package/manifest/driver layer + the shared
  resolver), [100](100-modules.md) 100.4 (separate compilation + per-module objects + the mangler
  package-identity slot), the `.nmi` sectioned interface (164.4).
- **Feeds:** [174](174-prelude-as-packages.md) (prelude/`std` as real packages consumed cross-package),
  [182](182-cross-module-inlining.md) (cross-module inline extends across the package boundary too),
  [172](172-incremental-build-cache.md) (a dependency package is a natural cache unit).
- **Interacts with:** [163](163-manifest-yaml.md) (JSON → YAML, where `dependencies` grows a lockfile),
  [161](161-test-framework.md) (test-only dependencies isolated from the production build).

## Refs

[`../../language/modules.md`](../../language/modules.md) (the programmer surface + compilation model;
§Visibility, §First-party addressing, §Tests); [173](173-package-model-driver-cli.md) §173.3 / §173.2
(the spun-out seal + workspace design); [100](100-modules.md) §100.2.5 (the single-package guard this builds
the cross-package half of); `src/modules/sources/{Manifest,ModuleGraph}.swift`,
`src/driver/sources/Driver.swift` (`resolveModule` / the discovery loop / `findPackageRoot`).
