import noir
import ast
import support
import ssair
import LLVM_C

// Value-witness tables (task 100.4.3.2; ABI in internals/backend.md §4). A VWT is per-concrete-type
// metadata an erased generic body reads to size, scan, copy, move, and destroy an opaque `T` value it
// holds by buffer. Layout: `{ i32 size, i32 align, i32 type_id, i32 flags, ptr copy, ptr move, ptr
// destroy, i32 xi_count, i32 xi_offset, i32 xi_first, i32 xi_width_shift }` — the first four i32s pack into
// two words ahead of the naturally-aligned pointers. The last four describe the type's extra inhabitants
// (`ExtraInhabitants`): how many, the byte offset of the integer holding them, its first unused
// value, and its width in bytes with the shift above it (`width | shift << 8`); a count of 0 means none. An
// erased body lays out an enum over a `T` payload from them, as the static layout does.
//
// Under the tracing GC (no refcount, no value-type deterministic teardown; memory-model.md) `copy` /
// `move` are `memcpy` and `destroy` a no-op for a type with no owned resources, so such a type sets the
// trivial (POD) flag and leaves the three function pointers null — the erased path (100.4.3.3) inlines
// `memcpy` and skips `destroy` on the flag. `type_id` is filled by cross-module type-id unification
// (100.4.7.4); it is a placeholder here, so a non-POD `T`'s GC scan is not yet wired (100.4.3.6 / 100.4.7).
extension LLVMGen {
    // VWT flag bits.
    static let vwtFlagPOD: UInt64 = 1   // trivial: memcpy copy/move, no-op destroy, no GC scan needed

    // A dictionary's word `i`. A dictionary is a constant.
    func loadDictionaryWord(_ dict: LLVMValueRef, _ i: Int) -> LLVMValueRef {
        var off = LLVMConstInt(i64, UInt64(i * 8), 0)
        let addr = LLVMBuildGEP2(b, i8, dict, &off, 1, "dict.word")!
        let word = LLVMBuildLoad2(b, i8ptr, addr, "dict.value")!
        markInvariantLoad(word)
        return word
    }

    // Byte offset of a VWT's extra-inhabitant fields, past the three pointers.
    static let vwtExtraInhabitantsOffset = 40

    // A VWT's extra inhabitants, each widened to `i64`: count, offset, first unused value, width, shift.
    func loadVWTExtraInhabitants(_ vwt: LLVMValueRef) -> (count: LLVMValueRef, offset: LLVMValueRef,
                                                          first: LLVMValueRef, width: LLVMValueRef, shift: LLVMValueRef) {
        func field(_ k: Int, _ name: String) -> LLVMValueRef {
            var off = LLVMConstInt(i64, UInt64(LLVMGen.vwtExtraInhabitantsOffset + 4 * k), 0)
            let addr = LLVMBuildGEP2(b, i8, vwt, &off, 1, "vwt.\(name).addr")!
            let v = LLVMBuildLoad2(b, i32, addr, "vwt.\(name)")!
            markInvariantLoad(v)
            return LLVMBuildZExt(b, v, i64, name)!
        }
        let ws = field(3, "xiws")
        return (field(0, "xicount"), field(1, "xioff"), field(2, "xifirst"),
                LLVMBuildAnd(b, ws, LLVMConstInt(i64, 0xff, 0), "xiwidth")!,
                LLVMBuildLShr(b, ws, LLVMConstInt(i64, 8, 0), "xishift")!)
    }

    // A VWT's `align` (its second `i32`), widened to `i64`.
    func loadVWTAlign(_ vwt: LLVMValueRef) -> LLVMValueRef {
        var off = LLVMConstInt(i64, 4, 0)
        let addr = LLVMBuildGEP2(b, i8, vwt, &off, 1, "vwt.align.addr")!
        let a = LLVMBuildLoad2(b, i32, addr, "vwt.align")!
        markInvariantLoad(a)
        return LLVMBuildZExt(b, a, i64, "align")!
    }

    // The constant dictionary `key` names. It may reach itself, through a recursive generic, so the global exists
    // before its words are built. Each type argument's words come first, then the bounds' tables, then the needs.
    func dictionary(_ key: String) -> LLVMValueRef? {
        if let g = dictionaryGlobals[key] { return g }
        guard let d = dictionaries[key] else { return nil }
        let count = d.typeArgs.count * 2 + d.bounds.reduce(0) { $0 + $1.count } + d.needs.count
        let ty = LLVMArrayType2(i8ptr, UInt64(count))!
        let g = LLVMAddGlobal(mod, ty, "dict.\(dictionaryGlobals.count)")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        dictionaryGlobals[key] = g

        var words: [LLVMValueRef?] = []
        for t in d.typeArgs {
            words.append(valueWitness(t))
            words.append(LLVMConstIntToPtr(LLVMConstInt(i64, UInt64(sizeOf(t)), 0), i8ptr))
        }
        for (i, bounds) in d.bounds.enumerated() {
            for iface in bounds {
                guard case .named(let name, _) = d.typeArgs[i], let w = witnessInstanceErased(name, iface) else { return nil }
                words.append(w)
            }
        }
        for need in d.needs {
            switch need {
            case .dictionary(let callee):
                guard let w = dictionary(callee) else { return nil }
                words.append(w)
            case .object(let t):
                guard case .named(let name, _) = t else { return nil }
                if let (header, element) = managedBufferArgs(t) {   // a channel's buffer: a buffer descriptor
                    words.append(LLVMConstIntToPtr(descOffsetHeader(managedBufferTypeId(header: header, element: element)), i8ptr))
                } else {
                    words.append(LLVMConstIntToPtr(descOffsetHeader(typeId(forHeapType: name)), i8ptr))
                }
            case .arrayBuffer, .box:
                words.append(LLVMConstNull(i8ptr))   // arrays and boxes of `T` are task 253
            }
        }
        LLVMSetInitializer(g, LLVMConstArray2(i8ptr, &words, UInt64(count)))
        return g
    }

