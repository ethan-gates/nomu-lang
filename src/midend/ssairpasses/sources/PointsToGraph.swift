import ssair
import support

// Points-to / reachability graph (task 166.1) — the one analysis the whole value-flow family (escape,
// fiber-locality, cross-fiber reachability, transfer, shareable-requirement, uniqueness) queries. Design:
// `internals/inference.md` ("Substrate design"). This file builds the per-function graph over raw
// (pre-transform) SSA; it computes no fact itself. The faithful escape query that reproduces today's
// `escapingValues` rides on top of it in task 166.2; the container/field-sensitive precision is 166.3.
//
// Node identity reuses SSA value ids (the decided scheme): an allocation-site result id *is* the abstract
// object it names, a parameter's id is its phantom object, and field edges are keyed by `(value-id,
// field)` — the field-sensitive extension of the old `derivedFrom` interior-pointer map.
//
// The graph is deliberately richer than the faithful escape query consumes. The faithful query reads only
// `sinks` + `interior` (the interior→base escape fixpoint); the points-to / field / flow structure is
// built but unconsumed until the precision flip and the interprocedural summary (task 164). Building it
// now keeps the representation ready for 164 to read two projections off one graph — this function's local
// facts and the k-limited interprocedural summary — without a rebuild.

// A field key. Field-sensitive on named struct/class/actor fields, keyed by **source name** (not physical
// offset) so a later layout reorder leaves 164's summary hash stable. Array elements collapse (an
// `elementAddr` indexes by a runtime value) and opaque-witness `T` collapses (its layout is hidden).
public enum PTGField: Hashable {
    case field(String)   // a named struct/class/actor field, by source name
    case element         // any array element — all elements collapse to one node
    case opaque          // opaque-witness payload / box payload / closure env / unresolved layout
}

// A field slot: an object (by value id) and one of its fields.
public struct PTGFieldRef: Hashable {
    public let base: Int
    public let field: PTGField
    public init(base: Int, field: PTGField) { self.base = base; self.field = field }
}

// A callee identity for a call-argument sink. A `direct` target names the callee so 164 can wire the
// argument into that callee's parameter summary; `witness`/`indirect` targets are unknown at this scope
// (164's dynamic-dispatch handling supplies the summary) and all their arguments stay conservatively
// escaping in the faithful query regardless.
public enum PTGCallee: Hashable {
    case direct(String)
    case witness(interface: String, method: String)
    case indirect
}

// A publishing use — a sink. The cases mirror `EscapeAnalysis.escapingUses`/`escapingTermUses` operand by
// operand, so the faithful escape query (166.2) is exactly "a value carrying any sink tag escapes" plus
// the interior→base fixpoint. The cross-fiber subset (`spawnCapture`, `actorSend`, and `callArg` to a
// channel-send once that library type exists) is the taxonomy that later drives fiber-locality and
// transfer in 164.
public enum PTGSink: Hashable {
    case ret                                           // returned from the function
    case edgeArg                                       // passed across a CFG edge as a block argument
    case store                                         // stored as the *value* into memory (store/writeBarrier)
    case box                                           // published into a box object
    case aggregate                                     // captured into a struct/enum/array-literal field
    case closureCapture                                // captured into a closure env
    case spawnCapture                                  // captured into a spawned fiber's env (cross-fiber)
    case actorSend                                     // actor message receiver/args (cross-fiber)
    case callArg(callee: PTGCallee, paramIndex: Int)   // argument to a callee's parameter i
    case globalStore                                   // stored into a module global — reserved; not structurally taggable today
}

public struct PointsToGraph {
    public let function: String

    // Abstract objects, by value id: allocation-site results plus one phantom object per parameter.
    public var objects: Set<Int>
    // The subset of `objects` that are managed class `alloc` sites — exactly what `StackPromotion`
    // promotes (actors and value aggregates are excluded). The precise escape query (166.3) relaxes field
    // containment only for a class object, since those are the promotable containers.
    public var classObjects: Set<Int>
    // Parameter phantom objects in declaration order (param index → object id). A root of 164's summary,
    // which keys escape/field facts per parameter.
    public var paramObjects: [Int]
    // Values flowed to a `ret`. The return-provenance root 164's summary reads.
    public var returnValues: Set<Int>

