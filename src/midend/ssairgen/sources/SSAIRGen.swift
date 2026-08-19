import ast
import noir
import ssair
import support

// Lowering-in: structured NOIR → SSAIR (m7-spec.md §7.2.2).
//
// Direct SSA construction (Braun et al., "Simple and Efficient Construction of Static Single
// Assignment Form"): as the structured tree lowers, the builder tracks the current SSA value of each
// variable per block, materializing block parameters at joins and sealing loop back-edges. Every
// local is an SSA candidate because Nomu has no address-of. Control flow (`if`/`while`/`break`/
// `continue`) flattens to blocks + terminators here — the one place the structured tree is flattened.
//
// Covered so far: scalars + control flow (7.2.2a); value aggregates (struct/enum) under the **slots**
// representation (Decided: Option B — a value aggregate lives in a stack slot, `stackAlloc` +
// `fieldAddr`/`load`/`store`; scalars and reference types stay pure SSA), class construction, field
// access/assignment, enum init + `switch`/match, and array literals (7.2.2b-i). Still ahead:
// type-method/actor-handler bodies + `self`, concrete method calls, closures + closure conversion,
// `box`/witness/indirect dispatch, actors + `actorSend`, and `spawn`.

public struct SSAGenResult {
    public let module: SSAModule
    public let diagnostics: DiagnosticSink
}

// Type-layout tables the lowerer needs: field order/index for struct & class construction and field
// access, and enum case order for `enumInit`/match. Physical layout stays the egress's concern —
// SSAIR carries only logical field/case indices.
struct ModuleContext {
    let structFields: [String: [NOIRField]]
    let classFields: [String: [NOIRField]]
    let enumCases: [String: [NOIREnumCase]]
    let methodsByType: [String: [NOIRFunc]]   // struct/enum/class instance methods, by owning type
    let actorFields: [String: [NOIRActorField]]   // actor storage + per-field initializers
    let opaqueUnderlyings: [String: Type]     // `some I` owner → concrete underlying (static dispatch)
    let interfaceSlots: [String: Set<String>] // interface → its requirement slots (method / `prop.get` / `prop.set`)

    func fields(_ name: String, _ kind: NamedKind) -> [NOIRField]? {
        switch kind {
        case .struct_: return structFields[name]
        case .class_:  return classFields[name]
        case .actor_:  return actorFields[name]?.map { NOIRField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) }
        default:       return nil
        }
    }
    func fieldIndex(_ name: String, _ kind: NamedKind, _ field: String) -> Int? {
        fields(name, kind)?.firstIndex { $0.name == field }
    }
    func enumCaseIndex(_ name: String, _ caseName: String) -> Int? {
        enumCases[name]?.firstIndex { $0.name == caseName }
    }
    func method(_ type: String, _ name: String) -> NOIRFunc? {
        methodsByType[type]?.first { $0.name == name }
    }
    // The mangled call name / SSAFunction name for a type method (matches the backend's callable key).
    static func methodSymbol(_ type: String, _ name: String) -> String { "m:\(type):\(name)" }

    // Which interface of a composition declares `method` (the owning sub-table to dispatch through).
    func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        ifaces.first { interfaceSlots[$0]?.contains(method) ?? false } ?? ifaces.first ?? "?"
    }
}

public func lowerToSSAIR(_ module: NOIRModule) -> SSAGenResult {
    let diags = DiagnosticSink()
    var structFields: [String: [NOIRField]] = [:]
    var classFields: [String: [NOIRField]] = [:]
    var enumCases: [String: [NOIREnumCase]] = [:]
    var methodsByType: [String: [NOIRFunc]] = [:]
    var actorFields: [String: [NOIRActorField]] = [:]
    for decl in module.decls {
        switch decl {
        case .structDecl(let s): structFields[s.name] = s.fields; methodsByType[s.name] = s.methods
        case .classDecl(let c):  classFields[c.name] = c.fields;  methodsByType[c.name] = c.methods
        case .enumDecl(let e):   enumCases[e.name] = e.cases;      methodsByType[e.name] = e.methods
        case .actorDecl(let a):  actorFields[a.name] = a.fields
        default: break
        }
    }
    var interfaceSlots: [String: Set<String>] = [:]
    for i in module.interfaces {
        var slots = Set(i.methods.map(\.name))
        for p in i.properties {
            slots.insert("\(p.name).get")
            if p.isSettable { slots.insert("\(p.name).set") }
        }
        interfaceSlots[i.name] = slots
    }
    let ctx = ModuleContext(structFields: structFields, classFields: classFields,
                            enumCases: enumCases, methodsByType: methodsByType, actorFields: actorFields,
                            opaqueUnderlyings: module.opaqueUnderlyings, interfaceSlots: interfaceSlots)

    let sink = ClosureSink()
    var functions: [SSAFunction] = []
    for decl in module.decls {
        switch decl {
        case .funcDecl(let f):
            let lowerer = FunctionLowerer(diags: diags, ctx: ctx, sink: sink)
            if let fn = lowerer.lower(f) { functions.append(fn) }
        case .structDecl(let s): lowerMethods(s.name, .struct_, s.methods, ctx, diags, sink, &functions)
        case .enumDecl(let e):   lowerMethods(e.name, .enum_, e.methods, ctx, diags, sink, &functions)
        case .classDecl(let c):  lowerMethods(c.name, .class_, c.methods, ctx, diags, sink, &functions)
        case .actorDecl(let a):
            // Each `on`-handler lowers like a mutating method with an actor (reference) `self`.
            let handlers = a.handlers.map { NOIRFunc(name: $0.name, params: $0.params, returnType: $0.returnType,
                                                     body: $0.body, isMutating: true, span: $0.span) }
            lowerMethods(a.name, .actor_, handlers, ctx, diags, sink, &functions)
        }
    }
    functions += sink.lifted   // the lifted closure bodies
    var aggregates = module.decls.compactMap { decl -> SSAAggregate? in
        switch decl {
        case .structDecl(let s): return SSAAggregate(name: s.name, kind: .struct_, fields: s.fields.map(field), span: s.span)
        case .classDecl(let c):  return SSAAggregate(name: c.name, kind: .class_, fields: c.fields.map(field), span: c.span)
        case .actorDecl(let a):  return SSAAggregate(name: a.name, kind: .actor_,
                                                     fields: a.fields.map { SSAField(name: $0.name, type: $0.type, isMutable: true) }, span: a.span)
        default: return nil
        }
    }
    aggregates += sink.envAggregates   // synthesized closure-environment layouts
    let enums = module.decls.compactMap { decl -> SSAEnum? in
        guard case .enumDecl(let e) = decl else { return nil }
        return SSAEnum(name: e.name,
                       cases: e.cases.map { SSAEnumCase(name: $0.name, fields: $0.fields.map(field), span: $0.span) },
                       span: e.span)
    }
    let ssa = SSAModule(functions: functions, aggregates: aggregates, enums: enums,
                        interfaces: module.interfaces, conformances: module.conformances,
                        composites: module.composites, opaqueUnderlyings: module.opaqueUnderlyings)
    return SSAGenResult(module: ssa, diagnostics: diags)
}

private func field(_ f: NOIRField) -> SSAField { SSAField(name: f.name, type: f.type, isMutable: f.isMutable) }

