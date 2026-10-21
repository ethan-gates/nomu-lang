import support   // Type

// Shaped-value liveness (task 176 Stage 2). A *shaped* value has conditional content (`Shape.conditional`):
// managed words whose managed-ness depends on a discriminant in the value, typed `i64` — a `String`, whose
// `word0` is a GC buffer pointer in the `heap` case, or a struct or enum holding one, or an enum with a
// managed payload. Such a value cannot ride the `addrspace(1)` statepoint root set, so when it is live across
// a safepoint the collector must be told where it sits (the frame-root path, shaped-roots.md Stages 3–4).
// This analysis answers *which shaped values are live at each point*, so codegen can home and record exactly
// those it needs to and leave non-crossing ones as pure SSA values (materialization is safepoint-gated).
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
    // `crossingInst[blockId][i]` — for a safepoint instruction `i`, the values that must be rooted at its
    // safepoint (`computeShapedLiveness` only; the homing and recording set).
    public var crossingInst: [Int: [Int: Set<Int>]] = [:]
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

// The operands an instruction stores into an object it allocates (an array literal's elements, a boxed
// value, an actor message's arguments, an appended element when the append grows the buffer). The lowering
// reads them after its allocation, so they are live at that safepoint even when the instruction is their
// last use.
public func storedOperands(_ k: SSAInstKind) -> [SSAValue] {
    switch k {
    case .arrayLit(let elements, _):        return elements
    case .box(let value, _, _):             return [value]
    case .actorSend(_, _, let args):        return args
    case .call(let c):
        if case .direct("__arrayAppend") = c.kind, c.args.count == 2 { return [c.args[1]] }
        return []
    default:                                return []
    }
}

// The SSA values that are frame addresses rather than values, though typed with their pointee: address-op
// results (`stackAlloc`, `fieldAddr`, `elementAddr`), a struct or enum method's by-pointer `self` (a mutating
// method's receiver is its caller's slot), and block parameters that receive an address.
public func addressValues(_ f: SSAFunction) -> Set<Int> {
    var addrs = Set<Int>()
    if f.isMutating, f.name.hasPrefix("m:"), let s = f.params.first {
        switch s.type {
        case .named(_, .struct_), .named(_, .enum_): addrs.insert(s.id)
        default: break
        }
    }
    for blk in f.blocks {
        for inst in blk.insts {
            guard let r = inst.result else { continue }
            switch inst.kind {
            case .stackAlloc, .fieldAddr, .elementAddr: addrs.insert(r.id)
            default: break
            }
        }
    }
    var paramsOf: [Int: [SSAValue]] = [:]
    for blk in f.blocks { paramsOf[blk.id] = blk.params }
    var changed = true
    while changed {
        changed = false
        for blk in f.blocks {
            for (target, args) in termEdges(blk.terminator.kind) {
                guard let ps = paramsOf[target] else { continue }
                for (k, a) in args.enumerated() where k < ps.count && addrs.contains(a.id) {
                    if addrs.insert(ps[k].id).inserted { changed = true }
                }
            }
        }
    }
    return addrs
}

private func termEdges(_ term: SSATermKind) -> [(Int, [SSAValue])] {
    switch term {
    case .br(let t, let args):                    return [(t, args)]
    case .condBr(_, let th, let ta, let el, let ea): return [(th, ta), (el, ea)]
    case .switchOn(_, let cases, let d, let da):  return cases.map { ($0.target, $0.args) } + [(d, da)]
    case .ret, .unreachable:                      return []
    }
}

// The tracked SSA value operands (uses) of an instruction or terminator.
private func operandIds(_ kind: SSAInstKind, _ tracked: (SSAValue) -> Bool) -> [Int] {
    var out: [Int] = []
    _ = remapOperands(kind) { if tracked($0) { out.append($0.id) }; return $0 }
    return out
}

private func operandIds(_ term: SSATermKind, _ tracked: (SSAValue) -> Bool) -> [Int] {
    var out: [Int] = []
    _ = remapOperands(term) { if tracked($0) { out.append($0.id) }; return $0 }
    return out
}

private func termSuccessors(_ term: SSATermKind) -> [Int] {
    switch term {
    case .br(let target, _):                      return [target]
    case .condBr(_, let then, _, let els, _):     return [then, els]
    case .switchOn(_, let cases, let def, _):     return cases.map(\.target) + [def]
    case .ret, .unreachable:                      return []
    }
}

// Backward dataflow to a fixpoint over the values with conditional content (`ShapeEnv.hasConditional`: a
// shaped leaf, a wrapper of one, or a struct or enum holding one or a managed enum payload), excluding frame
// addresses (`addressValues`), which are typed with their pointee. ids are enough for the consumer to key on.
// With no type context (`shapes` defaulted, the low-level liveness tests) no struct has content, so the
// tracked set is the leaves alone.
public func computeShapedLiveness(_ f: SSAFunction,
                                  _ shapes: ShapeEnv = ShapeEnv(structFields: { _ in nil }, enumCases: { _ in nil })) -> ShapedLiveness {
    let addrs = addressValues(f)
    func tracked(_ v: SSAValue) -> Bool { !addrs.contains(v.id) && shapes.hasConditional(v.type) }
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
            cur.formUnion(operandIds(b.terminator.kind, tracked))

            var perInst = [Set<Int>](repeating: [], count: b.insts.count)
            for i in b.insts.indices.reversed() {
                perInst[i] = cur                      // live immediately after inst i
                if let r = b.insts[i].result, tracked(r) { cur.remove(r.id) }
                cur.formUnion(operandIds(b.insts[i].kind, tracked))
            }
            liveOutInst[b.id] = perInst
            entry[b.id] = cur                         // includes live params (the loop-header poll set)

            var p = cur
            for bp in b.params where tracked(bp) { p.remove(bp.id) }
            if p != prop[b.id] {
                prop[b.id] = p
                changed = true
            }
        }
    }
    // The values crossing each safepoint instruction: live after it, less its own result (new, so it does
    // not cross), plus the operands it stores into the object it allocates (read after that allocation).
    var crossing: [Int: [Int: Set<Int>]] = [:]
    for b in f.blocks {
        for (i, inst) in b.insts.enumerated() where isSafepointInst(inst.kind) {
            var c = liveOutInst[b.id]?[i] ?? []
            if let r = inst.result { c.remove(r.id) }
            for v in storedOperands(inst.kind) where tracked(v) { c.insert(v.id) }
            crossing[b.id, default: [:]][i] = c
        }
    }
    return ShapedLiveness(liveInBlock: entry, liveOutInst: liveOutInst, crossingInst: crossing)
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
