# Managed tail-allocated buffer — the shared collection-storage primitive

**Avenue:** Usability (the collections-storage substrate) · **Type/Lifecycle:**
`stdlib · runtime · codegen · done` · **Size:** L · **Status:** done — 180.1–180.4 built + green (suite
125/125): the generalized buffer descriptor, header-aware geometry across all three collectors, the
`ManagedBuffer<Header, Element>` type + tail-alloc primitive + typed reference accessors, and String's heap
byte buffer re-keyed onto the shared buffer descriptor (180.4). The `Array`-buffer migration + ad-hoc kind-1
machinery retirement are [181](181-array-managed-buffer.md); the residual `stringStorageTypeId` /
`__nomu_stringstorage_typeid` symbol retirement rides [121](121-string-utf8-model.md) 121.1.3 (it needs the
`StringBase` restructuring first). · **Source:** split out of [121 String](121-string-utf8-model.md) (the
`heap` byte buffer `StringBase.allocHeap` returns) once the heap storage was recognized as the same facility
`Array` already needs ad hoc and a future `Dictionary` will need — so it is built once, correctly, rather than
per collection.

## What

One **managed, relocatable object** carrying a fixed header plus a variable-length tail of elements —
`{ GC header (type-id), fixed header fields…, capacity, element[0 … cap) }` — in a single allocation,
relocated as a single object. The reusable backing under `Array`'s buffer, `String`'s `heap` storage, and a
future `Dictionary`/`Set`. Nomu's analog of Swift's `ManagedBuffer` / `allocWithTailElems` (the thing
`__StringStorage` is built on).

The point is **one indirection, one object**: element/byte access lands at a fixed offset off the object
base, with no handle hop. A collection holds a pointer straight to this buffer.

## Why

Variable-length managed storage — a header plus an inline element tail — is the shape every growable
collection needs. Today only `Array` has it, as the kind-1 array buffer synthesized ad hoc in codegen
(`{ header, cap, elems }`). Without a shared primitive, each new collection either re-synthesizes its own
kind-1 buffer in codegen/C (more compiler magic per type) or wraps `Array` and pays a double indirection — a
fixed object → an `Array` handle `{ len, bufptr }` → the buffer — which lands an extra load on every hot
element access plus an extra allocation and an extra object to scan/relocate per instance. `String`'s heap
storage hit exactly this question ([121](121-string-utf8-model.md)): Swift avoids the double indirection only
because `__StringStorage` is a tail-allocated class, not a plain class. A first-class tail-allocated buffer
gives every collection the single-object, single-indirection, relocatable backing, with its own header for
type-specific metadata (capacity, flags, a future refcount), done once.

## Requirements

- **One allocation, one object.** `{ header, fixed header fields, capacity, tail elements }`. Element `i`
  sits at `headerSize + i * stride`; the owner's pointer is the object base.
- **GC-integrated.** The collector sizes it (`headerSize + cap * stride`) and scans it — the header's
  managed-pointer map *and* each element's managed-pointer map. This **generalizes the current kind-1
  descriptor**, which hardcodes `headerSize = 16` (`{ type-id, cap }`), no header managed pointers, and an
  element map. The generalized descriptor reads: header byte size, header managed map, `cap` location,
  element stride, element managed map. The existing kind-1 array buffer is then one special case.
- **Relocatable** on the moving collectors — rides the existing kind-1 relocation and both-collector lockstep.
- **Generic element.** `Element` may be a POD scalar (`UInt8` for `String`), a managed reference
  (`Array<SomeClass>`), or a value aggregate (`Array<Point>`); the element managed map comes from the element
  type, as array buffers already derive it.
- **Header for type-specific metadata** — capacity/count bookkeeping, flags (String's isASCII / scalar-count
  cache), and the natural home for a refcount once [127 LXR](127-lxr-collector.md) makes RC the
  uniqueness/COW signal.

## Layout and descriptor (decided)

### Object layout

One allocation, four regions, each reached at a fixed offset off the buffer base:

```
offset 0                  GC type-id header               (8 bytes, primitive-owned)
offset 8                  cap — allocated element count    (8 bytes, primitive-owned)
offset 16                 Header fields                    (headerSize bytes)
offset 16 + headerSize    element[0 … cap)                 (stride bytes each)
```

`cap` is pinned at offset 8 so the collector reads the object's extent with one load and no map indirection
on the sizing path. The user `Header` begins at offset 16; elements begin at `16 + headerSize`. A consumer's
own live-element `count` (distinct from the allocated `cap`) is an ordinary `Header` field when it wants one —
the collector only ever reads `cap`, and scanning a zeroed tail is safe because unused managed element slots
hold null.