private func lowerMethods(_ typeName: String, _ kind: NamedKind, _ methods: [NOIRFunc],
                          _ ctx: ModuleContext, _ diags: DiagnosticSink, _ sink: ClosureSink,
                          _ out: inout [SSAFunction]) {
    for m in methods {
        let lowerer = FunctionLowerer(diags: diags, ctx: ctx, sink: sink)
        if let fn = lowerer.lowerMethod(typeName: typeName, kind: kind, m) { out.append(fn) }
    }
}

// Shared across every `FunctionLowerer` in a module: closure conversion lifts each closure body to a
// top-level `SSAFunction` and synthesizes a struct layout for its captured environment. Both accumulate
// here (closures can appear in any function/method and can nest), collected after all bodies lower.
final class ClosureSink {
    var lifted: [SSAFunction] = []
    var envAggregates: [SSAAggregate] = []
    var nextId = 0
}

// MARK: - Free-variable collection (respects shadowing via `bound`) — ports the codegen analysis.

private func collectUses(_ stmts: [NOIRStmt], _ bound: inout Set<String>, _ used: inout [String]) {
    for s in stmts { collectUsesStmt(s, &bound, &used) }
}

private func collectUsesStmt(_ stmt: NOIRStmt, _ bound: inout Set<String>, _ used: inout [String]) {
    switch stmt.kind {
    case .letBinding(let name, _, let value):
        collectUsesExpr(value, bound, &used); bound.insert(name)
    case .spawnLet(let name, let value, _):
        collectUsesExpr(value, bound, &used); bound.insert(name)
    case .assign(let t, let v), .compoundAssign(let t, let v):
        collectUsesExpr(t, bound, &used); collectUsesExpr(v, bound, &used)
    case .ret(let e):
        if let e = e { collectUsesExpr(e, bound, &used) }
    case .ifStmt(let cond, let then, let els):
        collectUsesExpr(cond, bound, &used)
        var b1 = bound; collectUses(then, &b1, &used)
        if let els = els { var b2 = bound; collectUses(els, &b2, &used) }
    case .whileStmt(let cond, let body):
        collectUsesExpr(cond, bound, &used)
        var wb = bound; collectUses(body, &wb, &used)
    case .breakStmt, .continueStmt:
        break
    case .switchStmt(let sw):
        collectUsesExpr(sw.subject, bound, &used)
        for arm in sw.arms {
            var ab = bound
            for bnd in arm.bindings { ab.insert(bnd.name) }
            collectUses(arm.body, &ab, &used)
        }
    case .exprStmt(let e):
        collectUsesExpr(e, bound, &used)
    }
}

private func collectUsesExpr(_ e: NOIRExpr, _ bound: Set<String>, _ used: inout [String]) {
    switch e.kind {
    case .intLit, .doubleLit, .boolLit, .stringLit:
        break
    case .varRef(let n):
        if !bound.contains(n) { used.append(n) }
    case .fieldAccess(let base, _):
        collectUsesExpr(base, bound, &used)
    case .construct(_, let args), .enumInit(_, _, let args):
        for a in args { collectUsesExpr(a.value, bound, &used) }
    case .methodCall(let receiver, _, let args):
        collectUsesExpr(receiver, bound, &used)
        for a in args { collectUsesExpr(a, bound, &used) }
    case .call(let callee, let args, _):
        collectUsesExpr(callee, bound, &used)
        for a in args { collectUsesExpr(a.value, bound, &used) }
    case .binary(_, let l, let r):
        collectUsesExpr(l, bound, &used); collectUsesExpr(r, bound, &used)
    case .closure(let ps, let cbody):
        var nb = bound
        for p in ps { nb.insert(p.name) }
        collectUses(cbody, &nb, &used)
    case .box(let value, _):
        collectUsesExpr(value, bound, &used)
    case .arrayLit(let elements):
        for el in elements { collectUsesExpr(el, bound, &used) }
    case .index(let base, let idx):
        collectUsesExpr(base, bound, &used); collectUsesExpr(idx, bound, &used)
    }
}

// MARK: - Per-function lowering + SSA construction

final class FunctionLowerer {
    private let diags: DiagnosticSink
    private let ctx: ModuleContext
    private let sink: ClosureSink

    // Block storage under construction. A block is terminated once `term` is set; further statements
    // in a straight-line list are then skipped (dead).
    private struct BB {
        let id: Int
        var params: [(name: String, value: SSAValue)]   // block arguments, each tied to a variable
        var insts: [SSAInst]
        var term: SSATerm?
    }
    private var bbs: [Int: BB] = [:]
    private var order: [Int] = []
    private var curId = 0
    private var nextBlock = 0
    private var nextValue = 0

    // SSA construction state (Braun): current value per variable per block, sealed blocks, CFG preds.
    private var currentDef: [Int: [String: SSAValue]] = [:]
    private var sealed: Set<Int> = []
    private var preds: [Int: [Int]] = [:]
    private var varType: [String: Type] = [:]

    // Value-aggregate (struct/enum) locals live in a stack slot (Option B). `slots` maps such a
    // variable to its slot address (a `stackAlloc` value emitted into the entry block, so it dominates
    // every use); the slot is loop-invariant, so it never becomes a block parameter.
    private var slots: [String: SSAValue] = [:]
    private var entryId = 0

    private struct LoopCtx { let header: Int; let exit: Int; let spawnBase: Int }
    private var loopStack: [LoopCtx] = []
    private var lastSpan: Span

    // `spawn let` state. Each binding gets an egress-owned fiber handle keyed by `id`; reads join it,
    // and every scope exit (return / loop back-edge / break / continue) joins the spawns still active,
    // so a fiber never outlives its frame (structured concurrency). `spawnJoin` is idempotent.
    private var spawnBindings: [String: Int] = [:]     // spawn-let name → binding id
    private var spawnResultTypes: [Int: Type] = [:]    // binding id → result type
    private var activeSpawns: [Int] = []               // active binding ids, in spawn order
    private var nextSpawn = 0

    // In a method body, the receiver type + kind + its stored fields, so a bare `varRef` of a field
    // name (or `self`) resolves to a self-field access. `self` is registered as an ordinary variable
    // (a slot for a value receiver, a scalar pointer for a class receiver).
    private struct SelfCtx { let typeName: String; let kind: NamedKind; let fields: [NOIRField] }
    private var currentSelf: SelfCtx?

    init(diags: DiagnosticSink, ctx: ModuleContext, sink: ClosureSink) {
        self.diags = diags
        self.ctx = ctx
        self.sink = sink
        self.lastSpan = Span(startOffset: 0, endOffset: 0, map: nil)
    }

    func lower(_ f: NOIRFunc) -> SSAFunction? {
        let params = beginFunction(f)
        return finishFunction(f, params: params, name: f.name)
    }

