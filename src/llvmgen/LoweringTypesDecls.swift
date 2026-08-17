import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Callable declaration + definition

    // Callable-declaration primitives moved to LLVMGen (LLVMGenCallables.swift) — the signature is
    // ABI, shared across both egresses. Forwarded so the tree-walk callers are unchanged; these
    // forwarders retire with this path. `defineBody` (the NOIR body tree-walk) stays below.
    func declareFree(_ name: String) { e.declareFree(name) }
    func declareMethod(_ typeName: String, _ method: String) { e.declareMethod(typeName, method) }
    func declareActorHandler(_ actorName: String, _ handler: String) { e.declareActorHandler(actorName, handler) }

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
