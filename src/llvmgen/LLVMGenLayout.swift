import noir
import ast
import support
import ssair
import LLVM_C

// Type-layout primitives (moved from the tree-walk into the shared emitter, ssair.md): the
// LLVM struct types for Nomu structs/classes/enums/actors, `Type` → `LLVMTypeRef`, field/slot
// geometry. Built lazily and cached; layout is fed from the `structMap`/`enumMap`/… registries.
extension LLVMGen {
    func structType(_ name: String) -> LLVMTypeRef? {
        if let t = structTypes[name] { return t }
        guard let s = structMap[name] else { return nil }
        // A single-field shaped wrapper is byte-identical to its field, so it lowers to the field's type
        // directly (task 121.1.1) — `struct String` is `strTy`, not `{ strTy }`. This is what lets a wrapper
        // value stay a two-register shaped SSA value on the shaped-root path (its `makeStruct`/`extractField`
        // are identity in the egress) instead of a nested aggregate forced to a frame slot.
        if isShapedWrapper(.named(name, .struct_)), let ft = llvmType(s.fields[0].type, s.fields[0].span) {
            structTypes[name] = ft
            return ft
        }
        let st = LLVMStructCreateNamed(ctx, "struct.\(name)")!
        structTypes[name] = st   // cache before filling (value structs never self-nest, but be safe)
        // Elements in memory order (`ShapeEnv.memoryOrder`); `llvmFieldIndex` maps a declared position.
        var elems: [LLVMTypeRef] = []
        for i in memoryOrder(name) {
            guard let ft = fieldStorageType(s.fields[i].type, s.fields[i].span) else { return nil }
            elems.append(ft)
        }
        // A zero-field struct (e.g. a method-only `Time`) would lower to LLVM's empty type `{}`, which
        // the GC statepoint rewrite can't pass as a call argument ("Empty type passed to intrinsic").
        // Give it a one-byte placeholder so it is a real 1-byte value; no field ever indexes it.
        if elems.isEmpty { elems.append(i8) }
        setStructBody(st, elems)
        return st
    }