    // A type method: `self` is param 0. Reference receivers (class) pass `self` as the object pointer;
    // a struct/enum receiver passes `self` by pointer only when the method mutates it, else by value
    // (spilled to a slot for uniform field access). Self ABI is derivable at the egress from
    // `isMutating` + the receiver kind, so no extra flag is threaded.
    func lowerMethod(typeName: String, kind: NamedKind, _ f: NOIRFunc) -> SSAFunction? {
        lastSpan = f.span
        let entry = newBlock(); entryId = entry; seal(entry); curId = entry

        let fields = ctx.fields(typeName, kind) ?? []
        currentSelf = SelfCtx(typeName: typeName, kind: kind, fields: fields)
        let selfType = Type.named(typeName, kind)
        let selfParam = newValue(selfType)
        let byPointer = kind == .class_ || kind == .actor_ || f.isMutating
        if kind == .struct_ || kind == .enum_ {
            if byPointer {
                slots["self"] = selfParam                 // the param already is the slot address
            } else {
                let slot = entryStackAlloc(selfType)      // by value: spill for uniform field access
                emitVoid(.store(addr: slot, value: selfParam), f.span)
                slots["self"] = slot
            }
        } else {
            write("self", entry, selfParam)               // class/actor: a pointer scalar
        }

        var params = [selfParam]
        params += bindParams(f)
        return finishFunction(f, params: params, name: ModuleContext.methodSymbol(typeName, f.name))
    }

    // Shared prologue: entry block + parameters.
    private func beginFunction(_ f: NOIRFunc) -> [SSAValue] {
        lastSpan = f.span
        let entry = newBlock(); entryId = entry; seal(entry); curId = entry
        return bindParams(f)
    }

    private func bindParams(_ f: NOIRFunc) -> [SSAValue] {
        var params: [SSAValue] = []
        for p in f.params {
            let v = newValue(p.type)
            write(p.name, entryId, v)
            params.append(v)
        }
        return params
    }

    private func finishFunction(_ f: NOIRFunc, params: [SSAValue], name: String) -> SSAFunction? {
        lowerBlock(f.body)
        if bbs[curId]?.term == nil {       // fell off the end
            joinSpawns(from: 0)
            terminate(f.returnType == .void ? .ret(nil) : .unreachable, f.span)
        }
        let blocks = finalize(returnType: f.returnType)
        if diags.hasErrors { return nil }
        return SSAFunction(name: name, params: params, returnType: f.returnType,
                           blocks: blocks, isMutating: f.isMutating, span: f.span)
    }

    // MARK: Builder primitives

    private func newValue(_ t: Type) -> SSAValue { defer { nextValue += 1 }; return SSAValue(id: nextValue, type: t) }

    private func newBlock() -> Int {
        let id = nextBlock; nextBlock += 1
        bbs[id] = BB(id: id, params: [], insts: [], term: nil)
        order.append(id); preds[id] = []
        return id
    }

    private func addPred(_ block: Int, _ pred: Int) { preds[block, default: []].append(pred) }
    private func seal(_ block: Int) { sealed.insert(block) }
    private var terminated: Bool { bbs[curId]?.term != nil }

    private func emit(_ kind: SSAInstKind, _ type: Type, _ span: Span) -> SSAValue {
        let v = newValue(type)
        bbs[curId]?.insts.append(SSAInst(result: v, kind: kind, span: span))
        return v
    }
    private func emitVoid(_ kind: SSAInstKind, _ span: Span) {
        bbs[curId]?.insts.append(SSAInst(result: nil, kind: kind, span: span))
    }
    private func terminate(_ kind: SSATermKind, _ span: Span) {
        guard bbs[curId]?.term == nil else { return }
        bbs[curId]?.term = SSATerm(kind: kind, span: span)
    }

    private func fail(_ msg: String, _ span: Span) { diags.error("SSAIR lowering: " + msg, at: span) }

    // MARK: SSA construction (Braun et al.)

    private func write(_ name: String, _ block: Int, _ v: SSAValue) {
        currentDef[block, default: [:]][name] = v
        varType[name] = v.type
    }

    private func read(_ name: String, _ block: Int) -> SSAValue {
        if let v = currentDef[block]?[name] { return v }
        return readRecursive(name, block)
    }

    private func readRecursive(_ name: String, _ block: Int) -> SSAValue {
        let val: SSAValue
        if !sealed.contains(block) {
            val = newParam(block, name)                       // incomplete: back-edge preds unknown
        } else if let ps = preds[block], ps.count == 1 {
            val = read(name, ps[0])                            // single pred: forward directly
        } else if preds[block]?.isEmpty ?? true {
            fail("use of undefined variable '\(name)'", lastSpan)
            val = newValue(varType[name] ?? .error)
        } else {
            let p = newParam(block, name)                     // multiple preds: a join param
            write(name, block, p)                             // define before recursing — breaks cycles
            return p
        }
        write(name, block, val)
        return val
    }

    private func newParam(_ block: Int, _ name: String) -> SSAValue {
        let v = newValue(varType[name] ?? .error)
        bbs[block]?.params.append((name: name, value: v))
        return v
    }

    // MARK: Statements

    private func lowerBlock(_ stmts: [NOIRStmt]) {
        for s in stmts {
            if diags.hasErrors || terminated { return }
            lowerStmt(s)
        }
    }

