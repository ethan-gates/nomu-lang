# The minor collection's remembered-set buffer — allocated and zeroed on every minor

**Avenue:** Risk · **Type/Lifecycle:** `runtime · perf · ready-to-build` · **Size:** S · **Status:** ready to build ·
**Source:** the first collector report ([159](159-gc-observability.md).4).

## Today

`nomuSchedStwCollectMinor` (`runtime.nomu`) allocates a 1,048,576-entry (8 MiB) buffer for the drained
remembered set on every minor collection, and `rt_raw_alloc` zero-fills it. In the first report
(`gen_minor`, eight-block nursery, 48 minors) that allocation took ~0.9 ms of the first minor's 1.1 ms
collect: the gap between the root walk and the remembered-set drain. The stack-slot buffer (8192 entries)
is allocated the same way.

## What

Keep the buffers across collections (allocated once, grown when a drain fills them) and stop zero-filling
memory the drain overwrites. The drain's cap stays a cap: a remembered set larger than the buffer grows it
instead of being cut off.

## Work

- **221.1** Persistent, growable slot and remembered-set buffers; no zero-fill on reuse.
- **221.2** Measure with `gc.record` before and after: minor pause p50/p99 and the remembered-set drain
  phase on `gen_minor` and the nursery suite legs.

## Refs

`nomuSchedStwCollectMinor`, `nomuSchedStwCollectPlan` (`src/stdlib/runtime.nomu`), `rt_raw_alloc`,
`rt_modbuf_drain` (`src/runtime/embedded/runtime.c`).
