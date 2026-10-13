# Multi-package builds — external dependencies, cross-package linkage + seal enforcement

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · needs-design` (build orchestration + a thin
Sema/interface/mangler touch) · **Size:** L · **Status:** in-progress — 187.1 (manifest `dependencies` schema) + 187.2 (the resolver core:
workspace registry + `.package_` resolution, unit-tested) done; 187.3 (cross-package linkage + graph-spanning
with package-aware mangling) next · **Source:** spun out
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
- 187.2 — **Cross-package import resolution — the resolver core.** **Done** (`src/modules:modules_tests`
  green). The reusable machinery in `src/modules/sources/WorkspacePackages.swift`: `scanWorkspacePackages`
  builds the workspace **name→package-dir registry** by scanning the tree for `pkg.json` markers (packages
  do not nest, so a marker is a leaf; a nested workspace — a subtree with its own `nomu.yaml` — is a pruned
  boundary; a duplicate package name is a `WorkspaceError` consistency error). `resolvePackageImport` takes a
  `.package_(name)` import, the importer's declared deps, and the registry, and returns `.module(dir)` /
  `.notDeclared` (strict allow-list) / `.external` (declared but not in-workspace — deferred) / `.noModule`;
  a bare name forwards to the package's `default-module` (or its root module), a path names a submodule.
  Unit-tested with temp workspaces (registry build, duplicate-name error, nested-workspace pruning, strict
  rejection, default/submodule resolution, external, missing module). **Wiring into the compile graph and
  `query` (a graph that spans packages, keyed by workspace-relative identity) rides 187.3** — it needs the
  package-aware mangling that makes cross-package symbols collision-free, so the resolver ships first (the
  187.1→187.2 shape: infra consumed by the next phase).
- 187.3 — **Cross-package linkage + graph-spanning.** Wire the 187.2 resolver into the driver's discovery
  loop (and `query`) so the module graph spans packages, then fold the full identity into mangling so
  cross-package (and cross-workspace) symbols never collide. Compile a dependency package's modules to
  objects + `.nmi` (separate compilation, already per-module), compile the consumer against the dependency's
  interfaces, and link the dependency objects in. **Package-level dependency cycles are forbidden** — the
  inter-package `dependencies` graph must be a DAG, a rule distinct from (and stronger than) the existing
  module-import-cycle check: `P` depends on `Q` and `Q` on `P` is an error even when no single module cycle
  exists (the Rust/Go rule; it keeps per-package separate compilation and future caching sane). Build order
  is that package DAG. The `build/` `__mod_*` intermediates are already keyed workspace-relative (173/187
  build-root fix).

  **Symbol identity — decided.** A mangled symbol's canonical identity is three parts:
  `<workspace-name> :: <workspace-relative-module-path> :: <decl-signature>`, where the signature eventually
  encodes the base name + each param's **label and type** + generic args (+ the receiver type for a method),
  since overloading is **by type and label**. **187.3 implements only `workspace + module-path + name`** —
  Nomu has no overloading yet, so there is nothing to disambiguate; the label+type signature is added by the
  parameter-labels task ([112](112-param-labels-args.md)) when overloading lands (a localized `Mangle`
  change, full rebuild, no external-ABI cost). Properties:
  - **Workspace name is always included**, even for a single-workspace build — that is what makes a
    workspace's objects safe to link into *another* workspace as an external. Prelude/runtime symbols are
    the exception: they belong to the language, not a workspace, so they keep bare names and fold via
    weak-ODR.
  - **Identity is physical (workspace-relative path), not logical (package name).** Moving a package's
    directory changes its symbols → a full rebuild, accepted (incremental-cache misses on a move are rare).
  - **Full, readable, demanglable names — no hash.** The symbol *is* the canonical id. The id is unique by
    construction (workspace names unique per build via aliasing; the single-version rule means no two
    versions of a workspace coexist), so no disambiguator hash is needed — unlike Rust/Go, whose
    multi-version support forces one. Long symbols (heavy monomorphization) cost binary **size + link time**,
    never runtime (a static binary resolves to addresses; the runtime dispatches through pointers and keys GC
    off type-ids, not names); the size cost is handled by **stripping the release binary** (names live in a
    separate debug file). A demangler is trivial (the symbol parses back to the id) and rides the
    debugger/crash-trace work ([138](138-debugger.md)).

  The mechanical move: the home-qualifier and the consumer-side origin encoding (both package-relative
  today — `Mangle.qualifier(module: id.components)` and the `origin.split("/")` sites in `SSAIRToLLVM`) go to
  the three-part key in lockstep (the `Mangle.qualifier` package-identity slot carried from 100.4).
- 187.4 — **Products enforcement + the `package` tier across the boundary** (from 173.3 / the multi-package
  half of 100.2.5). **Module publicness is opt-in via manifest `products`** (replacing the old `sealed`
  opt-out — a schema flip in `Manifest`): a module is importable from outside its package only if it is a
  product; a foreign import of a non-product module is rejected with a clear diagnostic. The coupling
  invariant is enforced here: a `public` symbol is allowed **only inside a product module**, and a `public`
  in a non-product module is a **hard compile error** (steer to `package`, or add the module to products) —
  so a stray `public` can never leak a module. Consumers reach a product **by path** (`import <pkg>/<prod>`);
  products gate permission, never identity (no alias), so depending stays pathing. `package`-tier visibility
  reaches same-package siblings but not a foreign package: emit `package` symbols into the `.nmi` **tagged
  with their visibility**, and have a consumer admit a `package` symbol only when it shares the producer's
  package. The single-package signature-consistency guard (100.2.5) already stands; this closes the
  cross-boundary half. **White-box `test import` is restricted to modules in the same package** — a test
  module may widen into its own package's internals (173.5.4) but never into another package's; a
  cross-package import is always black-box, so a package's encapsulation holds even against a foreign test.
- 187.5 — **Workspace section** (deferred from 173.2). The repo-root `nomu.yaml` gains contents:
  - A required **`name`** — the workspace's identity. It is the first segment of every symbol's canonical id
    (187.3), and the handle a consumer pins an external workspace by. (New field; today `nomu.yaml` is a bare
    marker. A minimal name read is pulled forward into 187.3, since mangling needs it.)
  - The **external dependency pins** — one version + source per external *workspace*, workspace-wide (the
    single-version rule). In-workspace packages are **not** listed (discovered by markers, 187.2).
  - **External workspace aliasing** (deferred, lands with external support). A consumer may bind an external
    workspace under a local alias, so two unrelated external workspaces that happen to share a `name` can
    both be used without a flat-namespace clash (prior art: Rust Cargo `package =` rename, Swift
    `moduleAliases`). Small; it rides whenever external-workspace pulling is built.
  - Possibly the build/test root set. The minimal workspace-root resolution to anchor the marker scan is
    pulled forward into 187.2; this phase adds the external-pin + alias schema when external resolution lands.
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

**Module visibility (decided) — products, not seal.**

- **Opt-in via `products`.** A package lists its public modules (`products`) in the manifest; the default is
  package-internal. This **replaces the `sealed` opt-out** (a schema flip in `Manifest` — `sealed` → an
  opt-in list), so the default is encapsulated and one mechanism covers it. A module is importable from
  outside its package only if it is a product.
- **`public` ⟺ product, enforced (hard error).** A `public` symbol is allowed only inside a product module;
  a `public` in a non-product module is a compile error (steer to `package`, or add the module to products).
  Exposing a module is two deliberate acts — mark the symbol `public` *and* list the module as a product —
  so a stray `public` cannot leak an internal module, and `public` always means "external API."
- **Consumers path.** `import <package>/<product>`: products gate *permission*, never *identity* (no alias,
  no rollup), so depending stays pathing and the path names the module unambiguously. Importing a non-product
  module is an error.
- **`package` is the in-package tier** (essential), declared locally in source — the level a non-product
  module's shared symbols use.

**Symbol identity + mangling (decided).**

- **Three-part canonical id:** `<workspace-name> :: <workspace-relative-module-path> :: <decl-signature>`,
  signature encoding base name + param labels + param types + generic args (+ receiver type for methods),
  since overloading is by type **and** label. Reuses the 100.4 `Mangle.qualifier` slot, widened to the full
  key.
- **Workspace name always present** (so a workspace's objects are linkable as an external anywhere); prelude/
  runtime symbols excepted (language-owned, bare, weak-ODR-folded).
- **Physical identity** (workspace-relative path): moving a package's directory is a full rebuild — accepted.
- **Full demanglable names, no hash.** The symbol is the id, unique by construction (workspace names unique
  per build via aliasing; single-version rule → no coexisting versions), so no disambiguator is needed.
  Long symbols cost size + link time, never runtime (static binary; runtime dispatches by pointer, keys GC
  off type-ids); mitigated by stripping to a separate debug file. Demangler rides [138](138-debugger.md).
- **External workspace aliasing** (deferred to external support, 187.5) covers two externals sharing a
  `name`.

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
