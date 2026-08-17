import noir
import ast
import support
import LLVM_C

// Type-layout primitives (moved from the tree-walk into the shared emitter, m7-spec.md §7.2.3): the
// LLVM struct types for Nomu structs/classes/enums/actors, `Type` → `LLVMTypeRef`, field/slot
// geometry. Built lazily and cached; layout is fed from the `structMap`/`enumMap`/… registries.
extension LLVMGen {
    func structType(_ name: String) -> LLVMTypeRef? {
        if let t = structTypes[name] { return t }
        guard let s = structMap[name] else { return nil }
        let st = LLVMStructCreateNamed(ctx, "struct.\(name)")!
        structTypes[name] = st   // cache before filling (value structs never self-nest, but be safe)
        var elems: [LLVMTypeRef] = []
        for f in s.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        setStructBody(st, elems)
        return st
    }

    func llvmType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        switch t {
        case .int:        return i64
        case .double:     return f64
        case .bool:       return i1    // 8.5.2 — Bool is LLVM's native i1 (was i64)
        case .string:     return strTy
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
        case .existential, .composition:
            return p1   // `any I` / `any A & B` — a managed pointer to a heap { witness, payload } box (8.4.1)
        case .opaque:
            let u = concreteUnderlying(t)
            if case .opaque = u { fail("8.2.5: opaque type with no known underlying", span); return nil }
            return llvmType(u, span)                 // `some I` is unboxed — the concrete underlying's type
        default:
            fail("8.2.4: unsupported type '\(t)'", span)
            return nil
        }
    }

    // A class object is `{ i64 header /*ObjectHeader.type_id, 6.1.2*/, fields… }`, heap-allocated. The
    // header slot mirrors the runtime's `ObjectHeader`; codegen fills the type-id at 6.1.3 (zero until
    // then). Field index i is therefore at aggregate index i+1.
    func classType(_ name: String) -> LLVMTypeRef? {
        if let t = classTypes[name] { return t }
        guard let c = classMap[name] else { return nil }
        let ct = LLVMStructCreateNamed(ctx, "class.\(name)")!
        classTypes[name] = ct
        var elems: [LLVMTypeRef] = [i64]   // ObjectHeader
        for f in c.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        setStructBody(ct, elems)
        return ct
    }

    // An actor object is `{ i64 header, fields…, mailbox }`, heap-allocated (M6 · 6.4). Fields sit at
    // index i+1 (past the header, like a class); the trailing slot holds a managed pointer to the
    // actor's mailbox object (a GC object — so it is scanned, unlike the old runtime mutex).
    func actorType(_ name: String) -> LLVMTypeRef? {
        if let t = actorTypes[name] { return t }
        guard let a = actorMap[name] else { return nil }
        let at = LLVMStructCreateNamed(ctx, "actor.\(name)")!
        actorTypes[name] = at
        var elems: [LLVMTypeRef] = [i64]   // ObjectHeader
        for f in a.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        elems.append(p1)   // mailbox
        setStructBody(at, elems)
        return at
    }

    // The index of an actor's mailbox slot (after the header and every field).
    func actorMailboxIndex(_ name: String) -> Int { (actorMap[name]?.fields.count ?? 0) + 1 }

    // The aggregate type, kind, and fields of a named struct/class.
    func aggInfo(_ typeName: String) -> (ty: LLVMTypeRef, kind: AggKind, fields: [NOIRField])? {
        if let s = structMap[typeName], let t = structType(typeName) { return (t, .structVal, s.fields) }
        if let c = classMap[typeName], let t = classType(typeName) { return (t, .classRef, c.fields) }
        return nil
    }

    func fieldLLVMIndex(_ kind: AggKind, _ fieldPos: Int) -> Int {
        kind == .classRef ? fieldPos + 1 : fieldPos   // classes reserve index 0 for the header
    }

    // An enum lowers to `{ i64 tag, [P x i64] payload }`, P the largest case's slot count. Payload
    // fields are read/written by GEPing the case's struct type over the payload region.
    func enumType(_ name: String) -> LLVMTypeRef? {
        if let t = enumTypes[name] { return t }
        guard let en = enumMap[name] else { return nil }
        let et = LLVMStructCreateNamed(ctx, "enum.\(name)")!
        enumTypes[name] = et
        let slots = en.cases.map { caseSlots($0) }.max() ?? 0
        setStructBody(et, [i64, LLVMArrayType2(i64, UInt64(slots))])
        return et
    }

    // The struct of a case's payload field types — GEP'd over the enum's payload region.
    func caseStructType(_ enumName: String, _ c: NOIREnumCase) -> LLVMTypeRef? {
        var elems: [LLVMTypeRef] = []
        for f in c.fields {
            guard let t = llvmType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return structTy(elems)
    }

    func caseSlots(_ c: NOIREnumCase) -> Int { c.fields.reduce(0) { $0 + slotCount($1.type) } }

    // 6.5.2 — a captured value whose LLVM type carries no managed pointer (the scalar leaves), so a
    // stack-allocated closure env holding only such captures needs no barrier or stack-map scanning.
    func isScalarLeaf(_ ty: LLVMTypeRef) -> Bool { ty == i64 || ty == f64 || ty == i1 }

    // 8-byte slots a value occupies in an enum payload. Every supported leaf is 8-aligned.
    func slotCount(_ t: Type) -> Int {
        switch t {
        case .int, .double, .bool: return 1
        case .string:     return 2
        case .function:   return 1   // a managed pointer to a heap { fn, caps… } box (8.4.1)
        case .existential, .composition: return 1   // a managed pointer to a heap { witness, payload } box
        case .opaque:     return slotCount(concreteUnderlying(t))
        case .named(_, .class_), .named(_, .actor_): return 1   // a pointer
        case .named(let n, .struct_): return structMap[n]?.fields.reduce(0) { $0 + slotCount($1.type) } ?? 1
        case .named(let n, .enum_):   return 1 + (enumMap[n]?.cases.map { caseSlots($0) }.max() ?? 0)
        default: return 1
        }
    }

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
