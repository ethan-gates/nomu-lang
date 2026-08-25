import sema
import noir
import ast
import support
import Foundation
import LLVM_C

// Witness tables + `any`/`some` boxing (8.2.5) — the conformance ABI. A witness table is a struct of
// thunk function pointers per `type: iface`; `any I` is a heap `{ header, witness, payload }` box. The
// table shape (slot order), the per-conformance globals, the uniform-self thunks, and the box layout
// must match across both egresses, so they live in the shared emitter. `lowerBox`/`witnessDispatch`,
// which lower NOIR expressions, stay on each egress and call in through these primitives.
extension LLVMGen {
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

        let saved = beginThunk(fn)
        defer { endThunk(saved) }

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

        let saved = beginThunk(fn)
        defer { endThunk(saved) }
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
    // `onStack` (SSAIR EA, 7.3): a non-escaping box's witness struct is an entry alloca in place of the
    // managed heap object (same `{header, witness, payload}` layout, so witness-dispatch GEPs are
    // unchanged; the payload field stays `p1`, SROA scalar-replaces the slot so it becomes a tracked
    // root). Default `false` — the NOIR oracle + covariant-Self thunk keep the heap box.
    func makeAnyBox(_ witness: LLVMValueRef, _ payload: LLVMValueRef, onStack: Bool = false) -> LLVMValueRef {
        let box: LLVMValueRef = onStack ? entryAlloca(anyBoxTy, "box") : rtAllocManaged(LLVMConstInt(i64, 24, 0))
        LLVMBuildStore(b, LLVMConstInt(i64, anyBoxTypeId(), 0), structGEP(anyBoxTy, box, 0)) // header
        storeField(box, structGEP(anyBoxTy, box, 1), witness)   // witness (addrspace 0) → plain store
        storeField(box, structGEP(anyBoxTy, box, 2), payload)   // payload (managed) → write barrier (heap box only)
        return box
    }

    func anyBoxWitness(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, i8ptr, structGEP(anyBoxTy, box, 1), "wt")!
    }
    func anyBoxPayload(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, p1, structGEP(anyBoxTy, box, 2), "pl")!
    }

    // Load a requirement's function pointer from a witness table and call it, self (the payload)
    // first, over already-lowered argument values (+ their LLVM types, for the call signature). The
    // call type is taken from the site — consistent with the thunk's signature, since both lower the
    // same requirement types. The egress lowers the arg exprs and calls in with the resulting values.
    func witnessDispatch(witnessPtr: LLVMValueRef, iface: String, method: String, payload: LLVMValueRef,
                         argVals: [LLVMValueRef], argTys: [LLVMTypeRef], resultType: Type,
                         span: Span) -> LLVMValueRef? {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        let idx = witnessSlotIndex(iface, slot)
        guard idx >= 0 else { fail("8.2.5: no witness slot '\(slot)' in '\(iface)'", span); return nil }
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(iface), witnessPtr, idx), "slot")!

        guard let retTy = llvmType(resultType, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
        paramTys.append(contentsOf: argTys)
        var callArgs: [LLVMValueRef?] = [payload]
        for v in argVals { callArgs.append(v) }
        return buildCall(fnPtr, fnType(retTy, paramTys), callArgs)
    }

    // MARK: - Thunk emit scope

    // Emit-position save/restore for building a witness thunk mid-body: the thunk is a fresh function,
    // so its entry block + debug scope are swapped in and the enclosing builder position restored on
    // exit. Only emission position moves — the tree-walk's local/self/spawn state (owned by the walker,
    // untouched by thunk bodies) stays put, so this is lighter than the walker's closure/spawn
    // `enterThunk`. Both egresses build witness thunks, so it lives here.
    struct EmitScope {
        let block: LLVMBasicBlockRef?
        let fn: LLVMValueRef?
        let scope: LLVMMetadataRef?
        let debugLoc: LLVMMetadataRef?
    }

    func beginThunk(_ fn: LLVMValueRef, line: Int = 0) -> EmitScope {
        let saved = EmitScope(block: LLVMGetInsertBlock(b), fn: currentFn, scope: currentScope,
                              debugLoc: di != nil ? LLVMGetCurrentDebugLocation2(b) : nil)
        currentFn = fn
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        enterDebugScope(fn, line: line)
        return saved
    }

    func endThunk(_ saved: EmitScope) {
        currentFn = saved.fn
        if let block = saved.block { LLVMPositionBuilderAtEnd(b, block) }
        currentScope = saved.scope
        if di != nil { LLVMSetCurrentDebugLocation2(b, saved.debugLoc) }
    }
}
