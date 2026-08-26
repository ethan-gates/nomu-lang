# Incremental compilation

**Avenue:** Infra · **Type/Lifecycle:** `perf · refactor · needs-design` · **Size:** L ·
**Status:** needs-design (breakout candidate from modules) · **Source:** deferred.md (modules item +
pipeline hardening)

## What

A changed module recompiles without rebuilding the world. Recompute only what changed; ties to the
query-based architecture (`tooling.md`) and cached monomorphizations.

## Why broken out

Called out in the [modules](100-modules.md) item as a candidate to break out as its own task. It
depends on the module interface format + stable stage boundaries, so it sits downstream of both
modules and [IR/pipeline hardening](142-ir-pipeline-hardening.md).

## Dependencies & triggers

- **Depends on:** the [module interface format](100-modules.md), stable/versioned stage-boundary formats
  ([IR/pipeline hardening](142-ir-pipeline-hardening.md)), cached monomorphizations.
- **Feeds:** the M10 [LSP / query server](137-tooling-lsp-formatter.md) responsiveness, Bazel RBE caching.

## Refs

deferred.md "Modules + multi-file" (incremental breakout), "Pipeline boundary hardening";
`tooling.md` (query architecture); `backend.md` (cached monomorphizations).
