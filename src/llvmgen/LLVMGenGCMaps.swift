import noir
import mangle
import ast
import support
import LLVM_C
import ssair

// M6 GC pointer-map machinery (moved into the shared emitter, ssair.md): assign a type-id +
// managed-field offset map to each heap type (class/actor/closure/`any`-box/array-buffer/mailbox),
// stamp it into an object header, and emit the flat runtime tables at module finalization.
extension LLVMGen {
    // Register a fixed-size object's pointer map (managed-field byte offsets) + total byte size; the
    // returned type-id indexes `typeMaps`/`typeSizes`/`typeKinds`/`typeStrides`.
    func registerMap(_ offsets: [Int32], sizeBytes: Int32, symbol: String, foldable: Bool,
                     shaped: [(offset: Int32, shapeId: UInt64)] = []) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(offsets)
        typeSizes.append(sizeBytes)
        typeKinds.append(0)      // fixed
        typeStrides.append(0)
        typeSymbols.append((symbol, foldable))
        typeShaped.append(shaped)
        typeHeaderSizes.append(0)
        typeHeaderMaps.append([])
        return id
    }

    // Register an array-buffer type-id: `elementOffsets` are the managed-pointer byte offsets within
    // one element, `stride` its byte size (total size comes from `cap`/`len` at run time).
    func registerArrayMap(_ elementOffsets: [Int32], stride: Int32, symbol: String, foldable: Bool,
                          shaped: [(offset: Int32, shapeId: UInt64)] = []) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // array
        typeStrides.append(stride)
        typeSymbols.append((symbol, foldable))
        typeShaped.append(shaped)   // each element's shaped fields, enumerated per element
        typeHeaderSizes.append(0)   // a plain array buffer has no user header (the empty-header case, task 180)
        typeHeaderMaps.append([])
        return id
    }

    // Register a buffer type-id with a user header (task 180): a kind-1 buffer `{ type-id, cap, Header,
    // Element[cap] }`. `headerSize` is the header byte size (elements begin at `16 + headerSize`),
    // `headerOffsets` the managed-pointer byte offsets within the header (relative to the header base),
    // `elementOffsets` the managed offsets within one element, `stride` the element byte size. The header
    // offsets are emitted as the prefix of the pointer map, before the element offsets. A `ManagedBuffer`
    // instance uses this; the plain array buffer stays the `headerSize = 0` case via `registerArrayMap`.
    func registerBufferMap(headerSize: Int32, headerOffsets: [Int32], elementOffsets: [Int32],
                           stride: Int32, symbol: String, foldable: Bool,
                           shaped: [(offset: Int32, shapeId: UInt64)] = []) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // buffer (kind 1, generalized with a header)
        typeStrides.append(stride)
        typeSymbols.append((symbol, foldable))
        typeShaped.append(shaped)   // each element's shaped fields, enumerated per element
        typeHeaderSizes.append(headerSize)
        typeHeaderMaps.append(headerOffsets)
        return id
    }

    // Register a kind-2 *shaped* descriptor (task 176, `internals/shaped-roots.md` Stage 1): a value whose
    // managed-pointer map is discriminant-keyed rather than flat — a word is a managed pointer only for some
    // runtime tag value. `tagOff`/`tagShift` locate the discriminant: load the i64 at `base + tagOff` and
    // shift right by `tagShift`, the low bits are the tag. `cases` lists each tag value that carries managed
    // pointers and the managed byte-offsets live in that case (tags absent from the list carry none). The map
    // is serialized flat into the shared pointer-map section as
    // `[tagOff, tagShift, ncases, (tag, count, offsets…)…]`, self-describing, and the collector parses it
    // when it sees `kind` 2 (Stage 5). String is the first consumer: `tagOff 8, tagShift 60` (the top nibble
    // of `word1`), one case `heap` → managed offset `0` (`word0`).
    func registerShapedMap(tagOff: Int32, tagShift: Int32, sizeBytes: Int32,
                           cases: [(tag: Int32, offsets: [Int32])],
                           symbol: String, foldable: Bool) -> UInt64 {
        // Per-case format `(tag, nFlat, flat…, nShaped)` — the unified kind-2 layout (task 176.3b). A flat
        // shaped descriptor (String) has no nested sub-entries, so `nShaped` is 0; the enum emitter writes the
        // same shape with its `(off, subId)` pairs after the count.
        var serial: [Int32] = [tagOff, tagShift, Int32(cases.count)]
        for c in cases {
            serial.append(c.tag)
            serial.append(Int32(c.offsets.count))
            serial.append(contentsOf: c.offsets)
            serial.append(0)   // nShaped
        }
        let id = UInt64(typeMaps.count)
        typeMaps.append(serial)
        typeSizes.append(sizeBytes)
        typeKinds.append(2)      // shaped
        typeStrides.append(0)
        typeSymbols.append((symbol, foldable))
        typeShaped.append([])    // a shaped descriptor is itself the sub-shape; it has no shaped fields
        typeHeaderSizes.append(0)
        typeHeaderMaps.append([])
        return id
    }

    // Descriptor symbols come from `Mangle.descriptor`: the kind and the type, qualified by the module that
    // declares the type, so the linker folds copies of one type's descriptor across modules and never two
    // types' (task 100.4.7, task 203).

    // Type-id for a class/actor heap type; assigns one (and computes its pointer map) on first use.
    func typeId(forHeapType name: String) -> UInt64 {
        if let id = typeIds[name] { return id }
        let fieldTypes: [Type] = classMap[name].map { $0.fields.map(\.type) }
            ?? actorMap[name].map { $0.fields.map(\.type) } ?? []
        let isActor = actorMap[name] != nil
        var d = descriptorEntries(shapes.fieldsShape(fieldTypes, base: 8))   // header is slot 0; fields follow
        let slot = 1 + fieldTypes.reduce(0) { $0 + slotCount($1) }
        if isActor { d.offsets.append(Int32(slot * 8)) }   // trailing mailbox pointer is scanned
        let totalSlots = slot + (isActor ? 1 : 0)
        let id = registerMap(d.offsets, sizeBytes: Int32(totalSlots * 8),
                             symbol: Mangle.descriptor("desc", named: name, home: homeModule), foldable: true, shaped: d.shaped)
        typeIds[name] = id
        return id
    }

    // The kind-2 descriptor for a shaped leaf, built from the leaf registry (`ShapeLeaf`): the discriminant's
    // word and shift, and the managed word offsets under each tag that has any. For `StringBase`: tag in
    // `word1`'s top bits (`immortal = 0`, `small = 1`, `heap = 2`), `word0` managed only in the `heap` case.
    func leafShapeId(_ leaf: ShapeLeaf) -> UInt64 {
        if let id = leafShapeIds[leaf] { return id }
        let id = registerShapedMap(tagOff: Int32(leaf.tagOffset), tagShift: Int32(leaf.tagShift),
                                   sizeBytes: Int32(leaf.slots * 8),
                                   cases: leaf.managedCases.map { (tag: Int32($0.tag), offsets: $0.offsets.map(Int32.init)) },
                                   symbol: Mangle.descriptor(leaf.name, home: homeModule), foldable: true)
        leafShapeIds[leaf] = id
        return id
    }

    // The heap `String` byte buffer is a `ManagedBuffer<EmptyHeader, UInt8>` (task 180.4) — `headerSize = 0`,
    // stride 1 (byte elements), a GC leaf (no managed pointers in the element). Its type-id comes from the
    // shared `managedBufferTypeId(EmptyHeader, UInt8)` (no String-specific descriptor); `__stringAllocHeap`
    // stamps that id's header word via `emitManagedBufferAlloc`, and the Nomu `concat` fills the bytes. 121
    // later re-keys the header `EmptyHeader` → a `StringHeader` carrying the isASCII / scalar-count cache.

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only.
    func anyBoxTypeId() -> UInt64 {
        if let id = anyBoxMapId { return id }
        let id = registerMap([16], sizeBytes: 24, symbol: Mangle.descriptor("anybox", home: homeModule), foldable: true)
        anyBoxMapId = id
        return id
    }

    // Type-id for a spawn-result box `{ header, result… }` (150.3.13). A completed fiber's result rides in a
    // heap box at fib+216 until the joiner reads it; the self-hosted STW walk roots that slot, so the box must
    // be a proper GC object the moving collector can relocate — a header plus the result's managed-pointer map
    // (shifted past slot 0). A managed result is scanned so it survives + is fixed up too. One shape per result
    // type; the set is small, so a fresh map per call is fine.
    func spawnBoxTypeId(_ t: Type) -> UInt64 {
        let d = descriptorEntries(shapes.shape(t).shifted(by: 8))   // result at slot 1 (header is slot 0)
        let slots = 1 + slotCount(t)
        return registerMap(d.offsets, sizeBytes: Int32(slots * 8),
                           symbol: Mangle.descriptor("spawnbox", [t], home: homeModule), foldable: true, shaped: d.shaped)
    }

    // The shared type-id for every mailbox object `{ header, mb_head, mb_tail, scheduled, sched_next }`:
    // mb_head (8), mb_tail (16), sched_next (32) are managed pointers (scanned). 40 bytes.
    func mailboxTypeIdValue() -> UInt64 {
        if let id = mailboxTypeId { return id }
        let id = registerMap([8, 16, 32], sizeBytes: 40, symbol: Mangle.descriptor("mailbox", home: homeModule), foldable: true)
        mailboxTypeId = id
        return id
    }

    // The shared type-id for every Array handle `{ header, len, bufptr }` (bufptr at byte 16).
    func arrayHandleTypeId() -> UInt64 {
        if let id = arrayHandleMapId { return id }
        let id = registerMap([16], sizeBytes: 24, symbol: Mangle.descriptor("arrayhandle", home: homeModule), foldable: true)
        arrayHandleMapId = id
        return id
    }

    // The array-buffer type-id for element type `elem`: per-element managed-pointer offsets, repeated
    // `cap` times by the collector. Registered once per element type.
    func arrayBufTypeId(_ elem: Type) -> UInt64 {
        let key = elem.description
        if let id = arrayBufMapIds[key] { return id }
        let d = descriptorEntries(shapes.shape(elem))
        let id = registerArrayMap(d.offsets, stride: Int32(arrayElemStride(elem)),
                                  symbol: Mangle.descriptor("arraybuf", [elem], home: homeModule), foldable: true, shaped: d.shaped)
        arrayBufMapIds[key] = id
        return id
    }

    func arrayElemStride(_ t: Type) -> Int { max(slotCount(t) * 8, 8) }

    // The managed-buffer type-id for `ManagedBuffer<Header, Element>` (task 180): a kind-1 buffer whose
    // header is `Header` (byte size + managed map) and whose elements are `Element` (packed stride +
    // managed map). `headerSize` is `Header`'s value-layout byte size (elements begin at `16 + headerSize`);
    // the header/element managed offsets come from `shape(T)` exactly as the array buffer
    // derives its element map. Element stride is the packed natural size (`rawStride` — `UInt8` → 1, a
    // reference → 8), the footprint-dense model (180's stride decision), distinct from the array buffer's
    // 8-slot `arrayElemStride`. Registered once per `(Header, Element)` pair.
    func managedBufferTypeId(header: Type, element: Type) -> UInt64 {
        let key = header.description + "$" + element.description
        if let id = managedBufferMapIds[key] { return id }
        let headerShape = shapes.shape(header)
        if !headerShape.conditional.isEmpty {
            // A header is scanned once through plain offsets; a shaped header would need its own entry list.
            fail("ManagedBuffer header \(header) holds conditional content (a String or a managed enum), which buffer descriptors do not scan", zeroSpan)
        }
        let headerOffsets = headerShape.managed.map(Int32.init)
        let elem = descriptorEntries(shapes.shape(element))
        let elemOffsets = elem.offsets
        let id = registerBufferMap(headerSize: Int32(slotCount(header) * 8),
                                   headerOffsets: headerOffsets, elementOffsets: elemOffsets,
                                   stride: Int32(rawStride(element)),
                                   symbol: Mangle.descriptor("managedbuffer", [header, element], home: homeModule), foldable: true, shaped: elem.shaped)
        managedBufferMapIds[key] = id
        return id
    }

    // Recover a monomorphized `ManagedBuffer` value's `(Header, Element)` from its type (task 180). The
    // generic args are not structural on the type after monomorphization (the type is the instantiation
    // name), but the specializer records them in `monoTypeArgs` keyed by that name. Returns nil if `t` is
    // not a `ManagedBuffer` instantiation.
    func managedBufferArgs(_ t: Type) -> (header: Type, element: Type)? {
        // The mono'd name carries the `nomu/core` origin once `ManagedBuffer` is a package type (174.5.1),
        // e.g. `nomu/core@ManagedBuffer<EmptyHeader, UInt8>`; strip any `origin@` before the prefix match.
        guard case .named(let n, _) = t, (ExternalName.decode(n)?.name ?? n).hasPrefix("ManagedBuffer<"),
              let args = monoTypeArgs[n], args.count == 2 else { return nil }
        return (args[0], args[1])
    }

    // The value-layout descriptor id for a type used as a generic type argument (task 100.4.7.4 — the
    // VWT `type_id`). Describes the T *value*'s managed-pointer map at offset 0 (no object header), so a
    // collector handed a VWT can scan an erased-T buffer. Distinct from a heap-object descriptor (which
    // has its header at slot 0): the symbol is namespaced `val_<type>` to avoid colliding with it.
    func valueDescId(_ t: Type) -> UInt64 {
        let key = t.description
        if let id = valueDescIds[key] { return id }
        // Carry shaped sub-fields (a `String`, whose `word0` is a conditional managed pointer) into the
        // value-layout descriptor, so a collector handed this VWT scans the shaped content of an erased-T
        // buffer (the `kind 0` + `nshaped` fold the shared enumerator already recurses). Discarding them
        // would leave a `String` inside an erased `T` invisible to the typed-root walk (the erased-generic
        // shaped typed-root gap — `internals/gc-model-upgrade.md`).
        let d = descriptorEntries(shapes.shape(t))
        let id = registerMap(d.offsets, sizeBytes: Int32(slotCount(t) * 8),
                             symbol: Mangle.descriptor("val", [t], home: homeModule), foldable: true, shaped: d.shaped)
        valueDescIds[key] = id
        return id
    }

    // The frame-root shape ordinal for a value recorded in a deopt bundle (task 176.3). The shaped leaves take
    // the first ordinals, in registry order (`String` is 0), and a wrapper takes its leaf's; any other recorded
    // type gets the next ordinal and its descriptor registered, so this object's `__nomu_shape_table` resolves
    // it. The ordinal is a compile-time i32 constant the stackmap can hold; the descriptor's section offset (a
    // link-time value it cannot hold) lives in the table. Ordinals are numbered per object, so they mean
    // something only with their object's table.
    func shapeOrdinal(_ t: Type) -> Int32 {
        if let leaf = shapes.leaf(t) { return Int32(ShapeLeaf.allCases.firstIndex(of: leaf)!) }
        let key = t.description
        if let o = shapeOrdinalForType[key] { return o }
        // An enum value's descriptor is its kind-2 enum descriptor (discriminant-conditional); any other
        // aggregate uses its flat value-layout descriptor (task 176.3a/.3b).
        let desc: UInt64 = {
            if case .named(let n, .enum_) = t, let c = shapes.shape(t).conditional.first,
               case .enumCases(_, let cases) = c.kind {
                return enumShapeDescId(n, cases)
            }
            return valueDescId(t)
        }()
        let ord = Int32(ShapeLeaf.allCases.count + shapeOrdinalDescIds.count)
        shapeOrdinalDescIds.append(desc)
        shapeOrdinalForType[key] = ord
        return ord
    }

    // Emit this object's `__nomu_shape_table` — the ordinal→descriptor-offset table for the shape ordinals
    // in its stackmap records (task 176.3): word 0 is the ordinal count, then one entry per ordinal: the
    // shaped leaves' kind-2 descriptors first (`String` is ordinal 0), then each recorded aggregate's.
    // The entries are link-time offsets from the `__nomu_descs` section start (the `type_id`
    // `nomu_gc_live_offsets` consumes). Local to the object and kept from dead stripping (`llvm.used`): the
    // driver's frame index (task 195) points each object's stackmap records at its own table, found by this
    // name and the object in the link map. Its references also keep the leaf descriptors, which no object
    // header stamps, from being stripped.
    func emitShapeOrdinalTable() {
        var entries: [LLVMValueRef?] = ShapeLeaf.allCases.map { descOffsetHeader(leafShapeId($0)) }
        for d in shapeOrdinalDescIds { entries.append(descOffsetHeader(d)) }
        entries.insert(LLVMConstInt(i64, UInt64(entries.count), 0), at: 0)
        let count = UInt64(entries.count)
        let arrTy = LLVMArrayType2(i64, count)
        let g = LLVMAddGlobal(mod, arrTy, "__nomu_shape_table")!
        LLVMSetInitializer(g, entries.withUnsafeMutableBufferPointer { LLVMConstArray2(i64, $0.baseAddress, count) })
        LLVMSetGlobalConstant(g, 1)
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetAlignment(g, 8)
        var used: [LLVMValueRef?] = [g]
        let usedTy = LLVMArrayType2(i8ptr, 1)
        let u = LLVMAddGlobal(mod, usedTy, "llvm.used")!
        LLVMSetInitializer(u, used.withUnsafeMutableBufferPointer { LLVMConstArray2(i8ptr, $0.baseAddress, 1) })
        LLVMSetLinkage(u, LLVMAppendingLinkage)
        LLVMSetSection(u, "llvm.metadata")
    }

    // The byte stride of a `Ptr<T>` element (task 125): the natural size of a scalar `T`, so raw typed
    // memory is packed C-style — distinct from `arrayElemStride`'s 8-byte enum-slot model. Only the
    // scalar element set (checked in Sema) reaches here.
    func rawStride(_ t: Type) -> Int {
        switch t {
        case .uint8, .bool:                 return 1
        case .int, .uint64, .double, .rawPtr, .ptr:  return 8
        default:                            return 8
        }
    }

    // A shape as descriptor entries: its plain managed offsets, and each conditional sub-value as an
    // `(offset, sub-descriptor id)` pair the shared enumerator recurses into — a leaf's kind-2 descriptor, or an
    // enum's (task 176.5).
    func descriptorEntries(_ s: Shape) -> (offsets: [Int32], shaped: [(offset: Int32, shapeId: UInt64)]) {
        var shaped: [(offset: Int32, shapeId: UInt64)] = []
        for c in s.conditional {
            switch c.kind {
            case .leaf(let leaf):
                shaped.append((Int32(c.offset), leafShapeId(leaf)))
            case .enumCases(let name, let cases):
                shaped.append((Int32(c.offset), enumShapeDescId(name, cases)))
            }
        }
        return (s.managed.map(Int32.init), shaped)
    }

    // The kind-2 descriptor for an enum with managed content in some cases (task 176.3b): tag is the case
    // index at offset 0; each case's entries come from its payload shape (`ShapeCase`, offsets from the enum's
    // start). Memoized by enum name.
    func enumShapeDescId(_ name: String, _ shapeCases: [ShapeCase]) -> UInt64 {
        if let id = enumShapeIds[name] { return id }
        var cases: [(tag: Int32, flat: [Int32], shaped: [(offset: Int32, shapeId: UInt64)])] = []
        for c in shapeCases {
            // A nested enum-in-enum payload would alias the enumerator's recursion scratch; fail-stop rather
            // than scan it unsoundly (task 176.3b — the deferred half).
            if c.shape.conditional.contains(where: { if case .enumCases = $0.kind { return true }; return false }) {
                fail("176.3b: an enum payload that itself contains a managed enum (\(name)) is not yet supported", zeroSpan)
                continue
            }
            let d = descriptorEntries(c.shape)
            cases.append((tag: Int32(c.tag), flat: d.offsets, shaped: d.shaped))
        }
        let id = registerEnumShapedMap(sizeBytes: Int32(slotCount(.named(name, .enum_)) * 8), cases: cases,
                                       symbol: Mangle.descriptor("enum", named: name, home: homeModule), foldable: true)
        enumShapeIds[name] = id
        return id
    }

    // Register an enum kind-2 descriptor (task 176.3b). Tag at offset 0 (the case index, no shift). The map
    // is serialized at `emitDescriptors` (deferred) because a nested shaped sub-entry's id resolves to a
    // link-time section offset; stored structurally in `enumKind2Descs` keyed by the returned id.
    func registerEnumShapedMap(sizeBytes: Int32,
                               cases: [(tag: Int32, flat: [Int32], shaped: [(offset: Int32, shapeId: UInt64)])],
                               symbol: String, foldable: Bool) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append([]); typeSizes.append(sizeBytes); typeKinds.append(2); typeStrides.append(0)
        typeSymbols.append((symbol, foldable)); typeShaped.append([])
        typeHeaderSizes.append(0); typeHeaderMaps.append([])
        enumKind2Descs[id] = (tagOff: 0, tagShift: 0, cases: cases)
        return id
    }

    // 8-slot ABI count of an LLVM type (a pointer/int is one slot; a struct is the sum of its parts).
    func abiSlots(_ t: LLVMTypeRef) -> Int {
        switch LLVMGetTypeKind(t) {
        case LLVMPointerTypeKind, LLVMIntegerTypeKind:
            return 1
        case LLVMStructTypeKind:
            var n = 0
            for i in 0..<LLVMCountStructElementTypes(t) { n += abiSlots(LLVMStructGetTypeAtIndex(t, i)) }
            return n
        default:
            return 1
        }
    }

    // Write the type-id into the object's header (slot 0 at the object base) — the descriptor byte
    // offset (task 100.4.7), a link-time symbol difference.
    func writeTypeIdHeader(_ obj: LLVMValueRef, _ name: String) {
        LLVMBuildStore(b, descOffsetHeader(typeId(forHeapType: name)), obj)
    }

    // Stamp a raw (non-named-type) type-id into an object header — mailbox/message objects.
    func writeTypeIdHeaderRaw(_ obj: LLVMValueRef, _ id: UInt64) {
        LLVMBuildStore(b, descOffsetHeader(id), obj)
    }

    // The fixed-size GC type descriptor `{ i32 size, i32 stride, i32 kind, i32 nptr, i32 ptrmap_off,
    // i32 nshaped, i32 headerSize, i32 nHeaderPtr }` — 32 bytes, so a record's byte offset from the section
    // start divides cleanly to an ordinal. `kind` 0 = fixed, 1 = buffer, 2 = shaped (task 176). `ptrmap_off`
    // is the byte offset of this type's map within the parallel `__nomu_ptrmaps` section (task 100.4.7): a
    // flat managed-offset array for kind 0/1, a serialized discriminant-keyed map for kind 2
    // (`registerShapedMap`). `nshaped` (task 176 Stage 1 site 2) is the count of shaped-field entries that
    // follow the `nptr` direct offsets in the map — each a `(field byte offset, shape descriptor-offset)` i32
    // pair; 0 for the ordinary object (no added per-word work on the hot scan path, 178.1). `headerSize` /
    // `nHeaderPtr` (task 180) generalize the kind-1 buffer to a configurable user header before the elements:
    // the header byte size and the count of managed offsets within it (the blob prefix before the element
    // map); both 0 for an array buffer, which stays the byte-identical special case.
    func gcDescType() -> LLVMTypeRef {
        structTy([i32, i32, i32, i32, i32, i32, i32, i32])
    }

    // A synthetic `section$start$<seg>$<sect>` symbol (ld64 defines it at the section base); declared
    // extern once per module. The `\u{01}` prefix is LLVM's raw-symbol escape, suppressing the Mach-O
    // `_` global prefix so the name matches the linker's synthetic symbol exactly. `sectionOffset`
    // builds the link-time `&g − &start` truncated to i32.
    func sectionStartSym(_ seg: String, _ sect: String) -> LLVMValueRef {
        let name = "\u{01}section$start$\(seg)$\(sect)"
        if let g = LLVMGetNamedGlobal(mod, name) { return g }
        let g = LLVMAddGlobal(mod, i8, name)!
        LLVMSetLinkage(g, LLVMExternalLinkage)
        return g
    }

    func sectionOffset(of g: LLVMValueRef, seg: String, sect: String) -> LLVMValueRef {
        let start = sectionStartSym(seg, sect)
        let diff = LLVMConstSub(LLVMConstPtrToInt(g, i64), LLVMConstPtrToInt(start, i64))
        return LLVMConstTrunc(diff, i32)
    }

    // Get-or-declare a descriptor global by symbol. Header/VWT stamps reference it during body lowering,
    // before `emitDescriptors` (at finalization) fills in its initializer, section, and linkage.
    func descGlobalRef(_ name: String) -> LLVMValueRef {
        if let g = LLVMGetNamedGlobal(mod, name) { return g }
        return LLVMAddGlobal(mod, gcDescType(), name)!
    }

    // The i64 type-id stamped into an object header for a registered type: the link-time byte offset of
    // its descriptor from the `__nomu_descs` section start. Fits the header's low 32 bits (mark = bit 32,
    // forwarded = bit 33 are added later); the high bits are zero at allocation (task 100.4.7).
    func descOffsetHeader(_ id: UInt64) -> LLVMValueRef {
        let g = descGlobalRef(typeSymbols[Int(id)].name)
        let start = sectionStartSym("__DATA", "__nomu_descs")
        return LLVMConstSub(LLVMConstPtrToInt(g, i64), LLVMConstPtrToInt(start, i64))
    }

    // Emit the link-time offset-as-id descriptor section (task 100.4.7). One fixed-size record per heap
    // type into `__DATA,__nomu_descs` (foldable shapes weak so cross-module duplicates collapse; per-site
    // shapes internal), with the variable pointer map out of line in `__DATA,__nomu_ptrmaps`. Every
    // module emits its own; the runtime finds each section base via `getsectiondata` and reads a
    // descriptor at `base + type_id`, where a type-id is the record's byte offset from the section start.
    func emitDescriptors() {
        let descTy = gcDescType()
        var emitted = Set<String>()
        for (i, sym) in typeSymbols.enumerated() {
            guard emitted.insert(sym.name).inserted else { continue }   // fold duplicate shapes within a module
            let offsets = typeMaps[i]
            let shaped = typeShaped[i]
            let header = typeHeaderMaps[i]
            var ptrmapOff = LLVMConstInt(i32, 0, 0)
            if let ek = enumKind2Descs[UInt64(i)] {
                // An enum kind-2 descriptor: serialize its discriminant-keyed, per-case blob here (deferred,
                // task 176.3b), converting nested shaped sub-entry ids to link-time section offsets.
                let pm = emitEnumKind2PtrMap(Mangle.pointerMap(of: sym.name), ek, foldable: sym.foldable)
                ptrmapOff = sectionOffset(of: pm, seg: "__DATA", sect: "__nomu_ptrmaps")
            } else if !offsets.isEmpty || !shaped.isEmpty || !header.isEmpty {
                let pm = emitPtrMap(Mangle.pointerMap(of: sym.name), offsets, header: header, shaped: shaped, foldable: sym.foldable)
                ptrmapOff = sectionOffset(of: pm, seg: "__DATA", sect: "__nomu_ptrmaps")
            }
            let initv = constStruct(descTy, [
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeSizes[i])), 0),
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeStrides[i])), 0),
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeKinds[i])), 0),
                LLVMConstInt(i32, UInt64(offsets.count), 0),
                ptrmapOff,
                LLVMConstInt(i32, UInt64(shaped.count), 0),   // nshaped (task 176 site 2)
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeHeaderSizes[i])), 0),  // headerSize (task 180)
                LLVMConstInt(i32, UInt64(header.count), 0),                            // nHeaderPtr (task 180)
            ])
            let g = descGlobalRef(sym.name)
            LLVMSetInitializer(g, initv)
            LLVMSetGlobalConstant(g, 1)
            LLVMSetSection(g, "__DATA,__nomu_descs")
            LLVMSetAlignment(g, 8)
            LLVMSetLinkage(g, sym.foldable ? LLVMWeakODRLinkage : LLVMInternalLinkage)
        }
    }

    // One type's pointer map, out of line in `__nomu_ptrmaps`: the `nptr` direct managed-offset i32s first
    // (the descriptor's `nptr` gives their count), then `nshaped` shaped-field entries, each a `(field byte
    // offset, shape descriptor-offset)` i32 pair (task 176 Stage 1 site 2). The shape descriptor-offset is a
    // link-time `&shapeDesc − &__nomu_descs` — the same type-id convention a header carries — so the
    // collector hands it straight to the enumerator. Linkage matches the descriptor so the pair folds.
    func emitPtrMap(_ name: String, _ offsets: [Int32],
                    header: [Int32] = [],
                    shaped: [(offset: Int32, shapeId: UInt64)] = [], foldable: Bool) -> LLVMValueRef {
        // Blob layout (task 180): header managed offsets first (the `nHeaderPtr` prefix the element map
        // reads past), then the `nptr` element/direct offsets, then the shaped-field pairs (an object's, or
        // each buffer element's), which the accessors read at `nHeaderPtr + nptr + 2k`.
        var consts: [LLVMValueRef?] = header.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) }
        consts.append(contentsOf: offsets.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) })
        for entry in shaped {
            consts.append(LLVMConstInt(i32, UInt64(bitPattern: Int64(entry.offset)), 0))
            let shapeDesc = descGlobalRef(typeSymbols[Int(entry.shapeId)].name)
            consts.append(sectionOffset(of: shapeDesc, seg: "__DATA", sect: "__nomu_descs"))
        }
        let total = UInt64(consts.count)
        let arrTy = LLVMArrayType2(i32, total)
        let g = LLVMAddGlobal(mod, arrTy, name)!
        let initv = consts.withUnsafeMutableBufferPointer {
            LLVMConstArray2(i32, $0.baseAddress, total)
        }
        LLVMSetInitializer(g, initv)
        LLVMSetGlobalConstant(g, 1)
        LLVMSetSection(g, "__DATA,__nomu_ptrmaps")
        LLVMSetAlignment(g, 4)
        LLVMSetLinkage(g, foldable ? LLVMWeakODRLinkage : LLVMInternalLinkage)
        return g
    }

    // The out-of-line blob for an enum kind-2 descriptor (task 176.3b), serialized as
    // `[tagOff, tagShift, ncases, (tag, nFlat, flat…, nShaped, (off, subSectionOff)…)…]`. A per-case entry
    // carries both flat conditional managed offsets (an `Option<SomeClass>`) and nested shaped sub-entries
    // (an `Option<String>`), each sub-id resolved to a `&shapeDesc − &__nomu_descs` link-time offset — the
    // type-id the enumerator hands back to `nomu_gc_live_offsets` to recurse the payload's sub-shape.
    func emitEnumKind2PtrMap(_ name: String,
                             _ ek: (tagOff: Int32, tagShift: Int32,
                                    cases: [(tag: Int32, flat: [Int32], shaped: [(offset: Int32, shapeId: UInt64)])]),
                             foldable: Bool) -> LLVMValueRef {
        func c32(_ v: Int32) -> LLVMValueRef? { LLVMConstInt(i32, UInt64(bitPattern: Int64(v)), 0) }
        var consts: [LLVMValueRef?] = [c32(ek.tagOff), c32(ek.tagShift), c32(Int32(ek.cases.count))]
        for cse in ek.cases {
            consts.append(c32(cse.tag))
            consts.append(c32(Int32(cse.flat.count)))
            for o in cse.flat { consts.append(c32(o)) }
            consts.append(c32(Int32(cse.shaped.count)))
            for s in cse.shaped {
                consts.append(c32(s.offset))
                let sub = descGlobalRef(typeSymbols[Int(s.shapeId)].name)
                consts.append(sectionOffset(of: sub, seg: "__DATA", sect: "__nomu_descs"))
            }
        }
        let total = UInt64(consts.count)
        let arrTy = LLVMArrayType2(i32, total)
        let g = LLVMAddGlobal(mod, arrTy, name)!
        LLVMSetInitializer(g, consts.withUnsafeMutableBufferPointer { LLVMConstArray2(i32, $0.baseAddress, total) })
        LLVMSetGlobalConstant(g, 1)
        LLVMSetSection(g, "__DATA,__nomu_ptrmaps")
        LLVMSetAlignment(g, 4)
        LLVMSetLinkage(g, foldable ? LLVMWeakODRLinkage : LLVMInternalLinkage)
        return g
    }
}
