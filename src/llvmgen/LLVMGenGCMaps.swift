import noir
import ast
import support
import LLVM_C

// M6 GC pointer-map machinery (moved into the shared emitter, m7-spec.md §7.2.3): assign a type-id +
// managed-field offset map to each heap type (class/actor/closure/`any`-box/array-buffer/mailbox),
// stamp it into an object header, and emit the flat runtime tables at module finalization.
extension LLVMGen {
    // Register a fixed-size object's pointer map (managed-field byte offsets) + total byte size; the
    // returned type-id indexes `typeMaps`/`typeSizes`/`typeKinds`/`typeStrides`.
    func registerMap(_ offsets: [Int32], sizeBytes: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(offsets)
        typeSizes.append(sizeBytes)
        typeKinds.append(0)      // fixed
        typeStrides.append(0)
        return id
    }

    // Register an array-buffer type-id: `elementOffsets` are the managed-pointer byte offsets within
    // one element, `stride` its byte size (total size comes from `cap`/`len` at run time).
    func registerArrayMap(_ elementOffsets: [Int32], stride: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // array
        typeStrides.append(stride)
        return id
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
        let id = registerMap(offsets, sizeBytes: Int32(totalSlots * 8))
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
        return registerMap(offsets, sizeBytes: Int32(slot * 8))
    }

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only.
    func anyBoxTypeId() -> UInt64 {
        if let id = anyBoxMapId { return id }
        let id = registerMap([16], sizeBytes: 24)
        anyBoxMapId = id
        return id
    }

    // The shared type-id for every mailbox object `{ header, mb_head, mb_tail, scheduled, sched_next }`:
    // mb_head (8), mb_tail (16), sched_next (32) are managed pointers (scanned). 40 bytes.
    func mailboxTypeIdValue() -> UInt64 {
        if let id = mailboxTypeId { return id }
        let id = registerMap([8, 16, 32], sizeBytes: 40)
        mailboxTypeId = id
        return id
    }

    // The shared type-id for every Array handle `{ header, len, bufptr }` (bufptr at byte 16).
    func arrayHandleTypeId() -> UInt64 {
        if let id = arrayHandleMapId { return id }
        let id = registerMap([16], sizeBytes: 24)
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
        let id = registerArrayMap(elemOffsets, stride: Int32(arrayElemStride(elem)))
        arrayBufMapIds[key] = id
        return id
    }

    func arrayElemStride(_ t: Type) -> Int { max(slotCount(t) * 8, 8) }

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

    // Write the type-id into the object's header (slot 0 at the object base).
    func writeTypeIdHeader(_ obj: LLVMValueRef, _ name: String) {
        LLVMBuildStore(b, LLVMConstInt(i64, typeId(forHeapType: name), 0), obj)
    }

    // Stamp a raw (non-named-type) type-id into an object header — mailbox/message objects.
    func writeTypeIdHeaderRaw(_ obj: LLVMValueRef, _ id: UInt64) {
        LLVMBuildStore(b, LLVMConstInt(i64, id, 0), obj)
    }

    // Emit the flat pointer-map tables the runtime reads. Always emitted so runtime.c's externs
    // resolve even with no heap types.
    func emitTypeMaps() {
        var data: [Int32] = []
        var index: [Int32] = []
        for map in typeMaps {
            index.append(Int32(data.count))
            data.append(Int32(map.count))
            data.append(contentsOf: map)
        }
        emitI32Array("nomu_gc_typemap_data", data.isEmpty ? [0] : data)
        emitI32Array("nomu_gc_typemap_index", index.isEmpty ? [0] : index)
        emitI32Array("nomu_gc_typemap_sizes", typeSizes.isEmpty ? [0] : typeSizes)
        emitI32Array("nomu_gc_typemap_kind", typeKinds.isEmpty ? [0] : typeKinds)
        emitI32Array("nomu_gc_typemap_stride", typeStrides.isEmpty ? [0] : typeStrides)
        let g = LLVMAddGlobal(mod, i64, "nomu_gc_typemap_count")!
        LLVMSetInitializer(g, LLVMConstInt(i64, UInt64(typeMaps.count), 0))
        LLVMSetGlobalConstant(g, 1)
    }

    func emitI32Array(_ name: String, _ vals: [Int32]) {
        var consts: [LLVMValueRef?] = vals.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) }
        let g = LLVMAddGlobal(mod, LLVMArrayType2(i32, UInt64(vals.count)), name)!
        let initv = consts.withUnsafeMutableBufferPointer {
            LLVMConstArray2(i32, $0.baseAddress, UInt64(vals.count))
        }
        LLVMSetInitializer(g, initv)
        LLVMSetGlobalConstant(g, 1)
    }
}
