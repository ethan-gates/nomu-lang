# Prelude as packages

**Avenue:** Infra (+ self-hosting) · **Type/Lifecycle:** `language-feature · ready-to-build` (name
resolution + codegen + linkage + runtime-subset) · **Size:** L · **Status:** done (174.1–174.7 built) — **the prepend is
completely gone.** `core`/`runtime`/`std` are ordinary packages compiled once under the language
workspace and referenced externally: user-facing decls live in `std` (a multi-module package; every file
implicitly imports its default module `std/prelude`, the rest by `import std/<module>`), the runtime
in the `runtime` package (bare + weak-ODR, the C-ABI boundary the C floor and codegen reference by bare
symbol), and `core`'s `ManagedBuffer` is an ambient `nomu/core` type (`EmptyHeader` is a compiler builtin).
No ordinary build prepends anything; a user binary carries **zero** `nomu/runtime@…` or prepended-prelude
duplicate copies. Done: 174.1 (scaffold) + 188 + 174.2.1/.2 (`core` ambient; `Option`/`Result`/numeric helpers
flipped) + 174.2.3 (`String`/`concat`/`Time` flipped) + 174.3.1 (library-object allocation) + 174.3 (content
split) + 174.4 (runtime-subset by package membership) + 174.5 (retire the runtime prepend) + 174.5.1 (retire
the core-substrate prepend: `EmptyHeader` → egress builtin, `ManagedBuffer` → ambient `nomu/core` type) +
174.3.2 (curated prelude: `std` split into `prelude`/`math`/`time`/`random`, implicit `import std`) + 174.6
(dedicated tests) + 174.7 (foreign types in interfaces). Suite 155/155 under MMTk/selfhost/`nomu`; the
white-box runtime tests opt into a runtime prelude via `NOMU_RT_PRELUDE`. · **Source:** pulled out of
[100](100-modules.md) §100.3.7 + the Mini-horizon that sequenced it. Unlike the rest of the old 100.3 (the
packaging/driver layer, [173](173-package-model-driver-cli.md)), this one reaches into the compilation
pipeline — name resolution, codegen, linkage, and the runtime-subset mechanism.

## Goal

`core` / `runtime` / `std` become real packages compiled **once** and referenced via the external-symbol
path, replacing `prependPrelude`'s decl-prepend-into-every-module. This retires the per-object prelude/runtime
duplication (the `WeakODR` weak-prepend interim carried forward from 100.4.4) and enables the extensible
stdlib ([120](120-stdlib-core.md) / [121](121-string-utf8-model.md)).

The package layering — **the split rule is user-accessibility** (decided): a symbol user programs may name
lives in `std`; everything else (the native boundary + non-user-facing substrate) lives in `core`. The
placements below are the starting point, **movable in both directions** as the surface settles — don't
over-fit.

- **`core`** — the native boundary + the non-user-facing ambient substrate. The built-in/native primitives
  (`Int`/`Bool`/`RawPtr` compiler builtins), the GC substrate the compiler/runtime reference but users don't
  (`ManagedBuffer`, `EmptyHeader`), intrinsics / C-leaf ops, and the libc/FFI boundary. **Ambient**
  (auto-imported, no `import`) — a *soft* requirement (see Q4), the goal is auto-import of `core` types.
  Non-Nomu source is a **subset** of `core` (not all of it — `core` also carries Nomu substrate like
  `ManagedBuffer`); the earlier "non-Nomu ⊆ core" framing is relaxed to "`core` is the ambient + native-
  boundary package."
- **`runtime`** — pure Nomu, privileged; runtime-subset-by-default moves from the interim file-designation to
  **`runtime`-package membership** ([149](149-runtime-subset.md)). Uses `core` for native primitives.
- **`std`** — **everything user-facing, as ordinary unprivileged Nomu** (decided preference: `std` stays
  normal Nomu source until we are forced otherwise). Today's `core.nomu` user-facing contents move here —
  `Option`, `Result`, `String`, `concat`, `abs`/`max`/`min`, `Time`, `SimpleRNG` — plus future
  `Array`/collections/IO. A **curated prelude** (`Option`, `Result`, `String` and its methods) is
  auto-imported into every module (Rust `std::prelude` shape); the rest is explicit `import std/...`
  (174.3.2).
  (`String` is user-facing → `std`, even though the compiler references it for string literals — that
  compiler↔`std` coupling is an implementation detail, resolved like any other external symbol.)
