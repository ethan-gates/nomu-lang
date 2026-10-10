import noir
import ast
import support
import LLVM_C

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
    func registerArrayMap(_ elementOffsets: [Int32], stride: Int32, symbol: String, foldable: Bool) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // array
        typeStrides.append(stride)
        typeSymbols.append((symbol, foldable))
        typeShaped.append([])    // array-element shaped fields are a later cut (step 5 / 176.2)
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
                           stride: Int32, symbol: String, foldable: Bool) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // buffer (kind 1, generalized with a header)
        typeStrides.append(stride)
        typeSymbols.append((symbol, foldable))
        typeShaped.append([])
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

    // A descriptor symbol from a type/shape key: `nomu_gc_desc_<key>`, non-identifier chars replaced so
    // the linker can fold on the name. Foldable descriptors (named types, shared singletons, array
    // buffers) share this name across modules; per-site shapes (closures) get `foldable: false` and a
    // uniquified key so they never collide (task 100.4.7).
    func descSymbol(_ key: String) -> String {
        var s = "nomu_gc_desc_"
        for ch in key {
            switch ch {
            case "<", ">", ",", " ", ".", "-", "&", "|", ":", "(", ")", "[", "]":
                s.append("_")
            default:
                s.append(ch)
            }
        }
        return s
    }

    // Type-id for a class/actor heap type; assigns one (and computes its pointer map) on first use.
    func typeId(forHeapType name: String) -> UInt64 {
        if let id = typeIds[name] { return id }
        let fieldTypes: [Type] = classMap[name].map { $0.fields.map(\.type) }
            ?? actorMap[name].map { $0.fields.map(\.type) } ?? []
        let isActor = actorMap[name] != nil
        var offsets: [Int32] = []
        var shaped: [(offset: Int32, shapeId: UInt64)] = []
        var slot = 1   // header occupies slot 0; fields (and the actor's trailing mailbox) follow
        for ft in fieldTypes {
            collectManagedOffsets(ft, baseSlot: slot, into: &offsets, shaped: &shaped)
            slot += slotCount(ft)
        }
        if isActor { offsets.append(Int32(slot * 8)) }   // trailing mailbox pointer is scanned
        let totalSlots = slot + (isActor ? 1 : 0)
        let id = registerMap(offsets, sizeBytes: Int32(totalSlots * 8),
                             symbol: descSymbol(name), foldable: true, shaped: shaped)
        typeIds[name] = id
        return id
    }

    // Type-id for a fused closure object `{ header, fn, caps… }`: managed captures (scalar `p1`) are
    // scanned, `fn` (addr0) is skipped. Each closure site is its own shape, so a fresh map per closure.
    func closureTypeId(_ caps: [Capture]) -> UInt64 {
        var offsets: [Int32] = []
        var slot = 2   // header(0) + fn(1); captures follow
        for cap in caps {
            if cap.local.ty == p1 { offsets.append(Int32(slot * 8)) }
            slot += abiSlots(cap.local.ty)
        }
        // Each closure site is a distinct shape; a uniquified local symbol never folds across modules.
        return registerMap(offsets, sizeBytes: Int32(slot * 8),
                           symbol: descSymbol("closure_\(typeMaps.count)"), foldable: false)
    }

    // The shared shaped descriptor for every `String` value (task 121 / 176): a 16-byte bit-stealing
    // `{ i64 word0, i64 word1 }` whose `word0` is a managed buffer pointer only in the `heap` case. The
    // discriminant is the top nibble of `word1` (`tagOff 8, tagShift 60`): `small = 0`, `immortal = 1`,
    // `heap = 2`. Only `heap` carries a managed, relocatable pointer (at offset 0); `small` holds inline
    // bytes and `immortal` points at never-moved immortal space, so both contribute no managed offset.
    func stringShapeId() -> UInt64 {
        if let id = stringShapeMapId { return id }
        let id = registerShapedMap(tagOff: 8, tagShift: 60, sizeBytes: 16,
                                   cases: [(tag: 2, offsets: [0])],
                                   symbol: descSymbol("string"), foldable: true)
        stringShapeMapId = id
        return id
    }

    // The type-id for the heap `String` byte buffer: a `ManagedBuffer<EmptyHeader, UInt8>` (task 180.4) —
    // `headerSize = 0`, stride 1 (byte elements), no managed pointers in the element (a GC leaf). `cap`
    // (byte count) at offset 8 sizes it for copy/scan, the bytes follow at offset 16. A `heap` String's
    // `word0` points at this object's base; the collector relocates it like any managed buffer. Concat
    // (lowered in `EgressBuiltins`) stamps this type-id — read from the compiler-emitted
    // `__nomu_stringstorage_typeid` global — into the storage header. Routing through `managedBufferTypeId`
    // collapses the former ad-hoc `stringstorage` descriptor onto the shared buffer-descriptor path; the
    // layout is byte-identical, so the C floor (`rt_str_fill` / concat) is unchanged. 121 later re-keys the
    // header from `EmptyHeader` to a `StringHeader` carrying the isASCII / scalar-count cache.
    func stringStorageTypeId() -> UInt64 {
        if let id = stringStorageMapId { return id }
        let id = managedBufferTypeId(header: .named("EmptyHeader", .struct_), element: .uint8)
        stringStorageMapId = id
        return id
    }

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only.
    func anyBoxTypeId() -> UInt64 {
        if let id = anyBoxMapId { return id }
        let id = registerMap([16], sizeBytes: 24, symbol: descSymbol("anybox"), foldable: true)
        anyBoxMapId = id
        return id
    }

    // Type-id for a spawn-result box `{ header, result… }` (150.3.13). A completed fiber's result rides in a
    // heap box at fib+216 until the joiner reads it; the self-hosted STW walk roots that slot, so the box must
    // be a proper GC object the moving collector can relocate — a header plus the result's managed-pointer map
    // (shifted past slot 0). A managed result is scanned so it survives + is fixed up too. One shape per result
    // type; the set is small, so a fresh map per call is fine.
    func spawnBoxTypeId(_ t: Type) -> UInt64 {
        var offsets: [Int32] = []
        collectManagedOffsets(t, baseSlot: 1, into: &offsets)   // result at slot 1 (header is slot 0)
        let slots = 1 + slotCount(t)
        return registerMap(offsets, sizeBytes: Int32(slots * 8),
                           symbol: descSymbol("spawnbox_\(t.description)"), foldable: true)
    }

    // The shared type-id for every mailbox object `{ header, mb_head, mb_tail, scheduled, sched_next }`:
    // mb_head (8), mb_tail (16), sched_next (32) are managed pointers (scanned). 40 bytes.
    func mailboxTypeIdValue() -> UInt64 {
        if let id = mailboxTypeId { return id }
        let id = registerMap([8, 16, 32], sizeBytes: 40, symbol: descSymbol("mailbox"), foldable: true)
        mailboxTypeId = id
        return id
    }

    // The shared type-id for every Array handle `{ header, len, bufptr }` (bufptr at byte 16).
    func arrayHandleTypeId() -> UInt64 {
        if let id = arrayHandleMapId { return id }
        let id = registerMap([16], sizeBytes: 24, symbol: descSymbol("arrayhandle"), foldable: true)
        arrayHandleMapId = id
        return id
    }

    // The array-buffer type-id for element type `elem`: per-element managed-pointer offsets, repeated
    // `cap` times by the collector. Registered once per element type.
    func arrayBufTypeId(_ elem: Type) -> UInt64 {
        let key = elem.description
        if let id = arrayBufMapIds[key] { return id }
        var elemOffsets: [Int32] = []
        collectManagedOffsets(elem, baseSlot: 0, into: &elemOffsets)
        let id = registerArrayMap(elemOffsets, stride: Int32(arrayElemStride(elem)),
                                  symbol: descSymbol("arraybuf_\(key)"), foldable: true)
        arrayBufMapIds[key] = id
        return id
    }

    func arrayElemStride(_ t: Type) -> Int { max(slotCount(t) * 8, 8) }

    // The managed-buffer type-id for `ManagedBuffer<Header, Element>` (task 180): a kind-1 buffer whose
    // header is `Header` (byte size + managed map) and whose elements are `Element` (packed stride +
    // managed map). `headerSize` is `Header`'s value-layout byte size (elements begin at `16 + headerSize`);
    // the header/element managed offsets come from `collectManagedOffsets` exactly as the array buffer
    // derives its element map. Element stride is the packed natural size (`rawStride` — `UInt8` → 1, a
    // reference → 8), the footprint-dense model (180's stride decision), distinct from the array buffer's
    // 8-slot `arrayElemStride`. Registered once per `(Header, Element)` pair.
    func managedBufferTypeId(header: Type, element: Type) -> UInt64 {
        let key = header.description + "$" + element.description
        if let id = managedBufferMapIds[key] { return id }
        var headerOffsets: [Int32] = []
        collectManagedOffsets(header, baseSlot: 0, into: &headerOffsets)
        var elemOffsets: [Int32] = []
        collectManagedOffsets(element, baseSlot: 0, into: &elemOffsets)
        let id = registerBufferMap(headerSize: Int32(slotCount(header) * 8),
                                   headerOffsets: headerOffsets, elementOffsets: elemOffsets,
                                   stride: Int32(rawStride(element)),
                                   symbol: descSymbol("managedbuffer_\(key)"), foldable: true)
        managedBufferMapIds[key] = id
        return id
    }

    // Recover a monomorphized `ManagedBuffer` value's `(Header, Element)` from its type (task 180). The
    // generic args are not structural on the type after monomorphization (the type is the instantiation
    // name), but the specializer records them in `monoTypeArgs` keyed by that name. Returns nil if `t` is
    // not a `ManagedBuffer` instantiation.
    func managedBufferArgs(_ t: Type) -> (header: Type, element: Type)? {
        guard case .named(let n, _) = t, n.hasPrefix("ManagedBuffer<"),
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
        var offsets: [Int32] = []
        var shaped: [(offset: Int32, shapeId: UInt64)] = []
        collectManagedOffsets(t, baseSlot: 0, into: &offsets, shaped: &shaped)
        let id = registerMap(offsets, sizeBytes: Int32(slotCount(t) * 8),
                             symbol: descSymbol("val_\(key)"), foldable: true, shaped: shaped)
        valueDescIds[key] = id
        return id
    }

    // The frame-root shape ordinal for a value recorded in a deopt bundle (task 176.3). String is ordinal 0
    // (its kind-2 descriptor); a shaped-containing value aggregate gets the next ordinal and its value-layout
    // descriptor registered, so `__nomu_shape_table[ordinal]` resolves to it. The ordinal is a compile-time
    // i32 constant the stackmap can hold; the descriptor's section offset (a link-time value it cannot hold)
    // lives in the table.
    func shapeOrdinal(_ t: Type) -> Int32 {
        if case .string = t { return 0 }
        let key = t.description
        if let o = shapeOrdinalForType[key] { return o }
        // An enum value's shape is its kind-2 descriptor (discriminant-conditional); any other aggregate uses
        // its flat value-layout descriptor (task 176.3a/.3b).
        let desc: UInt64 = { if case .named(_, .enum_) = t { return enumShapeDescId(t) } else { return valueDescId(t) } }()
        shapeOrdinalDescIds.append(desc)
        let ord = Int32(shapeOrdinalDescIds.count)   // 1-based; ordinal i resolves to shapeOrdinalDescIds[i-1]
        shapeOrdinalForType[key] = ord
        return ord
    }

    // Emit `__nomu_shape_table` — the ordinal→descriptor-offset table both walkers read through
    // `nomu_shape_desc_for_ordinal` (task 176.3). Entry 0 is the String kind-2 descriptor; entry i>0 is the
    // i-th recorded aggregate's value-layout descriptor. The entries are link-time offsets from the
    // `__nomu_descs` section start (the `type_id` `nomu_gc_live_offsets` consumes). One table per compilation
    // (whole-program mono); cross-module ordinal unification is deferred with the erased-shaped path.
    func emitShapeOrdinalTable() {
        var entries: [LLVMValueRef?] = [descOffsetHeader(stringShapeId())]
        for d in shapeOrdinalDescIds { entries.append(descOffsetHeader(d)) }
        let count = UInt64(entries.count)
        let arrTy = LLVMArrayType2(i64, count)
        let g = LLVMGetNamedGlobal(mod, "__nomu_shape_table") ?? LLVMAddGlobal(mod, arrTy, "__nomu_shape_table")!
        LLVMSetInitializer(g, entries.withUnsafeMutableBufferPointer { LLVMConstArray2(i64, $0.baseAddress, count) })
        LLVMSetGlobalConstant(g, 1)
        LLVMSetLinkage(g, LLVMWeakODRLinkage)
        let cg = LLVMGetNamedGlobal(mod, "__nomu_shape_table_count") ?? LLVMAddGlobal(mod, i64, "__nomu_shape_table_count")!
        LLVMSetInitializer(cg, LLVMConstInt(i64, UInt64(entries.count), 0))
        LLVMSetGlobalConstant(cg, 1)
        LLVMSetLinkage(cg, LLVMWeakODRLinkage)
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

    // Append the byte offsets of managed (`p1`) pointers within a field of type `t` laid out starting at
    // `baseSlot`, and the byte offsets of *shaped* fields (a `String`, or an `enum` whose payload is managed
    // only in some cases) into `shaped` with their sub-shape's type-id. Recurses into inline value structs.
    // A `String` field becomes a shaped entry the collector recurses into (task 176 Stage 1 site 2); an enum
    // field with conditional managed content becomes a nested kind-2 shaped entry (task 176.3b).
    func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32],
                               shaped: inout [(offset: Int32, shapeId: UInt64)]) {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            offsets.append(Int32(baseSlot * 8))
        case .string:
            shaped.append((Int32(baseSlot * 8), stringShapeId()))
        case .named(let n, .struct_):
            var s = baseSlot
            for sf in (structMap[n]?.fields ?? []) {
                collectManagedOffsets(sf.type, baseSlot: s, into: &offsets, shaped: &shaped)
                s += slotCount(sf.type)
            }
        case .named(let n, .enum_):
            guard enumHasManagedOrShaped(t) else { break }   // a plain-data enum carries nothing
            // A nested enum-in-enum payload would alias the enumerator's recursion scratch; fail-stop rather
            // than scan it unsoundly (task 176.3b — the deferred half).
            if !enumShapeInProgress.isEmpty {
                fail("176.3b: an enum payload that itself contains a managed enum (\(n)) is not yet supported", zeroSpan)
                break
            }
            shaped.append((Int32(baseSlot * 8), enumShapeDescId(t)))
        case .opaque:
            collectManagedOffsets(concreteUnderlying(t), baseSlot: baseSlot, into: &offsets, shaped: &shaped)
        default:
            break   // int, bool
        }
    }

    // Whether a type transitively carries a managed pointer or shaped value — used to decide if an enum case
    // (or an enum field) contributes to a descriptor. Pure predicate (builds no descriptor), so it is safe to
    // call while a descriptor is mid-construction. A value graph can only recurse through a reference (which
    // short-circuits to `true`), so the recursion is bounded.
    func enumHasManagedOrShaped(_ t: Type) -> Bool {
        switch t {
        case .string, .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            return true
        case .named(let n, .struct_):
            return (structMap[n]?.fields ?? []).contains { enumHasManagedOrShaped($0.type) }
        case .named(let n, .enum_):
            return (enumMap[n]?.cases ?? []).contains { $0.fields.contains { enumHasManagedOrShaped($0.type) } }
        case .opaque:
            return enumHasManagedOrShaped(concreteUnderlying(t))
        default:
            return false
        }
    }

    // The kind-2 shaped descriptor for an `enum` whose payload is managed/shaped only in some cases (task
    // 176.3b). Tag is the case index at offset 0; each case's managed/shaped entries come from
    // `collectManagedOffsets` over its payload fields (payload starts at slot 1, past the tag word). Memoized.
    func enumShapeDescId(_ t: Type) -> UInt64 {
        guard case .named(let name, .enum_) = t, let en = enumMap[name] else { return stringShapeId() }
        if let id = enumShapeIds[name] { return id }
        enumShapeInProgress.insert(name)
        defer { enumShapeInProgress.remove(name) }
        var cases: [(tag: Int32, flat: [Int32], shaped: [(offset: Int32, shapeId: UInt64)])] = []
        for (ci, c) in en.cases.enumerated() {
            var flat: [Int32] = []
            var shaped: [(offset: Int32, shapeId: UInt64)] = []
            var slot = 1   // the tag word is slot 0; the payload begins at slot 1
            for f in c.fields {
                collectManagedOffsets(f.type, baseSlot: slot, into: &flat, shaped: &shaped)
                slot += slotCount(f.type)
            }
            if !flat.isEmpty || !shaped.isEmpty { cases.append((tag: Int32(ci), flat: flat, shaped: shaped)) }
        }
        let id = registerEnumShapedMap(sizeBytes: Int32(slotCount(t) * 8), cases: cases,
                                       symbol: descSymbol("enum_\(name)"), foldable: true)
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

    // Overload for callers that do not yet consume shaped fields (array buffers, value-layout descriptors):
    // collect only the direct managed offsets, discarding shaped entries. A shaped value inside these
    // aggregates is a later cut (step 5 / 176.2).
    func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32]) {
        var discard: [(offset: Int32, shapeId: UInt64)] = []
        collectManagedOffsets(t, baseSlot: baseSlot, into: &offsets, shaped: &discard)
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
                let pm = emitEnumKind2PtrMap(sym.name + "__ptrmap", ek, foldable: sym.foldable)
                ptrmapOff = sectionOffset(of: pm, seg: "__DATA", sect: "__nomu_ptrmaps")
            } else if !offsets.isEmpty || !shaped.isEmpty || !header.isEmpty {
                let pm = emitPtrMap(sym.name + "__ptrmap", offsets, header: header, shaped: shaped, foldable: sym.foldable)
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
        // reads past), then the `nptr` element/direct offsets, then the shaped-field pairs. Header and
        // shaped never coexist (a buffer has no shaped fields; an object has no header), so the shaped
        // accessors reading at `nptr + 2k` stay correct.
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