    // The shared VWT struct type.
    func valueWitnessType() -> LLVMTypeRef {
        if let t = valueWitnessTy { return t }
        let st = LLVMStructCreateNamed(ctx, "vwt")!
        setStructBody(st, [i32, i32, i32, i32, i8ptr, i8ptr, i8ptr, i32, i32, i32, i32])
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
        let sizeBytes = Int32(sizeOf(t))
        let align = Int32(shapes.align(t))
        // POD iff the value holds no managed word at all, plain or conditional (a `String` is not POD).
        let flags = shapes.shape(t).isEmpty ? LLVMGen.vwtFlagPOD : 0
        // The `type_id` is the value-layout GC descriptor's section offset (100.4.7.4), so a collector
        // handed this VWT reaches the T value's pointer map to scan an erased-T buffer.
        let typeIdVal = sectionOffset(of: descGlobalRef(typeSymbols[Int(valueDescId(t))].name),
                                      seg: "__DATA", sect: "__nomu_descs")

        // A generic class is a reference, which the shape environment knows only by its specialized name.
        let xi: ExtraInhabitants? = {
            if case .generic(let base, _) = t, classMap[base] != nil {
                return ExtraInhabitants(offset: 0, width: 8, first: 0, count: ShapeEnv.referenceExtraInhabitants)
            }
            return shapes.extraInhabitants(t)
        }()

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
            LLVMConstInt(i32, UInt64(xi?.count ?? 0), 0),
            LLVMConstInt(i32, UInt64(xi?.offset ?? 0), 0),
            LLVMConstInt(i32, UInt64(xi?.first ?? 0), 0),
            LLVMConstInt(i32, UInt64((xi?.width ?? 0) | (xi?.shift ?? 0) << 8), 0),
        ]
        LLVMSetInitializer(g, constStruct(vwt, vals))
        return g
    }
}

// Reading and writing an extra inhabitant or a tag whose width is known only at run time: an erased enum's
// payload is a `T`, whose extra inhabitants live in an integer of 1, 2, 4 or 8 bytes.
extension LLVMGen {
    // The unsigned integer of `width` bytes at `p`, as an `i64`. A constant width loads directly.
    func loadUInt(_ p: LLVMValueRef, width: LLVMValueRef) -> LLVMValueRef {
        if LLVMIsAConstantInt(width) != nil {
            let w = Int(LLVMConstIntGetZExtValue(width))
            let v = LLVMBuildLoad2(b, intType(bytes: w), p, "xi.v")!
            return w < 8 ? LLVMBuildZExt(b, v, i64, "xi.v64")! : v
        }
        let (fn, ty) = uintAccessFn(store: false, LLVMTypeOf(p))
        return buildCall(fn, ty, [p, width])!
    }

    // Store the low `width` bytes of `v` (an `i64`) at `p`.
    func storeUInt(_ p: LLVMValueRef, width: LLVMValueRef, _ v: LLVMValueRef) {
        if LLVMIsAConstantInt(width) != nil {
            let w = Int(LLVMConstIntGetZExtValue(width))
            LLVMBuildStore(b, w < 8 ? LLVMBuildTrunc(b, v, intType(bytes: w), "xi.t")! : v, p)
            return
        }
        let (fn, ty) = uintAccessFn(store: true, LLVMTypeOf(p))
        _ = buildCall(fn, ty, [p, width, v])
    }

    // `__nomu_uint_load(p, width) -> i64` and `__nomu_uint_store(p, width, v)`: a switch on the width. One per
    // address space of `p`: a frame buffer, or a heap object's field.
    private func uintAccessFn(store: Bool, _ ptrTy: LLVMTypeRef) -> (LLVMValueRef, LLVMTypeRef) {
        let space = LLVMGetPointerAddressSpace(ptrTy)
        let name = (store ? "__nomu_uint_store" : "__nomu_uint_load") + (space == 0 ? "" : ".p\(space)")
        if let f = runtimeFns[name] { return (f.fn, f.ty) }
        let ty = store ? fnType(voidTy, [ptrTy, i64, i64]) : fnType(i64, [ptrTy, i64])
        let fn = LLVMAddFunction(mod, name, ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        withStubBody(fn) {
            let p = LLVMGetParam(fn, 0)!, width = LLVMGetParam(fn, 1)!
            let widths = [1, 2, 4]
            let wide = LLVMAppendBasicBlockInContext(ctx, fn, "w8")!
            let sw = LLVMBuildSwitch(b, width, wide, UInt32(widths.count))!
            func access(_ w: Int) {
                if store {
                    let v = LLVMGetParam(fn, 2)!
                    LLVMBuildStore(b, w < 8 ? LLVMBuildTrunc(b, v, intType(bytes: w), "t")! : v, p)
                    LLVMBuildRetVoid(b)
                } else {
                    let v = LLVMBuildLoad2(b, intType(bytes: w), p, "v")!
                    LLVMBuildRet(b, w < 8 ? LLVMBuildZExt(b, v, i64, "z")! : v)
                }
            }
            for w in widths {
                let bb = LLVMAppendBasicBlockInContext(ctx, fn, "w\(w)")!
                LLVMAddCase(sw, LLVMConstInt(i64, UInt64(w), 0), bb)
                LLVMPositionBuilderAtEnd(b, bb)
                access(w)
            }
            LLVMPositionBuilderAtEnd(b, wide)
            access(8)
        }
        runtimeFns[name] = (fn, ty)
        return (fn, ty)
    }
}
