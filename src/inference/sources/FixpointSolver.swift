// The interprocedural fixpoint engine (task 168) — the stage- and scope-agnostic solver every
// caller-relevant inferred fact (mutating-ness, shareable-requirement, interprocedural escape) runs
// through. Design home: `internals/inference.md` ("Scope-agnostic engine", "Summary and composition").
//
// It condenses a call graph into strongly-connected components (Tarjan), processes them callees-first,
// and evaluates an analysis-supplied transfer function at each node — once for an acyclic node, iterated
// to a fixpoint for a recursive SCC. It is generic over the lattice and owns no call resolution, no NOIR,
// and no SSA, so it lives below both altitudes that drive it.

// An abstract summary lattice. `bottom` is the optimistic start; `joined` is the least upper bound. A
// monotone transfer over a finite-height lattice terminates (the k-limit in task 169 is what bounds the
// escape lattice's height).
public protocol FactSummary: Equatable {
    static var bottom: Self { get }
    func joined(with other: Self) -> Self
}

// A disjunctive boolean fact (bottom = false, join = ||) — the lattice for mutating-ness and any other
// "this function reaches the property" bit.
public struct BoolFact: FactSummary {
    public let value: Bool
    public init(_ value: Bool) { self.value = value }
    public static var bottom: BoolFact { BoolFact(false) }
    public func joined(with other: BoolFact) -> BoolFact { BoolFact(value || other.value) }
}

// A call graph over opaque node identifiers. Nodes and edges keep insertion order so the solve is
// deterministic. A node is a function with a body in this scope; an edge may point at a node *not* in the
// graph (an external / unresolved callee), which the summary provider resolves rather than the SCC walk.
public struct CallGraph<Node: Hashable> {
    public private(set) var nodes: [Node] = []
    private var index: [Node: Int] = [:]
    private var edges: [Node: [Node]] = [:]
    private var edgeSet: [Node: Set<Node>] = [:]

    public init() {}

    public mutating func addNode(_ n: Node) {
        if index[n] == nil { index[n] = nodes.count; nodes.append(n) }
    }
    // Record a call `from → to`. `from` becomes a graph node; `to` stays whatever it is (a graph node is
    // traversed for SCCs, an external node is left to the summary provider).
    public mutating func addEdge(from: Node, to: Node) {
        addNode(from)
        if edgeSet[from, default: []].insert(to).inserted { edges[from, default: []].append(to) }
    }

    public func contains(_ n: Node) -> Bool { index[n] != nil }
    public func callees(of n: Node) -> [Node] { edges[n] ?? [] }
    func orderIndex(_ n: Node) -> Int { index[n] ?? Int.max }
}

public struct FixpointSolver<Node: Hashable, S: FactSummary> {
    private let graph: CallGraph<Node>
    private let external: (Node) -> S
    private let transfer: (Node, _ lookup: (Node) -> S) -> S

    // `external` resolves a callee outside the graph (an imported summary, or a conservative element the
    // provider chooses); it defaults to `bottom`. `transfer` computes a node's summary from the node and
    // a `lookup` that returns each callee's current summary.
    public init(graph: CallGraph<Node>,
                external: @escaping (Node) -> S = { _ in S.bottom },
                transfer: @escaping (Node, _ lookup: (Node) -> S) -> S) {
        self.graph = graph; self.external = external; self.transfer = transfer
    }

    public func solve() -> [Node: S] {
        var result: [Node: S] = [:]
        let lookup: (Node) -> S = { n in
            self.graph.contains(n) ? (result[n] ?? S.bottom) : self.external(n)
        }
        // SCCs come back callees-first (Tarjan's reverse-topological emission over caller→callee edges).
        for scc in stronglyConnectedComponents() {
            if scc.count == 1, !graph.callees(of: scc[0]).contains(scc[0]) {
                let n = scc[0]
                result[n] = transfer(n, lookup)   // acyclic node: one evaluation
            } else {
                for n in scc { result[n] = S.bottom }   // recursive SCC: iterate to a fixpoint
                var changed = true
                while changed {
                    changed = false
                    for n in scc {
                        let next = transfer(n, lookup)
                        if next != result[n] { result[n] = next; changed = true }
                    }
                }
            }
        }
        return result
    }

    // Tarjan's SCC algorithm, iterative (so a deep call chain cannot overflow the Swift stack), traversing
    // only in-graph callees in deterministic order. Components are returned in reverse-topological order —
    // a component is emitted when its root finishes, and a sink component (a leaf function) finishes
    // first — which is exactly callees-before-callers.
    func stronglyConnectedComponents() -> [[Node]] {
        var counter = 0
        var idx: [Node: Int] = [:]
        var low: [Node: Int] = [:]
        var onStack = Set<Node>()
        var stack: [Node] = []
        var sccs: [[Node]] = []

        func succ(_ v: Node) -> [Node] {
            graph.callees(of: v).filter { graph.contains($0) }
                 .sorted { graph.orderIndex($0) < graph.orderIndex($1) }
        }

        for root in graph.nodes where idx[root] == nil {
            idx[root] = counter; low[root] = counter; counter += 1
            stack.append(root); onStack.insert(root)
            var work: [(node: Node, next: Int, succ: [Node])] = [(root, 0, succ(root))]
            while let top = work.last {
                let v = top.node
                if top.next < top.succ.count {
                    let w = top.succ[top.next]
                    work[work.count - 1].next += 1
                    if idx[w] == nil {
                        idx[w] = counter; low[w] = counter; counter += 1
                        stack.append(w); onStack.insert(w)
                        work.append((w, 0, succ(w)))
                    } else if onStack.contains(w) {
                        low[v] = Swift.min(low[v]!, idx[w]!)
                    }
                } else {
                    if low[v]! == idx[v]! {   // v is an SCC root: pop its component
                        var scc: [Node] = []
                        while true {
                            let w = stack.removeLast(); onStack.remove(w); scc.append(w)
                            if w == v { break }
                        }
                        sccs.append(scc)
                    }
                    work.removeLast()
                    if let parent = work.last?.node { low[parent] = Swift.min(low[parent]!, low[v]!) }
                }
            }
        }
        return sccs
    }
}
