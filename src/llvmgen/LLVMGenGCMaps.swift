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
    func registerMap(_ offsets: [Int32], sizeBytes: Int32, symbol: String, foldable: Bool) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(offsets)
        typeSizes.append(sizeBytes)
        typeKinds.append(0)      // fixed
        typeStrides.append(0)
        typeSymbols.append((symbol, foldable))
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
        var slot = 1   // header occupies slot 0; fields (and the actor's trailing mailbox) follow
        for ft in fieldTypes {
            collectManagedOffsets(ft, baseSlot: slot, into: &offsets)
            slot += slotCount(ft)
        }
        if isActor { offsets.append(Int32(slot * 8)) }   // trailing mailbox pointer is scanned
        let totalSlots = slot + (isActor ? 1 : 0)
        let id = registerMap(offsets, sizeBytes: Int32(totalSlots * 8),
                             symbol: descSymbol(name), foldable: true)
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

    // The value-layout descriptor id for a type used as a generic type argument (task 100.4.7.4 — the
    // VWT `type_id`). Describes the T *value*'s managed-pointer map at offset 0 (no object header), so a
    // collector handed a VWT can scan an erased-T buffer. Distinct from a heap-object descriptor (which
    // has its header at slot 0): the symbol is namespaced `val_<type>` to avoid colliding with it.
    func valueDescId(_ t: Type) -> UInt64 {
        let key = t.description
        if let id = valueDescIds[key] { return id }
        var offsets: [Int32] = []
        collectManagedOffsets(t, baseSlot: 0, into: &offsets)
        let id = registerMap(offsets, sizeBytes: Int32(slotCount(t) * 8),
                             symbol: descSymbol("val_\(key)"), foldable: true)
        valueDescIds[key] = id
        return id
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

    // Append the byte offsets of managed (`p1`) pointers within a field of type `t` laid out starting
    // at `baseSlot`. Recurses into inline value structs; String's buffer is runtime-owned (addr0) so
    // it is skipped, and enum payloads carry no references in the language today.
    func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32]) {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            offsets.append(Int32(baseSlot * 8))
        case .named(let n, .struct_):
            var s = baseSlot
            for sf in (structMap[n]?.fields ?? []) {
                collectManagedOffsets(sf.type, baseSlot: s, into: &offsets)
                s += slotCount(sf.type)
            }
        case .opaque:
            collectManagedOffsets(concreteUnderlying(t), baseSlot: baseSlot, into: &offsets)
        default:
            break   // int, bool, string, enum payload
        }
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
    // i32 pad }` — 24 bytes, so a record's byte offset from the section start divides cleanly to an
    // ordinal. `ptrmap_off` is the byte offset of this type's managed-offset array within the parallel
    // `__nomu_ptrmaps` section (task 100.4.7).
    func gcDescType() -> LLVMTypeRef {
        structTy([i32, i32, i32, i32, i32, i32])
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
            var ptrmapOff = LLVMConstInt(i32, 0, 0)
            if !offsets.isEmpty {
                let pm = emitPtrMap(sym.name + "__ptrmap", offsets, foldable: sym.foldable)
                ptrmapOff = sectionOffset(of: pm, seg: "__DATA", sect: "__nomu_ptrmaps")
            }
            let initv = constStruct(descTy, [
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeSizes[i])), 0),
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeStrides[i])), 0),
                LLVMConstInt(i32, UInt64(bitPattern: Int64(typeKinds[i])), 0),
                LLVMConstInt(i32, UInt64(offsets.count), 0),
                ptrmapOff,
                LLVMConstInt(i32, 0, 0),
            ])
            let g = descGlobalRef(sym.name)
            LLVMSetInitializer(g, initv)
            LLVMSetGlobalConstant(g, 1)
            LLVMSetSection(g, "__DATA,__nomu_descs")
            LLVMSetAlignment(g, 8)
            LLVMSetLinkage(g, sym.foldable ? LLVMWeakODRLinkage : LLVMInternalLinkage)
        }
    }

    // One type's managed-offset array, out of line in `__nomu_ptrmaps`; the descriptor's `nptr` gives the
    // length, so no count prefix. Linkage matches the descriptor so the pair folds together.
    func emitPtrMap(_ name: String, _ offsets: [Int32], foldable: Bool) -> LLVMValueRef {
        var consts: [LLVMValueRef?] = offsets.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) }
        let arrTy = LLVMArrayType2(i32, UInt64(offsets.count))
        let g = LLVMAddGlobal(mod, arrTy, name)!
        let initv = consts.withUnsafeMutableBufferPointer {
            LLVMConstArray2(i32, $0.baseAddress, UInt64(offsets.count))
        }
        LLVMSetInitializer(g, initv)
        LLVMSetGlobalConstant(g, 1)
        LLVMSetSection(g, "__DATA,__nomu_ptrmaps")
        LLVMSetAlignment(g, 4)
        LLVMSetLinkage(g, foldable ? LLVMWeakODRLinkage : LLVMInternalLinkage)
        return g
    }
}
