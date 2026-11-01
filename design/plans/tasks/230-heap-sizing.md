# Heap sizing — a heap that grows, and a clean out-of-memory

**Avenue:** Risk · **Type/Lifecycle:** `runtime · gc · needs-design` · **Size:** M · **Status:** not started ·
**Source:** binary-trees against Go: Nomu crashes at the standard depth 21 and slows sharply at depth 20.

## Today

The heap is one Immix space of a fixed size: `rtHeapBlocks = 8192` blocks of 32 KiB, 256 MiB
(`startup.nomu`). Its side tables are sized from the same constant, and the write barrier's heap range and
log-bit base are startup constants derived from it. Nothing reads a size from the build or the environment,
and nothing grows the space.

Two consequences, both seen in binary-trees (`practice/`, not committed):

- **Out of memory crashes.** When a full collection leaves no free block, `rtImmixRefill` returns false,
  `rtTlabAlloc` returns null, and generated code stores through it: the process dies on `SIGSEGV` (exit 139)
  with no message. Depth 21 does this at a 294 MB peak; its live data does not fit in 256 MiB.
- **A cliff near the limit.** With live data close to the heap size, each collection frees little and the
  next one comes soon. Depth 19 runs in 0.98 s (Go 1.13 s); depth 20 in 17.7 s (Go 2.50 s), at 249 MiB
  resident, against the 256 MiB heap.

## What

A heap whose size follows the live data, so a program fails only when the machine is out of memory, and a
clear fatal error when it does.

## Design questions

- **Reserve big or grow.** The heap is a zeroed reservation whose pages cost memory only when touched
  ([225](225-return-memory-to-the-os.md)'s groundwork). A large virtual reservation (tens of GiB) keeps the
  heap range, the log-bit base and the barrier's constants fixed, and growth becomes a policy over how many
  blocks are in use. Growing the reservation instead moves those constants, which the barrier reads as
  invariant loads. The side tables' cost under a large reservation matters: they are reserved too, and a
  collector pass that reads a table entry for every block would touch them all (225, "Reads count").
- **The growth policy.** When to take more blocks instead of collecting: a target ratio of heap to live
  data after a major (Go's `GOGC` shape), a cap on time spent collecting, or both. Whether a user-facing
  limit exists (Go's `GOMEMLIMIT`), and how it is set: a build setting, an environment variable, or both.
- **Out of memory.** Where the fatal error is raised: in `rtTlabAlloc` on a failed refill, before returning
  to generated code. The message names the heap size and the live bytes after the last collection.
  [219](219-runtime-fault-handling.md)'s handler would catch today's null store, but out of memory is a
  condition the runtime detects itself and reports directly.
- **Interaction with the nursery.** The generational reserve and the mature floor (`NOMU_NURSERY_RESERVE`,
  `NOMU_MATURE_FLOOR`) are counted in blocks of a fixed heap; under growth they become fractions or follow
  the current size.

## Work

- **230.1** Out of memory: a fatal error from the allocator instead of a null result, with a suite case.
- **230.2** The design: reservation, growth policy and limit, decided in this doc.
- **230.3** Growth: build it, then measure binary-trees at depths 19–21 against Go (time and peak resident
  memory).

## Refs

`rtHeapBlocks`, `rtSpace` (`src/stdlib/runtime/startup.nomu`), `rtImmixRefill`, `rtSelfhostOom`,
`rtTlabAlloc` (`src/stdlib/runtime/carrier.nomu`); [225 return memory to the OS](225-return-memory-to-the-os.md),
[219 fault handling](219-runtime-fault-handling.md), [127 LXR](127-lxr-collector.md).