    private func lowerStmt(_ stmt: NOIRStmt) {
        lastSpan = stmt.span
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            if let v = lowerExpr(value) { bind(name, v, stmt.span) }

        case .assign(let target, let value):
            lowerAssign(target: target, value: value, span: stmt.span)

        case .compoundAssign(let target, let value):
            // Nomu's only compound assignment is `+=` (Int or Double), on a scalar local or self field.
            guard case .varRef(let name) = target.kind else {
                fail("unsupported compound-assignment target", stmt.span); return
            }
            guard let cur = readVar(name, stmt.span, fieldType: value.type), let v = lowerExpr(value) else { return }
            let sum = emit(.binary(.add, cur, v), value.type, stmt.span)
            if varType[name] != nil {
                write(name, curId, sum)
            } else if let idx = selfFieldIndex(name) {
                writeSelfField(idx, sum, stmt.span)
            } else {
                fail("unknown compound-assignment target '\(name)'", stmt.span)
            }

        case .ret(let e):
            // Compute the value first (its own spawn reads join), then join the rest before returning.
            var rv: SSAValue?
            if let e = e {
                guard let v = lowerExpr(e) else { return }
                rv = v
            }
            joinSpawns(from: 0)
            terminate(.ret(rv), stmt.span)

        case .ifStmt(let cond, let then, let els):
            lowerIf(cond: cond, then: then, els: els, span: stmt.span)

        case .whileStmt(let cond, let body):
            lowerWhile(cond: cond, body: body, span: stmt.span)

        case .breakStmt:
            guard let loop = loopStack.last else { fail("break outside a loop", stmt.span); return }
            joinSpawns(from: loop.spawnBase)
            terminate(.br(target: loop.exit, args: []), stmt.span)
            addPred(loop.exit, curId)

        case .continueStmt:
            guard let loop = loopStack.last else { fail("continue outside a loop", stmt.span); return }
            joinSpawns(from: loop.spawnBase)
            terminate(.br(target: loop.header, args: []), stmt.span)
            addPred(loop.header, curId)

        case .switchStmt(let sw):
            lowerSwitch(sw, stmt.span)

        case .spawnLet(let name, let value, let resultType):
            lowerSpawnLet(name: name, value: value, resultType: resultType, span: stmt.span)

        case .exprStmt(let e):
            _ = lowerExpr(e)
        }
    }

    // Emit an (idempotent) join for every spawn still active from `base` onward, newest first — a scope
    // exit must not leave a fiber running past its frame.
    private func joinSpawns(from base: Int) {
        guard base < activeSpawns.count else { return }
        for id in activeSpawns[base...].reversed() {
            if let rt = spawnResultTypes[id] { _ = emit(.spawnJoin(binding: id, resultType: rt), rt, lastSpan) }
        }
    }

    // `spawn let name = value` — run `value` on a fiber. Its free variables are captured into an env
    // (as for a closure); the body is lifted to `spawn:N(env) -> resultType`. The site starts the
    // fiber (`spawn`), and reads of `name` (plus scope exit) join it.
    private func lowerSpawnLet(name: String, value: NOIRExpr, resultType: Type, span: Span) {
        var used: [String] = []
        collectUsesExpr(value, [], &used)
        var seen = Set<String>()
        let capNames = used.filter { seen.insert($0).inserted && (slots[$0] != nil || varType[$0] != nil) }
        var caps: [(name: String, value: SSAValue)] = []
        for n in capNames { guard let v = readVar(n, span) else { return }; caps.append((n, v)) }

        let id = sink.nextId; sink.nextId += 1
        let envName = "spawn.\(id).env"
        let envType = Type.named(envName, .class_)
        sink.envAggregates.append(SSAAggregate(
            name: envName, kind: .class_,
            fields: caps.map { SSAField(name: $0.name, type: $0.value.type, isMutable: false) }, span: span))
        var env: SSAValue?
        if !caps.isEmpty {
            let e = emit(.alloc(envType), envType, span)
            for (i, cap) in caps.enumerated() {
                let addr = emit(.fieldAddr(base: e, fieldIndex: i), cap.value.type, span)
                emitVoid(.writeBarrier(object: e, value: cap.value), span)
                emitVoid(.store(addr: addr, value: cap.value), span)
            }
            env = e
        }

        // Lift `spawn:N(env) -> resultType { return value }`.
        let startName = "spawn:\(id)"
        let child = FunctionLowerer(diags: diags, ctx: ctx, sink: sink)
        let body = [NOIRStmt(kind: .ret(value), span: span)]
        if let lifted = child.lowerClosureBody(name: startName, envType: envType,
                                               captures: caps.map { ($0.name, $0.value.type) },
                                               params: [], body: body, ret: resultType, span: span) {
            sink.lifted.append(lifted)
        }

        let binding = nextSpawn; nextSpawn += 1
        emitVoid(.spawn(binding: binding, startFn: startName, env: env, resultType: resultType), span)
        spawnResultTypes[binding] = resultType
        activeSpawns.append(binding)
        spawnBindings[name] = binding
    }

    // `if cond { then } else { els }` → a condBr to fresh then/else blocks that both branch to a
    // merge block. Each successor is sealed as soon as its (single) predecessor is known; the merge
    // is sealed once both arms have branched (its predecessors are then complete).
    private func lowerIf(cond: NOIRExpr, then: [NOIRStmt], els: [NOIRStmt]?, span: Span) {
        guard let condV = lowerExpr(cond) else { return }
        let thenB = newBlock()
        let elseB = els != nil ? newBlock() : nil
        let mergeB = newBlock()
        let falseTarget = elseB ?? mergeB

        terminate(.condBr(cond: condV, then: thenB, thenArgs: [], else: falseTarget, elseArgs: []), span)
        addPred(thenB, curId); addPred(falseTarget, curId)

        seal(thenB); curId = thenB
        lowerBlock(then)
        if !terminated { terminate(.br(target: mergeB, args: []), span); addPred(mergeB, curId) }

        if let els = els, let elseB = elseB {
            seal(elseB); curId = elseB
            lowerBlock(els)
            if !terminated { terminate(.br(target: mergeB, args: []), span); addPred(mergeB, curId) }
        }

        seal(mergeB); curId = mergeB
    }

    // `while cond { body }` → header (re-tests each iteration) / body / exit. The header stays
    // **unsealed** while the condition and body lower, so a variable read in the header creates an
    // incomplete block parameter; the back-edge from the body completes its predecessors, and the
    // header is sealed after the body. This is the loop back-edge correctness the direct-construction
    // approach owns.
    private func lowerWhile(cond: NOIRExpr, body: [NOIRStmt], span: Span) {
        let headerB = newBlock()
        terminate(.br(target: headerB, args: []), span); addPred(headerB, curId)

        curId = headerB                                   // header unsealed: back-edge pred still unknown
        guard let condV = lowerExpr(cond) else { return }
        let bodyB = newBlock()
        let exitB = newBlock()
        terminate(.condBr(cond: condV, then: bodyB, thenArgs: [], else: exitB, elseArgs: []), cond.span)
        addPred(bodyB, headerB); addPred(exitB, headerB)

        seal(bodyB); curId = bodyB
        let spawnBase = activeSpawns.count                // spawns made in the body don't outlive the loop
        loopStack.append(LoopCtx(header: headerB, exit: exitB, spawnBase: spawnBase))
        lowerBlock(body)
        if !terminated {
            joinSpawns(from: spawnBase)                   // the iteration's spawns join on the back-edge
            terminate(.br(target: headerB, args: []), span); addPred(headerB, curId)
        }
        loopStack.removeLast()
        activeSpawns.removeLast(activeSpawns.count - spawnBase)

        seal(headerB)                                     // both preds (entry + back-edge) now known
        seal(exitB)                                       // preds: header + any `break` edges
        curId = exitB
    }

    // MARK: Expressions

    private func lowerExpr(_ e: NOIRExpr) -> SSAValue? {
        lastSpan = e.span
        switch e.kind {
        case .intLit(let n):    return emit(.constInt(n), .int, e.span)
        case .doubleLit(let x): return emit(.constDouble(x), .double, e.span)
        case .boolLit(let b):   return emit(.constBool(b), .bool, e.span)
        case .stringLit(let s): return emit(.constString(s), .string, e.span)

        case .varRef(let name):
            return readVar(name, e.span, fieldType: e.type)

        case .binary(let op, let l, let r):
            guard let lv = lowerExpr(l), let rv = lowerExpr(r) else { return nil }
            return emit(.binary(op, lv, rv), e.type, e.span)

        case .call(let callee, let args, let typeArgs):
            return lowerCall(callee: callee, args: args, typeArgs: typeArgs, type: e.type, span: e.span)

        case .index(let base, let idx):
            return lowerIndex(base: base, idx: idx, elem: e.type, span: e.span)

        case .fieldAccess(let base, let field):
            return lowerFieldRead(base: base, field: field, type: e.type, span: e.span)

        case .construct(let typeName, let args):
            return lowerConstruct(typeName: typeName, args: args, type: e.type, span: e.span)

        case .enumInit(let typeName, let caseName, let args):
            return lowerEnumInit(typeName: typeName, caseName: caseName, args: args, type: e.type, span: e.span)

        case .arrayLit(let elements):
            guard case .array(let elem) = e.type else { fail("array literal is not of array type", e.span); return nil }
            var vals: [SSAValue] = []
            for el in elements { guard let v = lowerExpr(el) else { return nil }; vals.append(v) }
            return emit(.arrayLit(elements: vals, elem: elem), e.type, e.span)

        case .methodCall(let receiver, let method, let args):
            return lowerMethodCall(receiver: receiver, method: method, args: args, type: e.type, span: e.span)

        case .box(let value, let interfaces):
            guard let v = lowerExpr(value) else { return nil }
            return emit(.box(value: v, interfaces: interfaces, onStack: false), e.type, e.span)

        case .closure(let params, let body):
            return lowerClosure(params: params, body: body, type: e.type, span: e.span)
        }
    }

    // Closure conversion. The captures are the body's free variables that name enclosing locals; each
    // is copied by value into a synthesized environment struct (`clo.N.env`). The body is lifted to a
    // top-level `SSAFunction` (`clo:N`) whose first parameter is that env — captures are read back from
    // it at entry. The closure value is `makeClosure(clo:N, env)`: a single managed pointer, so it never
    // rides across a safepoint as a first-class `{fn, env}` aggregate (I10 / 8.4.1).
    private func lowerClosure(params: [NOIRParam], body: [NOIRStmt], type: Type, span: Span) -> SSAValue? {
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUses(body, &bound, &used)
        // Captures: free vars that are enclosing locals (a slot or an SSA-tracked variable/param),
        // de-duplicated in first-use order. A referenced self-field is not captured (closures over
        // `self` are not yet supported).
        var seen = Set<String>()
        let capNames = used.filter { seen.insert($0).inserted && (slots[$0] != nil || varType[$0] != nil) }

        var caps: [(name: String, value: SSAValue)] = []
        for n in capNames { guard let v = readVar(n, span) else { return nil }; caps.append((n, v)) }

        let id = sink.nextId; sink.nextId += 1
        let envName = "clo.\(id).env"
        let envType = Type.named(envName, .class_)
        sink.envAggregates.append(SSAAggregate(
            name: envName, kind: .class_,
            fields: caps.map { SSAField(name: $0.name, type: $0.value.type, isMutable: false) }, span: span))

        // Build the environment at the site (nil when there are no captures).
        var env: SSAValue?
        if !caps.isEmpty {
            let e = emit(.alloc(envType), envType, span)
            for (i, cap) in caps.enumerated() {
                let addr = emit(.fieldAddr(base: e, fieldIndex: i), cap.value.type, span)
                emitVoid(.writeBarrier(object: e, value: cap.value), span)   // egress gates on the value being managed
                emitVoid(.store(addr: addr, value: cap.value), span)
            }
            env = e
        }

        var ret = Type.void
        if case .function(_, let r) = type { ret = r }
        let liftedName = "clo:\(id)"
        let child = FunctionLowerer(diags: diags, ctx: ctx, sink: sink)
        if let lifted = child.lowerClosureBody(name: liftedName, envType: envType,
                                               captures: caps.map { ($0.name, $0.value.type) },
                                               params: params, body: body, ret: ret, span: span) {
            sink.lifted.append(lifted)
        }
        return emit(.makeClosure(funcName: liftedName, env: env, onStack: false), type, span)
    }

    // Lower a lifted closure body: env is parameter 0, captures are loaded from it into scope, then the
    // closure's own parameters follow. A fresh scope (no `self`, no enclosing locals).
    func lowerClosureBody(name: String, envType: Type, captures: [(name: String, type: Type)],
                          params: [NOIRParam], body: [NOIRStmt], ret: Type, span: Span) -> SSAFunction? {
        lastSpan = span
        let entry = newBlock(); entryId = entry; seal(entry); curId = entry

        let envParam = newValue(envType)
        var fnParams = [envParam]
        for (i, cap) in captures.enumerated() {
            let addr = emit(.fieldAddr(base: envParam, fieldIndex: i), cap.type, span)
            let v = emit(.load(addr), cap.type, span)
            bind(cap.name, v, span)
        }
        for p in params {
            let v = newValue(p.type)
            write(p.name, entry, v)
            fnParams.append(v)
        }

        lowerBlock(body)
        if bbs[curId]?.term == nil { joinSpawns(from: 0); terminate(ret == .void ? .ret(nil) : .unreachable, span) }
        let blocks = finalize(returnType: ret)
        if diags.hasErrors { return nil }
        return SSAFunction(name: name, params: fnParams, returnType: ret, blocks: blocks, isMutating: false, span: span)
    }

    // A method call, dispatched by receiver type:
    //  • `any I` / `any A & B` → dynamic `call .witness` through the box's witness slot;
    //  • `some I` → static dispatch on the hidden concrete underlying (unboxed);
    //  • actor → a fire-and-forget `actorSend`;
    //  • struct/enum/class → a `.direct` call to the method symbol with `self` prepended.
    private func lowerMethodCall(receiver: NOIRExpr, method: String, args: [NOIRExpr], type: Type, span: Span) -> SSAValue? {
        // Dynamic dispatch through a boxed existential.
        if case .existential(let iface) = receiver.type {
            return lowerWitnessCall(receiver: receiver, interface: iface, method: method, args: args, type: type, span: span)
        }
        if case .composition(let ifaces) = receiver.type {
            return lowerWitnessCall(receiver: receiver, interface: ctx.compositionOwner(ifaces, method),
                                    method: method, args: args, type: type, span: span)
        }
        // `some I` devirtualizes to its concrete underlying.
        var recvType = receiver.type
        if case .opaque(_, let owner) = recvType, let u = ctx.opaqueUnderlyings[owner] { recvType = u }

        // An actor method call is an asynchronous message send (fire-and-forget, no value).
        if case .named(_, .actor_) = recvType {
            guard let recv = lowerExpr(receiver) else { return nil }
            var argVals: [SSAValue] = []
            for a in args { guard let v = lowerExpr(a) else { return nil }; argVals.append(v) }
            emitVoid(.actorSend(receiver: recv, handler: method, args: argVals), span)
            return nil
        }

        guard case .named(let typeName, let kind) = recvType,
              kind == .struct_ || kind == .enum_ || kind == .class_ else {
            fail("unsupported method-call receiver", span)
            return nil
        }
        let isMutating = ctx.method(typeName, method)?.isMutating ?? false
        // `self` argument: a class is the object pointer; a mutating value receiver passes its address;
        // a read-only value receiver passes its value.
        let selfArg: SSAValue?
        if kind == .class_ {
            selfArg = lowerExpr(receiver)
        } else if isMutating {
            selfArg = structAddr(receiver) ?? spill(receiver)
        } else {
            selfArg = lowerExpr(receiver)
        }
        guard let selfV = selfArg else { return nil }

        var argVals = [selfV]
        for a in args { guard let v = lowerExpr(a) else { return nil }; argVals.append(v) }
        let call = SSACall(kind: .direct(ModuleContext.methodSymbol(typeName, method)), args: argVals)
        if type == .void { emitVoid(.call(call), span); return nil }
        return emit(.call(call), type, span)
    }

    // Materialize a value aggregate into a fresh slot and return its address (for a mutating call on
    // an rvalue receiver — the mutation is then local to the temporary, as by-value semantics dictate).
    private func spill(_ e: NOIRExpr) -> SSAValue? {
        guard let v = lowerExpr(e) else { return nil }
        let slot = entryStackAlloc(e.type)
        emitVoid(.store(addr: slot, value: v), e.span)
        return slot
    }

    // MARK: Self-field access

    // Read a variable by name: an aggregate slot loads the slot, an SSA-tracked variable reads its
    // current value, a bare self-field name resolves through `currentSelf`. `fieldType` is the read's
    // result type (needed for a self-field read).
    private func readVar(_ name: String, _ span: Span, fieldType: Type = .void) -> SSAValue? {
        if let binding = spawnBindings[name], let rt = spawnResultTypes[binding] {
            return emit(.spawnJoin(binding: binding, resultType: rt), rt, span)   // reading a spawn joins it
        }
        if let slot = slots[name] { return emit(.load(slot), slot.type, span) }
        if varType[name] != nil { return read(name, curId) }
        if let idx = selfFieldIndex(name) { return selfFieldRead(name, idx, fieldType, span) }
        fail("unknown variable '\(name)'", span); return nil
    }

    private func selfFieldIndex(_ name: String) -> Int? {
        currentSelf?.fields.firstIndex { $0.name == name }
    }

    // The base for a self-field access: a class receiver's pointer, or a value receiver's slot address.
    private func selfBase() -> SSAValue? {
        guard let cs = currentSelf else { return nil }
        if cs.kind == .class_ || cs.kind == .actor_ { return read("self", curId) }
        return slots["self"]
    }

    private func selfFieldRead(_ name: String, _ idx: Int, _ type: Type, _ span: Span) -> SSAValue? {
        guard let base = selfBase() else { fail("no self for '\(name)'", span); return nil }
        let addr = emit(.fieldAddr(base: base, fieldIndex: idx), type, span)
        return emit(.load(addr), type, span)
    }

    private func selfFieldWrite(_ name: String, _ idx: Int, _ value: NOIRExpr, _ span: Span) {
        guard let base = selfBase() else { fail("no self for '\(name)'", span); return }
        let addr = emit(.fieldAddr(base: base, fieldIndex: idx), value.type, span)
        guard let v = lowerExpr(value) else { return }
        if isReferenceSelf { emitVoid(.writeBarrier(object: base, value: v), span) }
        emitVoid(.store(addr: addr, value: v), span)
    }

    // Store an already-computed value into self field `idx` (used by compound assignment).
    private func writeSelfField(_ idx: Int, _ v: SSAValue, _ span: Span) {
        guard let base = selfBase() else { fail("no self", span); return }
        let addr = emit(.fieldAddr(base: base, fieldIndex: idx), v.type, span)
        if isReferenceSelf { emitVoid(.writeBarrier(object: base, value: v), span) }
        emitVoid(.store(addr: addr, value: v), span)
    }

    private var isReferenceSelf: Bool {
        currentSelf.map { $0.kind == .class_ || $0.kind == .actor_ } ?? false
    }

    // A stored-field read. A struct base is a value → `extractField`; a class/actor base is a managed
    // pointer → `fieldAddr` + `load`.
    private func lowerFieldRead(base: NOIRExpr, field: String, type: Type, span: Span) -> SSAValue? {
        guard case .named(let typeName, let kind) = base.type,
              let idx = ctx.fieldIndex(typeName, kind, field) else {
            fail("field access on a non-aggregate '\(field)'", span); return nil
        }
        if kind == .struct_ {
            // A struct in an addressable location (a slot / nested field) reads through `fieldAddr`+
            // `load` — cheaper than materializing the whole aggregate, and it keeps a pointer-bearing
            // struct out of a first-class SSA value (I10). A struct rvalue (a temporary, a by-value
            // param) has no address → project with `extractField`.
            if let addr = structAddr(base) {
                let fa = emit(.fieldAddr(base: addr, fieldIndex: idx), type, span)
                return emit(.load(fa), type, span)
            }
            guard let baseV = lowerExpr(base) else { return nil }
            return emit(.extractField(base: baseV, fieldIndex: idx), type, span)
        }
        guard let baseV = lowerExpr(base) else { return nil }   // class/actor: the managed pointer
        let addr = emit(.fieldAddr(base: baseV, fieldIndex: idx), type, span)
        return emit(.load(addr), type, span)
    }

    // Construct a struct (a by-value aggregate → `makeStruct`), a class (a managed heap object → an
    // explicit `alloc` the escape pass can un-heap, then a barriered store per field), or an actor (a
    // heap object like a class, then a `mailboxInit` in its reserved slot). Fields are emitted in
    // declared order, matched to the labelled constructor arguments (or, for an actor field, its
    // declared initializer).
    private func lowerConstruct(typeName: String, args: [NOIRArg], type: Type, span: Span) -> SSAValue? {
        guard case .named(_, let kind) = type else { fail("cannot construct '\(typeName)'", span); return nil }

        if kind == .actor_ {
            guard let fields = ctx.actorFields[typeName] else { fail("unknown actor '\(typeName)'", span); return nil }
            let obj = emit(.alloc(type), type, span)
            for (idx, f) in fields.enumerated() {
                let v: SSAValue?
                if let initE = f.initializer { v = lowerExpr(initE) }                       // declared initializer
                else if let arg = args.first(where: { $0.label == f.name }) { v = lowerExpr(arg.value) }
                else { fail("missing field '\(f.name)' constructing actor '\(typeName)'", span); return nil }
                guard let fv = v else { return nil }
                let addr = emit(.fieldAddr(base: obj, fieldIndex: idx), f.type, span)
                emitVoid(.writeBarrier(object: obj, value: fv), span)
                emitVoid(.store(addr: addr, value: fv), span)
            }
            emitVoid(.mailboxInit(obj), span)
            return obj
        }

        guard let fields = ctx.fields(typeName, kind) else { fail("cannot construct '\(typeName)'", span); return nil }
        func fieldValue(_ f: NOIRField) -> SSAValue? {
            guard let arg = args.first(where: { $0.label == f.name }) else {
                fail("missing field '\(f.name)' constructing '\(typeName)'", span); return nil
            }
            return lowerExpr(arg.value)
        }
        if kind == .struct_ {
            var vals: [SSAValue] = []
            for f in fields { guard let v = fieldValue(f) else { return nil }; vals.append(v) }
            return emit(.makeStruct(type, fields: vals), type, span)
        }
        // class: alloc, then a barriered store into each field slot.
        let obj = emit(.alloc(type), type, span)
        for (idx, f) in fields.enumerated() {
            guard let v = fieldValue(f) else { return nil }
            let addr = emit(.fieldAddr(base: obj, fieldIndex: idx), f.type, span)
            emitVoid(.writeBarrier(object: obj, value: v), span)
            emitVoid(.store(addr: addr, value: v), span)
        }
        return obj
    }

    private func lowerEnumInit(typeName: String, caseName: String, args: [NOIRArg], type: Type, span: Span) -> SSAValue? {
        guard let caseIdx = ctx.enumCaseIndex(typeName, caseName),
              let payload = ctx.enumCases[typeName]?[caseIdx].fields else {
            fail("cannot construct '\(typeName).\(caseName)'", span); return nil
        }
        var vals: [SSAValue] = []
        for f in payload {
            guard let arg = args.first(where: { $0.label == f.name }) else {
                fail("missing payload field '\(f.name)' for '\(typeName).\(caseName)'", span); return nil
            }
            guard let v = lowerExpr(arg.value) else { return nil }
            vals.append(v)
        }
        return emit(.makeEnum(type, caseIndex: caseIdx, fields: vals), type, span)
    }

    // A call to a named global (a free function / builtin) is `.direct`; a call through a value — a
    // closure/function-typed local, param, self field, or field access — is `.indirect`. A void-typed
    // call produces no value.
    private func lowerCall(callee: NOIRExpr, args: [NOIRArg], typeArgs: [Type], type: Type, span: Span) -> SSAValue? {
        let kind: SSACallKind
        if case .varRef(let name) = callee.kind, !isLocalName(name) {
            kind = .direct(name)                                   // a global function / builtin
        } else {
            guard let fn = lowerExpr(callee) else { return nil }   // a function value
            kind = .indirect(fn)
        }
        var argVals: [SSAValue] = []
        for a in args {
            guard let v = lowerExpr(a.value) else { return nil }
            argVals.append(v)
        }
        let call = SSACall(kind: kind, args: argVals, typeArgs: typeArgs)
        if type == .void { emitVoid(.call(call), span); return nil }
        return emit(.call(call), type, span)
    }

    // Whether a bare name refers to something in scope (a local, a slot, or a self field) rather than a
    // global function / builtin — i.e. whether a call on it is indirect.
    private func isLocalName(_ name: String) -> Bool {
        varType[name] != nil || slots[name] != nil || selfFieldIndex(name) != nil
    }

    private func lowerWitnessCall(receiver: NOIRExpr, interface: String, method: String,
                                  args: [NOIRExpr], type: Type, span: Span) -> SSAValue? {
        guard let box = lowerExpr(receiver) else { return nil }
        var argVals: [SSAValue] = []            // `self` is the box (carried in the `.witness` kind), not an arg
        for a in args { guard let v = lowerExpr(a) else { return nil }; argVals.append(v) }
        let call = SSACall(kind: .witness(receiver: box, interface: interface, method: method), args: argVals)
        if type == .void { emitVoid(.call(call), span); return nil }
        return emit(.call(call), type, span)
    }

    // `a[i]` → an explicit bounds check against the array's length, then an element load. The check is
    // the `boundscheck` op (BCE's target); `elementAddr`/`load` carry the element type as the pointee.
    private func lowerIndex(base: NOIRExpr, idx: NOIRExpr, elem: Type, span: Span) -> SSAValue? {
        guard let handle = lowerExpr(base), let idxV = lowerExpr(idx) else { return nil }
        let len = emit(.arrayLen(handle), .int, span)
        emitVoid(.boundscheck(index: idxV, length: len), span)
        let addr = emit(.elementAddr(base: handle, index: idxV), elem, span)
        return emit(.load(addr), elem, span)
    }

    // MARK: Aggregates (Option B — slots) and assignment

    private func isAggregate(_ t: Type) -> Bool {
        if case .named(_, let k) = t { return k == .struct_ || k == .enum_ }
        return false
    }

    // A `stackAlloc` for a value-aggregate slot, always emitted into the entry block so it dominates
    // every use (and never grows the stack on a loop iteration). The slot value's type is the pointee
    // aggregate type (the address-of convention SSAIR uses for `alloc`/`fieldAddr`/`elementAddr`).
    private func entryStackAlloc(_ t: Type) -> SSAValue {
        let v = newValue(t)
        bbs[entryId]?.insts.append(SSAInst(result: v, kind: .stackAlloc(t), span: lastSpan))
        return v
    }

    // Bind a name to a freshly-produced value. An aggregate goes into a new stack slot (store the
    // value in); a scalar (or reference) is tracked by SSA construction.
    private func bind(_ name: String, _ value: SSAValue, _ span: Span) {
        if isAggregate(value.type) {
            let slot = entryStackAlloc(value.type)
            emitVoid(.store(addr: slot, value: value), span)
            slots[name] = slot
        } else {
            write(name, curId, value)
        }
    }

    private func lowerAssign(target: NOIRExpr, value: NOIRExpr, span: Span) {
        switch target.kind {
        case .varRef(let name):
            if let slot = slots[name] {
                guard let v = lowerExpr(value) else { return }
                emitVoid(.store(addr: slot, value: v), span)   // whole-aggregate reassignment
            } else if varType[name] != nil {
                guard let v = lowerExpr(value) else { return }
                write(name, curId, v)                          // scalar / reference SSA rebinding
            } else if let idx = selfFieldIndex(name) {
                selfFieldWrite(name, idx, value, span)
            } else {
                fail("unknown assignment target '\(name)'", span)
            }

        case .fieldAccess(let base, let field):
            guard case .named(let typeName, let kind) = base.type,
                  let idx = ctx.fieldIndex(typeName, kind, field) else {
                fail("field assignment on a non-aggregate '\(field)'", span); return
            }
            if kind == .struct_ {
                guard let baseAddr = structAddr(base) else {
                    fail("struct field assignment needs an addressable base", span); return
                }
                let addr = emit(.fieldAddr(base: baseAddr, fieldIndex: idx), value.type, span)
                guard let v = lowerExpr(value) else { return }
                emitVoid(.store(addr: addr, value: v), span)   // struct slot: stack, no barrier
            } else {
                guard let ptr = lowerExpr(base) else { return }   // class/actor: the managed pointer
                let addr = emit(.fieldAddr(base: ptr, fieldIndex: idx), value.type, span)
                guard let v = lowerExpr(value) else { return }
                emitVoid(.writeBarrier(object: ptr, value: v), span)
                emitVoid(.store(addr: addr, value: v), span)
            }

        default:
            fail("unsupported assignment target", span)
        }
    }

    // The address of a struct lvalue (its slot, or a `fieldAddr` chain into one), or nil when the
    // expression is an rvalue struct with no address (a temporary, or a by-value param). Non-failing,
    // so callers can fall back to the value form; the assignment path reports the error itself.
    private func structAddr(_ e: NOIRExpr) -> SSAValue? {
        switch e.kind {
        case .varRef(let name):
            if let slot = slots[name] { return slot }
            if let idx = selfFieldIndex(name), let base = selfBase() {
                return emit(.fieldAddr(base: base, fieldIndex: idx), e.type, e.span)
            }
            return nil
        case .fieldAccess(let base, let field):
            guard case .named(let typeName, let kind) = base.type,
                  let idx = ctx.fieldIndex(typeName, kind, field) else { return nil }
            // A struct nested in a struct GEPs into the same slot; a struct behind a class pointer
            // GEPs off the loaded pointer.
            guard let ba = (kind == .struct_ ? structAddr(base) : lowerExpr(base)) else { return nil }
            return emit(.fieldAddr(base: ba, fieldIndex: idx), e.type, e.span)
        default:
            return nil
        }
    }

    // MARK: Match / switch

    // `switch subj { case .c(bindings): body ... }` → read the enum tag, then a `switchOn` to one
    // block per arm (exhaustive upstream, so the default is `unreachable`). Each arm extracts its
    // payload fields off the subject value and lowers its body, branching to a shared merge block.
    private func lowerSwitch(_ sw: NOIRSwitch, _ span: Span) {
        guard case .named(let enumName, .enum_) = sw.subject.type, ctx.enumCases[enumName] != nil else {
            fail("switch subject must be a concrete enum", sw.subject.span); return
        }
        guard let subjVal = lowerExpr(sw.subject) else { return }
        let tag = emit(.enumTag(subjVal), .int, span)

        var cases: [SSASwitchCase] = []
        var arms: [(block: Int, arm: NOIRCaseArm, caseIdx: Int)] = []
        let defaultB = newBlock()
        let mergeB = newBlock()
        for arm in sw.arms {
            guard let caseIdx = ctx.enumCaseIndex(enumName, arm.caseName) else {
                fail("unknown case '\(arm.caseName)' of '\(enumName)'", arm.span); continue
            }
            let ab = newBlock()
            cases.append(SSASwitchCase(value: caseIdx, target: ab, args: []))
            addPred(ab, curId)
            arms.append((ab, arm, caseIdx))
        }
        addPred(defaultB, curId)
        terminate(.switchOn(scrutinee: tag, cases: cases, defaultTarget: defaultB, defaultArgs: []), span)

        for (ab, arm, caseIdx) in arms {
            seal(ab); curId = ab
            for (i, binding) in arm.bindings.enumerated() {
                let pv = emit(.extractPayload(base: subjVal, caseIndex: caseIdx, fieldIndex: i), binding.type, arm.span)
                bind(binding.name, pv, arm.span)
            }
            lowerBlock(arm.body)
            if !terminated { terminate(.br(target: mergeB, args: []), arm.span); addPred(mergeB, curId) }
        }

        seal(defaultB); curId = defaultB; terminate(.unreachable, span)
        seal(mergeB); curId = mergeB
    }

    // MARK: Finalization

    // Turn the builder state into `SSABlock`s: seal everything, materialize block-argument lists on
    // every edge (each successor param `v` receives `read(v, pred)`), then delete trivial block
    // parameters (a param whose incoming arguments are all one value, ignoring self-references).
    private func finalize(returnType: Type) -> [SSABlock] {
        sealed.formUnion(order)

        // Fixpoint: reading a variable at a predecessor may itself introduce a parameter there, which
        // its own predecessors must then supply. Iterate until the parameter set is stable.
        var changed = true
        while changed {
            changed = false
            for b in order {
                guard let term = bbs[b]?.term else { continue }
                for succ in successors(term.kind) {
                    for param in bbs[succ]?.params ?? [] {
                        let before = bbs[b]?.params.count ?? 0
                        _ = read(param.name, b)
                        if (bbs[b]?.params.count ?? 0) != before { changed = true }
                    }
                }
            }
        }

        // Materialize the argument lists now that every block's parameters are fixed. Compute each
        // filled terminator into a local first: `fillArgs` reads `bbs`, so it must not run inside the
        // modifying access of the assignment back into `bbs`.
        for b in order {
            guard let term = bbs[b]?.term else { continue }
            let filled = fillArgs(term.kind, from: b)
            bbs[b]?.term = SSATerm(kind: filled, span: term.span)
        }

        var blocks = order.map { id -> SSABlock in
            let bb = bbs[id]!
            let term = bb.term ?? SSATerm(kind: returnType == .void ? .ret(nil) : .unreachable, span: lastSpan)
            return SSABlock(id: id, params: bb.params.map(\.value), insts: bb.insts, terminator: term)
        }
        blocks = pruneUnreachable(blocks)
        removeTrivialParams(&blocks)
        return blocks
    }

    // Drop blocks not reachable from the entry (e.g. the merge block after a match whose arms all
    // return). Unreachable blocks have no predecessors, so no edge references them.
    private func pruneUnreachable(_ blocks: [SSABlock]) -> [SSABlock] {
        guard let entry = blocks.first else { return blocks }
        var reachable: Set<Int> = [entry.id]
        var work = [entry.id]
        let byId = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        while let id = work.popLast() {
            for s in successors(byId[id]!.terminator.kind) where reachable.insert(s).inserted {
                work.append(s)
            }
        }
        return blocks.filter { reachable.contains($0.id) }
    }

    // Set each edge's argument list from the target block's parameters, read at this block.
    private func fillArgs(_ kind: SSATermKind, from block: Int) -> SSATermKind {
        func args(_ target: Int) -> [SSAValue] { (bbs[target]?.params ?? []).map { read($0.name, block) } }
        switch kind {
        case .br(let t, _):
            return .br(target: t, args: args(t))
        case .condBr(let cond, let t, _, let e, _):
            return .condBr(cond: cond, then: t, thenArgs: args(t), else: e, elseArgs: args(e))
        case .ret, .unreachable, .switchOn:
            return kind   // switch is not emitted in the SSA core
        }
    }
}

