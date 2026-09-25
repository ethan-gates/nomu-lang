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
  specialization yet). **Scoped below.**

  *Goal / boundary.* Debug-mode witness baseline: a public generic function / type / method is compiled
  **once** in its producer and called across a module boundary through runtime witnesses, no body
  shipped. Intra-module generics keep monomorphizing in debug; the erased path is emitted for public
  generics at module edges. Cross-module *specialization* (reading `.bir`, the `--mono` dial, COMDAT
  fold) is 100.5, out of scope here. This is the first case where a generic is called without its body
  present — today a residual generic requirement reaching codegen is a hard error
  (`FunctionLowerer` "not resolved by monomorphization").

  *Representation — Decided: value-witness tables (Swift's model, and the `modules.md` baseline).* Each
  type parameter `T` carries type metadata (size / align + a **value-witness table**: copy / move /
  destroy) and one **protocol witness table** per bound (`T: I`). A `T` value lives in a caller-provided
  stack buffer sized from the VWT and is copied / moved / destroyed through VWT calls — no forced heap
  boxing. Requirement calls dispatch through the interface witness tables already built in
  `llvmgen/LLVMGenWitness.swift` (mature for existentials — slot layout, per-conformance globals,
  `witnessDispatch`, uniform-self thunks; reused here). A VWT is emitted at the instantiation site (the
  consumer, for its concrete type arguments) from layout the consumer already has; the producer's erased
  function only receives witness pointers, so this needs little beyond the interface surface 100.4.1
  already carries. **The concrete ABI — VWT layout, the witness-argument calling convention, indirect
  value passing, erased-symbol mangling — is pinned in [`../../internals/backend.md`](../../internals/backend.md) §4.**
  (The rejected alternative — reuse the existential heap box for every erased `T` — was
  smaller to build but heap-allocates every value in debug, enlarges the GC surface, and diverges from
  the documented value-witness baseline; release perf is identical either way via the 100.5 dial, so the
  box shortcut bought only build speed at the cost of a later rework.)

  - 100.4.3.1 — Consumer sees imported generics. **Done for generic types.** `interfaceToDecls`
    reconstructs imported generic struct/class/enum decls (with generics + bounds); `Sema` routes an
    imported generic type through `lowerGenericDecl` so the consumer monomorphizes its layout locally
    from the interface (no body crosses the boundary — a type has none). Fixture `module_generic_type`
    (imports `Box<T>` + `Opt<T>`, constructs/matches at `Int`) compiles and runs. **Deferred to the
    erased path (100.4.3.2–.4):** generic *functions* (a body-free reconstruction would let mono clone an
    empty body, so they stay skipped) and *methods* on imported generic types.
  - 100.4.3.2 — Value-witness ABI. **Done (emit side).** `llvmgen/LLVMGenValueWitness.swift` defines the
    VWT struct type and an on-demand cached per-concrete-type emitter (`vwt_<type>`, internal constant):
    real `size`/`align` from the value layout, a POD flag set when the type holds no managed pointers
    (memcpy copy/move + no-op destroy under the tracing GC), null copy/move/destroy pointers (trivial
    path), and `type_id` a placeholder filled by 100.4.7.4. Monomorphized generic value-type
    instantiations are emitted at finalization; verified via `--emit-llvm` (`vwt_Box<Int>` = size 8 POD,
    `vwt_Opt<Int>` = size 16 POD). **Consumed by 100.4.3.3** (the erased body reads size/flags to buffer
    and memcpy `T`); representing an opaque `T` as a caller-provided buffer is that lowering step.
  - 100.4.3.3 — Erased generic-function lowering: lower a function with residual `.typeParam` through
    NOIR → SSAIR → LLVM — `T` params / locals / returns as VWT-driven opaque buffers, requirement calls
    via protocol witness dispatch, copy / move / destroy via VWT — and retire the "must be
    monomorphized" hard-error for the erased case. **Large, cross-cutting (NOIR + mono + backend);
    extracted to the working doc `100.4.3.3.md` at the project root** (full context + the residual-
    `.typeParam` blast radius). Decomposition there:
    - 100.4.3.3.1 — `NOIRFunc` carries visibility; mono emits an erased copy of each public generic
      function (type params retained, witness/VWT params added) under the bare erased symbol.
    - 100.4.3.3.2 — backend lowers a move-only erased body (residual `.typeParam` → opaque buffer, `T`
      return → sret, moves → VWT-sized memcpy). Target: `public fun id<T>(x: T) -> T` emits IR-verified
      erased code, producer-side. First milestone.
    - 100.4.3.3.3 — requirement dispatch for bounded `T` via the PWT. **Done, POD-scoped, end-to-end.**
      Producer: `declareErasedFunction` adds a PWT parameter per (type parameter, bound) after the VWTs
      (bounds name-sorted); a requirement call on a `.typeParam` receiver lowers to a witness call
      (`FunctionLowerer` resolves the bound declaring the method) that the backend dispatches through the
      PWT parameter with the value buffer as self (`witnessDispatchErased`). Consumer: `interfaceToDecls`
      reconstructs imported interfaces; `buildIRInterfaces` includes them so codegen has the slot layout;
      the call threads a **value-buffer-self** witness table (`witnessInstanceErased` — dedicated erased
      thunks, so the `any I` box-self path is untouched, protecting release dynamic-dispatch perf). Self-ABI
      chosen as **Option 3** (separate erased thunks) over unifying the existential thunk, on GC-soundness
      and hot-path-perf grounds. **POD guardrail:** a non-POD type argument is a clear compile error until
      the GC trace map lands (100.4.3.6/100.4.7.4) — the erased buffer isn't yet scannable, so only
      pointer-free type arguments cross soundly. Fixture `module_generic_bound` (`total<T: Sized>`,
      conformer `Point` with the impl in the consumer). Deferred within .3.3.3: class/actor conformers
      (non-POD), covariant-`Self` requirements, and importing a conformer whose method impls live in the
      producer (needs producer-exported witness tables).
    - 100.4.3.3.4 — `T`-field access / constructing `T`-containing values. **Done for struct-composed POD
      types, end-to-end** (field read, construction, composed return). Mono emits each generic type
      **template** (type parameters retained, methods stripped) so an erased body has a composed
      `.generic` receiver's layout; `llvmType(.generic)` is an opaque buffer. **Derived-VWT synthesis**
      (backend.md §4 open item, now built): the value layout is the uniform 8-byte-slot model, so a
      composed type's size is the sum of its field sizes and a field's offset is the running prefix sum —
      each field size a runtime VWT load for a `T` field, a static slot count for a concrete one
      (`erasedTypeSize` / `erasedFieldOffset`). A field read GEPs the buffer by the derived offset; a `ret`
      of a composed value memcpys the derived size to the sret buffer; construction allocates a
      derived-sized buffer and copies each field to its offset. Fixtures `module_generic_field` (`Box<T>` +
      `unwrap`) and `module_generic_compose` (`Pair<T>` + `make` construction/return + `snd` non-first
      field). **Also fixed:** an erased-call fast-path bug — a second call to the same imported generic hit
      the `callables` cache and lowered as a raw by-value call; the `externalGenericSigs` check now precedes
      the cache. **Enum-composed erased types done too** (`Opt<T>`): the tagged buffer layout is a tag word
      plus a payload sized to the largest case (a runtime max over the cases' derived sizes); construction
      stamps the tag and copies the payload, `enumTag`/`extractPayload`/`switch` read the tag and payload
      fields at their derived offsets, and a composed enum return memcpys the derived size. Fixtures
      `module_generic_field`/`_compose`/`_enum`. **Deferred:** the GC-trace of a non-POD opaque `T` (couples
      100.4.7 — the POD guardrail holds until then).
  - 100.4.3.4 — Witness-argument ABI: pass each type parameter's metadata / VWT plus one protocol witness
    table per bound as hidden leading parameters; the producer emits the compiled-once erased symbol, the
    consumer emits the external call threading the witnesses for its concrete type arguments. **Done for
    the move-only, unbounded case.** `interfaceToDecls` reconstructs imported generic functions (external,
    body-free) so a consumer's call type-checks; Sema carries their signatures out as `ExternalGenericSig`;
    the SSAIR→LLVM egress lowers a call to one through the erased ABI — a VWT global per concrete type
    argument, a result buffer when the return mentions a type parameter, and each `.typeParam` value boxed
    into a stack buffer, reading the result back after the call. Fixture `module_generic_fn` (imports
    `id<T>`, calls at `Int`) compiles and runs, matching the whole-program result. **Deferred:** a **bounded**
    type parameter's PWT arguments + requirement dispatch (pairs with 100.4.3.3.3), and `T`-field / `T`-value
    construction across the boundary (pairs with 100.4.3.3.4).
  - 100.4.3.5 — Generic methods on imported generic types (`Option.isSome()` across a boundary) — method
    erasure atop 100.4.3.3.
  - 100.4.3.6 — GC-trace of an opaque `T`: the type metadata / VWT carries the per-type GC trace map so a
    tracing / moving collector scans an erased `T`'s stack buffer and heap copies. **Couples with
    100.4.7** (cross-module type-id / type-map unification) — the same GC work from two sides; build
    together.
  - 100.4.3.7 (tests) — cross-module generic function, generic type, and generic method; erased output
    matches the whole-program mono golden (same observable result).

  *Residual-`.typeParam` blast radius* (the sites erased lowering must handle) is extracted to the
  working doc **`100.4.3.3.md`** at the project root, alongside the 100.4.3.3 decomposition.
- 100.4.4 — Link separate per-module objects + runtime.
- 100.4.5 — Driver incremental cache: content-addressed per-module keying; interface byte-stability;
  skip unchanged modules; rebuild on interface change.
- 100.4.6 (tests) — Incremental (body edit doesn't rebuild dependents); interface stability;
  separate-compile output matches the whole-program golden.
- 100.4.7 — Cross-module GC type-id / type-map unification: a dependency module's heap types get stable
  cross-module type-ids and contribute to the `nomu_gc_typemap_*` tables, so a GC-traced type crossing a
  module boundary is scanned (closes the entry-only GC-type-map interim). Prerequisite for the full
  prelude module; see the mini-horizon under 100.5. **Scoped below.**

  *The problem, three facets.* (1) Type-ids are a **per-module dense counter from 0**
  (`typeId(forHeapType:)` = `UInt64(typeMaps.count)`, `llvmgen/LLVMGenGCMaps.swift`), so separately-compiled
  modules collide on id values. (2) The maps are single flat extern-global arrays
  (`nomu_gc_typemap_data`/`index`/`sizes`/`kind`/`stride`/`count`) emitted by **exactly one object** — the
  entry (`emitTypeMaps: false` for deps) — so a dependency's heap types never enter them. (3) The runtime
  indexes those arrays **densely by `type_id`** (`nomu_gc_typemap(id)` bounds-checks against
  `…_count`, `runtime.c`), and the id is stamped into the object header, where the bit budget gives it
  only **32 bits** (mark = bit 32, forwarded = bit 33; `stdlib/runtime.nomu`) — so a global id must stay a
  small dense integer, ruling out a 64-bit content hash or a descriptor address in the header.

  *Decision — link-time offset-as-id (Go's `typeOff` model).* Each module emits its heap types'
  **fixed-size descriptors** (`{ size, align, kind, flags, ptrmap_off }`, variable pointer-map out of
  line) into one aggregated linker section, as COMDAT/weak symbols so duplicates fold to one. The
  header's 32-bit type-id field holds the descriptor's **section offset** (`&desc − __start`, a
  link-resolved symbol difference); the GC reads metadata in place at `section_base + offset`. No
  id-numbering pass, no id→metadata tables, no per-object id namespace. *Why:* per-module compiles stay
  hermetic — all whole-program work is confined to the link (the same mechanism as a cross-module call),
  so it does not break Bazel — and a symbol-difference offset is PIE-clean; the rejected dense-id and
  two-level `(module_id, local_id)` schemes both need whole-graph analysis *before* per-module codegen.
  Fixed-size descriptors keep a dense ordinal derivable (`offset / record_size`) if anything later needs
  one.

  - 100.4.7.1 — Type descriptors: emit a fixed-size descriptor per heap type into the aggregated section
    (COMDAT/weak), pointer-map out of line; retire the per-module dense counter and the single-object
    flat-array emission (`emitTypeMaps`, `emitTypeMaps: false` for deps).
  - 100.4.7.2 — Header stamp + GC read: the header holds `&desc − __start`; the GC resolves
    `section_base + offset` and reads the descriptor in place.
  - 100.4.7.3 — Cross-module + shared types: a consumer stamping an imported (or locally-instantiated
    generic) type references the producer's descriptor symbol, resolved at link; shared descriptors
    (prelude, shared instantiations) fold by symbol (couples 100.4.3.6).
  - 100.4.7.4 — VWT `type_id` becomes the same descriptor offset (shared with 100.4.3, backend.md §4).
  - 100.4.7.5 (tests) — a GC-traced heap type defined in a dependency, and a generic instantiation
    crossing the boundary, are scanned / relocated correctly under forced GC (the `Tn` obligations,
    `ssair.md`).
- *Deliverable:* editing a module body doesn't rebuild its dependents. (Cross-module generics are
  witness-dispatched here; perf restored in 100.5.)

### 100.5 — Specialization dial + release mode

Restore monomorphized performance under separate compilation via the flag-driven dial.

- 100.5.1 — `.bir` body-IR serialization (bespoke, keyed by generic id).
- 100.5.2 — `--mono` flag + mode defaults (debug=none, release=a specialization spectrum along the
  dial, not a guarantee of full monomorphization — the erased witness path can still run in release,
  so its performance is a release-mode property); flag in the cache key.
- 100.5.3 — Cross-module specialization: consuming module reads deps' `.bir`, specializes its used
  instances; call sites dispatch specialized vs witness.
- 100.5.4 — Link-fold duplicate instances (COMDAT/weak symbols).
- 100.5.5 (tests) — Release perf parity with whole-program mono (golden/perf); debug-fast and
  release-specialized both correct.
- *Deliverable:* release recovers monomorphized performance; debug stays fast and incremental.

### Mini-horizon — the full prelude module (100.3.7 dependency chain)

**Goal:** `core`/`runtime`/`std` become real packages compiled once and referenced via the
external-symbol path; `prependPrelude` + WeakODR retire; runtime-subset moves onto module membership
(task 149). Reaching it needs the deferred half of the interface, the erased generic path, and the
GC-map interim closed. This overlay sequences existing phases toward that one goal; it does not add
work outside task 100.

Where the prerequisites stand today: the witness *execution* path exists only for existentials (`any I`
is a heap-boxed `{witness, payload}`, dispatched via `call .witness` in `FunctionLowerer`); generic
**functions** are always monomorphized (`Monomorphize` specializes every instantiation, and
`FunctionLowerer` errors if a static requirement survives to codegen). The `.nmi` is the non-generic
subset (`interfaceToDecls` reconstructs everything as `generics: []`, no enums/methods/conformances).
GC type maps are entry-only. So the goal is gated, in this order:

1. **Complete 100.4.1 — the full `.nmi`.** Extend interface emit + the (de)serializer to carry enums,
   methods (including on generic types), generic signatures + bounds, conformances, witness /
   value-witness layouts, per-type GC trace metadata, and the mutating-ness / shareability facts. The
   contract a consumer must see to use prelude generics. Prerequisite for both items below.

   *Pinned conventions (internal ABI, no language surface):*
   - **Witness-slot order.** An interface's requirement slots are keyed `name` (method), `name.get` /
     `name.set` (property accessor) — the same keys `ModuleContext.interfaceSlots` already uses — and
     the witness-table index is those keys in lexicographic order. The `.nmi` records the requirements
     name-sorted; both producer and consumer derive the identical order from that one rule.
   - **Member export.** A public type exports all of its members (methods, computed properties, enum
     cases). A private helper method on a public type is the refinement case, left for later.
   - **Determinism.** Enums, interfaces, methods, properties, conformances are name-sorted; generic
     parameters, enum cases, and fields keep declared order (position / discriminant / layout are
     significant).
   *Deferred out of this step:* per-type layout + GC pointer-map (semantic layout info; couples with
   100.4.7) and the mutating-ness / shareability contract facts (gate 100.4.5, not the prelude). This
   step carries the declaration/signature surface; consuming generics across a boundary is 100.4.3.
2. **100.4.3 — cross-module generics via witness dispatch.** Build the erased generic-function path: a
   `fun f<T: I>` lowered once to take a witness dictionary + a value-witness table for `T` (size /
   align / copy / move / destroy) and dispatch `T`'s requirements through it, instead of being
   monomorphized away. Reuse the existential `.witness` execution machinery; the new ABI piece is
   value-witnesses for stack `T`. Debug default = witnesses at module edges; specialization stays the
   100.5 dial. This is what lets `Option`/`Result` live in a compiled-once `std`.
3. **100.4.7 (new) — cross-module GC type-id / type-map unification.** Close the entry-only GC-type-map
   interim: a dependency (and prelude) module's heap types get stable cross-module type-ids and
   contribute to the `nomu_gc_typemap_*` tables, so a GC-traced type crossing a module boundary is
   scanned. Couples with the value-witness GC-trace metadata from step 1/2, and also fixes plain
   non-generic dependency heap types (independent of 100.4.3).
4. **100.3.7 — prelude as packages (full), the goal.** With 1–3 in place: `core` (ambient built-in
   types + intrinsics / FFI leaves), `runtime` (privileged, subset-by-module-membership — the task 149
   designation swap), and `std` (`Option`/`Result`/helpers + the curated auto-imported prelude subset)
   become real packages compiled once, referenced via the external path. Retire `prependPrelude` +
   WeakODR. `core`-function gating (ambient vs `unsafe`) stays deferred — no new keyword surface without
   agreement.

**Dependency graph:** 100.4.1 → {100.4.3, 100.4.7} → 100.3.7. Steps 2 and 3 are coupled through
GC-trace metadata and can be built together. Partial fallback (if the goal is deferred): the
non-generic prelude surface — the `rt*` runtime functions plus `abs`/`max`/`min`, `Time`/`SimpleRNG`
methods — can move to compiled-once packages on the existing external path now, keeping `Option`/`Result`
ambient, which retires WeakODR for everything except generic instantiations.

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
