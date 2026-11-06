# Raw pointers into managed memory held across safepoints

**Avenue:** Risk · **Type/Lifecycle:** `correctness · bug` · **Size:** M · **Status:** 246.1 done (`String.eq`/`lt` fixed); 246.2 (the class) done: tracked with their base (d) ·
**Source:** found during [241](241-frame-contract.md)'s measurement of generated code

## The bug

`String.eq` returns false for two equal strings when a collection moves one of them during the comparison.

- **Cause.** `eq` (and `lt`) take each string's byte address once, with `bytePointer()`, then compare in a
  `while` loop. The loop has no calls, so it gets a safepoint poll at its header. A collection requested by
  another carrier stops the fiber at that poll and may move a `heap` string's buffer; the loop keeps reading
  through the old address. In machine code (`prelude6String2eq`) the two addresses sit in `x20` and
  `x21` across the poll's slow call. For a `small` string the address is a stack slot, which a moving stack
  would break the same way.
- **Reproduction.** One fiber allocates to force minor collections while another compares fresh 10 KB heap
  strings against a long-lived equal one, 20,000 times (`tests/fixtures/string_eq_moving`, not yet a suite case; correct output is `bad 0 1`):
  with 4 carriers and `NOMU_NURSERY_RESERVE=1`, 8 of 12 runs reported a mismatch; on one carrier, none. The
  same loop written with `byte(at:)`, which takes the address from the reloaded `String` each time, gave 0
  of 12.
- **Why it hid.** One fiber cannot hit it: a collection at that poll needs another carrier to request it. The
  stale copy is often intact, so a mismatch needs the moved-from memory reused before the loop ends, as in
  176.5.

## The class

A `RawPtr` taken from managed memory is an interior pointer the statepoint rewrite cannot see (it is made
by `ptrtoint`/`inttoptr`), and I12, which forbids interior pointers across a safepoint, checks only SSAIR's
address operations. The sources:

- `StringBase.bytePointer()` (`strPtr` in `SSAIRToLLVM.swift`): a heap buffer interior, or a stack slot.
- `ManagedBuffer.headerPtr()` and `elementPtr(at:)`: documented as "used within a safepoint-free region"
  (task 180), with nothing to enforce it; user-visible through the core package.
- `__gcObjAddr`: documented as sound only on a non-moving heap.

The frame-address split (243, claim 2) finds the stack half independently: in `String.eq` and `String.lt`
it reports two frame-derived values it cannot recompute, the select between a `small` string's inline bytes
and its heap buffer. A fix here has to keep both halves off the poll; the split cannot recompute a merged
address.

The stack check reaches the same class (104.3.1): it runs before a function's first call, so a short
string's byte address taken before it (`print`'s, in any function that prints a string) is live across its
slow path, held in a scratch register `preserve_most` keeps; a stack moved there leaves it stale. The suite
at `stack_move_checks=1` or `=3` crashes on it (`globals-startup`, `string-surface`).

## Options

- **(a) Rewrite the callers** so no raw pointer spans a poll: `eq`/`lt` reload per iteration or per chunk.
  Fixes the known instances only.
- **(b) Enforce it:** extend I12 to `RawPtr` values derived from managed or frame memory (the intrinsics
  above mark their results), rejecting any live across a safepoint. Callers then re-derive after each
  safepoint, as I12 already requires for interior pointers.
- **(c) Make such loops safepoint-free:** no poll in a bounded loop over a buffer. Changes stop-the-world
  latency and preemption (236) and does not cover loops with calls.
- **(d) Track them:** record raw pointers derived from managed memory with their base, which the frame
  mechanism of [194](194-gc-frame-metadata.md) may provide (241, R4).

(a) fixes the bug now; (b) or (d) closes the class, and 194's contract (241) owns that choice.

## Work

