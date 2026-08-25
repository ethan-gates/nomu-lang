# LXR collector (footprint endgame)

**Avenue:** Risk (the headline risk bet) · **Type/Lifecycle:** `perf · evaluate` · **Size:** XL ·
**Status:** scheduled, gated on a benchmark-scale stdlib · **Source:** roadmap ("LXR-style collector")

## What

An *owned* RC-hybrid reimplementation behind the same `VMBinding` and reusing the
`__nomu_write_barrier` seam, replacing/backing today's GenImmix. The footprint endgame — a moving
collector at near-live-set footprint is the performance thesis; LXR pushes footprint further via
reference counting hybridized with tracing.

## Why deferred — the real gate

**Intent (2026-08-04): scheduled, not open-ended** — targeted after M8 and the M11 debugger, but the
**real gate is a benchmark-scale stdlib**. LXR is the footprint endgame, so validating it against
Immix needs a stdlib mature enough to build meaningfully large programs to measure
footprint/throughput on. Sequenced by that prerequisite, not a fixed milestone number.

Targets **mainline GenImmix** as the shipped collector (M6); LXR is the later owned effort, not a
dependency on the stalled upstream MMTk branch.

## Dependencies & triggers

- **Gated on:** a [benchmark-scale stdlib](120-stdlib-core.md) (to measure footprint on real programs).
- **May fold with:** [self-hosting the runtime](128-self-hosting-runtime.md) — LXR could be the collector
  that gets written in Nomu. Decide whether to fold them.
- **Kept open by:** a clean `VMBinding` + the `__nomu_write_barrier` seam (M6 substrate).

## Refs

roadmap "LXR-style collector"; `memory-model.md` §3 (object model / `VMBinding`); `backend.md`
(barrier seam); [self-hosting](128-self-hosting-runtime.md).
