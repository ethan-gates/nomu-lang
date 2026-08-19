import ssair
import support

// SSAIR verifier — the GC-precision-survival gate (m7-spec.md §7.0.5). Optimizer passes over a moving
// collector fail *silently* (relocation corruption, non-deterministic), so the driver runs this after
// every transform and rejects a module that violates the invariants below. It checks the structural
// properties a buggy transform would break; the full relational guarantee (root set / barrier set is a
// justified refinement of the tier-off program) is the differential test obligation T1–T7.
//
// Coverage of I1–I10:
//  • I1 — typed values are preserved: an SSA value id carries one address-space-bearing `Type` at its
//    definition and every use. A transform that re-provenanced a value (managed↔unmanaged, or any type
//    change) shows up as a value id used at two types.
//  • I2 — no managed↔unmanaged reinterpretation is introduced. SSAIR has no address-space cast op, so
//    managedness is fixed at a value's definition; the checkable form is that a heap allocation
//    (`alloc`/`box`/`arrayLit`/`makeClosure`) defines a managed (`addrspace(1)`) value, never a
//    by-value one.
//  • I3 — the root set is well-formed: every used value is defined, and every CFG edge passes exactly
//    the target block's parameter count with matching types (block-args → φ). A dropped def or a
//    mismatched merge edge is how the recovered root set diverges from the un-optimized one.
//  • I4/I5/I6 — a reference-type `stackAlloc` (a promoted heap allocation) must be non-escaping. Reuses
//    `escapingValues`, whose interior-pointer fixpoint also enforces I5 (an escaping `fieldAddr` would
//    block SROA, leaving a managed field unscannable) and I6 (a returned value escapes, so a promoted
//    object can't outlive the frame). Struct/enum `stackAlloc`s are original value-aggregate slots, not
//    promotions, and are skipped.
//  • I7 — a barrier is elided only where sound: a managed store into a heap object's field (an address
//    derived by `fieldAddr` from an `alloc`) must be covered by a `writeBarrier` for the same
//    object+value in the block. A store into a `stackAlloc` slot needs none (the slot is a scanned
//    root). I8 (a moved/copied store carries its barrier) is this same post-condition holding after any
//    store-moving transform.
//  • I9 — safepoint coverage is guaranteed downstream: the egress emits an unconditional poll at every
//    loop header (a back-edge target), so no loop is an unbounded safepoint-free region. Re-audit here
//    when a transform alters loop structure (inlining/unrolling, 7.5).
//  • I10 — a managed value stays a first-class scalar `p1`, never sunk into a pointer-bearing aggregate
//    live across a safepoint. Held by construction: Option B keeps mutable value aggregates in slots
//    (§7.2), and the statepoint rewriter rejects a GC pointer nested in an FCA. A liveness-based check
//    belongs with the transform that could introduce such a sink (inlining, 7.5).
//
// Returns a list of human-readable violations; empty means the module is well-formed.
public func verifySSAIR(_ module: SSAModule) -> [String] {
    var errs: [String] = []
    for f in module.functions { verifyFunction(f, &errs) }
    return errs
}

// A managed value is an `addrspace(1)` reference the collector scans/relocates. Value types (Int,
// Double, Bool, String, and by-value struct/enum) are unmanaged; `opaque` is post-mono-resolved
// elsewhere and treated conservatively as unmanaged here (heap allocations never carry it).
private func isManaged(_ t: Type) -> Bool {
    switch t {
    case .named(_, .class_), .named(_, .actor_), .array, .existential, .composition, .function:
        return true
    default:
        return false
    }
}

