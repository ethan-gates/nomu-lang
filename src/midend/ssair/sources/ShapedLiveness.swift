import support   // Type

// Shaped-value liveness (task 176 Stage 2). A *shaped* value is a 16-byte bit-stealing value whose
// managed-ness is per-value and dynamic — today only `String`, whose `word0` is a GC buffer pointer in the
// `heap` case. Such a value cannot ride the `addrspace(1)` statepoint root set, so when it is live across a
// safepoint the collector must be told where it sits (the frame-root path, shaped-roots.md Stages 3–4).
// This analysis answers *which shaped values are live at each point*, so codegen can pin and record exactly
// those it needs to and leave non-crossing ones as pure SSA pairs (materialization is safepoint-gated).
//
// It is per-point liveness restricted to shaped values. The consumer decides which points are safepoints
// (a non-leaf `call`, the loop-header poll) and reads the live set there:
//   • `liveOutInst[blockId][i]` — shaped values live immediately after instruction `i` (minus the inst's
//     own result = the values that *cross* a call at `i`).
//   • `liveInBlock[blockId]` — shaped values live at block entry **including the block's own live
//     parameters** (what crosses a loop-header poll: the poll sits after the params are bound, and a
//     loop-carried `acc` arrives as a header param that the body still uses).
public struct ShapedLiveness {
    public let liveInBlock: [Int: Set<Int>]
    public let liveOutInst: [Int: [Set<Int>]]
}

// Liveness of a given set of SSA value ids — used for shaped-containing value-aggregate *slots* (task 176.3a):
// which `stackAlloc` slots carrying shaped content are live across which safepoints, so the egress records
// each live slot's base + aggregate shape there. Same backward dataflow as `computeShapedLiveness`, but the
// tracked set is supplied by the consumer (the slot ids) and uses are *all* operands in that set (via
// `remapOperands`), not only shaped-typed ones. Returns the same shape: `liveOutInst[b][i]` = tracked ids
// live immediately after inst `i`; `liveInBlock[b]` = tracked ids live at block entry incl. live params.
public func computeSlotLiveness(_ f: SSAFunction, tracked: Set<Int>) -> ShapedLiveness {
    func uses(_ kind: SSAInstKind) -> [Int] {
        var out: [Int] = []
        _ = remapOperands(kind) { if tracked.contains($0.id) { out.append($0.id) }; return $0 }
        return out
    }
    func uses(_ term: SSATermKind) -> [Int] {
        var out: [Int] = []
        _ = remapOperands(term) { if tracked.contains($0.id) { out.append($0.id) }; return $0 }
        return out
    }
    var prop: [Int: Set<Int>] = [:]
    var entry: [Int: Set<Int>] = [:]
    for b in f.blocks { prop[b.id] = []; entry[b.id] = [] }
    var liveOutInst: [Int: [Set<Int>]] = [:]

    var changed = true
    while changed {
        changed = false
        for b in f.blocks.reversed() {
            var cur = Set<Int>()
            for s in termSuccessors(b.terminator.kind) { cur.formUnion(prop[s] ?? []) }
            cur.formUnion(uses(b.terminator.kind))

            var perInst = [Set<Int>](repeating: [], count: b.insts.count)
            for i in b.insts.indices.reversed() {
                perInst[i] = cur
                if let r = b.insts[i].result, tracked.contains(r.id) { cur.remove(r.id) }
                cur.formUnion(uses(b.insts[i].kind))
            }
            liveOutInst[b.id] = perInst
            entry[b.id] = cur

            var p = cur
            for bp in b.params where tracked.contains(bp.id) { p.remove(bp.id) }
            if p != prop[b.id] { prop[b.id] = p; changed = true }
        }
    }
    return ShapedLiveness(liveInBlock: entry, liveOutInst: liveOutInst)
}

// Instructions whose lowering emits a non-leaf (statepoint) call — a GC safepoint where a live shaped value
// must be homed and recorded as a shaped root (task 176, shaped-roots.md Stage 2). Shared so the codegen
// homing/recording sites and the `verifySSAIR` I11 check read one authoritative set: a kind here but missing
// from one consumer would silently drop a shaped root. The allocation-forming kinds are safepoints because an
// allocation can trigger a collection; the rest lower to non-leaf runtime calls.
public func isSafepointInst(_ k: SSAInstKind) -> Bool {
    switch k {
    case .call, .alloc, .arrayLit, .box, .actorSend, .spawn, .spawnJoin, .mailboxInit:
        return true
    default:
        return false
    }
}

