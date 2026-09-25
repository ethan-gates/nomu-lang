import noir
import ast
import support
import LLVM_C

// Value-witness tables (task 100.4.3.2; ABI in internals/backend.md §4). A VWT is per-concrete-type
// metadata an erased generic body reads to size, scan, copy, move, and destroy an opaque `T` value it
// holds by buffer. Layout: `{ i32 size, i32 align, i32 type_id, i32 flags, ptr copy, ptr move, ptr
// destroy }` — the four i32s pack into two words ahead of the naturally-aligned pointers.
//
// Under the tracing GC (no refcount, no value-type deterministic teardown; memory-model.md) `copy` /
// `move` are `memcpy` and `destroy` a no-op for a type with no owned resources, so such a type sets the
// trivial (POD) flag and leaves the three function pointers null — the erased path (100.4.3.3) inlines
// `memcpy` and skips `destroy` on the flag. `type_id` is filled by cross-module type-id unification
// (100.4.7.4); it is a placeholder here, so a non-POD `T`'s GC scan is not yet wired (100.4.3.6 / 100.4.7).
extension LLVMGen {
    // VWT flag bits.
    static let vwtFlagPOD: UInt64 = 1   // trivial: memcpy copy/move, no-op destroy, no GC scan needed

    // The shared VWT struct type.
    func valueWitnessType() -> LLVMTypeRef {
        if let t = valueWitnessTy { return t }
        let st = LLVMStructCreateNamed(ctx, "vwt")!
        setStructBody(st, [i32, i32, i32, i32, i8ptr, i8ptr, i8ptr])
        valueWitnessTy = st
        return st
    }

    // The VWT global for a concrete type, built on demand and cached (mirrors `witnessInstance`). An
    // internal constant so link folds duplicates across a module and dead-strips it when unreferenced.
    // `size`/`align` size a `T` buffer; the POD flag records whether `T` holds managed pointers (so the
    // erased path knows a `memcpy` copy/move + no-op destroy is sound).
    @discardableResult
    func valueWitness(_ t: Type) -> LLVMValueRef {
        let key = t.description
        if let g = valueWitnessGlobals[key] { return g }
        let sizeBytes = Int32(slotCount(t) * 8)          // value layout is the uniform 8-byte-slot model
        let align = Int32(8)
        var offsets: [Int32] = []
        collectManagedOffsets(t, baseSlot: 0, into: &offsets)
        let flags = offsets.isEmpty ? LLVMGen.vwtFlagPOD : 0
        // The `type_id` is the value-layout GC descriptor's section offset (100.4.7.4), so a collector
        // handed this VWT reaches the T value's pointer map to scan an erased-T buffer.
        let typeIdVal = sectionOffset(of: descGlobalRef(typeSymbols[Int(valueDescId(t))].name),
                                      seg: "__DATA", sect: "__nomu_descs")

        let vwt = valueWitnessType()
        let g = LLVMAddGlobal(mod, vwt, "vwt_\(key)")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        valueWitnessGlobals[key] = g
        let vals: [LLVMValueRef?] = [
            LLVMConstInt(i32, UInt64(bitPattern: Int64(sizeBytes)), 0),
            LLVMConstInt(i32, UInt64(bitPattern: Int64(align)), 0),
            typeIdVal,
            LLVMConstInt(i32, flags, 0),
            LLVMConstPointerNull(i8ptr),   // copy   — null ⇒ memcpy (POD); a thunk when non-trivial (deferred)
            LLVMConstPointerNull(i8ptr),   // move   — null ⇒ memcpy
            LLVMConstPointerNull(i8ptr),   // destroy — null ⇒ no-op
        ]
        LLVMSetInitializer(g, constStruct(vwt, vals))
        return g
    }
}
