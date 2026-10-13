# Multi-package builds — external dependencies, cross-package linkage + seal enforcement

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · needs-design` (build orchestration + a thin
Sema/interface/mangler touch) · **Size:** L · **Status:** in-progress — 187.1 (manifest `dependencies` schema) + 187.2 (the resolver core:
workspace registry + `.package_` resolution, unit-tested) + 187.3 (cross-package linkage + graph-spanning
with workspace-relative identity in mangling, the package-level DAG check, and the strict allow-list) + 187.4
(the visibility boundary: `products` schema, the product import gate, the `package` tier across the boundary,
the `public`⟺product hard error, and `test import` same-package-only) + 187.6 (the multi-package test
fixtures) done, suite 143/143. **The in-workspace multi-package deliverable is complete.** 187.5
(external-workspace support) is **deferred out of this task** — external workspaces (registries, dependency +
version resolution, ecosystem) are a separate future effort, with **multi–local-workspace builds** as an
intermediate task before it (sidesteps registries/versioning) and real dependency management much later ·
**Source:** spun out
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
- 187.3 — **Cross-package linkage + graph-spanning.** **Done.** The 187.2 resolver is wired into the
  driver's discovery loop (and `query`), so the module graph spans packages: a `.package_(name)` import
  builds the workspace registry lazily, enforces the strict allow-list (the importer's package must list
  `name` in its `dependencies`), resolves to the dependency module's directory, and adds it to the graph +
  parse worklist. Each module carries a `ModuleHome` (its package root + name + declared deps), so `pkg/…`
  resolution and the allow-list are correct per package. Module identity is now **workspace-relative** (keyed
  off the `nomu.yaml` root), so two packages with a same-named module never collide in the graph, the
  `build/` intermediates, or the symbols. Mangling folds the canonical identity in lockstep — the
  `Mangle.qualifier` and the consumer-side `origin@name` encoding both use `workspace-name` + the module's
  workspace-relative path (via the driver's `mangleOrigin`), so a dependency's `homeQualifier` and the
  consumer's external declaration resolve to the one symbol. A dependency package's modules compile to
  home-qualified objects + `.nmi` (separate compilation, already per-module), the consumer compiles against
  those interfaces and links their objects. **Package-level dependency cycles are forbidden** — the
  inter-package `dependencies` graph must be a DAG (`packageDependencyCycle`), a rule distinct from (and
  stronger than) the module-import-cycle check: `P` → `Q` → `P` is an error even when no single module cycle
  exists. Tests (in-suite): `multipackage-basic` (consumer imports a dependency, links, runs),
  `multipackage-undeclared` (allow-list rejection), `multipackage-cycle` (a package-only cycle, no module
  cycle). The `nomu.yaml` `name:` is read minimally here (the 187.5 field pulled forward); full external
  `.nmi` identity threading rides 187.5.

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
  half of 100.2.5). In progress. **The `Manifest` schema flip is done:** `sealed` (opt-out) → `products`
  (opt-in list, default package-internal), in `src/modules/sources/Manifest.swift` with
  `ManifestTests.swift` green. **The product import gate is done:** `resolveImport` (Driver.swift) matches a
  cross-package import's targeted module against the target package's `products` (the module's
  package-relative path; `""` for a single-module package's root) and rejects a non-product with a clear
  diagnostic — tested by `multipackage-nonproduct` (declared dependency, no products → rejected). Same-package
  (`pkg/…`) imports are never gated. **The `package` tier across the boundary is done:** each interface
  decl is tagged with its visibility (`InterfaceFunc`/`Type`/`Enum`/`Protocol` gained a `visibility` field),
  `buildInterface` ships `public` + `package` (and `internal` for a white-box test target), and the driver
  admits a producer decl per consumer — `public` to anyone, `package` only to a same-package consumer
  (`sharePackage`), `internal` only to a `test import`er — filtering `externals`, `moduleFuncs`/`moduleTypes`,
  and `externalMutating` through `admittedInterface`. Generic `package` symbols cross too: `shippedTemplates`
  / `selectForDial` ship + select exported (`>= .package`) generics, and `Monomorphize` emits the erased
  compiled-once symbol for a `package` generic (not just `public`), so a same-package consumer links it.
  Proven by `multipackage-package-hidden` (a product module's `package` symbol is invisible to a foreign
  package: "module 'lib' has no member 'secret'"). **The `public`⟺product hard error is done:**
  `checkVisibilityConsistency` takes `isProduct` (the module's package-relative path ∈ its package's
  `products`) and rejects a `public` decl in a non-product module — tested by `module-public-nonproduct`.
  The full fixture sweep landed with it: every single-package `module_*`/`erased_*` fixture's internal
  `public`→`package` (the multipackage product libs stay `public`). **`test import` same-package-only is
  done:** a `test import` resolving across a package boundary (a `.package_` root) is a discovery-time error
  (`crossPackage != nil`), so white-box widening never crosses a package — tested by
  `multipackage-testimport-foreign`; a same-package `test import` (`pkg/…`) still grants white-box
  (`module-test-import`). **187.4 is complete, suite green at 142/142.** **Module publicness is opt-in via
  manifest `products`**: a module is importable from
  outside its package only if it is a product. The coupling
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
- 187.5 — **External-workspace support. Deferred out of this task** (a separate future effort). Pulling an
  *external* workspace in drags the whole dependency-management problem — registries, dependency + version
  resolution, source kinds (registry/git/path), a lockfile, and ecosystem concerns — which is out of scope
  here; 187's goal is multi-package builds **within one workspace**, which 187.1–187.4 deliver. The sequencing
  decided: **multi–local-workspace builds** come first as an intermediate task (one repo consuming another
  by local path — this sidesteps registries and version resolution while still exercising cross-workspace
  linkage: an external module's symbols carry *its* workspace name, so the `.nmi` must then carry each
  module's full identity, the one piece 187.3 left for here), and **real dependency management** much later.
  The `nomu.yaml` `name` is read minimally today (187.3); its formalization + the external-pin/alias schema
  ride those future tasks, folded with the YAML move ([163](163-manifest-yaml.md)). Nothing external is built
  now.
- 187.6 — **Multi-package test fixtures. Done.** The cases that need a second package, all in the suite:
  `multipackage-basic` (consumer imports a dependency, builds, links, runs), `multipackage-undeclared`
  (strict allow-list), `multipackage-cycle` (the package DAG), `multipackage-nonproduct` (the product import
  gate), `multipackage-package-hidden` (a `package`-tier symbol denied across the boundary; admitted within
  via `module-qualified`/`module-method`), `multipackage-testimport-foreign` (`test import` same-package
  only), `multipackage-coexist` (same-named symbols in two packages coexist — mangler identity), and
  `module-public-nonproduct` (the `public`⟺product hard error).

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

**Compilation unit & separate compilation — the evolution invariant (decided).** The **module** is the
compilation unit, and the end state is one module per `nomu compile` subprocess, with an external driver
(Bazel, then a mini-Bazel CAS) building the module graph and invoking each compile independently. Two
invariants protect that evolution; anything built here must hold them:

- **No producer compilation state crosses to a consumer in memory — only on-disk, canonical outputs.** A
  consumer learns a producer's ABI, perf facts, generic templates, and object only from files the producer
  wrote (`.nmi` = `abi` + `perf`, `.bir`, `.o`). Today the whole-graph-in-one-process driver still holds a
  producer's `ModuleInterface`/escape summary **in memory** (`interfaces[k]`, `depEscape[k]`) and does not
  write a dependency's `.nmi` in a normal build — a pre-existing property (100.4). This is **tolerated as an
  in-process optimization only** because every datum it passes already has its on-disk form; the
  subprocess-split task replaces the in-memory reads with on-disk `.nmi` reads (no format work needed). Do
  not introduce a cross-module datum that has no on-disk representation.
- **Symbol identity is a pure function of a module's canonical identity, derivable from disk alone.** The
  producer and the consumer each compute a symbol from `workspace-name` + the module's workspace-relative
  path (the driver's `mangleOrigin`) — no coordination, no reading the producer's symbol out of its
  in-memory interface. This is what lets two independent subprocesses agree on a link name. Physical-path
  identity is CAS-compatible: the path is a stable hashed input, so the same content at the same path
  (across commit switches) yields the same symbol and the same digest → a cache hit. The cross-workspace
  case (187.5) is the one place a consumer cannot recompute a producer's `workspace-name` (a foreign
  workspace), so the `.nmi` must then carry the producer's full canonical identity — an additive field.
- **Producer outputs are reached through one location function.** `modArtifactStem(id)` + the build root is
  the single "where does this module's output live" map; the mini-Bazel CAS swaps it for a digest→content
  fetch without touching callers. Keep it the only such map.

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
