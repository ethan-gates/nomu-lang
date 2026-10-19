# Explicit module builds — dependency scan + build plan

**Avenue:** Infra · **Type/Lifecycle:** `infra · needs-design` (driver + build orchestration) · **Size:** L ·
**Status:** not-started — shape agreed, three decisions open (§Open decisions). · **Source:** found closing
[174](174-prelude-as-packages.md): the embedded `std` package compiled `std/prelude` twice per build.

## Deliverable

The Swift explicit-module-build model for Nomu. The driver scans the whole build's imports up front, plans
one job per module in dependency order, and runs each job once. **Invariant:** by the time `compile()` runs
for a module, every module it imports is already built, and its artifacts (`.nmi`, `.bir`, `.o`) are handed
in. `compile()` compiles exactly one module and does no discovery.

## Why

Inside one `compile()` call the driver already plans: discovery builds the module graph, a topological
order follows, and each module compiles once. The duplication comes from the two places that call
`compile()` as nested, independent builds, each planning only its own graph:

- **The embedded `nomu` workspace** (`compileNomuWorkspace`): one call per `std` module. `std/time`
  imports `pkg/prelude`, so its call rebuilds `prelude` from source as a `__mod_*` intermediate, beside the
  standalone `prelude` build. Only the standalone object links.
- **The external-workspace builder** (`buildExternalWorkspace`, [188](188-multi-local-workspace-builds.md)):
  one call per product. A product that imports a sibling product rebuilds it the same way.

This is Swift's *implicit* module build (the compiler builds what it imports, mid-compile), minus the
shared module cache that lets Swift reuse those builds. The explicit model removes the class of problem:
every module of every workspace in the build is a node in one graph, built by one job.

It is also the shape [172](172-incremental-build-cache.md) needs: the content-addressed cache keys on a
job (its inputs + options), the way Swift's compile caching rides its explicit jobs.

## Shape

1. **Scan.** A fast pass reads only each file's import block. Imports must precede every declaration (the
   parser enforces it), so the scanner lexes a file until the first token that starts no import and stops
   there. No declaration is parsed. It covers every reachable module: the user's packages, the embedded
   `core`/`runtime`/`std`, and pinned external workspaces.
2. **Plan.** Resolve the scanned imports into one module graph, one canonical ID per module (its origin).
   Every check that needs only the graph moves here: unresolved imports, product gates, the `dependencies`
   allow-list, package and module cycles, reserved package names. The output is a job list in dependency
   order. A job is a serializable value carrying its source files, its dependencies' artifacts, its options
   (library or binary, runtime-subset by membership, the mangling workspace name, white-box interface for a
   `test import` target), and its outputs.
3. **Execute.** Run each job after its dependencies. A missing dependency artifact is a planner bug,
   reported as one.
4. **Link.** The final job links every object the plan produced.

The implicit `import std` (174.3.2) is injected at scan time, so `std/prelude` is an ordinary graph node.

**The plan holds exactly the reachable modules, and the link takes every object the plan built.** There is
no separate link-selection step: a module enters the build only when something imports it (`core` and the
runtime are always nodes, since the compiler references them; `std/prelude` always is, through the implicit
import). This replaces today's over-linking, where the nested builders build — and the driver links — a
whole workspace up front: all of `std`, and every product (plus `__mod_*` intermediate) of a pinned
workspace, whether imported or not. 190.4 and 190.5 must not carry that behavior over.

## Phases

- **190.1 — scanner.** Header-only import scan per file; returns each file's imports with spans (for
  diagnostics). Measured against today's full parse on a large module.
- **190.2 — planner.** One graph across all workspaces; the graph-only checks move from discovery into the
  planner; output is the job list.
- **190.3 — single-module `compile()`.** `compile()` takes one job and its ready artifacts; discovery and
  the per-module loop leave it. The existing `compileModule` body is most of the job runner.
- **190.4 — embedded workspace in the graph.** `core`/`runtime`/`std` modules become plan nodes;
  `compileNomuWorkspace` and its nested calls go away.
- **190.5 — external workspaces in the graph.** Pinned workspaces' modules become plan nodes;
  `buildExternalWorkspace` and its nested calls go away.
- **190.6 — tests.** Each module compiles exactly once per build (a per-origin job count the harness can
  assert, e.g. from the timings report); planner errors (unresolved import, cycle, product gate) fire before
  any compile; existing multi-package and cross-workspace cases stay green.

## Open decisions

Decided when the relevant phase is taken on.

- **D1 — how jobs run.**
  - *In-process, sequential.* Smallest step from today; no parallelism, but the job boundary is real.
  - *In-process, threaded.* Parallel without spawning processes; needs the compiler's shared state safe
    across threads (today's `compile()` is one large function with captured state).
  - *Subprocess per job.* Swift's model (`nomu compile-module <job>`): isolation and easy parallelism;
    costs a spawn per job and re-reading inputs from disk.
- **D2 — where artifacts live.**
  - *Per producer workspace,* as today (an external workspace builds into its own `build/`, the embedded
    workspace into a scratch directory).
  - *One build tree for the whole graph,* under the consumer's `build/`, keyed by canonical origin, like
    Swift's single per-build module directory. Sharing a workspace's artifacts across different consumers
    then waits for 172.
- **D3 — what the scanner returns.**
  - *Imports only;* the planner reads manifests itself.
  - *Imports plus per-file facts the planner needs* (e.g. test-module status). These come from manifests
    today, so likely unnecessary.

## Non-goals

- Reusing artifacts across builds. Every build still compiles every module once; skipping unchanged
  modules is [172](172-incremental-build-cache.md).
- Sub-module (query-level) incrementality — [136](136-incremental-compilation.md).

## Dependencies & triggers

- Builds on 100 (separate compilation), 187 (multi-package), 188 (local external workspaces) and 174
  (embedded `nomu` workspace).
- Precedes 172: the cache keys on 190's jobs.

## Refs

- `src/driver/sources/Driver.swift` — `compile()` (discovery, topological loop, `compileModule`),
  `compileNomuWorkspace`, `buildExternalWorkspace`.
- `src/frontend/parse/sources/Parser.swift` — `parseImports` (the top-of-file import block the scanner
  mirrors).
- Swift: explicit module builds (`swift-frontend -scan-dependencies`, libSwiftScan,
  `-explicit-swift-module-map-file`).
