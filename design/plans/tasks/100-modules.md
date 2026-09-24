# Modules + multi-file / multi-module compilation

**Avenue:** Infra (+ Usability) · **Type/Lifecycle:** `language-feature · needs-design` (language +
compiler + driver + build system) · **Size:** XL · **Status:** needs-design · **Source:** deferred.md
(2026-08-18) — the largest missing architectural piece

**► Design settled — see the contract doc [`../../language/modules.md`](../../language/modules.md).**
The programmer surface and the compilation model are decided there. The fork resolved to **separate
compilation** (module = compilation unit) with a **witness baseline + flag-driven specialization dial**
(debug=none, release=specialize; threshold → [145](145-monomorphization-cost.md)), **bespoke-binary
`.nmi`/`.bir`** artifacts, and a **single-binary** driver (`compile` primitive + `build`/`run`/`test`
uber layer + `query` metadata; in-process locally, per-module subprocess under Bazel). This task now
carries the *implementation*; the design detail and rationale live in the contract doc and in this
doc's sections below. Spun-out tasks: [160](160-resource-embedding.md) resource embedding,
[161](161-test-framework.md) test framework, [162](162-interface-serialization-opt.md) serialization
optimization; conditional compilation folded into [141](141-comptime.md).

Original framing (kept for context): the compilation-model fork was the decide-early item before M10 —
separate-compilation-vs-whole-program-mono constrains how much direct-to-LLVM / mono logic accretes,
and M10's LSP depends on modules for responsiveness.

## What / scope

- **Modules + visibility** — multiple files, module boundaries, `public`/`private` (+ any
  module-internal level).
- **Module interface format** — the artifact a consumer compiles against: exported signatures, types,
  witness tables, shareability facts, and (open) generic bodies for cross-module
  specialization/inlining. Analogues: Swift `.swiftinterface` / `.swiftmodule`, Rust crate metadata.
  (The deferred "Module-level interface as input" item made concrete.)
- **Linker outputs** — per-module object files + symbol visibility / mangling across modules (builds
  on M4.15 mangling).
- **nomuc scope / driver** — a driver refactor + a scope decision: keep a pure compiler with a
  separate build/package tool, or fold build / run / package subcommands into one CLI (swift-style
  uber-CLI). **Candidate breakout.**
- **[Incremental compilation](136-incremental-compilation.md)** — broken out as its own task.
- **LSP** — the M10 [query server](137-tooling-lsp-formatter.md) reasons in module units; modules +
  incremental make it responsive.
- **Bazel + remote execution** — deferred (not in the plan below). The design stays RE-ready
  (deterministic `compile` primitive, content-addressed caching, `query` for graph discovery), so
  adding Starlark rules later is wiring, not redesign. Not built now.

## The central architectural fork — separate compilation vs whole-program monomorphization

The compiler today is single-CU with **whole-program monomorphization** (M5) + cross-everything
inlining. Modules pull the other way:
- Bazel RBE, incremental rebuilds, and LSP responsiveness want **hermetic separate compilation** —
  each module built from its deps' *interfaces*.
- Whole-program mono + cross-module inlining want **all IR present at once** (runtime-perf +
  self-hosting lean here).

**Resolved** (contract: [`../../language/modules.md`](../../language/modules.md); plan below).
Separate compilation is the model — module = compilation unit, one `.nmi` interface per module,
per-module compile against deps' interfaces. Cross-module generics dispatch through **witnesses by
default** (debug); a flag-driven **specialization dial** (`--mono`) specializes them cross-module in
release (shipping `.bir` bodies to do so), recovering whole-program-mono performance. Whole-program
mono is the high end of the dial, not a separate model. Bespoke-binary artifacts, no cross-version
ABI stability.

## Plan — implementation milestones (100.1–100.5)

