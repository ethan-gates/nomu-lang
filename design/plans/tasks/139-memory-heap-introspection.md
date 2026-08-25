# Memory debugging / heap introspection

**Avenue:** Usability · **Type/Lifecycle:** `observability · needs-design` · **Size:** M ·
**Status:** evaluate (importance uncertain; likely very late-stage) · **Source:** deferred.md
(2026-08-18)

## What

Developer tooling to inspect the live heap: an object-graph view, retention / root paths ("why is
this object still alive"), allocation + footprint profiling, per-type live counts. The analogue is
Xcode's memory-graph view.

## Why the rationale differs from Swift

Xcode's memory graph earns its keep mostly by finding reference cycles, which ARC leaks. Nomu's moving
GC collects cycles, so that use disappears. What remains valuable in Nomu is *logical* retention — an
object held alive by an unintended root or reference (a cache, a long-lived collection) that the
collector correctly cannot reclaim — plus allocation / footprint profiling, which feeds the
[LXR](127-lxr-collector.md) footprint-endgame goal.

## How it would build

Reuse the GC's object-graph walk (the precise scan already enumerates roots + references) to snapshot
the live graph; surface retention paths from roots to a selected object; host it on the M11
[debugger](138-debugger.md) plugin (DAP) and/or the M10 [tooling](137-tooling-lsp-formatter.md) surface.
Opt-in instrumentation, off the steady-state hot path.

## Trigger

Late — after the M11 [debugger](138-debugger.md) exists to host it, and once benchmark-scale programs
(the LXR gate's stdlib) create heaps worth inspecting.

## Roadmap assessment

**Deferred-only.** Fails the three-head test (low architecture ripple, no steady-state perf cost, no
programmer-reasoning-contract change). Rides M10/M11 tooling; worth a mention inside the M11 debugger
scope.

## Refs

deferred.md "Memory debugging / heap introspection"; `runtime.md` §6 (precise scan);
[debugger](138-debugger.md), [LXR](127-lxr-collector.md).