// The shaped-typed SSA value operands (uses) of an instruction.
private func shapedUses(_ kind: SSAInstKind, _ shapes: ShapeEnv) -> [SSAValue] {
    func s(_ vs: SSAValue...) -> [SSAValue] { vs.filter { shapes.isShapedValue($0.type) } }
    switch kind {
    case .constInt, .constDouble, .constBool, .constString,
         .alloc, .stackAlloc, .spawnJoin, .funcAddr:
        return []
    case .binary(_, let a, let b):                return s(a, b)
    case .load(let a):                            return s(a)
    case .store(let addr, let value):             return s(addr, value)
    case .writeBarrier(let object, let value):    return s(object, value)
    case .fieldAddr(let base, _):                 return s(base)
    case .elementAddr(let base, let index):       return s(base, index)
    case .arrayLen(let a):                         return s(a)
    case .boundscheck(let index, let length):     return s(index, length)
    case .call(let c):
        var vs = c.args
        if case .witness(let receiver, _, _) = c.kind { vs.append(receiver) }
        if case .indirect(let callee) = c.kind { vs.append(callee) }
        return vs.filter { shapes.isShapedValue($0.type) }
    case .mailboxInit(let a):                      return s(a)
    case .actorSend(let receiver, _, let args):   return (args + [receiver]).filter { shapes.isShapedValue($0.type) }
    case .spawn(_, _, let env, _):                return [env].compactMap { $0 }.filter { shapes.isShapedValue($0.type) }
    case .makeStruct(_, let fields):              return fields.filter { shapes.isShapedValue($0.type) }
    case .makeEnum(_, _, let fields):             return fields.filter { shapes.isShapedValue($0.type) }
    case .extractField(let base, _):              return s(base)
    case .enumTag(let a):                          return s(a)
    case .extractPayload(let base, _, _):         return s(base)
    case .box(let value, _, _):                   return s(value)
    case .arrayLit(let elements, _):              return elements.filter { shapes.isShapedValue($0.type) }
    case .makeClosure(_, let env, _):             return [env].compactMap { $0 }.filter { shapes.isShapedValue($0.type) }
    }
}

private func shapedUses(_ term: SSATermKind, _ shapes: ShapeEnv) -> [SSAValue] {
    switch term {
    case .br(_, let args):
        return args.filter { shapes.isShapedValue($0.type) }
    case .condBr(let cond, _, let thenArgs, _, let elseArgs):
        return ([cond] + thenArgs + elseArgs).filter { shapes.isShapedValue($0.type) }
    case .switchOn(let scrutinee, let cases, _, let defaultArgs):
        var vs = [scrutinee] + defaultArgs
        for c in cases { vs += c.args }
        return vs.filter { shapes.isShapedValue($0.type) }
    case .ret(let v):
        return v.flatMap { shapes.isShapedValue($0.type) ? [$0] : [] } ?? []
    case .unreachable:
        return []
    }
}

private func termSuccessors(_ term: SSATermKind) -> [Int] {
    switch term {
    case .br(let target, _):                      return [target]
    case .condBr(_, let then, _, let els, _):     return [then, els]
    case .switchOn(_, let cases, let def, _):     return cases.map(\.target) + [def]
    case .ret, .unreachable:                      return []
    }
}

// Backward dataflow to a fixpoint. Shaped values only (`ShapeEnv.isShapedValue`: a shaped leaf or a wrapper of
// one); ids are enough for the consumer to key on. With no type context (`shapes` defaulted, the low-level
// liveness tests) no struct is a wrapper, so the tracked set is the leaves alone.
public func computeShapedLiveness(_ f: SSAFunction,
                                  _ shapes: ShapeEnv = ShapeEnv(structFields: { _ in nil }, enumCases: { _ in nil })) -> ShapedLiveness {
    // `prop` is the live-in propagated to predecessors (block params removed — a param is defined by the
    // incoming edge, not live-in). `entry` is live-at-entry *including* live params — the poll record set.
    var prop: [Int: Set<Int>] = [:]
    var entry: [Int: Set<Int>] = [:]
    for b in f.blocks { prop[b.id] = []; entry[b.id] = [] }
    var liveOutInst: [Int: [Set<Int>]] = [:]

    var changed = true
    while changed {
        changed = false
        // Reverse order speeds convergence; the fixpoint loop makes order immaterial to the result.
        for b in f.blocks.reversed() {
            var cur = Set<Int>()
            for s in termSuccessors(b.terminator.kind) { cur.formUnion(prop[s] ?? []) }
            cur.formUnion(shapedUses(b.terminator.kind, shapes).map(\.id))

            var perInst = [Set<Int>](repeating: [], count: b.insts.count)
            for i in b.insts.indices.reversed() {
                perInst[i] = cur                      // live immediately after inst i
                if let r = b.insts[i].result, shapes.isShapedValue(r.type) { cur.remove(r.id) }
                cur.formUnion(shapedUses(b.insts[i].kind, shapes).map(\.id))
            }
            liveOutInst[b.id] = perInst
            entry[b.id] = cur                         // includes live params (the loop-header poll set)

            var p = cur
            for bp in b.params where shapes.isShapedValue(bp.type) { p.remove(bp.id) }
            if p != prop[b.id] {
                prop[b.id] = p
                changed = true
            }
        }
    }
    return ShapedLiveness(liveInBlock: entry, liveOutInst: liveOutInst)
}

