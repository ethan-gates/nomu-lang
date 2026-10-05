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
(100.1–100.2 + the packaging layer, now [173](173-package-model-driver-cli.md)/[174](174-prelude-as-packages.md)),
then swap the build model underneath without changing the surface (100.4–100.5).** That
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
  deferred until directory-as-module exists (100.2.1+); tracked under [155](155-integration-suite-harness.md)
  (the suite migration folded in from the old 100.3.8).
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
      inference). Sealed/cross-package rules are not live ([173](173-package-model-driver-cli.md) §173.3.1).
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
  cross-package linkage exists. That cross-boundary half is tracked as **[173](173-package-model-driver-cli.md) §173.3.1**.
- 100.2.6 — Mangling: encode real package + relative module path, replacing the implied `main`
  (generic-arg encoding already present). Mangling is currently **spread** (9-encoding in
  `midend/sources/Monomorphize.swift`; `nomu_` construction across `llvmgen/*`); **consolidate it into
  one 154-style capability module** here to restore the single swap point (backend.md §3).
- 100.2.7 — Compile all modules whole-program in module-topological order (still mono).
- 100.2.8 (tests) — Multi-module fixtures; visibility errors; re-export; collision diagnostics.
- *Deliverable:* multi-module programs compile and run whole-program; full surface works.

### 100.3 — Packages, manifest, driver, entry points — **moved out of task 100**

The package structure + usable build tool was pulled out of 100, since its prerequisites (100.1/100.2/100.4)
are done, nothing remaining in 100 (the 100.5 dial) depends on it, and it is a layer *around* the compiler
rather than compilation-pipeline work. It splits into:

