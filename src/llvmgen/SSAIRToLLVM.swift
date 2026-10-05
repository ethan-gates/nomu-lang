import sema

import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// M7 · 7.2.3 — the SSAIR → LLVM egress, the sole backend path since M7.7. A CFG-walk that holds one
// `LLVMGen` and lowers through its GC-ABI primitives (object layout / alloc / barrier / witness / actor
// ABI emitted from one place, §7.0.4). SSAIR supplies a CFG with block arguments and SSA values, so
// this egress maps blocks 1:1 (block args → LLVM φ) and keeps SSA values in a per-function id→value
// table with no per-scalar spill. (`LLVMGen` was factored out as a shared emitter while the retired
// NOIR tree-walk still co-existed; it now serves this egress alone.)
//
// Type-layout + witness + actor metadata come from the original NOIR module (populated into `LLVMGen`),
// plus the closure/spawn environment aggregates the SSA module synthesized. Function *declaration* is
// done here (the `m:Type:method` → `nomu_m_*` mangling); the
// shared witness/actor thunks find the resulting callables already declared, so their internal
// `declareMethod`/`declareActorHandler` calls early-return without needing NOIR method bodies.
final class SSAIRToLLVM {
    let e: LLVMGen

    // Per-function state, reset in `defineFunction`.
    var values: [Int: LLVMValueRef] = [:]          // SSAValue.id → LLVM value
    var blockMap: [Int: LLVMBasicBlockRef] = [:]   // SSABlock.id → LLVM basic block
    var blocksById: [Int: SSABlock] = [:]          // SSABlock.id → the block (for edge φ wiring)
    // φ incomings, deferred until every block's instructions are lowered: a branch argument may be
    // defined in a block that lowers after the branch's block (e.g. a loop latch whose block id
    // precedes the case block that computes the carried value), so resolving `val(arg)` eagerly would
    // miss it. Captured at terminator time (the predecessor is the current block), wired at the end.
    var pendingIncomings: [(phi: LLVMValueRef, pred: LLVMBasicBlockRef, arg: SSAValue)] = []
    var spawnHandles: [Int: LLVMValueRef] = [:]    // spawn binding id → its handle alloca

    // Erased generic ABI (backend.md §4), set in `defineFunction` for an erased generic (non-empty
    // `generics`) and read when lowering its body. `curVWTParams` maps a type-parameter name to its VWT
    // pointer parameter; `curPWTParams` maps "T::iface" to the PWT pointer parameter for that bound
    // (used to dispatch a requirement call on a `.typeParam` receiver); `curSretParam` is the
    // caller-allocated result buffer; `curReturnVWT` is the VWT for the returned type parameter (sizing
    // the move memcpy). All empty/nil for a normal (fully-concrete) function.
    var curVWTParams: [String: LLVMValueRef] = [:]
    var curPWTParams: [String: LLVMValueRef] = [:]
    var curSretParam: LLVMValueRef?
    var curReturnType: Type?   // an erased function's return type (mentions a type parameter); sizes the `ret` move

    // Producer-internal typed GC roots (task 100.4.3.6). When an erased body *constructs* a composed
    // value with a `T` field (`makeStruct`/`makeEnum` → `erased.box`/`erased.enum`), that `T` lives in an
    // opaque byte buffer the stackmap can't see into, so the buffer's `T`-component must be registered on
    // the fiber's shadow stack for as long as the composed value is live — else a collection while it is
    // live across an allocation would strand or dangle the managed pointers inside it. `curProducerSave`
    // is the shadow-top captured in the erased prologue (nil when the frame constructs no such value); the
    // epilogue `rtShadowPopTo`s it before every `ret`, so the frame's pushes unwind on any exit. A POD `T`
    // is registered too — its VWT descriptor reports no managed pointers, so the walk expands it to
    // nothing (correct, a little redundant).
    //
    // Loop constructions (hazard (b) in the milestone doc) use a loop-scoped save: each loop header saves
    // the shadow-top into `headerSaveSlot[header]`, and every back-edge `rtShadowPopTo`s that save before
    // branching, so an iteration's pushes are cleared before the next iteration re-pushes the same
    // entry-hoisted nodes — without the pop the re-push would make a node's `prev` point at itself.
    // `curBackEdges` maps a block to the header it back-branches to.
    var curProducerSave: LLVMValueRef?
    var curBackEdges: [Int: Int] = [:]
    var headerSaveSlot: [Int: LLVMValueRef] = [:]
    var curBlockId: Int = -1

    // The erased ABI's PWT parameters (backend.md §4), in fixed order: one per (type parameter, bound),
    // type parameters in declaration order and bounds name-sorted — the identical order the producer
    // declares and the consumer threads, so they line up across the boundary.
    private func erasedPWTs(_ f: SSAFunction) -> [(param: String, iface: String)] {
        f.generics.flatMap { gp in gp.bounds.sorted().map { (gp.name, $0) } }
    }

    // Derived-VWT layout (task 100.4.3.3.4; backend.md §4). The value layout is the uniform 8-byte-slot
    // model, so a composed type's size is the sum of its fields' sizes with no alignment padding, and a
    // field's offset is the running sum of the sizes before it. A type parameter's size is read from its
    // VWT (runtime); a concrete type's from its static slot count. Enums are deferred (their tagged
    // layout differs); only struct-composed types are synthesized here.
    private func erasedTypeSize(_ t: Type, _ span: Span) -> LLVMValueRef? {
        switch t {
        case .typeParam(let name):
            guard let vwt = curVWTParams[name] else {
                e.fail("100.4.3.3.4: no VWT for type parameter '\(name)'", span); return nil
            }
            let sizeField = e.structGEP(e.valueWitnessType(), vwt, 0)
            let s32 = LLVMBuildLoad2(b, e.i32, sizeField, "vwtsize")
            return LLVMBuildZExt(b, s32, e.i64, "vwtsize64")
        case .generic(let base, let args):
            if let s = e.structMap[base] {
                let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
                var total = LLVMConstInt(e.i64, 0, 0)!
                for f in s.fields {
                    guard let fs = erasedTypeSize(substType(f.type, subst), span) else { return nil }
                    total = LLVMBuildAdd(b, total, fs, "sz")!
                }
                return total
            }
            if let en = e.enumMap[base] {
                // Tagged layout: one tag word, then a payload region sized to the largest case (task
                // 100.4.3.3.4). Each case's payload size is a prefix sum of its field sizes; the max is a
                // runtime select chain, since a `T`-carrying case's size is only known via the VWT.
                let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
                var maxPayload = LLVMConstInt(e.i64, 0, 0)!
                for c in en.cases {
                    var caseSize = LLVMConstInt(e.i64, 0, 0)!
                    for f in c.fields {
                        guard let fs = erasedTypeSize(substType(f.type, subst), span) else { return nil }
                        caseSize = LLVMBuildAdd(b, caseSize, fs, "csz")!
                    }
                    let bigger = LLVMBuildICmp(b, LLVMIntUGT, caseSize, maxPayload, "big")!
                    maxPayload = LLVMBuildSelect(b, bigger, caseSize, maxPayload, "maxpl")!
                }
                return LLVMBuildAdd(b, LLVMConstInt(e.i64, 8, 0), maxPayload, "enumsz")!   // tag + payload
            }
            e.fail("100.4.3.3.4: no layout for generic '\(base)'", span); return nil
        default:
            return LLVMConstInt(e.i64, UInt64(e.slotCount(t) * 8), 0)
        }
    }

    // The runtime byte offset of field `fieldIndex` in a struct-composed generic — the running sum of
    // the sizes of the fields before it (8-byte-slot model, no padding).
    private func erasedFieldOffset(_ composed: Type, _ fieldIndex: Int, _ span: Span) -> LLVMValueRef? {
        guard case .generic(let base, let args) = composed else { return LLVMConstInt(e.i64, 0, 0) }
        // A struct value buffer starts at offset 0; a **class** object (reference receiver, task 100.4.3.9)
        // starts its user fields past the 8-byte i64 object header. Either way the running offset is the
        // VWT-derived sum of prior field sizes.
        let generics: [NOIRGenericParam], fields: [NOIRField], header: UInt64
        if let s = e.structMap[base] { generics = s.generics; fields = s.fields; header = 0 }
        else if let c = e.classMap[base] { generics = c.generics; fields = c.fields; header = 8 }
        else { return LLVMConstInt(e.i64, 0, 0) }
        let subst = Dictionary(uniqueKeysWithValues: zip(generics.map(\.name), args))
        var off = LLVMConstInt(e.i64, header, 0)!
        for j in 0..<min(fieldIndex, fields.count) {
            guard let fs = erasedTypeSize(substType(fields[j].type, subst), span) else { return nil }
            off = LLVMBuildAdd(b, off, fs, "off")!
        }
        return off
    }

    // The runtime byte offset of payload field `fieldIndex` of case `caseIndex` in an erased generic
    // enum: past the tag word (offset 8), then the running sum of the case's prior field sizes.
    private func erasedEnumPayloadOffset(_ base: String, _ args: [Type], _ caseIndex: Int, _ fieldIndex: Int, _ span: Span) -> LLVMValueRef? {
        guard let en = e.enumMap[base], caseIndex < en.cases.count else { return LLVMConstInt(e.i64, 8, 0) }
        let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
        let fields = en.cases[caseIndex].fields
        var off = LLVMConstInt(e.i64, 8, 0)!   // past the tag word
        for j in 0..<min(fieldIndex, fields.count) {
            guard let fs = erasedTypeSize(substType(fields[j].type, subst), span) else { return nil }
            off = LLVMBuildAdd(b, off, fs, "poff")!
        }
        return off
    }

    // Substitute a composed type's template type-parameter names with its actual arguments.
    private func substType(_ t: Type, _ s: [String: Type]) -> Type {
        switch t {
        case .typeParam(let p): return s[p] ?? t
        case .generic(let b, let a): return .generic(base: b, args: a.map { substType($0, s) })
        case .array(let e): return .array(substType(e, s))
        case .ptr(let e): return .ptr(substType(e, s))
        case .function(let ps, let r): return .function(params: ps.map { substType($0, s) }, ret: substType(r, s))
        default: return t
        }
    }

    var loweredMain = false
    var error: String? { e.error }

    init(ctx: LLVMContextRef, mod: LLVMModuleRef) {
        self.e = LLVMGen(ctx: ctx, mod: mod)
    }

    // MARK: - Convenience accessors over the shared emitter

    var b: LLVMBuilderRef { e.b }
    var ctx: LLVMContextRef { e.ctx }
    func ty(_ t: Type, _ span: Span) -> LLVMTypeRef? { e.llvmType(t, span) }

