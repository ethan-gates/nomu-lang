import ssair
import support

// Escape analysis + stack promotion (M7 · 7.3). The analysis is intraprocedural and flow-insensitive
// for now (a value escapes if it reaches an escaping use anywhere in the function); the transform
// rewrites a non-escaping heap `alloc` to a stack `stackAlloc` and drops the write barriers into it.
//
// Soundness (I4): when unsure, an allocation escapes — a false "non-escaping" is the one unsound
// direction. So the escaping set is an over-approximation: every use that could publish the pointer
// (return, any call/send/spawn argument, a store *of* the value into memory, boxing, capture into an
// aggregate/closure, a block argument) marks it escaping, and an interior pointer escaping
// (`fieldAddr`/`elementAddr`) marks its base escaping (I5 — never leave a stack object's managed field
// unscannable behind an address-taken use). Class instances are promoted; actors are never (their
// mailbox/drain semantics assume a shared heap object), and struct/enum values are already `stackAlloc`.

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

// Stack promotion: rewrite each non-escaping `alloc` of a promotable type to a `stackAlloc`, and drop
// the now-unnecessary write barriers into those objects (I7 — a store into a stack slot, itself a
// root scanned every GC, needs no barrier). The egress allocates the object's storage in the entry
// block; SROA then scalar-replaces it, so a managed field becomes a statepoint-tracked SSA root (I5).
public struct StackPromotion: SSAPass {
    public init() {}
    public var name: String { "stack-promotion" }

    public func run(_ module: inout SSAModule) {
        for fi in module.functions.indices {
            let escaping = escapingValues(module.functions[fi])
            var promoted = Set<Int>()        // `alloc` sites → `stackAlloc`
            var stackObjects = Set<Int>()    // `makeClosure`/`box` results → the object stack-allocated
            for blk in module.functions[fi].blocks {
                for inst in blk.insts {
                    guard let r = inst.result, !escaping.contains(r.id) else { continue }
                    switch inst.kind {
                    case .alloc(let t) where isPromotable(t): promoted.insert(r.id)
                    case .makeClosure, .box:                  stackObjects.insert(r.id)
                    default:                                  break
                    }
                }
            }
            if promoted.isEmpty && stackObjects.isEmpty { continue }
            for bi in module.functions[fi].blocks.indices {
                var insts: [SSAInst] = []
                insts.reserveCapacity(module.functions[fi].blocks[bi].insts.count)
                for inst in module.functions[fi].blocks[bi].insts {
                    let onStack = inst.result.map { stackObjects.contains($0.id) } ?? false
                    switch inst.kind {
                    case .alloc(let t) where inst.result.map({ promoted.contains($0.id) }) ?? false:
                        insts.append(SSAInst(result: inst.result, kind: .stackAlloc(t), span: inst.span))
                    case .makeClosure(let fn, let env, _) where onStack:
                        insts.append(SSAInst(result: inst.result, kind: .makeClosure(funcName: fn, env: env, onStack: true), span: inst.span))
                    case .box(let v, let ifaces, _) where onStack:
                        insts.append(SSAInst(result: inst.result, kind: .box(value: v, interfaces: ifaces, onStack: true), span: inst.span))
                    case .writeBarrier(let object, _) where promoted.contains(object.id):
                        continue   // barrier into a stack slot — drop (the following store remains)
                    default:
                        insts.append(inst)
                    }
                }
                module.functions[fi].blocks[bi].insts = insts
            }
        }
    }

    // Which `alloc` types promote to a `stackAlloc` slot. Only class instances. Actors keep their
    // shared-heap semantics; struct/enum values are already `stackAlloc`. A non-escaping closure
    // *object* promotes separately (the `makeClosure` `onStack` flag), but its `env` object still
    // allocates here as a heap class — env stack-promotion is a scoped follow-up (the `p1` env-param
    // addrspace wall); a spawn env is likewise never promoted (it crosses the fiber boundary).
    private func isPromotable(_ t: Type) -> Bool {
        if case .named(_, .class_) = t { return true }
        return false
    }
}