Sequencing principle: **land the whole language surface on the existing whole-program pipeline first
(100.1–100.3), then swap the build model underneath without changing the surface (100.4–100.5).** That
isolates the one hard re-architecture (separate compilation) and keeps every phase shippable and
green. Bazel is dropped from this plan (design stays RE-ready; see scope).

**Sequencing revision — separate compilation up front.** The multi-module surface is being built
directly on separate compilation rather than on a whole-program-merge intermediate. Merging modules
into one namespace was rejected as a scaffold: a module must only ever see another module's public
interface, never a shared namespace. So after multi-file (100.1) and import parsing (100.2.2), the
order becomes: **visibility tiers → minimal package manifest (package identity) → module-path mangling
→ `.nmi` emission on a single module → consume `.nmi` for a two-module separate build.** The `.nmi`
starts as a **textual** interface (bespoke binary is a later optimization, task 162) over a **subset**
(non-generic public functions + public types with layouts; generics, conformances, and
mutating/shareability facts layer in after the basic two-module link works). Module discovery + the
acyclic graph (100.2.1) stay; the interim whole-program merge is removed when the two-module separate
build lands.

### 100.1 — Multi-file within a module

Multiple `.nomu` files in one directory compiled as one module with the implicit shared namespace.
Smallest step from today's single-CU.

- 100.1.1 — Frontend accepts N source files as one module (parse each, merge into one module).
- 100.1.2 — Shared intra-module namespace in resolution; `private` (file-scoped) vs `internal`
  (module) distinction.
- 100.1.3 — Duplicate-symbol detection across a module's files (collision = error; overloads distinct).
- 100.1.4 — Merged module flows through the existing whole-program pipeline unchanged.
- 100.1.5 (tests) — Multi-file module fixtures in the integration suite, added as **directory
  fixtures** (a fixture directory = one module; the harness passes its `.nomu` files as the file list,
  with an explicit `-o` binary path). The existing flat `examples/` fixtures stay single-file for now.
  Migrating the whole suite so that every fixture is its own directory (**1 dir == 1 module**) is
  deferred until directory-as-module exists (100.2.1+); tracked under 100.3.8.
- *Foundation exists:* the driver's `prependPrelude` already parses multiple sources (`core.nomu`,
  `runtime.nomu`) into separate `Program`s and merges their decls into the user program. 100.1
  generalizes that merge from "2 fixed preludes + 1 user file" to "N user files as one module," adding
  duplicate detection and the `private`(file)/`internal`(module) split. The CLI takes one file today
  (`nomuc … <file.nomu>`), so input intake also widens to a module directory.
- *Deliverable:* a directory of files compiles and runs as one module.

### 100.2 — Multi-module surface (whole-program)

The full import/visibility surface, still compiled whole-program (all modules, one CU).

- 100.2.1 — Module discovery by directory walk; module dependency graph from imports; acyclic-graph
  enforcement.
