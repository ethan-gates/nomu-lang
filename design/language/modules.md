# Modules & packages — the contract

What a Nomu author can rely on for structuring code across files, modules, and packages: naming,
imports, visibility, layout, initialization, and tests. The build model (separate compilation with a
specialization dial) is resolved; see [Compilation model](#compilation-model) at the end and task
[100](../plans/tasks/100-modules.md).

Status tags: **Decided** · **Leaning** · **Deferred** · **Open**. Design detail and rationale for
open items live in task [100](../plans/tasks/100-modules.md).

## Model — two levels

**Decided.** Two units, at different granularities:

- **Package** — the named, versioned, distributed unit. Depends on other packages, carries a
  manifest, is the boundary for versioning and for the seal.
- **Module** — a directory of source files, the compilation unit. Addressed by its path relative to
  the package source root. A module's identity is `package + relative path`, so `a/util` and `b/util`
  are distinct.

This is Go's package/module split (its "module" is our package, its "package" is our module) with
Rust-style origin-hiding (a package is referenced by a short local name, not its origin URL).
Nested packages are forbidden; a package tree contains only modules.

## Modules

**Decided.**

- **One directory = one module = one compilation unit.** A directory containing at least one `.nomu`
  source file is a module. A directory with only subdirectories is a path segment, not a module.
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
- **Sealed transitivity.** Importing `B` does not expose what `B` imported. Transitive dependencies
  never leak into scope.
- **Collisions** between bare symbols are resolved by qualifying (`foo.Bar`); a leaf-name collision
  between two modules is resolved by aliasing one.

Same-package imports use the `pkg` root keyword (below); external-package imports name the package.

**Leaning.** Type-directed resolution of a bare-name clash (Swift-style) is the intended model, and it
depends on keeping expression-level inference cheap — see [Type inference dependency](#type-inference-dependency).

## First-party addressing

**Decided.** Within a package, a module imports a sibling with the reserved root keyword **`pkg`**:
`import pkg/util/parse`. `pkg` resolves to the package whose manifest encloses the importing file.
Rename- and extraction-safe (internal imports never name the package), no self-name repetition, no
`super`/`self`-relative navigation.

External packages are named by their manifest alias: `import foo/parse` targets a nested module,
`import foo` targets the package's root module. A package need not have a root module; if it lacks one,
bare `import foo` is an error and callers import a submodule.

## Visibility

**Decided.** Four symbol tiers, declared in source on the declaration:

- `private` — visible in its file only.
- `internal` — visible in its module. **Default.**
- `package` — visible to all modules in the package.
- `public` — visible externally (the module API).

Widening reach is the deliberate act; the default (`internal`) matches the implicit intra-module
namespace. A symbol is externally reachable only when it is `public`.

**Module publicness is derived**, not declared: a module is externally importable to the extent it has
`public` symbols. There is no module-level visibility keyword.

**The seal** is the one exception, and it is declared in the **package manifest**, not in source. A
sealed module cannot be imported outside its package, and its symbols are capped at `package` reach
regardless of any `public` inside it. The seal is a team-governance boundary (auditable in one place,
diffable), which is why it lives in the manifest while fine-grained symbol visibility stays local in
source. It guards against a stray `public` leaking a module that is meant to stay internal.

## Re-export

**Decided.** A module republishes another module's public symbols into its own **public** API with
`public import foo`. Plain `import foo` republishes nothing (file-local). Whole-module granularity
(no per-symbol re-export or rename). Chaining composes, so a facade or prelude can flatten deep
submodules into one import. Consumers disambiguate any resulting clash with `Module.Name`.

A `package`-scoped re-export was considered and rejected: it cannot enforce indirection (siblings can
always import the target directly), and within a package — refactored atomically — the decoupling a
facade provides has little value. The public facade keeps its value because it protects consumers in
other packages.

## Disk layout

**Decided.**

- **Flat source.** No `src/`. The manifest and the root module's files sit at the package root;
  `import pkg/foo` maps to `<package-root>/foo`.
- **`.nomu`** file extension.
- **Path components are lowercase valid identifiers** — `[a-z][a-z0-9_]*` — because each component
  becomes a bare qualifier (`net.Client`). This rule covers module directory names and package names
  alike; hyphens and other symbols are excluded (they can't sit in identifier position), and package
  names cannot be hyphenated.
- **Free filenames** within a module.

## Manifest

**Decided (contents).** One manifest type, appearing once per package. Holds: package name, version,
dependencies, the `sealed` module list, executable declarations (`bin`), and test-module
declarations. The repo root additionally carries a workspace section (member packages; the single
resolved version per external dependency). A single-package repo has exactly one manifest.

Module metadata is zero: no per-module file. The manifest references modules only as policy lists
(sealed, bin, tests, exports of executables), never as an addressing inventory.

**Decided (format rule).** Not TOML. The manifest is **declarative data**, never a program, so the
compiler, an LSP, and a dependency resolver can all read it as static, inspectable data.

**Decided (format): JSON for now.** Chosen because it parses dependency-free in the Swift host
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
- **Entry point.** A `main` function marks an executable. Executables are declared explicitly in the
  manifest (`bin`), each naming the module whose `main` is its entry; no auto-discovery. A package with
  no `bin` section and a `main` at its root module is the single-executable shorthand.

## Tests

**Decided.**

- **Test identity is module-level**, declared in the manifest. A module is real XOR test — no
  double-duty modules, no filename-suffix discovery. Test modules have normally-named files and may sit
  adjacent to the code they test.
- **White-box access** via `test import pkg/foo`, which widens the test module's visibility into `foo`
  to `internal`/`package`. A plain import stays black-box (public only). One test module can be
  black-box on some targets and white-box on others.

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

**Specialization dial — a build flag with mode defaults.**
- Controlled by a compiler flag (e.g. `--mono`), never by in-source markers (no `@specialize`).
- **Debug default: none** — cross-module specialization off; generics dispatch through witnesses at
  module edges. Opt in per invocation (`nomuc compile MyModule --mono=all`).
- **Release default: specialize** — start at specialize-all (recovers today's whole-program
  performance); a smarter threshold (heuristic / profile-guided / size-budget) is task
  [145](../plans/tasks/145-monomorphization-cost.md).
- The flag is part of the build config and every action's cache key, so switching debug↔release is a
  full rebuild.

**Module artifacts.** A module compile produces `.o` (concrete code + the erased generic path), `.nmi`
(interface), and `.bir` (generic and inlinable-non-generic body IR).
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
