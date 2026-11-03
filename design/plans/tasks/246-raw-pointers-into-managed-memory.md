# Raw pointers into managed memory held across safepoints

**Avenue:** Risk · **Type/Lifecycle:** `correctness · bug` · **Size:** M · **Status:** reproduced; fix open ·
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

## Refs

[241](241-frame-contract.md) (R4, G4); [176](176-shaped-gc-roots.md) 176.5 (the same failure shape);
[180](180-managed-buffer.md) (the access discipline); `src/stdlib/std/prelude/prelude.nomu` (`eq`, `lt`).
