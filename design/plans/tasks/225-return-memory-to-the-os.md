# Return free heap memory to the OS

**Avenue:** Risk (footprint) · **Type/Lifecycle:** `runtime · perf · needs-design` · **Size:** M · **Status:** not started ·
**Source:** [223](223-retire-the-c-floor.md).1.6, which made the heap a zeroed reservation whose pages become
resident only on first touch; the other half of footprint is giving pages back.

## What

The heap and its side tables are reserved with `mmap` (`Runtime.reserveZeroed`), so a page costs physical
memory only once it is touched. Once touched, it stays resident for the life of the process: the collector
frees the objects on it and the allocator reuses the block, but nothing tells the kernel the contents are
no longer needed. A program that peaks at 200 MB of heap holds about 200 MB afterwards.

This task returns the pages of blocks a collection leaves entirely free, so resident memory follows the
live heap down as well as up. `selfhosted-gc.md` §7 lists it as an open footprint question; LXR
([127](127-lxr-collector.md)) is the footprint endgame it feeds.

## Design questions

- **Mechanism.** `madvise` on a free block's range. Linux's `MADV_DONTNEED` frees the pages at once and the
  next touch reads zero; `MADV_FREE` frees them lazily and the old contents may survive; darwin's
  `MADV_FREE_REUSABLE` / `MADV_FREE_REUSE` pair also keeps the kernel's accounting of the process
  accurate. The choice decides whether a returned block must be re-zeroed when reused. The platform values
  go in `TargetPlatform` (llvmgen), beside the `mmap` flags.
- **Policy.** Returning and re-faulting pages costs time: a page fault per page on reuse, and the
  `madvise` call itself. When to return (every collection, after a block stays free across several, or
  above a free-memory threshold), how much to keep, and whether to do it on the collector's thread or in
  the background.
- **Reads count.** On darwin, reading an untouched anonymous page makes it resident just as writing does
  (measured: reading one byte per page of a fresh 256 MiB mapping took resident memory from 1 MB to
  257 MB). Collector passes that scan a whole side table or the whole heap range, rather than the blocks in
  use, would pull returned pages back in; they must stay bounded by the blocks in use.
- **Side tables.** The line, block, free-list, defrag and log-bit tables take 650 bytes per 32 KiB block
  (about 2% of the heap, mostly the log-bit table), so returning their pages matters less; decide whether
  to bother.
- **Measuring.** Peak and steady resident memory on a workload that grows its heap and then shrinks its
  live set, before and after; the 159 report can carry the returned-bytes counter.

## Refs

`rtImmixNew` and the block pool (`runtime.nomu`), `nomuReserveZeroed` and `TargetPlatform`
(`src/llvmgen`), `../../internals/selfhosted-gc.md` §7, [127](127-lxr-collector.md),
[159](159-gc-observability.md), [218](218-linux-support.md).