- **[173](173-package-model-driver-cli.md) — Package model, manifest + driver CLI** (the old 100.3.1–100.3.6):
  JSON manifest + schema, package boundary / workspace / identity, seal enforcement (incl. the cross-package
  `package`-tier + qualifier item carried from 100.4's interims), entry points / `bin` declarations / ordered
  init, and the `compile`/`build`/`run`/`test`/`query` single-binary driver. Deliverable: `nomuc build/run/test`
  on a manifest'd package with multiple bins.
- **[174](174-prelude-as-packages.md) — Prelude as packages** (the old 100.3.7 + its Mini-horizon): `core` /
  `runtime` / `std` become real packages compiled once and referenced, retiring `prependPrelude` + the
  `WeakODR` per-object duplication (the 100.4.4 interim). Its three prerequisites — the full `.nmi` (100.4.1),
  cross-module generics (100.4.3), cross-module GC type-ids (100.4.7) — are now all done. Couples with
  [149](149-runtime-subset.md) (runtime-subset by module membership).
- **Suite migration to 1 dir == 1 module** (the old 100.3.8) folds into
  [155](155-integration-suite-harness.md).

### 100.4 — Separate compilation (witness baseline)

The architectural shift: module = compilation unit, compiled against interfaces, incremental.

**Status — 100.4 complete.** Every sub-phase is done (100.4.1 `.nmi` generation, 100.4.2 per-module compile
against deps' `.nmi`, 100.4.3 cross-module generics via witness dispatch, 100.4.4 separate-object + runtime
link, 100.4.7 cross-module GC type-id unification) or moved to a dedicated task (100.4.5/.6 → the build cache
[172](172-incremental-build-cache.md)). The driver compiles each module to its own object in topological
order, a consumer resolves and links against a dependency's serialized interface (import-scoped, public-only;
non-public symbols are invisible by construction), and the objects + runtime link into the binary. Module-path
mangling is in: a dependency's symbols carry its module-path qualifier (`nomu_fn_<path>_<name>`, etc.), a
consumer derives the same qualifier from the interface's `modulePath`, and the entry module plus the C-ABI
prelude/runtime symbols stay bare (nothing imports the entry; the C runtime pins the prelude names). The
deferred edges of 100.4.3 live in [171](171-modules-cleanup.md); the packaging + build tool spun out to
[173](173-package-model-driver-cli.md) (package model, manifest, driver CLI) and
[174](174-prelude-as-packages.md) (prelude-as-packages); the remaining in-100 work is 100.5 (the
specialization dial). Two carried-forward **interims**, both owned by other phases:
- **Weak prelude linkage.** The prelude is still prepended to every module, so its functions get
  `WeakODR` linkage to fold the per-object duplicates. Proper fix: [174](174-prelude-as-packages.md)
  (prelude-as-packages).
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
    - 100.4.3.3.3 — requirement dispatch for bounded `T` via the PWT. **Done, end-to-end; POD and non-POD
      value/class conformers.** Producer: `declareErasedFunction` adds a PWT parameter per (type parameter,
      bound) after the VWTs (bounds name-sorted); a requirement call on a `.typeParam` receiver lowers to a
      witness call (`FunctionLowerer` resolves the bound declaring the method) that the backend dispatches
      through the PWT parameter with the value buffer as self (`witnessDispatchErased`). Consumer:
      `interfaceToDecls` reconstructs imported interfaces; `buildIRInterfaces` includes them so codegen has
      the slot layout; the call threads a **value-buffer-self** witness table (`witnessInstanceErased` —
      dedicated erased thunks, so the `any I` box-self path is untouched, protecting release
      dynamic-dispatch perf). Self-ABI chosen as **Option 3** (separate erased thunks) over unifying the
      existential thunk, on GC-soundness and hot-path-perf grounds. **Non-POD lifted:** the old POD
      guardrail is gone now that an erased arg buffer is a typed GC root (100.4.3.6) and its VWT carries the
      value-layout descriptor (100.4.7.4). A **non-POD value-type** conformer (`struct`/`enum` with managed
      fields — e.g. an `Array` field) crosses: `bridgeErasedThunkSelf` loads the value from the buffer as
      before, and the buffer is scanned via its descriptor. A **class** conformer crosses too:
      `bridgeErasedThunkSelf` loads the object reference the buffer holds at offset 0 as the `p1` self
      (`propThunkErased` likewise loads the reference then GEPs the object for a stored-property
      requirement). Fixtures `module_generic_bound` (`total<T: Sized>`, POD `Point`) and
      `module_generic_bound_nonpod` (`holdGet<T: Valued>`, class conformer `Cell` held across a force-all
      evacuation — teeth: `fixed 1 roots`, the buffer's reference fixed up, dispatch reads the relocated
      object). **Deferred within .3.3.3:** actor conformers (same reference ABI, but synchronous erased
      dispatch on an actor is untested — rejected in `bridgeErasedThunkSelf`), covariant-`Self` requirements
      (rejected in `methodThunkErased`), and importing a conformer whose method impls live in the producer
      (needs producer-exported witness tables). Owned by [171](171-modules-cleanup.md) §171.2.
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
      `module_generic_field`/`_compose`/`_enum`. The GC-trace of a non-POD opaque `T` that this composition
      enables is handled in **100.4.3.6** (typed roots) + **100.4.7** (descriptors) — now done for the
      straight-line and common loop forms; see those items for the residual gaps.
  - 100.4.3.4 — Witness-argument ABI: pass each type parameter's metadata / VWT plus one protocol witness
    table per bound as hidden leading parameters; the producer emits the compiled-once erased symbol, the
    consumer emits the external call threading the witnesses for its concrete type arguments. **Done for
    the move-only, unbounded case.** `interfaceToDecls` reconstructs imported generic functions (external,
    body-free) so a consumer's call type-checks; Sema carries their signatures out as `ExternalGenericSig`;
    the SSAIR→LLVM egress lowers a call to one through the erased ABI — a VWT global per concrete type
    argument, a result buffer when the return mentions a type parameter, and each `.typeParam` value boxed
    into a stack buffer, reading the result back after the call. Fixture `module_generic_fn` (imports
    `id<T>`, calls at `Int`) compiles and runs, matching the whole-program result. The once-deferred
    extensions are now done in their own items: a **bounded** type parameter's PWT arguments + requirement
    dispatch in 100.4.3.3.3 (POD and non-POD value/class conformers), and `T`-field / `T`-value
    construction across the boundary in 100.4.3.3.4.
  - 100.4.3.5 — Methods on imported types across a boundary; method erasure atop 100.4.3.3. Decomposed
    into the numbered sub-phases below; the shared mechanism (set up by 100.4.3.5.1) is: `interfaceToDecls`
    reconstructs a type's methods body-free so `structs`/`classes` carry them and `x.m()` type-checks, Sema
    lowers the imported type for layout with **method bodies stripped** (`strippingMethodBodies`) emitting
    no definition, and the call lowers to the producer's symbol by decoding the receiver's origin-encoded
    type name (`m:<origin@Type>:method` → `Mangle.method(Type, method, qualifier)`).
    - 100.4.3.5.1 — **non-static, non-generic instance methods on imported non-generic types. Done.**
      Before this, no method (generic or not) resolved on an imported type — the `.nmi` serialized methods
      but `interfaceToDecls` dropped them. Parameter types follow the values ssairgen produced (a class
      receiver is a reference, a non-mutating value receiver is by value). Fixture `module_method` (a struct
      `Pt.sum()` / `Pt.scaled(by:)` and a class `Counter.doubled()` called across the boundary).
    - 100.4.3.5.2 — **a `mutating` value method across the boundary. Done + green (95/95).** Its
      self-by-pointer ABI needs the method's inferred mutating-ness at the consumer, which 100.4.3.5.1
      drops. The `.nmi` carries it (`InterfaceFunc.isMutating`, 164.4.1); this phase threads the set of
      imported mutating methods (keyed `origin@Type.method`, built in the driver's `externalMutating(of:)`
      from deps' `.nmi`) through `Sema` → `NOIRModule.externalMutatingMethods` → `ModuleContext`, where it
      drives two consumers: the caller mutable-receiver check (`Sema`, unioned with the in-module
      `mutating` set) and the receiver-ABI choice (`ModuleContext.methodIsMutating` → `FunctionLowerer`
      passes `self` by pointer). The egress needs nothing new — it builds the external call's param types
      from the arg values ssairgen produced, so a by-pointer `self` follows automatically. A class method
      is unaffected (self is always a reference). Fixtures: `module_method` extended with a mutating
      `Pt.shift(by:)` on a `var` receiver (the mutation sticks: sum → 23); `module_mut_method_bad` asserts
      the compile error when the receiver is a `let`.
    - 100.4.3.5.3 — **generic methods / methods on generic types** (`Option.isSome()` across a boundary) —
      the erased-method path atop 100.4.3.3; the blocker the 100.4.3.7 method-differential leg waits on. The
      erased-receiver ABI is already designed (`backend.md` §4: `self` is a normal value param, a
      value-buffer pointer, after the hidden VWT/PWT/sret params), so this extends the erased-function path
      to a `self`. **Convention (pinned here):** a method's hidden VWT/PWT params cover the **owning type's**
      generics in declaration order, then the method's own generics; the owning-type VWTs are supplied from
      the receiver's instantiation (`Box<Int>` → `Int`'s VWT). Steps (flat — no deeper nesting):
      - 100.4.3.5.3.1 — **producer. Done + green (95/95).** `Monomorphize` keeps generic-type methods on
        the emitted template; `FunctionLowerer.lowerMethod` lowers a generic-value-type method erased —
        `self` typed `.generic(base, [typeParams])` (so self-field access GEPs by VWT offset via the
        existing 100.4.3.3.4 `.generic` path), the SSAFunction carrying the owner's type params then the
        method's own, so the egress declares it under the erased ABI with `self` in the §4 value slot.
        Verified: a public `Box<T>.get() -> T` emits `@nomu_m_Box_get(ptr VWT, ptr sret, ptr self)` and
        `Opt<T>.present() -> Bool` emits `@nomu_m_Opt_present(ptr VWT, ptr self)`; both lower, own-module
        calls still use the monomorphized specialization (unchanged output), suite green. Refinement (erased
        emission gated to all generic types rather than public-only — a code-size, not correctness, item) →
        [171](171-modules-cleanup.md) §171.6. (Generic **class** receivers landed later in 100.4.3.9; the
        generic-enum discriminant check landed in 100.4.3.5.3.4.)
      - 100.4.3.5.3.2 — **interface + resolution. Done + green (95/95).** `interfaceToDecls` now
        reconstructs **enum** methods too (struct/class already did); `Sema` registers each imported
        generic-type method into `externalGenericSigs` keyed `m:origin@Type:method`, with hidden generics =
        owning type's then the method's own, `self` the leading `.generic` value param, so the call-site
        lowering (.3.3) can route to the erased symbol with the receiver's type-arg VWTs. Behavior-
        preserving: the registered erased key does not match today's monomorphized call name, so nothing
        changes until .3.3. Verified: an imported `Box<T>.get()` and `Opt<T>.present()` now type-check and
        resolve (they reach lowering — `get` link-fails on the mono'd symbol, `present` hits `unknown call
        target` — both .3.3's to fix), where the enum method previously failed to resolve at all.
      - 100.4.3.5.3.3 — **consumer call lowering. Done + green (96/96) for struct generic methods.**
        `Monomorphize` records each instantiation's type args (`NOIRModule.monoTypeArgs`, threaded to the
        egress like `opaqueUnderlyings`). The egress `m:` branch detects a call whose receiver is a mono'd
        instantiation of an imported generic type with a registered erased sig (.3.2) and routes it through
        `emitErasedExternalCall` (gained a `symbolOverride` for `Mangle.method`): `self` is `sig.params[0]`
        (`.generic`), spilled to a buffer by the existing arg path; the receiver's type args supply the
        VWTs; the erased symbol drops the type-arg suffix (`nomu_m_util_Box_get`). A fix in `selfFieldRead`:
        an erased `self` yields a field's **address** (its `T` representation), never a loaded value — the
        `.generic` convention. Fixture `module_generic_method`: `Box<T>.get() -> T` (erased T return, sret)
        and `Box<T>.tagged() -> Bool` (concrete return) called across the boundary → `7` / `1`.
        **Carry-forward:** generic **enum** methods (`Opt<T>.present()`) are blocked by a pre-existing gap —
        an imported generic **enum**'s receiver type resolves without its `origin@` prefix, so the call
        symbol is `m:Opt<Int>:present` (no origin) and the erased routing can't key it. This is an
        enum-type-resolution issue, independent of the erased-method ABI; it lands with .3.4.
      - 100.4.3.5.3.4 — **generic-enum methods across the boundary. Done + green (97/97).** Closed the
        enum-origin gap the .3.3 carry-forward flagged: an imported generic **enum** now carries its
        `origin@` prefix like a struct, so the erased method call keys and routes. Fixes, symmetric with
        the struct path: `encodeExternalDecl` gained an `.enumDecl` case (name + case-field types encoded);
        `ownTypes` and `moduleTypes` include `iface.enums`; the bare generic-type-annotation path in
        `Sema.resolve` origin-resolves the base name (`Opt<Int>` → `origin@Opt`, the same resolution the
        non-generic bare-name path already did — this also fixed explicit `Box<Int>` annotations, which had
        only worked via constructor inference). A fix in `FunctionLowerer.readVar`: an erased `.generic`
        value slot (the method's `self`) reads as the buffer **pointer** directly, never a load — so
        `switch self` reads the tag with a single load (the prior double-load dereferenced the tag value and
        segfaulted on a `.some` tag of 0). Fixture `module_generic_enum_method`: `Opt<T>.present() -> Bool`
        and `Opt<T>.orElse(d: T) -> T` (erased-`T` payload returned by sret) → `1`/`5`/`0`/`9`.
        **Moved out:** **methods with their own type params** (`Box<T>.map<U>`) are not an edge of this
        boundary work — method-level generics are unimplemented in-module too (even on a non-generic type,
        a method's own `<U>` never enters scope). Owned end to end by [170](170-method-level-generics.md);
        the 100.4.3.7 method-differential leg for generic **methods-with-own-params** rides 170.5.
      - 100.4.3.7 (method leg, structs/enums over the type's params) — **done.** Whole-program twins
        (`wp_generic_method` / `wp_generic_enum_method`) assert the erased split-module generic-**type**-method
        output matches mono; the method-own-params leg waits on [170](170-method-level-generics.md).
    - 100.4.3.5.4 — **static methods + computed properties on imported types. Non-generic types done + green
      (98/98); generic types split out to 100.4.3.8.** (The original phrasing was unqualified — "on imported
      types" — so this is a resized scope: the non-generic member case shipped, the generic-type case is its
      own sibling phase. "Computed-property *requirements*" in the interface-conformance sense is not what was
      built here — these are computed-property *members*; a conformance-requirement reading is unaddressed.)
      Both members were carried in the `.nmi` already but dropped on reconstruction; now reconstructed and
      linked.
      - **Computed properties.** `interfaceToDecls` reconstructs each `InterfaceProperty` as a body-free
        `ComputedProperty` (getter, plus a setter when settable); `registerProps` (already run over
        `externalDecls`) records it, so `x.p` / `x.p = v` type-check and lower to accessor calls
        (`p.get` / `p.set`) that link to the producer's accessor symbols — the imported-instance-method
        model. `strippingMethodBodies` now also strips properties so the consumer emits no accessor
        definition (registration uses the un-stripped original). A **mutating setter** needs the
        self-by-pointer ABI the same way a mutating method does (100.4.3.5.2): the accessor's inferred
        mutating-ness, already in the fact store (accessors lower to methods, so `collectFacts` keys
        `Type.p.set`), is carried on the `.nmi` as `InterfaceProperty.getterMutating`/`setterMutating`, and
        the driver's `externalMutating(of:)` adds the mutating accessor keys so the consumer's mutable-
        receiver check + ABI match the producer. Verified: a `let`-receiver setter is rejected with the
        mutating-receiver diagnostic across the boundary.
      - **Static methods.** A `static fun` is free-function-shaped (the producer emits it as a free function
        `Type.method`), so `interfaceToDecls` reconstructs it as a static `FuncDecl`, Sema registers it as an
        external free function keyed `origin@Type.method` (`externalFuncNames`), and the call-site resolution
        origin-resolves the bare type name (new `Sema.importedTypeIdentity`) so `Rect.square(…)` targets
        `origin@Rect.square` — linked via the external-function path. `encodeExternalDecl` gained an `encM`
        (encode method signature types) + `encP` (encode property type) so a `-> Rect` return / property type
        resolves to its per-origin identity.
        Fixture `module_static_computed`: `Rect.square(side:) -> Rect` (static), `Rect.area` (read),
        `Rect.scale` (get + mutating set), `Shape.area` (enum computed property) → `25`/`2`/`45`/`16`.
        **Deferred:** static methods / computed properties on imported **generic** types (ride the erased
        paths — a generic-type computed property is an erased accessor method like 100.4.3.5.3; a generic-type
        static method rides the erased generic-function path), and **generic** static methods (own type
        params) which ride [170](170-method-level-generics.md).
  - 100.4.3.6 — GC-trace of an opaque `T`: the type metadata / VWT carries the per-type GC trace map so a
    tracing / moving collector scans an erased `T`'s stack buffer and heap copies. **Couples with
    100.4.7** (cross-module type-id / type-map unification) — the same GC work from two sides; built
    together. **Mechanism: typed stack roots (hybrid).** An erased `T` lives in an opaque byte buffer the
    LLVM stackmap can't see into, so generated code registers each live non-POD `T` buffer on a per-fiber
    shadow stack (`{prev, buffer, vwt}` nodes on the native stack; fiber head at offset 288); the STW root
    walk (`nomuSchedWalkRoots` → `rtWalkShadow`) expands each via the VWT's value-layout descriptor
    (100.4.7.4) into the buffer's interior managed-pointer slots, which ride the ordinary evacuation +
    in-place fixup. POD args stay unregistered (the hybrid fast path keeps them pure inline buffers).
    Boxing was rejected: the producer is compiled once with `T` erased and can't statically choose
    box-vs-inline, so a uniform box either regresses the POD path or is thrown away.
    **Done (consumer-side):** registration for non-POD **unbounded** erased args (`emitErasedExternalCall`
    wraps the call in `rtShadowSave`/`rtShadowPush`/`rtShadowPopTo`), end-to-end under a forced moving STW
    — fixture `module_generic_nonpod` (a non-POD `T` reachable only through the erased buffer survives
    force-all evacuation; teeth-checked via the STW root count in stderr).
    **Done (producer-internal, straight-line):** an erased body that *constructs* a composed value with a
    `T`-component (`makeStruct`/`makeEnum` → `erased.box`/`erased.enum`) registers that component as a
    typed root for the rest of the frame. A function-scoped save/restore brackets it: the erased prologue
    captures the shadow-top (`curProducerSave`, emitted only when the frame builds a registrable
    composite), each construction pushes an entry-hoisted node per `T`-component (bare `T` via the runtime
    VWT parameter; a nested composed **struct** field recurses; a POD `T` is registered too and expands to
    nothing in the walk), and every `ret` `rtShadowPopTo`s the saved top so the pushes unwind on any exit.
    Fixture `module_generic_producer` (an erased `holdBoxed<T>` composes `Box<T>` and holds it across
    force-all evacuation; the box's own copy of the pointer is fixed up — teeth: the stderr root count is
    `fixed 2 roots`, the arg buffer plus the box component, vs `fixed 1 roots` and a moved-from read when
    producer registration is disabled).
    **Done (producer-internal, loops):** a composite constructed inside a loop is registered too, scoped by
    a loop-local unwind — each loop header saves the shadow-top into `headerSaveSlot[header]`, and every
    back-edge `rtShadowPopTo`s it (`curBackEdges`) so the iteration's pushes clear before the next
    iteration re-pushes the same entry-hoisted nodes; without the pop the re-push would set a node's `prev`
    to itself and cycle the chain. Fixture `module_generic_producer_loop` (a `Box<T>` rebuilt each
    iteration and held across repeated force-all evacuations; teeth: with the back-edge pop removed the
    root walk hits the self-referential chain and hangs). **Deferred:** (a) a composite that is
    **loop-carried or live-out of the loop** (its buffer flows through a φ to a later iteration or past the
    loop) is protected only within its construction iteration — the back-edge pop unwinds it, and it is
    re-registered only at a construction site, so a collection in a later iteration while it is live sees
    it unregistered (no worse than before, no cycle); full coverage wants per-iteration nodes or φ-aware
    lifetime; (b) a nested composed **enum** field (e.g. `Wrap<Opt<T>>`) — the active case (and so which
    payload is managed) is a runtime property, so only the top-level `makeEnum`, which knows its own case,
    registers its payload; (c) the **bounded** non-POD path is now open for value-type and class conformers
    (guardrail lifted, the non-POD arg buffer rides the same typed-root registration; task 100.4.3.3.3) —
    only actor conformers and covariant-`Self` remain; (d) a non-scheduler run config (no `NOMU_SCHED=nomu`)
    has no shadow walk. Deferred edges (a)/(b)/(d) are owned by [171](171-modules-cleanup.md) §171.3; (c)'s
    actor/covariant-`Self` remainder by §171.2.
  - 100.4.3.7 (tests) — cross-module generic function, generic type, and generic method; erased output
    matches the whole-program mono golden (same observable result). **Partial.** The generic-function and
    generic-type/field legs are covered by whole-program twins asserting the same output as the erased
    split-module fixtures: `wp_generic_fn.nomu` ↔ `module_generic_fn` (`id<T>`), `wp_generic_field.nomu` ↔
    `module_generic_field` (`Box<T>` + `unwrap<T>`), each monomorphized in one module vs erased across the
    boundary, both `42`. **Done:** the generic-method leg over the **type's** params — whole-program twins
    `wp_generic_method.nomu` ↔ `module_generic_method` (`Box<T>.get`/`tagged`, `7`/`1`) and
    `wp_generic_enum_method.nomu` ↔ `module_generic_enum_method` (`Opt<T>.present`/`orElse`, `1`/`5`/`0`/`9`),
    each monomorphized in one module vs erased across the boundary, same output (suite 100/100). **Blocked on
    [170](170-method-level-generics.md):** the method-own-type-params leg (`Box<T>.map<U>`), since
    method-level generics are unimplemented in-module.

  - 100.4.3.8 — **static methods + computed properties on imported *generic* types. Done + green (101/101).**
    The deferred half of 100.4.3.5.4 (non-generic case), split out as a flat sibling. Both reuse machinery
    already in place; the producer already emits the erased accessors, so the work was consumer routing + one
    producer gate.
    - **Computed properties.** An accessor on a generic type is an erased method, so `Sema.collectGlobals`
      now registers each generic type's accessors (`m:origin@Type:p.get` / `.set`) in `externalGenericSigs`
      (`registerGenericAccessors`, `self` the leading `.generic` value param) — the egress `m:` branch then
      routes `x.p` / `x.p = v` on a mono'd instantiation through `emitErasedExternalCall` with the receiver's
      type-arg VWTs, instead of a nonexistent monomorphized accessor symbol. Covers an erased-`T` getter
      (sret), a concrete getter, a mutating setter, and a generic **enum**'s `switch self` accessor.
    - **Static methods.** A `static fun` on a generic type is the producer's erased **generic free function**
      (`Box.of`, parameterized by the owner's params). The producer gate: `lowerStaticMethods` now marks the
      generic static method's free function `.public` so `Monomorphize`'s public-generic erased emission fires
      (a non-generic static method stays `.internal` — a plain symbol, never erased). The consumer:
      `registerStaticMethods` registers the generic case in `externalGenericSigs` keyed `origin@Type.method`,
      and the existing generic-static call site (`Box<Int>.of(…)`, type args threaded) routes through the
      erased free-function path.
    Fixture `module_generic_static_computed`: `Box<Int>.of` + `Box.held`/`flag`, `Opt<Int>.wrap` +
    `Opt.isSome` → `7`/`10`/`1`/`0`. (Still distinct from a method with its *own* type params — task
    [170](170-method-level-generics.md) — and the erased-`T` field *write* gap, 100.4.3.10.)
  - 100.4.3.9 — **methods on an imported generic *class* (reference `self`). Read path done + green.** The
    erased-method path extended from value receivers to a reference receiver (closing the stale
    "not yet handled" note under 100.4.3.5.3.1). Changes: `Monomorphize` emits the generic **class**
    template (like struct/enum) so codegen has its layout; `FunctionLowerer.lowerMethod`'s erased branch
    accepts `.class_`, binding `self` as the managed object pointer (via `write("self", …)`, not a value
    buffer); `llvmType(.generic)` lowers a class base to **`p1`** so the statepoint GC tracks the erased
    `self` as a root; `erasedFieldOffset` adds the 8-byte object header before the VWT-derived field sum;
    the consumer (`emitErasedExternalCall`) passes a class `self` directly (no buffer spill) as `p1`; and
    the erased-return `memcpy` addrspace-casts a `p1` field source to addr0 (sound — a synchronous copy has
    no safepoint). Fixtures `module_generic_class_method` + `wp_generic_class_method` (`Ref<T>.get`/`tagged`
    → `7`/`1`). The **write** path (a mutating class method) is now closed by 100.4.3.10 below. **Open:** the
    §4 ·62 thunk reconciliation for a class receiver — a requirement dispatch on a bounded field of a generic
    class — is deferred to [171](171-modules-cleanup.md) §171.1.
  - 100.4.3.10 — **erased-`T` field *write* in a mutating method. Done + green (105/105).** The write dual of
    the erased field read/return path, for a generic **struct** and **class** alike. Three changes:
    - **Producer (the core).** The backend `.store` of an erased value (`value.type` mentions a type
      parameter) is a VWT-sized memcpy from the source buffer into the destination field, not a first-class
      pointer store — the `curVWTParams`-sized copy (`SSAIRToLLVM` `.store` case), the write dual of the
      construct/return memcpys. Both operands addrspace-cast to addr0 so a `p1` class-field destination is
      sound (a synchronous copy has no safepoint). The write-barrier/store **fuse** in `lowerBlock` is
      suppressed for an erased store (`!mentionsTypeParam`) so it does not fold into `storeField`.
    - **Consumer — mutating recognition.** A generic instantiation (`origin@Box<Int>`) keys the carried
      mutating set under its bare type name (`origin@Box`), since mutating-ness is a property of the generic
      method, not the instantiation (`ModuleContext.methodIsMutating` strips the type-arg suffix). This drives
      ssairgen to pass `self` by its real storage (`structAddr`) for a mutating value method.
    - **Consumer — self by address.** `emitErasedExternalCall` threads a composed value receiver already
      materialized as a pointer (`sig.params[0]` is `.generic` and the arg is an address) straight through as
      the self buffer rather than copying it into a fresh buffer — so the producer's write lands in the
      caller's storage and sticks past the call. A read-only value self (first-class aggregate) and a bare
      `.typeParam` value (incl. a managed class type argument, itself a pointer) are still spilled into a
      buffer. A generic **class** receiver already passes directly as `p1` (100.4.3.9), so the write lands in
      the shared object with only the producer change.
    Fixtures `module_generic_mut_method` (struct `Box<T>.replace` by real storage + class `Ref<T>.replace`
    through the shared object → `7`/`42`/`3`/`99`) and the whole-program twin `wp_generic_mut_method` (same
    output from monomorphized stores). **Deferred (→ [171](171-modules-cleanup.md)):** the generational
    logging barrier for a **non-POD** `T` written into a heap (class) object — the memcpy writes the interior
    managed pointers but logs no remembered-set entry; the current test GC configs full-heap-scan, so none is
    lost under them (§171.4). Also a `let`-receiver mutating-call diagnostic for a generic instantiation (the
    Sema mutation pass keys the un-stripped instantiation name) — a missing error, not a miscompile (§171.5.1).

  *Deferred edges of 100.4.3 — moved to [171](171-modules-cleanup.md).* The uncovered corners noted at each
  sub-phase (requirement dispatch on a bounded field of a generic class [the §4 class-receiver thunk]; the
  bounded-dispatch conformer gaps under 100.4.3.3.3; the erased-`T` GC typed-root corners under 100.4.3.6;
  the non-POD erased-field-write barrier under 100.4.3.10; the diagnostic clarifications) are owned by task
  171 so the remaining module-generics scope has one home. Method-own type params stay in
  [170](170-method-level-generics.md).

  *Residual-`.typeParam` blast radius* (the sites erased lowering must handle) is extracted to the
  working doc **`100.4.3.3.md`** at the project root, alongside the 100.4.3.3 decomposition.
- 100.4.4 — **Link separate per-module objects + runtime. Done + green (106/106).** The mechanism stood
  from 100.4.2/100.4.3 — the driver emits each module to its own object (`__mod_<path>.o`) in topological
  order and links the entry object + every per-module dependency object + the runtime static archive + the GC
  archive into one native binary via `cc` (`emitLLVMBinary`, `extraObjects` = the dep objects). This phase
  closes it with an explicit teeth test: fixture `module_link_diamond` — a diamond (`main` → `left`, `right`;
  `left`, `right` → `data`) where the shared leaf `data` compiles to one object (`__mod_data.o`) that
  satisfies external references from **both** `left.o` and `right.o` at link, so four separately-compiled
  objects (plus the runtime/GC archives) must combine correctly → `23`. **Carried-forward interim (not a
  100.4.4 gap):** the prelude + Nomu runtime tier is still prepended into every module object as
  `weak_odr`/`weak external` symbols, folded to one copy at link (an N-module program compiles the runtime N
  times and discards N−1). The proper fix — the prelude/runtime compiled once and referenced, not duplicated
  — is owned by **[174](174-prelude-as-packages.md)** (prelude-as-packages) and **149** (runtime-subset by
  module membership). Package identity in the mangling qualifier likewise waits on multi-package linkage
  ([173](173-package-model-driver-cli.md) §173.3.1).
- 100.4.5 / 100.4.6 — **Moved out to [172](172-incremental-build-cache.md).** The driver incremental cache
  (content-addressed per-module keying, interface byte-stability, skip-unchanged, rebuild-on-interface-change)
  and its stability / correctness harness (body edit doesn't rebuild dependents; interface stability;
  separate-compile output matches the whole-program golden) are pulled into a dedicated, design-first caching
  task. The separate-compilation artifacts this builds on — sectioned `.nmi` with independent ABI/perf hashes
  (164.4.2), per-module objects (100.4.2) — are in place. The finer-grained query-based successor stays at
  [136](136-incremental-compilation.md).
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
    flat-array emission (`emitTypeMaps`, `emitTypeMaps: false` for deps). **Done.** Record `{ size, stride,
    kind, nptr, ptrmap_off, pad }` (24 B) in `__DATA,__nomu_descs`, variable map in `__DATA,__nomu_ptrmaps`;
    `weak_odr` for foldable shapes (named types, singletons, array buffers) and `internal` per-site
    (closures). Emitted by every module (`emitDescriptors`), the flat arrays gone.
  - 100.4.7.2 — Header stamp + GC read: the header holds `&desc − __start`; the GC resolves
    `section_base + offset` and reads the descriptor in place. **Done.** The offset is the link-time
    `&desc − section$start$__DATA$__nomu_descs` (LLVM `\01` raw-symbol escape so the name matches ld64's
    synthetic section-start symbol); `runtime.c` resolves the base via `getsectiondata` and reads the
    descriptor in place; the self-hosted collector reads it through the same `nomu_gc_type*` accessors,
    with its per-type histogram re-keyed to the ordinal `offset / 24`.
  - 100.4.7.3 — Cross-module + shared types: a consumer stamping an imported (or locally-instantiated
    generic) type references the producer's descriptor symbol, resolved at link; shared descriptors
    (prelude, shared instantiations) fold by symbol (couples 100.4.3.6). **Done.** `weak_odr` descriptors
    keyed by mangled type name fold at link; fixture `module_gc_deptype` holds a dependency-defined managed
    graph (`Holder` → `Inner`, both declared and allocated in the `lib` dependency) live across a churning
    GC-stress workload, so the evacuating collector resolves the dependency's descriptors across the
    boundary to size the copy and fix up the interior `inner` slot. Two suite legs (`module-gc-deptype`
    nogc baseline, `module-gc-deptype-evac` immix + `NOMU_GC_STRESS`) assert identical output; the evac leg
    runs ~2941 defrag-every-GC evacuations with the graph live (confirmed via `NOMU_GC_STATS`), so a
    mis-resolved cross-module descriptor would corrupt the object or leave `inner` pointing at moved-from
    space.
  - 100.4.7.4 — VWT `type_id` becomes the same descriptor offset (shared with 100.4.3, backend.md §4).
    **Done.** The VWT carries a value-layout descriptor (`val_<type>`, managed map at offset 0, no object
    header), its offset filling `type_id`; the typed-root walk reaches a buffer's pointer map through it.
  - 100.4.7.5 (tests) — a GC-traced heap type defined in a dependency, and a generic instantiation
    crossing the boundary, are scanned / relocated correctly under forced GC (the `Tn` obligations,
    `ssair.md`). **Done.** `module_generic_nonpod` covers an erased non-POD type argument under force-all
    evacuation (the scheduler STW path); `module_gc_deptype` covers a dependency-defined non-generic managed
    graph relocated across the boundary under immix GC-stress (the single-threaded evac path), its output
    matching the nogc baseline.
- *Deliverable:* each module compiles against its deps' interfaces to its own object, and the objects +
  runtime link into a binary (100.4.1–100.4.4 + 100.4.7, done). Cross-module generics are witness-dispatched
  here; perf restored in 100.5. The "editing a module body doesn't rebuild its dependents" payoff is the
  caching task [172](172-incremental-build-cache.md) (pulled out of the old 100.4.5/.6).

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

### Mini-horizon — the full prelude module → [174](174-prelude-as-packages.md)

The overlay that sequenced the prelude-as-packages goal moved to task [174](174-prelude-as-packages.md)
along with the goal itself. Its three gating prerequisites — the full `.nmi` (100.4.1), cross-module generics
via witness dispatch (100.4.3), and cross-module GC type-id / type-map unification (100.4.7) — are all now
done, so the gate is open; 174 carries the remaining construction (`core` / `runtime` / `std` as real
packages, retiring `prependPrelude` + `WeakODR`), coupled with [149](149-runtime-subset.md).

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
(graph), llvmgen (mangling). 173/174 → `src/modules/` (package + manifest), driver, nomu-cli. 100.4 →
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

- [161](161-test-framework.md) test framework — after [173](173-package-model-driver-cli.md) (test-module
  identity + `test import`).
- [162](162-interface-serialization-opt.md) serialization optimization — after 100.4 (v1 exists).
- [145](145-monomorphization-cost.md) monomorphization cost model — after 100.5.
- [160](160-resource-embedding.md) resource embedding, [141](141-comptime.md) conditional compilation
  — independent / later.
- [172](172-incremental-build-cache.md) module-granular build cache (the pulled-out 100.4.5/.6);
  [136](136-incremental-compilation.md) fine-grained incremental builds on it.
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
