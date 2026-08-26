# `deinit` / finalization

**Avenue:** Usability (+ GC architecture) · **Type/Lifecycle:** `language-feature · needs-design` ·
**Size:** M · **Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

**► Decide-early:** decide the fork alongside the
[`defer` + linear-types](101-defer-linear-types.md) resource-cleanup work — same problem space.
Design-ahead, not build-ahead.

## What

Cleanup hooks on classes (and actors?). Under a moving generational GC this is **finalization**:
run timing (GC-scheduled), ordering, resurrection, keep-alive/pinning, the finalizer queue, and
interaction with M8 linear types + `defer` (deterministic cleanup).

## The fork (the decide-early piece)

Whether classes get a **GC-finalized `deinit` at all**, versus **deterministic cleanup only through
linear/`defer`**. This gates the resource-management story and belongs next to M8.

## Roadmap assessment (three-head)

**Yes — hits all three heads.** Finalization is a GC subsystem (architecture); finalizers add
collector work and pin objects (perf envelope); "when does my cleanup run" is a core contract
(programmer-expectation).

## Dependencies & triggers

- **Pairs with:** [`defer` + linear types](101-defer-linear-types.md) (the deterministic-cleanup
  alternative).
- **Couples with:** the moving GC (finalizer queue, pinning, resurrection).

## Refs

deferred.md "User-level language surface"; `memory-model.md` §3 (object model / GC);
[`defer` + linear types](101-defer-linear-types.md).
