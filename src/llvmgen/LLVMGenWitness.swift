import sema
import mangle
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
    // `type_witness` (a value payload's descriptor, in an `any` table). Every slot is a pointer, so the witness struct is N pointers and a
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
            // A constraint-only base is never `any`, so no upcast reads its slot.
            if interfaceDefs[base]?.isConstraintOnly == true { vals.append(LLVMConstPointerNull(i8ptr)); continue }
            guard let bw = witnessInstance(type, base) else { return nil }
            vals.append(bw)
        }
        // type_witness: a value payload's descriptor header, which a compiled-once body boxing this type reads to
        // stamp the payload it copies the value into; a reference payload is the object itself, so null.
        vals.append(boxIsValue(type) ? LLVMConstIntToPtr(descOffsetHeader(valueBoxTypeId(.named(type, namedKind(type)))), i8ptr)
                                     : LLVMConstPointerNull(i8ptr))
        LLVMSetInitializer(g, constStruct(wt, vals))
        return g
    }

    // The erased-path witness table for `type: iface` (task 100.4.3.3.3): the same slot layout as
    // `witnessInstance`, but each method/property slot holds an **erased** thunk whose self-ABI is a
    // value-buffer pointer (addrspace 0, value at offset 0) rather than a heap box. A consumer threads
    // this table into a cross-module bounded generic call; the producer's erased body dispatches through
    // it with the buffer it holds. The `any I` table is left untouched, so its dispatch is unchanged.
    func witnessInstanceErased(_ type: String, _ iface: String) -> LLVMValueRef? {
        let key = "\(type)::\(iface)::erased"
        if let g = witnessErasedGlobals[key] { return g }
        guard let idef = interfaceDefs[iface] else {
            fail("8.2.5: unknown interface '\(iface)'", zeroSpan); return nil
        }
        let wt = witnessType(iface)
        let g = LLVMAddGlobal(mod, wt, "wte_\(type)_\(iface)")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        witnessErasedGlobals[key] = g   // cache before recursion into base witnesses

        var vals: [LLVMValueRef?] = []
        for m in idef.methods {
            guard let thunk = methodThunkErased(type, iface, m) else { return nil }
            vals.append(thunk)
        }
        for p in idef.properties {
            guard let getT = propThunkErased(type, iface, p, setter: false) else { return nil }
            vals.append(getT)
            if p.isSettable {
                guard let setT = propThunkErased(type, iface, p, setter: true) else { return nil }
                vals.append(setT)
            }
        }
        for base in idef.bases {
            guard let bw = witnessInstanceErased(type, base) else { return nil }
            vals.append(bw)
        }
        vals.append(LLVMConstPointerNull(i8ptr))   // type_witness (reserved)
        LLVMSetInitializer(g, constStruct(wt, vals))
        return g
    }

    // Bridge an erased thunk's value-buffer pointer (the value at offset 0, no box header) to the impl's
    // `self` (task 100.4.3.3.3). Value-type conformers (struct/enum, POD or not) — a by-value method loads
    // the value, a mutating one takes the buffer pointer directly. A class conformer's value buffer holds
    // the managed object reference at offset 0, so `self` is that reference loaded as `p1` (the impl takes
    // the object pointer, like `bridgeThunkSelf`'s class path). The GC-trace of a non-POD value buffer — a
    // class reference, or managed fields inside a struct — is handled at the call site (the typed-root
    // registration, task 100.4.3.6). An actor conformer's requirements are sends, built before this is reached.
    func bridgeErasedThunkSelf(_ valuePtr: LLVMValueRef, _ type: String, _ c: Callable) -> LLVMValueRef? {
        if classMap[type] != nil {
            return LLVMBuildLoad2(b, p1, valuePtr, "self")   // buffer holds the object reference at offset 0
        }
        if c.selfByPointer {
            return valuePtr   // mutating value method: the impl takes an addrspace(0) pointer to the value
        }
        guard let st = selfLLVMType(type) else { return nil }
        return LLVMBuildLoad2(b, st, valuePtr, "self")   // value at offset 0
    }

    // A uniform value-buffer-self thunk `ret(ptr self, params…)` for the erased path — the counterpart of
    // `methodThunk`, differing only in that `self` is a value-buffer pointer (offset 0) rather than a box. `Self` in
    // the requirement passes as a type parameter would (`selfSlot`): a buffer result is written to a result buffer
    // passed after `self`, the slot returning nothing.
    func methodThunkErased(_ type: String, _ iface: String, _ m: NOIRMethodReq) -> LLVMValueRef? {
        let returnsBuffer = selfSlot(m.selfRet) == .buffer
        guard let retTy = returnsBuffer ? voidTy : erasedSlotType(m.selfRet) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]   // self — value-buffer pointer (addrspace 0)
        if returnsBuffer { paramTys.append(i8ptr) }
        for pt in m.selfParams {
            guard let t = erasedSlotType(pt) else { return nil }
            paramTys.append(t)
        }
        let sname = m.name.replacingOccurrences(of: ".", with: "_")
        let (fn, _) = emitFunction("wte_\(type)_\(iface)_\(sname)", ret: retTy, params: paramTys)

        let saved = beginThunk(fn)
        defer { endThunk(saved) }
        let first: UInt32 = returnsBuffer ? 2 : 1
        // The result buffer is in the caller's frame and written after the call, which may move the stack.
        let resultBuf = returnsBuffer ? markFrameAddress(LLVMGetParam(fn, 1)!) : nil

        if actorMap[type] != nil {
            // An actor's buffer holds its reference; the requirement is its handler, so the call is a send.
            let actor = LLVMBuildLoad2(b, p1, LLVMGetParam(fn, 0)!, "actor")!
            let args: [LLVMValueRef] = m.selfParams.enumerated().map { i, pt in
                let p = LLVMGetParam(fn, first + UInt32(i))!
                return pt == .selfType ? LLVMBuildLoad2(b, p1, p, "arg")! : p
            }
            guard emitActorSend(type, m.name, actor, { args }, zeroSpan) != nil else { return nil }
            LLVMBuildRetVoid(b)
            return fn
        }

        if m.isStatic, let imported = importedGenericStatic(type, m.name) {
            // The producer's compiled-once static method: as `importedGenericMethod`, without `self`.
            let isClass = classMap[type] != nil
            var callArgs: [LLVMValueRef?] = [imported.dict]
            if imported.returnsBuffer { callArgs.append(resultBuf) }
            for (i, pt) in m.selfParams.enumerated() {
                let p = LLVMGetParam(fn, first + UInt32(i))!
                callArgs.append(pt == .selfType && isClass ? LLVMBuildLoad2(b, p1, p, "arg")! : p)
            }
            guard let result = buildCall(imported.fn, imported.ty, callArgs) else { return nil }
            if imported.returnsBuffer || m.ret == .void { LLVMBuildRetVoid(b) }
            else if let resultBuf { LLVMBuildStore(b, result, resultBuf); LLVMBuildRetVoid(b) }
            else { LLVMBuildRet(b, result) }
            return fn
        }
        if m.isStatic {
            guard let (callee, calleeTy) = staticMethod(type, m) else { return nil }
            var callArgs: [LLVMValueRef?] = []
            for (i, pt) in m.selfParams.enumerated() {
                let p = LLVMGetParam(fn, first + UInt32(i))!
                guard selfSlot(pt) == .buffer else { callArgs.append(p); continue }
                guard let v = loadConformer(p, pt, type) else { return nil }
                callArgs.append(v)
            }
            guard let result = buildCall(callee, calleeTy, callArgs) else { return nil }
            if let resultBuf { LLVMBuildStore(b, result, resultBuf); LLVMBuildRetVoid(b) }
            else if m.ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, result) }
            return fn
        }
        if importedGenericMethod(type, m.name) != nil {
            // The producer's compiled-once method passes the conformer as a type parameter too, except that a generic
            // class is a reference, so only a bare `Self` of a class needs converting.
            let buffer = LLVMGetParam(fn, 0)!
            let isClass = classMap[type] != nil
            let selfArg = isClass ? LLVMBuildLoad2(b, p1, buffer, "self")! : buffer
            let args: [LLVMValueRef?] = m.selfParams.enumerated().map { i, pt in
                let p = LLVMGetParam(fn, first + UInt32(i))!
                return pt == .selfType && isClass ? LLVMBuildLoad2(b, p1, p, "arg")! : p
            }
            if m.selfRet == .selfType && isClass {
                guard let result = callImportedGeneric(type, m.name, self: selfArg, args) else { return nil }
                LLVMBuildStore(b, result, resultBuf!)
            } else if returnsBuffer {
                _ = callImportedGeneric(type, m.name, self: selfArg, args, resultBuffer: resultBuf)
            } else {
                guard let result = callImportedGeneric(type, m.name, self: selfArg, args) else { return nil }
                if m.ret != .void { LLVMBuildRet(b, result); return fn }
            }
            LLVMBuildRetVoid(b)
            return fn
        }
        declareMethod(type, m.name, requirement: (m.selfParams, m.selfRet))
        guard let c = callables["m:\(type):\(m.name)"] else { return nil }
        guard let selfArg = bridgeErasedThunkSelf(LLVMGetParam(fn, 0)!, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        for (i, pt) in m.selfParams.enumerated() {
            let p = LLVMGetParam(fn, first + UInt32(i))!
            guard selfSlot(pt) == .buffer else { callArgs.append(p); continue }
            guard let v = loadConformer(p, pt, type) else { return nil }
            callArgs.append(v)
        }
        guard let result = buildCall(c.fn, c.ty, callArgs) else { return nil }
        if let resultBuf {
            LLVMBuildStore(b, result, resultBuf)
            LLVMBuildRetVoid(b)
        } else if m.ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, result) }
        return fn
    }

    // The conformer's static method satisfying static requirement `m`, a free function `Type.method`. An imported
    // conformer's is declared from the requirement, with `Self` as the conformer.
    func staticMethod(_ type: String, _ m: NOIRMethodReq) -> (LLVMValueRef, LLVMTypeRef)? {
        // A generic instance's is the specialization of the type's generic static method, `Box.make<Int>`.
        let base = String(type.prefix { $0 != "<" })
        let name = monoTypeArgs[type] != nil ? "\(base).\(m.name)\(type.dropFirst(base.count))" : "\(type).\(m.name)"
        if funcMap[name] != nil {
            declareFree(name)
            guard let c = callables["f:\(name)"] else { return nil }
            return (c.fn, c.ty)
        }
        guard ExternalName.isEncoded(type), monoTypeArgs[type] == nil else {
            fail("static requirement '\(m.name)' of '\(type)' cannot be called through a bound in a compiled-once body yet", zeroSpan)
            return nil
        }
        if let c = callables["f:\(name)"] { return (c.fn, c.ty) }
        guard let ret = llvmType(withSelf(m.selfRet, type), zeroSpan) else { return nil }
        var params: [LLVMTypeRef] = []
        for p in m.selfParams { guard let t = llvmType(withSelf(p, type), zeroSpan) else { return nil }; params.append(t) }
        let (fn, fnTy) = emitFunction(Mangle.function(name, home: homeModule), ret: ret, params: params)
        callables["f:\(name)"] = Callable(fn: fn, ty: fnTy,
                                           ir: NOIRFunc(name: name, params: [], returnType: withSelf(m.selfRet, type), body: [],
                                                        isMutating: false, span: zeroSpan),
                                           selfType: nil, selfByPointer: false)
        return (fn, fnTy)
    }

    // An imported generic type's static method `method`, compiled once in its producer for a conformer instance
    // `type`: the declaration, the instance's dictionary, and whether the result comes back in a result buffer passed
    // after the dictionary. The declaration is cached under the key the erased call lowering uses.
    func importedGenericStatic(_ type: String, _ method: String)
        -> (fn: LLVMValueRef, ty: LLVMTypeRef, dict: LLVMValueRef, returnsBuffer: Bool)? {
        guard ExternalName.isEncoded(type), let typeArgs = monoTypeArgs[type] else { return nil }
        let symbol = "\(String(type.prefix { $0 != "<" })).\(method)"
        guard let sig = externalGenericSigs[symbol] else { return nil }
        guard let dict = dictionary(dictionaryKey(symbol, typeArgs)) else {
            fail("no dictionary for '\(symbol)' at \(typeArgs)", zeroSpan); return nil
        }
        func reference(_ t: Type) -> Bool {
            switch t {
            case .array, .function: return true
            case .generic(let base, _): return classMap[base] != nil
            default: return false
            }
        }
        let returnsBuffer = sig.ret.mentionsTypeParameter && !reference(sig.ret)
        if let c = callables["f:\(symbol)"] { return (c.fn, c.ty, dict, returnsBuffer) }
        var params = [i8ptr] + (returnsBuffer ? [i8ptr] : [])
        for p in sig.params {
            if p.mentionsTypeParameter { params.append(reference(p) ? p1 : i8ptr); continue }
            guard let t = llvmType(p, zeroSpan) else { return nil }; params.append(t)
        }
        guard let ret = returnsBuffer ? voidTy : sig.ret.mentionsTypeParameter ? p1 : llvmType(sig.ret, zeroSpan) else { return nil }
        let (fn, fnTy) = emitFunction(Mangle.function(symbol, home: homeModule), ret: ret, params: params)
        callables["f:\(symbol)"] = Callable(fn: fn, ty: fnTy,
                                           ir: NOIRFunc(name: symbol, params: [], returnType: sig.ret, body: [],
                                                        isMutating: false, span: zeroSpan),
                                           selfType: nil, selfByPointer: false)
        return (fn, fnTy, dict, returnsBuffer)
    }

    // How the compiled-once witness ABI passes a requirement type: `Self` is a type parameter there, so a type
    // mentioning it is held by buffer, unless it is a reference (an array, a function value, a generic class).
    enum SelfSlot { case plain, reference, buffer }
    func selfSlot(_ t: Type) -> SelfSlot {
        guard t.mentionsSelf else { return .plain }
        switch t {
        case .array, .function: return .reference
        case .generic(let base, _) where classMap[base] != nil: return .reference
        default: return .buffer
        }
    }

    func erasedSlotType(_ t: Type) -> LLVMTypeRef? {
        switch selfSlot(t) {
        case .plain: return llvmType(t, zeroSpan)
        case .reference: return p1
        case .buffer: return i8ptr
        }
    }

    // A value of requirement type `t` read from its buffer, with `Self` as the conformer.
    func loadConformer(_ buffer: LLVMValueRef, _ t: Type, _ type: String) -> LLVMValueRef? {
        guard let lt = llvmType(withSelf(t, type), zeroSpan) else { return nil }
        return LLVMBuildLoad2(b, lt, buffer, "conformer")
    }

    // Requirement type `t` with `Self` as the conformer, an applied generic named as its specialized instance
    // (`Option<Num>`), which Monomorphize made for the witness table (`specializeRequirementTypes`).
    func withSelf(_ t: Type, _ type: String) -> Type {
        func named(_ t: Type) -> Type {
            switch t {
            case .generic(let base, let args):
                let resolved = args.map(named)
                guard let name = monoTypeArgs.first(where: { $0.value == resolved && $0.key.hasPrefix(base + "<") })?.key
                else { return .generic(base: base, args: resolved) }
                return .named(name, namedKind(name))
            case .array(let e): return .array(named(e))
            case .function(let ps, let r): return .function(params: ps.map(named), ret: named(r))
            default: return t
            }
        }
        return named(t.replacingSelf(with: .named(type, namedKind(type))))
    }

    // The property counterpart of `methodThunkErased` — value-buffer self (offset 0). A stored-field-backed
    // requirement is a direct load/store; a computed one routes through the concrete accessor. A `Self` property is
    // read into a result buffer passed after `self` and written from a buffer.
    func propThunkErased(_ type: String, _ iface: String, _ p: NOIRPropReq, setter: Bool) -> LLVMValueRef? {
        let isSelf = selfSlot(p.selfType) == .buffer
        guard let slotTy = erasedSlotType(p.selfType), let propTy = llvmType(p.type, zeroSpan) else { return nil }
        let viaBuffer = isSelf && !setter
        var paramTys: [LLVMTypeRef] = [i8ptr]   // self — value-buffer pointer (addrspace 0)
        if setter || viaBuffer { paramTys.append(slotTy) }
        let slot = setter ? "\(p.name)_set" : "\(p.name)_get"
        let (fn, _) = emitFunction("wte_\(type)_\(iface)_\(slot)",
                                   ret: setter || viaBuffer ? voidTy : propTy, params: paramTys)
        let saved = beginThunk(fn)
        defer { endThunk(saved) }
        let valuePtr = LLVMGetParam(fn, 0)!
        // The written value, or the getter's result buffer, in the caller's frame and written after the call.
        let operand = paramTys.count > 1 ? (viaBuffer ? markFrameAddress(LLVMGetParam(fn, 1)!) : LLVMGetParam(fn, 1)!) : nil
        func newValue() -> LLVMValueRef? { isSelf ? loadConformer(operand!, p.selfType, type) : operand }
        func give(_ v: LLVMValueRef) {
            if viaBuffer { LLVMBuildStore(b, v, operand!); LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, v) }
        }

        if let info = aggInfo(type), let pos = info.fields.firstIndex(where: { $0.name == p.name }) {
            // A value conformer's fields are inline at offset 0 of the buffer; a class conformer's buffer
            // holds the object reference, so load it first and GEP the object (past its header). A setter
            // on a class field goes through the barriered `storeField`.
            let base = info.kind == .classRef ? LLVMBuildLoad2(b, p1, valuePtr, "self")! : valuePtr
            let addr = structGEP(info.ty, base, llvmFieldIndex(type, pos))
            if setter {
                guard let v = newValue() else { return nil }
                if info.kind == .classRef { storeField(base, addr, v) } else { LLVMBuildStore(b, v, addr) }
                LLVMBuildRetVoid(b)
            } else {
                guard let fieldTy = isSelf ? llvmType(withSelf(p.selfType, type), zeroSpan) : propTy else { return nil }
                give(LLVMBuildLoad2(b, fieldTy, addr, "fld"))
            }
            return fn
        }

        let accessor = "\(p.name).\(setter ? "set" : "get")"
        if importedGenericMethod(type, accessor) != nil {
            let isClass = classMap[type] != nil
            let selfArg = isClass ? LLVMBuildLoad2(b, p1, valuePtr, "self")! : valuePtr
            let bareSelf = p.selfType == .selfType
            if setter {
                let v = bareSelf && isClass ? LLVMBuildLoad2(b, p1, operand!, "arg")! : operand
                _ = callImportedGeneric(type, accessor, self: selfArg, [v])
                LLVMBuildRetVoid(b)
            } else if viaBuffer && !(bareSelf && isClass) {
                _ = callImportedGeneric(type, accessor, self: selfArg, [], resultBuffer: operand)
                LLVMBuildRetVoid(b)
            } else {
                guard let result = callImportedGeneric(type, accessor, self: selfArg, []) else { return nil }
                give(result)
            }
            return fn
        }
        declareMethod(type, accessor, requirement: setter ? ([p.selfType], .void) : ([], p.selfType))
        guard let c = callables["m:\(type):\(accessor)"] else { return nil }
        guard let selfArg = bridgeErasedThunkSelf(valuePtr, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        if setter { guard let v = newValue() else { return nil }; callArgs.append(v) }
        guard let result = buildCall(c.fn, c.ty, callArgs) else { return nil }
        if setter { LLVMBuildRetVoid(b) } else { give(result) }
        return fn
    }

    // Bridge a thunk's `payload` pointer to the impl's `self`: a by-pointer (mutating/class) method
    // takes it directly; a by-value method loads the concrete value out of it.
    func bridgeThunkSelf(_ payload: LLVMValueRef, _ type: String, _ c: Callable) -> LLVMValueRef? {
        if c.selfByPointer {
            // A class/actor impl takes the managed object pointer directly. A struct/enum mutating impl
            // takes an addrspace(0) pointer to a stack-ABI value, so cast the value slot (past the box
            // header) down.
            if classMap[type] != nil || actorMap[type] != nil { return payload }
            return toUnmanaged(payloadValue(payload))
        }
        guard let st = selfLLVMType(type) else { return nil }
        return LLVMBuildLoad2(b, st, payloadValue(payload), "self")   // value payload: value is past the header
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

        if actorMap[type] != nil {
            // An actor's payload is its reference; the requirement is its handler, so the call is a send.
            let args = (0..<m.params.count).map { LLVMGetParam(fn, UInt32($0 + 1))! }
            guard emitActorSend(type, m.name, LLVMGetParam(fn, 0)!, { args }, zeroSpan) != nil else { return nil }
            LLVMBuildRetVoid(b)
            return fn
        }
        let covariant: Bool = { if case .existential = m.ret { return true }; return false }()
        if importedGenericMethod(type, m.name) != nil {
            // The copy out of the box, its root node and a result buffer make a frame too large to run unchecked.
            if !isRuntimePackage && !measureNoStackChecks { emitStackCheck([]) }
            let args = (0..<m.params.count).map { LLVMGetParam(fn, UInt32($0 + 1)) }
            let payload = LLVMGetParam(fn, 0)!
            if covariant {
                // The compiled-once method returns the conformer in a result buffer, a class as its reference;
                // re-box it as `any iface`.
                var value: LLVMValueRef
                if classMap[type] != nil {
                    guard let r = callImportedGenericBoxed(type, m.name, payload: payload, args) else { return nil }
                    value = r
                } else {
                    guard let st = selfLLVMType(type) else { return nil }
                    let buf = entryAlloca(st, "ret.buf")
                    _ = callImportedGenericBoxed(type, m.name, payload: payload, args, resultBuffer: buf)
                    value = LLVMBuildLoad2(b, st, buf, "ret")!
                }
                guard let w = witnessInstance(type, iface),
                      let pl = boxPayload({ value }, .named(type, namedKind(type))) else { return nil }
                LLVMBuildRet(b, makeAnyBox(w, pl))
                return fn
            }
            guard let result = callImportedGenericBoxed(type, m.name, payload: payload, args) else { return nil }
            if m.ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, result) }
            return fn
        }
        declareMethod(type, m.name, requirement: (m.params, m.ret))
        guard let c = callables["m:\(type):\(m.name)"] else { return nil }
        guard let selfArg = bridgeThunkSelf(LLVMGetParam(fn, 0)!, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        for i in 0..<m.params.count { callArgs.append(LLVMGetParam(fn, UInt32(i + 1))) }
        guard let result = buildCall(c.fn, c.ty, callArgs) else { return nil }

        if case .existential = m.ret {
            // Covariant `Self`: the impl returns the concrete conformer; re-box it as `any iface`.
            guard let w = witnessInstance(type, iface),
                  let pl = boxPayload({ result }, .named(type, namedKind(type))) else { return nil }
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
            // A struct value payload's fields start past the box's 8-byte header; a class payload is the
            // object itself (header at 0, which `llvmFieldIndex` steps past).
            let base = info.kind == .classRef ? payload : payloadValue(payload)
            let addr = structGEP(info.ty, base, llvmFieldIndex(type, pos))
            if setter {
                storeField(payload, addr, LLVMGetParam(fn, 1)!)
                LLVMBuildRetVoid(b)
            } else {
                LLVMBuildRet(b, LLVMBuildLoad2(b, propTy, addr, "fld"))
            }
            return fn
        }

        let accessor = "\(p.name).\(setter ? "set" : "get")"
        if importedGenericMethod(type, accessor) != nil {
            let result = callImportedGenericBoxed(type, accessor, payload: payload, setter ? [LLVMGetParam(fn, 1)] : [])
            if setter { LLVMBuildRetVoid(b) } else if let result { LLVMBuildRet(b, result) } else { return nil }
            return fn
        }
        declareMethod(type, accessor, requirement: setter ? ([p.type], .void) : ([], p.type))
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

    // Whether an `any` box of `type` copies the value into a payload object; a class or actor is its own payload.
    func boxIsValue(_ type: String) -> Bool { classMap[type] == nil && actorMap[type] == nil }

    // Which interface of a composition declares `method` (used to pick the owning sub-table).
    func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        for i in ifaces where witnessSlots(i).contains(slot) { return i }
        return ifaces.first ?? "?"
    }

    // The `any I` payload for a value: a reference type is its pointer; a value type is copied to a
    // fresh managed allocation so the pointer outlives the temporary.
    // `v` is called after the payload's allocation, so a shaped value is read from its home once a collection
    // there has run.
    func boxPayload(_ v: () -> LLVMValueRef, _ t: Type) -> LLVMValueRef? {
        switch t {
        case .named(_, .class_), .named(_, .actor_):
            return v()
        default:
            // A value payload is a proper GC object `{ header, value }`: type-id header at offset 0, value
            // at offset 8, carrying the value's managed-pointer map (valueBoxTypeId). Header-less, a moving
            // collection reads the value's first word as a bogus type-id and mis-scans/mis-copies the
            // payload. Readers reach the value at payload+8 (payloadValue, used by bridgeThunkSelf and propThunk).
            let p = rtAllocManaged(LLVMConstInt(i64, UInt64(valueBoxSize(t)), 0))
            writeTypeIdHeaderRaw(p, valueBoxTypeId(t))
            LLVMBuildStore(b, v(), payloadValue(p))
            return p
        }
    }

    // The value slot of a value-payload box (`{ header, value }`) — the byte past the 8-byte header. Only
    // value (struct/enum) payloads carry this header; a class/actor payload is the object itself.
    func payloadValue(_ payload: LLVMValueRef) -> LLVMValueRef {
        gepByte(payload, LLVMConstInt(i64, 8, 0))
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
        LLVMBuildStore(b, descOffsetHeader(anyBoxTypeId()), structGEP(anyBoxTy, box, 0)) // header
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

    // The erased-generic counterpart of `witnessDispatch` (task 100.4.3.3.3; backend.md §4): the witness
    // table is the PWT pointer passed to an erased body, and `self` is the value-buffer pointer
    // (addrspace 0), not a heap box. The slot holds an **erased** thunk (`witnessInstanceErased`) whose
    // self-ABI is that value pointer, so the two agree without touching the existential (`any I`) path.
    // `resultBuffer` receives a result held by buffer (`slotReturnsBuffer`); the call then returns nothing.
    func witnessDispatchErased(pwt: LLVMValueRef, iface: String, method: String, selfPtr: LLVMValueRef,
                               argVals: [LLVMValueRef], argTys: [LLVMTypeRef], resultType: Type,
                               resultBuffer: LLVMValueRef? = nil, span: Span) -> LLVMValueRef? {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        let idx = witnessSlotIndex(iface, slot)
        guard idx >= 0 else { fail("8.2.5: no witness slot '\(slot)' in '\(iface)'", span); return nil }
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(iface), pwt, idx), "slot")!
        guard let retTy = resultBuffer != nil ? voidTy : llvmType(resultType, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]   // self — a value-buffer pointer (addrspace 0)
        var callArgs: [LLVMValueRef?] = [selfPtr]
        if let resultBuffer { paramTys.append(i8ptr); callArgs.append(resultBuffer) }
        paramTys.append(contentsOf: argTys)
        for v in argVals { callArgs.append(v) }
        return buildCall(fnPtr, fnType(retTy, paramTys), callArgs)
    }

    // Whether requirement `method` of `iface` (a method, or a property's `name.get`) returns a type mentioning `Self`
    // held by buffer, which the compiled-once witness ABI returns in a result buffer.
    func slotReturnsBuffer(_ iface: String, _ method: String) -> Bool {
        guard let i = interfaceDefs[iface] else { return false }
        if let m = i.methods.first(where: { $0.name == method }) { return selfSlot(m.selfRet) == .buffer }
        guard method.hasSuffix(".get"), let p = i.properties.first(where: { $0.name == String(method.dropLast(4)) })
        else { return false }
        return selfSlot(p.selfType) == .buffer
    }

    // MARK: - Imported generic conformers

    // A method of an instance of an imported generic type is compiled once in its producer, behind the witness ABI
    // (`m:<origin@Type>:method`): its dictionary for the instance's type arguments, then `self` by buffer (a class by
    // reference), then the arguments. A requirement's arguments and result mention the conformer's type parameters
    // only as `Self`, the instance itself. Nil when `type` is no such instance. The declaration is cached under the key
    // the erased call lowering uses, so the two share it.
    func importedGenericMethod(_ type: String, _ method: String) -> (fn: LLVMValueRef, ty: LLVMTypeRef, dict: LLVMValueRef)? {
        guard ExternalName.isEncoded(type), let typeArgs = monoTypeArgs[type] else { return nil }
        let symbol = "m:\(String(type.prefix { $0 != "<" })):\(method)"
        guard let sig = externalGenericSigs[symbol] else { return nil }
        guard let dict = dictionary(dictionaryKey(symbol, typeArgs)) else {
            fail("no dictionary for '\(symbol)' at \(typeArgs)", zeroSpan); return nil
        }
        if let c = callables["f:\(symbol)"] { return (c.fn, c.ty, dict) }
        // A result that mentions the type's parameters, `Self` for a value conformer, comes back in a result buffer
        // passed after the dictionary; a generic class is a reference and returns as one.
        let isClass = classMap[type] != nil
        let returnsBuffer = sig.ret.mentionsTypeParameter && !isClass
        var params = [i8ptr] + (returnsBuffer ? [i8ptr] : []) + [isClass ? p1 : i8ptr]
        for p in sig.params.dropFirst() {
            if p.mentionsTypeParameter { params.append(isClass ? p1 : i8ptr); continue }
            guard let t = llvmType(p, zeroSpan) else { return nil }; params.append(t)
        }
        guard let ret = returnsBuffer ? voidTy : sig.ret.mentionsTypeParameter ? p1 : llvmType(sig.ret, zeroSpan) else { return nil }
        let base = String(type.prefix { $0 != "<" })
        let (fn, fnTy) = emitFunction(Mangle.method(base, method, home: homeModule), ret: ret, params: params)
        callables["f:\(symbol)"] = Callable(fn: fn, ty: fnTy,
                                           ir: NOIRFunc(name: symbol, params: [], returnType: sig.ret, body: [], isMutating: false,
                                                        span: zeroSpan),
                                           selfType: nil, selfByPointer: false)
        return (fn, fnTy, dict)
    }

    // Call `method` of an imported generic instance from a thunk, with `self` a value buffer (addrspace 0) or, for a
    // class, the reference. The caller of the thunk roots the buffer.
    // `resultBuffer` receives a result held by buffer, a value conformer returned as `Self`.
    func callImportedGeneric(_ type: String, _ method: String, self selfArg: LLVMValueRef, _ args: [LLVMValueRef?],
                             resultBuffer: LLVMValueRef? = nil) -> LLVMValueRef? {
        guard let m = importedGenericMethod(type, method) else { return nil }
        return buildCall(m.fn, m.ty, [m.dict] + (resultBuffer.map { [$0] } ?? []) + [selfArg] + args)
    }

    // The same from a boxed thunk: a value conformer is copied out of the box into a frame buffer, registered as a
    // typed root around the call, since the box may move while the call runs; a class conformer is its reference.
    func callImportedGenericBoxed(_ type: String, _ method: String, payload: LLVMValueRef, _ args: [LLVMValueRef?],
                                  resultBuffer: LLVMValueRef? = nil) -> LLVMValueRef? {
        if classMap[type] != nil { return callImportedGeneric(type, method, self: payload, args) }
        guard let st = selfLLVMType(type) else { return nil }
        let buf = entryAlloca(st, "self.buf")
        LLVMBuildStore(b, LLVMBuildLoad2(b, st, payloadValue(payload), "self")!, buf)
        let save = preludeFn("nomu_fn_rtShadowSave", ret: i64, params: [])
        let top = buildCall(save.0, save.1, [])!
        let push = preludeFn("nomu_fn_rtShadowPush", ret: voidTy, params: [i8ptr, i8ptr, i8ptr])
        let node = entryAlloca(structTy([i8ptr, i8ptr, i8ptr]), "shadow.node")
        _ = buildCall(push.0, push.1, [node, buf, valueWitness(.named(type, namedKind(type)))])
        let result = callImportedGeneric(type, method, self: buf, args, resultBuffer: resultBuffer)
        let pop = preludeFn("nomu_fn_rtShadowPopTo", ret: voidTy, params: [i64])
        _ = buildCall(pop.0, pop.1, [top])
        return result
    }

    // MARK: - Thunk emit scope

    // Emit-position save/restore for building a witness thunk mid-body: the thunk is a fresh function,
    // so its entry block + debug scope are swapped in and the enclosing builder position restored on
    // exit. Only emission position moves — the tree-walk's local/self/fiber state (owned by the walker,
    // untouched by thunk bodies) stays put, so this is lighter than the walker's closure/fiber
    // `enterThunk`. Both egresses build witness thunks, so it lives here.
    struct EmitScope {
        let block: LLVMBasicBlockRef?
        let fn: LLVMValueRef?
        let scope: LLVMMetadataRef?
        let debugLoc: LLVMMetadataRef?
        let deopt: [LLVMValueRef?]?
    }

    // The caller's pending shaped-root bundle is set aside too: its slots live in the caller, so a call in the
    // thunk must not carry it.
    func beginThunk(_ fn: LLVMValueRef, line: Int = 0) -> EmitScope {
        let saved = EmitScope(block: LLVMGetInsertBlock(b), fn: currentFn, scope: currentScope,
                              debugLoc: di != nil ? LLVMGetCurrentDebugLocation2(b) : nil, deopt: pendingDeopt)
        currentFn = fn
        pendingDeopt = nil
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        enterDebugScope(fn, line: line)
        return saved
    }

    func endThunk(_ saved: EmitScope) {
        currentFn = saved.fn
        pendingDeopt = saved.deopt
        if let block = saved.block { LLVMPositionBuilderAtEnd(b, block) }
        currentScope = saved.scope
        if di != nil { LLVMSetCurrentDebugLocation2(b, saved.debugLoc) }
    }
}