**The array buffer is the empty-header instance.** With `headerSize = 0` the layout is
`{ type-id@0, cap@8, elems@16 }` — byte-identical to today's array buffer, so the migration (180.4) is a
mechanical re-key onto the shared path with the existing buffer as the regression baseline.

Both the `Header` and the `Element` may carry managed references, each with its own managed-pointer map (an
`Array<SomeClass>` has managed elements; a header may hold a managed reference). The header map is applied
once over `[16, 16 + headerSize)`; the element map is applied at each of the `cap` element bases, as the
array buffer does today. (A *shaped* field — a `String` — sitting inside a header or element folds the way
the kind-0 object path folds a shaped field today; that fold for buffer headers/elements is a later cut,
matching the array buffer, which likewise does not yet fold a shaped element.)

### Descriptor

The collector dispatches on a descriptor's `kind` field — a collector-internal tag, nothing language-facing:
`0` = fixed-size object, `1` = variable-length buffer, `2` = shaped value (`String`). This **generalizes the
existing buffer descriptor (`kind 1`) in place** rather than adding a new kind, so the array buffer becomes
its `headerSize = 0` special case and there is one buffer code path per collector to keep in lockstep, not
two near-duplicates.

The fixed descriptor record grows from `{ size, stride, kind, nptr, ptrmap_off, nshaped }` (24 bytes) by two
i32 — `headerSize` and `nHeaderPtr` — to 32 bytes. The out-of-line pointer-map blob for a buffer is the
header managed offsets followed by the element managed offsets:

```
ptrmap = [ headerOff …(nHeaderPtr) , elementOff …(nptr) ]
```

For a plain array buffer `headerSize = 0` and `nHeaderPtr = 0`, so the blob is the element offsets exactly as
today — array descriptor content is unchanged. The collector then:

- **sizes** a buffer as `16 + headerSize + cap * stride` — `cap` at offset 8, `headerSize` / `stride` from
  the record, all already-loaded fields, no map indirection;
- **scans** it by applying the header map once over the header region, then the element map at each of the
  `cap` element bases from `16 + headerSize`.

**Hot-path cost ([178.1](178-runtime-gc-performance.md)).** The per-element / per-word scan loop is unchanged
from today's array buffer. The generalization adds, per *object* (not per element or word), one `headerSize`
load and one add to locate the element region, plus an `nHeaderPtr`-iteration header-map pass that is zero
iterations for every array. The common kind-0 object path and the array hot path keep their current cost.

### Stride, growth, and refcount (decided)

- **Element stride is the packed natural size** (C-style, as String bytes and `Ptr<T>` already stride):
  `UInt8` → 1, `Int` or a managed reference → 8, a value aggregate → its packed size. This drops the array
  buffer's current 8-byte-slot rounding (`max(slotCount*8, 8)`), making `Array<UInt8>` 8× denser; a managed
  reference stays 8 bytes, so the element map is unchanged in the reference case. The 180.4 Array migration
  therefore also changes `Array<small-scalar>` layout and its element-offset math — the riskiest step, run
  against the live buffer as its differential baseline.
- **The buffer is fixed-capacity.** `cap` is immutable after allocation; there is no in-place grow. Growth is
  the consumer's job — allocate a larger buffer, copy, repoint, drop the old one. A moving/compacting
  collector cannot extend an object in place, so growth is "new buffer + copy" regardless; keeping it in the
  consumer holds the primitive to one job and makes `cap` an invariant the GC reads with no synchronization.
- **The COW refcount is storage-owned, placed when [127 LXR](127-lxr-collector.md) lands.** 180 reserves no
  physical slot — the current generational Immix collector carries no refcount, and spending 8 bytes per
  buffer now would tax every allocation. What 180 fixes is only that the refcount lives on the buffer (every
  reference to the shared storage reads one count); its representation — header-word bits (the LXR style) or a
  prefix slot — is a 127/123 call, and the header layout stays extensible so it drops in without disturbing
  consumers.

## Surface (decided)