// MARK: - Trivial block-parameter elimination

// Delete a block parameter whose incoming arguments (across all predecessor edges) are all the same
// value, ignoring self-references — the block-argument analog of trivial-φ removal (Braun §3.1). This
// keeps the constructed SSA minimal, so the dump reads cleanly and later passes see no forwarding
// noise. Cascades (removing one parameter can make another trivial), so it iterates to a fixpoint.
private func removeTrivialParams(_ blocks: inout [SSABlock]) {
    var changed = true
    while changed {
        changed = false
        outer: for si in blocks.indices {
            let target = blocks[si].id
            for i in blocks[si].params.indices {
                let param = blocks[si].params[i]
                var incoming: [SSAValue] = []
                for b in blocks { incoming += edgeArgs(b.terminator.kind, toBlock: target, at: i) }
                if incoming.isEmpty { continue }
                let distinct = incoming.filter { $0.id != param.id }
                let ids = Set(distinct.map(\.id))
                guard ids.count == 1, let rep = distinct.first else { continue }

                blocks[si].params.remove(at: i)
                for bi in blocks.indices {
                    let k = removeEdgeArg(blocks[bi].terminator.kind, toBlock: target, at: i)
                    blocks[bi].terminator = SSATerm(kind: k, span: blocks[bi].terminator.span)
                }
                substitute(&blocks, [param.id: rep])
                changed = true
                break outer
            }
        }
    }
}

