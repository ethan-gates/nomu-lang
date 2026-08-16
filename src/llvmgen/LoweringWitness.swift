import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Witness tables + `any`/`some` (8.2.5)

    // Resolve a `some I` opaque type to its hidden concrete underlying (known to codegen, M5 A3);
    // everything else passes through unchanged.
    func concreteUnderlying(_ t: Type) -> Type {
        if case .opaque(_, let owner) = t, let u = opaqueUnderlyings[owner] { return u }
        return t
    }

    func namedKind(_ type: String) -> NamedKind {
        if enumMap[type] != nil { return .enum_ }
        if classMap[type] != nil { return .class_ }
        return .struct_
    }

    // The witness slots of an interface, in the layout order: each method requirement, then each
    // property's `_get` (and `_set` if settable), then a `base_<B>` per transitive base, then the
    // reserved `type_witness`. Every slot is a pointer, so the witness struct is N pointers and a
    // slot is reached by its index here.
    func witnessSlots(_ iface: String) -> [String] {
        if let cached = witnessSlotsCache[iface] { return cached }
        guard let i = interfaceDefs[iface] else { return ["type_witness"] }
        var slots = i.methods.map(\.name)
        for p in i.properties {
            slots.append("\(p.name)_get")
            if p.isSettable { slots.append("\(p.name)_set") }
        }
        for b in i.bases { slots.append("base_\(b)") }
        slots.append("type_witness")
        witnessSlotsCache[iface] = slots
        return slots
    }

    func witnessSlotIndex(_ iface: String, _ slot: String) -> Int {
        witnessSlots(iface).firstIndex(of: slot) ?? -1
    }

    // The witness struct type for an interface — one `ptr` slot per `witnessSlots` entry.
    func witnessType(_ iface: String) -> LLVMTypeRef {
        if let t = witnessTypes[iface] { return t }
        let n = max(witnessSlots(iface).count, 1)
        let st = LLVMStructCreateNamed(ctx, "witness.\(iface)")!
        setStructBody(st, [LLVMTypeRef](repeating: i8ptr, count: n))
        witnessTypes[iface] = st
        return st
    }

    // The witness-table instance for a conformance `type: iface`, an internal LLVM global built on
    // demand: a struct of thunk function pointers (uniform `void*`-self signatures), base-witness
    // pointers, and the reserved type-witness. The global is cached before its slots are filled so
    // a base pointer can reference the same conformer's (recursively built) base witnesses.
    func witnessInstance(_ type: String, _ iface: String) -> LLVMValueRef? {
        let key = "\(type)::\(iface)"
        if let g = witnessGlobals[key] { return g }
        guard let idef = interfaceDefs[iface] else {
            fail("8.2.5: unknown interface '\(iface)'", zeroSpan); return nil
        }
        let wt = witnessType(iface)
        let g = LLVMAddGlobal(mod, wt, "wt_\(type)_\(iface)")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        witnessGlobals[key] = g   // cache before recursion into base witnesses

        var vals: [LLVMValueRef?] = []
        for m in idef.methods {
            guard let thunk = methodThunk(type, iface, m) else { return nil }
            vals.append(thunk)
        }
        for p in idef.properties {
            guard let getT = propThunk(type, iface, p, setter: false) else { return nil }
            vals.append(getT)
            if p.isSettable {
                guard let setT = propThunk(type, iface, p, setter: true) else { return nil }
                vals.append(setT)
            }
        }
        for base in idef.bases {
            guard let bw = witnessInstance(type, base) else { return nil }
            vals.append(bw)
        }
        vals.append(LLVMConstPointerNull(i8ptr))   // type_witness (reserved)
        LLVMSetInitializer(g, constStruct(wt, vals))
        return g
    }

    // Bridge a thunk's `payload` pointer to the impl's `self`: a by-pointer (mutating/class) method
    // takes it directly; a by-value method loads the concrete value out of it.
    func bridgeThunkSelf(_ payload: LLVMValueRef, _ type: String, _ c: Callable) -> LLVMValueRef? {
        if c.selfByPointer {
            // A class/actor impl takes the managed object pointer directly. A struct/enum mutating
            // impl takes an addrspace(0) pointer to a stack-ABI value, so cast the heap box down.
            if classMap[type] != nil || actorMap[type] != nil { return payload }
            return toUnmanaged(payload)
        }
        guard let st = selfLLVMType(type) else { return nil }
        return LLVMBuildLoad2(b, st, payload, "self")
    }

    // A uniform-signature thunk `ret(ptr self, params…)` wrapping the concrete impl: it bridges
    // `self` (the payload pointer) to the impl's ABI — by value for a read-only value method, by
    // pointer for a mutating / class method — and re-boxes a covariant-`Self` result as `any iface`.
    func methodThunk(_ type: String, _ iface: String, _ m: NOIRMethodReq) -> LLVMValueRef? {
        guard let retTy = llvmType(m.ret, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
        for pt in m.params {
            guard let t = llvmType(pt, zeroSpan) else { return nil }
            paramTys.append(t)
        }
        let sname = m.name.replacingOccurrences(of: ".", with: "_")
        let (fn, _) = emitFunction("wt_\(type)_\(iface)_\(sname)", ret: retTy, params: paramTys)

        let saved = enterThunk(fn)
        defer { leaveThunk(saved) }

        declareMethod(type, m.name)
        guard let c = callables["m:\(type):\(m.name)"] else { return nil }
        guard let selfArg = bridgeThunkSelf(LLVMGetParam(fn, 0)!, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        for i in 0..<m.params.count { callArgs.append(LLVMGetParam(fn, UInt32(i + 1))) }
        guard let result = buildCall(c.fn, c.ty, callArgs) else { return nil }

        if case .existential = m.ret {
            // Covariant `Self`: the impl returns the concrete conformer; re-box it as `any iface`.
            guard let w = witnessInstance(type, iface),
                  let pl = boxPayload(result, .named(type, namedKind(type))) else { return nil }
            LLVMBuildRet(b, makeAnyBox(w, pl))
        } else if m.ret == .void {
            LLVMBuildRetVoid(b)
        } else {
            LLVMBuildRet(b, result)
        }
        return fn
    }

    // A property get/set thunk. A stored-field-backed requirement is a direct field load/store; a
    // computed one routes through the concrete accessor method (`prop.get` / `prop.set`).
    func propThunk(_ type: String, _ iface: String, _ p: NOIRPropReq, setter: Bool) -> LLVMValueRef? {
        guard let propTy = llvmType(p.type, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
        if setter { paramTys.append(propTy) }
        let slot = setter ? "\(p.name)_set" : "\(p.name)_get"
        let (fn, _) = emitFunction("wt_\(type)_\(iface)_\(slot)",
                                   ret: setter ? voidTy : propTy, params: paramTys)

        let saved = enterThunk(fn)
        defer { leaveThunk(saved) }
        let payload = LLVMGetParam(fn, 0)!

        if let info = aggInfo(type), let pos = info.fields.firstIndex(where: { $0.name == p.name }) {
            let addr = structGEP(info.ty, payload, fieldLLVMIndex(info.kind, pos))
            if setter {
                storeField(payload, addr, LLVMGetParam(fn, 1)!)
                LLVMBuildRetVoid(b)
            } else {
                LLVMBuildRet(b, LLVMBuildLoad2(b, propTy, addr, "fld"))
            }
            return fn
        }

        let accessor = "\(p.name).\(setter ? "set" : "get")"
        declareMethod(type, accessor)
        guard let c = callables["m:\(type):\(accessor)"] else { return nil }
        guard let selfArg = bridgeThunkSelf(payload, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        if setter { callArgs.append(LLVMGetParam(fn, 1)) }
        let result = buildCall(c.fn, c.ty, callArgs)
        if setter { LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, result!) }
        return fn
    }

    // The composite-witness struct type for `any A & B` — one `ptr` sub-table slot per interface.
    func compositeType(_ ifaces: [String]) -> LLVMTypeRef {
        let key = ifaces.joined(separator: "&")
        if let t = compositeTypes[key] { return t }
        let st = LLVMStructCreateNamed(ctx, "comp.\(key)")!
        setStructBody(st, [LLVMTypeRef](repeating: i8ptr, count: max(ifaces.count, 1)))
        compositeTypes[key] = st
        return st
    }

    // The composite-witness instance for `type: A & B` — a global holding one single-interface
    // witness pointer per interface.
    func compositeInstance(_ type: String, _ ifaces: [String]) -> LLVMValueRef? {
        let key = "\(type)::\(ifaces.joined(separator: "&"))"
        if let g = compositeGlobals[key] { return g }
        let ct = compositeType(ifaces)
        let g = LLVMAddGlobal(mod, ct, "comp_\(type)_\(ifaces.joined(separator: "_"))")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        compositeGlobals[key] = g
        var vals: [LLVMValueRef?] = []
        for i in ifaces {
            guard let w = witnessInstance(type, i) else { return nil }
            vals.append(w)
        }
        LLVMSetInitializer(g, constStruct(ct, vals))
        return g
    }

    // Which interface of a composition declares `method` (used to pick the owning sub-table).
    func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        for i in ifaces where witnessSlots(i).contains(slot) { return i }
        return ifaces.first ?? "?"
    }

    // Load a requirement's function pointer from a witness table and call it, self (the payload)
    // first. The call type is taken from the site (result type + argument types) — consistent with
    // the thunk's signature, since both lower the same requirement types.
    func witnessDispatch(witnessPtr: LLVMValueRef, iface: String, method: String,
                                 payload: LLVMValueRef, args: [NOIRExpr], resultType: Type,
                                 span: Span) -> LLVMValueRef? {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        let idx = witnessSlotIndex(iface, slot)
        guard idx >= 0 else { fail("8.2.5: no witness slot '\(slot)' in '\(iface)'", span); return nil }
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(iface), witnessPtr, idx), "slot")!

        guard let retTy = llvmType(resultType, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
        var argVals: [LLVMValueRef?] = [payload]
        for a in args {
            guard let t = llvmType(a.type, span), let v = lowerExpr(a) else { return nil }
            paramTys.append(t); argVals.append(v)
        }
        return buildCall(fnPtr, fnType(retTy, paramTys), argVals)
    }

    // Wrap a concrete conformer as `any I` / `any A & B`, or upcast `any B` → `any A`.
    func lowerBox(_ value: NOIRExpr, _ ifaces: [String], _ span: Span) -> LLVMValueRef? {
        // `any B` → `any A`: re-box through the source witness's base pointer, keeping the payload.
        if case .existential(let src) = value.type, ifaces.count == 1 {
            guard let box = lowerExpr(value) else { return nil }
            let witnessPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
            let idx = witnessSlotIndex(src, "base_\(ifaces[0])")
            guard idx >= 0 else { fail("8.2.5: '\(src)' has no base '\(ifaces[0])'", span); return nil }
            let base = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(src), witnessPtr, idx), "base")!
            return makeAnyBox(base, payload)
        }
        guard case .named(let t, _) = value.type else {
            fail("8.2.5: cannot box non-nominal value", span); return nil
        }
        guard let v = lowerExpr(value) else { return nil }
        let witness = ifaces.count == 1 ? witnessInstance(t, ifaces[0]) : compositeInstance(t, ifaces)
        guard let w = witness, let pl = boxPayload(v, value.type) else { return nil }
        return makeAnyBox(w, pl)
    }

    // The `any I` payload for a value: a reference type is its pointer; a value type is copied to a
    // fresh heap allocation so the pointer outlives the temporary (rt_alloc, leaked until the M6 GC).
    func boxPayload(_ v: LLVMValueRef, _ t: Type) -> LLVMValueRef? {
        switch t {
        case .named(_, .class_), .named(_, .actor_):
            return v
        default:
            let bytes = max(slotCount(t) * 8, 8)
            let p = rtAllocManaged(LLVMConstInt(i64, UInt64(bytes), 0))
            LLVMBuildStore(b, v, p)
            return p
        }
    }

    // An `any I` value is a managed pointer to a heap `{ i8ptr witness, p1 payload }` box (8.4.1):
    // keeping the box behind a `p1` pointer means the value the mutator holds and passes across
    // calls is a single scalar GC reference the rewrite pass tracks, never a first-class aggregate
    // with a GC pointer nested inside (which the pass cannot relocate). The witness is a static
    // table (addrspace 0); the payload is the managed object / heap value-copy pointer (addrspace 1).
    func makeAnyBox(_ witness: LLVMValueRef, _ payload: LLVMValueRef) -> LLVMValueRef {
        let box = rtAllocManaged(LLVMConstInt(i64, 24, 0))   // header + witness + payload
        LLVMBuildStore(b, LLVMConstInt(i64, anyBoxTypeId(), 0), structGEP(anyBoxTy, box, 0)) // header
        storeField(box, structGEP(anyBoxTy, box, 1), witness)   // witness (addrspace 0) → plain store
        storeField(box, structGEP(anyBoxTy, box, 2), payload)   // payload (managed) → write barrier
        return box
    }

    func anyBoxWitness(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, i8ptr, structGEP(anyBoxTy, box, 1), "wt")!
    }
    func anyBoxPayload(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, p1, structGEP(anyBoxTy, box, 2), "pl")!
    }

    // Reposition the builder to a freshly built thunk, saving the enclosing lowering state; the
    // returned tuple is handed back to `leaveThunk` to restore it (thunks are built inline, mid-body).
    struct ThunkState {
        let block: LLVMBasicBlockRef?
        let locals: [String: (addr: LLVMValueRef, ty: LLVMTypeRef)]
        let self_: SelfCtx?
        let fn: LLVMValueRef?
        let spawnLocals: [String: SpawnLocal]
        let activeSpawns: [SpawnLocal]
        let scope: LLVMMetadataRef?
        let debugLoc: LLVMMetadataRef?
        let loops: [LoopCtx]
    }

    func enterThunk(_ fn: LLVMValueRef, line: Int = 0) -> ThunkState {
        let saved = ThunkState(block: LLVMGetInsertBlock(b), locals: locals, self_: currentSelf, fn: currentFn,
                               spawnLocals: spawnLocals, activeSpawns: activeSpawns,
                               scope: currentScope, debugLoc: di != nil ? LLVMGetCurrentDebugLocation2(b) : nil,
                               loops: loopStack)
        currentFn = fn; currentSelf = nil; locals = [:]
        spawnLocals = [:]; activeSpawns = []; loopStack = []
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        enterDebugScope(fn, line: line)
        return saved
    }

    func leaveThunk(_ saved: ThunkState) {
        locals = saved.locals; currentSelf = saved.self_; currentFn = saved.fn
        spawnLocals = saved.spawnLocals; activeSpawns = saved.activeSpawns
        loopStack = saved.loops
        if let block = saved.block { LLVMPositionBuilderAtEnd(b, block) }
        currentScope = saved.scope
        if di != nil { LLVMSetCurrentDebugLocation2(b, saved.debugLoc) }
    }

    // A captured local: its name and the (addr, ty) slot it lives in in the enclosing scope. Shared
    // by closures and `spawn let`, which both copy free variables by value into a heap env.
    typealias Capture = (name: String, local: (addr: LLVMValueRef, ty: LLVMTypeRef))

    // The free variables of `used` that name enclosing locals, de-duplicated in first-use order.
    func resolveCaptures(_ used: [String]) -> [Capture] {
        var seen = Set<String>()
        return used.compactMap { name in
            guard seen.insert(name).inserted, let l = locals[name] else { return nil }
            return (name, l)
        }
    }

    // The env struct type holding the captures in order; an i8 placeholder when empty so `rt_alloc`
    // still has a nonzero size.
    func captureEnvType(_ caps: [Capture]) -> LLVMTypeRef {
        structTy(caps.isEmpty ? [LLVMInt8TypeInContext(ctx)!] : caps.map { $0.local.ty })
    }

    // Inside a freshly entered thunk: copy each capture out of `env` into a fresh local slot.
    // `baseIndex` is the field index of the first capture in `envTy` — 0 for a spawn env object,
    // 1 for a fused closure object (whose field 0 is the fn pointer).
    func loadCapturesIntoScope(_ caps: [Capture], _ envTy: LLVMTypeRef, _ env: LLVMValueRef, baseIndex: Int = 0) {
        for (i, cap) in caps.enumerated() {
            let slot = LLVMBuildAlloca(b, cap.local.ty, cap.name)!
            let v = LLVMBuildLoad2(b, cap.local.ty, structGEP(envTy, env, i + baseIndex), cap.name)
            LLVMBuildStore(b, v, slot)
            locals[cap.name] = (slot, cap.local.ty)
        }
    }

    // At a `spawn` capture site: heap-allocate the env and copy each capture's current value into
    // it. The env is a managed (addrspace 1) object; the spawn site casts it to addrspace(0) for
    // the `fiber_spawn` boundary (D1). (Closures don't use this — they fuse captures into the
    // closure object; see `lowerClosure`.)
    func allocAndFillEnv(_ caps: [Capture], _ envTy: LLVMTypeRef) -> LLVMValueRef {
        let bytes = caps.reduce(0) { $0 + abiSlots($1.local.ty) } * 8
        let envPtr = rtAllocManaged(LLVMConstInt(i64, UInt64(max(bytes, 8)), 0))
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            storeField(envPtr, structGEP(envTy, envPtr, i), v)
        }
        return envPtr
    }

    // A closure lowers to a hoisted impl function `ret nomu_cloN(ptr obj, params…)` plus a site
    // that heap-allocates one fused object `{ fn, caps… }` and yields a managed pointer to it (the
    // closure value). Fusing the captures inline after the fn pointer makes creation a single
    // allocation, and the value is one scalar `p1` the rewrite pass tracks — no `{fn,env}` aggregate
    // rides across a safepoint (8.4.1). The impl receives the object as its first param and reads
    // its captures from fields 1…N. Captures are the body's free variables that name enclosing locals.
    func lowerClosure(params: [NOIRParam], body: [NOIRStmt], ret: Type, span: Span) -> LLVMValueRef? {
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUses(body, bound: &bound, used: &used)
        let caps = resolveCaptures(used)
        let objTy = structTy([i64, i8ptr] + caps.map { $0.local.ty })   // { header, fn, cap0, cap1, … }

        // 6.5.2 — a non-escaping closure whose captures are all scalar leaves gets a stack env: the
        // impl takes its env as an addrspace(0) pointer and the site `alloca`s it, so the fused object
        // never heaps. The env holds no managed pointers, so it needs no scanning; escape analysis
        // proved the closure is only invoked locally, never stored/passed/returned.
        let stackEnv = escapes.isNonEscaping(span, .closure) && caps.allSatisfy { isScalarLeaf($0.local.ty) }
        let envTy: LLVMTypeRef = stackEnv ? i8ptr : p1

        guard let retTy = llvmType(ret, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [envTy]   // the closure object itself, captures read via GEP
        for p in params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            paramTys.append(t)
        }
        let (fn, _) = emitFunction("nomu_clo\(closureSeq)", ret: retTy, params: paramTys,
                                   debug: ("closure", span.begin.line))
        closureSeq += 1

        // Define the impl body against a fresh scope (captures loaded from the object + params),
        // then restore the enclosing builder position and lowering state. A fresh scope, including
        // spawn/actor state — the body's `return` must not join the enclosing function's spawns
        // (that would reference its allocas from another function).
        let saved = enterThunk(fn, line: span.begin.line)
        loadCapturesIntoScope(caps, objTy, LLVMGetParam(fn, 0)!, baseIndex: 2)
        for (i, p) in params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(fn, UInt32(i) + 1), slot)
            locals[p.name] = (slot, t)
            declareLocal(p.name, type: p.type, addr: slot, line: p.span.begin.line, argNo: i + 2)
        }
        lowerBlock(body)
        if !blockTerminated() {
            joinActiveSpawns()
            if ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        leaveThunk(saved)

        // Site: allocate the fused object, store the fn pointer then each capture by value, and
        // yield the managed pointer as the closure value.
        let slots = 2 + caps.reduce(0) { $0 + abiSlots($1.local.ty) }   // header + fn + captures
        let obj = stackEnv ? entryAlloca(objTy, "clo.env")
                           : rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
        LLVMBuildStore(b, LLVMConstInt(i64, closureTypeId(caps), 0), structGEP(objTy, obj, 0)) // header
        LLVMBuildStore(b, fn, structGEP(objTy, obj, 1))                                          // fn
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            storeField(obj, structGEP(objTy, obj, i + 2), v)
        }
        return obj
    }

}
