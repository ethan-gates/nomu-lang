# A vector of references kept only its first lane rooted

**Avenue:** Risk · **Type/Lifecycle:** `compiler · bug` · **Size:** S · **Status:** done · **Source:**
[253](253-finish-generics.md) 253.8's sweep of the suite in every mode (253.14).

## What

`sched-mixed-load` failed in any optimized build on 4 carriers or more: a segfault in a minor collection's stack-root
scan, or a hang. Its suite cases ran debug only, so nothing caught it; it was older than 253.

The vectorizer (`default<O3>`) merged two adjacent loads of references, a relay fiber's `tally` and `done` read from
its environment, into one `<2 x ptr addrspace(1)>` load. `rewrite-statepoints-for-gc` relocates such a vector but
records it as one stack-map location of 16 bytes, and the runtime's walk reads each location as one pointer. The
second lane, `done`'s buffer, went unrooted: a minor moved the buffer, the relay kept the old address, and every
message it sent after carried it, so the sinks' handlers handed the collector string bytes as an object.

## Work

- **267.1** Done. `nomu-split-reference-aggregates` (`src/llvmpasses`) splits a vector of references as it splits an
  aggregate: each lane is read out where the vector is defined, and a use a stop may separate from the definition
  takes the lane, or the vector rebuilt from the lanes right before it. The rewrite then tracks each lane as a
  pointer, and the runtime's one-pointer-per-location rule holds. The other ways out were to read a location's
  size in every runtime walker, base and derived vectors paired lane by lane, or to turn the vectorizer off.
  Test: `sched-mixed-load-release` (fails before the fix on 4, 6 and 8 carriers, 6 runs in 8 at 6).

## How it was found

`no_inline` hid it; bisecting the inliner by caller and callee narrowed it to `Channel<Msg>.receive` inlined into
`relay`, which put the two loads side by side. A walk that reported each bad root with its frame's return address
showed the bad value was `done`'s first address, held only by the sinks' handler thunks, and that the relay fiber's
frame recorded six of its seven references. The IR showed the vector load.

A compiler built with LLVM's assertions stops on this program in the rewrite ("support for FCA unimplemented"), but
that assertion fires on any aggregate holding a reference, live or not (253.15), so it does not point at this.