    // The LLVM type of a field inside an aggregate (struct, class, actor, enum case, actor message): its
    // size in the value layout (`ShapeEnv.size`), so LLVM's natural layout places it where the value layout
    // does. A `Bool` is stored as a byte; its register type stays `i1` (`llvmType`), and
    // `toFieldStorage`/`fromFieldStorage` convert at `insertvalue`/`extractvalue`. A load or store through a
    // field address keeps the register type, which LLVM reads and writes as one byte. `checkLayout` rejects
    // any aggregate whose LLVM layout differs.
    func fieldStorageType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        switch smallFieldBase(t) {
        case .bool: return i8
        default:    return llvmType(t, span)
        }
    }

    // A `some I` field stores its concrete underlying type, so a small underlying widens too.
    private func smallFieldBase(_ t: Type) -> Type {
        if case .opaque = t { return concreteUnderlying(t) }
        return t
    }

    func toFieldStorage(_ v: LLVMValueRef, _ t: Type) -> LLVMValueRef {
        switch smallFieldBase(t) {
        case .bool: return LLVMBuildZExt(b, v, i8, "fld.byte")!
        default:    return v
        }
    }

    func fromFieldStorage(_ v: LLVMValueRef, _ t: Type) -> LLVMValueRef {
        switch smallFieldBase(t) {
        case .bool: return LLVMBuildTrunc(b, v, i1, "fld.bool")!
        default:    return v
        }
    }

    func llvmType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        switch t {
        case .int:        return i64
        case .uint8:      return i8    // an 8-bit unsigned byte
        case .uint64:     return i64   // a 64-bit unsigned word
        case .double:     return f64
        case .bool:       return i1    // 8.5.2 — Bool is LLVM's native i1 (was i64)
        case .stringBase:     return strTy
        case .void:       return voidTy
        case .function:   return p1   // a closure value is a managed pointer to a heap { fn, caps… } object (8.4.1)
        case .named(let n, .struct_):
            if let st = structType(n) { return st }
            fail("8.2.2: unknown struct '\(n)'", span)
            return nil
        case .named(let n, .enum_):
            if let et = enumType(n) { return et }
            fail("8.2.3: unknown enum '\(n)'", span)
            return nil
        case .named(let n, .class_):
            if classMap[n] != nil { return p1 }   // a class value is a managed pointer to its object (D1)
            fail("8.2.4: unknown class '\(n)'", span)
            return nil
        case .named(let n, .actor_):
            if actorMap[n] != nil { return p1 }    // an actor handle is a managed pointer to its object (D1)
            fail("8.2.6: unknown actor '\(n)'", span)
            return nil
        case .array:
            return p1   // `Array<T>` is a reference type — a managed pointer to the heap handle (M6)
        case .rawPtr, .ptr:
            return i8ptr   // `RawPtr` / `Ptr<T>` — an unmanaged addrspace(0) address (task 125); never a GC root
        case .existential, .composition:
            return p1   // `any I` / `any A & B` — a managed pointer to a heap { witness, payload } box (8.4.1)
        case .opaque:
            let u = concreteUnderlying(t)
            if case .opaque = u { fail("8.2.5: opaque type with no known underlying", span); return nil }
            return llvmType(u, span)                 // `some I` is unboxed — the concrete underlying's type
        case .typeParam:
            return i8ptr   // an erased generic body holds a `T` value indirectly — a ptr to a caller-allocated VWT-sized buffer (backend.md §4)
        case .generic(let base, _):
            // A residual composed generic (`Box<T>`) in an erased body is held by buffer (i8ptr); but a
            // generic **class** is a reference, a managed `p1` object pointer (task 100.4.3.9) — so the
            // statepoint GC tracks an erased class `self` as a root and its fields are byte-GEP'd in
            // addrspace 1. mono names concrete instantiations, so only residual ones reach here (100.4.3.3.4).
            return classMap[base] != nil ? p1 : i8ptr
        default:
            fail("8.2.4: unsupported type '\(t)'", span)
            return nil
        }
    }

    // A class object is `{ i64 header /*ObjectHeader.type_id, 6.1.2*/, fields… }`, heap-allocated. The
    // header slot mirrors the runtime's `ObjectHeader`; codegen fills the type-id at 6.1.3 (zero until
    // then). The fields follow in memory order; `llvmFieldIndex` maps a declared position.
    func classType(_ name: String) -> LLVMTypeRef? {
        if let t = classTypes[name] { return t }
        guard let c = classMap[name] else { return nil }
        let ct = LLVMStructCreateNamed(ctx, "class.\(name)")!
        classTypes[name] = ct
        var elems: [LLVMTypeRef] = [i64]   // ObjectHeader
        for i in memoryOrder(name) {
            guard let ft = fieldStorageType(c.fields[i].type, c.fields[i].span) else { return nil }
            elems.append(ft)
        }
        setStructBody(ct, elems)
        return ct
    }

    // An actor object is `{ i64 header, mailbox, fields… }`, heap-allocated (M6 · 6.4). The mailbox slot at
    // byte 8 holds a managed pointer to the actor's mailbox object (a GC object, so it is scanned); the
    // fields follow in memory order from byte 16.
    func actorType(_ name: String) -> LLVMTypeRef? {
        if let t = actorTypes[name] { return t }
        guard let a = actorMap[name] else { return nil }
        let at = LLVMStructCreateNamed(ctx, "actor.\(name)")!
        actorTypes[name] = at
        var elems: [LLVMTypeRef] = [i64, p1]   // ObjectHeader, mailbox
        for i in memoryOrder(name) {
            guard let ft = fieldStorageType(a.fields[i].type, a.fields[i].span) else { return nil }
            elems.append(ft)
        }
        setStructBody(at, elems)
        return at
    }

    // An actor's mailbox slot: element 1, byte 8, just past the header.
    func actorMailboxIndex(_ name: String) -> Int { 1 }
    func actorMailboxOffset(_ name: String) -> Int { 8 }

    // Where a class's or actor's fields begin: past the header word, and an actor's mailbox.
    func objectFieldBase(_ name: String) -> Int { actorMap[name] != nil ? 16 : 8 }

    // A class's or actor's fields: offsets by declared position.
    func objectLayout(_ name: String) -> FieldsLayout { shapes.objectLayout(name, base: objectFieldBase(name)) }

    // A struct's, class's or actor's declared field positions in memory order.
    func memoryOrder(_ name: String) -> [Int] {
        let fields = structMap[name]?.fields ?? classMap[name]?.fields
        if let fields { return shapes.memoryOrder(fields.map(\.type), marks: fields.map(\.fromTypeParameter)) }
        return shapes.memoryOrder(actorMap[name]?.fields.map(\.type) ?? [], marks: nil)
    }

    // The LLVM element index of a struct's, class's or actor's field at declared position `pos`: its place in
    // memory order, past a class's header or an actor's header and mailbox.
    func llvmFieldIndex(_ name: String, _ pos: Int) -> Int {
        if let m = fieldIndexMaps[name] { return m[pos] }
        let order = memoryOrder(name)
        let first = structMap[name] != nil ? 0 : (actorMap[name] != nil ? 2 : 1)
        var m = [Int](repeating: 0, count: order.count)
        for (k, i) in order.enumerated() { m[i] = first + k }
        fieldIndexMaps[name] = m
        return m[pos]
    }

    // A value box `{ header, value }`'s size in bytes (`boxPayload`).
    func valueBoxSize(_ t: Type) -> Int { ShapeEnv.alignUp(8 + sizeOf(t), 8) }

    // Where a `ManagedBuffer<Header, Element>`'s elements begin: past the type-id and capacity words and the
    // header, rounded up to a word, which is every element's alignment or more. A constant, so erased code
    // that knows only `Header` agrees with specialized code.
    func managedBufferElementStart(header: Type) -> Int { ShapeEnv.alignUp(16 + sizeOf(header), 8) }

    // A class or actor object's size in bytes: the header word, an actor's mailbox pointer, and the fields.
    func objectSize(_ name: String) -> Int { ShapeEnv.alignUp(objectLayout(name).end, 8) }

    // The aggregate type, kind, and fields of a named struct/class.
    func aggInfo(_ typeName: String) -> (ty: LLVMTypeRef, kind: AggKind, fields: [NOIRField])? {
        if let s = structMap[typeName], let t = structType(typeName) { return (t, .structVal, s.fields) }
        if let c = classMap[typeName], let t = classType(typeName) { return (t, .classRef, c.fields) }
        return nil
    }


    // An enum lowers by its layout (`ShapeEnv.enumLayout`): a tag only, `{ iN tag }`; over its payload's extra
    // inhabitants, the payload case's fields `{ f0, f1, … }`; with a tag, the payload region then the tag,
    // `{ region…, iN tag }`, each case's fields read and written by GEPing its struct type over the region. A
    // word-aligned region is words, a pointer where every payload case holds a reference (the shape's plain
    // managed words, which the statepoint rewrite relocates) and an `i64` elsewhere; a narrower region is
    // integers of its alignment.
    func enumType(_ name: String) -> LLVMTypeRef? {
        if let t = enumTypes[name] { return t }
        guard let en = enumMap[name] else { return nil }
        let et = LLVMStructCreateNamed(ctx, "enum.\(name)")!
        enumTypes[name] = et
        switch shapes.enumLayout(name) {
        case .tagOnly(let w):
            setStructBody(et, [intType(bytes: w)])
        case .overExtraInhabitants(let p):
            guard let fields = caseFieldTypes(en.cases[p]) else { return nil }
            setStructBody(et, fields)
        case .tagged(let tagOffset, let w):
            let region = shapes.enumPayloadRegion(name)
            var elems: [LLVMTypeRef] = []
            if region.align >= 8 {
                let pointers = Set(shapes.shape(.named(name, .enum_)).managed)
                for off in stride(from: 0, to: tagOffset, by: 8) { elems.append(pointers.contains(off) ? p1 : i64) }
            } else {
                elems = Array(repeating: intType(bytes: region.align), count: tagOffset / region.align)
            }
            setStructBody(et, elems + [intType(bytes: w)])
        case .spareBits:
            // The payload region's words, a pointer where every payload case holds a reference (one of them
            // carrying the case in its low bits).
            let pointers = Set(shapes.shape(.named(name, .enum_)).managed)
            let size = shapes.size(.named(name, .enum_))
            setStructBody(et, stride(from: 0, to: size, by: 8).map { pointers.contains($0) ? p1 : i64 })
        }
        return et
    }

    // The integer type of `bytes` bytes: a tag, or the field an extra inhabitant is written to.
    func intType(bytes: Int) -> LLVMTypeRef { LLVMIntTypeInContext(ctx, UInt32(bytes * 8))! }

    private func caseFieldTypes(_ c: NOIREnumCase) -> [LLVMTypeRef]? {
        var elems: [LLVMTypeRef] = []
        for f in c.fields {
            guard let t = fieldStorageType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return elems
    }

    // The struct of a case's payload field types — GEP'd over the enum's payload region.
    func caseStructType(_ enumName: String, _ c: NOIREnumCase) -> LLVMTypeRef? {
        var elems: [LLVMTypeRef] = []
        for f in c.fields {
            guard let t = fieldStorageType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return structTy(elems)
    }

    // 6.5.2 — a captured value whose LLVM type carries no managed pointer (the scalar leaves), so a
    // stack-allocated closure env holding only such captures needs no barrier or stack-map scanning.
    func isScalarLeaf(_ ty: LLVMTypeRef) -> Bool { ty == i64 || ty == f64 || ty == i1 }

    // A value's size in bytes: the value layout every component shares (`ShapeEnv.size`).
    func sizeOf(_ t: Type) -> Int { shapes.size(t) }

    func typeMethods(_ typeName: String) -> [NOIRFunc] {
        structMap[typeName]?.methods ?? enumMap[typeName]?.methods ?? classMap[typeName]?.methods ?? []
    }

    // The aggregate pointee type used for a `self` parameter. A class always passes `self` by
    // pointer, so this is the class object type; structs/enums pass the value type.
    func selfLLVMType(_ typeName: String) -> LLVMTypeRef? {
        if structMap[typeName] != nil { return structType(typeName) }
        if enumMap[typeName] != nil { return enumType(typeName) }
        if classMap[typeName] != nil { return classType(typeName) }
        if actorMap[typeName] != nil { return actorType(typeName) }
        return nil
    }
}
