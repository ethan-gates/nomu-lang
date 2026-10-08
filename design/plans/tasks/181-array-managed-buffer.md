# Array buffer onto `ManagedBuffer` — migrate + retire the ad-hoc kind-1 machinery

**Avenue:** Infra (collections-storage consolidation) · **Type/Lifecycle:** `codegen · runtime · ready-to-build`
· **Size:** M · **Status:** ready-to-build — split out of [180](180-managed-buffer.md) 180.4 so the
byte-identical String re-key ships on its own; this task carries the one piece with a real layout change.
· **Source:** the Array half of 180's "adopt" phase, separated because it changes `Array<small-scalar>`
layout and wants its own differential baseline.

## What

Migrate `Array`'s backing buffer off the ad-hoc kind-1 array buffer onto a `ManagedBuffer<EmptyHeader, T>`
instance, then retire the now-unused ad-hoc machinery (`registerArrayMap`, `arrayBufTypeId`,
`arrayElemStride`), leaving `managedBufferTypeId` / `registerBufferMap` as the single buffer-descriptor path.

The Array *handle* (`{ header, len, bufptr }`, a fixed object via `arrayHandleTypeId`) is unchanged — only the
buffer it points at migrates. `String`'s heap storage already moved onto `ManagedBuffer` in
[180](180-managed-buffer.md) 180.4, so after this task the ad-hoc kind-1 path has no consumers.

## Why

[180](180-managed-buffer.md) built the shared managed buffer so each collection stops re-synthesizing its own
kind-1 storage. The array buffer `{ type-id@0, cap@8, elems@16 }` is the `headerSize = 0` case of that
primitive, so it should *be* a `ManagedBuffer<EmptyHeader, T>` rather than a parallel descriptor path the
collectors must keep in lockstep separately. Collapsing it removes the second buffer-descriptor source and the
`arrayElemStride` 8-slot model that `ManagedBuffer`'s packed stride supersedes.

## The layout change (the risk)

The array buffer is byte-identical to a `ManagedBuffer<EmptyHeader, T>` except for **element stride**:

- today `arrayElemStride(t) = max(slotCount(t) * 8, 8)` — every element rounded up to an 8-byte slot;
- `ManagedBuffer` uses `rawStride(t)` — the packed natural size (`UInt8` → 1, a reference → 8, a value
  aggregate → its packed size).

For reference elements both are 8, so `Array<SomeClass>` is unaffected. The change bites `Array<small-scalar>`
(`Array<UInt8>` becomes 8× denser) and value-aggregate elements: the element-offset math in `EgressArrays`
(`16 + i * stride`) and the descriptor's per-element managed map (repeated every `stride`) must agree on the
packed stride. Element load/store already run at the element's native width off the `elementAddr` slot, so
what moves is the stride constant and the descriptor, not the access width.

## Phases

- **181.1 — packed stride + element access.** Route `EgressArrays` (`lowerArrayLit`, `elementAddr`,
  `emitArraySet`, `emitArrayAppend`) off `arrayElemStride` onto `rawStride`, so codegen geometry and the
  stamped descriptor share one stride source. This is where `Array<small-scalar>` layout changes (8-slot →
  packed) and the element-offset math moves.
- **181.2 — re-key the descriptor.** `arrayBufTypeId(elem)` becomes `managedBufferTypeId(header: EmptyHeader,
  element: elem)`; the array buffer is then a genuine `ManagedBuffer` instance stamped with the shared
  buffer descriptor. The `runtime.c` / `lib.rs` / `runtime.nomu` kind-1 scan is unchanged (same kind, same
  geometry 180.1.2 already generalized).
- **181.3 — differential baseline.** Keep `arr-gc` / `arr-gc-evac` green, and add small-scalar /
  value-aggregate array cases (`Array<UInt8>`, `Array<Point>` with a managed field) exercised across the
  moving collectors, run against the live array buffer as the regression oracle — the step 180.4 deferred
  here. A stride or element-map mismatch strands or mis-scans an element and diverges from the baseline.
- **181.4 — retire the ad-hoc machinery.** With String (180.4) and Array both migrated, delete
  `registerArrayMap`, `arrayBufTypeId`, and `arrayElemStride`, leaving `registerBufferMap` /
  `managedBufferTypeId` as the single buffer-descriptor path. `arrayHandleTypeId` (the fixed `{header, len,
  bufptr}` handle) stays — it is a kind-0 object, not a buffer.

## Open design fork

Whether `EgressArrays` element store/load should be re-expressed on top of the `storeRef` / `ref` /
`elementPtr` intrinsics built in [180](180-managed-buffer.md) 180.3, or keep its inline `storeField` geometry
and share only the descriptor. Re-expressing removes the duplicated barrier/offset arithmetic (one element
path for every collection); keeping it inline avoids threading `monoTypeArgs` through the array handle's
element type at codegen. Decide at 181.1 — it sets how much of `EgressArrays` collapses.

## Refs

Split from [180 managed buffer](180-managed-buffer.md) 180.4 (the Array half); the ad-hoc kind-1 array buffer
it retires (`LLVMGenGCMaps` `registerArrayMap` / `arrayBufTypeId` / `arrayElemStride`, `EgressArrays`,
`runtime.c` `nomu_gc_live_offsets` kind-1 path). Depends on 180 (the `ManagedBuffer` primitive + typed
accessors). Consumed by [124 generic hash map](124-generic-hashmap.md) indirectly (same storage substrate).