- 100.2.2 — Import syntax + parsing: `import path`, `import path as alias`, `pkg/…`; per-file scope.
- 100.2.3 — Cross-module resolution: whole-module wildcard-bare, leaf-name qualifier, alias, sealed
  transitivity; bare-name collision → qualify, leaf collision → alias (diagnostics). Split into a
  representation refactor and the resolution built on it:
  - 100.2.3.1 — **Module representation refactor. Done.** A module is now `[SourceFile]` (path + decls +
    imports; `ast/AST.swift`) instead of a flattened `Program`, so per-file imports survive; the
    module-wide passes take the union view (`files.flatMap(\.decls)`). Sema builds one module-wide symbol
    table across the files (shared namespace, unchanged) and records a **per-file import scope**
    (`fileVisibleModules` + `externalSymbolModule`, built by the driver's `fileScopes`, following each
    import's re-export closure). `Sema.checkImported` gates every imported (external) symbol at its use
    site — function references/calls (`NOIRGen`), type positions (`resolve`), and construction — so an
    imported symbol is bare-visible only in a file that imports its origin module; a use elsewhere errors
    ("defined in module 'pkg/X' but not imported in this file"). Same-module symbols stay global.
    Synthetic (interface-reconstructed) decls carry no file and are exempt. Tests:
    `tests/fixtures/module_perfile_import`. This is Go's model (package = shared namespace, imports
    file-scoped) and sets up cleaner diagnostics + later per-file incrementality.
  - 100.2.3.2 — **Cross-module resolution. Done.** Built on the per-file scope from 100.2.3.1.
    - *Wildcard-bare + qualified access* — bare when unambiguous; leaf-name qualifier + `as`-alias
      (`mod.name`, `alias.name`) for functions, construction, and value references, and for **type
      positions** (`let p: util.Point` — `TypeRef` gained a `qualifier`, the parser accepts a dotted
      type ref). Resolved through `Sema.resolveExternal` / `.member` handling against the file's qualifier
      bindings. Tests: `module_qualified`.
    - *Collision resolution by qualification* (the modules.md purpose) — imported symbols carry a
      **per-origin identity** `origin@name` (`ast/ExternalName`): the driver rewrites external decls to it
      (functions and types, including type refs to a module's own types), Sema resolves a user reference
      (bare-unambiguous or qualified) to that key, and codegen decodes a function's key to the producer's
      mangled symbol (a type's key is just a distinct layout key). So two modules exporting the same name
      coexist and `a.greet`/`b.greet` (and `a.Val`/`b.Val`, distinct layouts) resolve correctly. Bare use
      of a colliding name → error (qualify it); leaf-name collision (two imports sharing a qualifier) →
      error suggesting an alias (`reportLeafCollisions`). This replaced the flat symbol table for
      externals and retired the old per-name `externalOrigin` mangling map. Tests: `module_collision`
      (bare error), `module_leaf_collision` (leaf error), `module_collision_resolve` (funcs + types
      resolved distinctly), plus `module_reexport`/`module_perfile_import` unchanged.
    - Type-directed clash resolution (Swift-style) stays deferred (the "leaning" model; depends on cheap
      inference). Sealed/cross-package rules are not live (100.3.3.1).
- 100.2.4 — `public import` re-export (resolution + republish into public API). **Done:** a module's
  `.nmi` records its `public import` edges (`reexports: [InterfaceRef]`, package + module path); a
  consumer follows them transitively (`visibleModules` in the driver), unioning each re-exported
  module's public surface into its own external decls, with each symbol keeping its **origin module's**
  mangling qualifier — so a re-exported call links to the true producer, not the re-exporter. Resolution
  is interface-mediated (the edge travels in the `.nmi`, so a downstream sees it without the
  re-exporter's source). Test: `tests/fixtures/module_reexport` (main → mid → util). Re-export name
  collisions across imports fold into cross-module resolution/diagnostics (100.2.3 / 100.2.8).
- 100.2.5 — Visibility tiers `private`/`internal`/`package`/`public`, defaults, derived module
  publicness; enforced across boundaries. **Done for the single-package surface:** only `public` reaches
  a `.nmi` (so `internal`/`private` are invisible across a module by construction), and a
  signature-consistency pass (`sema/astpass/VisibilityCheck.swift`, run pre-prelude beside
  `checkDuplicates`) rejects a `public`/`package` declaration that exposes a lesser-visibility type in
  its signature — the `.nmi` well-formedness guard. **Deferred to multi-package:** `package` reaching
  same-package siblings (excluded from the `.nmi` today, so it behaves like `internal` across a module),
  seal enforcement, and denying a foreign package a `package` symbol — none is exercisable until
  cross-package linkage exists. That cross-boundary half is tracked as **100.3.3.1**.
- 100.2.6 — Mangling: encode real package + relative module path, replacing the implied `main`
  (generic-arg encoding already present). Mangling is currently **spread** (9-encoding in
  `midend/sources/Monomorphize.swift`; `nomu_` construction across `llvmgen/*`); **consolidate it into
  one 154-style capability module** here to restore the single swap point (backend.md §3).
- 100.2.7 — Compile all modules whole-program in module-topological order (still mono).
- 100.2.8 (tests) — Multi-module fixtures; visibility errors; re-export; collision diagnostics.
- *Deliverable:* multi-module programs compile and run whole-program; full surface works.

### 100.3 — Packages, manifest, driver, entry points (whole-program)

Package structure and the usable tool, build still whole-program internally.

- 100.3.1 — Manifest in **JSON** (dependency-free in the Swift host; switch to YAML later,
  [163](163-manifest-yaml.md)) + schema: name, version, `sealed`, `bin`, tests (deps later). Interim
  file name `pkg.json`; root still marked by `nomu.yaml` (both subject to change). A minimal
  name-only manifest already loads (separate-compilation-first reorder); absent → default package
  `main`. **Open policy:** keep open requiring a manifest and erroring when absent (drop the default)
  once the fixtures/tooling assume one — decide when the whole suite migrates to 1 dir == 1 module.
- 100.3.2 — Package boundary (manifest presence); workspace (root + members); package identity.
- 100.3.3 — Seal enforcement (sealed module not importable outside package; symbols capped at package).
  - 100.3.3.1 — **`package`-tier visibility across the package boundary** (the multi-package half of
    100.2.5, deferred there until cross-package linkage exists). Today only `public` reaches a `.nmi`,
    so a `package` symbol behaves like `internal` across a module — wrong once siblings compile
    separately. When multi-package lands: emit `package` symbols into the `.nmi` **tagged with their
    visibility**, have a consumer admit a `package` (or sealed) symbol only when it shares the producer's
    package (deny it to a foreign package with a clear diagnostic), and fold package identity into the
    mangling qualifier (the pending item noted in §100.4). The single-package signature-consistency
    guard (100.2.5) already stands; this closes the cross-boundary half.
- 100.3.4 — Entry points: `main` detection, `bin` declarations, root-`main` shorthand;
  declarations-only enforcement; ordered-eager global init in module-topological order.
- 100.3.5 — Single-binary driver: `compile`/`build`/`run`/`test`/`query`; compile-logic-as-library;
  in-process build orchestration over the module graph.
- 100.3.6 — `query` metadata (package → modules + inter-module dep edges + external deps).
- 100.3.7 — **Prelude becomes packages, not a decl-prepend.** Replace `prependPrelude` with a
  first-party package layering, compiled once (cached per toolchain version, or prebuilt) and referenced
  via cross-module linkage rather than merged into every module:
  - **`core`** — the *only* package containing non-Nomu source: built-in types (`Int`/`Bool`/`String`/
    `RawPtr`), built-in functions (intrinsics, C-leaf ops), and the libc/FFI boundary. Types are
    ambient (always in scope); low-level functions are the native/unsafe surface. **Invariant
    (target):** non-Nomu source ⊆ `core` — reached as the runtime finishes self-hosting; native GC
    (mmtk) still sits under the runtime today, so it is not yet literally true.
  - **`runtime`** — pure Nomu (target), privileged; runtime-subset-by-default moves from the interim
    file-designation to **module membership** ([149](149-runtime-subset.md)). Uses `core` for native
    primitives.
  - **`std`** — pure Nomu, non-privileged; today's `core.nomu` contents (`Option`, `Result`, `abs`/
    `max`/`min`, `Time`, `SimpleRNG`) move here, plus future `Array`/collections/IO. A **curated prelude
    subset** (`Option`, `Result`, pervasive helpers) is auto-imported into every module (Rust `std::prelude`
    shape); the rest is explicit `import std/...`.
  - User packages — pure Nomu.

  Bootstrapping: `std` does not auto-import its own prelude; `core` types stay ambient. Required by 100.4
  (decl-prepend duplicates symbols under separate compilation). The *demand-driven* emission that links
  only used prelude parts stays a [136](136-incremental-compilation.md) optimization. Enables the
  extensible stdlib ([120](120-stdlib-core.md)/[121](121-string-utf8-model.md)).
  - *Open sub-decision (build-time):* whether each `core` **function** is ambient or explicit-import/
    `unsafe`-gated (types are ambient; low-level fns lean gated, cf. Rust `core::intrinsics`).
- 100.3.8 (tests) — Package builds; multiple bins; `run`/`test`; seal enforcement; init order;
  implicit-`core` visibility and single-definition of core symbols. **Migrate the integration suite to
  1 dir == 1 module** — reorganize the flat `examples/` fixtures so each is its own module directory,
  once directory-as-module (100.2.1) makes the rule real.
- *Deliverable:* `nomuc build/run/test` on a manifest'd package with multiple bins.

### 100.4 — Separate compilation (witness baseline)

The architectural shift: module = compilation unit, compiled against interfaces, incremental.

**Status (separate-compilation-first reorder):** 100.4.1 (`.nmi`, textual/subset) and the core of 100.4.2
are built — the driver compiles each module to its own object in topological order, a consumer resolves
and links against a dependency's serialized interface (import-scoped, public-only; non-public symbols
are invisible by construction), and objects link into the binary. Module-path mangling is in: a
dependency's symbols carry its module-path qualifier (`nomu_fn_<path>_<name>`, etc.), a consumer derives
the same qualifier from the interface's `modulePath`, and the entry module plus the C-ABI prelude/runtime
symbols stay bare (nothing imports the entry; the C runtime pins the prelude names). Two carried-forward
**interims**:
- **Weak prelude linkage.** The prelude is still prepended to every module, so its functions get
  `WeakODR` linkage to fold the per-object duplicates. Proper fix: prelude-as-packages (100.3.7).
- **Entry-only GC type maps.** The `nomu_gc_typemap_*` tables are single extern globals the C runtime
  reads, so only the entry object emits them; dependency objects reference them externally. A
  dependency's own heap types are therefore not yet in the map — needs **cross-module type-id / type-map
  unification** (new sub-item under this milestone) before GC-traced types cross a module boundary.
- **Package identity not yet in the qualifier.** The qualifier encodes the relative module path but not
  the package name, since cross-package linkage (external-package deps via manifest aliases) is not live
  yet. Package identity folds into `Mangle.qualifier` when that lands; today every module sits in one
  implied package, so the module path alone is collision-safe.

- 100.4.1 — `.nmi` generation: contents (signatures, type layouts, generic signatures + bounds,
  conformances, witness/value-witness layouts + GC trace metadata, mutating-ness/shareability) +
  bespoke-binary serialization (deterministic, name-sorted, body-free).
- 100.4.2 — Per-module compile against deps' `.nmi` (not source); codegen emits external references.
- 100.4.3 — Cross-module generics via witness dispatch (reuse the witness baseline; no cross-module
  specialization yet).
- 100.4.4 — Link separate per-module objects + runtime.
- 100.4.5 — Driver incremental cache: content-addressed per-module keying; interface byte-stability;
  skip unchanged modules; rebuild on interface change.
- 100.4.6 (tests) — Incremental (body edit doesn't rebuild dependents); interface stability;
  separate-compile output matches the whole-program golden.
- *Deliverable:* editing a module body doesn't rebuild its dependents. (Cross-module generics are
  witness-dispatched here; perf restored in 100.5.)

### 100.5 — Specialization dial + release mode

Restore monomorphized performance under separate compilation via the flag-driven dial.

- 100.5.1 — `.bir` body-IR serialization (bespoke, keyed by generic id).
- 100.5.2 — `--mono` flag + mode defaults (debug=none, release=specialize-all); flag in the cache key.
- 100.5.3 — Cross-module specialization: consuming module reads deps' `.bir`, specializes its used
  instances; call sites dispatch specialized vs witness.
- 100.5.4 — Link-fold duplicate instances (COMDAT/weak symbols).
- 100.5.5 (tests) — Release perf parity with whole-program mono (golden/perf); debug-fast and
  release-specialized both correct.
- *Deliverable:* release recovers monomorphized performance; debug stays fast and incremental.

### Source organization

Place the work deliberately rather than swelling existing files, in the spirit of
[154](154-source-tree-decomposition.md). Principle: **new logic goes into new standalone types with
clear responsibilities (capability extraction, as 154 does), composed into the pipeline — not methods
bolted onto the `Sema` / `SSAIRGen` monoliths, whether by direct append or by a Swift `extension`
block that merely spreads a god-object across files.** New subsystems get new top-level components;
work that belongs to an existing subsystem gets new *component* files in that subsystem's directory.
Consolidate the spread mangling into a single capability module (100.2.6). Follow 154's concrete form
for every new component: a **caseless-enum namespace of `static func`s over `inout`/`borrowing State`,
value semantics, no reference context object.** 154 status to coordinate against: `Sema` and `SSAIRGen`
are **done** (new sema passes drop in cleanly), `SSAIRToLLVM` is **mid-split**, and `Parser.swift` is
**not yet decomposed** — so the import-syntax parser work (100.1/100.2) should decompose-as-it-goes per
154's guidelines rather than swell `Parser.swift`.

New components (new subsystems):
- **`src/modules/`** — the module/package model: `Module`, `Package`, `Workspace`, and `ModuleGraph`
  (directory discovery, acyclic check, topological order). Manifest schema + parser
  (StrictYAML/KDL) live here too (`modules/manifest`).
- **`src/interface/`** — the artifacts: `InterfaceModel`, interface emit, and the bespoke-binary
  (de)serializer for `.nmi` and `.bir` (deterministic, name-sorted). Body-IR serialization for `.bir`
  sits alongside.

New component files within existing subsystems (standalone types composed into the pipeline, not
appends or `extension` blocks on the monoliths):
- **`src/frontend/parse/sources/`** — import forms (`import`, `as`, `pkg/…`, `public import`,
  `test import`) and visibility modifiers.
- **`src/frontend/sema/sources/passes/`** — `ImportResolve` (cross-module resolution),
  `VisibilityCheck`, re-export handling, and `InterfaceLoad` (consume deps' `.nmi` as sema input).
- **`src/midend/sources/`** — `CrossModuleSpecialize` (the dial + `.bir` read) alongside the existing
  `Monomorphize`, not folded into it.
- **`src/llvmgen/`** — mangling (currently spread here + in `midend/Monomorphize`; consolidate into
  one capability module in 100.2.6) and per-module object emission + linking. Note `SSAIRToLLVM.swift`
  is mid-decomposition under 154 (Calls/Values remain) — coordinate.
- **`src/driver/sources/`** — build orchestration (module-graph build, in-process worker pool,
  content-addressed incremental cache, link) and subcommand dispatch (`compile`/`build`/`run`/`test`/
  `query`); the compile primitive exposed as a library entry point.
- **`src/nomu-cli/sources/`** — thin subcommand wiring over the driver library.

Per-milestone touch map: 100.1 → parse + sema/passes. 100.2 → parse, sema/passes, `src/modules/`
(graph), llvmgen (mangling). 100.3 → `src/modules/` (package + manifest), driver, nomu-cli. 100.4 →
`src/interface/`, sema (`InterfaceLoad`), llvmgen (per-module object + link), driver (incremental
cache). 100.5 → `src/interface/` (`.bir`), midend (`CrossModuleSpecialize`), llvmgen (link-fold).

### Intra-module parallelism

Two levels of parallelism: **inter-module** (the driver compiles independent modules in the acyclic
graph concurrently) and **intra-module** (within one module's compile). The intra-module phase
structure, in one process:

1. Parse — parallel per file (independent).
2. Collect declarations → module symbol table — parallel collect + merge; duplicate detection.
3. Resolve signatures + type layouts — dependency-ordered (topological over type/signature refs);
   cheap; recursive types break the layout cycle through references.
4a. Infer caller-relevant body-derived contract facts (mutating-ness, shareability requirement) — a
   call-graph fixpoint, parallel across independent SCCs, serial within a dependency chain.
4b. Body type-check + IR gen — parallel per function against the now-frozen, read-only symbol table.
5. Mid-end + backend — parallel per function, with a concurrent dedup map for shared instantiations.

Mechanics: phase barriers; **freeze the symbol table and share it read-only** across phase-4 tasks (no
locks in the hot phase); collect per-function results in **canonical order** (name-sorted outputs,
location-sorted diagnostics) so output and error order are independent of thread timing; thread-safe
interning (concurrent table or per-thread + merge).

**Decided (revisit post-build): mutating-ness and shareability stay inferred** — no `mutating` keyword,
no `shared` annotation on visible bodies — to keep the "programmers don't need to know much about
memory" tenant. This keeps phase 4a (the fixpoint pre-pass). The rule that governs it: a caller waits
on a callee's body exactly when a caller-relevant contract fact is inferred from it; putting such facts
in signatures would remove the wait. We accept the fixpoint here because shareability inference already
reads bodies, so an explicit `mutating` keyword would remove nothing while shareability stays inferred.
Revisit only after 100.1–100.5 are built and parallelization is measurable — then weigh sacrificing the
no-annotation tenant against the fixpoint's actual cost. (Cross-refs: `../../internals/types.md`
mutating-ness, `../../internals/concurrency.md` §5 shareability inference.)

### Open sub-decisions inside the plan

- **Manifest serialization format** — decided: JSON now (dependency-free), YAML later
  ([163](163-manifest-yaml.md)).
- **Release specialization threshold** (100.5) — starts at specialize-all; smarter policy is
  [145](145-monomorphization-cost.md).

### Attached / dependent tasks

- [161](161-test-framework.md) test framework — after 100.3 (test-module identity + `test import`).
- [162](162-interface-serialization-opt.md) serialization optimization — after 100.4 (v1 exists).
- [145](145-monomorphization-cost.md) monomorphization cost model — after 100.5.
- [160](160-resource-embedding.md) resource embedding, [141](141-comptime.md) conditional compilation
  — independent / later.
- [136](136-incremental-compilation.md) incremental compilation overlaps 100.4.5; coordinate.
- [149](149-runtime-subset.md) runtime-subset designation moves onto module membership once 100.2 lands
  (see below).

## Triggers this un-parks

The [`shared` spellings](132-shared-spellings.md) (hidden bodies across a module boundary) and
"Module-level interface as input" both fire when modules land.

**Runtime-subset designation ([149](149-runtime-subset.md)) should move onto module membership.** Surface
A for the runtime subset is "the runtime tier is subset-by-default" — a module-level property. Until this
task lands there is no module boundary to hang it on, so 149 uses an **interim file designation** (a
compiler input marking specific source files subset; functions in them get the no-alloc / no-barrier /
no-safepoint properties). When modules exist, replace the file designation with module membership: a
designated runtime/privileged module makes its functions subset by default. The internal per-function
property set (`runtime-subset.md` §3) stays unchanged — only the *source* that populates it moves from
file to module, so this is a designation swap, not a rework. See `runtime-subset.md` §8 (open: module
designation mechanism).

## Roadmap assessment

**Yes — a named milestone**, with [incremental compilation](136-incremental-compilation.md) and the
nomuc uber-CLI / build tool possibly split out. All three heads, hard. It gates parked work and
underlies LSP + Bazel scaling.

## Refs

deferred.md "Modules + multi-file"; `modules.md`; `noir.md` §2a (mangling); [137 tooling](137-tooling-lsp-formatter.md);
[incremental compilation](136-incremental-compilation.md), [ir-pipeline hardening](142-ir-pipeline-hardening.md),
[shared spellings](132-shared-spellings.md).
