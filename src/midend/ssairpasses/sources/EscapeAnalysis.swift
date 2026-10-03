import ssair
import support

// Escape analysis (M7 · 7.3) — the analysis only; the `StackPromotion` transform that consumes its
// result lives in `StackPromotion.swift` (the analysis/transform split, task 165.2). Intraprocedural
// and flow-insensitive for now: a value escapes if it reaches an escaping use anywhere in the function.
// Task 164 lifts this to an interprocedural, store-backed summary the transform reads.
//
// Soundness (I4): when unsure, an allocation escapes — a false "non-escaping" is the one unsound
// direction. So the escaping set is an over-approximation: every use that could publish the pointer
// (return, any call/send/spawn argument, a store *of* the value into memory, boxing, capture into an
// aggregate/closure, a block argument) marks it escaping, and an interior pointer escaping
// (`fieldAddr`/`elementAddr`) marks its base escaping (I5 — never leave a stack object's managed field
// unscannable behind an address-taken use).

// The set of SSA value ids that escape their defining function.
public func escapingValues(_ f: SSAFunction) -> Set<Int> {
    var escaping = Set<Int>()
    var derivedFrom: [Int: Int] = [:]   // interior pointer (fieldAddr/elementAddr result) → its base

    for blk in f.blocks {
        for inst in blk.insts {
            for u in escapingUses(inst.kind) { escaping.insert(u.id) }
            if let r = inst.result {
                switch inst.kind {
                case .fieldAddr(let base, _), .elementAddr(let base, _): derivedFrom[r.id] = base.id
                default: break
                }
            }
        }
        for u in escapingTermUses(blk.terminator.kind) { escaping.insert(u.id) }
    }

    // Fixpoint: if an interior pointer escapes, so does the object it points into.
    var changed = true
    while changed {
        changed = false
        for (result, base) in derivedFrom where escaping.contains(result) && !escaping.contains(base) {
            escaping.insert(base)
            changed = true
        }
    }
    return escaping
}

// Operands of an instruction that publish the value (make it reachable outside the current frame).
// The base of a `fieldAddr`/`elementAddr` and the object of a `store`/`writeBarrier` are structural
// (writing *into* the object), so they are not escaping uses; the *value* written is.
private func escapingUses(_ kind: SSAInstKind) -> [SSAValue] {
    switch kind {
    case .store(_, let value):            return [value]
    case .writeBarrier(_, let value):     return [value]
    // The boxed value is published into the box (reachable through it); the payload object stays heap
    // this slice, so keep it escaping. Only the box *object* is promoted (the `onStack` flag).
    case .box(let v, _, _):               return [v]
    case .arrayLit(let elems, _):         return elems
    // The env is published into the closure object (the captures become reachable through it). The env
    // *object* still escapes here — only the closure *object* is promoted this slice; a stack-promoted
    // env hits the `p1` env-param addrspace wall (a scoped follow-up, like `spawn:N`).
    case .makeClosure(_, let env, _):     return env.map { [$0] } ?? []
    case .makeStruct(_, let fields):      return fields
    case .makeEnum(_, _, let fields):     return fields
    case .actorSend(let recv, _, let args): return [recv] + args
    case .spawn(_, _, let env, _):        return env.map { [$0] } ?? []
    case .call(let c):
        // Only the call arguments escape. Calling *through* a value reads it — a witness receiver has
        // its witness+payload extracted, a closure/fn value has its fn+env loaded — none of which
        // publishes the value itself, so neither the witness receiver nor the indirect callee is an
        // escaping use (that is what lets a locally-dispatched box / locally-called closure promote).
        return c.args
    default:
        return []
    }
}

// A returned value escapes; a value handed across a CFG edge as a block argument is conservatively
// escaping (v1 does not unify an alloc with the φ it feeds — a refinement for loop-carried objects).
private func escapingTermUses(_ kind: SSATermKind) -> [SSAValue] {
    switch kind {
    case .ret(let v):                              return v.map { [$0] } ?? []
    case .br(_, let args):                         return args
    case .condBr(_, _, let ta, _, let ea):         return ta + ea
    case .switchOn(_, let cases, _, let da):       return cases.flatMap { $0.args } + da
    case .unreachable:                             return []
    }
}
