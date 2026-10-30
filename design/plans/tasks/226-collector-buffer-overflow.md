# Collector work buffers that overflow silently

**Avenue:** Risk (correctness) · **Type/Lifecycle:** `runtime · gc · bug` · **Size:** S–M · **Status:**
built ·
**Source:** found during [223](223-retire-the-c-floor.md).2.2 while reading the root walk for the
unstarted-fiber root fix.

## What

The collector fills fixed-size buffers allocated per collection, and past their end it either drops entries
or writes out of bounds. Either way a large enough program loses live objects with no error.

- **Roots.** `nomuSchedStwCollectPlan` and `nomuSchedStwCollectMinor` pass an 8,192-entry slot buffer to
  `nomuSchedWalkSlots`. `nomuSchedWalkRoots`, `rtWalkFrom`, `rtWalkShadow` and `rtCollectRoots` guard each
  append with `if n < cap` and drop the root otherwise. A dropped root's object is freed or moved without
  its slot being updated. 8,192 roots is a few hundred fibers with modest frames.
- **Remembered set.** `nomuSchedStwCollectMinor` passes a 1,048,576-entry buffer to
  `rtCarriersDrainModBufs`, which stops copying at the cap but empties every carrier's mod-buffer anyway.
  A remembered object past the cap is forgotten, so its young referents are not forwarded.
- **Mark stacks.** `rtImmixMark`, `rtImmixUnmark`, `rtGenUnmarkAndUnlog` and `rtImmixEvacMark` (and the
  verify passes `rtMarkVerify`, `rtMarkVerifyImmix`, `rtLineMarkCheck`) push onto a fixed
  1,048,576-entry stack with no check, so an overflow writes past the buffer. The stack holds every object
  pushed and not yet popped, so one array of more than a million references overflows it.

The minor collection's Cheney queue already grows (`rtQueuePush`: a handle whose buffer doubles, off the
managed heap, so growth during stop-the-world never re-enters collection). Every buffer above can take the
same shape.

## Design questions

- **Grow or count first.** Growing (doubling, as `rtQueuePush`) costs a copy on overflow and nothing
  otherwise. Counting first (walk once to size, then fill) doubles the walk. Growing fits all three cases.
- **Interface.** The walkers take `(outBuf, n, cap)` and return the new count. A growable buffer passed by
  handle changes their signatures; the root walk's value mode (`nomuSchedWalkParked`, the STW smoke's
  oracle) shares them.
- **Out of memory during a collection.** Growth allocates raw memory under stop-the-world; a failed
  allocation exits with "out of memory", as `RawPtr.alloc` does today.

## Tests

A suite case per buffer that overflows today's cap, under `tools/memcap.py` while iterating: more live
roots than 8,192 (many fibers, each with several references live across a collection); more than a million
remembered objects in one minor cycle; an array of more than a million references marked and evacuated.
Each must keep every object.

## Built

- **Mark stacks.** Each of the seven mark and unmark passes keeps its stack and capacity in locals and checks
  `top == wcap` before every push (21 sites), calling `rtStackGrow` (double, copy, free) only when full.
  One compare per push and no call on the common path. The stacks start at 4,096 entries instead of a
  fixed 1,048,576, so a pass no longer zero-fills 8 MB up front.
- **Remembered set.** `rtCarriersModBufTotal` sums the carriers' mod-buffer counts under stop-the-world and
  the minor collection allocates exactly that; `rtCarriersDrainModBufs` takes no capacity.
- **Roots.** `rtWalkFrom`, `rtWalkShadow` and `nomuSchedWalkRoots` push through `rtQueuePush` into a
  growable handle (`rtRootsNew` / `rtRootsFree`, `{base, cap}`, starting at 4,096); the collect functions
  read the base after the walk. `nomuSchedWalkParked`, the C stop-the-world smoke driver's entry, walks
  into a growable buffer, copies up to the caller's capacity, and returns the true total; the driver
  clamps its loop. `rtCollectRoots`, used only by the walk fixtures, stores up to its capacity and returns
  the true total, since the runtime tier has no abort primitive.

Measured (one session, `hyperfine -N`, 30 runs): `binary_tree` 605.7 → 603.0 ms (within noise), peak
memory 165 → 157 MB; `alloc_live` 116.4 → 114.8 ms, 76 → 68 MB. The full tier ran in 84 s, from about
106 s, from the same per-collection zero-fill.

Tests, each confirmed to fail on the compiler from before this task:
- `gc-overflow-roots`: three fibers 60 frames deep, 48 Boxes per frame, chained by spawn and join, so
  one walk covers 17,280 root slots; seven minor collections. Before: a wrong checksum.
- `gc-overflow-remembered`: 1.2M promoted Holders each given the same young Box with no allocation in
  between, so one minor drains 1.2M remembered objects. Before: a wrong sum.
- `gc-overflow-mark`: a 1.1M-element array live across major-only collections. Before: a segfault.

The full tier (754 passed), `--check-reproducible` (1707 identical), and the 18 Bazel test targets.

## Refs

`nomuSchedWalkRoots`, `rtWalkFrom`, `rtWalkShadow`, `rtCollectRoots`, `rtCarriersDrainModBufs`,
`rtQueuePush`, the mark and unmark functions (`src/stdlib/runtime.nomu`);
`../../internals/selfhosted-gc.md`; [158](158-gc-packaging.md), [127](127-lxr-collector.md).
