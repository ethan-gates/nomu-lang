# Modules + multi-file / multi-module compilation

**Avenue:** Infra (+ Usability) · **Type/Lifecycle:** `language-feature · needs-design` (language +
compiler + driver + build system) · **Size:** XL · **Status:** needs-design · **Source:** deferred.md
(2026-08-18) — the largest missing architectural piece

**► Decide-early: the compilation-model fork before M10.**
Separate-compilation-vs-whole-program-mono constrains how much direct-to-LLVM / mono logic accretes,
and M10's LSP depends on modules for responsiveness. Decide the model early even if the full build
lands around M10. Design-ahead, not build-ahead.

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
- **Bazel + remote execution** — multi-module builds should run under Bazel + RBE, requiring hermetic
  file-based per-module compilation (deps' interfaces in → object + interface out).

## The central architectural fork — separate compilation vs whole-program monomorphization

The compiler today is single-CU with **whole-program monomorphization** (M5) + cross-everything
inlining. Modules pull the other way:
- Bazel RBE, incremental rebuilds, and LSP responsiveness want **hermetic separate compilation** —
  each module built from its deps' *interfaces*.
- Whole-program mono + cross-module inlining want **all IR present at once** (runtime-perf +
  self-hosting lean here).

Resolution is likely a **hybrid**: separate compilation as the default build graph (fast, cacheable,
RBE-friendly), plus an optional whole-program / LTO / cross-module-optimization pass for release
builds (cf. Swift `-cmo`, Rust `-C lto`). Cross-module generics then need a decision:
witness-passing at the boundary (no specialization — machinery exists for `any`) vs shipping generic
bodies in the interface for use-site specialization (Rust-style). This fork sets the whole
compile-time / runtime-perf tradeoff.

## Triggers this un-parks

The [`shared` spellings](132-shared-spellings.md) (hidden bodies across a module boundary) and
"Module-level interface as input" both fire when modules land.

## Roadmap assessment

**Yes — a named milestone**, with [incremental compilation](136-incremental-compilation.md) and the
nomuc uber-CLI / build tool possibly split out. All three heads, hard. It gates parked work and
underlies LSP + Bazel scaling.

## Refs

deferred.md "Modules + multi-file"; `modules.md`; `noir.md` §2a (mangling); roadmap M10;
[incremental compilation](136-incremental-compilation.md), [ir-pipeline hardening](142-ir-pipeline-hardening.md),
[shared spellings](132-shared-spellings.md).