// The frame slots the collector must be told about (task 176.5), and how every slot-derived address maps to
// its slot. A `stackAlloc` slot is recorded when its type has conditional content (managed words the
// statepoint rewrite cannot see: a shaped leaf, an enum payload), or when its type has any managed word and
// its address escapes — it, or an address derived from it (`fieldAddr`, `elementAddr`, a block parameter it
// flows into), is an operand of any instruction other than a load, store or address computation through it.
// A slot that does not escape is promoted to SSA by SROA, where the statepoint rewrite sees its plain managed
// pointers; an escaped one stays in memory, where it does not. Recording every non-empty slot would block
// SROA for every struct holding a reference.
public struct RecordedSlots {
    public let types: [Int: Type]            // recorded slot id → its type
    public let root: [Int: Int]              // recorded slot, or an address derived from one → the slot id
    // A block parameter that receives addresses of two different slots: its uses cannot be attributed to
    // one slot. Reported as a compile error rather than recorded imprecisely.
    public let ambiguous: [Int]

    public init(types: [Int: Type] = [:], root: [Int: Int] = [:], ambiguous: [Int] = []) {
        self.types = types; self.root = root; self.ambiguous = ambiguous
    }

    // The recorded slots a set of slot or slot-derived address ids refer to.
    public func roots(_ ids: Set<Int>) -> Set<Int> { Set(ids.compactMap { root[$0] }) }
}

public func recordedSlots(_ f: SSAFunction, _ shapes: ShapeEnv) -> RecordedSlots {
    var slotType: [Int: Type] = [:]
    var root: [Int: Int] = [:]
    for blk in f.blocks {
        for inst in blk.insts {
            if case .stackAlloc(let t) = inst.kind, let r = inst.result { slotType[r.id] = t; root[r.id] = r.id }
        }
    }
    var paramsOf: [Int: [SSAValue]] = [:]
    for blk in f.blocks { paramsOf[blk.id] = blk.params }
    var ambiguous = Set<Int>()
    // Derived addresses, to a fixpoint (block order need not be dominance order).
    func flow(_ target: Int, _ args: [SSAValue]) -> Bool {
        var grew = false
        for (k, a) in args.enumerated() {
            guard let s = root[a.id], let ps = paramsOf[target], k < ps.count else { continue }
            let p = ps[k].id
            if let have = root[p] { if have != s { ambiguous.insert(p) } }
            else { root[p] = s; grew = true }
        }
        return grew
    }
    var changed = true
    while changed {
        changed = false
        for blk in f.blocks {
            for inst in blk.insts {
                guard let r = inst.result, root[r.id] == nil else { continue }
                switch inst.kind {
                case .fieldAddr(let base, _), .elementAddr(let base, _):
                    if let s = root[base.id] { root[r.id] = s; changed = true }
                default: break
                }
            }
            switch blk.terminator.kind {
            case .br(let t, let args):
                if flow(t, args) { changed = true }
            case .condBr(_, let th, let ta, let el, let ea):
                if flow(th, ta) { changed = true }
                if flow(el, ea) { changed = true }
            case .switchOn(_, let cases, let d, let da):
                for c in cases where flow(c.target, c.args) { changed = true }
                if flow(d, da) { changed = true }
            case .ret, .unreachable:
                break
            }
        }
    }
    var escaped = Set<Int>()
    for blk in f.blocks {
        for inst in blk.insts {
            switch inst.kind {
            case .load, .fieldAddr, .elementAddr:
                continue   // reads through, or computes an address in, the slot
            case .store(_, let value):
                if let s = root[value.id] { escaped.insert(s) }   // the address itself stored somewhere
            default:
                _ = remapOperands(inst.kind) { if let s = root[$0.id] { escaped.insert(s) }; return $0 }
            }
        }
        if case .ret(let v?) = blk.terminator.kind, let s = root[v.id] { escaped.insert(s) }
    }
    var types: [Int: Type] = [:]
    for (id, t) in slotType {
        if shapes.hasConditional(t) || (escaped.contains(id) && !shapes.shape(t).isEmpty) { types[id] = t }
    }
    return RecordedSlots(types: types, root: root.filter { types[$0.value] != nil },
                         ambiguous: ambiguous.filter { root[$0].map { types[$0] != nil } ?? false }.sorted())
}