- **User packages** — pure Nomu.

**Packaging form (decided):** `core`/`runtime`/`std` **build as ordinary Nomu packages** (real `pkg.json`,
products, resolved through the 187 machinery — not a parallel code path), but their source stays **embedded
in the compiler** (materialized + compiled from the embedded bytes, not read from the user's disk). "Compiled
once" here means **once per build** — a single node in the build graph, referenced externally by every other
module; the *persistent cross-build* cache is [172](172-incremental-build-cache.md)'s job and rides later.

*Resolved sub-decisions:* auto-import of `core` types is the goal but a **soft** requirement (explicit import
acceptable as an interim if it simplifies bring-up). Whether low-level `core` **functions** are `unsafe`-gated
is **deferred** — it implies new surface, which needs agreement; for now `core` functions follow the same
ambient/import rule as types.

**Bootstrapping:** `std` does not auto-import its own prelude; `core` is ambient. The *demand-driven*
emission that links only used prelude parts stays a [136](136-incremental-compilation.md) optimization.

## Prerequisites — now in place

The Mini-horizon that gated this goal sequenced three prerequisites, all now **done**:

1. **The full `.nmi`** (100.4.1, done) — the interface carries enums, methods (incl. on generic types),
   generic signatures + bounds, conformances, witness / value-witness layouts, per-type GC trace metadata,
   and mutating-ness / shareability facts (164.4.x). The contract a consumer must see to use prelude generics.
2. **Cross-module generics via witness dispatch** (100.4.3, done) — a public generic function / type / method
   compiled once and called across a boundary through value-witness + protocol-witness tables, no body
   shipped. This is what lets `Option` / `Result` live in a compiled-once `std`. (Residual edges →
   [171](171-modules-cleanup.md).)
3. **Cross-module GC type-id / type-map unification** (100.4.7, done) — a dependency (and prelude) module's
   heap types get stable cross-module type-ids and contribute to the GC type maps, so a GC-traced prelude
   type crossing a module boundary is scanned.

So the gate is open: the remaining work is the prelude-as-packages construction itself.

## Scope — the three packages

*What each package contains* (the build order + the cutover mechanics are the "Cutover plan" section below,
which owns the 174.x sub-phase numbering).

- **`core` package** — the native boundary + non-user-facing ambient substrate: intrinsics / FFI leaves, and
  the GC substrate the compiler names (`ManagedBuffer`, `EmptyHeader`). Ambient (no import). Non-Nomu source
  is a subset of it. Replaces the ambient half of the prepend.
- **`runtime` package** — the pure-Nomu runtime tier compiled once, privileged, with runtime-subset driven by
  **package membership** instead of file designation ([149](149-runtime-subset.md)'s swap). Uses `core`. Its
  C-ABI / codegen boundary keeps bare symbols (Inventory B).
- **`std` package + curated prelude** — everything user-facing, ordinary unprivileged Nomu (`Option`,
  `Result`, `String`, numeric helpers, `Time`, `SimpleRNG`, future collections/IO). Its default module
  `std/prelude` auto-imports into every module; the rest explicit `import std/...` (174.3.2).

**Tests** (174.6) — implicit-`core` visibility; single-definition of core symbols (no per-object duplicates
in the linked binary); `std` prelude auto-import; a prelude generic (`Option`/`Result`) consumed across a
module boundary from the compiled-once `std`.

**Partial fallback** (if the full goal is deferred): the non-generic prelude surface — the `rt*` runtime
functions plus `abs`/`max`/`min`, `Time`/`SimpleRNG` methods — can move to compiled-once packages on the
existing external path first, keeping `Option`/`Result` ambient, which retires `WeakODR` for everything except
generic instantiations. (Decided: **full goal**, so this is a fallback only.)

## Cutover plan + symbol inventory (design)

The risk is not in standing the packages up, it is in the **cutover** — the moment every prelude reference
flips from "in every module (prepended, bare)" to "external, resolved against the once-compiled package
objects," with the binary staying linkable. Two inventories de-risk it; both are facts from the tree, not
speculation.

**The bundled workspace.** `core`/`runtime`/`std` live in a compiler-owned workspace named **`nomu`** (its
`nomu.yaml name`), so every prelude symbol's canonical identity is `nomu :: <pkg>/<module> :: <decl>` — stable
across every user build (187.3 mangling). The three packages' source stays embedded in the compiler; the
driver **materializes** the embedded bytes to a known `build/` location and compiles them as **one build-graph
node, once per build** (a persistent cross-build cache is [172](172-incremental-build-cache.md), later). Every
user module gains an implicit dependency on them.

**Inventory A — compiler-referenced *types* (name resolution).** The compiler names only three prelude types
when lowering; everything else (`Option`, `Result`, `Some`/`None`, `concat`, …) is **not** compiler-referenced
— those are ordinary library types resolved through the curated `std` prelude, no special handling.
- `String` → `std` (user-facing). Sites: `Sema` (`readLine` return), `NOIRGen` (string-literal lowering emits
  `.construct(typeName: "String", …)` + the `.stringType` constant), `Typechecker` (`"String": .builtin`),
  `Monomorphize` (`.stringBase → "String"`), `LLVMGenDebug` (debug info).
- `ManagedBuffer`, `EmptyHeader` → `core` (GC substrate, not user-facing). Sites: `NOIRGen` (buffer-backed
  construction), `PointerIntrinsics`, `SSAIRToLLVM` (`emitManagedBufferAlloc` + `managedBufferTypeId`).
  The work: these name references must resolve to the **package** type so the existing construct/method
  mangling picks up the package qualifier. Where the reference is pre-Sema it rides ambient name resolution
  for free; the **post-Sema** sites (`NOIRGen`'s synthesized `.construct`, `SSAIRToLLVM`'s alloc) must carry
  the type's package origin explicitly rather than a bare name.

**Inventory B — the runtime bare set (the P3 boundary, extended).** The `runtime` package's functions are
package-qualified like any package's, **except** a small, explicit set that must keep a **bare** symbol
because something outside the normal Nomu-import path references it by name. The compiler carries this as an
internal **C-ABI / codegen bare list** (no language surface — the same shape as the existing `main →
nomu_main` special-case); every other `runtime` symbol qualifies normally.
- *Called by the C floor* (`runtime.c` `extern nomu_fn_*`, ~15): `nomuSchedNew`/`Spawn`/`Join`/`Boot`/`Sleep`,
  `nomuSchedActorSend`/`MailboxPop`/`Safepoint`/`WalkParked`,
  `nomuSchedStwCollect`/`StwCollectDefrag`/`StwCollectMinor`, `nomuGcSpaceAvail`/`nomuGcSpaceBlocks`,
  `rtGcRemember`; plus `nomu_main` (the entry, already bare).
- *Inserted by codegen* (`SSAIRToLLVM`/`LLVMGenRuntime` emit these by name): `rtShadowSave`/`Push`/`PopTo`,
  `rtCollectRoots` (Nomu runtime); `rtSwitch`/`rtFiberInit` (the asm floor — already bare).
- *Not in scope:* the GC type-map descriptor ABI (`nomu_gc_*`, `nomu_gc_desc_*`) is C/backend-owned and stays
  bare untouched; the Nomu→C direction (`nomu_gc_alloc`, the write barrier, …) are C symbols on the existing
  FFI path, unaffected by qualifying Nomu symbols.

**Sequencing (each step stays green).**
1. **174.1 — scaffold, alongside the prepend. (Built.)** The three packages are embedded as real
   single-module `pkg.json` packages (`products: [""]`) under a materialized `nomu.yaml` workspace named
   `nomu`; the driver compiles each once per build into a home-qualified library object (origin `nomu/<pkg>`)
   and links all three into every binary, with `prependPrelude` **still live** and nothing yet referencing
   the package symbols. Behavior-preserving (143/143). Mechanics: embed via the `embed.sh`/`BUILD.bazel`
   genrule (`EmbeddedSources.stdPreludeSource` joins the two existing prelude blobs); an internal
   `EmitOptions.compilingPrelude` flag suppresses the prepend and routes the entry module through the
   library-object emit (no `main`, no program-wide type maps, strong linkage — no weak-origin); `Driver`'s
   `buildNomuWorkspace` materializes the workspace to a pid-unique scratch, compiles each package, and feeds
   the objects into `emitLLVMBinary`'s link, removing the scratch after. **No content cache** — the
   cross-build CAS cache (172, next) subsumes it, so each build recompiles the workspace (absorbed by the
   suite's concurrency; one interim cost noted below).
   - *Interim duplication (shrinks at 174.4, fully resolves at 174.5).* The `runtime` package's C-ABI/scheduler
     functions carry safepoints until 174.4 and are pinned by the no-dead-strip `__LLVM_StackMaps` section — a
     second, inert copy survives in every binary (the bare prepend copy, compiled `noSafepoint`, is the one the
     C floor calls). 174.4 makes the package subset-by-membership (`noSafepoint`), so the functions no longer
     pinned by their own stackmaps dead-strip; a residual cluster survives because the runtime takes the
     address of its own functions within the package object. It fully collapses at 174.5, when removing the
     prepend leaves the package copy as the single referenced copy. The unreferenced `core`/`std` copies
     already dead-strip cleanly.
2. **174.2 — cut the references over.** Make `core` ambient + route references to the `nomu/core` package.
   Reworked onto [188](188-multi-local-workspace-builds.md): the `nomu` workspace is a compiler-injected
   external workspace, so the cut-over rides 188's cross-workspace resolution/linkage. The runtime flip
   (Inventory B bare list) and the `std` curated prelude move out of 174.2 — the runtime couples with 174.4
   (it can't run on a non-subset package before the subset designation moves), `std` with 174.3 (it is empty
   until the content split). Sub-steps:
   - **174.2.1 — built.** The `nomu` workspace builds before the compile loop and loads as a compiler-injected
     external (origin `nomu/<pkg>`): `buildNomuWorkspace` returns each package's `.o`+`.nmi`, the driver loads
     the interfaces + links the objects via the external path. Behavior-preserving — prepend still live,
     `core` not ambient yet (145/145).
   - **174.2.2 — ambient `core` + the non-P1 cut-over, built.** Every module gets `nomu/core` ambient
     (seeded into `visibleModules` + per-file visibility); a locally-prepended symbol cleanly shadows the
     ambient one, so a symbol is cut over simply by dropping it from the prepend (`flippedCoreSymbols`).
     Cut over (and marked `public` in `core.nomu`): `abs`/`max`/`min` (free functions) and `Option`/`Result`
     (generic enums). They resolve against `nomu/core`, mangle under `nomu/core`, link, and run — 145/145,
     including the GC-stress cases `option-string-gc`/`-evac` (an external `Option<String>` relocated across a
     moving collection) and `module-generic-enum`. This is the central-hypothesis proof: prelude generics
     from a compiled-once package, GC-traced across the module boundary. Enabling fix: cross-module generic
     enum construction — `Sema.enumNameForConstruction` resolves a bare enum base to the local bare key or an
     in-scope external key (`origin@name`), used by both the no-payload (`NOIRGen` `.member`) and payload
     (`checkCall`) construction sites; matching already handled the external enum. `SimpleRNG` stays
     prepended for now (stored field + mutating method → cross-module field/mutating-ness, folded into a later
     slice).
   - **174.2.3 — `String` + `concat` + `Time` flipped, built (riding 174.3.1).** The P1 compiler-referenced
     surface type `String`, the allocating free function `concat`, and the method-bearing `Time` now resolve
     against `nomu/core`. The flip is the external-type shape (Approach 2): `String`'s identity is the ordinary
     per-origin key `nomu/core@String`, which the existing external-symbol machinery mangles, links, and
     GC-traces with no central redirect — the type-resolution `default` path already externalizes a bare
     `String`, the egress `structMap`/`shapedStructs` pick up the imported single-field shaped wrapper
     structurally (so a heap `String` relocates across the boundary), and the GC buffer descriptor folds by
     content. The compiler-synthesized string sites carry the identity via
     `Sema.stringType(at:)`/`stringTypeName(at:)` (bare while `String` is local — the `nomu/core` package's own
     build — else the ambient key), routed through `NOIRGen.wrapString`/`asStringBase` (now `Sema`-aware) and
     `isStringType`. `concat` allocates its heap result from the `nomu/core` package object, which 174.3.1
     makes work under the self-hosted plan. `readLine`'s return stays bare `String` (unexercised; its external
     identity is a follow-up). Verified 145/145 incl. the string-GC-under-evacuation cases (`gc-string`,
     `module-generic-string-evac`, `gc-string-field`) under MMTk, selfhost, and the self-hosted `nomu` plan.
   - **Then still prepended (all since resolved):** `SimpleRNG` (moved to `std` at 174.3) and
     `ManagedBuffer`/`EmptyHeader` (retired at 174.5.1 — `ManagedBuffer` → ambient `nomu/core` type,
     `EmptyHeader` → compiler builtin).
   - **Uniformity note:** the cut-over currently applies only to the final-binary build (ambient `core` guarded
     by `!emitLibrary`); external-workspace *product* builds still prepend the full `core`. Making the flip
     uniform (so an external product may also expose cut-over types across the boundary) couples with 174.3.

   *Original 174.2 framing (superseded by the sub-steps above):* make `core` ambient + the curated `std`
   prelude auto-imported, route Inventory A's type sites to the package types, apply Inventory B's bare list
   to the `runtime` package, flip lowering to the external symbols.
3. **174.3 — content split, built.** Every user-facing decl moved `core.nomu` → `std.nomu`: `Option`,
   `Result`, `String`, `concat`, `abs`/`max`/`min`, `Time`, `SimpleRNG` (all `public`). `core.nomu` keeps only
   the GC substrate `ManagedBuffer`/`EmptyHeader`. `std` is ambient alongside `core` (the whole package for
   now; the curated-prelude-subset vs. explicit-`import std/…` split is a later refinement), so the moved
   symbols resolve to `nomu/std@…` with no source import — verified by the emitted symbols
   (`nomu_fn_nomu_std_abs`, `nomu_fn_nomu_std_concat`, `nomu_m_nomu_std_String_*`). `String`'s synthesized-site
   identity still routes through `Sema.stringType(at:)`, which now resolves to `nomu/std@String` (bare while
   `String` is local — the `std` package's own build). The prepend (`core.nomu`) now carries only the
   substrate + the `runtime` prelude; the `flippedCoreSymbols` cut-over set is retired (the symbols physically
   left the prepend). `runtime.nomu` is already its own package source; it stays prepended until 174.5. The
   one cross-package need — `std`'s `concat` heap path makes codegen name `core`'s `EmptyHeader` — is met by
   prepending `core`'s substrate into the `std` package build (`EmitOptions.prependCoreSubstrate`), so the
   bare `.named("EmptyHeader", …)` lookup finds its zero-field layout locally; the allocator functions link
   external (174.3.1). Suite 145/145 under MMTk/selfhost/`nomu`, incl. the string-GC-under-evacuation cases.
   - **174.3.1 — library-object allocation, built (pulled ahead for 174.2.3's `concat`).** A package object
     now allocates under the self-hosted plan, so `std`'s allocating surface (`concat`, collections, IO) can
     live in a compiled-once package rather than the prepend. Two parts, both done: (a) the generated
     allocation function (`nomuSelfhostAlloc`) declares the runtime allocator functions
     `rtImmixNew`/`rtTlabAlloc` **external** by their bare runtime symbols (`nomu_fn_rt…`) when they are absent
     from `callables` — a package build suppresses the runtime-prelude prepend, so this is the path there;
     they resolve against the runtime's weak-ODR definitions in the final binary (formerly it emitted a
     null-returning stub, which is what crashed `concat` in a package). (b) The self-hosted Immix space
     `__nomu_selfhost_space` moved from an `InternalLinkage` per-object global to a single process-shared
     definition in the C floor (`runtime.c`); both codegen sites (the allocator in `LLVMGenRuntime`, the
     tracer's reach `__gcSelfhostSpace` in `SSAIRToLLVM`) now reference it as an external global, so every
     object allocates into the one heap (the existing double-checked lock around space creation now guards it
     process-wide). This also lets the flip go uniform for external-workspace product builds (174.3's
     remaining uniformity note). Earlier latent assumption this removes: allocation happening only in the
     entry object — the per-object space was a singleton solely because nothing but the entry allocated.
   - **174.3.2 — curated prelude, built.** `std` is a multi-module package whose `default-module` is
     `prelude`, and every file of a binary build carries an invisible `import std` — so "implicitly
     imported" means exactly that import, resolved by the ordinary import path. The modules:
     - `std/prelude` — `Option`, `Result`, `String` and its methods. `concat` is a `String` method
       (`a.concat(b)`), part of the prelude with the type.
     - `std/math` — `abs`, `max`, `min`.
     - `std/time` — `Time`.
     - `std/random` — `SimpleRNG`.

     The boundary is expected to move as `std` grows; moving a decl is a file move between module
     directories.

     *Mechanism.* The driver materializes the language workspace before discovery, so the root token
     `std` resolves against it like a pinned external workspace (`std` needs no `dependencies` entry). The
     package names `std` and `pkg` are reserved: a user package named either is a compile error. The implicit import is injected per file unless the file names
     bare `std` itself (e.g. to alias it); it also gives the `std.` qualifier. `core` stays ambient (whole
     module, for `ManagedBuffer`). Each `std` module compiles to its own object; all of them link, and
     `-dead_strip` drops what the program never reaches. Sources live at `src/stdlib/std/<module>/`,
     embedded as `EmbeddedSources.stdModules`. Library (`emitLibrary`) builds carry no implicit import,
     since they have no language workspace — the same scope ambient `std` had.
4. **174.4 — runtime-subset by membership, built** ([149](149-runtime-subset.md) designation swap). The
   `runtime` package build designates every function it defines runtime-subset by **package membership**
   (`EmitOptions.runtimeSubsetByMembership`, set for `p.name == "runtime"` in `buildNomuWorkspace`): the subset
   name set is sourced from the package's own `funcDecl`s rather than the prepend's `runtime.nomu` parse — the
   same set, from the package. Its functions now compile `noSafepoint` and pass `checkRuntimeSubset` in the
   package build (they already did under the prepend's file-designation, so the set is subset-legal). Suite
   145/145 incl. the subset/scheduler/selfhost cases. The prepend keeps its file-designation until it retires
   (174.5) — while `runtime.nomu` is prepended, the bare copies the C floor calls still need designating, and
   a prepended function has no package to belong to, so the file-designation can only fully retire once the
   prepend is gone. **Duplication:** the inert `nomu/runtime@…` package copy partially dead-strips now (the
   `noSafepoint` functions no longer pinned by their own stackmaps drop); a residual survives because the
   runtime takes the address of its own functions (fiber entry points, scheduler callbacks) within the package
   object, so the cluster looks live to `-dead_strip`. It fully collapses at 174.5, when removing the prepend
   leaves the package copy as the single, referenced copy.
5. **174.5 — retire the runtime prepend + the per-object weak duplication, built.** The runtime prepend is
   gone: the `runtime` package emits its functions **bare + weak-ODR** (its own source files are the
   weak-origin set in the package build, keyed by their materialized path — what the spans carry), so the C
   floor and codegen references (`nomu_fn_rt…`, `nomu_fn_nomuSched…`; Inventory B + the `preludeFn` set) that
   used to resolve against the prepend's per-object copies now resolve against the package's single copy. No
   user build prepends the runtime; `prependPrelude` is deleted. Confirmed: a user binary carries **zero**
   `nomu/runtime@…` qualified copies — only the bare runtime symbols from the one package object (dead-strip
   keeps the referenced closure). The runtime duplication is fully collapsed. White-box runtime tests — the
   fixtures that call runtime internals (`rtArenaNew`, the Immix/gen ops) directly, which the prepend used to
   expose — opt back into a runtime prelude via `NOMU_RT_PRELUDE` (an env flag the suite sets on the 11
   `rt-prelude`/`immix-*`/`gen-*` cases); its bare weak-ODR definitions fold with the package's, adding no
   duplication. Suite 145/145 under MMTk/selfhost/`nomu`.
   - **Residual — the core-substrate prepend.** `prependCoreSubstrate` remains: every build still prepends
     `core`'s `ManagedBuffer`/`EmptyHeader` so codegen's bare `managedBufferTypeId(EmptyHeader, …)` reads a
     local zero-field layout. This is types only (no function symbols, no weak duplication), so it is not the
     `WeakODR` cost 174.5 targeted. Retiring it is **174.5.1** (below).
   - **174.5.1 — retire the core-substrate prepend, built.** The last prepend is gone; no build prepends
     anything (white-box runtime tests aside). The two substrate types split by how the compiler uses them:
     - **`EmptyHeader` → compiler builtin.** It is never written in source (only codegen names it, for a heap
       `String`'s `ManagedBuffer<EmptyHeader, UInt8>` buffer), carries no symbols, and is a zero-field header.
       The egress seeds its zero-field layout into `structMap` directly (`SSAIRToLLVM.lower`), so
       `slotCount`/`collectManagedOffsets` read headerSize 0 with no decl — in every build, including the
       `std` package build whose `concat` names it. Removed from `core.nomu`.
     - **`ManagedBuffer` → ambient `nomu/core` package type.** It is a generic class Monomorphize specializes
       (its instantiations are reference types the egress lays out as `p1`), so it stays a real decl — now
       `public` in `core.nomu`, resolved through the ambient `nomu/core` external path like any package type.
       Imported generic-class specialization works (the empty template reconstructs from the `.nmi`, mono
       names the instantiation `nomu/core@ManagedBuffer<…>`). Three compiler sites that keyed off the bare
       name now carry the per-origin identity: the `create` intrinsic result base (`NOIRGen` →
       `ManagedBufferIntrinsics.checkStatic(base:)`, from `Sema.externalTypeKey("ManagedBuffer")`), the
       instance-accessor gate (`NOIRGen`, origin-stripped match), and `managedBufferArgs` (`LLVMGenGCMaps`,
       origin-stripped prefix). The static/method written-name gate (`tn == "ManagedBuffer"`) is unchanged —
       it reads the source spelling, still bare. `prependCoreSubstrate` + `EmitOptions.prependCoreSubstrate`
       deleted. Suite 145/145 under MMTk/selfhost/`nomu`, incl. the managed-buffer + string-GC-under-evacuation
       cases.
6. **174.6 — tests, built.** One named suite case per invariant:
   - `prelude-implicit` — `Option`, `Result`, `String` methods and the `std.` qualifier with no import.
   - `prelude-single-definition` — the program's own object defines no runtime, `core` or `std` function or
     method (`nm -U` on `<binary>.o` via the harness's new `object_symbols` assertion).
   - `core-import` (formerly `prelude-core-ambient`) — `ManagedBuffer` resolves through `import core`; `core`
     is no longer ambient (190.1).
   - `prelude-cross-module` — `Option<String>` / `Result<Int, String>` returned by a dependency module and
     matched by the consumer (needed 174.7).
   - `std-module-import` / `std-module-missing` — `import std/math|random|time` works, bare and qualified;
     `max` without its import is "undefined name 'max'".
   - `reserved-pkg-std` / `reserved-pkg-pkg` — a user package may not take either name.

   The Sema unit tests (`frontend_tests`) see the prelude's `String` as an external decl parsed from the
   embedded `std/prelude`, the way a real build sees it through the implicit `import std`.
7. **174.7 — foreign types in interfaces, built.** Found by 174.6: a dependency's signature naming a type from
   a third module (`-> Option<String>`, or a user `-> Point` from a sibling module) failed in the consumer
   ("unknown type") — interface type text is bare, and the consumer had no record of where the name came
   from. The producer now records `foreignTypes` in its interface (bare name → defining module's origin,
   resolved against its own imports; a name ambiguous across its imports is left out), and the consumer
   encodes those names to `origin@name`. A type named this way from a module the consumer does not import
   still loads (types only, transitively), so its values type-check, but its name stays out of scope — no
   implicit re-export, the Rust rule (modules.md §Re-export). Cases: `module-foreign-type` (consumer
   imports only the dependency), `module-foreign-type-unnamed` (naming the type without its import errors).
   Known edge: a prebuilt external-workspace `.nmi` whose foreign type comes from a module the consumer build
   never loads still fails; nothing exercises it yet.

## Dependencies & triggers

- **Rides:** 100.4.1 / 100.4.3 / 100.4.7 (all done — the three prerequisites), [173](173-package-model-driver-cli.md)
  (the package model prelude/`std` plug into).
- **Couples with:** [149](149-runtime-subset.md) (runtime-subset by module membership — the designation swap
  is 174.2).
- **Unblocks:** [120](120-stdlib-core.md) / [121](121-string-utf8-model.md) (the extensible stdlib lives in
  `std`); the self-hosting invariant (non-Nomu source ⊆ `core`); demand-driven prelude emission as a
  [136](136-incremental-compilation.md) optimization.
- **Closes:** the 100.4.4 per-object prelude/runtime duplication interim.

## Refs

[100](100-modules.md) §100.3.7 + the former Mini-horizon (the dependency chain, prerequisites now done);
`prependPrelude` (`src/driver/sources/Driver.swift`); [149](149-runtime-subset.md) (runtime-subset
mechanism); [`../../language/modules.md`](../../language/modules.md) (the package surface).