`class` is fixed-size with no tail-allocation surface, so the primitive needs one. The surface is a
stdlib-facing generic **`ManagedBuffer<Header, Element>`** (Swift's factoring), with the compiler magic
confined to two points — the same split that keeps `StringBase` thin in 121:

- **The allocation primitive** — an `allocWithTailElems` analog. Given `Header` / `Element` (which fix the
  descriptor type-id) and a runtime `cap`, it allocates `16 + headerSize + cap * stride` zeroed bytes, stamps
  the type-id header, writes `cap` at offset 8, and returns the base as a rooted managed pointer. Plan-aware
  (nursery vs. large-object by size) and rooted across its own safepoint, like every managed alloc.
- **The descriptor generator** — the compiler derives `headerSize` and the header managed map from `Header`,
  and `stride` and the element managed map from `Element`, through the existing `collectManagedOffsets` /
  layout machinery, and emits the generalized buffer descriptor above.

A `ManagedBuffer` value is a managed pointer (`p1`) straight to the buffer base — one object, one
indirection. Header and element access is through `RawPtr` ([125](125-unsafe-raw-memory.md)): the header at
`base + 16`, element `i` at `base + 16 + headerSize + i * stride`. A collection (`Array`, `String`'s heap
storage, a future `Dictionary`) holds this pointer directly.

**Access across a safepoint.** A `RawPtr` into the buffer is an interior pointer, so the derived address is
taken fresh from the live `ManagedBuffer` value and used within a safepoint-free region, reloaded after any
safepoint — the discipline `Array` already follows: the handle is the GC root, element addresses are
recomputed, a collection relocates the buffer, and the next access reloads. The `ManagedBuffer` value is the
root the inference + rooting machinery keeps live; that liveness plus the reload discipline covers access, so
the surface stays the raw accessors with no scoped-closure pinning form layered on top.

Alternatives set aside: a dedicated tail-allocated `class` form or attribute (more language surface, more
invasive), and a purely compiler-internal buffer with no Nomu type (rejected by the do-it-right goal — this
should be a real, reusable type).

## Consumers / relationships

- **[121 String](121-string-utf8-model.md)** — the `heap` byte buffer behind `StringBase.allocHeap` is a
  `ManagedBuffer<StringHeader, UInt8>`. 121 depends on this task for its heap storage.
- **[181 Array-on-ManagedBuffer](181-array-managed-buffer.md) / `Array`** — `Array`'s buffer migrates off the
  ad-hoc kind-1 path onto the shared primitive (the existing buffer is the validation baseline), retiring the
  ad-hoc kind-1 machinery. Split out of 180.4 because it carries a real layout change; see task 181.
- **[124 generic hash map](124-generic-hashmap.md)** — its storage buffer.
- **[123 copy-on-write](123-copy-on-write.md) / [127 LXR](127-lxr-collector.md)** — the header is where a
  refcount lives once RC gives uniqueness directly.
- **Rests on:** [125 unsafe raw memory](125-unsafe-raw-memory.md) (element access), the existing kind-1
  array-buffer machinery (generalized here), and the GC type-descriptor machinery
  (`internals/memory-model.md` §6, `LLVMGenGCMaps`). Both collectors stay in lockstep on the generalized
  descriptor.

## Phases

- **180.1 — generalized buffer descriptor.** Append `headerSize` + `nHeaderPtr` to the record (24 → 32 bytes;
  existing field indices stay put), extend the ptrmap blob to `[header offsets, element offsets]`, and teach
  all three collectors (`runtime.c`, `gcbinding/lib.rs`, `stdlib/runtime.nomu`) to size a buffer as
  `16 + headerSize + cap * stride` and scan the header map once, then the per-element map from
  `16 + headerSize`. Built in three sub-phases:
  - **180.1.1 — record growth.** Grow the descriptor record to 32 bytes with the two new fields emitted as 0,
    and route the record stride through one runtime source (`nomu_gc_descsize` / `RawPtr.gcDescSize()`) so the
    self-hosted type-id ↔ ordinal math stops hardcoding the width. Behavior-preserving. Growing the record
    shifts every type-id (a descriptor's section offset), so build clean across the embedded-sources genrule
    and the Rust binding together — this sub-phase isolates and validates that shift.
  - **180.1.2 — `headerSize`-aware geometry.** Replace the hardcoded element start and size formula with
    geometry read from the descriptor. The self-hosted collector duplicates the `cap@8` / `16 + i*stride` /
    `16 + cap*stride` arithmetic across ~14 sites in ~10 phases (`rtObjHash`, `rtObjSize`, the mark / evac /
    verify loops); MMTk centralizes it in three (`scan_object`, `get_current_size`, `mv_obj_hash`). Pull the
    element start into one helper (`rtBufElemStart`, a Rust/C equivalent) so the `16 → 16 + headerSize` change
    has a single definition per collector. Behavior-preserving (every real type is still `headerSize = 0`);
    the array buffer stays the byte-identical `headerSize = 0` baseline.
  - **180.1.3 — header scan + first consumer.** Add the once-per-buffer header-pointer scan loop (the phase's
    own per-reference action over `nHeaderPtr` offsets at `base + 16`) and fold the header's scalar words into
    `rtObjHash`. Zero-cost for every near-term consumer (String / Array / Dictionary headers are scalar, and
    `nHeaderPtr = 0`). **Lands with 180.2, not before** — the header-pointer scan can only be exercised by a
    buffer that carries a header, and nothing can allocate one until the tail-alloc primitive exists. So the
    header-scan code, the Swift header-offset descriptor emit, and the mark-verify / `*-evac` oracle test
    (a buffer with a nonzero header and a managed header pointer, held live across a forced + evacuating GC)
    are built on top of 180.2's first headered buffer — validated for real rather than against a throwaway.
    180.1 is otherwise complete at the geometry level (180.1.1 + 180.1.2, green).
- **180.2 — tail allocation + access.** The plan-aware, rooted, zeroed tail-allocating alloc primitive;
  header and element access via `RawPtr`.
- **180.3 — the `ManagedBuffer<Header, Element>` type.** The stdlib generic over the alloc primitive and the
  descriptor generator; the raw accessors (`capacity`/`headerPtr`/`elementPtr`) and the typed *reference*
  accessors (`storeRef`/`ref` for a reference `Element`, `storeHeaderRef`/`headerRef` for a reference
  `Header`), which store/load a managed pointer through the write-barrier / `p1` path.
- **180.4 — adopt (String).** `String`'s heap byte buffer becomes a `ManagedBuffer<EmptyHeader, UInt8>`:
  `stringStorageTypeId` routes through `managedBufferTypeId`, collapsing the ad-hoc `stringstorage` descriptor
  onto the shared buffer-descriptor path. The layout is byte-identical (`headerSize = 0`, stride 1), so the C
  floor (`rt_str_fill` / concat in `EgressBuiltins`) and the `__nomu_stringstorage_typeid` global are
  unchanged — the global simply holds the ManagedBuffer descriptor's offset now. Hands to
  [121](121-string-utf8-model.md) 121.1.3/.4, which re-keys the header from `EmptyHeader` to a `StringHeader`
  carrying the isASCII / scalar-count cache. The `Array`-buffer migration and the retirement of the ad-hoc
  kind-1 machinery (`registerArrayMap` / `arrayBufTypeId` / `arrayElemStride`) are split out to
  [181 Array-on-ManagedBuffer](181-array-managed-buffer.md) — that migration carries a real layout change
  (`Array<small-scalar>` 8-slot → packed stride) and wants its own differential baseline, distinct from this
  byte-identical String re-key.

## Implementation notes (180.2 / 180.3 build)

Mechanism (decided + partly built): `ManagedBuffer<Header, Element>` is an ordinary **empty generic class**
declared in `core.nomu` (accepted + inert, suite green), so the type system, monomorphization, `p1`
representation, and pass routing come for free. Its four operations are compiler intrinsics synthesized in
`NOIRGen` — `create` intercepted at the static-call site (`ManagedBuffer<H,E>.create(capacity:)`, the `Ptr<T>`
static pattern), the accessors at the instance-call site (receiver typed `ManagedBuffer<H,E>`). The declared
class carries no method bodies; the interception provides them.

Lowering (`SSAIRToLLVM`), modeled on `EgressArrays`:
- `create(capacity:)` → `rtAllocManaged(16 + headerSize + cap*stride)` (returns a tracked `p1`), stamp
  `descOffsetHeader(managedBufferTypeId(H,E))` at 0, store `cap` at 8, return the `p1` — which *is* the
  `ManagedBuffer` reference. The buffer is scanned as a kind-1 buffer via the stamped descriptor; the empty
  class's own kind-0 descriptor is never stamped (harmless if emitted).
- `capacity` → load `@8`; `headerPtr()` → `base + 16`; `elementPtr(at:i)` → `base + 16 + headerSize + i*stride`.

**Open fork — recovering `Header`/`Element` at codegen.** `create` and `elementPtr` need `headerSize`,
`stride`, and `managedBufferTypeId(H,E)`, all derived from the concrete `Header`/`Element`. `Array` reaches
its element type at codegen because `.array(elem)` is a dedicated `Type` case that carries `elem`
structurally through monomorphization; a user generic class instantiation instead becomes a distinct
monomorphized class *by name*, so `H`/`E` are not structurally on the type at codegen. Two ways to resolve,
to decide before building `create`/`elementPtr`:
1. a dedicated built-in `Type` case `.managedBuffer(header:element:)` (like `.array`) — `H`/`E` survive
   structurally, cleanest codegen access, but more pipeline sites to teach (treat like `.array`);
2. keep the generic class and have monomorphization record a monomorphized-class-name → `(Header, Element)`
   map codegen looks up (the `opaqueUnderlyings` pattern) — fewer pipeline sites, one lookup table.

Fork resolved: the existing `monoTypeArgs` table (specializer-recorded, already threaded to codegen) maps the
instantiation name → `[Header, Element]`; `managedBufferArgs` reads it. No new `Type` case.

**Built + green** (`examples/managed_buffer.nomu`, cases `managed-buffer` / `managed-buffer-evac`, full suite
121/121): `create(capacity:)` (tail-alloc + stamp + cap, returns the tracked `p1`), `capacity()`,
`headerPtr()`, `elementPtr(at:)`. The evac case exercises a nonzero (`Int`) header through the sizing path —
180.1.2 geometry validated on a real headered buffer.

**180.1.3 — built + green.** The once-per-buffer header-pointer scan over `nHeaderPtr` offsets at
`base + 16` is in all 8 self-hosted trace/evac phases (`rtMarkVerify`, `rtMarkVerifyImmix`, `rtLineMarkCheck`,
`rtImmixMark`, `rtImmixUnmark`, `rtGenUnmarkAndUnlog`, `rtImmixEvacMark`, `rtMinorScanObj`) and in `lib.rs`
`scan_object`, each mirroring that phase's per-reference action. The hash functions skip the header region
identically in both collectors, so they stay in lockstep without change (the trace following the header
pointer to its child is what the fingerprint covers). Validated by `examples/managed_buffer_ref.nomu` (cases
`managed-buffer-ref` / `-evac` / `-self`): a `ManagedBuffer<Box, Box>` with a managed pointer in both header
and element, reachable only through the buffer, held live across relocating GC — the header and element
pointers relocate correctly under MMTk evacuation and the self-hosted STW collector, matching the NoGC
baseline.

**Typed managed accessors — built + green.** `storeRef(_:at:)` / `ref(at:)` (reference `Element`) and
`storeHeaderRef(_:)` / `headerRef()` (reference `Header`) let Nomu code put a managed reference in a buffer —
the facility `Array<SomeClass>` needs — rather than the raw-`addrOf` test trick. Sema
(`ManagedBufferIntrinsics`) reads `Header`/`Element` from the receiver's generic type and rejects a
non-reference type arg with a targeted diagnostic (a scalar/value element uses the raw `elementPtr(at:)`);
codegen computes the slot off the buffer `p1` (staying addrspace(1)) and routes the store through `storeField`
(the write barrier), the load as a plain `p1` load — the same mechanism as the array element store. The
managed reference passed as a call argument escapes conservatively through the ordinary points-to path, so the
stored object is kept live with no special escape modelling. The oracle `examples/managed_buffer_ref.nomu` now
stores through `storeHeaderRef` / `storeRef` and reads back through `headerRef` / `ref`, so the three oracle
cases exercise the barrier path end to end on both moving collectors; `managed-buffer-scalar-ref-bad` pins the
reference-only diagnostic.

**Task 180 is complete and green** (suite 125/125): 180.1 + 180.2 + 180.3 (descriptor, geometry, the
`ManagedBuffer` type + typed reference accessors) and 180.4 (String's heap byte buffer re-keyed onto the shared
buffer descriptor, byte-identical). Two follow-ons live in other tasks: the `Array`-buffer migration + ad-hoc
kind-1 machinery retirement (a real `Array<small-scalar>` layout change) is [task 181](181-array-managed-buffer.md);
the residual retirement of the bespoke `stringStorageTypeId` / `__nomu_stringstorage_typeid` symbols — routing
String's heap allocation through the `ManagedBuffer` primitive rather than the inline `rtAllocManaged` in
`EgressBuiltins` concat — rides [121](121-string-utf8-model.md) 121.1.3, which needs the `StringBase`
restructuring first.

## Refs

Split from [121 String](121-string-utf8-model.md) (heap storage); the kind-1 array buffer it generalizes
(`LLVMGenGCMaps` `registerArrayMap`, `runtime.c` `nomu_gc_live_offsets` kind-1 path); Swift `ManagedBuffer` /
`__StringStorage` as prior art.
