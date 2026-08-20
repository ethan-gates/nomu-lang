import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Statements

    func lowerBlock(_ stmts: [NOIRStmt]) {
        for s in stmts {
            if error != nil || blockTerminated() { return }
            lowerStmt(s)
        }
    }

    // A stack slot for a local/temporary, always created in the function's **entry block** — never at
    // the current insertion point. LLVM only treats entry-block allocas as fixed frame slots; an
    // alloca emitted inside a loop body is a *dynamic* stack allocation that grows the stack every
    // iteration and overflows a fiber's fixed stack (128 KB) after enough iterations. `-O2` hoists
    // these anyway, so this only shows up in the debug pipeline (mem2reg/sroa, no LICM/DCE). Reusing
    // one slot across iterations is correct: locals are dead at the loop back-edge, and closures
    // snapshot captures **by value** at creation (`allocAndFillEnv`), so per-iteration binding does not
    // depend on a fresh slot. A scratch builder keeps the main builder's position untouched.
    func entryAlloca(_ ty: LLVMTypeRef, _ name: String) -> LLVMValueRef {
        guard let fn = currentFn, let entry = LLVMGetEntryBasicBlock(fn) else {
            return LLVMBuildAlloca(b, ty, name)!
        }
        let tmp = LLVMCreateBuilderInContext(ctx)!
        defer { LLVMDisposeBuilder(tmp) }
        if let first = LLVMGetFirstInstruction(entry) {
            LLVMPositionBuilderBefore(tmp, first)
        } else {
            LLVMPositionBuilderAtEnd(tmp, entry)
        }
        return LLVMBuildAlloca(tmp, ty, name)!
    }

    func lowerStmt(_ stmt: NOIRStmt) {
        setDebugLoc(stmt.span)   // 8.3: line-table entry; inherited by this statement's instructions
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            guard llvmType(value.type, stmt.span) != nil, let v = lowerExpr(value) else { return }
            // Slot type follows the produced value, not the nominal type: usually identical, but a
            // 6.5.2 stack-allocated class flows as an addrspace(0) pointer rather than the managed p1.
            let ty = LLVMTypeOf(v)!
            let slot = entryAlloca(ty, name)
            LLVMBuildStore(b, v, slot)
            locals[name] = (slot, ty)
            declareLocal(name, type: value.type, addr: slot, line: stmt.span.begin.line)

        case .assign(let target, let value):
            assignTo(target, value)

        case .compoundAssign(let target, let value):
            // Nomu's only compound assignment is `+=`, on Int or Double (CodegenIR emits `l += r`).
            guard let dst = lvalue(target) else { return }
            guard let v = lowerExpr(value) else { return }
            let cur = LLVMBuildLoad2(b, dst.ty, dst.addr, "cur")
            let sum = value.type == .double ? LLVMBuildFAdd(b, cur, v, "fadd")
                                            : LLVMBuildAdd(b, cur, v, "add")
            LLVMBuildStore(b, sum, dst.addr)

        case .ret(let e):
            // A returned value is computed before joins/unlock so its own spawn reads happen first.
            let v = e != nil ? lowerExpr(e!) : nil
            if e != nil, v == nil { return }
            joinActiveSpawns()
            if let v = v { LLVMBuildRet(b, v) } else { LLVMBuildRetVoid(b) }

        case .spawnLet(let name, let value, let resultType):
            lowerSpawnLet(name: name, value: value, resultType: resultType, span: stmt.span)

        case .ifStmt(let cond, let then, let els):
            lowerIf(cond: cond, then: then, els: els)

        case .whileStmt(let cond, let body):
            lowerWhile(cond: cond, body: body)

        case .breakStmt:
            guard let loop = loopStack.last else { return }
            joinSpawnsFrom(loop.spawnBase)
            LLVMBuildBr(b, loop.exit)

        case .continueStmt:
            guard let loop = loopStack.last else { return }
            joinSpawnsFrom(loop.spawnBase)
            LLVMBuildBr(b, loop.header)

        case .switchStmt(let sw):
            lowerSwitch(sw)

        case .exprStmt(let e):
            _ = lowerExpr(e)
        }
    }

    func lowerIf(cond: NOIRExpr, then: [NOIRStmt], els: [NOIRStmt]?) {
        guard let fn = currentFn, let condV = lowerExpr(cond) else { return }
        let condBit = condV   // 8.5.2 — a Bool is already i1; branch on it directly
        let thenBB = LLVMAppendBasicBlockInContext(ctx, fn, "then")
        let elseBB = els != nil ? LLVMAppendBasicBlockInContext(ctx, fn, "else") : nil
        let mergeBB = LLVMAppendBasicBlockInContext(ctx, fn, "ifcont")

        LLVMBuildCondBr(b, condBit, thenBB, elseBB ?? mergeBB)

        LLVMPositionBuilderAtEnd(b, thenBB)
        var saved = locals; lowerBlock(then); locals = saved
        if !blockTerminated() { LLVMBuildBr(b, mergeBB) }

        if let els = els, let elseBB = elseBB {
            LLVMPositionBuilderAtEnd(b, elseBB)
            saved = locals; lowerBlock(els); locals = saved
            if !blockTerminated() { LLVMBuildBr(b, mergeBB) }
        }
        LLVMPositionBuilderAtEnd(b, mergeBB)
    }

    // `while cond { body }` — header/body/exit blocks (`loops.md`). The header re-tests each
    // iteration; the body branches back to the header (the back-edge, where 8.4.2 will place a
    // safepoint poll). Body-scoped locals and spawns are saved on entry and restored on exit, and
    // each exiting edge (normal fall-through, `continue`, `break`) joins the spawns the body made.
    func lowerWhile(cond: NOIRExpr, body: [NOIRStmt]) {
        guard let fn = currentFn else { return }
        let headerBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.header")!
        let bodyBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.body")!
        let exitBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.exit")!

        LLVMBuildBr(b, headerBB)
        LLVMPositionBuilderAtEnd(b, headerBB)
        setDebugLoc(cond.span)
        // 8.4.2 (D3): a loop that reaches no safepoint on its own (no non-leaf call and no
        // allocation in its body) gets an inert safepoint poll each iteration, so a moving GC (M6)
        // can stop the fiber and bound time-to-safepoint. A loop that already hits a statepoint
        // every iteration needs none — elide it there. Placed at the top of the header, so every
        // back-edge (fall-through and `continue`) passes through it.
        if !loopBodyHasSafepoint(body) { emitSafepointPoll() }
        guard let condV = lowerExpr(cond) else { return }
        let condBit = condV   // 8.5.2 — a Bool is already i1; branch on it directly
        LLVMBuildCondBr(b, condBit, bodyBB, exitBB)

        LLVMPositionBuilderAtEnd(b, bodyBB)
        let base = activeSpawns.count
        let savedLocals = locals
        let savedSpawnLocals = spawnLocals
        loopStack.append(LoopCtx(header: headerBB, exit: exitBB, spawnBase: base))
        lowerBlock(body)
        if !blockTerminated() {
            joinSpawnsFrom(base)                 // normal fall-through joins the iteration's spawns
            LLVMBuildBr(b, headerBB)
        }
        loopStack.removeLast()
        locals = savedLocals
        spawnLocals = savedSpawnLocals
        activeSpawns = Array(activeSpawns.prefix(base))   // body spawns don't outlive the loop

        LLVMPositionBuilderAtEnd(b, exitBB)
    }

    // MARK: - Expressions

    func lowerExpr(_ e: NOIRExpr) -> LLVMValueRef? {
        switch e.kind {
        case .intLit(let n):
            // A UInt8 literal is an i8 constant (unsigned); every other integer literal is i64.
            if e.type == .uint8 { return LLVMConstInt(i8, UInt64(n & 0xFF), /*SignExtend=*/0) }
            return LLVMConstInt(i64, UInt64(bitPattern: Int64(n)), /*SignExtend=*/1)
        case .doubleLit(let x):
            return LLVMConstReal(f64, x)
        case .boolLit(let v):
            return LLVMConstInt(i1, v ? 1 : 0, 0)
        case .stringLit(let s):
            return lowerStringLit(s)
        case .arrayLit(let elements):
            return lowerArrayLit(elements, e.type, e.span)
        case .index(let base, let idx):
            return lowerIndex(base, idx, e.type, e.span)
        case .varRef(let name) where spawnLocals[name] != nil:
            return joinSpawn(name)
        case .varRef, .fieldAccess:
            guard let lv = lvalue(e) else { return nil }
            return LLVMBuildLoad2(b, lv.ty, lv.addr, "ld")
        case .binary(let op, let l, let r):
            return lowerBinary(op, l, r)
        case .construct(let typeName, let args):
            return lowerConstruct(typeName, args, e.span)
        case .enumInit(let typeName, let caseName, let args):
            return lowerEnumInit(typeName, caseName, args, e.span)
        case .methodCall(let receiver, let method, let args):
            return lowerMethodCall(receiver: receiver, method: method, args: args,
                                   resultType: e.type, span: e.span)
        case .call(let callee, let args, _):
            return lowerCall(callee: callee, args: args, span: e.span)
        case .closure(let params, let body):
            var ret = Type.void
            if case .function(_, let r) = e.type { ret = r }
            return lowerClosure(params: params, body: body, ret: ret, span: e.span)
        case .box(let value, let interfaces):
            return lowerBox(value, interfaces, e.span)
        }
    }

    // The address of an assignable/aggregate expression. A local or self-field yields its slot; a
    // field access GEPs into its base's address; any other value is spilled to a temp alloca so a
    // field read off an rvalue (e.g. `makePoint().x`) still works.
    func lvalue(_ e: NOIRExpr) -> (addr: LLVMValueRef, ty: LLVMTypeRef)? {
        switch e.kind {
        case .varRef(let name):
            if let l = locals[name] { return l }
            if let cs = currentSelf, let pos = cs.fields.firstIndex(where: { $0.name == name }) {
                guard let fieldTy = llvmType(cs.fields[pos].type, e.span) else { return nil }
                return (structGEP(cs.llvmTy, cs.addr, fieldLLVMIndex(cs.kind, pos)), fieldTy)
            }
            fail("8.2.4: unknown variable '\(name)'", e.span)
            return nil
        case .fieldAccess(let base, let field):
            guard case .named(let typeName, _) = base.type, let info = aggInfo(typeName),
                  let pos = info.fields.firstIndex(where: { $0.name == field }) else {
                fail("8.2.4: field access on a non-aggregate", e.span)
                return nil
            }
            // A struct's base is addressable (its value lives in memory); a class's value *is* the
            // object pointer, so GEP off that directly (past the header).
            let basePtr: LLVMValueRef
            if info.kind == .classRef {
                guard let bv = lowerExpr(base) else { return nil }
                basePtr = bv
            } else {
                guard let ba = lvalue(base) else { return nil }
                basePtr = ba.addr
            }
            guard let fieldTy = llvmType(info.fields[pos].type, e.span) else { return nil }
            return (structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos)), fieldTy)
        default:
            // An rvalue (e.g. a call result): materialize it in a temp so it has an address.
            guard let ty = llvmType(e.type, e.span), let v = lowerExpr(e) else { return nil }
            let slot = entryAlloca(ty, "tmp")
            LLVMBuildStore(b, v, slot)
            return (slot, ty)
        }
    }

    // Lower an assignment `target = value`, routing a reference write into a managed object field
    // through the write barrier (8.4.4). Mirrors `lvalue`'s assignable cases, but keeps the managed
    // object base (so the barrier can log it) and lowers the field base exactly once — computing the
    // target address before the value, as the plain-store path did (evaluation order preserved).
    // A write to a stack local or a struct-value field (addrspace 0, not a GC object) is a plain store.
    func assignTo(_ target: NOIRExpr, _ valueExpr: NOIRExpr) {
        switch target.kind {
        case .varRef(let name):
            if let l = locals[name] {
                guard let v = lowerExpr(valueExpr) else { return }
                LLVMBuildStore(b, v, l.addr)
                return
            }
            if let cs = currentSelf, let pos = cs.fields.firstIndex(where: { $0.name == name }) {
                let slot = structGEP(cs.llvmTy, cs.addr, fieldLLVMIndex(cs.kind, pos))
                guard let v = lowerExpr(valueExpr) else { return }
                if cs.kind == .classRef { storeField(cs.addr, slot, v) } else { LLVMBuildStore(b, v, slot) }
                return
            }
            fail("8.2.4: unknown variable '\(name)'", target.span)
        case .fieldAccess(let base, let field):
            guard case .named(let typeName, _) = base.type, let info = aggInfo(typeName),
                  let pos = info.fields.firstIndex(where: { $0.name == field }) else {
                fail("8.2.4: field access on a non-aggregate", target.span)
                return
            }
            let basePtr: LLVMValueRef
            if info.kind == .classRef {
                guard let bv = lowerExpr(base) else { return }   // the object pointer (managed)
                basePtr = bv
            } else {
                guard let ba = lvalue(base) else { return }      // the struct's stack address
                basePtr = ba.addr
            }
            let slot = structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos))
            guard let v = lowerExpr(valueExpr) else { return }
            if info.kind == .classRef { storeField(basePtr, slot, v) } else { LLVMBuildStore(b, v, slot) }
        default:
            guard let dst = lvalue(target), let v = lowerExpr(valueExpr) else { return }
            LLVMBuildStore(b, v, dst.addr)
        }
    }

    func lowerBinary(_ op: BinOp, _ l: NOIRExpr, _ r: NOIRExpr) -> LLVMValueRef? {
        guard let lv = lowerExpr(l), let rv = lowerExpr(r) else { return nil }
        // Double uses the floating-point opcodes; everything else is the i64 integer path. Sema
        // guarantees both operands share the numeric type, so the left operand's type decides.
        if l.type == .double {
            switch op {
            case .add: return LLVMBuildFAdd(b, lv, rv, "fadd")
            case .sub: return LLVMBuildFSub(b, lv, rv, "fsub")
            case .mul: return LLVMBuildFMul(b, lv, rv, "fmul")
            case .div: return LLVMBuildFDiv(b, lv, rv, "fdiv")
            case .mod: return LLVMBuildFRem(b, lv, rv, "frem")
            case .eq, .neq, .lt, .gt, .lte, .gte:
                // Ordered predicates (false when either operand is NaN).
                let pred: LLVMRealPredicate
                switch op {
                case .eq:  pred = LLVMRealOEQ
                case .neq: pred = LLVMRealONE
                case .lt:  pred = LLVMRealOLT
                case .gt:  pred = LLVMRealOGT
                case .lte: pred = LLVMRealOLE
                default:   pred = LLVMRealOGE   // .gte
                }
                return LLVMBuildFCmp(b, pred, lv, rv, "fcmp")
            case .bitAnd, .bitOr, .bitXor, .shl, .shr:
                fail("bitwise/shift operators are not valid on Double", l.span); return lv
            }
        }
        // Integer path: signed for Int, unsigned for UInt8 — differing on div/rem, `>>`, and compares.
        let unsigned = (l.type == .uint8)
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
            // Comparisons on Int yield Bool — now the `icmp`'s native i1 directly (8.5.2, no zext).
            let pred: LLVMIntPredicate
            switch op {
            case .eq:  pred = LLVMIntEQ
            case .neq: pred = LLVMIntNE
            case .lt:  pred = unsigned ? LLVMIntULT : LLVMIntSLT
            case .gt:  pred = unsigned ? LLVMIntUGT : LLVMIntSGT
            case .lte: pred = unsigned ? LLVMIntULE : LLVMIntSLE
            default:   pred = unsigned ? LLVMIntUGE : LLVMIntSGE   // .gte
            }
            return LLVMBuildICmp(b, pred, lv, rv, "cmp")
        }
    }

    func lowerConstruct(_ typeName: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        if let s = structMap[typeName], let st = structType(typeName) {
            var agg = LLVMGetUndef(st)
            for (idx, field) in s.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                agg = LLVMBuildInsertValue(b, agg, v, UInt32(idx), "")
            }
            return agg
        }
        if let c = classMap[typeName], let ct = classType(typeName) {
            // A non-escaping class instance is stack-allocated: one `alloca` (addrspace 0, hoisted to
            // the entry block) in place of `rt_alloc`, so it never heaps. Escape analysis proved the
            // object pointer only ever feeds field access, so SROA scalar-replaces the alloca and each
            // field becomes an SSA value: a managed field becomes an addrspace(1) SSA root that the
            // statepoint rewriter relocates like any other class-typed local (the same mechanism the
            // whole GC substrate rests on), so no interior stack-map scanning is needed. Field stores
            // are plain (a stack slot is not a heap location the write barrier tracks). Same struct
            // layout as the heap object, so field GEPs are unchanged.
            if escapes.isNonEscaping(span, .classInstance) {
                let obj = entryAlloca(ct, typeName)
                writeTypeIdHeader(obj, typeName)   // kept for layout uniformity; unread on the stack
                for (idx, field) in c.fields.enumerated() {
                    guard let v = constructField(field, args, typeName, span) else { return nil }
                    LLVMBuildStore(b, v, structGEP(ct, obj, fieldLLVMIndex(.classRef, idx)))
                }
                return obj
            }
            // Heap-allocate the object (rt_alloc, bump-and-leak), then store each field past the
            // header. The class value is the returned pointer (reference semantics).
            let slots = 1 + c.fields.reduce(0) { $0 + slotCount($1.type) }
            let obj = rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
            writeTypeIdHeader(obj, typeName)   // M6 · 6.1.3 — stamp the type-id into the header
            for (idx, field) in c.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                storeField(obj, structGEP(ct, obj, fieldLLVMIndex(.classRef, idx)), v)
            }
            return obj
        }
        if let a = actorMap[typeName], let at = actorType(typeName) {
            // Heap-allocate the object, initialize each field (a declared initializer, else the
            // matching constructor argument), then install a fresh mailbox in the last slot (M6 · 6.4).
            let slots = 2 + a.fields.reduce(0) { $0 + slotCount($1.type) }   // header + fields + mailbox
            let obj = rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
            writeTypeIdHeader(obj, typeName)   // M6 · 6.1.3 — stamp the type-id into the header
            for (idx, field) in a.fields.enumerated() {
                let v: LLVMValueRef?
                if let initE = field.initializer { v = lowerExpr(initE) }
                else { v = constructActorField(field, args, typeName, span) }
                guard let fv = v else { return nil }
                storeField(obj, structGEP(at, obj, fieldLLVMIndex(.classRef, idx)), fv)
            }
            // The mailbox is its own GC object `{ header, mb_head, mb_tail, scheduled, sched_next }`
            // (zeroed by the allocator → empty + unscheduled). Stored into the actor's last slot
            // through the barrier.
            let mailbox = rtAllocManaged(LLVMConstInt(i64, 40, 0))
            writeTypeIdHeaderRaw(mailbox, mailboxTypeIdValue())
            storeField(obj, structGEP(at, obj, actorMailboxIndex(typeName)), mailbox)
            return obj
        }
        fail("8.2.6: cannot construct '\(typeName)' (not a struct, class, or actor)", span)
        return nil
    }

    func constructActorField(_ field: NOIRActorField, _ args: [NOIRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.6: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    func constructField(_ field: NOIRField, _ args: [NOIRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.4: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    // Build an enum value in a temp: store the case index as the tag, then each payload field via
    // the case's struct type GEP'd over the payload region; return the loaded aggregate.
    func lowerEnumInit(_ typeName: String, _ caseName: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let et = enumType(typeName), let e = enumMap[typeName],
              let caseIdx = e.cases.firstIndex(where: { $0.name == caseName }) else {
            fail("8.2.3: cannot construct '\(typeName).\(caseName)'", span)
            return nil
        }
        let c = e.cases[caseIdx]
        let slot = entryAlloca(et, "enum")
        LLVMBuildStore(b, LLVMConstInt(i64, UInt64(caseIdx), 0), structGEP(et, slot, 0))
        if !c.fields.isEmpty {
            guard let cst = caseStructType(typeName, c) else { return nil }
            let payload = structGEP(et, slot, 1)
            for (idx, field) in c.fields.enumerated() {
                guard let arg = args.first(where: { $0.label == field.name }) else {
                    fail("8.2.3: missing payload field '\(field.name)' for '\(typeName).\(caseName)'", span)
                    return nil
                }
                guard let v = lowerExpr(arg.value) else { return nil }
                LLVMBuildStore(b, v, structGEP(cst, payload, idx))
            }
        }
        return LLVMBuildLoad2(b, et, slot, "enumv")
    }

    // switch on the enum tag: an LLVM `switch` with one block per arm (exhaustive → default is
    // unreachable). Each arm binds its payload fields (as local copies) then lowers its body.
    func lowerSwitch(_ sw: NOIRSwitch) {
        guard let fn = currentFn else { return }
        guard case .named(let enumName, .enum_) = sw.subject.type,
              let e = enumMap[enumName], let et = enumType(enumName) else {
            fail("8.2.3: switch subject must be a concrete enum", sw.subject.span)
            return
        }
        guard let subj = lvalue(sw.subject) else { return }
        let tag = LLVMBuildLoad2(b, i64, structGEP(et, subj.addr, 0), "tag")

        let defaultBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.default")
        let mergeBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.merge")
        let inst = LLVMBuildSwitch(b, tag, defaultBB, UInt32(sw.arms.count))

        for arm in sw.arms {
            guard let caseIdx = e.cases.firstIndex(where: { $0.name == arm.caseName }) else { continue }
            let c = e.cases[caseIdx]
            let armBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.\(arm.caseName)")
            LLVMAddCase(inst, LLVMConstInt(i64, UInt64(caseIdx), 0), armBB)
            LLVMPositionBuilderAtEnd(b, armBB)

            let saved = locals
            if !arm.bindings.isEmpty, let cst = caseStructType(enumName, c) {
                let payload = structGEP(et, subj.addr, 1)
                for (i, binding) in arm.bindings.enumerated() {
                    guard let bty = llvmType(binding.type, sw.subject.span) else { break }
                    let val = LLVMBuildLoad2(b, bty, structGEP(cst, payload, i), binding.name)
                    let bslot = entryAlloca(bty, binding.name)
                    LLVMBuildStore(b, val, bslot)
                    locals[binding.name] = (bslot, bty)
                    declareLocal(binding.name, type: binding.type, addr: bslot, line: sw.subject.span.begin.line)
                }
            }
            lowerBlock(arm.body)
            if !blockTerminated() { LLVMBuildBr(b, mergeBB) }
            locals = saved
        }

        LLVMPositionBuilderAtEnd(b, defaultBB)
        LLVMBuildUnreachable(b)
        LLVMPositionBuilderAtEnd(b, mergeBB)
    }

    func lowerMethodCall(receiver: NOIRExpr, method: String, args: [NOIRExpr],
                                 resultType: Type, span: Span) -> LLVMValueRef? {
        // Requirement call through `any I` — dispatch dynamically via the box's witness slot.
        if case .existential(let iface) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let witnessPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
            return witnessDispatch(witnessPtr: witnessPtr, iface: iface, method: method,
                                   payload: payload, args: args, resultType: resultType, span: span)
        }
        // Through `any A & B` — the witness is a composite struct; load the owning interface's
        // sub-table, then dispatch through its slot.
        if case .composition(let ifaces) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let compPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
            let owner = compositionOwner(ifaces, method)
            guard let ownerIdx = ifaces.firstIndex(of: owner) else {
                fail("8.2.5: no interface owns '\(method)' in composition", span); return nil
            }
            let subAddr = structGEP(compositeType(ifaces), compPtr, ownerIdx)
            let subTable = LLVMBuildLoad2(b, i8ptr, subAddr, "sub")!
            return witnessDispatch(witnessPtr: subTable, iface: owner, method: method,
                                   payload: payload, args: args, resultType: resultType, span: span)
        }

        // A concrete receiver, or a `some I` opaque one devirtualized to its known underlying.
        let recvType = concreteUnderlying(receiver.type)
        guard case .named(let typeName, let kind) = recvType,
              kind == .struct_ || kind == .enum_ || kind == .class_ || kind == .actor_ else {
            fail("8.2.5: only concrete/any/some method calls are supported", span)
            return nil
        }

        // A `some I` property read arrives as `prop.get`; when the underlying backs it with a
        // stored field, that's a direct field load (mirrors the witness thunk's stored-field path).
        if method.hasSuffix(".get") {
            let prop = String(method.dropLast(4))
            if let info = aggInfo(typeName), let pos = info.fields.firstIndex(where: { $0.name == prop }) {
                guard let fieldTy = llvmType(info.fields[pos].type, span) else { return nil }
                let basePtr: LLVMValueRef
                if info.kind == .classRef {
                    guard let bv = lowerExpr(receiver) else { return nil }
                    basePtr = bv
                } else {
                    guard let ba = lvalue(receiver) else { return nil }
                    basePtr = ba.addr
                }
                return LLVMBuildLoad2(b, fieldTy, structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos)), "ld")
            }
        }

        // An actor handler call is a fire-and-forget message-send, not a direct call (M6 · 6.4): build
        // a message and `rt_actor_send` it (the handler runs later on a rented pool worker; the call
        // returns immediately with no value). `self` is the actor object pointer.
        if kind == .actor_ {
            guard let recvValue = lowerExpr(receiver) else { return nil }
            return lowerActorCall(typeName, method, recvValue, args, span)
        }

        declareMethod(typeName, method)
        guard let c = callables["m:\(typeName):\(method)"] else { return nil }

        // How `self` reaches the callee: a class receiver's value already *is* the object pointer;
        // a struct/enum mutating method wants the address of the (mutable) receiver value; a
        // read-only value method takes a copy of the value.
        let selfArg: LLVMValueRef?
        if kind == .class_ {
            selfArg = lowerExpr(receiver)
        } else if c.selfByPointer {
            selfArg = lvalue(receiver)?.addr
        } else {
            selfArg = lowerExpr(receiver)
        }
        guard let selfVal = selfArg else { return nil }

        var argVals: [LLVMValueRef?] = [selfVal]
        for a in args {
            guard let v = lowerExpr(a) else { return nil }
            argVals.append(v)
        }
        return buildCall(c.fn, c.ty, argVals)
    }

}
