import ssair
import support
import ast

// Scalar promotion for the loop-carried φ-web (m7-spec.md §7.3.1). A non-escaping class object that is
// reassigned to a fresh allocation each iteration flows through a loop block parameter (an object φ);
// v1 `StackPromotion` leaves it heap because any block-argument value is marked escaping, and LLVM
// leaves the managed-pointer φ un-promoted (SROA does not scalarize a phi-captured allocation). This
// pass decomposes such an object into per-field SSA values — Approach B (field scalarization), the move
// Swift SIL and Go SSA make above their backend: the object's φ widens into one φ per field, the `alloc`
// disappears, and a managed field becomes an ordinary addrspace(1) SSA value tracked as a root across
// the loop-header poll (the statepoint mechanism, T2/escape-nonleaf).
//
// v1 scope: loop-carried classes with scalar / reference fields, constructed fresh (each field stored
// once at construction) and never mutated in place through a φ value. In-place field mutation of a
// loop-carried object (which needs field-level joins the object φ does not mark — per-field mem2reg)
// and classes with embedded value-aggregate fields are deferred; those webs stay heap. The direct
// (non-loop) path stays on `StackPromotion` + LLVM SROA. Actors are never promoted.
//
// Soundness reduces to two mechanisms already trusted: field decomposition is SSA construction at field
// granularity, and a scalarized managed field is a `p1` SSA value relocated by the statepoint rewriter.
// The atomic-escape rule over each φ-web (any member escaping ⇒ the whole web stays heap) removes any
// need to reconstitute a partially promoted object. The distinct-SSA-value form is also why a
// same-slot aliasing hazard (a previous object read after the fresh one is built) cannot arise.

public struct ScalarPromotion: SSAPass {
    public init() {}
    public var name: String { "scalar-promotion" }

    public func run(_ module: inout SSAModule) {
        for fi in module.functions.indices {
            promote(&module.functions[fi])
        }
    }
}

// A minimal union-find over SSA value ids, used to build φ-webs (a block parameter unified with each
// value passed to it on an incoming edge).
private final class UnionFind {
    private var parent: [Int: Int] = [:]
    func find(_ x: Int) -> Int {
        if parent[x] == nil { parent[x] = x; return x }
        var r = x
        while parent[r]! != r { r = parent[r]! }
        var c = x
        while parent[c]! != r { let n = parent[c]!; parent[c] = r; c = n }
        return r
    }
    func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
    var roots: Set<Int> { Set(parent.keys.map { find($0) }) }
    func members(of root: Int) -> [Int] { parent.keys.filter { find($0) == root } }
}

// The (target block, argument list) of each outgoing edge of a terminator, in edge order.
private func edges(_ kind: SSATermKind) -> [(target: Int, args: [SSAValue])] {
    switch kind {
    case .br(let t, let a):                              return [(t, a)]
    case .condBr(_, let t, let ta, let e, let ea):       return [(t, ta), (e, ea)]
    case .switchOn(_, let cs, let d, let da):            return cs.map { ($0.target, $0.args) } + [(d, da)]
    case .ret, .unreachable:                             return []
    }
}

private func isClass(_ t: Type) -> Bool {
    if case .named(_, .class_) = t { return true }
    return false
}

// A field type v1 will thread through a widened φ: a scalar (one SSA value) or a class/actor reference
// (one `p1` pointer, tracked as a root). A by-value struct/enum, `String`, existential, or closure field
// is excluded — those either form a pointer-bearing aggregate φ (the FCA/I10 hazard) or await proof.
private func isFieldPromotable(_ t: Type) -> Bool {
    switch t {
    case .int, .double, .bool:                     return true
    case .named(_, .class_), .named(_, .actor_):   return true
    default:                                       return false
    }
}

// How a value id is defined in a function: a fresh `alloc`, a block parameter, or anything else
// (a call result, a function parameter, a field read, …) — the last disqualifies its web (v1).
private enum Def {
    case alloc(Type)
    case param(block: Int, pos: Int)
    case other
}

