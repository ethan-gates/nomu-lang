import ssair
import support
import inference   // the shared SCC/fixpoint engine (168)
import facts       // the EscapeSummary schema + fact store (167)

// Interprocedural escape summary (task 169) — the second client of the fixpoint engine, after
// mutating-ness. It projects each function's points-to graph (166) into a per-function escape summary and
// composes those bottom-up over the call graph through the 168 engine, so a caller's escape analysis
// survives a call instead of assuming every argument escapes. Design: `internals/inference.md` ("Summary
// and composition"). This ships the Level-1 floor: the sole relaxation over the intraprocedural faithful
// escape is "an argument passed to a callee that does not escape it does not escape." The
// intoReturn/intoParam threading and the k≥2 field summary are the documented refinements.

// The engine lattice element: an `EscapeSummary` as a `FactSummary`. The wrapper keeps the conformance out
// of `facts` (which stays dependency-free). `bottom` is the optimistic start — an empty summary a
// not-yet-computed in-graph callee reads as all-`noEscape`; the transfer recomputes the real summary from
// the graph each iteration, widening toward escape only as evidence forces.
struct EscapeFact: FactSummary, Equatable {
    var summary: EscapeSummary
    init(_ s: EscapeSummary) { summary = s }
    static var bottom: EscapeFact { EscapeFact(EscapeSummary(params: [], ret: .fresh)) }
    func joined(with other: EscapeFact) -> EscapeFact {
        let n = max(summary.params.count, other.summary.params.count)
        var params: [ParamDisposition] = []
        for i in 0..<n {
            let a = i < summary.params.count ? summary.params[i] : .noEscape
            let b = i < other.summary.params.count ? other.summary.params[i] : .noEscape
            params.append(a == .escapes || b == .escapes ? .escapes : .noEscape)
        }
        let ret: ReturnProvenance = (summary.ret == .escaped || other.summary.ret == .escaped) ? .escaped : .fresh
        return EscapeFact(EscapeSummary(params: params, ret: ret))
    }
}

