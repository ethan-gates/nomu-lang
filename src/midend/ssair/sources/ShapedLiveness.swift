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

// A *shaped* type is one whose value is the 16-byte bit-stealing shaped representation — `StringBase`, or a
// **single-field struct that wraps a shaped value** (task 121.1.1). A single-field wrapper is
// representationally identical to its field (one field at offset 0, the same 16 bytes, two registers), so it
// is itself shaped: it rides the shaped-root path and takes the kind-2 descriptor directly, rather than the
// frame-slot aggregate path a multi-field shaped-containing struct takes (task 176.3a). This is how
// `struct String { let base: StringBase }` inherits `StringBase`'s treatment with no String-specific code; the
// rule generalizes to any newtype over a shaped value. `shapedStructs` is the precomputed set of such wrapper
// names (`computeShapedStructs`); it is empty when there is no struct context (the low-level liveness tests),
// which leaves the predicate at its `StringBase`-only base case.
public func isShapedType(_ t: Type, _ shapedStructs: Set<String> = []) -> Bool {
    switch t {
    case .stringBase:                 return true
    case .named(let n, .struct_):     return shapedStructs.contains(n)
    default:                          return false
    }
}

// The single-field-shaped-wrapper set over a module's struct layouts: every struct with exactly one stored
// field whose type is shaped (a `StringBase`, or itself such a wrapper). A fixpoint so a wrapper-over-a-wrapper
// is included; iteration count is bounded by the struct count. A struct with zero or several stored fields is
// never a wrapper (a multi-field struct holding a shaped field rides the aggregate path, task 176.3a).
public func computeShapedStructs(_ structFields: [String: [Type]]) -> Set<String> {
    var set = Set<String>()
    var changed = true
    while changed {
        changed = false
        for (name, fields) in structFields where !set.contains(name) {
            if fields.count == 1, isShapedType(fields[0], set) {
                set.insert(name)
                changed = true
            }
        }
    }
    return set
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
private func shapedUses(_ kind: SSAInstKind, _ shapedStructs: Set<String>) -> [SSAValue] {
    func s(_ vs: SSAValue...) -> [SSAValue] { vs.filter { isShapedType($0.type, shapedStructs) } }
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
        return vs.filter { isShapedType($0.type, shapedStructs) }
    case .mailboxInit(let a):                      return s(a)
    case .actorSend(let receiver, _, let args):   return (args + [receiver]).filter { isShapedType($0.type, shapedStructs) }
    case .spawn(_, _, let env, _):                return [env].compactMap { $0 }.filter { isShapedType($0.type, shapedStructs) }
    case .makeStruct(_, let fields):              return fields.filter { isShapedType($0.type, shapedStructs) }
    case .makeEnum(_, _, let fields):             return fields.filter { isShapedType($0.type, shapedStructs) }
    case .extractField(let base, _):              return s(base)
    case .enumTag(let a):                          return s(a)
    case .extractPayload(let base, _, _):         return s(base)
    case .box(let value, _, _):                   return s(value)
    case .arrayLit(let elements, _):              return elements.filter { isShapedType($0.type, shapedStructs) }
    case .makeClosure(_, let env, _):             return [env].compactMap { $0 }.filter { isShapedType($0.type, shapedStructs) }
    }
}

private func shapedUses(_ term: SSATermKind, _ shapedStructs: Set<String>) -> [SSAValue] {
    switch term {
    case .br(_, let args):
        return args.filter { isShapedType($0.type, shapedStructs) }
    case .condBr(let cond, _, let thenArgs, _, let elseArgs):
        return ([cond] + thenArgs + elseArgs).filter { isShapedType($0.type, shapedStructs) }
    case .switchOn(let scrutinee, let cases, _, let defaultArgs):
        var vs = [scrutinee] + defaultArgs
        for c in cases { vs += c.args }
        return vs.filter { isShapedType($0.type, shapedStructs) }
    case .ret(let v):
        return v.flatMap { isShapedType($0.type, shapedStructs) ? [$0] : [] } ?? []
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

// Backward dataflow to a fixpoint. Shaped values only; ids are enough for the consumer to key on.
// `shapedStructs` (default empty) extends the shaped set to single-field shaped wrappers (task 121.1.1); with
// it empty the tracked set is `StringBase` values alone, matching the pre-wrapper behavior exactly.
public func computeShapedLiveness(_ f: SSAFunction, _ shapedStructs: Set<String> = []) -> ShapedLiveness {
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
            cur.formUnion(shapedUses(b.terminator.kind, shapedStructs).map(\.id))

            var perInst = [Set<Int>](repeating: [], count: b.insts.count)
            for i in b.insts.indices.reversed() {
                perInst[i] = cur                      // live immediately after inst i
                if let r = b.insts[i].result, isShapedType(r.type, shapedStructs) { cur.remove(r.id) }
                cur.formUnion(shapedUses(b.insts[i].kind, shapedStructs).map(\.id))
            }
            liveOutInst[b.id] = perInst
            entry[b.id] = cur                         // includes live params (the loop-header poll set)

            var p = cur
            for bp in b.params where isShapedType(bp.type, shapedStructs) { p.remove(bp.id) }
            if p != prop[b.id] {
                prop[b.id] = p
                changed = true
            }
        }
    }
    return ShapedLiveness(liveInBlock: entry, liveOutInst: liveOutInst)
}