private func verifyFunction(_ f: SSAFunction, _ errs: inout [String]) {
    // Pass 1 — collect definitions (function params, block params, instruction results) and each
    // value id's type. I1: a redefinition at a different type, or a second definition of an id.
    var typeOf: [Int: Type] = [:]
    var defined = Set<Int>()
    func define(_ v: SSAValue, _ site: String) {
        if let prior = typeOf[v.id], prior != v.type {
            errs.append("[\(f.name)] I1: value %\(v.id) defined at conflicting types \(prior) vs \(v.type) (\(site))")
        }
        if !defined.insert(v.id).inserted {
            errs.append("[\(f.name)] SSA: value %\(v.id) defined more than once (\(site))")
        }
        typeOf[v.id] = v.type
    }
    for p in f.params { define(p, "param") }
    for blk in f.blocks {
        for p in blk.params { define(p, "bb\(blk.id) block-param") }
        for inst in blk.insts { if let r = inst.result { define(r, "bb\(blk.id) result") } }
    }

    // I2 — a heap allocation defines a managed value.
    for blk in f.blocks {
        for inst in blk.insts {
            guard let r = inst.result else { continue }
            // A heap allocation defines a managed value; an `onStack` closure/box is instead a stack
            // allocation (like a promoted `stackAlloc`), checked for non-escape in I4 below.
            var onStack = false
            switch inst.kind {
            case .alloc, .arrayLit:                 break
            case .makeClosure(_, _, let s):         onStack = s
            case .box(_, _, let s):                 onStack = s
            default:                                continue
            }
            if !onStack && !isManaged(r.type) {
                errs.append("[\(f.name)] I2: %\(r.id) is a heap allocation of non-managed type \(r.type)")
            }
        }
    }

    // Pass 2 — check uses. Every operand must be defined (I3 / SSA integrity) and used at its
    // definition type (I1). `remapOperands` enumerates an instruction's / terminator's operands
    // without re-listing the op set (a non-mutating walk: record, return unchanged).
    let blockIds = Set(f.blocks.map(\.id))
    func use(_ v: SSAValue, _ ctx: String) {
        if !defined.contains(v.id) {
            errs.append("[\(f.name)] I3: use of undefined value %\(v.id) (\(ctx))")
        } else if let t = typeOf[v.id], t != v.type {
            errs.append("[\(f.name)] I1: %\(v.id) used as \(v.type) but defined as \(t) (\(ctx))")
        }
    }
    for blk in f.blocks {
        for inst in blk.insts {
            _ = remapOperands(inst.kind) { v in use(v, "bb\(blk.id) inst"); return v }
        }
        _ = remapOperands(blk.terminator.kind) { v in use(v, "bb\(blk.id) term"); return v }

        // I3 — CFG edges: each target exists and receives exactly its block-parameter count, types
        // matching (the block-args → φ contract; a mismatch corrupts the merge-point root set).
        for (target, args) in edgeArgs(blk.terminator.kind) {
            guard blockIds.contains(target) else {
                errs.append("[\(f.name)] I3: bb\(blk.id) branches to nonexistent bb\(target)")
                continue
            }
            let params = f.blocks.first { $0.id == target }!.params
            if args.count != params.count {
                errs.append("[\(f.name)] I3: bb\(blk.id)→bb\(target) passes \(args.count) args, bb\(target) declares \(params.count) params")
            } else {
                for (i, a) in args.enumerated() where a.type != params[i].type {
                    errs.append("[\(f.name)] I3: bb\(blk.id)→bb\(target) arg \(i) type \(a.type) ≠ param \(params[i].type)")
                }
            }
        }
    }

    // The defining instruction of each value (for the provenance-sensitive checks below).
    var defKind: [Int: SSAInstKind] = [:]
    for blk in f.blocks {
        for inst in blk.insts { if let r = inst.result { defKind[r.id] = inst.kind } }
    }

    // I4/I5/I6 — a promoted allocation must be non-escaping. A reference-type `stackAlloc` is one the
    // stack-promotion transform produced from an `alloc`; ssairgen only stack-allocates struct/enum
    // value aggregates, so a class/actor `stackAlloc` is always a promotion. `escapingValues` folds in
    // I5 (an escaping interior pointer marks the base escaping) and I6 (a returned value escapes).
    let escaping = escapingValues(f)
    for blk in f.blocks {
        for inst in blk.insts {
            if case .stackAlloc(let t) = inst.kind, let r = inst.result, isManaged(t), escaping.contains(r.id) {
                errs.append("[\(f.name)] I4: stack-promoted %\(r.id) of \(t) escapes its frame")
            }
            // A stack-promoted closure object (`makeClosure`) or box (`box`) with `onStack` must likewise
            // be non-escaping — StackPromotion only sets the flag for a non-escaping result.
            if case .makeClosure(_, _, true) = inst.kind, let r = inst.result, escaping.contains(r.id) {
                errs.append("[\(f.name)] I4: stack-promoted closure %\(r.id) escapes its frame")
            }
            if case .box(_, _, true) = inst.kind, let r = inst.result, escaping.contains(r.id) {
                errs.append("[\(f.name)] I4: stack-promoted box %\(r.id) escapes its frame")
            }
        }
    }

    // I7 — a managed store into a heap object's field must be barriered. The barrier is elided only for
    // a `stackAlloc` slot (a scanned root); a store whose address is a `fieldAddr` off an `alloc` is a
    // heap-object store and needs a `writeBarrier` for the same object+value in the block. (I8 is this
    // holding after any store-moving transform.) Array element stores go through the `__arraySet`
    // builtin, not `store`, so `elementAddr` is not treated as a heap-field store here.
    for blk in f.blocks {
        var barriered = Set<String>()   // "object.id:value.id" seen so far in this block
        for inst in blk.insts {
            switch inst.kind {
            case .writeBarrier(let object, let value):
                barriered.insert("\(object.id):\(value.id)")
            case .store(let addr, let value) where isManaged(value.type):
                // A managed field store needs a barrier unless the object is a stack slot. The object
                // is `fieldAddr`'s base; a `stackAlloc` base (a value aggregate or a promoted object)
                // is a scanned root and skips the barrier, any other managed base is a heap object.
                guard case .fieldAddr(let base, _)? = defKind[addr.id] else { break }
                if case .stackAlloc(_)? = defKind[base.id] { break }
                guard isManaged(base.type) else { break }
                if !barriered.contains("\(base.id):\(value.id)") {
                    errs.append("[\(f.name)] I7: managed store of %\(value.id) into heap field of %\(base.id) is not barriered")
                }
            default:
                break
            }
        }
    }
}

// The (target, edge-args) pairs a terminator carries — the block-argument side of each CFG edge.
private func edgeArgs(_ term: SSATermKind) -> [(Int, [SSAValue])] {
    switch term {
    case .br(let t, let a): return [(t, a)]
    case .condBr(_, let t, let ta, let e, let ea): return [(t, ta), (e, ea)]
    case .switchOn(_, let cases, let d, let da): return cases.map { ($0.target, $0.args) } + [(d, da)]
    case .ret, .unreachable: return []
    }
}