private func promote(_ f: inout SSAFunction) {
    // 1 · CFG predecessors + φ-webs. Union each class-typed block parameter with the value passed to it
    // on every incoming edge; the connected components are the object webs (alloc ↔ φ ↔ back-edge value).
    let uf = UnionFind()
    for blk in f.blocks {
        for e in edges(blk.terminator.kind) {
            guard let target = f.blocks.first(where: { $0.id == e.target }) else { continue }
            for (i, p) in target.params.enumerated() where isClass(p.type) && i < e.args.count {
                uf.union(p.id, e.args[i].id)
            }
        }
    }
    if uf.roots.isEmpty { return }

    // 2 · Definitions + the constructor stores of each alloc, plus a fieldAddr → (base, index) map.
    var def: [Int: Def] = [:]
    for p in f.params { def[p.id] = .other }
    var fieldAddrOf: [Int: (base: Int, index: Int)] = [:]
    for blk in f.blocks {
        for (pos, p) in blk.params.enumerated() { def[p.id] = .param(block: blk.id, pos: pos) }
        for inst in blk.insts {
            if case .fieldAddr(let base, let idx) = inst.kind, let r = inst.result {
                fieldAddrOf[r.id] = (base.id, idx)
            }
            guard let r = inst.result else { continue }
            switch inst.kind {
            case .alloc(let t): def[r.id] = .alloc(t)
            default:            def[r.id] = def[r.id] ?? .other
            }
        }
    }
    // Constructor stores: field index → stored value, per alloc base. Also count stores per (base,index)
    // so a field written more than once (mutation) disqualifies the web.
    var ctor: [Int: [Int: SSAValue]] = [:]
    var storeCount: [Int: [Int: Int]] = [:]
    for blk in f.blocks {
        for inst in blk.insts {
            if case .store(let addr, let value) = inst.kind, let fa = fieldAddrOf[addr.id] {
                ctor[fa.base, default: [:]][fa.index] = value
                storeCount[fa.base, default: [:]][fa.index, default: 0] += 1
            }
        }
    }

    // 3 · Escaping members. A member escapes if it is a `ret` value or appears in a publishing operand
    // position of any instruction (store/barrier value, call/send/spawn argument, boxed/captured/…).
    // Edge arguments are intra-web by construction (the union above), so they never escape here.
    var escaping = Set<Int>()
    for blk in f.blocks {
        for inst in blk.insts { for id in escapingOperandIds(inst.kind) { escaping.insert(id) } }
        if case .ret(let v?) = blk.terminator.kind { escaping.insert(v.id) }
    }

    // 4 · Classify each web; keep the promotable ones (v1 shape).
    struct Web { var members: [Int]; var fieldTypes: [Type] }
    var promotable: [Web] = []
    for root in uf.roots {
        let members = uf.members(of: root)
        // A class web (representative type is a class) that no member escapes.
        guard let repType = members.compactMap({ typeOf($0, f) }).first(where: { isClass($0) }) else { continue }
        _ = repType
        if members.contains(where: { escaping.contains($0) }) { continue }
        // Every member is an alloc or a block parameter; a param member is never mutated in place; every
        // alloc member is constructed with each field stored exactly once (contiguous 0..<n).
        var allocFieldTypes: [Type]? = nil
        var ok = true
        for m in members {
            switch def[m] {
            case .alloc:
                let stores = storeCount[m] ?? [:]
                let n = stores.count
                guard n > 0, (0..<n).allSatisfy({ stores[$0] == 1 }) else { ok = false; break }
                let types = (0..<n).map { ctor[m]![$0]!.type }
                // v1 field types: scalars and class/actor references only. A by-value struct/enum field
                // would become an FCA φ (a pointer-bearing aggregate across the loop-header safepoint —
                // the I10 hazard the verifier does not catch); `String`/existential/closure fields are
                // left out until their φ form is proven. Any other field type ⇒ the web stays heap.
                guard types.allSatisfy(isFieldPromotable) else { ok = false; break }
                if let prev = allocFieldTypes, prev.count != types.count { ok = false; break }
                allocFieldTypes = types
            case .param:
                // No store may target a field of a φ value (in-place mutation → needs a field join).
                if fieldStoreTargets(f, base: m, fieldAddrOf: fieldAddrOf) { ok = false }
            default:
                ok = false   // a member from a call / function parameter / elsewhere — cannot scalarize
            }
            if !ok { break }
        }
        guard ok, let fieldTypes = allocFieldTypes else { continue }
        promotable.append(Web(members: members, fieldTypes: fieldTypes))
    }
    if promotable.isEmpty { return }

    // 5 · Decompose. Assign per-field SSA values to every member: an alloc's fields are its constructor
    // values; a φ value's fields are fresh block parameters (widening the object φ into field φs).
    var nextId = maxValueId(f) + 1
    func fresh(_ t: Type) -> SSAValue { let v = SSAValue(id: nextId, type: t); nextId += 1; return v }

    var fieldOf: [Int: [SSAValue]] = [:]           // member id → its per-field values
    var widenedParam = Set<Int>()                  // param-member ids replaced by field params
    for web in promotable {
        for m in web.members {
            switch def[m]! {
            case .alloc:
                fieldOf[m] = (0..<web.fieldTypes.count).map { ctor[m]![$0]! }
            case .param:
                fieldOf[m] = web.fieldTypes.map { fresh($0) }
                widenedParam.insert(m)
            case .other:
                break
            }
        }
    }

    // A field read `load(fieldAddr(member, i))` becomes the member's current field value. Resolve chains
    // (a constructor value can itself be another member's field read).
    var subst: [Int: SSAValue] = [:]
    for blk in f.blocks {
        for inst in blk.insts {
            guard case .load(let addr) = inst.kind, let r = inst.result,
                  let fa = fieldAddrOf[addr.id], fieldOf[fa.base] != nil else { continue }
            subst[r.id] = fieldOf[fa.base]![fa.index]
        }
    }
    func resolve(_ v: SSAValue) -> SSAValue {
        var cur = v; var guardCount = 0
        while let next = subst[cur.id], guardCount < 1_000_000 { cur = next; guardCount += 1 }
        return cur
    }

    // Rewrite: drop the object's alloc / field GEPs / barriers / loads / stores; remap remaining operands
    // through `resolve`; widen block parameters and the edge arguments feeding them.
    let originalParams: [Int: [SSAValue]] = Dictionary(uniqueKeysWithValues: f.blocks.map { ($0.id, $0.params) })
    func isDeadAddrUser(_ kind: SSAInstKind) -> Bool {
        switch kind {
        case .alloc:                    return false   // handled by member check below
        case .fieldAddr(let base, _):   return fieldOf[base.id] != nil
        case .load(let addr):           return fieldAddrOf[addr.id].map { fieldOf[$0.base] != nil } ?? false
        case .store(let addr, _):       return fieldAddrOf[addr.id].map { fieldOf[$0.base] != nil } ?? false
        case .writeBarrier(let obj, _): return fieldOf[obj.id] != nil
        default:                        return false
        }
    }
    for bi in f.blocks.indices {
        // Instructions: drop the scalarized object's memory ops, keep + operand-remap the rest.
        var insts: [SSAInst] = []
        insts.reserveCapacity(f.blocks[bi].insts.count)
        for inst in f.blocks[bi].insts {
            if let r = inst.result, fieldOf[r.id] != nil, case .alloc = inst.kind { continue }   // the object alloc
            if isDeadAddrUser(inst.kind) { continue }
            insts.append(SSAInst(result: inst.result, kind: remapOperands(inst.kind, resolve), span: inst.span))
        }
        f.blocks[bi].insts = insts
        // Block parameters: replace each widened object param by its field params.
        f.blocks[bi].params = f.blocks[bi].params.flatMap { widenedParam.contains($0.id) ? fieldOf[$0.id]! : [$0] }
        // Terminator: widen the arguments feeding a widened target param; remap the rest.
        f.blocks[bi].terminator = SSATerm(
            kind: rewriteEdges(f.blocks[bi].terminator.kind, originalParams: originalParams,
                               widenedParam: widenedParam, fieldOf: fieldOf, resolve: resolve),
            span: f.blocks[bi].terminator.span)
    }
}

