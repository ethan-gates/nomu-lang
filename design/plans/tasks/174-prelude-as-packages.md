# Prelude as packages

**Avenue:** Infra (+ self-hosting) · **Type/Lifecycle:** `language-feature · needs-design` (name
resolution + codegen + linkage + runtime-subset) · **Size:** L · **Status:** needs-design — **its three
prerequisites are now done; this is the goal they were gating.** · **Source:** pulled out of
[100](100-modules.md) §100.3.7 + the Mini-horizon that sequenced it. Unlike the rest of the old 100.3 (the
packaging/driver layer, [173](173-package-model-driver-cli.md)), this one reaches into the compilation
pipeline — name resolution, codegen, linkage, and the runtime-subset mechanism.

## Goal

`core` / `runtime` / `std` become real packages compiled **once** and referenced via the external-symbol
path, replacing `prependPrelude`'s decl-prepend-into-every-module. This retires the per-object prelude/runtime
duplication (the `WeakODR` weak-prepend interim carried forward from 100.4.4) and enables the extensible
stdlib ([120](120-stdlib-core.md) / [121](121-string-utf8-model.md)).

The package layering:

- **`core`** — the *only* package containing non-Nomu source: built-in types (`Int`/`Bool`/`String`/
  `RawPtr`), built-in functions (intrinsics, C-leaf ops), and the libc/FFI boundary. Types are ambient
  (always in scope); low-level functions are the native/unsafe surface. **Invariant (target):** non-Nomu
  source ⊆ `core` — reached as the runtime finishes self-hosting; native GC (mmtk) still sits under the
  runtime today, so it is not yet literally true.
- **`runtime`** — pure Nomu (target), privileged; runtime-subset-by-default moves from the interim
  file-designation to **module membership** ([149](149-runtime-subset.md)). Uses `core` for native
  primitives.
- **`std`** — pure Nomu, non-privileged; today's `core.nomu` contents (`Option`, `Result`, `abs`/`max`/`min`,
  `Time`, `SimpleRNG`) move here, plus future `Array`/collections/IO. A **curated prelude subset** (`Option`,
  `Result`, pervasive helpers) is auto-imported into every module (Rust `std::prelude` shape); the rest is
  explicit `import std/...`.
- **User packages** — pure Nomu.

**Bootstrapping:** `std` does not auto-import its own prelude; `core` types stay ambient. The *demand-driven*
emission that links only used prelude parts stays a [136](136-incremental-compilation.md) optimization.

*Open sub-decision (build-time):* whether each `core` **function** is ambient or explicit-import /
`unsafe`-gated (types are ambient; low-level fns lean gated, cf. Rust `core::intrinsics`). No new keyword
surface without agreement.

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

## Scope — the construction

- 174.1 — **`core` package** — native types ambient (always in scope, no import), intrinsics / FFI leaves as
  the native surface; the sole non-Nomu-source package. Replaces the ambient-types half of the prepend.
- 174.2 — **`runtime` package** — the pure-Nomu runtime tier compiled once, privileged, with runtime-subset
  driven by **module membership** instead of file designation ([149](149-runtime-subset.md)'s designation
  swap). Uses `core`.
- 174.3 — **`std` package + curated prelude** — move today's `core.nomu` Nomu contents into `std`; auto-import
  the curated subset (`Option` / `Result` / pervasive helpers) into every module; the rest explicit
  `import std/...`.
- 174.4 — **Retire `prependPrelude` + `WeakODR`** — module codegen references prelude/runtime symbols as
  external (resolved at link against the once-compiled package objects) rather than emitting weak definitions
  per object. Closes the 100.4.4 weak-prelude interim.
- 174.5 (tests) — implicit-`core` visibility; single-definition of core symbols (no per-object duplicates in
  the linked binary); `std` prelude auto-import; a prelude generic (`Option`/`Result`) consumed across a
  module boundary from the compiled-once `std`.

**Partial fallback** (if the full goal is deferred): the non-generic prelude surface — the `rt*` runtime
functions plus `abs`/`max`/`min`, `Time`/`SimpleRNG` methods — can move to compiled-once packages on the
existing external path first, keeping `Option`/`Result` ambient, which retires `WeakODR` for everything except
generic instantiations.

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
