# Modules & packages — the contract

What a Nomu author can rely on for structuring code across files, modules, and packages: naming,
imports, visibility, layout, initialization, and tests. The build model (separate compilation with a
specialization dial) is resolved; see [Compilation model](#compilation-model) at the end and task
[100](../plans/tasks/100-modules.md).

Status tags: **Decided** · **Leaning** · **Deferred** · **Open**. Design detail and rationale for
open items live in task [100](../plans/tasks/100-modules.md).

## Model — two levels

**Decided.** Two units, at different granularities:

- **Package** — the named **encapsulation + identity** unit: a group of modules forming a library, carrying
  a manifest, that shares internals among its own modules (the `package` visibility tier) while presenting a
  curated `public` surface (its declared products). It is the boundary for visibility, and the name an
  import resolves to. Its reason to exist is this mid-tier encapsulation: a **module** is too small
  (one module cannot share a hidden symbol with a sibling module without making it `public` to the world),
  and the **workspace** is too big (no encapsulation at all). A package earns its keep exactly when a
  multi-module library has internal-but-shared modules; absent that, it is only a namespace.
- **Module** — a directory of source files, the compilation unit. Addressed by its path relative to
  the package source root. A module's identity is `package + relative path`, so `a/util` and `b/util`
  are distinct.
- **Workspace** — the repo (`nomu.yaml`): the unit of **versioning and external consumption**, above the
  packages. It pins external dependencies (one version per external *workspace*, workspace-wide). In-workspace
  packages are discovered by their markers, not listed here. (Versioning/distribution lives here, not on the
  package — the package is encapsulation + identity only.)

This is Go's package/module split (its "module" is our package, its "package" is our module) with
Rust-style origin-hiding (a package is referenced by a short local name, not its origin URL), and a
Bazel-style workspace above both as the version/consumption unit. Nested packages are forbidden; a package
tree contains only modules.

## Modules

**Decided.**

- **One directory = one module = one compilation unit**, and **a module is a leaf.** A directory holds
  *either* `.nomu` source (→ it is a module, and has no subdirectories) *or* subdirectories (→ it is a
  pure path-segment container, and has no source) — never both. So no module contains a submodule, and the
  package root is a module only for a single-directory package (source, no subdirectories); a multi-module
  package keeps its root a container whose leaf subdirectories are the modules. Hierarchy (`net/http`) is
  expressed through container path-segments, not through a directory that is simultaneously a module and a
  parent — that dual role is what the leaf rule removes, so a path always names exactly one module.
- **Addressing is mechanical**, derived from the directory path. There is no name→location map and no
  per-module metadata file. The filesystem is the module list.
- **Files within a module share one namespace implicitly.** A symbol in one file is visible to the
  other files of the same module with no import (this is the `internal` default, below). Filenames are
  organizational, not semantic — no filename-based discovery or meaning.
- Modules form an **acyclic graph** (import cycles between modules are rejected), which supplies a
  topological order for initialization and incrementality.

## Imports

**Decided.**

- **Per-file.** Each file declares the external modules it uses. Files in the same module are not
  imported (shared namespace). Import blocks scale with external dependencies, flat as a module grows.
- **Whole-module, wildcard-bare.** `import foo` brings `foo`'s public symbols into scope unqualified.
  `foo.Bar` is available at any use site to disambiguate, where `foo` is the module's **leaf name**.
- **Alias** with `import foo as bar` renames the local qualifier only (`bar.Bar`). It exists for
  collision disambiguation (two imported modules sharing a leaf name) and brevity. It does not rename
  bare symbols or affect consumers.
- **Non-transitive imports.** Importing `B` does not expose what `B` imported. Transitive dependencies
  never leak into scope.
- **Collisions** between bare symbols are resolved by qualifying (`foo.Bar`); a leaf-name collision
  between two modules is resolved by aliasing one.

Same-package imports use the `pkg` root keyword (below); external-package imports name the package.

**The implicit `import std`.** Every file behaves as if it began with an invisible `import std`, which names
the standard library's default module, `std/prelude` (`Option`, `Result`, `String`). Everything else in
`std` is an ordinary explicit import: `import std/math`, `import std/time`. The root `std` always means the
compiler-embedded standard library; it needs no `dependencies` entry. The package names `std` and `pkg` are
reserved: a user package named either is a compile error. A file that writes `import std`
itself (to alias it) uses that import in place of the implicit one. The implicit import is the whole
mechanism, so prelude names follow the normal import rules (`std.Option` qualifies), and moving a decl in or
out of the prelude is moving it between `std` modules (task [174](../plans/tasks/174-prelude-as-packages.md) §174.3.2).

**`std` is the gateway to the embedded library.** The implicit `import std` is the only implicit import. The
embedded `core` package holds what depends on compiler internals (`ManagedBuffer`, whose tail allocation and
operations are compiler intrinsics), so that `std` stays ordinary Nomu with as little magic as possible.
Only `std`'s modules may import `core`; elsewhere `import core` is a compile error (unless the importing
package lists a package of its own workspace named `core` in its `dependencies`, which the import then names). A user reaches anything in `core` through `std`.