// Compute the escape summary of every function, composing bottom-up over the call graph via the engine.
// `aggregates` feeds the graph's field-name resolution. The result maps each function's name to its
// summary; a direct call to a function outside `functions` reads `external` — a dependency's published
// per-definition summaries, keyed by the call name this module uses (`util@foo` / `m:util@Type:method`),
// seeded from imported `.nmi`s (task 164.6). A callee in neither the in-module graph nor `external` (a
// builtin, an un-summarized import) stays conservative — the "all arguments escape" floor.
public func computeEscapeSummaries(_ functions: [SSAFunction],
                                   aggregates: [SSAAggregate] = [],
                                   external: [String: EscapeSummary] = [:]) -> [String: EscapeSummary] {
    let graphs = Dictionary(functions.map { ($0.name, buildPointsToGraph($0, aggregates: aggregates)) },
                            uniquingKeysWith: { a, _ in a })
    let fnByName = Dictionary(functions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    var callGraph = CallGraph<String>()
    for f in functions {
        callGraph.addNode(f.name)
        guard let g = graphs[f.name] else { continue }
        for (_, sinkSet) in g.sinks {
            for sink in sinkSet {
                if case .callArg(.direct(let callee), _) = sink { callGraph.addEdge(from: f.name, to: callee) }
            }
        }
    }

    let solution = FixpointSolver(graph: callGraph) { (name: String, lookup: (String) -> EscapeFact) in
        guard let f = fnByName[name], let g = graphs[name] else { return EscapeFact.bottom }
        return EscapeFact(summarize(f, g, callGraph: callGraph, external: external, lookup: lookup))
    }.solve()

    return solution.mapValues { $0.summary }
}

// Write computed summaries into the fact store's perf section (task 169.4), keyed by the function's
// mangled name — the per-definition record 164's emit serializes and a dependency's build reads back.
public func writeEscapeSummaries(_ summaries: [String: EscapeSummary], into store: inout FactStore) {
    for (name, s) in summaries { store.update(SymbolID(name)) { $0.perf.escape = s } }
}

// Re-key SSA-named escape summaries to the per-definition `.nmi` convention (task 164.4.3). A method's
// `m:Type:method` SSA name (ssairgen's `ModuleContext.methodSymbol`) becomes `Type.method`; a free
// function keeps its bare name. This is the per-definition (erased-body) form the `.nmi` perf section
// publishes and a dependent seeds its fixpoint from (164.6) — distinct from the per-instance post-mono
// SSA keys the promotion path consumes (164.2/164.5), which this computation over pre-mono SSA produces.
public func perDefinitionEscapeSummaries(_ ssaKeyed: [String: EscapeSummary]) -> [String: EscapeSummary] {
    var out: [String: EscapeSummary] = [:]
    for (name, s) in ssaKeyed {
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "m" { out["\(parts[1]).\(parts[2])"] = s }
        else { out[name] = s }
    }
    return out
}

// MARK: - The per-function projection (the engine's transfer function)

// Project one function's graph into its summary, resolving each call argument through the callee's current
// summary (`lookup`). This is the engine transfer: it reads callees' summaries, never its own node's prior
// value, so recomputing from the graph each iteration is correct.
func summarize(_ f: SSAFunction, _ g: PointsToGraph,
               callGraph: CallGraph<String>, external: [String: EscapeSummary] = [:],
               lookup: (String) -> EscapeFact) -> EscapeSummary {
    // Does a value escape f's frame? Faithful rules, except a direct-call argument escapes only when the
    // callee's summary says it escapes that parameter. `includeReturn` folds the returned value into the
    // escaping set for the parameter dispositions; the return-provenance query runs it again without.
    func escaping(includeReturn: Bool) -> Set<Int> {
        var esc = Set<Int>()
        for (v, sinkSet) in g.sinks {
            for sink in sinkSet {
                switch sink {
                case .globalStore, .spawnCapture, .actorSend,
                     .store, .box, .aggregate, .closureCapture, .edgeArg:
                    esc.insert(v)                                   // conservative / cross-fiber — terminal
                case .ret:
                    if includeReturn { esc.insert(v) }
                case .callArg(let callee, let j):
                    if argEscapes(callee, j, callGraph: callGraph, external: external, lookup: lookup) { esc.insert(v) }
                }
            }
        }
        // An interior pointer escaping marks the object it points into (as in the faithful query).
        var changed = true
        while changed {
            changed = false
            for (i, ref) in g.interior where esc.contains(i) && !esc.contains(ref.base) {
                esc.insert(ref.base); changed = true
            }
        }
        return esc
    }

    let escWithReturn = escaping(includeReturn: true)
    let params = f.params.map { escWithReturn.contains($0.id) ? ParamDisposition.escapes : .noEscape }

    // Return provenance: `fresh` only when every returned value is a freshly allocated object in this
    // function (not a parameter) that does not otherwise escape; conservative `escaped` otherwise.
    let paramIDs = Set(g.paramObjects)
    let escNoReturn = escaping(includeReturn: false)
    let ret: ReturnProvenance
    if !g.returnValues.isEmpty,
       g.returnValues.allSatisfy({ g.objects.contains($0) && !paramIDs.contains($0) && !escNoReturn.contains($0) }) {
        ret = .fresh
    } else {
        ret = .escaped
    }
    return EscapeSummary(params: params, ret: ret)
}

// Does an argument at parameter position `j` of `callee` escape? A direct call to an in-graph callee reads
// its current summary (a not-yet-computed callee reads as optimistic `noEscape`, widening as the fixpoint
// proceeds); an external direct callee and every witness / indirect call are conservative.
private func argEscapes(_ callee: PTGCallee, _ j: Int,
                        callGraph: CallGraph<String>, external: [String: EscapeSummary],
                        lookup: (String) -> EscapeFact) -> Bool {
    func disposition(_ s: EscapeSummary) -> Bool { j < s.params.count ? s.params[j] == .escapes : false }
    switch callee {
    case .direct(let name):
        if let s = external[name] { return disposition(s) }   // a dependency's published summary (164.6)
        guard callGraph.contains(name) else { return true }   // builtin / un-summarized import — conservative
        return disposition(lookup(name).summary)
    case .witness, .indirect:
        return true                                           // unknown dynamic target — conservative
    }
}
