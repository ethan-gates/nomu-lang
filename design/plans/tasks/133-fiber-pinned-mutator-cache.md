# Fiber-pinned mutator cache

**Avenue:** Infra (perf) · **Type/Lifecycle:** `perf · needs-grounding` · **Size:** S ·
**Status:** needs-grounding (ground against a profile first) · **Source:** deferred.md (2026-08 session)

## What

The inline alloc fast path reads the per-carrier MMTk mutator via the thread-local `rt_mutator`. On
macOS a thread-local read compiles to a `_tlv_get_addr` call, so the fast path is not fully call-free
on Darwin. Cache the mutator where codegen can reach it without a tlv call (a fiber/carrier-pinned
slot or a reserved register), removing the per-alloc tlv cost.

## Why deferred

Ground against a profile first — confirm the tlv read actually dominates the alloc fast path before
building.

## Refs

deferred.md "Fiber-pinned mutator cache"; the inline alloc seam, `backend.md` (GC backend substrate);
`runtime.c` `rt_mutator`.