    // The LLVM storage type for a `stackAlloc` slot. For a value aggregate `llvmType` is already the
    // storage (the struct/enum value); for a **stack-promoted** class/actor the slot must hold the
    // object struct `{ header, fields… }`, not the `p1` `llvmType` gives a reference — the slot is an
    // addrspace(0) pointer to that struct, and `fieldAddr` GEPs past the header like a heap object.
    func storageType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        if case .named(let n, let k) = t {
            switch k {
            case .class_: return e.classType(n)
            case .actor_: return e.actorType(n)
            default: break
            }
        }
        return ty(t, span)
    }

    var curFnName = ""
    // Every SSA value is defined before use (SSA dominance) and every def maps here, so a miss is an
    // egress bug, not user error — report it as a compile error (a null placeholder keeps lowering from
    // trapping; the error aborts the emit before the module is used).
    func val(_ v: SSAValue) -> LLVMValueRef {
        if let x = values[v.id] { return x }
        e.fail("7.2.3: internal — unmapped SSA value id=\(v.id) (\(v.type)) in '\(curFnName)'", e.zeroSpan)
        return LLVMConstNull(e.i8ptr)
    }

    // MARK: - Entry

    // Lower a whole SSA module. `noirModule` supplies the NOIR-shaped type/witness metadata the shared
    // layout/witness/actor primitives read (the SSA module keeps only logical field indices); the SSA
    // module supplies every function body plus the synthesized closure/spawn env aggregates.
    func lower(_ module: SSAModule, from noirModule: NOIRModule) {
        // Type + witness registries — mirror `NOIRToLLVM.lower`.
        for i in noirModule.interfaces { e.interfaceDefs[i.name] = i }
        e.opaqueUnderlyings = noirModule.opaqueUnderlyings
        e.monoTypeArgs = noirModule.monoTypeArgs
        for decl in noirModule.decls {
            switch decl {
            case .funcDecl(let f):   e.funcMap[f.name] = f
            case .structDecl(let s): e.structMap[s.name] = s
            case .enumDecl(let en):  e.enumMap[en.name] = en
            case .classDecl(let c):  e.classMap[c.name] = c
            case .actorDecl(let a):  e.actorMap[a.name] = a
            }
        }
        // Synthesized closure/spawn environment layouts live only in the SSA module — register them as
        // classes so `classType`/`aggInfo`/`typeId` can lay them out and scan their captured fields.
        for agg in module.aggregates where e.classMap[agg.name] == nil && agg.kind == .class_ {
            e.classMap[agg.name] = NOIRClass(
                name: agg.name,
                fields: agg.fields.map { NOIRField(name: $0.name, type: $0.type, isMutable: $0.isMutable, span: agg.span) },
                methods: [], span: agg.span)
        }

        // A library module has no `main`; debug info still needs a source file, so fall back to the first
        // function's. Only the entry object requires `main` (checked by the driver via `loweredMain`).
        if let anyFn = module.functions.first(where: { $0.name == "main" }) ?? module.functions.first {
            e.setupDebugInfo(sourceFile: anyFn.span.file)
        }

        for f in module.functions { declareFunction(f) }
        for f in module.functions {
            if error != nil { break }
            defineFunction(f)
        }

        // Value-witness tables for monomorphized generic value-type instantiations (task 100.4.3.2;
        // instantiation names carry `<…>`). The erased path (100.4.3.3+) additionally emits VWTs on
        // demand for the concrete type arguments at call sites; emitting the module's generic value types
        // here exercises the VWT capability (unreferenced ones dead-strip).
        for name in e.structMap.keys.sorted() where name.contains("<") { e.valueWitness(.named(name, .struct_)) }
        for name in e.enumMap.keys.sorted() where name.contains("<") { e.valueWitness(.named(name, .enum_)) }

        // The link-time offset-as-id descriptor section (task 100.4.7): every module emits its own
        // types' descriptors, weak duplicates folding at link — so a dependency's heap types are all
        // present at the section the runtime reads via `getsectiondata`.
        e.emitDescriptors()
        if let dib = e.di {
            LLVMDIBuilderFinalize(dib)
            LLVMDisposeDIBuilder(dib)
            e.di = nil
        }
        if error == nil { loweredMain = e.callables["f:main"] != nil }
    }

    // MARK: - Declaration (the callable-key / symbol mangling)

    // The callable key + method receiver info for an SSA function. Free functions key `f:<name>`
    // (closures/spawn routines are `f:clo:N` / `f:spawn:N`); methods and actor handlers key
    // `m:<type>:<method>` — matching the `.direct`/`.witness` call names ssairgen emits.
    private func keyAndSelf(_ f: SSAFunction) -> (key: String, selfType: String?, byPointer: Bool, symbol: String) {
        // The origin qualifier is the module this function is *defined* in (task 100.4); it must match
        // the on-demand declaration in `LLVMGenCallables`, which derives it the same way from the file.
        let qualifier = e.definitionQualifier(forFile: f.span.file)
        guard f.name.hasPrefix("m:") else {
            return ("f:\(f.name)", nil, false, Mangle.free(f.name, qualifier: qualifier))
        }
        let rest = f.name.dropFirst(2)
        let colon = rest.firstIndex(of: ":")!
        let type = String(rest[rest.startIndex..<colon])
        let method = String(rest[rest.index(after: colon)...])
        let isActor = e.actorMap[type] != nil
        let isReference = e.classMap[type] != nil || isActor
        let byPointer = isReference || f.isMutating
        let symbol = isActor ? Mangle.actorHandler(type, method, qualifier: qualifier)
                             : Mangle.method(type, method, qualifier: qualifier)
        return ("m:\(f.name.dropFirst(2))", type, byPointer, symbol)
    }

    // Distinct residual type-parameter names in a function's signature, in first-appearance order
    // (params then return). Non-empty ⇒ the function is an **erased** generic (backend.md §4): mono
    // substitutes every type parameter away in a monomorphized decl, so a residual `.typeParam` only
    // survives in a public generic's erased copy (100.4.3.3).
    private func signatureTypeParams(_ f: SSAFunction) -> [String] {
        var out: [String] = []
        for p in f.params { collectTypeParams(p.type, into: &out) }
        collectTypeParams(f.returnType, into: &out)
        return out
    }

    private func collectTypeParams(_ t: Type, into out: inout [String]) {
        switch t {
        case .typeParam(let p): if !out.contains(p) { out.append(p) }
        case .generic(_, let args): for a in args { collectTypeParams(a, into: &out) }
        case .array(let e): collectTypeParams(e, into: &out)
        case .ptr(let e): collectTypeParams(e, into: &out)
        case .function(let ps, let r): for p in ps { collectTypeParams(p, into: &out) }; collectTypeParams(r, into: &out)
        default: break
        }
    }

    private func mentionsTypeParam(_ t: Type) -> Bool {
        var tmp: [String] = []; collectTypeParams(t, into: &tmp); return !tmp.isEmpty
    }

    // Create the LLVM function for `f` and register it in `callables` with the ABI-correct signature —
    // the self ABI (by-pointer for a class/actor/mutating receiver, else by value) mirrors
    // `declareCallable`, so a witness/actor thunk built later dispatches through a matching signature.
    private func declareFunction(_ f: SSAFunction) {
        let (key, selfType, byPointer, symbol) = keyAndSelf(f)
        if e.callables[key] != nil { return }
        if !f.generics.isEmpty { declareErasedFunction(f, key: key, symbol: symbol); return }
        guard let retTy = ty(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        var rest = f.params
        if let selfType = selfType {
            guard let st = e.selfLLVMType(selfType) else { return }
            let isReference = e.classMap[selfType] != nil || e.actorMap[selfType] != nil
            if byPointer {
                paramTys.append(isReference ? e.p1 : LLVMPointerType(st, 0)!)
            } else {
                paramTys.append(st)
            }
            rest = Array(f.params.dropFirst())
        }
        for p in rest {
            guard let t = ty(p.type, f.span) else { return }
            paramTys.append(t)
        }
        // A lifted `spawn:N` routine's env crosses the fiber (C) boundary as a runtime-held `void*`, so
        // its env parameter is addrspace(0) — like the NOIR spawn routine — not the managed `p1` its
        // class type would give. Keeping it addr0 avoids a 0→1 addrspacecast the GC statepoint rewriter
        // rejects; the captured-field loads GEP off the addr0 pointer and reload each managed capture as
        // its own root. (Closures never cross the boundary, so their env stays `p1`.)
        if f.name.hasPrefix("spawn:"), !paramTys.isEmpty { paramTys[0] = e.i8ptr }
        let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys,
                                        debug: (f.name, f.span.begin.line))
        // Prelude functions are compiled into every module's object (interim, task 100.3.7); weak
        // linkage lets the linker fold the duplicate definitions to one.
        if e.weakOriginFiles.contains(f.span.file) { LLVMSetLinkage(fn, LLVMWeakODRLinkage) }
        let dummy = NOIRFunc(name: f.name, params: [], returnType: f.returnType,
                             body: [], isMutating: f.isMutating, span: f.span)
        e.callables[key] = Callable(fn: fn, ty: fnTy, ir: dummy,
                                    selfType: selfType, selfByPointer: byPointer)
    }

    // Declare a public generic's **erased** copy under the witness-passing ABI (backend.md §4). Hidden
    // leading parameters, in the fixed order: (1) one VWT pointer per type parameter, in declaration
    // order; (2) one PWT pointer per (type parameter, bound), bounds name-sorted; (3) a result buffer
    // (sret-style) when the return type mentions a type parameter. Then the value parameters, each
    // `.typeParam`-typed one passed indirectly as a `ptr` to a caller-allocated buffer. A method
    // (`m:` prefix) with residual type parameters would also need self handling — not reached, since
    // only free generic functions are emitted erased today.
    private func declareErasedFunction(_ f: SSAFunction, key: String, symbol: String) {
        let returnsTP = mentionsTypeParam(f.returnType)
        var paramTys: [LLVMTypeRef] = []
        for _ in f.generics { paramTys.append(e.i8ptr) }        // (1) VWT pointer per type parameter
        for _ in erasedPWTs(f) { paramTys.append(e.i8ptr) }     // (2) PWT pointer per (type parameter, bound)
        if returnsTP { paramTys.append(e.i8ptr) }               // (3) result buffer (sret)
        for p in f.params {                                     // value parameters (a `T` value is a ptr)
            guard let t = ty(p.type, f.span) else { return }
            paramTys.append(t)
        }
        let retTy: LLVMTypeRef
        if returnsTP {
            retTy = e.voidTy
        } else {
            guard let r = ty(f.returnType, f.span) else { return }
            retTy = r
        }
        let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys,
                                        debug: (f.name, f.span.begin.line))
        if e.weakOriginFiles.contains(f.span.file) { LLVMSetLinkage(fn, LLVMWeakODRLinkage) }
        let dummy = NOIRFunc(name: f.name, params: [], returnType: f.returnType,
                             body: [], isMutating: f.isMutating, span: f.span)
        e.callables[key] = Callable(fn: fn, ty: fnTy, ir: dummy, selfType: nil, selfByPointer: false)
    }

    // MARK: - Body

    private func defineFunction(_ f: SSAFunction) {
        let (key, _, _, _) = keyAndSelf(f)
        guard let c = e.callables[key] else { return }
        values = [:]; blockMap = [:]; blocksById = [:]; spawnHandles = [:]; pendingIncomings.removeAll(keepingCapacity: true)
        curVWTParams = [:]; curPWTParams = [:]; curSretParam = nil; curReturnType = nil
        curProducerSave = nil; curBackEdges = [:]; headerSaveSlot = [:]; curBlockId = -1
        curFnName = f.name
        e.currentFn = c.fn

        // An erased generic's value parameters sit past the hidden leading parameters — VWT pointers,
        // then PWT pointers, then an sret result buffer if the return mentions a type parameter
        // (backend.md §4). Map the VWTs/PWTs (for requirement dispatch) and the sret + returned type
        // parameter's VWT (so `ret` can lower the move as a VWT-sized memcpy).
        if !f.generics.isEmpty {
            let returnsTP = mentionsTypeParam(f.returnType)
            let vwtCount = f.generics.count
            let pwts = erasedPWTs(f)
            let leading = vwtCount + pwts.count + (returnsTP ? 1 : 0)
            for (i, gp) in f.generics.enumerated() { curVWTParams[gp.name] = LLVMGetParam(c.fn, UInt32(i)) }
            for (i, pw) in pwts.enumerated() { curPWTParams["\(pw.param)::\(pw.iface)"] = LLVMGetParam(c.fn, UInt32(vwtCount + i)) }
            for (i, p) in f.params.enumerated() { values[p.id] = LLVMGetParam(c.fn, UInt32(leading + i)) }
            if returnsTP {
                curSretParam = LLVMGetParam(c.fn, UInt32(vwtCount + pwts.count))
                curReturnType = f.returnType   // the `ret` move sizes it via the derived VWT
            }
        } else {
            // Function parameters map to the LLVM parameters by position (the SSA param order — self first
            // for a method — matches the declared signature).
            for (i, p) in f.params.enumerated() { values[p.id] = LLVMGetParam(c.fn, UInt32(i)) }
        }

        e.enterDebugScope(c.fn, line: f.span.begin.line)

        // Pass A — materialize every block, and a φ for each block parameter (block args → φ).
        for blk in f.blocks {
            let bb = LLVMAppendBasicBlockInContext(ctx, c.fn, "bb\(blk.id)")!
            blockMap[blk.id] = bb
            blocksById[blk.id] = blk
        }
        for blk in f.blocks {
            LLVMPositionBuilderAtEnd(b, blockMap[blk.id])
            for p in blk.params {
                guard let pty = ty(p.type, f.span) else { return }
                values[p.id] = LLVMBuildPhi(b, pty, "arg")
            }
        }

        // Producer-internal typed-root prologue (task 100.4.3.6): if this erased frame constructs a
        // composed `T`-carrying value, capture the shadow-top at entry so the epilogue can unwind exactly
        // the frame's own pushes. Emitted once, at the end of the entry block (after its φs, before its
        // body), so the saved value dominates every `ret`. A per-header save slot (entry alloca) is set up
        // for the loop-scoped unwind; the stores land when the header block is lowered.
        if !f.generics.isEmpty, let entry = f.blocks.first, frameBuildsRegistrableComposite(f) {
            for be in backEdges(f) { curBackEdges[be.from] = be.to }
            LLVMPositionBuilderAtEnd(b, blockMap[entry.id])
            let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i8ptr, params: [])
            curProducerSave = e.buildCall(save.0, save.1, [])
            for h in Set(curBackEdges.values) { headerSaveSlot[h] = e.entryAlloca(e.i8ptr, "loopshadow.save") }
        }

        // Pass B — lower each block's instructions and terminator. A GC safepoint poll goes at the top
        // of every loop header (a back-edge target): a poll-free loop can't be paused by a
        // stop-the-world collector, so the mutator must reach a safepoint on every back-edge (D3). The
        // NOIR walker does the same at each `while` header; placed after the header's φs and before its
        // body, so every iteration passes through it. (Eliding it when the loop already hits a safepoint
        // each iteration — NOIR's `loopBodyHasSafepoint` — is a later refinement / the safepoint pass.)
        // A runtime-subset (`noSafepoint`) function elides the poll (task 149, runtime-subset.md §4): its
        // code may run during a stop-the-world, so a poll here would recursively try to stop the world.
        // The closure check (Sema) already keeps subset code from reaching a non-subset callee, so no poll
        // hides behind a call either. This is the codegen-site guard the scheduler loop needs (128.1.1).
        let headers = f.noSafepoint ? Set<Int>() : loopHeaders(f)
        for blk in f.blocks {
            LLVMPositionBuilderAtEnd(b, blockMap[blk.id])
            if headers.contains(blk.id) {
                e.setDebugLoc(blk.insts.first?.span ?? blk.terminator.span)
                e.emitSafepointPoll()
            }
            // Loop-scoped typed-root save (task 100.4.3.6): record the shadow-top on entry to this loop
            // header, so the back-edge can restore it and clear the iteration's producer pushes.
            if let slot = headerSaveSlot[blk.id] {
                let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i8ptr, params: [])
                LLVMBuildStore(b, e.buildCall(save.0, save.1, []), slot)
            }
            lowerBlock(blk)
            if error != nil { return }
        }

        // Every value is now defined; wire the deferred φ incomings (block-argument edges).
        flushIncomings()
    }

    // The loop headers of a function: back-edge targets, found by a DFS that marks a node "on the
    // recursion stack" — an edge to such a node is a back-edge, and its target is a loop header. Order
    // matches ssairgen's `blocks` (entry first). Iterative to avoid deep recursion on large CFGs.
    private func loopHeaders(_ f: SSAFunction) -> Set<Int> {
        var succ: [Int: [Int]] = [:]
        for blk in f.blocks { succ[blk.id] = successorIds(blk.terminator) }
        var headers = Set<Int>()
        var state: [Int: Int] = [:]   // 0/absent = unvisited, 1 = on stack, 2 = done
        guard let entry = f.blocks.first?.id else { return headers }
        var stack: [(node: Int, next: Int)] = [(entry, 0)]
        state[entry] = 1
        while let top = stack.last {
            let succs = succ[top.node] ?? []
            if top.next < succs.count {
                stack[stack.count - 1].next += 1
                let s = succs[top.next]
                switch state[s] ?? 0 {
                case 0: state[s] = 1; stack.append((s, 0))
                case 1: headers.insert(s)   // edge to a node on the stack → back-edge
                default: break
                }
            } else {
                state[top.node] = 2
                stack.removeLast()
            }
        }
        return headers
    }

    private func successorIds(_ term: SSATerm) -> [Int] {
        switch term.kind {
        case .br(let t, _): return [t]
        case .condBr(_, let t, _, let e, _): return [t, e]
        case .switchOn(_, let cases, let def, _): return cases.map { $0.target } + [def]
        case .ret, .unreachable: return []
        }
    }

    // The back-edges of a function (task 100.4.3.6): edges `from → to` where `to` is on the DFS recursion
    // stack, i.e. a loop header. The producer typed-root unwind restores the shadow-top at each of these.
    private func backEdges(_ f: SSAFunction) -> [(from: Int, to: Int)] {
        var succ: [Int: [Int]] = [:]
        for blk in f.blocks { succ[blk.id] = successorIds(blk.terminator) }
        guard let entry = f.blocks.first?.id else { return [] }
        var edges: [(from: Int, to: Int)] = []
        var state: [Int: Int] = [:]   // 0/absent = unvisited, 1 = on stack, 2 = done
        var stack: [(node: Int, next: Int)] = [(entry, 0)]
        state[entry] = 1
        while let top = stack.last {
            let succs = succ[top.node] ?? []
            if top.next < succs.count {
                stack[stack.count - 1].next += 1
                let s = succs[top.next]
                switch state[s] ?? 0 {
                case 0: state[s] = 1; stack.append((s, 0))
                case 1: edges.append((top.node, s))
                default: break
                }
            } else {
                state[top.node] = 2
                stack.removeLast()
            }
        }
        return edges
    }

    // Whether an erased frame constructs a composed value with a `T`-carrying field — the trigger for
    // emitting the producer typed-root prologue/epilogue (task 100.4.3.6). Mirrors the registration
    // predicate in `makeStruct`/`makeEnum` so the prologue save exists exactly when a `ret` (or back-edge)
    // will need to unwind a push.
    private func frameBuildsRegistrableComposite(_ f: SSAFunction) -> Bool {
        for blk in f.blocks {
            for inst in blk.insts {
                switch inst.kind {
                case .makeStruct(let t, _), .makeEnum(let t, _, _):
                    if composedHasTypeParamField(t) { return true }
                default: break
                }
            }
        }
        return false
    }

    // Whether a composed generic type (as it appears in an erased body — type parameters retained) has a
    // field / payload whose type mentions a type parameter, i.e. a `T`-component held inline in its buffer.
    private func composedHasTypeParamField(_ t: Type) -> Bool {
        guard case .generic(let base, let args) = t else { return false }
        if let s = e.structMap[base] {
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            return s.fields.contains { mentionsTypeParam(substType($0.type, subst)) }
        }
        if let en = e.enumMap[base] {
            let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
            return en.cases.contains { $0.fields.contains { mentionsTypeParam(substType($0.type, subst)) } }
        }
        return false
    }

    // Register the `T`-components of a just-constructed composed buffer as typed GC roots (task
    // 100.4.3.6). `baseOff` is the component's byte offset within `buf`. A bare type parameter pushes one
    // shadow node pairing its slot with the runtime VWT passed for that parameter; a nested composed
    // struct recurses into its `T`-carrying fields. (A nested composed *enum* field is deferred — its
    // active case, and so which payload is managed, is a runtime property; the top-level `makeEnum` knows
    // its own case and registers that directly.) A construction in a loop is cleared each iteration by the
    // back-edge unwind. No-op when the prologue took no save (the frame builds no registrable composite).
    private func registerErasedComponents(_ buf: LLVMValueRef, _ t: Type, _ baseOff: LLVMValueRef, _ span: Span) {
        guard curProducerSave != nil else { return }
        switch t {
        case .typeParam(let name):
            guard let vwt = curVWTParams[name] else { return }
            producerShadowPush(e.gepByte(buf, baseOff), vwt)
        case .generic(let base, let args):
            guard let s = e.structMap[base] else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            for (i, f) in s.fields.enumerated() {
                let ft = substType(f.type, subst)
                guard mentionsTypeParam(ft), let foff = erasedFieldOffset(t, i, span) else { continue }
                registerErasedComponents(buf, ft, LLVMBuildAdd(b, baseOff, foff, "coff")!, span)
            }
        default:
            break
        }
    }

    // Push one typed-root node for `comp` (a slot address) paired with its value-layout VWT, on the
    // current fiber's shadow stack. The node storage is an entry-hoisted alloca; `rtShadowPush` is a
    // no-op when no fiber is bound (non-scheduler runs), so this is safe in any run config.
    private func producerShadowPush(_ comp: LLVMValueRef, _ vwt: LLVMValueRef) {
        let push = e.preludeFn("nomu_fn_rtShadowPush", ret: e.voidTy, params: [e.i8ptr, e.i8ptr, e.i8ptr])
        let node = e.entryAlloca(e.structTy([e.i8ptr, e.i8ptr, e.i8ptr]), "pshadow.node")
        _ = e.buildCall(push.0, push.1, [node, comp, vwt])
    }

    private func lowerBlock(_ blk: SSABlock) {
        curBlockId = blk.id
        var i = 0
        while i < blk.insts.count {
            let inst = blk.insts[i]
            e.setDebugLoc(inst.span)
            // ssairgen emits `writeBarrier(obj, v)` immediately before `store(addr, v)` for a managed
            // field write; fuse the pair into one barriered store (the combined ABI the shared
            // `storeField` emits). A standalone `store` is a plain store.
            // An erased store (writing a `T`-typed value, held by buffer) is a VWT-sized copy, not a
            // first-class pointer store, so it must not fold into `storeField` (task 100.4.3.10). The
            // generational logging barrier for a non-POD `T` written into a heap object is a residual gap;
            // the current test GC configs full-heap-scan, so no remembered-set entry is lost under them.
            if case .writeBarrier(let object, let bv) = inst.kind,
               i + 1 < blk.insts.count, case .store(let addr, let sv) = blk.insts[i + 1].kind, sv.id == bv.id,
               !mentionsTypeParam(sv.type) {
                e.storeField(val(object), val(addr), val(sv))
                i += 2
                continue
            }
            lowerInst(inst)
            i += 1
        }
        e.setDebugLoc(blk.terminator.span)
        lowerTerminator(blk.terminator)
    }

    // MARK: - Instructions

    private func lowerInst(_ inst: SSAInst) {
        let span = inst.span
        switch inst.kind {
        case .constInt(let n):
            if inst.result?.type == .uint8 {
                define(inst, LLVMConstInt(e.i8, UInt64(n & 0xFF), 0))
            } else {
                define(inst, LLVMConstInt(e.i64, UInt64(bitPattern: Int64(n)), 1))
            }
        case .constDouble(let x):
            define(inst, LLVMConstReal(e.f64, x))
        case .constBool(let v):
            define(inst, LLVMConstInt(e.i1, v ? 1 : 0, 0))
        case .constString(let s):
            define(inst, e.lowerStringLit(s))

        case .binary(let op, let l, let r):
            define(inst, lowerBinary(op, l, r, span))

        case .alloc(let t):
            define(inst, lowerAlloc(t, span))
        case .stackAlloc(let t):
            guard let lt = storageType(t, span) else { return }
            define(inst, e.entryAlloca(lt, "slot"))
        case .load(let addr):
            guard let rt = inst.result.flatMap({ ty($0.type, span) }) else { return }
            define(inst, LLVMBuildLoad2(b, rt, val(addr), "ld"))
        case .store(let addr, let value):
            // An erased value (`.typeParam`, or a composed `.generic`) is held by a buffer pointer, so a
            // store of one is a VWT-sized copy from the source buffer into the destination — the write dual
            // of the erased field read/return path (task 100.4.3.10). A residual `.typeParam` only survives
            // in an erased body, where `curVWTParams` sizes the copy. The destination may be a `p1` field
            // address of an erased class receiver; a synchronous copy has no safepoint, so casting both
            // operands to addr0 is sound.
            if mentionsTypeParam(value.type) {
                guard let size64 = erasedTypeSize(value.type, span) else { return }
                let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                var dst = val(addr), src = val(value)
                if LLVMGetPointerAddressSpace(LLVMTypeOf(dst)) == 1 { dst = e.toUnmanaged(dst) }
                if LLVMGetPointerAddressSpace(LLVMTypeOf(src)) == 1 { src = e.toUnmanaged(src) }
                _ = e.buildCall(memcpy, mty, [dst, src, size64])
            } else {
                LLVMBuildStore(b, val(value), val(addr))
            }
        case .writeBarrier:
            break   // handled by the fused-pair path in `lowerBlock`; a lone barrier is a no-op
        case .fieldAddr(let base, let idx):
            define(inst, fieldSlotAddr(base, idx, span))
        case .elementAddr(let base, let index):
            define(inst, EgressArrays.elementAddr(self, base, index, inst.result!.type, span))
        case .arrayLen(let arr):
            define(inst, LLVMBuildLoad2(b, e.i64, e.gepByte(val(arr), LLVMConstInt(e.i64, 8, 0)), "arr.len"))
        case .boundscheck(let index, let length):
            EgressArrays.emitBoundscheck(self, val(index), val(length))

        case .call(let call):
            lowerCall(call, inst: inst, span: span)

        case .mailboxInit(let obj):
            EgressConcurrency.lowerMailboxInit(self, obj, span)
        case .actorSend(let receiver, let handler, let args):
            guard case .named(let actorName, _) = receiver.type else {
                e.fail("7.2.3: actorSend on a non-actor receiver", span); return
            }
            _ = e.emitActorSend(actorName, handler, val(receiver), args.map { val($0) }, span)
        case .spawn(let binding, let startFn, let env, let resultType):
            EgressConcurrency.lowerSpawn(self, binding: binding, startFn: startFn, env: env, resultType: resultType, span: span)
        case .spawnJoin(let binding, let resultType, let fin):
            EgressConcurrency.lowerSpawnJoin(self, inst, binding: binding, resultType: resultType, final: fin, span: span)

        case .makeStruct(let t, let fields):
            define(inst, makeStruct(t, fields, span))
        case .makeEnum(let t, let caseIndex, let fields):
            define(inst, makeEnum(t, caseIndex, fields, span))
        case .extractField(let base, let idx):
            define(inst, LLVMBuildExtractValue(b, val(base), UInt32(idx), "fld"))
        case .enumTag(let base):
            if case .generic = base.type {
                define(inst, LLVMBuildLoad2(b, e.i64, val(base), "etag"))   // tag word at offset 0 of the buffer
            } else {
                define(inst, LLVMBuildExtractValue(b, val(base), 0, "tag"))
            }
        case .extractPayload(let base, let caseIndex, let fieldIndex):
            define(inst, extractPayload(base, caseIndex, fieldIndex, inst.result!.type, span))

        case .box(let value, let interfaces, let onStack):
            define(inst, lowerBox(value, interfaces, onStack, span))
        case .arrayLit(let elements, let elem):
            define(inst, EgressArrays.lowerArrayLit(self, elements, elem, span))
        case .makeClosure(let funcName, let env, let onStack):
            define(inst, EgressConcurrency.makeClosure(self, funcName, env, onStack, span))
        case .funcAddr(let name):
            // The bare C-ABI code pointer of a top-level function (task 128.2, RawPtr.ofFunc). The
            // callable's `fn` is a `ptr` already usable as an addrspace(0) RawPtr (the closure/spawn
            // paths store it into an i8ptr slot directly), so no cast is needed.
            guard let c = e.callables["f:\(name)"] else {
                e.fail("128.2: unknown function '\(name)' for RawPtr.ofFunc", span); return
            }
            define(inst, c.fn)
        }
    }

    private func define(_ inst: SSAInst, _ value: LLVMValueRef?) {
        guard let value = value, let result = inst.result else { return }
        values[result.id] = value
    }

    // MARK: - Terminators (block args → φ incomings)

    private func lowerTerminator(_ term: SSATerm) {
        // Loop-scoped typed-root unwind (task 100.4.3.6): a back-edge restores the shadow-top saved at its
        // header, clearing this iteration's producer pushes before the next iteration re-pushes them. The
        // non-back successors of such a block are the loop exit, which also wants the pre-loop top, so an
        // unconditional restore here is correct for the standard loop shapes. A `ret` block is never a
        // back-edge source (it branches nowhere), so this never races the function epilogue pop.
        if let header = curBackEdges[curBlockId], let slot = headerSaveSlot[header], curProducerSave != nil {
            let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i8ptr])
            _ = e.buildCall(pop.0, pop.1, [LLVMBuildLoad2(b, e.i8ptr, slot, "loopshadow")])
        }
        switch term.kind {
        case .br(let target, let args):
            passArgs(to: target, args)
            LLVMBuildBr(b, blockMap[target])
        case .condBr(let cond, let then, let thenArgs, let els, let elseArgs):
            passArgs(to: then, thenArgs)
            passArgs(to: els, elseArgs)
            LLVMBuildCondBr(b, val(cond), blockMap[then], blockMap[els])
        case .switchOn(let scrutinee, let cases, let defaultTarget, let defaultArgs):
            passArgs(to: defaultTarget, defaultArgs)
            let sw = LLVMBuildSwitch(b, val(scrutinee), blockMap[defaultTarget], UInt32(cases.count))
            for c in cases {
                passArgs(to: c.target, c.args)
                LLVMAddCase(sw, LLVMConstInt(e.i64, UInt64(bitPattern: Int64(c.value)), 1), blockMap[c.target])
            }
        case .ret(let v):
            // Producer-internal typed-root epilogue (task 100.4.3.6): unwind every shadow node this frame
            // pushed, restoring the shadow-top saved in the prologue. Before the return move, so the
            // frame's registrations never outlive it. The returned composed buffer's `T`-components are
            // re-registered by the caller (consumer bracketing) or the caller's own prologue, if held.
            if let save = curProducerSave {
                let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i8ptr])
                _ = e.buildCall(pop.0, pop.1, [save])
            }
            if let sret = curSretParam, let rt = curReturnType, let v = v {
                // Erased return: move the value buffer into the caller's result buffer (backend.md §4),
                // sized by the return type's derived VWT (a bare `T`, or a composed `Box<T>` summed from
                // its field VWTs). A move is a memcpy — the source is not read again after return, so the
                // trivial (POD) inline memcpy is sound without the indirect `move` witness.
                guard let size64 = erasedTypeSize(rt, term.span) else { return }
                let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                // The source may be a `p1` field address of an erased **class** receiver (task 100.4.3.9) —
                // cast it to addr0 for the memcpy. A synchronous copy has no safepoint, so the object cannot
                // move mid-copy; the addrspacecast is sound here.
                var srcBuf = val(v)
                if LLVMGetPointerAddressSpace(LLVMTypeOf(srcBuf)) == 1 { srcBuf = e.toUnmanaged(srcBuf) }
                _ = e.buildCall(memcpy, mty, [sret, srcBuf, size64])
                LLVMBuildRetVoid(b)
            } else if let v = v {
                LLVMBuildRet(b, val(v))
            } else {
                LLVMBuildRetVoid(b)
            }
        case .unreachable:
            LLVMBuildUnreachable(b)
        }
    }

    // Record each edge argument as a pending incoming of the target block's φ, from the current block.
    // The predecessor block is fixed now; the argument's LLVM value is resolved in `flushIncomings`,
    // after every block is lowered, so an argument defined in a later-lowered block still resolves.
    private func passArgs(to target: Int, _ args: [SSAValue]) {
        guard !args.isEmpty, let params = blocksById[target]?.params else { return }
        guard let pred = LLVMGetInsertBlock(b) else { return }
        for (i, arg) in args.enumerated() where i < params.count {
            guard let phi = values[params[i].id] else { continue }
            pendingIncomings.append((phi: phi, pred: pred, arg: arg))
        }
    }

    // Wire every deferred φ incoming once all definitions exist.
    private func flushIncomings() {
        for p in pendingIncomings {
            var incoming: [LLVMValueRef?] = [val(p.arg)]
            var block: [LLVMBasicBlockRef?] = [p.pred]
            LLVMAddIncoming(p.phi, &incoming, &block, 1)
        }
        pendingIncomings.removeAll(keepingCapacity: true)
    }

    // MARK: - Operations

    private func lowerBinary(_ op: BinOp, _ l: SSAValue, _ r: SSAValue, _ span: Span) -> LLVMValueRef {
        let lv = val(l), rv = val(r)
        if l.type == .double {
            switch op {
            case .add: return LLVMBuildFAdd(b, lv, rv, "fadd")
            case .sub: return LLVMBuildFSub(b, lv, rv, "fsub")
            case .mul: return LLVMBuildFMul(b, lv, rv, "fmul")
            case .div: return LLVMBuildFDiv(b, lv, rv, "fdiv")
            case .mod: return LLVMBuildFRem(b, lv, rv, "frem")
            case .eq, .neq, .lt, .gt, .lte, .gte:
                let pred: LLVMRealPredicate
                switch op {
                case .eq:  pred = LLVMRealOEQ
                case .neq: pred = LLVMRealONE
                case .lt:  pred = LLVMRealOLT
                case .gt:  pred = LLVMRealOGT
                case .lte: pred = LLVMRealOLE
                default:   pred = LLVMRealOGE
                }
                return LLVMBuildFCmp(b, pred, lv, rv, "fcmp")
            case .bitAnd, .bitOr, .bitXor, .shl, .shr:
                e.fail("7.2.3: bitwise/shift operators are not valid on Double", span); return lv
            case .and, .or:
                e.fail("logical '&&'/'||' are lowered to branches in SSAIRgen; none should reach the egress", span); return lv
            }
        }
        // Integer path: signed for Int, unsigned for UInt8/UInt64 — differing on div/rem, `>>`, and compares.
        let unsigned = (l.type == .uint8 || l.type == .uint64)
        switch op {
        case .add: return LLVMBuildAdd(b, lv, rv, "add")
        case .sub: return LLVMBuildSub(b, lv, rv, "sub")
        case .mul: return LLVMBuildMul(b, lv, rv, "mul")
        case .div: return unsigned ? LLVMBuildUDiv(b, lv, rv, "div") : LLVMBuildSDiv(b, lv, rv, "div")
        case .mod: return unsigned ? LLVMBuildURem(b, lv, rv, "rem") : LLVMBuildSRem(b, lv, rv, "rem")
        case .bitAnd: return LLVMBuildAnd(b, lv, rv, "and")
        case .bitOr:  return LLVMBuildOr(b, lv, rv, "or")
        case .bitXor: return LLVMBuildXor(b, lv, rv, "xor")
        case .shl:    return LLVMBuildShl(b, lv, rv, "shl")
        case .shr:    return unsigned ? LLVMBuildLShr(b, lv, rv, "shr") : LLVMBuildAShr(b, lv, rv, "shr")
        case .eq, .neq, .lt, .gt, .lte, .gte:
            let pred: LLVMIntPredicate
            switch op {
            case .eq:  pred = LLVMIntEQ
            case .neq: pred = LLVMIntNE
            case .lt:  pred = unsigned ? LLVMIntULT : LLVMIntSLT
            case .gt:  pred = unsigned ? LLVMIntUGT : LLVMIntSGT
            case .lte: pred = unsigned ? LLVMIntULE : LLVMIntSLE
            default:   pred = unsigned ? LLVMIntUGE : LLVMIntSGE
            }
            return LLVMBuildICmp(b, pred, lv, rv, "cmp")
        case .and, .or:
            e.fail("logical '&&'/'||' are lowered to branches in SSAIRgen; none should reach the egress", span); return lv
        }
    }

    // A managed heap allocation for a class / actor / synthesized env object: size = header (+ mailbox
    // for an actor) + fields, then stamp the type-id header. `alloc` for a value aggregate never
    // occurs (those are `stackAlloc`/`makeStruct`).
    private func lowerAlloc(_ t: Type, _ span: Span) -> LLVMValueRef? {
        guard case .named(let name, let kind) = t else { e.fail("7.2.3: alloc of non-nominal type", span); return nil }
        let obj: LLVMValueRef
        if kind == .actor_, let a = e.actorMap[name] {
            let slots = 2 + a.fields.reduce(0) { $0 + e.slotCount($1.type) }   // header + fields + mailbox
            obj = e.rtAllocManaged(LLVMConstInt(e.i64, UInt64(slots * 8), 0))
        } else if let c = e.classMap[name] {
            let slots = 1 + c.fields.reduce(0) { $0 + e.slotCount($1.type) }   // header + fields
            obj = e.rtAllocManaged(LLVMConstInt(e.i64, UInt64(slots * 8), 0))
        } else {
            e.fail("7.2.3: alloc of unknown heap type '\(name)'", span); return nil
        }
        e.writeTypeIdHeader(obj, name)
        return obj
    }

    // The address of field `idx` in `base`. A struct base (a `stackAlloc` slot) GEPs at field index;
    // a class/actor/env base (a managed object pointer) GEPs past the object header (index+1).
    private func fieldSlotAddr(_ base: SSAValue, _ idx: Int, _ span: Span) -> LLVMValueRef? {
        // A residual composed generic (`Box<T>`) is held as an opaque buffer (task 100.4.3.3.4): the
        // field slot is the buffer pointer offset by the field's derived-VWT byte offset (0 for the
        // first field; the running sum of prior field sizes otherwise, computed from the VWTs).
        if case .generic = base.type {
            guard let off = erasedFieldOffset(base.type, idx, span) else { return nil }
            return e.gepByte(val(base), off)
        }
        guard case .named(let name, let kind) = base.type else {
            e.fail("7.2.3: fieldAddr on a non-nominal base", span); return nil
        }
        switch kind {
        case .struct_:
            guard let st = e.structType(name) else { return nil }
            return e.structGEP(st, val(base), idx)
        case .class_:
            guard let ct = e.classType(name) else { return nil }
            return e.structGEP(ct, val(base), e.fieldLLVMIndex(.classRef, idx))
        case .actor_:
            guard let at = e.actorType(name) else { return nil }
            return e.structGEP(at, val(base), e.fieldLLVMIndex(.classRef, idx))
        default:
            e.fail("7.2.3: fieldAddr on '\(name)'", span); return nil
        }
    }

    private func makeStruct(_ t: Type, _ fields: [SSAValue], _ span: Span) -> LLVMValueRef? {
        // A residual composed generic (`Box<T>`) is built into a derived-VWT-sized stack buffer: each
        // field is copied to its offset — a VWT-sized memcpy for a type-parameter/composed field (held
        // by buffer), a plain store for a concrete scalar field (task 100.4.3.3.4).
        if case .generic(let base, let args) = t, let s = e.structMap[base] {
            guard let size = erasedTypeSize(t, span) else { return nil }
            let buf = LLVMBuildArrayAlloca(b, e.i8, size, "erased.box")!
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            for (i, f) in s.fields.enumerated() where i < fields.count {
                guard let off = erasedFieldOffset(t, i, span) else { return nil }
                let dst = e.gepByte(buf, off)
                let ft = substType(f.type, subst)
                if mentionsTypeParam(ft) {
                    guard let fsize = erasedTypeSize(ft, span) else { return nil }
                    let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                    _ = e.buildCall(memcpy, mty, [dst, val(fields[i]), fsize])
                    registerErasedComponents(buf, ft, off, span)   // typed GC root for the `T`-component (100.4.3.6)
                } else {
                    LLVMBuildStore(b, val(fields[i]), dst)
                }
            }
            return buf
        }
        guard case .named(let name, _) = t, let st = e.structType(name) else {
            e.fail("7.2.3: makeStruct of non-struct", span); return nil
        }
        var agg = LLVMGetUndef(st)
        for (idx, f) in fields.enumerated() {
            agg = LLVMBuildInsertValue(b, agg, val(f), UInt32(idx), "")
        }
        return agg
    }

    // Build an enum value `{ i64 tag, [P x i64] payload }` in a temp slot, then load the aggregate.
    private func makeEnum(_ t: Type, _ caseIndex: Int, _ fields: [SSAValue], _ span: Span) -> LLVMValueRef? {
        // A residual composed generic enum (`Opt<T>`) is built into a derived-VWT-sized stack buffer: the
        // tag word at offset 0, then each payload field copied to its offset (task 100.4.3.3.4).
        if case .generic(let base, let args) = t, let en = e.enumMap[base], caseIndex < en.cases.count {
            guard let size = erasedTypeSize(t, span) else { return nil }
            let buf = LLVMBuildArrayAlloca(b, e.i8, size, "erased.enum")!
            LLVMBuildStore(b, LLVMConstInt(e.i64, UInt64(caseIndex), 0), buf)   // tag (i64) at offset 0
            let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
            for (i, f) in en.cases[caseIndex].fields.enumerated() where i < fields.count {
                guard let off = erasedEnumPayloadOffset(base, args, caseIndex, i, span) else { return nil }
                let dst = e.gepByte(buf, off)
                let ft = substType(f.type, subst)
                if mentionsTypeParam(ft) {
                    guard let fsize = erasedTypeSize(ft, span) else { return nil }
                    let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                    _ = e.buildCall(memcpy, mty, [dst, val(fields[i]), fsize])
                    registerErasedComponents(buf, ft, off, span)   // typed GC root for the `T`-component (100.4.3.6)
                } else {
                    LLVMBuildStore(b, val(fields[i]), dst)
                }
            }
            return buf
        }
        guard case .named(let name, _) = t, let et = e.enumType(name),
              let en = e.enumMap[name] else { e.fail("7.2.3: makeEnum of non-enum", span); return nil }
        let slot = e.entryAlloca(et, "enum")
        LLVMBuildStore(b, LLVMConstInt(e.i64, UInt64(caseIndex), 0), e.structGEP(et, slot, 0))
        if !fields.isEmpty {
            guard let cst = e.caseStructType(name, en.cases[caseIndex]) else { return nil }
            let payload = e.structGEP(et, slot, 1)
            for (idx, f) in fields.enumerated() {
                LLVMBuildStore(b, val(f), e.structGEP(cst, payload, idx))
            }
        }
        return LLVMBuildLoad2(b, et, slot, "enumv")
    }

    // Read a payload field of an enum *value*: spill it, GEP the case struct over the payload region.
    private func extractPayload(_ base: SSAValue, _ caseIndex: Int, _ fieldIndex: Int,
                                _ fieldType: Type, _ span: Span) -> LLVMValueRef? {
        // A residual composed generic enum (`Opt<T>`) held by buffer: the payload field is at its
        // derived offset past the tag; a `T` field yields a buffer pointer, a concrete field a load.
        if case .generic(let genBase, let args) = base.type {
            guard let off = erasedEnumPayloadOffset(genBase, args, caseIndex, fieldIndex, span) else { return nil }
            let ptr = e.gepByte(val(base), off)
            if mentionsTypeParam(fieldType) { return ptr }
            guard let fty = ty(fieldType, span) else { return nil }
            return LLVMBuildLoad2(b, fty, ptr, "pl")
        }
        guard case .named(let name, _) = base.type, let et = e.enumType(name),
              let en = e.enumMap[name], let cst = e.caseStructType(name, en.cases[caseIndex]),
              let fty = ty(fieldType, span) else { e.fail("7.2.3: extractPayload on non-enum", span); return nil }
        let slot = e.entryAlloca(et, "enum")
        LLVMBuildStore(b, val(base), slot)
        let payload = e.structGEP(et, slot, 1)
        return LLVMBuildLoad2(b, fty, e.structGEP(cst, payload, fieldIndex), "pl")
    }

    // Wrap a conformer as `any I` / `any A & B`, or upcast `any B` → `any A` — the SSA `box` op's value
    // is already lowered, so this is `lowerBox` over an operand.
    private func lowerBox(_ value: SSAValue, _ interfaces: [String], _ onStack: Bool, _ span: Span) -> LLVMValueRef? {
        if case .existential(let src) = value.type, interfaces.count == 1 {
            let box = val(value)
            let witnessPtr = e.anyBoxWitness(box)
            let payload = e.anyBoxPayload(box)
            let idx = e.witnessSlotIndex(src, "base_\(interfaces[0])")
            guard idx >= 0 else { e.fail("7.2.3: '\(src)' has no base '\(interfaces[0])'", span); return nil }
            let base = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(e.witnessType(src), witnessPtr, idx), "base")!
            return e.makeAnyBox(base, payload, onStack: onStack)
        }
        guard case .named(let t, _) = value.type else { e.fail("7.2.3: cannot box non-nominal value", span); return nil }
        let witness = interfaces.count == 1 ? e.witnessInstance(t, interfaces[0]) : e.compositeInstance(t, interfaces)
        guard let w = witness, let pl = e.boxPayload(val(value), value.type) else { return nil }
        return e.makeAnyBox(w, pl, onStack: onStack)
    }

    // MARK: - Calls

    private func lowerCall(_ call: SSACall, inst: SSAInst, span: Span) {
        switch call.kind {
        case .direct(let name):
            if let v = lowerDirectCall(name, call.args, typeArgs: call.typeArgs,
                                       resultType: inst.result?.type ?? .void, span: span) {
                define(inst, v)
            }
        case .witness(let receiver, let interface, let method):
            // Erased requirement dispatch (task 100.4.3.3.3): the receiver is a `.typeParam` value held
            // by buffer, and the witness table is the PWT parameter passed for that bound (backend.md
            // §4) — dispatch through it with the value-buffer pointer as self, rather than the boxed
            // existential path below.
            if case .typeParam(let tp) = receiver.type {
                guard let pwt = curPWTParams["\(tp)::\(interface)"] else {
                    e.fail("100.4.3.3.3: no witness parameter for '\(tp): \(interface)'", span); return
                }
                var argVals: [LLVMValueRef] = []
                var argTys: [LLVMTypeRef] = []
                for a in call.args {
                    guard let t = ty(a.type, span) else { return }
                    argTys.append(t); argVals.append(val(a))
                }
                if let v = e.witnessDispatchErased(pwt: pwt, iface: interface, method: method, selfPtr: val(receiver),
                                                   argVals: argVals, argTys: argTys,
                                                   resultType: inst.result?.type ?? .void, span: span) {
                    define(inst, v)
                }
                return
            }
            let box = val(receiver)
            let witnessPtr: LLVMValueRef
            if case .composition(let ifaces) = receiver.type {
                let compPtr = e.anyBoxWitness(box)
                guard let ownerIdx = ifaces.firstIndex(of: interface) else {
                    e.fail("7.2.3: no interface owns '\(method)' in composition", span); return
                }
                witnessPtr = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(e.compositeType(ifaces), compPtr, ownerIdx), "sub")!
            } else {
                witnessPtr = e.anyBoxWitness(box)
            }
            let payload = e.anyBoxPayload(box)
            var argVals: [LLVMValueRef] = []
            var argTys: [LLVMTypeRef] = []
            for a in call.args {
                guard let t = ty(a.type, span) else { return }
                argTys.append(t); argVals.append(val(a))
            }
            if let v = e.witnessDispatch(witnessPtr: witnessPtr, iface: interface, method: method, payload: payload,
                                         argVals: argVals, argTys: argTys,
                                         resultType: inst.result?.type ?? .void, span: span) {
                define(inst, v)
            }
        case .indirect(let callee):
            guard case .function(let ptys, let rty) = callee.type, let retTy = ty(rty, span) else {
                e.fail("7.2.3: indirect call on a non-function value", span); return
            }
            let closure = val(callee)
            let cloTy = e.structTy([e.i64, e.i8ptr, e.p1])
            let fnPtr = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(cloTy, closure, 1), "clo.fn")!
            let env = LLVMBuildLoad2(b, e.p1, e.structGEP(cloTy, closure, 2), "clo.env")!
            var paramTys: [LLVMTypeRef] = [e.p1]
            for t in ptys { guard let lt = ty(t, span) else { return }; paramTys.append(lt) }
            var argVals: [LLVMValueRef?] = [env]
            for a in call.args { argVals.append(val(a)) }
            let r = e.buildCall(fnPtr, e.fnType(retTy, paramTys), argVals)
            define(inst, r)
        }
    }

    private func lowerDirectCall(_ name: String, _ args: [SSAValue], typeArgs: [Type] = [], resultType: Type, span: Span) -> LLVMValueRef? {
        switch name {
        case "print":    return EgressBuiltins.emitPrint(self, args, span)
        case "putByte":  return EgressBuiltins.emitPutByte(self, args, span)
        case "concat":   return EgressBuiltins.emitConcat(self, args, span)
        case "sleep":    return EgressBuiltins.emitSleep(self, args, span)
        case "readLine": return EgressBuiltins.emitReadLine(self)
        case "__array_count_int": return LLVMBuildLoad2(b, e.i64, e.gepByte(val(args[0]), LLVMConstInt(e.i64, 8, 0)), "arr.count")
        case "__arraySet":    return EgressArrays.emitArraySet(self, args, span)
        case "__arrayAppend": return EgressArrays.emitArrayAppend(self, args, span)
        // Unsafe raw memory (task 125). RawPtr / Ptr<T> are addrspace(0) i8ptr words; load/store/advance
        // are plain addrspace(0) memory ops (no barrier, never a GC root), alloc/free hit the raw floor.
        case "__rawAlloc":
            let (fn, fty) = e.runtimeFn("rt_raw_alloc", ret: e.i8ptr, params: [e.i64, e.i64], varArg: false)
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        case "__rawFree":
            let (fn, fty) = e.runtimeFn("rt_raw_free", ret: e.voidTy, params: [e.i8ptr], varArg: false)
            return e.buildCall(fn, fty, [val(args[0])])
        case "__rawAdvanced":
            return e.gepByte(val(args[0]), val(args[1]))
        case "__rawStore":
            LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), val(args[2])))
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawZeroBytes":
            // memset(self, 0, n) — bulk-zero a reused heap hole (task 150.4.5.1).
            let (mfn, mfty) = e.runtimeFn("memset", ret: e.i8ptr, params: [e.i8ptr, e.i32, e.i64], varArg: false)
            let z = LLVMBuildTrunc(b, LLVMConstInt(e.i64, 0, 0), e.i32, "zero.byte")
            _ = e.buildCall(mfn, mfty, [val(args[0]), z, val(args[1])])
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawCopyBytes":
            // memcpy(self, from, n) — copy a raw byte range (grow the minor promotion queue). Non-overlapping.
            let (cfn, cfty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
            _ = e.buildCall(cfn, cfty, [val(args[0]), val(args[1]), val(args[2])])
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawLoad":
            guard let lt = ty(resultType, span) else { return nil }
            return LLVMBuildLoad2(b, lt, e.gepByte(val(args[0]), val(args[1])), "raw.load")
        // Atomics (task 128.1.1, scheduler substrate). i64 seq-cst ops over an addrspace(0) RawPtr slot —
        // pure LLVM instructions, no OS/asm. The primitive under the MT-safe run queue, STW flags, and
        // futex words. gc-leaf: no barrier, never a GC root. The fixture keeps offsets 8-aligned.
        case "__atomicLoad":
            let ld = LLVMBuildLoad2(b, e.i64, e.gepByte(val(args[0]), val(args[1])), "atomic.load")
            LLVMSetOrdering(ld, LLVMAtomicOrderingSequentiallyConsistent)
            LLVMSetAlignment(ld, 8)
            return ld
        case "__atomicStore":
            let st = LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), val(args[2])))
            LLVMSetOrdering(st, LLVMAtomicOrderingSequentiallyConsistent)
            LLVMSetAlignment(st, 8)
            return LLVMConstInt(e.i64, 0, 0)
        case "__atomicCas":
            // cmpxchg yields { i64 old, i1 success }; return the old word (caller compares to `expected`).
            let cx = LLVMBuildAtomicCmpXchg(b, e.gepByte(val(args[0]), val(args[3])),
                                            val(args[1]), val(args[2]),
                                            LLVMAtomicOrderingSequentiallyConsistent,
                                            LLVMAtomicOrderingSequentiallyConsistent, 0)
            return LLVMBuildExtractValue(b, cx, 0, "atomic.cas.old")
        case "__atomicFetchAdd":
            return LLVMBuildAtomicRMW(b, LLVMAtomicRMWBinOpAdd, e.gepByte(val(args[0]), val(args[2])),
                                      val(args[1]), LLVMAtomicOrderingSequentiallyConsistent, 0)
        case "__atomicExchange":
            // atomicrmw xchg: swap the word for `value`, yield the previous word. The futex-mutex xchg.
            return LLVMBuildAtomicRMW(b, LLVMAtomicRMWBinOpXchg, e.gepByte(val(args[0]), val(args[2])),
                                      val(args[1]), LLVMAtomicOrderingSequentiallyConsistent, 0)
        // Raw OS clock (task 128.1.1, scheduler substrate). Monotonic nanoseconds straight from the OS —
        // on macOS the libSystem entry `uint64_t clock_gettime_nsec_np(clockid_t)` (the stable Darwin
        // floor, selfhosted-scheduler.md §3.3), no C-runtime shim. `CLOCK_MONOTONIC` is 6 on Darwin. The
        // Linux lowering (raw `clock_gettime`/vDSO) lands with the Linux build target (§5).
        case "__sysMonotonicNanos":
            let (fn, fty) = e.runtimeFn("clock_gettime_nsec_np", ret: e.i64, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 6, 0)])
        // Asm-floor isolation self-test (task 128.2): the runtime harness rt_asm_selftest drives a
        // context-switch round-trip and returns 1/0. Just a call to the runtime symbol.
        case "__sysAsmSelfTest":
            let (fn, fty) = e.runtimeFn("rt_asm_selftest", ret: e.i64, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        // Carrier-local slot (task 128.1.6): the running fiber handle (`rt_current`). Backed by a
        // `_Thread_local` word in the embedded floor (core.c). tlsGet reads it, tlsSet writes it.
        case "__sysTlsGet":
            let (fn, fty) = e.runtimeFn("rt_tls_get", ret: e.i8ptr, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        case "__sysTlsSet":
            let (fn, fty) = e.runtimeFn("rt_tls_set", ret: e.voidTy, params: [e.i8ptr], varArg: false)
            _ = e.buildCall(fn, fty, [val(args[0])])
            return LLVMConstInt(e.i64, 0, 0)
        // I/O poller substrate (task 128.1.7): the macOS kqueue floor + pipe/read/write, bound as libSystem
        // externs (selfhosted-scheduler.md §3.3). fd numbers and counts are i32 at the C boundary; buffers
        // are raw i8ptr. Results are sign-extended back to i64.
        case "__sysKqueue":
            let (fn, fty) = e.runtimeFn("kqueue", ret: e.i32, params: [], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [])!, e.i64, "kqueue.r")
        case "__sysKevent":
            // int kevent(int kq, const struct kevent* changes, int nchanges, struct kevent* events,
            //            int nevents, const struct timespec* timeout) — timeout NULL = block.
            let (fn, fty) = e.runtimeFn("kevent", ret: e.i32,
                                        params: [e.i32, e.i8ptr, e.i32, e.i8ptr, e.i32, e.i8ptr], varArg: false)
            let kq = LLVMBuildTrunc(b, val(args[0]), e.i32, "kq")
            let nch = LLVMBuildTrunc(b, val(args[2]), e.i32, "nch")
            let nev = LLVMBuildTrunc(b, val(args[4]), e.i32, "nev")
            let r = e.buildCall(fn, fty, [kq, val(args[1]), nch, val(args[3]), nev, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "kevent.r")
        case "__sysPipe":
            let (fn, fty) = e.runtimeFn("pipe", ret: e.i32, params: [e.i8ptr], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [val(args[0])])!, e.i64, "pipe.r")
        case "__sysWrite":
            // ssize_t write(int fd, const void* buf, size_t count)
            let (fn, fty) = e.runtimeFn("write", ret: e.i64, params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let wfd = LLVMBuildTrunc(b, val(args[0]), e.i32, "wfd")
            return e.buildCall(fn, fty, [wfd, val(args[1]), val(args[2])])
        case "__sysRead":
            // ssize_t read(int fd, void* buf, size_t count)
            let (fn, fty) = e.runtimeFn("read", ret: e.i64, params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let rfd = LLVMBuildTrunc(b, val(args[0]), e.i32, "rfd")
            return e.buildCall(fn, fty, [rfd, val(args[1]), val(args[2])])
        // Asm-floor context switch (task 128.2): rtSwitch(from, to). Void — returns a dummy word.
        case "__sysCtxSwitch":
            let (fn, fty) = e.runtimeFn("rtSwitch", ret: e.voidTy, params: [e.i8ptr, e.i8ptr], varArg: false)
            _ = e.buildCall(fn, fty, [val(args[0]), val(args[1])])
            return LLVMConstInt(e.i64, 0, 0)
        case "__sysFiberInit":
            let (fn, fty) = e.runtimeFn("rtFiberInit", ret: e.voidTy,
                                        params: [e.i8ptr, e.i8ptr, e.i8ptr, e.i8ptr], varArg: false)
            _ = e.buildCall(fn, fty, [val(args[0]), val(args[1]), val(args[2]), val(args[3])])
            return LLVMConstInt(e.i64, 0, 0)
        // Carrier thread create (task 128.2): pthread_create(handle, NULL, entry, arg). `entry` is a
        // (RawPtr)->RawPtr Nomu function address, ABI-identical to void*(*)(void*).
        case "__sysThreadCreate":
            let (fn, fty) = e.runtimeFn("pthread_create", ret: e.i32,
                                        params: [e.i8ptr, e.i8ptr, e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [val(args[0]), LLVMConstNull(e.i8ptr), val(args[1]), val(args[2])])
            return LLVMBuildSExt(b, r!, e.i64, "thread.create.r")
        case "__sysThreadJoin":
            // pthread_join(pthread_t, NULL); the handle (a pointer-sized pthread_t) is loaded from the slot.
            let t = LLVMBuildLoad2(b, e.i8ptr, val(args[0]), "pthread.t")
            let (fn, fty) = e.runtimeFn("pthread_join", ret: e.i32, params: [e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [t!, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "thread.join.r")
        // Indirect call through a RawPtr code address with the fiber-entry ABI i8ptr(i8ptr) (task 128.1.3).
        case "__sysCallEntry":
            return e.buildCall(val(args[0]), e.fnType(e.i8ptr, [e.i8ptr]), [val(args[1])])
        // Futex (task 128.1.1, scheduler substrate). macOS __ulock_wait / __ulock_wake — the libSystem
        // futex floor (selfhosted-scheduler.md §3.3), no C-runtime shim. Operation bits (private XNU ABI):
        // UL_COMPARE_AND_WAIT = 1; ULF_NO_ERRNO = 0x01000000 returns the negated errno rather than setting
        // the thread-local errno (so the primitive stays subset-friendly, no libc errno slot); ULF_WAKE_ALL
        // = 0x100 wakes every waiter (STW broadcast) instead of one (lock handoff).
        case "__sysFutexWait":
            // int __ulock_wait(uint32 operation, void* addr, uint64 value, uint32 timeout_us)
            let (wf, wt) = e.runtimeFn("__ulock_wait", ret: e.i32,
                                       params: [e.i32, e.i8ptr, e.i64, e.i32], varArg: false)
            let op = LLVMConstInt(e.i32, 0x0100_0001, 0)
            let tmo = LLVMBuildTrunc(b, val(args[2]), e.i32, "futex.tmo")
            let r = e.buildCall(wf, wt, [op, val(args[0]), val(args[1]), tmo])
            return LLVMBuildSExt(b, r!, e.i64, "futex.wait.r")
        case "__sysFutexWake":
            // int __ulock_wake(uint32 operation, void* addr, uint64 wake_value)
            let (kf, kt) = e.runtimeFn("__ulock_wake", ret: e.i32,
                                       params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let oneOp = LLVMConstInt(e.i32, 0x0100_0001, 0)
            let allOp = LLVMConstInt(e.i32, 0x0100_0001 | 0x100, 0)
            let op = LLVMBuildSelect(b, val(args[1]), allOp, oneOp, "futex.wake.op")
            let r = e.buildCall(kf, kt, [op, val(args[0]), LLVMConstInt(e.i64, 0, 0)])
            return LLVMBuildSExt(b, r!, e.i64, "futex.wake.r")
        // Ptr<T>: typed element access at the natural stride of T (index-scaled, C-style packed).
        case "__ptrAlloc":
            guard case .ptr(let elem) = resultType else { e.fail("125: __ptrAlloc result not Ptr<T>", span); return nil }
            let strideV = LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0)
            let bytes = LLVMBuildMul(b, val(args[0]), strideV, "ptr.bytes")!
            let (fn, fty) = e.runtimeFn("rt_raw_alloc", ret: e.i8ptr, params: [e.i64, e.i64], varArg: false)
            return e.buildCall(fn, fty, [bytes, strideV])
        case "__ptrStore":
            let off = LLVMBuildMul(b, val(args[2]), LLVMConstInt(e.i64, UInt64(e.rawStride(args[1].type)), 0), "ptr.off")!
            LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), off))
            return LLVMConstInt(e.i64, 0, 0)
        case "__ptrLoad":
            guard let lt = ty(resultType, span) else { return nil }
            let off = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(resultType)), 0), "ptr.off")!
            return LLVMBuildLoad2(b, lt, e.gepByte(val(args[0]), off), "ptr.load")
        case "__ptrAdvanced":
            guard case .ptr(let elem) = resultType else { e.fail("125: __ptrAdvanced result not Ptr<T>", span); return nil }
            let off = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "ptr.adv")!
            return e.gepByte(val(args[0]), off)
        case "__ptrAsRaw", "__rawAsPtr":
            return val(args[0])   // no-op reinterpret — both are one addrspace(0) word
        case "__ptrNull":
            return LLVMConstPointerNull(e.i8ptr)
        case "__ptrIsNull":
            return LLVMBuildICmp(b, LLVMIntEQ, val(args[0]), LLVMConstPointerNull(e.i8ptr), "ptr.isnull")
        case "__ptrEq":
            return LLVMBuildICmp(b, LLVMIntEQ, val(args[0]), val(args[1]), "ptr.eq")
        case "__rawToInt":
            // A RawPtr (addrspace(0)) → its numeric address as an Int (ptrtoint). Sound on raw memory (the
            // Immix heap + side tables are addrspace(0)); the collector uses it for addr→index math (150.3.1).
            return LLVMBuildPtrToInt(b, val(args[0]), e.i64, "raw.toint")
        // GC type-table reads (task 150 rung 2): reach the codegen-emitted per-type-id side tables from
        // Nomu through the existing runtime accessors (`c-types.md` §1/§3.2). Pure gc-leaf reads — the
        // Nomu tracer describes an object's layout through the same tables the MMTk binding reads.
        case "__gcObjAddr":
            // A managed object (addrspace(1) p1) → its raw address as a RawPtr (addrspace(0)). ptrtoint
            // then inttoptr — the same bit-preserving step the alloc path uses in reverse. Sound only on
            // the non-moving rung-2 heap; a moving collector would relocate the object out from under it.
            let a = LLVMBuildPtrToInt(b, val(args[0]), e.i64, "obj.addr")!
            return LLVMBuildIntToPtr(b, a, e.i8ptr, "obj.raw")
        case "__gcStackmapBase", "__gcStackmapSize":
            // The linker synthesizes `section$start$<seg>$<sect>` / `section$end$…` symbols whose addresses
            // bracket the section — the libc-free way to reach `__llvm_stackmaps` from generated code. The
            // `\u{01}` prefix suppresses LLVM's automatic `_` Mach-O mangling so the literal ld64 name is used.
            let startName = "\u{01}section$start$__LLVM_STACKMAPS$__llvm_stackmaps"
            let endName = "\u{01}section$end$__LLVM_STACKMAPS$__llvm_stackmaps"
            let start = LLVMGetNamedGlobal(e.mod, startName) ?? LLVMAddGlobal(e.mod, e.i8ptr, startName)
            if name == "__gcStackmapBase" { return start }
            let end = LLVMGetNamedGlobal(e.mod, endName) ?? LLVMAddGlobal(e.mod, e.i8ptr, endName)
            let sb = LLVMBuildPtrToInt(b, start, e.i64, "sm.b")!
            let se = LLVMBuildPtrToInt(b, end, e.i64, "sm.e")!
            return LLVMBuildSub(b, se, sb, "sm.size")
        case "__gcFrameAddr":
            let (fn, fty) = e.runtimeFn("llvm.frameaddress.p0", ret: e.i8ptr, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])
        case "__gcReturnAddr":
            let (fn, fty) = e.runtimeFn("llvm.returnaddress.p0", ret: e.i8ptr, params: [e.i32], varArg: false)
            let ra = e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])!
            return LLVMBuildPtrToInt(b, ra, e.i64, "retaddr")
        case "__gcForceCollect":
            // Drive one collection at a clean point (task 150 rung 2, mark-verify oracle) via the C
            // runtime, which forwards the current carrier's mutator to MMTk's user-collection request.
            let (fn, fty) = e.runtimeFn("rt_gc_force_collect", ret: e.voidTy, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        case "__gcParkedAnchors":
            // Task 128.3.1: fetch each parked fiber's saved frame-pointer anchor from the C fiber registry.
            let (fn, fty) = e.runtimeFn("rt_gc_parked_anchors", ret: e.i64, params: [e.i8ptr, e.i64], varArg: false)
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        case "__gcSchedHead":
            // Task 128.3.1 (scheduler root): load the C global `rt_sched_head` — the scheduled-mailbox queue
            // head, a single managed root. Reference it directly as an extern global (defined in runtime.c and
            // linked in); the load yields the mailbox object pointer the C root scan reports at the same point.
            let g = LLVMGetNamedGlobal(e.mod, "rt_sched_head") ?? LLVMAddGlobal(e.mod, e.i8ptr, "rt_sched_head")
            return LLVMBuildLoad2(b, e.i8ptr, g, "gc.schedhead")
        case "__schedHandle":
            // Task 128.3.2: load the C global `rt_nomu_sched` — the self-hosted scheduler's Sched handle,
            // bound at boot under NOMU_SCHED=nomu (null under the C plan). Lets a driver reach the scheduler
            // to run the self-hosted STW walk (nomuSchedWalkParked). Same direct-extern-load shape as __gcSchedHead.
            let g = LLVMGetNamedGlobal(e.mod, "rt_nomu_sched") ?? LLVMAddGlobal(e.mod, e.i8ptr, "rt_nomu_sched")
            return LLVMBuildLoad2(b, e.i8ptr, g, "sched.handle")
        case "__gcSelfhostSpace":
            // Task 150 rung 3: load the codegen-internal global `__nomu_selfhost_space` (the Immix space
            // descriptor the alloc seam lazily creates under NOMU_GC_PLAN=nomu). Get-or-add with the same
            // internal linkage + null initializer the seam uses, so both sites share one global.
            let g = LLVMGetNamedGlobal(e.mod, "__nomu_selfhost_space") ?? {
                let ng = LLVMAddGlobal(e.mod, e.i8ptr, "__nomu_selfhost_space")!
                LLVMSetInitializer(ng, LLVMConstPointerNull(e.i8ptr))
                LLVMSetLinkage(ng, LLVMInternalLinkage)
                return ng
            }()
            return LLVMBuildLoad2(b, e.i8ptr, g, "gc.selfhostspace")
        case "__gcSelfModBuf":
            // Task 150.4.2: this carrier's write-barrier mod-buffer (rt_self_modbuf_get, binding + registering
            // it on first use). A plain runtime call — the buffer is a raw addrspace(0) control block.
            let (fn, fty) = e.runtimeFn("rt_self_modbuf_get", ret: e.i8ptr, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        case "__gcDrainModBufs":
            // Task 150.4.3: drain every carrier's mod-buffer into outBuf (the minor GC's remembered set),
            // resetting the buffers; returns the count. A runtime call over the C-side buffer registry.
            let (fn, fty) = e.runtimeFn("rt_modbuf_drain", ret: e.i64, params: [e.i8ptr, e.i64], varArg: false)
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        case "__gcNurseryReserve":
            // Task 150.4.3: load the C global `__nomu_nursery_reserve` (the env-set nursery reserve in blocks,
            // 0 = default). rtImmixNew reads it at space creation. Same direct-extern-load shape as __gcSchedHead.
            let g = LLVMGetNamedGlobal(e.mod, "__nomu_nursery_reserve") ?? LLVMAddGlobal(e.mod, e.i64, "__nomu_nursery_reserve")
            return LLVMBuildLoad2(b, e.i64, g, "gc.nurseryreserve")
        case "__gcMatureFloor":
            // Task 150.4.4: load the C global `__nomu_mature_floor` (the env-set mature-pressure floor in
            // blocks, 0 = default). rtImmixRefill reads it to pick minor vs. major. Same direct-extern-load
            // shape as __gcNurseryReserve.
            let g = LLVMGetNamedGlobal(e.mod, "__nomu_mature_floor") ?? LLVMAddGlobal(e.mod, e.i64, "__nomu_mature_floor")
            return LLVMBuildLoad2(b, e.i64, g, "gc.maturefloor")
        case "__gcExternalDriver":
            // Load the C global `__nomu_gc_ext_driver` (nonzero when an external STW driver owns collection so
            // the default minor coordinator is not running). rtGenReserve gates generational off on it.
            let g = LLVMGetNamedGlobal(e.mod, "__nomu_gc_ext_driver") ?? LLVMAddGlobal(e.mod, e.i64, "__nomu_gc_ext_driver")
            return LLVMBuildLoad2(b, e.i64, g, "gc.extdriver")
        case "__gcTypeCount":
            // The number of descriptors = `__nomu_descs` section size / record size, resolved at run
            // time from the linked section (task 100.4.7); no compile-time dense count exists.
            let (fn, fty) = e.runtimeFn("nomu_gc_typecount", ret: e.i64, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        case "__gcTypeSize":
            let (fn, fty) = e.runtimeFn("nomu_gc_typesize", ret: e.i64, params: [e.i64], varArg: false)
            return e.buildCall(fn, fty, [val(args[0])])
        case "__gcTypeStride":
            let (fn, fty) = e.runtimeFn("nomu_gc_typestride", ret: e.i64, params: [e.i64], varArg: false)
            return e.buildCall(fn, fty, [val(args[0])])
        case "__gcTypeKind":
            let (fn, fty) = e.runtimeFn("nomu_gc_typekind", ret: e.i32, params: [e.i64], varArg: false)
            let k = e.buildCall(fn, fty, [val(args[0])])!
            return LLVMBuildZExt(b, k, e.i64, "gc.kind")
        case "__gcTypeNumPtrs":
            let (fn, fty) = e.runtimeFn("nomu_gc_typemap", ret: e.i8ptr, params: [e.i64, e.i8ptr], varArg: false)
            let cslot = e.entryAlloca(e.i32, "gc.nptr")
            _ = e.buildCall(fn, fty, [val(args[0]), cslot])
            let c = LLVMBuildLoad2(b, e.i32, cslot, "gc.nptr.v")!
            return LLVMBuildZExt(b, c, e.i64, "gc.nptr.z")
        case "__gcTypePtrOffset":
            let (fn, fty) = e.runtimeFn("nomu_gc_typemap", ret: e.i8ptr, params: [e.i64, e.i8ptr], varArg: false)
            let cslot = e.entryAlloca(e.i32, "gc.off.c")
            let base = e.buildCall(fn, fty, [val(args[0]), cslot])!
            let off = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, 4, 0), "gc.off.byte")!
            let elt = LLVMBuildLoad2(b, e.i32, e.gepByte(base, off), "gc.off.v")!
            return LLVMBuildZExt(b, elt, e.i64, "gc.off.z")
        case "__int_double_double": return LLVMBuildSIToFP(b, val(args[0]), e.f64, "i2d")
        case "__double_int_int":
            let (fn, fty) = e.runtimeFn("llvm.round.f64", ret: e.f64, params: [e.f64], varArg: false)
            let rounded = e.buildCall(fn, fty, [val(args[0])])!
            return LLVMBuildFPToSI(b, rounded, e.i64, "d2i")
        case "__int_uint8_uint8": return LLVMBuildTrunc(b, val(args[0]), e.i8, "i2u8")
        case "__uint8_int_int":   return LLVMBuildZExt(b, val(args[0]), e.i64, "u82i")
        // UInt64 conversions: Int↔UInt64 share the i64 representation (no-op reinterpret); UInt8→UInt64
        // zero-extends, UInt64→UInt8 truncates to the low byte.
        case "__int_uint64_uint64":     return val(args[0])
        case "__uint64_int_int":        return val(args[0])
        case "__uint8_uint64_uint64":   return LLVMBuildZExt(b, val(args[0]), e.i64, "u82u64")
        case "__uint64_uint8_uint8":    return LLVMBuildTrunc(b, val(args[0]), e.i8, "u642u8")
        case "__void_timemonotonic_int": return EgressBuiltins.emitTimeMonotonic(self, args, span)
        default:
            if Builtins.cLeaf.contains(name) { return EgressBuiltins.emitCLeaf(self, name, args) }
            // An imported *generic* function (task 100.4.3.4): call it through the erased witness-passing
            // ABI to the producer's compiled-once symbol, threading the VWTs for the concrete type
            // arguments — rather than the by-value signature below. Checked before the `callables`
            // fast-path: `emitErasedExternalCall` caches the declaration under this key, so a second call
            // to the same generic must still route here to marshal its args (not a raw by-value call).
            if let sig = e.externalGenericSigs[name] {
                return emitErasedExternalCall(name, sig: sig, args: args, typeArgs: typeArgs,
                                              resultType: resultType, span: span)
            }
            // A user free function or a method symbol — resolve the declared callable.
            let key = name.hasPrefix("m:") ? name : "f:\(name)"
            if let c = e.callables[key] {
                return e.buildCall(c.fn, c.ty, args.map { val($0) })
            }
            // A function imported from a dependency (task 100.4.2): declared here as an external symbol
            // (no body), resolved at link against the dependency's object. Signature comes from the call.
            if e.externalFuncNames.contains(name) {
                guard let retTy = ty(resultType, span) else { return nil }
                var paramTys: [LLVMTypeRef] = []
                for a in args { guard let t = ty(a.type, span) else { return nil }; paramTys.append(t) }
                // An imported function's callee name is its per-origin identity `origin@name`
                // (task 100.2.3.2); decode it to the producer's mangled symbol so this external
                // declaration matches the definition the dependency emitted.
                let symbol: String
                if let (origin, bare) = ExternalName.decode(name) {
                    symbol = Mangle.free(bare, qualifier: Mangle.qualifier(module: origin.split(separator: "/").map(String.init)))
                } else {
                    symbol = Mangle.free(name)
                }
                let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys)
                e.callables[key] = Callable(fn: fn, ty: fnTy,
                                            ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                         body: [], isMutating: false, span: span),
                                            selfType: nil, selfByPointer: false)
                return e.buildCall(fn, fnTy, args.map { val($0) })
            }
            // An instance method on an imported type (task 100.4.3.5): its body lives in the producer, so
            // declare the producer's symbol and link. The receiver type is origin-encoded in the callee
            // (`m:<origin@Type>:method`); decode the origin for the qualifier, matching the symbol the
            // dependency emitted. Parameter types (self included) follow the values ssairgen produced — a
            // class receiver is a reference, a non-mutating value receiver is by value. A *mutating* value
            // method would need its self-by-pointer ABI, which awaits `isMutating` in the `.nmi` (B).
            if name.hasPrefix("m:") {
                let rest = name.dropFirst(2)
                if let colon = rest.firstIndex(of: ":"),
                   case let typePart = String(rest[rest.startIndex..<colon]),
                   let (origin, bareType) = ExternalName.decode(typePart) {
                    let method = String(rest[rest.index(after: colon)...])
                    // Erased generic method (task 100.4.3.5.3.3): `typePart` is a mono'd instantiation of
                    // an imported generic type whose method the producer compiled once erased. Route
                    // through the witness ABI with the receiver's type-arg VWTs to the erased symbol (no
                    // type-arg suffix), rather than the undefined monomorphized method symbol.
                    if let typeArgs = e.monoTypeArgs[typePart] {
                        let erasedTypeKey = String(typePart.prefix { $0 != "<" })   // util@Box
                        if let sig = e.externalGenericSigs["m:\(erasedTypeKey):\(method)"] {
                            let bareBase = String(bareType.prefix { $0 != "<" })    // Box
                            let symbol = Mangle.method(bareBase, method,
                                qualifier: Mangle.qualifier(module: origin.split(separator: "/").map(String.init)))
                            return emitErasedExternalCall("m:\(erasedTypeKey):\(method)", sig: sig, args: args,
                                typeArgs: typeArgs, resultType: resultType, span: span, symbolOverride: symbol)
                        }
                    }
                    guard let retTy = ty(resultType, span) else { return nil }
                    let argVals = args.map { val($0) }
                    let paramTys = argVals.map { LLVMTypeOf($0)! }
                    let symbol = Mangle.method(bareType, method,
                                               qualifier: Mangle.qualifier(module: origin.split(separator: "/").map(String.init)))
                    let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys)
                    e.callables[key] = Callable(fn: fn, ty: fnTy,
                                                ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                             body: [], isMutating: false, span: span),
                                                selfType: nil, selfByPointer: false)
                    return e.buildCall(fn, fnTy, argVals)
                }
            }
            // A property accessor `m:Type:prop.get`/`.set` with no method body is a stored-field
            // requirement — ssairgen devirtualized it to a direct call; lower it to a field access.
            if let v = lowerStoredAccessor(name, args, span) { return v }
            e.fail("7.2.3: unknown call target '\(name)'", span); return nil
        }
    }

    // Call an imported generic function through the erased witness-passing ABI (task 100.4.3.4;
    // backend.md §4) — the caller half of `declareErasedFunction`. The producer compiled the generic
    // once behind hidden leading parameters; here the consumer threads the VWTs for its concrete type
    // arguments, boxes each `.typeParam` value into a stack buffer, and reads the result back from a
    // caller-allocated result buffer.
    private func emitErasedExternalCall(_ name: String, sig: ExternalGenericSig, args: [SSAValue],
                                        typeArgs: [Type], resultType: Type, span: Span,
                                        symbolOverride: String? = nil) -> LLVMValueRef? {
        guard typeArgs.count == sig.generics.count, args.count == sig.params.count else {
            e.fail("100.4.3.4: erased call of '\(name)' has \(typeArgs.count) type arg(s) / \(args.count) value arg(s), signature wants \(sig.generics.count) / \(sig.params.count)", span)
            return nil
        }
        let returnsTP = mentionsTypeParam(sig.ret)

        // The PWT arguments (task 100.4.3.3.3): one per (type parameter, bound), bounds name-sorted —
        // the identical order the producer declares. Each is the concrete type argument's erased witness
        // table for that bound. A non-POD **value-type** conformer crosses soundly now — its erased arg
        // buffer is registered as a typed GC root below (the `shadowBufs` path, task 100.4.3.6), and the
        // VWT threaded for it carries the value-layout descriptor the walk reads. A **class/actor**
        // conformer (different self-ABI) and a **covariant-`Self`** requirement are still rejected, deeper
        // — when `witnessInstanceErased` builds the thunks (`bridgeErasedThunkSelf` / `methodThunkErased`).
        var pwtConformers: [(type: String, iface: String)] = []
        for (i, bounds) in sig.bounds.enumerated() {
            guard bounds.isEmpty || { if case .named = typeArgs[i] { return true } else { return false } }() else {
                e.fail("100.4.3.3.3: cross-module bounded generic needs a nominal type argument, got '\(typeArgs[i])'", span)
                return nil
            }
            for iface in bounds.sorted() {
                guard case .named(let tn, _) = typeArgs[i] else { return nil }
                pwtConformers.append((tn, iface))
            }
        }

        // The erased signature, matching the producer's `declareErasedFunction`: a VWT pointer per type
        // parameter, then a PWT pointer per (type parameter, bound), then a result buffer when the return
        // mentions a type parameter, then the value parameters (a `.typeParam` one indirect as a buffer
        // pointer; a concrete one by value).
        var paramTys: [LLVMTypeRef] = []
        for _ in sig.generics { paramTys.append(e.i8ptr) }
        for _ in pwtConformers { paramTys.append(e.i8ptr) }
        if returnsTP { paramTys.append(e.i8ptr) }
        for p in sig.params {
            // A generic **class** receiver is a managed `p1` reference, passed directly (task 100.4.3.9); a
            // value `.typeParam` / `.generic` buffer is an i8ptr; a concrete param is its own type.
            if case .generic(let gb, _) = p, e.classMap[gb] != nil { paramTys.append(e.p1) }
            else if mentionsTypeParam(p) { paramTys.append(e.i8ptr) }
            else { guard let t = ty(p, span) else { return nil }; paramTys.append(t) }
        }
        let fnRetTy: LLVMTypeRef = returnsTP ? e.voidTy : (ty(resultType, span) ?? e.voidTy)

        // The producer's erased symbol — its qualified name with no type-argument suffix — decoded from
        // the callee's per-origin identity `origin@bare` (task 100.2.3.2), so this matches the definition.
        let symbol: String
        if let symbolOverride {           // an erased generic *method* — `Mangle.method`, computed by the caller
            symbol = symbolOverride
        } else if let (origin, bare) = ExternalName.decode(name) {
            symbol = Mangle.free(bare, qualifier: Mangle.qualifier(module: origin.split(separator: "/").map(String.init)))
        } else {
            symbol = Mangle.free(name)
        }
        let key = "f:\(name)"
        let fn: LLVMValueRef, fnTy: LLVMTypeRef
        if let c = e.callables[key] { fn = c.fn; fnTy = c.ty }
        else {
            let declared = e.emitFunction(symbol, ret: fnRetTy, params: paramTys)
            e.callables[key] = Callable(fn: declared.fn, ty: declared.ty,
                                        ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                     body: [], isMutating: false, span: span),
                                        selfType: nil, selfByPointer: false)
            fn = declared.fn; fnTy = declared.ty
        }

        var callArgs: [LLVMValueRef?] = []
        for t in typeArgs { callArgs.append(e.valueWitness(t)) }
        for pw in pwtConformers {
            guard let w = e.witnessInstanceErased(pw.type, pw.iface) else { return nil }
            callArgs.append(w)
        }
        var resultBuf: LLVMValueRef? = nil
        if returnsTP {
            guard let rt = ty(resultType, span) else { return nil }
            let buf = e.entryAlloca(rt, "erased.ret")
            resultBuf = buf
            callArgs.append(buf)
        }
        // Non-POD `T` arg buffers to register as typed GC roots across the call (task 100.4.3.6): the
        // collector can't see managed pointers inside an opaque `T` buffer, so without this the callee's
        // allocations would strand or dangle them. Each pairs the buffer with its value-layout VWT.
        var shadowBufs: [(buf: LLVMValueRef, vwt: LLVMValueRef)] = []
        for (i, p) in sig.params.enumerated() {
            let v = val(args[i])
            // A generic **class** receiver is already a managed `p1` pointer — pass it directly, no buffer
            // spill (task 100.4.3.9). The statepoint GC tracks it as an ordinary pointer argument.
            if case .generic(let gb, _) = p, e.classMap[gb] != nil {
                callArgs.append(v)
            } else if mentionsTypeParam(p) {
                // A composed value receiver (`sig.params[0]` typed `.generic`) that ssairgen already
                // materialized as a pointer is its own storage buffer: a mutating value method passes `self`
                // by its real address (ssairgen's `structAddr`), so thread it through rather than copying into
                // a fresh buffer — the producer's erased `T`-field write then lands in the caller's storage
                // and sticks past the call (task 100.4.3.10). A read-only value self arrives as a first-class
                // aggregate, and a bare `.typeParam` value (incl. a managed class type argument, itself a
                // pointer) is the value to box — both are spilled into a buffer as before.
                let buf: LLVMValueRef
                let isComposed: Bool = { if case .generic = p { return true } else { return false } }()
                if isComposed, LLVMGetTypeKind(LLVMTypeOf(v)) == LLVMPointerTypeKind {
                    buf = v
                } else {
                    guard let at = ty(args[i].type, span) else { return nil }
                    let a = e.entryAlloca(at, "erased.arg")
                    LLVMBuildStore(b, v, a)
                    buf = a
                }
                callArgs.append(buf)
                var offs: [Int32] = []
                e.collectManagedOffsets(args[i].type, baseSlot: 0, into: &offs)
                if !offs.isEmpty { shadowBufs.append((buf, e.valueWitness(args[i].type))) }
            } else {
                callArgs.append(v)
            }
        }

        // Register the non-POD buffers on the current fiber's typed-root shadow stack, around the call.
        // A node per buffer rides this (addrspace-0) frame; `rtShadowPopTo` restores the saved top on
        // return. POD args are left unregistered — the hybrid fast path keeps them pure inline buffers.
        var savedTop: LLVMValueRef? = nil
        if !shadowBufs.isEmpty {
            let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i8ptr, params: [])
            savedTop = e.buildCall(save.0, save.1, [])
            let push = e.preludeFn("nomu_fn_rtShadowPush", ret: e.voidTy, params: [e.i8ptr, e.i8ptr, e.i8ptr])
            let nodeTy = e.structTy([e.i8ptr, e.i8ptr, e.i8ptr])
            for sb in shadowBufs {
                let node = e.entryAlloca(nodeTy, "shadow.node")
                _ = e.buildCall(push.0, push.1, [node, sb.buf, sb.vwt])
            }
        }

        let call = e.buildCall(fn, fnTy, callArgs)

        if let st = savedTop {
            let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i8ptr])
            _ = e.buildCall(pop.0, pop.1, [st])
        }
        if returnsTP, let rt = ty(resultType, span), let buf = resultBuf {
            return LLVMBuildLoad2(b, rt, buf, "erased.res")
        }
        return call
    }

    // A stored-field-backed property accessor `m:Type:prop.get` / `m:Type:prop.set` reached as a direct
    // call (no method body exists) — read/write the field directly. Mirrors the NOIR egress's
    // stored-field getter/setter path. `self` is args[0] (a struct value for a getter, a pointer for a
    // class or a mutating setter); the setter's new value is args[1]. Returns nil if `name` is not such
    // an accessor.
    private func lowerStoredAccessor(_ name: String, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard name.hasPrefix("m:") else { return nil }
        let rest = name.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let type = String(rest[rest.startIndex..<colon])
        let method = String(rest[rest.index(after: colon)...])
        let isGet = method.hasSuffix(".get"), isSet = method.hasSuffix(".set")
        guard isGet || isSet else { return nil }
        let prop = String(method.dropLast(4))
        guard let info = e.aggInfo(type), let pos = info.fields.firstIndex(where: { $0.name == prop }),
              let fieldTy = ty(info.fields[pos].type, span) else { return nil }
        let selfV = val(args[0])
        if isGet {
            if info.kind == .classRef {
                return LLVMBuildLoad2(b, fieldTy, e.structGEP(info.ty, selfV, e.fieldLLVMIndex(.classRef, pos)), "ld")
            }
            return LLVMBuildExtractValue(b, selfV, UInt32(pos), "fld")   // struct value receiver
        }
        // setter: `self` is a pointer (class, or a mutating struct receiver passed by address)
        let slot = e.structGEP(info.ty, selfV, e.fieldLLVMIndex(info.kind, pos))
        if info.kind == .classRef { e.storeField(selfV, slot, val(args[1])) }
        else { LLVMBuildStore(b, val(args[1]), slot) }
        return LLVMConstInt(e.i64, 0, 0)
    }

}