- **246.1 The known instances: done.** `eq` and `lt` compare with one call, the new
  `RawPtr.compareBytes(with:byteCount:)` (`memcmp`, gc-leaf), so no byte address is live across a stop:
  option (a). The other `bytePointer` users hold no address across a stop: `byte(at:)` loads at once, and
  `concat` copies with gc-leaf calls. The fixture is the suite case `string-eq-moving` (4 carriers, a
  one-block nursery). Before the fix, a copy of the old byte loop in the fixture compared wrong in 5 of 12
  runs; after it, 0 of 50, and 0 of 50 with `NOMU_STACK_MOVE=1`. K2 no longer reports unhandled values in
  either function. The run is also faster (0.33 s against 0.45 s), since `memcmp` is vectorized. Full suite
  937/937, with and without `--run-setting stack_move=1`.
- **246.2 The class: open.** `ManagedBuffer.headerPtr`/`elementPtr`, `__gcObjAddr` and any future
  `bytePointer` caller can still hold a raw address across a stop. 194's decision (recording B) makes (d)
  available: interior pointers become derived pointers RS4GC records with their base, and possibly-stack
  addresses are tracked values.
  **Decided: (d).** The intrinsics that make raw pointers from managed or frame memory produce tracked
  values; RS4GC records a heap interior pointer with its base, and the tracking pass handles a stack
  address. Code like the old byte loop is then correct as written. Why over (b): it follows 194's
  recording B and lifts I12's rule where (b) extends it; its cost is a spill and reload per stop such a
  pointer spans, the same as a heap reference. Open: the merged case (`bytePointer`'s select between a
  `small` string's stack slot and a heap buffer), whose base differs by path.
  **Done** (as [104](104-fiber-stack-strategy.md).3.2):
  - **The marker.** Codegen makes each such `RawPtr` with `nomu.raw.interior(base, offset)`, both
    integers: `bytePointer` (base the small string's slot, the heap buffer or the immortal bytes; offset
    16 for a heap buffer, else 0), `headerPtr`, `elementPtr(at:)` and `__gcObjAddr` (base the object).
    The merged case is settled by selecting the base before the marker, so one pointer has one base on
    every path. The runtime package keeps plain addresses.
  - **The tracking.** The frame-address tracking (`TrackFrameAddresses.cpp`) turns the marker into the
    base as a tracked value plus a GEP by the offset; everything derived from it (GEPs, PHIs, selects) stays
    tracked, as for `nomu.frame.addr`. The statepoint rewrite records (base, derived) pairs.
  - **The runtime.** The walker (`rtWalkFrom`, `rtCollectRoots`) reads the stack map's GC locations as
    pairs and roots only the base; before, it rooted base and derived both, so every root was counted twice
    (six suite expectations halved). In slot mode a derived pointer in a slot of its own is kept with its
    base slot and offset (`rtRootsAddDerived`); after a moving collection `rtRootsFixDerived` rebuilds it
    from the base's new address, and the copier adjusts it like any slot. A base into a stack or a global
    is not a managed object, so the collector leaves it and its derived pointers alone.
  - **Tests.** `string_eq_moving` gained `loopEq`, the old loop's shape: both byte pointers held across a
    call and an allocation per byte, for a heap string and a small one. Without tracking
    (`measure_no_frame_split`) the small case crashes under `NOMU_STACK_MOVE_CHECKS=3` every run and the
    heap case compared wrong in 1 of 6 runs; with it, 12 of 12 correct, and correct with stack moves. The
    suite passes plain, at `stack_move=1`, `stack_move_checks=7`, `=3` and `=1`, and with 32 KiB stacks
    (995/995 each), which `globals-startup` and `string-surface` failed before. Cost against no tracking, within
    noise: `frames_strings` −0.5%, `frames_tree` +1.2%, `binary_tree` +0.2%, `micro_dispatch` −2.1%.

## Refs

[241](241-frame-contract.md) (R4, G4); [176](176-shaped-gc-roots.md) 176.5 (the same failure shape);
[180](180-managed-buffer.md) (the access discipline); `src/stdlib/std/prelude/prelude.nomu` (`eq`, `lt`).
