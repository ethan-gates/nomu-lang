# IR + pipeline-boundary hardening

**Avenue:** Infra · **Type/Lifecycle:** `refactor · observability · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** deferred.md ("IR hardening" 2026-08-18 + "Pipeline boundary
hardening" 2026-07-21)

Merges two overlapping deferred items: hardening the IR *formats* and hardening the *stage boundaries*
— one coherent goal (deliberate, durable stage-to-stage contracts).

**► Decide-early: inject the format discipline into the current M7 tier.** SSAIR is new right now; set
the format + stage-boundary discipline before more IR node kinds and passes accrete. Cheapest moment.
Design-ahead, with a light build. (Also tracked in `148-ssair-optimizer-tier.md` §148.8.)

## What — evaluation axes

1. **Format covers current + future needs** — a versioned, extensible IR text format (new node kinds /
   fields without breaking readers), designed once across all three IRs (AST, NOIR, SSAIR) as a shared
   discipline. Today each IR has an ad-hoc printer (e.g. `SSAIRDump`); emit is file-based under
   `build/` (`--emit-ast/-noir/-ssair`, `--stop=`).
2. **Per-stage I/O override** — each stage as a function `IR_in → IR_out` with parse + serialize at
   the boundary, so a stage runs on an injected artifact (hand SSAIR a `.noir` file, skip the
   frontend). Enables **per-stage unit tests** and treating a stage as an **invariant** (golden IR in
   → expected IR out). Needs a *parser* per IR (round-trip), stable stage boundaries, and a
   `--start-from` counterpart to `--stop`. Generalizes the "Intermediate-based iso regression" item.
3. **Machine-readability** — a defined grammar / structured syntax so external tools (verifiers,
   visualizers, diff tools) run over IR as the compiler scales.
4. **Streaming** — whether IRs are processed/emitted incrementally vs whole-module in memory. Ties to
   [frontend perf](144-frontend-perf.md) (pull lexer). Likely defer (batch model is fine now).

Additional pipeline-boundary checklist (from 2026-07-21): golden per-phase tests at every boundary
(source→tokens→AST→NOIR→SSAIR→LLVM), phase output formats designed for speed, format stability
(versioned/backward-compatible for cached artifacts), parallelism opportunities, and per-phase
debuggability (`ASTDump` + the NOIR/SSAIR dumps to extend).

## Cost/value tension

A round-trippable canonical format is an ongoing invariant: every IR change keeps its parser in sync,
whereas a print-only dump is free to drift. The payoff (per-stage tests, stage-as-invariant, tooling)
must beat that carry. Scope it: full round-trip for every IR, or only the stage boundaries unit tests
target.

## Trigger / why early

Cheaper decided early, before more stages/node kinds accrete. Fits the M7 IR tier (SSAIR is new) and
the M10 tooling milestone. Prerequisite for [incremental compilation](136-incremental-compilation.md)
(cached artifacts survive compiler changes).

## Roadmap assessment

**One-liner pointer.** Primarily the architecture head — a round-trippable, versioned IR format +
decoupled stage I/O is a compiler-architecture foundation testing + tooling rest on. Little
perf/programmer-expectation ripple. Rides M7 (IR tier) + M10 (tooling).

## Refs

deferred.md "IR hardening", "Pipeline boundary hardening"; `noir.md` (pipeline); the emit/stop flags;
`SSAIRDump` / `SSAIRGen`; `148-ssair-optimizer-tier.md` §148.8; `architecture.md` (interface modules);
`src/frontend/README.md` (the `exit(1)`-on-first-error blocker).