    // Value-flow edges: value id → the ids flowing *into* it (block-parameter edge arguments; a value read
    // out of a field). Points-to is reachability over these from a value to the object sites it reaches.
    public var flow: [Int: Set<Int>]
    // Field store edges: a field slot → the value ids written into it (from a `store` through an interior
    // pointer, and from the field operands of `makeStruct`/`makeEnum`/`arrayLit`/`box`/`makeClosure`).
    public var fieldStores: [PTGFieldRef: Set<Int>]
    // The field slots written by a real `store`/`writeBarrier` through an interior pointer — a heap field
    // write, as opposed to object construction (`box`/`makeClosure`/aggregate), whose published operands
    // stay unconditionally escaping this slice (a stack-promoted box payload / closure env hits the `p1`
    // env-param addrspace wall). The precise query relaxes containment only for these.
    public var storeFieldRefs: Set<PTGFieldRef>
    // Interior pointers: a `fieldAddr`/`elementAddr` result → the field slot it addresses. Drives both the
    // faithful interior→base escape fixpoint (`ref.base`) and store/load resolution through the pointer.
    public var interior: [Int: PTGFieldRef]
    // Field reads: a `load` through an interior pointer (and `extractField`/`extractPayload`) → the field
    // slot it reads, so the loaded value's points-to resolves to that field's stored set.
    public var fieldLoads: [Int: PTGFieldRef]

    // Publishing sinks reached at a use, by value id. The faithful escape terminal set.
    public var sinks: [Int: Set<PTGSink>]

    public init(function: String) {
        self.function = function
        self.objects = []
        self.classObjects = []
        self.paramObjects = []
        self.returnValues = []
        self.flow = [:]
        self.fieldStores = [:]
        self.storeFieldRefs = []
        self.interior = [:]
        self.fieldLoads = [:]
        self.sinks = [:]
    }

    fileprivate mutating func addFlow(into dst: Int, from src: Int) {
        flow[dst, default: []].insert(src)
    }
    fileprivate mutating func addFieldStore(_ ref: PTGFieldRef, _ value: Int) {
        fieldStores[ref, default: []].insert(value)
    }
    fileprivate mutating func addSink(_ v: Int, _ s: PTGSink) {
        sinks[v, default: []].insert(s)
    }
}