// Rebuild a terminator's edge arguments: at a position whose target parameter was a widened φ value,
// the single object argument expands to that argument's per-field values; every other argument is
// operand-remapped. Non-edge operands (a `condBr`/`switch` scrutinee, a `ret` value) are remapped too.
private func rewriteEdges(_ kind: SSATermKind, originalParams: [Int: [SSAValue]],
                          widenedParam: Set<Int>, fieldOf: [Int: [SSAValue]],
                          resolve: (SSAValue) -> SSAValue) -> SSATermKind {
    func expand(_ target: Int, _ args: [SSAValue]) -> [SSAValue] {
        let params = originalParams[target] ?? []
        var out: [SSAValue] = []
        for (i, a) in args.enumerated() {
            if i < params.count, widenedParam.contains(params[i].id), let fields = fieldOf[a.id] {
                out.append(contentsOf: fields.map(resolve))
            } else {
                out.append(resolve(a))
            }
        }
        return out
    }
    switch kind {
    case .br(let t, let a):
        return .br(target: t, args: expand(t, a))
    case .condBr(let c, let t, let ta, let e, let ea):
        return .condBr(cond: resolve(c), then: t, thenArgs: expand(t, ta), else: e, elseArgs: expand(e, ea))
    case .switchOn(let s, let cs, let d, let da):
        let cases = cs.map { SSASwitchCase(value: $0.value, target: $0.target, args: expand($0.target, $0.args)) }
        return .switchOn(scrutinee: resolve(s), cases: cases, defaultTarget: d, defaultArgs: expand(d, da))
    case .ret(let v):
        return .ret(v.map(resolve))
    case .unreachable:
        return .unreachable
    }
}