// The argument at position `i` on every edge from this terminator to `target`.
private func edgeArgs(_ kind: SSATermKind, toBlock target: Int, at i: Int) -> [SSAValue] {
    func at(_ args: [SSAValue]) -> [SSAValue] { i < args.count ? [args[i]] : [] }
    switch kind {
    case .br(let t, let args):
        return t == target ? at(args) : []
    case .condBr(_, let t, let ta, let e, let ea):
        return (t == target ? at(ta) : []) + (e == target ? at(ea) : [])
    case .switchOn(_, let cases, let d, let da):
        return cases.filter { $0.target == target }.flatMap { at($0.args) } + (d == target ? at(da) : [])
    case .ret, .unreachable:
        return []
    }
}

// Drop the argument at position `i` from every edge to `target`.
private func removeEdgeArg(_ kind: SSATermKind, toBlock target: Int, at i: Int) -> SSATermKind {
    func drop(_ args: [SSAValue], _ hit: Bool) -> [SSAValue] {
        guard hit, i < args.count else { return args }
        var a = args; a.remove(at: i); return a
    }
    switch kind {
    case .br(let t, let args):
        return .br(target: t, args: drop(args, t == target))
    case .condBr(let c, let t, let ta, let e, let ea):
        return .condBr(cond: c, then: t, thenArgs: drop(ta, t == target), else: e, elseArgs: drop(ea, e == target))
    case .switchOn(let s, let cases, let d, let da):
        let cs = cases.map { SSASwitchCase(value: $0.value, target: $0.target, args: drop($0.args, $0.target == target)) }
        return .switchOn(scrutinee: s, cases: cs, defaultTarget: d, defaultArgs: drop(da, d == target))
    case .ret, .unreachable:
        return kind
    }
}

// Replace value uses under `map` across every instruction operand and terminator argument.
private func substitute(_ blocks: inout [SSABlock], _ map: [Int: SSAValue]) {
    let f: (SSAValue) -> SSAValue = { map[$0.id] ?? $0 }
    for bi in blocks.indices {
        let insts = blocks[bi].insts.map {
            SSAInst(result: $0.result, kind: remapOperands($0.kind, f), span: $0.span)
        }
        blocks[bi].insts = insts
        let t = blocks[bi].terminator
        blocks[bi].terminator = SSATerm(kind: remapOperands(t.kind, f), span: t.span)
    }
}