// Build the per-function graph over raw SSA. `aggregates` resolves a `fieldAddr`/`makeStruct` field index
// to its source name for field sensitivity; an absent layout collapses the field to `.opaque` (sound —
// the conservative merge), so the builder never depends on the layout being present.
public func buildPointsToGraph(_ f: SSAFunction, aggregates: [SSAAggregate] = []) -> PointsToGraph {
    var g = PointsToGraph(function: f.name)
    let layout = Dictionary(aggregates.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    // Parameters are phantom objects, one per param, addressable by index.
    for p in f.params {
        g.objects.insert(p.id)
        g.paramObjects.append(p.id)
    }

    // Target block parameters, by block id, so edge arguments wire into the matching φ parameter.
    let paramsOf = Dictionary(f.blocks.map { ($0.id, $0.params) }, uniquingKeysWith: { a, _ in a })

    for blk in f.blocks {
        for inst in blk.insts {
            record(inst, into: &g, layout: layout)
        }
        recordTerminator(blk.terminator.kind, into: &g, paramsOf: paramsOf)
    }
    return g
}

// Resolve a `fieldAddr`/`makeStruct`-style field index against a base type to a field key.
private func fieldKey(_ baseType: Type, _ index: Int, _ layout: [String: SSAAggregate]) -> PTGField {
    if case .named(let name, _) = baseType, let agg = layout[name], index >= 0, index < agg.fields.count {
        return .field(agg.fields[index].name)
    }
    return .opaque
}

private func record(_ inst: SSAInst, into g: inout PointsToGraph, layout: [String: SSAAggregate]) {
    let kind = inst.kind
    // Sinks — mirror EscapeAnalysis.escapingUses operand by operand.
    switch kind {
    case .store(_, let value):              g.addSink(value.id, .store)
    case .writeBarrier(_, let value):       g.addSink(value.id, .store)
    case .box(let v, _, _):                 g.addSink(v.id, .box)
    case .arrayLit(let elems, _):           for e in elems { g.addSink(e.id, .aggregate) }
    case .makeClosure(_, let env, _):       if let e = env { g.addSink(e.id, .closureCapture) }
    case .makeStruct(_, let fields):        for e in fields { g.addSink(e.id, .aggregate) }
    case .makeEnum(_, _, let fields):       for e in fields { g.addSink(e.id, .aggregate) }
    case .actorSend(let recv, _, let args): g.addSink(recv.id, .actorSend); for a in args { g.addSink(a.id, .actorSend) }
    case .spawn(_, _, let env, _):          if let e = env { g.addSink(e.id, .spawnCapture) }
    case .call(let c):                      recordCallArgSinks(c, into: &g)
    default:                                break
    }

    // A `store`/`writeBarrier` through an interior pointer is a field edge on the base object, recorded as
    // a real field write (`storeFieldRefs`) so the precise query can relax its containment. Handled before
    // the result guard below, since these ops are void (no result).
    if case .store(let addr, let value) = kind, let ref = g.interior[addr.id] {
        g.addFieldStore(ref, value.id); g.storeFieldRefs.insert(ref)
    }
    if case .writeBarrier(let object, let value) = kind, let ref = g.interior[object.id] {
        g.addFieldStore(ref, value.id); g.storeFieldRefs.insert(ref)
    }

    // Objects + field/flow structure.
    guard let r = inst.result else { return }
    switch kind {
    case .alloc(let t), .stackAlloc(let t):
        g.objects.insert(r.id)
        if case .named(_, .class_) = t { g.classObjects.insert(r.id) }
    case .fieldAddr(let base, let idx):
        g.interior[r.id] = PTGFieldRef(base: base.id, field: fieldKey(base.type, idx, layout))
    case .elementAddr(let base, _):
        g.interior[r.id] = PTGFieldRef(base: base.id, field: .element)
    case .load(let addr):
        if let ref = g.interior[addr.id] { g.fieldLoads[r.id] = ref }
    case .box(let v, _, _):
        g.objects.insert(r.id)
        g.addFieldStore(PTGFieldRef(base: r.id, field: .opaque), v.id)
    case .makeClosure(_, let env, _):
        g.objects.insert(r.id)
        if let e = env { g.addFieldStore(PTGFieldRef(base: r.id, field: .opaque), e.id) }
    case .arrayLit(let elems, _):
        g.objects.insert(r.id)
        for e in elems { g.addFieldStore(PTGFieldRef(base: r.id, field: .element), e.id) }
    case .makeStruct(let t, let fields):
        g.objects.insert(r.id)
        for (i, e) in fields.enumerated() { g.addFieldStore(PTGFieldRef(base: r.id, field: fieldKey(t, i, layout)), e.id) }
    case .makeEnum(let t, _, let fields):
        g.objects.insert(r.id)
        for (i, e) in fields.enumerated() { g.addFieldStore(PTGFieldRef(base: r.id, field: fieldKey(t, i, layout)), e.id) }
    case .extractField(let base, let idx):
        g.fieldLoads[r.id] = PTGFieldRef(base: base.id, field: fieldKey(base.type, idx, layout))
    case .extractPayload(let base, _, let idx):
        g.fieldLoads[r.id] = PTGFieldRef(base: base.id, field: fieldKey(base.type, idx, layout))
    default:
        break
    }
}

// Tag each call argument with the callee it feeds, so 164 can wire the argument into that parameter's
// summary. All call arguments carry a sink regardless of callee kind, so the faithful query escapes them
// exactly as the legacy analysis does.
private func recordCallArgSinks(_ c: SSACall, into g: inout PointsToGraph) {
    let callee: PTGCallee
    switch c.kind {
    case .direct(let name):                            callee = .direct(name)
    case .witness(_, let interface, let method):       callee = .witness(interface: interface, method: method)
    case .indirect:                                    callee = .indirect
    }
    for (i, a) in c.args.enumerated() { g.addSink(a.id, .callArg(callee: callee, paramIndex: i)) }
}

// Terminator operands: a returned value is a return root + `.ret` sink; a block argument flows into the
// target block's matching parameter (value-flow) and is also conservatively tagged `.edgeArg` so the
// faithful query escapes it as the legacy analysis does.
private func recordTerminator(_ kind: SSATermKind, into g: inout PointsToGraph, paramsOf: [Int: [SSAValue]]) {
    // A block argument flows into the target block's matching parameter (value-flow) and is also tagged
    // `.edgeArg` so the faithful query escapes it conservatively, as the legacy analysis does.
    func edge(_ target: Int, _ args: [SSAValue]) {
        let params = paramsOf[target] ?? []
        for (i, a) in args.enumerated() {
            g.addSink(a.id, .edgeArg)
            if i < params.count { g.addFlow(into: params[i].id, from: a.id) }
        }
    }
    switch kind {
    case .ret(let v):
        if let v = v { g.returnValues.insert(v.id); g.addSink(v.id, .ret) }
    case .br(let target, let args):
        edge(target, args)
    case .condBr(_, let then, let thenArgs, let elseB, let elseArgs):
        edge(then, thenArgs); edge(elseB, elseArgs)
    case .switchOn(_, let cases, let def, let defArgs):
        for c in cases { edge(c.target, c.args) }
        edge(def, defArgs)
    case .unreachable:
        break
    }
}
