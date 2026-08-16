import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Types

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
    // actor's mailbox object (a GC object — so it is scanned, unlike the old runtime mutex). Codegen
    // loads this at the call site and hands the mailbox to `rt_actor_send`, so the actor object never
    // crosses the runtime C ABI.
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

    // An enum lowers to `{ i64 tag, [P x i64] payload }`. All supported field types are 8-aligned
    // and a multiple of 8 bytes, so a case's storage is exactly its field-slot count; P is the
    // largest case's. Payload fields are read/written by GEPing the case's struct type over the
    // payload region (opaque pointers make the reinterpretation free). This layout is internal to
    // the LLVM object (enums never cross the runtime C ABI), so it need not match `CodegenIR`'s.
    func enumType(_ name: String) -> LLVMTypeRef? {
        if let t = enumTypes[name] { return t }
        guard let e = enumMap[name] else { return nil }
        let et = LLVMStructCreateNamed(ctx, "enum.\(name)")!
        enumTypes[name] = et
        let slots = e.cases.map { caseSlots($0) }.max() ?? 0
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

    // 6.5.2 — a captured value whose LLVM type carries no managed pointer, so a stack-allocated
    // closure env holding only such captures needs no barrier and no stack-map scanning. The scalar
    // leaves (`Int`/`Double`/`Bool`) are the safe set; a `p1` capture, a String, or an aggregate that
    // could embed a pointer keeps the closure on the heap for now.
    func isScalarLeaf(_ ty: LLVMTypeRef) -> Bool { ty == i64 || ty == f64 || ty == i1 }

    // 8-byte slots a value occupies in an enum payload. Every supported leaf is 8-aligned, so a
    // struct/enum is just the sum/tag+max of its parts — no padding to account for.
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

    // MARK: - Callable declaration + definition

    func declareFree(_ name: String) {
        let key = "f:\(name)"
        guard callables[key] == nil, let f = funcMap[name] else { return }
        let llvmName = name == "main" ? "nomu_main" : "nomu_fn_\(name)"
        declareCallable(key: key, llvmName: llvmName, ir: f, selfType: nil, selfByPointer: false)
    }

    func declareMethod(_ typeName: String, _ method: String) {
        let key = "m:\(typeName):\(method)"
        guard callables[key] == nil else { return }
        guard let f = typeMethods(typeName).first(where: { $0.name == method }) else {
            fail("8.2.3: unknown method '\(typeName).\(method)'", Span(startOffset: -1, endOffset: -1, map: nil))
            return
        }
        let sanitized = method.replacingOccurrences(of: ".", with: "_")
        // A class is a reference type: `self` is always the object pointer. A struct/enum passes
        // `self` by pointer only when the method mutates it.
        let byPointer = classMap[typeName] != nil || f.isMutating
        declareCallable(key: key, llvmName: "nomu_m_\(typeName)_\(sanitized)",
                        ir: f, selfType: typeName, selfByPointer: byPointer)
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

    // An actor `on`-handler, declared on demand: `self` is the object pointer (a reference type,
    // like a class), the body mutex-serialized (defineBody brackets it with lock/unlock).
    func declareActorHandler(_ actorName: String, _ handler: String) {
        let key = "m:\(actorName):\(handler)"
        guard callables[key] == nil else { return }
        guard let h = actorMap[actorName]?.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", zeroSpan)
            return
        }
        let f = NOIRFunc(name: h.name, params: h.params, returnType: h.returnType,
                       body: h.body, isMutating: true, span: h.span)
        declareCallable(key: key, llvmName: "nomu_on_\(actorName)_\(handler)",
                        ir: f, selfType: actorName, selfByPointer: true)
    }

    func declareCallable(key: String, llvmName: String, ir f: NOIRFunc,
                                 selfType: String?, selfByPointer: Bool) {
        guard let retTy = llvmType(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        if let selfType = selfType {
            guard let st = selfLLVMType(selfType) else { return }
            if selfByPointer {
                // A class/actor receiver is the managed object pointer (addrspace 1). A struct/enum
                // mutating receiver is a pointer to the stack-resident value (addrspace 0).
                let isReference = classMap[selfType] != nil || actorMap[selfType] != nil
                paramTys.append(isReference ? p1 : LLVMPointerType(st, 0)!)
            } else {
                paramTys.append(st)
            }
        }
        for p in f.params {
            guard let t = llvmType(p.type, p.span) else { return }
            paramTys.append(t)
        }
        let (fn, fnTy) = emitFunction(llvmName, ret: retTy, params: paramTys,
                                      debug: (f.name, f.span.begin.line))
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType,
                                  selfByPointer: selfByPointer)
        pending.append(key)
    }

    func defineBody(_ key: String) {
        guard let c = callables[key] else { return }
        let f = c.ir
        currentFn = c.fn
        let block = LLVMAppendBasicBlockInContext(ctx, c.fn, "entry")
        LLVMPositionBuilderAtEnd(b, block)

        let savedLocals = locals; let savedSelf = currentSelf
        let savedSpawns = spawnLocals; let savedActive = activeSpawns
        let savedScope = currentScope
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        locals = [:]; currentSelf = nil; spawnLocals = [:]; activeSpawns = []
        // Adopt this function's subprogram + a live location before the prologue so its
        // instructions (self setup, actor lock) are covered.
        enterDebugScope(c.fn, line: f.span.begin.line)

        var paramBase: UInt32 = 0
        if let selfType = c.selfType, let st = selfLLVMType(selfType) {
            // A class or actor is a reference type: `self` is the object pointer, fields at index i+1.
            let isReference = classMap[selfType] != nil || actorMap[selfType] != nil
            let selfPtr = c.selfByPointer ? LLVMGetParam(c.fn, 0)!
                                          : { let s = LLVMBuildAlloca(b, st, "self")!
                                              LLVMBuildStore(b, LLVMGetParam(c.fn, 0), s); return s }()
            let fields = structMap[selfType]?.fields ?? classMap[selfType]?.fields
                ?? actorMap[selfType]?.fields.map { NOIRField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) }
                ?? []
            currentSelf = SelfCtx(fields: fields, kind: isReference ? .classRef : .structVal,
                                  llvmTy: st, addr: selfPtr)
            if isReference {
                // `self` as a value is the managed object pointer; keep it in an addrspace(1) slot
                // for `varRef self` (mem2reg promotes it so the rewrite pass tracks it as a root).
                let slot = LLVMBuildAlloca(b, p1, "self")!
                LLVMBuildStore(b, selfPtr, slot)
                locals["self"] = (slot, p1)
            } else {
                locals["self"] = (selfPtr, st)   // loading the slot yields the struct/enum value
            }
            paramBase = 1

            let selfKind: NamedKind = structMap[selfType] != nil ? .struct_
                : classMap[selfType] != nil ? .class_
                : enumMap[selfType] != nil ? .enum_ : .actor_
            if let selfSlot = locals["self"]?.addr {
                declareLocal("self", type: .named(selfType, selfKind), addr: selfSlot,
                             line: f.span.begin.line, argNo: 1)
            }

            // M6 · 6.4 — an actor handler no longer locks a mutex. The mailbox serializes handlers (one
            // drain per actor at a time), so the body runs plainly like any method.
        }

        for (i, p) in f.params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(c.fn, UInt32(i) + paramBase), slot)
            locals[p.name] = (slot, t)
            declareLocal(p.name, type: p.type, addr: slot, line: p.span.begin.line,
                         argNo: i + Int(paramBase) + 1)
        }
        lowerBlock(f.body)
        if !blockTerminated() {
            joinActiveSpawns()
            if f.returnType == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        locals = savedLocals; currentSelf = savedSelf
        spawnLocals = savedSpawns; activeSpawns = savedActive
        currentScope = savedScope
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

    // Join every fiber the current function spawned — the structured-concurrency guarantee that no
    // child outlives the scope. `spawn_join` is idempotent, so re-joining an already-read spawn is safe.
    func joinActiveSpawns() { joinSpawnsFrom(0) }

    // Join the spawns created since index `base` (those `activeSpawns[base...]`). Used at function
    // exit (base 0) and at each loop-body exit edge (base = the loop's entry count), so a `break` /
    // `continue` / back-edge joins only what that path actually spawned. `spawn_join` is idempotent.
    func joinSpawnsFrom(_ base: Int) {
        guard base < activeSpawns.count else { return }
        let sj = runtimeFn("spawn_join", ret: i8ptr, params: [i8ptr], varArg: false)
        for s in activeSpawns[base...] { _ = buildCall(sj.0, sj.1, [s.handleSlot]) }
    }

    func blockTerminated() -> Bool {
        LLVMGetBasicBlockTerminator(LLVMGetInsertBlock(b)) != nil
    }

}
