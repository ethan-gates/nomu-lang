# Array buffer onto `ManagedBuffer` — migrate + retire the ad-hoc kind-1 machinery

**Avenue:** Infra (collections-storage consolidation) · **Type/Lifecycle:** `codegen · runtime · ready-to-build`
· **Size:** M · **Status:** done — `Array`'s buffer is a `ManagedBuffer<EmptyHeader, Element>` at the
element's own stride; split out of [180](180-managed-buffer.md) 180.4 so the byte-identical String re-key
shipped on its own.
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

- **181.1 — packed stride + element access.** Done. `EgressArrays` (`lowerArrayLit`, `elementAddr`,
  `emitArraySet`, `emitArrayAppend`) steps by `rawStride` (the element's size in the value layout, at least 1,
  since a descriptor stride of 0 marks a fixed object) from `arrayElementStart`. `Array<Bool>` and
  `Array<UInt8>` step by 1 byte, a three-byte struct by 3, a zero-size struct by 1.
- **181.2 — re-key the descriptor.** Done. `arrayBufTypeId(elem)` is
  `managedBufferTypeId(header: EmptyHeader, element: elem)`; the runtime's buffer scan is unchanged.
- **181.3 — differential baseline.** Done. `arr-gc` and `arr-gc-evac` pass; new fixture `gc_dense_arrays`
  (arrays of `Bool`, `UInt8`, a three-byte struct, a struct whose reference precedes its byte field, a struct
  holding a `String`, and a zero-size struct, built by literal and append and rewritten in place after they
  survive collections) as suite cases `arr-dense` (GC stress), `arr-dense-release` and `arr-dense-immix`.
  Full tier 1927 passed before the new cases.
- **181.4 — retire the ad-hoc machinery.** Done. `registerArrayMap`, `arrayElemStride` and the array-buffer
  cache are gone; `registerBufferMap` / `managedBufferTypeId` is the single buffer-descriptor path.
  `arrayHandleTypeId` (the fixed `{header, len, bufptr}` handle) stays.

Measured (196.1's pairs, best of 5): `Array<Bool>` and `Array<UInt8>` of 4M take 10 MB of RSS where they
took 67 MB, matching the hand-packed buffers, and build in 47–49 ms where they took 64.

## Open design fork — decided: keep the inline geometry

Whether `EgressArrays` element store/load should be re-expressed on top of the `storeRef` / `ref` /
`elementPtr` intrinsics built in [180](180-managed-buffer.md) 180.3, or keep its inline `storeField` geometry
and share only the descriptor and stride. Kept inline: the layout change needs only the stride
(`rawStride`) and the element start (`arrayElementStart`), and the buffer is byte-identical to a
`ManagedBuffer<EmptyHeader, Element>` either way, which re-expressing through the intrinsics can still
build on later.

## Shareability

`ManagedBuffer` has no fields, so the share rule counts it, and any struct holding one, as shareable. That is
sound for `String` (immutable bytes) and `Channel` (contents the runtime synchronizes,
[102](102-channels.md)), but an `Array` on a `ManagedBuffer` is mutable: it must not become shareable this way.
Give the buffer's shareability to its element type and its user, rather than to the class. Not reached by
this task: `Array` stays the builtin `.array` type, and only its buffer's descriptor and stride changed, so
the share rule sees no `ManagedBuffer`.

## Dependencies

- A dependency of [196](196-dense-value-layout.md) (dense value layout), which owns dense layout for every
  type and settled element layout: an element's stride is its size from 196's layout function
  (`ShapeEnv.size`), so `Array<Bool>` and `Array<UInt8>` step by 1 byte once `Array` is a `ManagedBuffer`.
  196's 196.9 re-measures the byte arrays after this task.

## Refs

Split from [180 managed buffer](180-managed-buffer.md) 180.4 (the Array half); the ad-hoc kind-1 array buffer
it retires (`LLVMGenGCMaps` `registerArrayMap` / `arrayBufTypeId` / `arrayElemStride`, `EgressArrays`,
`runtime.c` `nomu_gc_live_offsets` kind-1 path). Depends on 180 (the `ManagedBuffer` primitive + typed
accessors). Consumed by [124 generic hash map](124-generic-hashmap.md) indirectly (same storage substrate).
