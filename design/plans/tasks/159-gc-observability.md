# GC observability — structured collection tracing, stats, and pause timing

**Avenue:** Risk · **Type/Lifecycle:** `runtime · observability · needs-design` · **Size:** M ·
**Status:** needs-design (pairs with the GC-benchmarking step — horizon "after GenImmix" run-up, step 3) ·
**Source:** grounded during 150.4.5.3 — debugging a minor-collector segfault and an STW deadlock, the only
signal was a single per-collection line and a native backtrace that could not unwind the collector's carrier
stack (frame #0 only). Ad-hoc `RawPtr.gcDbg` breadcrumbs localized both bugs, then were stripped.

Give the collector a real observability surface: structured per-collection stats, phase tracing, heap/space
occupancy, and pause timing — enough to debug a fault without hand-adding prints, and to feed the GC
benchmarking that gates MMTk removal.

## Why now

The collector runs on a carrier stack the native unwinder cannot walk, so a fault yields only frame #0. The
existing signal is thin: one `nomu-gc-sync: collection N (kind), R roots, avail -> A` line per collection,
plus `NOMU_GC_DEBUG_STW`. During 150.4.5.3 that was not enough to see a promotion-queue overflow (needed the
promoted count) or an STW deadlock (needed to know which root-source phase was live). Temporary `gcDbg`
breadcrumbs found both; a permanent, structured facility should exist so the next collector bug is legible
without re-instrumenting by hand. It also underpins step 3 GC benchmarking (pause distribution + footprint
are observability outputs), and it should be designed so it works across the packaged plans
([158](158-gc-packaging.md)), not just GenImmix.

## What — the surface

1. **Per-collection stats record.** Kind, trigger source, roots scanned, objects/bytes evacuated, objects
   promoted, blocks reclaimed, nursery occupancy before/after, mature availability, queue high-water. One
   structured record per collection, printable and machine-readable.
2. **Phase tracing.** Breadcrumbs at collection phase boundaries (root sources, evacuation, remset drain,
   Cheney/scan, sweep, reclaim) so a hang or fault localizes to a phase without a usable backtrace. This is
   the durable version of the stripped `gcDbg` scaffold — one tagged-trace primitive, gated, low-overhead.
3. **Pause timing.** Wall-clock per STW (and per concurrent phase for LXR), so pause distribution is a
   first-class output — the metric step 3 benchmarks and the metric LXR exists to improve.
4. **Heap/space introspection hooks.** Live occupancy by space (nursery / mature Immix / LOS), fragmentation,
   block-state histogram — enough to explain a footprint number, and the seed for
   [139 memory/heap introspection](139-memory-heap-introspection.md).

## Design axes

- **One trace facility, not a knob per site.** A single gated trace/stat primitive with severity/category,
  routed to stderr or a structured sink — rather than a new `NOMU_GC_DEBUG_*` env per feature (the sprawl
  [157](157-env-var-audit.md) is collapsing). Enablement rides the [157] scheme.
- **Overhead when off.** The trace primitive must compile to near-nothing when disabled (a load + branch),
  since it sits inside the collector's hot loops.
- **Plan-agnostic vs plan-specific.** The stats record has a shared core (roots, pause, reclaimed) plus a
  per-plan extension (GenImmix promotion counts; LXR RC decrement/coalesce counts). Co-designed with 158.
- **Structured output for benchmarking.** A machine-readable emission (JSON or similar) the step-3 benchmark
  harness consumes, aligned with the 155 harness's `--json`.

## Non-goals

- Not the collector packaging itself ([158](158-gc-packaging.md)) — this observes plans; 158 structures them.
- Not general program heap introspection ([139](139-memory-heap-introspection.md)) — this is
  collector-internal, though it seeds the space-occupancy hooks 139 would surface to users.

## Refs

[158 GC packaging](158-gc-packaging.md), [150 GC ladder](150-selfhosted-gc-ladder.md),
[157 env-var audit](157-env-var-audit.md), [155 integration-suite harness](155-integration-suite-harness.md)
(consumes the machine-readable stats), [139 memory/heap introspection](139-memory-heap-introspection.md);
horizon "after GenImmix" run-up, step 3.
