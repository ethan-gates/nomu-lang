import ssair
import support

// Escape as a query on the points-to / reachability graph (task 166.2). The design (`internals/
// inference.md`) makes every value-flow fact a reachability query on one graph with a fact-specific sink
// set; this is the first such query, and it is deliberately **faithful** — it reproduces today's
// `EscapeAnalysis.escapingValues` exactly, so the graph swaps in behind `StackPromotion` with zero
// behaviour change (task 166.3, the differential oracle). The container/field-sensitive precision the
// graph's points-to / field edges enable is task 166.3's flip; this query ignores them.
//
// The reproduction is structural: `buildPointsToGraph` tags exactly the operands
// `EscapeAnalysis.escapingUses`/`escapingTermUses` publish, so a value escapes iff it carries any sink
// tag — then the one legacy refinement, "an interior pointer escaping marks its base escaping", is the
// interior→base fixpoint over the graph's `interior` map.

extension PointsToGraph {
    // The faithful escape terminal set: value ids that reach an escaping use. Over-approximate (unsure ⇒
    // escapes), matching the legacy soundness direction (I4).
    public func faithfulEscaping() -> Set<Int> {
        var escaping = Set(sinks.keys)   // a value carrying any publishing-sink tag escapes
        // Fixpoint: if an interior pointer (fieldAddr/elementAddr result) escapes, so does the object it
        // points into — never leave a stack object's managed field unscannable behind an address-taken
        // use (I5). Iterated so chained interior pointers propagate.
        var changed = true
        while changed {
            changed = false
            for (result, ref) in interior where escaping.contains(result) && !escaping.contains(ref.base) {
                escaping.insert(ref.base)
                changed = true
            }
        }
        return escaping
    }
}

// A sink that publishes a value out of the frame unconditionally — the terminal set the precise query
// seeds from. The two **conditional** sinks are excluded: `.store` (a heap field write, relaxed to field
// containment) and `.edgeArg` (a CFG-edge block argument, relaxed to value-flow into the target
// parameter). Object-construction sinks (`.box`/`.closureCapture`/`.aggregate`) stay terminal — a
// stack-promoted box payload / closure env hits the `p1` env-param addrspace wall, so their contents stay
// heap this slice.
extension PTGSink {
    fileprivate var isTerminalEscape: Bool {
        switch self {
        case .ret, .globalStore, .spawnCapture, .actorSend, .callArg,
             .box, .closureCapture, .aggregate:
            return true
        case .store, .edgeArg:
            return false
        }
    }
}

extension PointsToGraph {
    // The precise (container/field-sensitive) escape set (task 166.3). It relaxes two faithful rules: a
    // value written into a non-escaping local **class** object's field escapes only if that object does
    // (today it escapes unconditionally), and a block argument escapes only if the target parameter does.
    // Everything else stays conservative, so the result is a **subset** of `faithfulEscaping()` by
    // construction — `StackPromotion` therefore promotes a **superset**. Soundness is validated by the
    // GC-stress suite; the unsure directions stay escaping (a non-class / parameter / construction
    // container, and any field write whose base is not a visible local class object, keep the value
    // escaping).
    public func preciseEscaping() -> Set<Int> {
        var escaping = Set<Int>()
        for (v, ss) in sinks where ss.contains(where: { $0.isTerminalEscape }) { escaping.insert(v) }

        var changed = true
        while changed {
            changed = false
            func mark(_ id: Int) { if escaping.insert(id).inserted { changed = true } }

            // A block argument escapes only if the target parameter it flows into does.
            for (dst, srcs) in flow where escaping.contains(dst) {
                for s in srcs { mark(s) }
            }
            // An interior pointer escaping marks the object it points into (as faithful).
            for (i, ref) in interior where escaping.contains(i) { mark(ref.base) }
            // Field containment: a value written into a field escapes if its container does. Relaxed only
            // for a real field write into a local class object; every other container (construction, a
            // parameter, or an unresolved base) keeps the value unconditionally escaping.
            for (ref, vals) in fieldStores {
                let relaxable = storeFieldRefs.contains(ref) && classObjects.contains(ref.base)
                if !relaxable || escaping.contains(ref.base) {
                    for v in vals { mark(v) }
                }
            }
        }
        return escaping
    }
}

// The graph-backed escape provider: build the graph, run the chosen query. Drop-in for the `escaping:`
// provider `StackPromotion` consumes (task 165.2's injection point). `precise == false` is the faithful
// query (166.3's unchanged-output oracle); `precise == true` is the container/field-sensitive query
// (166.3). `aggregates` feeds field-name resolution.
public func graphEscaping(_ f: SSAFunction, aggregates: [SSAAggregate] = [], precise: Bool = false) -> Set<Int> {
    let g = buildPointsToGraph(f, aggregates: aggregates)
    return precise ? g.preciseEscaping() : g.faithfulEscaping()
}
