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

        guard let mainFn = module.functions.first(where: { $0.name == "main" }) else { return }
        e.setupDebugInfo(sourceFile: mainFn.span.file)

        for f in module.functions { declareFunction(f) }
        for f in module.functions {
            if error != nil { break }
            defineFunction(f)
        }

        e.emitTypeMaps()
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
        guard f.name.hasPrefix("m:") else {
            let symbol = f.name == "main" ? "nomu_main" : "nomu_fn_\(sanitize(f.name))"
            return ("f:\(f.name)", nil, false, symbol)
        }
        let rest = f.name.dropFirst(2)
        let colon = rest.firstIndex(of: ":")!
        let type = String(rest[rest.startIndex..<colon])
        let method = String(rest[rest.index(after: colon)...])
        let isActor = e.actorMap[type] != nil
        let isReference = e.classMap[type] != nil || isActor
        let byPointer = isReference || f.isMutating
        let sanitized = method.replacingOccurrences(of: ".", with: "_")
        let symbol = isActor ? "nomu_on_\(type)_\(sanitized)" : "nomu_m_\(type)_\(sanitized)"
        return ("m:\(f.name.dropFirst(2))", type, byPointer, symbol)
    }

    private func sanitize(_ s: String) -> String {
        String(s.map { $0 == ":" || $0 == "." ? "_" : $0 })
    }

    // Create the LLVM function for `f` and register it in `callables` with the ABI-correct signature —
    // the self ABI (by-pointer for a class/actor/mutating receiver, else by value) mirrors
    // `declareCallable`, so a witness/actor thunk built later dispatches through a matching signature.
    private func declareFunction(_ f: SSAFunction) {
        let (key, selfType, byPointer, symbol) = keyAndSelf(f)
        if e.callables[key] != nil { return }
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
        let dummy = NOIRFunc(name: f.name, params: [], returnType: f.returnType,
                             body: [], isMutating: f.isMutating, span: f.span)
        e.callables[key] = Callable(fn: fn, ty: fnTy, ir: dummy,
                                    selfType: selfType, selfByPointer: byPointer)
    }

    // MARK: - Body

    private func defineFunction(_ f: SSAFunction) {
        let (key, _, _, _) = keyAndSelf(f)
        guard let c = e.callables[key] else { return }
        values = [:]; blockMap = [:]; blocksById = [:]; spawnHandles = [:]; pendingIncomings.removeAll(keepingCapacity: true)
        curFnName = f.name
        e.currentFn = c.fn

        // Function parameters map to the LLVM parameters by position (the SSA param order — self first
        // for a method — matches the declared signature).
        for (i, p) in f.params.enumerated() { values[p.id] = LLVMGetParam(c.fn, UInt32(i)) }

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

        // Pass B — lower each block's instructions and terminator. A GC safepoint poll goes at the top
        // of every loop header (a back-edge target): a poll-free loop can't be paused by a
        // stop-the-world collector, so the mutator must reach a safepoint on every back-edge (D3). The
        // NOIR walker does the same at each `while` header; placed after the header's φs and before its
        // body, so every iteration passes through it. (Eliding it when the loop already hits a safepoint
        // each iteration — NOIR's `loopBodyHasSafepoint` — is a later refinement / the safepoint pass.)
        let headers = loopHeaders(f)
        for blk in f.blocks {
            LLVMPositionBuilderAtEnd(b, blockMap[blk.id])
            if headers.contains(blk.id) {
                e.setDebugLoc(blk.insts.first?.span ?? blk.terminator.span)
                e.emitSafepointPoll()
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

    private func lowerBlock(_ blk: SSABlock) {
        var i = 0
        while i < blk.insts.count {
            let inst = blk.insts[i]
            e.setDebugLoc(inst.span)
            // ssairgen emits `writeBarrier(obj, v)` immediately before `store(addr, v)` for a managed
            // field write; fuse the pair into one barriered store (the combined ABI the shared
            // `storeField` emits). A standalone `store` is a plain store.
            if case .writeBarrier(let object, let bv) = inst.kind,
               i + 1 < blk.insts.count, case .store(let addr, let sv) = blk.insts[i + 1].kind, sv.id == bv.id {
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
            LLVMBuildStore(b, val(value), val(addr))
        case .writeBarrier:
            break   // handled by the fused-pair path in `lowerBlock`; a lone barrier is a no-op
        case .fieldAddr(let base, let idx):
            define(inst, fieldSlotAddr(base, idx, span))
        case .elementAddr(let base, let index):
            define(inst, elementAddr(base, index, inst.result!.type, span))
        case .arrayLen(let arr):
            define(inst, LLVMBuildLoad2(b, e.i64, e.gepByte(val(arr), LLVMConstInt(e.i64, 8, 0)), "arr.len"))
        case .boundscheck(let index, let length):
            emitBoundscheck(val(index), val(length))

        case .call(let call):
            lowerCall(call, inst: inst, span: span)

        case .mailboxInit(let obj):
            lowerMailboxInit(obj, span)
        case .actorSend(let receiver, let handler, let args):
            guard case .named(let actorName, _) = receiver.type else {
                e.fail("7.2.3: actorSend on a non-actor receiver", span); return
            }
            _ = e.emitActorSend(actorName, handler, val(receiver), args.map { val($0) }, span)
        case .spawn(let binding, let startFn, let env, let resultType):
            lowerSpawn(binding: binding, startFn: startFn, env: env, resultType: resultType, span: span)
        case .spawnJoin(let binding, let resultType):
            lowerSpawnJoin(inst, binding: binding, resultType: resultType, span: span)

        case .makeStruct(let t, let fields):
            define(inst, makeStruct(t, fields, span))
        case .makeEnum(let t, let caseIndex, let fields):
            define(inst, makeEnum(t, caseIndex, fields, span))
        case .extractField(let base, let idx):
            define(inst, LLVMBuildExtractValue(b, val(base), UInt32(idx), "fld"))
        case .enumTag(let base):
            define(inst, LLVMBuildExtractValue(b, val(base), 0, "tag"))
        case .extractPayload(let base, let caseIndex, let fieldIndex):
            define(inst, extractPayload(base, caseIndex, fieldIndex, inst.result!.type, span))

        case .box(let value, let interfaces, let onStack):
            define(inst, lowerBox(value, interfaces, onStack, span))
        case .arrayLit(let elements, let elem):
            define(inst, lowerArrayLit(elements, elem, span))
        case .makeClosure(let funcName, let env, let onStack):
            define(inst, makeClosure(funcName, env, onStack, span))
        }
    }

    private func define(_ inst: SSAInst, _ value: LLVMValueRef?) {
        guard let value = value, let result = inst.result else { return }
        values[result.id] = value
    }

    // MARK: - Terminators (block args → φ incomings)

    private func lowerTerminator(_ term: SSATerm) {
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
            if let v = v { LLVMBuildRet(b, val(v)) } else { LLVMBuildRetVoid(b) }
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
            if let v = lowerDirectCall(name, call.args, resultType: inst.result?.type ?? .void, span: span) {
                define(inst, v)
            }
        case .witness(let receiver, let interface, let method):
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

    private func lowerDirectCall(_ name: String, _ args: [SSAValue], resultType: Type, span: Span) -> LLVMValueRef? {
        switch name {
        case "print":    return emitPrint(args, span)
        case "putByte":  return emitPutByte(args, span)
        case "concat":   return emitConcat(args, span)
        case "sleep":    return emitSleep(args, span)
        case "readLine": return emitReadLine()
        case "__array_count_int": return LLVMBuildLoad2(b, e.i64, e.gepByte(val(args[0]), LLVMConstInt(e.i64, 8, 0)), "arr.count")
        case "__arraySet":    return emitArraySet(args, span)
        case "__arrayAppend": return emitArrayAppend(args, span)
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
        case "__rawLoad":
            guard let lt = ty(resultType, span) else { return nil }
            return LLVMBuildLoad2(b, lt, e.gepByte(val(args[0]), val(args[1])), "raw.load")
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
        case "__gcTypeCount":
            let g = LLVMGetNamedGlobal(e.mod, "nomu_gc_typemap_count") ?? LLVMAddGlobal(e.mod, e.i64, "nomu_gc_typemap_count")
            return LLVMBuildLoad2(b, e.i64, g, "gc.tcount")
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
        case "__void_timemonotonic_int": return emitTimeMonotonic(args, span)
        default:
            if Builtins.cLeaf.contains(name) { return emitCLeaf(name, args) }
            // A user free function or a method symbol — resolve the declared callable.
            let key = name.hasPrefix("m:") ? name : "f:\(name)"
            if let c = e.callables[key] {
                return e.buildCall(c.fn, c.ty, args.map { val($0) })
            }
            // A property accessor `m:Type:prop.get`/`.set` with no method body is a stored-field
            // requirement — ssairgen devirtualized it to a direct call; lower it to a field access.
            if let v = lowerStoredAccessor(name, args, span) { return v }
            e.fail("7.2.3: unknown call target '\(name)'", span); return nil
        }
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

    // MARK: - Builtins (over already-lowered operands)

    private func emitPrint(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { e.fail("7.2.3: print expects one argument", span); return nil }
        let value = val(arg)
        let (fn, pty) = e.runtimeFn("printf", ret: e.i32, params: [e.i8ptr], varArg: true)
        switch arg.type {
        case .int:
            return e.buildCall(fn, pty, [e.intFormat(), value])
        case .double:
            let (pf, pfty) = e.runtimeFn("rt_print_double", ret: e.voidTy, params: [e.f64], varArg: false)
            return e.buildCall(pf, pfty, [value])
        case .uint8:
            return e.buildCall(fn, pty, [e.intFormat(), LLVMBuildZExt(b, value, e.i64, "u82i")])
        case .uint64:
            return e.buildCall(fn, pty, [e.uintFormat(), value])
        case .bool:
            return e.buildCall(fn, pty, [e.intFormat(), LLVMBuildZExt(b, value, e.i64, "b2i")])
        case .string:
            let data = LLVMBuildExtractValue(b, value, 0, "data")
            let len = LLVMBuildExtractValue(b, value, 1, "len")
            let len32 = LLVMBuildTrunc(b, len, e.i32, "len32")
            return e.buildCall(fn, pty, [e.strFormat(), len32, data])
        default:
            e.fail("7.2.3: print supports Int, UInt8, Double, Bool, or String", span); return nil
        }
    }

    // putByte(b): write one raw byte to stdout via libc `putchar`. Output is libc-buffered (block- or
    // line-buffered) and flushed on normal program exit; no explicit flush primitive is exposed.
    private func emitPutByte(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { e.fail("putByte expects one argument", span); return nil }
        let (fn, fty) = e.runtimeFn("putchar", ret: e.i32, params: [e.i32], varArg: false)
        let c = LLVMBuildZExt(b, val(arg), e.i32, "byte")
        return e.buildCall(fn, fty, [c])
    }

    private func emitTimeMonotonic(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        let (fn, pty) = e.runtimeFn("__void_timemonotonic_int", ret: e.i64, params: [], varArg: false)
        return e.buildCall(fn, pty, [])
    }

    private func emitConcat(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else { e.fail("7.2.3: concat expects two arguments", span); return nil }
        let (fn, fty) = e.runtimeFn("rt_str_concat", ret: e.strTy, params: [e.strTy, e.strTy], varArg: false)
        return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
    }

    private func emitSleep(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first else { e.fail("7.2.3: sleep expects one argument", span); return nil }
        let (fn, fty) = e.runtimeFn("rt_sleep_ms", ret: e.i64, params: [e.i64], varArg: false)
        return e.buildCall(fn, fty, [val(arg)])
    }

    private func emitReadLine() -> LLVMValueRef? {
        let (fn, fty) = e.runtimeFn("rt_read_line", ret: e.strTy, params: [e.i32], varArg: false)
        return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])
    }

    private func emitCLeaf(_ name: String, _ args: [SSAValue]) -> LLVMValueRef? {
        let sig = Builtins.signature(name)
        let paramTys = ([sig.receiver] + sig.params).map { cType($0) }
        let retIsBool = sig.ret == .bool
        let retTy = retIsBool ? e.i64 : cType(sig.ret)
        let (fn, fty) = e.runtimeFn(name, ret: retTy, params: paramTys, varArg: false)
        guard let r = e.buildCall(fn, fty, args.map { val($0) }) else { return nil }
        return retIsBool ? LLVMBuildTrunc(b, r, e.i1, "b") : r
    }

    private func cType(_ t: Type) -> LLVMTypeRef {
        switch t {
        case .string: return e.strTy
        case .double: return e.f64
        case .bool:   return e.i1
        default:      return e.i64
        }
    }

    // MARK: - Arrays

    private func lowerArrayLit(_ elements: [SSAValue], _ elem: Type, _ span: Span) -> LLVMValueRef? {
        let stride = e.arrayElemStride(elem)
        let n = elements.count
        let handle = e.rtAllocManaged(LLVMConstInt(e.i64, 24, 0))
        LLVMBuildStore(b, LLVMConstInt(e.i64, e.arrayHandleTypeId(), 0), handle)
        LLVMBuildStore(b, LLVMConstInt(e.i64, UInt64(n), 0), e.gepByte(handle, LLVMConstInt(e.i64, 8, 0)))
        let buf = e.rtAllocManaged(LLVMConstInt(e.i64, UInt64(16 + n * stride), 0))
        LLVMBuildStore(b, LLVMConstInt(e.i64, e.arrayBufTypeId(elem), 0), buf)
        LLVMBuildStore(b, LLVMConstInt(e.i64, UInt64(n), 0), e.gepByte(buf, LLVMConstInt(e.i64, 8, 0)))
        for (i, el) in elements.enumerated() {
            e.storeField(buf, e.gepByte(buf, LLVMConstInt(e.i64, UInt64(16 + i * stride), 0)), val(el))
        }
        e.storeField(handle, e.gepByte(handle, LLVMConstInt(e.i64, 16, 0)), buf)
        return handle
    }

    // The bounds-check trap sequence (`index UGE length` → `rt_bounds_trap` → unreachable); on return
    // the builder sits in the in-bounds continuation.
    private func emitBoundscheck(_ idx: LLVMValueRef, _ len: LLVMValueRef) {
        guard let fn = e.currentFn else { return }
        let oob = LLVMBuildICmp(b, LLVMIntUGE, idx, len, "arr.oob")!
        let trapBB = LLVMAppendBasicBlockInContext(ctx, fn, "arr.trap")!
        let okBB = LLVMAppendBasicBlockInContext(ctx, fn, "arr.ok")!
        LLVMBuildCondBr(b, oob, trapBB, okBB)
        LLVMPositionBuilderAtEnd(b, trapBB)
        let (trap, tty) = e.runtimeFn("rt_bounds_trap", ret: e.voidTy, params: [e.i64, e.i64], varArg: false)
        _ = e.buildCall(trap, tty, [idx, len])
        LLVMBuildUnreachable(b)
        LLVMPositionBuilderAtEnd(b, okBB)
    }

    private func elementAddr(_ handle: SSAValue, _ index: SSAValue, _ elemType: Type, _ span: Span) -> LLVMValueRef {
        let buf = LLVMBuildLoad2(b, e.p1, e.gepByte(val(handle), LLVMConstInt(e.i64, 16, 0)), "arr.buf")!
        let stride = LLVMConstInt(e.i64, UInt64(e.arrayElemStride(elemType)), 0)
        let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, 16, 0), LLVMBuildMul(b, val(index), stride, "arr.mul"), "arr.off")!
        return e.gepByte(buf, off)
    }

    private func emitArraySet(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 3 else { e.fail("7.2.3: __arraySet expects 3 args", span); return nil }
        let handle = val(args[0]), idxV = val(args[1]), value = val(args[2])
        let len = LLVMBuildLoad2(b, e.i64, e.gepByte(handle, LLVMConstInt(e.i64, 8, 0)), "arr.len")!
        emitBoundscheck(idxV, len)
        let buf = LLVMBuildLoad2(b, e.p1, e.gepByte(handle, LLVMConstInt(e.i64, 16, 0)), "arr.buf")!
        let stride = LLVMConstInt(e.i64, UInt64(e.arrayElemStride(args[2].type)), 0)
        let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, 16, 0), LLVMBuildMul(b, idxV, stride, "arr.mul"), "arr.off")!
        e.storeField(buf, e.gepByte(buf, off), value)
        return LLVMConstInt(e.i64, 0, 0)
    }

    private func emitArrayAppend(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2, let fn = e.currentFn else { e.fail("7.2.3: __arrayAppend expects 2 args", span); return nil }
        let elem = args[1].type
        let handle = val(args[0]), value = val(args[1])
        let stride = e.arrayElemStride(elem)
        let strideV = LLVMConstInt(e.i64, UInt64(stride), 0)
        let len = LLVMBuildLoad2(b, e.i64, e.gepByte(handle, LLVMConstInt(e.i64, 8, 0)), "app.len")!
        let buf0 = LLVMBuildLoad2(b, e.p1, e.gepByte(handle, LLVMConstInt(e.i64, 16, 0)), "app.buf")!
        let cap = LLVMBuildLoad2(b, e.i64, e.gepByte(buf0, LLVMConstInt(e.i64, 8, 0)), "app.cap")!
        let full = LLVMBuildICmp(b, LLVMIntUGE, len, cap, "app.full")!
        let growBB = LLVMAppendBasicBlockInContext(ctx, fn, "app.grow")!
        let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "app.cont")!
        LLVMBuildCondBr(b, full, growBB, contBB)

        LLVMPositionBuilderAtEnd(b, growBB)
        let isZero = LLVMBuildICmp(b, LLVMIntEQ, cap, LLVMConstInt(e.i64, 0, 0), "app.cap0")!
        let dbl = LLVMBuildMul(b, cap, LLVMConstInt(e.i64, 2, 0), "app.dbl")!
        let newCap = LLVMBuildSelect(b, isZero, LLVMConstInt(e.i64, 4, 0), dbl, "app.newcap")!
        let newBytes = LLVMBuildAdd(b, LLVMConstInt(e.i64, 16, 0), LLVMBuildMul(b, newCap, strideV, "app.nb"), "app.bytes")!
        let newBuf = e.rtAllocManaged(newBytes)
        LLVMBuildStore(b, LLVMConstInt(e.i64, e.arrayBufTypeId(elem), 0), newBuf)
        LLVMBuildStore(b, newCap, e.gepByte(newBuf, LLVMConstInt(e.i64, 8, 0)))
        let copyBytes = LLVMBuildMul(b, len, strideV, "app.copy")!
        let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
        _ = e.buildCall(memcpy, mty, [e.toUnmanaged(e.gepByte(newBuf, LLVMConstInt(e.i64, 16, 0))),
                                      e.toUnmanaged(e.gepByte(buf0, LLVMConstInt(e.i64, 16, 0))), copyBytes])
        e.storeField(handle, e.gepByte(handle, LLVMConstInt(e.i64, 16, 0)), newBuf)
        LLVMBuildBr(b, contBB)

        LLVMPositionBuilderAtEnd(b, contBB)
        let buf = LLVMBuildLoad2(b, e.p1, e.gepByte(handle, LLVMConstInt(e.i64, 16, 0)), "app.buf2")!
        let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, 16, 0), LLVMBuildMul(b, len, strideV, "app.mul"), "app.off")!
        e.storeField(buf, e.gepByte(buf, off), value)
        LLVMBuildStore(b, LLVMBuildAdd(b, len, LLVMConstInt(e.i64, 1, 0), "app.inc"), e.gepByte(handle, LLVMConstInt(e.i64, 8, 0)))
        return LLVMConstInt(e.i64, 0, 0)
    }

    // MARK: - Actors, closures, spawn

    private func lowerMailboxInit(_ obj: SSAValue, _ span: Span) {
        guard case .named(let name, _) = obj.type, let at = e.actorType(name) else {
            e.fail("7.2.3: mailboxInit on a non-actor", span); return
        }
        let mailbox = e.rtAllocManaged(LLVMConstInt(e.i64, 40, 0))
        e.writeTypeIdHeaderRaw(mailbox, e.mailboxTypeIdValue())
        e.storeField(val(obj), e.structGEP(at, val(obj), e.actorMailboxIndex(name)), mailbox)
    }

    // A closure value is a managed `{ i64 header, i8ptr fn, p1 env }` object (the env carries the
    // captures, built separately as a class object). Same shape as an `any` box (one managed field at
    // byte 16), so it reuses the any-box type-id for GC scanning.
    private func makeClosure(_ funcName: String, _ env: SSAValue?, _ onStack: Bool, _ span: Span) -> LLVMValueRef? {
        guard let c = e.callables["f:\(funcName)"] else { e.fail("7.2.3: unknown closure body '\(funcName)'", span); return nil }
        let cloTy = e.structTy([e.i64, e.i8ptr, e.p1])
        // A non-escaping closure object lives on the stack (EA 7.3): an entry alloca in place of the
        // managed heap object. Same `{header, fn, env}` layout, so the indirect-call GEPs are unchanged;
        // the env field stays `p1` (the env object itself is still heap this slice). `storeField` sees
        // an addrspace(0) base and emits a plain store (no barrier, I7); SROA then scalar-replaces the
        // slot so its managed env field becomes a statepoint-tracked root (I5).
        let obj: LLVMValueRef = onStack ? e.entryAlloca(cloTy, "clo") : e.rtAllocManaged(LLVMConstInt(e.i64, 24, 0))
        LLVMBuildStore(b, LLVMConstInt(e.i64, e.anyBoxTypeId(), 0), e.structGEP(cloTy, obj, 0))
        LLVMBuildStore(b, c.fn, e.structGEP(cloTy, obj, 1))
        let envVal = env != nil ? val(env!) : LLVMConstNull(e.p1)
        e.storeField(obj, e.structGEP(cloTy, obj, 2), envVal)
        return obj
    }

    // Start `startFn(env)` on a fiber. The lifted `spawn:N(env: envClass) -> R` returns its result
    // directly, but the runtime's fiber routine ABI is `i8ptr(i8ptr)`, so wrap it in a per-spawn thunk
    // that re-manages the env pointer, calls the lifted body, boxes the result, and returns the box.
    private func lowerSpawn(binding: Int, startFn: String, env: SSAValue?, resultType: Type, span: Span) {
        guard let start = e.callables["f:\(startFn)"], let resTy = ty(resultType, span) else {
            e.fail("7.2.3: unknown spawn body '\(startFn)'", span); return
        }
        let (thunk, _) = e.emitFunction("nomu_spawnthunk_\(binding)", ret: e.i8ptr, params: [e.i8ptr])
        e.withStubBody(thunk) {
            let envArg = LLVMGetParam(thunk, 0)!   // addr0 void* — matches `spawn:N`'s addr0 env param
            let r = e.buildCall(start.fn, start.ty, [envArg])!
            let bytes = max(e.slotCount(resultType) * 8, 8)
            let box = e.rtAllocManaged(LLVMConstInt(e.i64, UInt64(bytes), 0))
            e.storeField(box, box, r)
            LLVMBuildRet(b, e.toUnmanaged(box))
        }
        let (spawn, sty) = e.runtimeFn("fiber_spawn", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr], varArg: false)
        let envArg = env != nil ? e.toUnmanaged(val(env!)) : LLVMConstNull(e.i8ptr)
        let fiber = e.buildCall(spawn, sty, [thunk, envArg])!
        _ = resTy
        let handleSlot = e.entryAlloca(e.spawnHandleTy, "spawn.h")
        LLVMBuildStore(b, fiber, e.structGEP(e.spawnHandleTy, handleSlot, 0))
        spawnHandles[binding] = handleSlot
    }

    private func lowerSpawnJoin(_ inst: SSAInst, binding: Int, resultType: Type, span: Span) {
        guard let handleSlot = spawnHandles[binding] else { return }
        let (sj, sty) = e.runtimeFn("spawn_join", ret: e.i8ptr, params: [e.i8ptr], varArg: false)
        let box = e.buildCall(sj, sty, [handleSlot])!
        if let result = inst.result, let rt = ty(resultType, span) {
            values[result.id] = LLVMBuildLoad2(b, rt, box, "spawn.res")
        }
    }
}