**Leaning.** Type-directed resolution of a bare-name clash (Swift-style) is the intended model, and it
depends on keeping expression-level inference cheap — see [Type inference dependency](#type-inference-dependency).

## First-party addressing

**Decided.** Within a package, a module imports a sibling with the reserved root keyword **`pkg`**:
`import pkg/util/parse`. `pkg` resolves to the package whose manifest encloses the importing file.
Rename- and extraction-safe (internal imports never name the package), no self-name repetition, no
`super`/`self`-relative navigation.

External packages are named by their own package name (no per-importer aliasing): `import foo/parse`
targets the module `parse` in package `foo` — which must be one of `foo`'s products (§Visibility). Bare
`import foo` resolves to the package's **default module** — the module the manifest designates
(a single-directory package's sole module is its implicit default). A package that designates no default
has no bare name: `import foo` is an error and callers name a submodule (`import foo/parse`). The same
default-module forwarding governs a bare package path given to `build`/`run`/`test`.

## Visibility

**Decided.** Four symbol tiers, declared in source on the declaration:

- `private` — visible in its file only.
- `internal` — visible in its module. **Default.**
- `package` — visible to all modules in the package.
- `public` — visible externally (the module API).

Widening reach is the deliberate act; the default (`internal`) matches the implicit intra-module
namespace. A symbol is externally reachable only when it is `public` **and** sits in a product module (below).

**Module publicness is opt-in, via products.** A package lists its **products** in the manifest — the
modules that make up its external API. A module is importable from outside its package only if it is a
product; the default is package-internal. `public` and products are coupled by an invariant: a `public`
symbol is allowed **only inside a product module**, and a `public` symbol in a non-product module is a
**compile error** (use `package`, or add the module to the package's products). So exposing a module is two
deliberate acts — mark the symbol `public` *and* list the module as a product — and a stray `public` can
never leak an internal module by accident; the invariant keeps `public` meaning exactly "external API."

Consumers still reach a product **by path** — `import <package>/<product>`. The products list is a
producer-side gate on the module's identity, never an alias: the import path still names the module
unambiguously (depending is pathing), and the list only governs permission, the way symbol visibility
already does. Importing a non-product module is an error. (Products replaced the earlier manifest *seal*: an
opt-in public surface is the inverse of an opt-out hidden list, and the default is now encapsulated, so one
mechanism covers it.)

## Re-export

**Decided.** A module republishes another module's public symbols into its own **public** API with
`public import foo`. Plain `import foo` republishes nothing (file-local). Whole-module granularity
(no per-symbol re-export or rename). Chaining composes, so a facade or prelude can flatten deep
submodules into one import. Consumers disambiguate any resulting clash with `Module.Name`.

**Types in a public signature are not re-exported** (the Rust rule). A module may name another module's type
in its own public API — a parameter, return, field or payload — without re-exporting it. A consumer can use
values of that type fully (read fields, call methods, match cases) with no import of the defining module;
writing the type's *name* still needs that import. The interface records each such type's defining module
(`foreignTypes`), so the consumer resolves it to the right identity and loads its declaration without
bringing the module into scope. Rationale: re-exporting just to mention a dependency's type would make
`public import` routine, and implicit re-export would let a dependency change add or remove names in its
consumers' scope.

A `package`-scoped re-export was considered and rejected: it cannot enforce indirection (siblings can
always import the target directly), and within a package — refactored atomically — the decoupling a
facade provides has little value. The public facade keeps its value because it protects consumers in
other packages.

## Disk layout

**Decided.**

- **Flat source.** No `src/`. The manifest sits at the package root. A single-module package puts its
  source at the root (the root *is* that module); a multi-module package keeps the root a pure container
  and its modules in leaf subdirectories. `import pkg/foo` maps to `<package-root>/foo`.
- **`.nomu`** file extension.
- **Path components are lowercase valid identifiers** — `[a-z][a-z0-9_]*` — because each component
  becomes a bare qualifier (`net.Client`). This rule covers module directory names and package names
  alike; hyphens and other symbols are excluded (they can't sit in identifier position), and package
  names cannot be hyphenated.
- **Free filenames** within a module.

## Manifest

**Decided (two files, one per level).** The package and the workspace each have their own file; a
module has none.

- **Package** — `pkg.json`, at the package root. Holds package name, version, dependencies, the
  **default module** (the leaf module a bare package name forwards to, for `import`/`build`/`run`; a
  single-module package's root module is the implicit default), the **products** (public-module list — see
  §Visibility; the opt-in external surface, replacing the earlier `sealed` opt-out), executable
  declarations (`bin`), and test-module declarations. One per package; a single-package repo has exactly
  one. Its presence marks the package root, and `pkg` addressing resolves to it.
  - **Dependencies** (schema built, task [187](../plans/tasks/187-multi-package-builds.md) §187.1). A
    `"dependencies"` **list of package names** — the allow-list of packages this package's modules may import
    from (a module may import only packages its `pkg.json` declares; a dependency's own dependencies are
    **not** transitively importable). A name is the dependency's **own package name**, which is the root
    token an import uses (`import libfoo/bar` names the package `libfoo`) — no per-importer aliasing, since a
    package's identity is workspace-unique. **No paths or versions live in `pkg.json`:** an in-workspace
    dependency is found by its `pkg.json` marker within the workspace tree (discovered, not declared), and an
    external dependency's workspace is pinned (version + source) in `nomu.yaml`. Example:
    `"dependencies": ["libfoo", "netutil"]`.
- **Workspace** — `nomu.yaml`, at the repo root, above the packages. The unit of **versioning and external
  consumption**. It carries a **`scope`** and a **`name`**, which together are the workspace's identity:
  the first segment of every symbol's mangled identity (so a workspace's compiled objects are safe to link
  into another workspace), and how a build recognizes two copies of one project, whatever their version or
  source. Both are required and follow the path-component rule (`[a-z][a-z0-9_]*`). The scope is chosen
  once by the workspace's owner (`nomu init` proposes a default to confirm) and consumers never write it.
  Identity rules: [189](../plans/tasks/189-multi-remote-workspace-builds.md) §Decided. It pins each external dependency to a **single version +
  source**, per *workspace* (the unit of external consumption is another repo's workspace, not a lone
  package), one version across the whole workspace — so the diamond problem cannot arise (the Bazel stance);
  a consumer may bind an external under a **local alias** for its imports (`import <alias>/<package>`),
  which never changes the external's identity or symbols. In-workspace
  packages are not listed here: they are discovered by their `pkg.json` markers in the tree. A consumed
  external workspace is self-describing the same way — its own `nomu.yaml` + markers define its packages.
  Its contents land with cross-package linkage ([187](../plans/tasks/187-multi-package-builds.md)); until
  then it is a marker only.
- **Module** — no file. Module metadata is zero; the filesystem is the module list (a per-module file
  is possible later if a need shows up). A manifest references modules only as policy lists (products,
  bin, tests), never as an addressing inventory.

**Decided (format rule).** Not TOML. The manifest is **declarative data**, never a program, so the
compiler, an LSP, and a dependency resolver can all read it as static, inspectable data.

**Decided (format): JSON for `pkg.json` now.** Chosen because it parses dependency-free in the Swift host
(Foundation), unblocking the module work without taking on a parser dependency. Its cost is
human-authoring friendliness (no comments). **Switch to YAML later** — task
[163](../plans/tasks/163-manifest-yaml.md) — for a comment-bearing, human-friendly format once the
system is in use. StrictYAML and KDL were the earlier leans; JSON is the pragmatic bootstrap.

## Initialization & entry point

**Decided.**

- **No top-level executable code.** The top level holds declarations only. Execution begins at an
  entry point.
- **Ordered-eager global initialization.** Globals may have runtime initializer expressions, run in
  module-topological order (supplied by the acyclic module graph), completed before `main`. No implicit
  `init()` blocks — initialization is traceable to the variable it initializes. Const-evaluable globals
  fold to compile time. Per-access cost is zero.
- **Entry point.** A `main` function makes its module an executable. `build`/`run` target a module **by
  path** (`nomu run pkg/server`) and build/exec it; a module without a `main` is not executable and running
  it is an error. Targeting by path is the selection — it is not whole-tree scanning, so the "no
  auto-discovery" concern does not apply. Binary modules are expected to sit shallow (`<pkg>/<name>`), so
  the path *is* the name.
- **Declared executables — deferred.** The manifest's `bin` list is a package's *shipped-executable
  manifest* (names + which modules), which earns its keep only for **distribution / install** (a package
  advertising its public executables by name, independent of internal layout) and **naming** (an installed
  binary named differently from its module). `build`-all is a graph traversal filtered to terminal
  executable modules, needing no declarations. So `bin` is carried in the schema but unconsumed until
  distribution/install lands; local `build`/`run` are purely path-based.

## Tests

**Decided.**

- **Test identity is module-level**, declared in the manifest. A module is real XOR test — no
  double-duty modules, no filename-suffix discovery. Test modules have normally-named files and may sit
  adjacent to the code they test.
- **White-box access** via `test import pkg/foo`, which widens the test module's visibility into `foo`
  to `internal`/`package`. A plain import stays black-box (public only). One test module can be
  black-box on some targets and white-box on others. **`test import` is restricted to modules in the same
  package** — a test may widen into its own package's internals, never another package's; a cross-package
  import is always black-box, so a package's encapsulation holds even against a foreign test (task 187).
  **Implemented** (task 173.5.4): a module reached
  through a `test import` edge has its interface built white-box (internal/package decls exposed, not just
  public), so the test module's Sema reaches the target's non-public API; non-public symbols already carry
  external linkage in the target's object, so admitting them to the interface is the whole mechanism.

Rationale for keeping test code in separate modules rather than mixing it into the module under test:
avoids an intra-module test/prod marker, namespace leakage of test helpers into production code,
test-dependency contamination of the production build, per-module compilation-unit variants, and a
class of cyclic-import hazards.

Test-case designation (how a function is marked a test) and the runner are deferred — task
[161](../plans/tasks/161-test-framework.md).

## Conditional compilation

**Leaning / Deferred.** Platform/arch/build-mode gating folds into `comptime` (platform facts as
comptime values, branch pruning at compile time), not a `#[cfg]`-style declaration-attribute surface
and not a filename convention (both rejected). Deferred to task
[141](../plans/tasks/141-comptime.md).

## Resource embedding

**Leaning / Deferred.** Native-embed model (compile-time embed into the binary), with explicit
manifest `include`/`exclude` for what ships with a package. Deferred to task
[160](../plans/tasks/160-resource-embedding.md).

## Type inference dependency

**Decided (as a dependency of the import model).** The Swift-style import ergonomics (wildcard-bare,
type-directed clash resolution) rely on keeping inference cheap. The intended inference model, which is
broader than modules:

- Mandatory function signatures; inference is local to a body and never crosses a function boundary.
  This also makes a module's public signatures its interface, a precondition for separate compilation.
- Single default type per literal.
- Operator overloading resolved bottom-up from operand types (no return-type-directed operator
  selection).
- A small closed set of unambiguous coercions (exact set open).
- Closures inferred from the expected type at the use site, with an explicit annotation required when
  context can't pin them.

These keep name resolution near Go's speed while the surface reads like Swift's.

## Compilation model

**Decided.** Separate compilation, with the **module as the compilation and caching unit**. The
original "separate compilation vs whole-program monomorphization" fork resolves as: separate
compilation is the model, and whole-program monomorphization is the high end of a specialization dial,
not a distinct model.

**Representation — from generics.md, already built.** Witness-passing (dictionary/erased) is the
semantic baseline; monomorphization is a specialization pass layered on top. `any I` is a heap-boxed
`{witness, payload}`. Both paths exist through M5, so the dial below is a policy over existing
machinery, not new representation.

**Specialization control — two axes: a consumer build flag + a producer in-source surface.**

*Consumer axis — the dial, a build flag.* `--mono` controls whether the module under compilation
specializes the generics it **consumes**, as a spectrum of values:
- **`none`** — no cross-module specialization; generics dispatch through witnesses at module edges.
- **`edge`** — specialize the directly-called generic instances only; nested generic calls inside a
  specialized body stay witness-dispatched. Shallow: faster builds / smaller code than full tree, more
  speed than witness.
- **`all`** — whole-tree: recursively specialize nested generic calls too (recovers whole-program-mono
  performance).
- **Depth is a configurable knob to start** (`edge` vs `all`), held open while the right default is
  unknown; it may later be subsumed by the per-call-site cost model (task
  [145](../plans/tasks/145-monomorphization-cost.md)), which would make a global depth flag obsolete.
- Mode defaults: **debug = `none`**, **release = `all`** (opt in per invocation,
  `nomuc compile MyModule --mono=edge`).
- The flag is part of the build config and every action's cache key, so switching modes is a full rebuild.
  The consumer axis is controlled by the flag, never an in-source marker — it is a build decision. The same
  depth knob governs the whole-program release pass below.

*Producer axis — in-source, per declaration.* A generic's author controls whether and how it is
specialized. (This reverses the earlier blanket "no in-source markers" — that rule now governs only the
consumer axis above.) Two forms:
- **Default: dynamic (witness), specialize opt-in.** A generic is witness-only by default — the erased
  path, no `.bir` shipped, consumers cannot specialize it. A **single contextual modifier keyword** —
  **`mono`** — marks a generic as specializable: ships its `.bir` so a consumer may
  specialize it per its dial. Contextual — recognized only in modifier
  position — so it does not reserve the word in user namespaces. No opt-out keyword is needed (witness is
  the default). This governs only the *cross-module* published form; in-module callers still monomorphize
  from the local body regardless.
- A **top-level `specialize <Instance>` directive** lists concrete instantiations the producer
  **prespecializes**: emits into its own object and advertises in the `.nmi`. The directive **must be
  top-level and must appear in the file where the generic is declared.** Prespecialization is
  producer-owned and co-located with the generic; a consumer cannot prespecialize a dependency's generic,
  so consumer-specific instances rely on the dial or the whole-program pass instead.
- **A prespecialized instance overrides the consumer dial.** At the consumer's *compile*, each generic call
  at a statically-known concrete type checks the dependency's `.nmi`-advertised prespecialization set; if the
  instance is there, the call binds directly to the prebuilt symbol — even under `mono=none`. This is
  deterministic and hermetic (the set is in the interface the consumer already reads), distinct from the
  rejected link-time sibling piggyback. It is always safe to let the prespecialization win: a specialization
  of `Foo<Int>` is semantically identical regardless of who built it. A **witness-default generic that
  prespecializes its hot instances is the stdlib pattern** — ship no bodies, prebuild the hot set, and every
  consumer (including debug) picks them up.

*Release mechanism — per-module specialization + COMDAT fold.* Release compiles each module with `--mono`
and the linker folds the duplicate specializations, which already yields whole-program-mono output — no
separate link-time pass is needed for parity. Duplicate specializations **fold at link** (COMDAT / coalesced
weak symbols); the specialized symbol is **producer-qualified + type args**, so copies emitted by different
consumers are byte-identical (deterministic specialization) and fold to one. There is **no opportunistic
"sibling piggyback"**: a module's witness calls are a per-module commitment, never redirected to a sibling's
specialization at link.

*Whole-program specialization pass — deferred build-efficiency optimization.* A deterministic whole-program
specialization / devirtualization pass at the link (LLVM WPD / ThinLTO model) would dedup the specialization
*work* — deciding and building each instance once instead of per consumer — but per-module + COMDAT already
gives the same *output*, so this changes build cost, not the binary, and is not required for release parity.
A "missed specialization" report (a witness call whose specialization is present in the binary anyway) feeds
the prespecialization list — a sibling of task [175](../plans/tasks/175-inference-observability.md).

*Prespecialization advertisement* rides the `.nmi` **ABI section** as a per-instance `(generic, type-args)`
set: a prespecialized instance is an additional exported concrete symbol, and its removal must invalidate
dependents, so it is ABI-relevant. The consumer derives the prebuilt symbol by mangling and matches via the
canonical type encoding.

**Module artifacts.** A module compile produces `.o` (concrete code + the erased generic path), `.nmi`
(interface), and `.bir` (generic and inlinable-non-generic body IR). Each module has its own directory under
the building **workspace**'s `build/`, at its workspace-relative path (`build/app/cli/` holds `cli.o`,
`cli.nmi`, and the binary `cli`); another workspace's modules sit under `build/_external/<scope>.<name>/`.
The runtime archive and the embedded `nomu` workspace's modules live in a per-host cache instead. Absent a
workspace marker, a loose package is its own build root. (Layout:
[190](../plans/tasks/190-explicit-module-builds.md) D2, D4.)
- `.nmi` is **body-free** and carries the API contract only: signatures, type layouts, generic
  signatures + bounds, conformances, witness / value-witness layouts + per-type GC trace metadata, and
  body-derived contract facts (mutating-ness, shareability). It holds no body and no body hash — that
  is what keeps it **byte-stable under non-API body edits**, the property the incremental build relies
  on. (Inferred mutating-ness means a body edit that flips it legitimately changes `.nmi`; the standing
  `mutating`-keyword argument lives here.)
- Dependencies by mode: **debug depends on deps' `.nmi` only** (a dep body edit that leaves its `.nmi`
  identical does not rebuild dependents — the fast loop); **release additionally depends on deps'
  `.bir`** to specialize. Cross-module specialization happens inside the consuming module's compile;
  duplicate instances fold at link (COMDAT). No per-instance build actions.

**Interface / IR serialization — Decided: bespoke binary** (v1 sketch in task
[100](../plans/tasks/100-modules.md); optimization in task
[162](../plans/tasks/162-interface-serialization-opt.md)). Deterministic bytes (name-sorted tables, no
timestamps) for cache correctness. A schema framework and a textual format were rejected: no schema
evolution is needed (no cross-version ABI stability; version-stamp + regenerate), `.bir` is inherently
bespoke IR serialization, and self-hosting means hand-writing the Nomu reader either way. A
`nomuc dump-interface` textual view exists for inspection.

**Symbol mangling — Decided** (detail in [internals/backend.md §3](../internals/backend.md)). The
existing `nomu_` + 9-encoded reversible scheme extends to encode the real package + relative module
path and generic type arguments. **No ABI stability** — an unstable internal contract; packages are
consumed as source and recompiled, and the compiled interface is a build cache tied to the compiler
version. **No compression**, preserving read-without-a-demangler; revisitable if measured.

**Driver / CLI — Decided: single binary, subcommands.**
- `compile` — single-module primitive (input→output, deterministic), machine-facing; not touched by
  humans in normal dev.
- `build` / `run` / `test` — package-granular, human-facing, the uber layer over `compile`.
- `query` — package metadata (modules + inter-module dependency edges from imports + external deps),
  for tooling and build-graph generation.
- The compile logic is a **library** with two entry points: an in-process API and the `compile`
  subcommand, byte-identical and deterministic on both. The built-in `build` driver runs compiles
  **in-process** (thread pool, shared caches, own local content-addressed cache) for the fast local
  loop. Under **Bazel**, Starlark rules spawn `compile` per module (one action = one module) for
  isolation, caching, and RE, and use `query` for dependency discovery — Bazel does the orchestration,
  the uber layer does not. Same action model, two schedulers.

**Constraints held throughout:** module = compilation unit, modules form an acyclic graph; a module's
public signatures are its interface; visibility tiers map to linkage (`private`/`internal`/`package`
hidden/internal, `public` external); single-version policy repo-wide (external deps, when added).

**Still deferred:** the release specialization threshold (task 145), cross-module inlining
(release-mode, needs `.bir` + LTO), prelude/implicit-import emission (task
[136](../plans/tasks/136-incremental-compilation.md)), distribution format, and the dependency
resolver algorithm. None are on the near-term single-package path.

## References

Tasks: [100 modules](../plans/tasks/100-modules.md) · [136 incremental](../plans/tasks/136-incremental-compilation.md)
· [141 comptime](../plans/tasks/141-comptime.md) · [145 monomorphization cost](../plans/tasks/145-monomorphization-cost.md)
· [160 resource embedding](../plans/tasks/160-resource-embedding.md) · [161 test framework](../plans/tasks/161-test-framework.md)
· [162 interface serialization](../plans/tasks/162-interface-serialization-opt.md).

Internals: [backend.md §3](../internals/backend.md) (mangling) · [generics.md](../internals/generics.md)
(witness + monomorphization) · [interfaces.md](../internals/interfaces.md) (witness tables, `any`/`some`).