// Operand ids of an instruction that publish a value (make it reachable outside the frame) — the escape
// set. Mirrors EscapeAnalysis's `escapingUses`; a `fieldAddr`/`elementAddr` base and a call/witness
// receiver are structural reads, not publications.
private func escapingOperandIds(_ kind: SSAInstKind) -> [Int] {
    switch kind {
    case .store(_, let v):                  return [v.id]
    case .writeBarrier(_, let v):           return [v.id]
    case .box(let v, _, _):                 return [v.id]
    case .arrayLit(let elems, _):           return elems.map(\.id)
    case .makeClosure(_, let env, _):       return env.map { [$0.id] } ?? []
    case .makeStruct(_, let fields):        return fields.map(\.id)
    case .makeEnum(_, _, let fields):       return fields.map(\.id)
    case .actorSend(let recv, _, let args): return [recv.id] + args.map(\.id)
    case .spawn(_, _, let env, _):          return env.map { [$0.id] } ?? []
    case .call(let c):                      return c.args.map(\.id)
    default:                                return []
    }
}

// Whether any store in the function targets a field of `base` (an in-place field mutation of a φ value).
private func fieldStoreTargets(_ f: SSAFunction, base: Int, fieldAddrOf: [Int: (base: Int, index: Int)]) -> Bool {
    for blk in f.blocks {
        for inst in blk.insts {
            if case .store(let addr, _) = inst.kind, fieldAddrOf[addr.id]?.base == base { return true }
        }
    }
    return false
}

private func typeOf(_ id: Int, _ f: SSAFunction) -> Type? {
    for p in f.params where p.id == id { return p.type }
    for blk in f.blocks {
        for p in blk.params where p.id == id { return p.type }
        for inst in blk.insts where inst.result?.id == id { return inst.result?.type }
    }
    return nil
}

private func maxValueId(_ f: SSAFunction) -> Int {
    var m = 0
    for p in f.params { m = max(m, p.id) }
    for blk in f.blocks {
        for p in blk.params { m = max(m, p.id) }
        for inst in blk.insts { if let r = inst.result { m = max(m, r.id) } }
    }
    return m
}
