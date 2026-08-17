import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Witness tables + `any`/`some` (8.2.5)

    // The witness/composite-table + `any`-box machinery moved to LLVMGen (LLVMGenWitness.swift) — the
    // conformance ABI, shared across both egresses. `witnessDispatch`/`lowerBox` below stay on the
    // tree-walk (they lower NOIR exprs via `lowerExpr`) and reach the moved primitives through these
    // forwarders; the forwarders retire with this path.
    func concreteUnderlying(_ t: Type) -> Type { e.concreteUnderlying(t) }
    func witnessType(_ iface: String) -> LLVMTypeRef { e.witnessType(iface) }
    func witnessSlotIndex(_ iface: String, _ slot: String) -> Int { e.witnessSlotIndex(iface, slot) }
    func witnessInstance(_ type: String, _ iface: String) -> LLVMValueRef? { e.witnessInstance(type, iface) }
    func compositeType(_ ifaces: [String]) -> LLVMTypeRef { e.compositeType(ifaces) }
    func compositeInstance(_ type: String, _ ifaces: [String]) -> LLVMValueRef? { e.compositeInstance(type, ifaces) }
    func compositionOwner(_ ifaces: [String], _ method: String) -> String { e.compositionOwner(ifaces, method) }
    func boxPayload(_ v: LLVMValueRef, _ t: Type) -> LLVMValueRef? { e.boxPayload(v, t) }
    func makeAnyBox(_ witness: LLVMValueRef, _ payload: LLVMValueRef) -> LLVMValueRef { e.makeAnyBox(witness, payload) }
    func anyBoxWitness(_ box: LLVMValueRef) -> LLVMValueRef { e.anyBoxWitness(box) }
    func anyBoxPayload(_ box: LLVMValueRef) -> LLVMValueRef { e.anyBoxPayload(box) }

    // Walker glue: lower a requirement call's argument exprs (with their LLVM types), then dispatch
    // through the witness slot (the emission core is on LLVMGen, over already-lowered operands).
    func witnessDispatch(witnessPtr: LLVMValueRef, iface: String, method: String,
                                 payload: LLVMValueRef, args: [NOIRExpr], resultType: Type,
                                 span: Span) -> LLVMValueRef? {
        var argVals: [LLVMValueRef] = []
        var argTys: [LLVMTypeRef] = []
        for a in args {
            guard let t = llvmType(a.type, span), let v = lowerExpr(a) else { return nil }
            argTys.append(t); argVals.append(v)
        }
        return e.witnessDispatch(witnessPtr: witnessPtr, iface: iface, method: method, payload: payload,
                                 argVals: argVals, argTys: argTys, resultType: resultType, span: span)
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
    // `Capture` is now a top-level typealias (LLVMGen.swift).

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
