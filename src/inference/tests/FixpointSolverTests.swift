import XCTest
@testable import inference

// The interprocedural fixpoint engine (task 168). A toy "reaches a property" analysis over synthetic call
// graphs exercises the solver: a node has the property if it is marked directly or calls a node that has
// it (the mutating-ness shape). Covers acyclic chains, a diamond (join order irrelevant), self- and
// mutual recursion (SCC iteration), external callees, and SCC ordering/determinism.
final class FixpointSolverTests: XCTestCase {
    // Build a solver over `edges` where `direct` marks nodes with the property directly.
    private func solver(_ nodes: [String], _ edges: [(String, String)], direct: Set<String>,
                        external: @escaping (String) -> BoolFact = { _ in .bottom })
        -> FixpointSolver<String, BoolFact> {
        var g = CallGraph<String>()
        for n in nodes { g.addNode(n) }
        for (a, b) in edges { g.addEdge(from: a, to: b) }
        return FixpointSolver(graph: g, external: external) { n, lookup in
            if direct.contains(n) { return BoolFact(true) }
            return BoolFact(g.callees(of: n).contains { lookup($0).value })
        }
    }
    private func truthy(_ r: [String: BoolFact]) -> Set<String> {
        Set(r.filter { $0.value.value }.map { $0.key })
    }

    // A chain a→b→c with c marked: the property propagates up to every caller.
    func testChainPropagates() {
        let r = solver(["a", "b", "c"], [("a", "b"), ("b", "c")], direct: ["c"]).solve()
        XCTAssertEqual(truthy(r), ["a", "b", "c"])
    }

    // A diamond a→{b,c}→d with d marked: the property reaches a regardless of merge order.
    func testDiamondJoin() {
        let r = solver(["a", "b", "c", "d"], [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d")],
                       direct: ["d"]).solve()
        XCTAssertEqual(truthy(r), ["a", "b", "c", "d"])
    }

    // A node marked directly propagates; an unmarked leaf stays false.
    func testUnmarkedLeafStaysFalse() {
        let r = solver(["a", "b"], [("a", "b")], direct: []).solve()
        XCTAssertEqual(truthy(r), [])
    }

    // Self-recursion: a→a converges — false with no direct mark, true with one.
    func testSelfRecursion() {
        XCTAssertEqual(truthy(solver(["a"], [("a", "a")], direct: []).solve()), [])
        XCTAssertEqual(truthy(solver(["a"], [("a", "a")], direct: ["a"]).solve()), ["a"])
    }

    // Mutual recursion a↔b (a 2-node SCC): one direct mark makes both true via SCC iteration.
    func testMutualRecursion() {
        XCTAssertEqual(truthy(solver(["a", "b"], [("a", "b"), ("b", "a")], direct: []).solve()), [])
        XCTAssertEqual(truthy(solver(["a", "b"], [("a", "b"), ("b", "a")], direct: ["a"]).solve()),
                       ["a", "b"])
    }

    // An external callee (not a graph node) resolves through the summary provider, not the SCC walk.
    func testExternalCalleeViaProvider() {
        let r = solver(["a"], [("a", "ext")], direct: [],
                       external: { $0 == "ext" ? BoolFact(true) : .bottom }).solve()
        XCTAssertEqual(truthy(r), ["a"], "a reaches the property through its external callee")
    }

    // SCCs come back callees-first, and the partition is correct: {c,d} is one component, b and a single.
    func testSCCOrderingCalleesFirst() {
        var g = CallGraph<String>()
        for n in ["a", "b", "c", "d"] { g.addNode(n) }
        for (x, y) in [("a", "b"), ("b", "c"), ("c", "d"), ("d", "c")] { g.addEdge(from: x, to: y) }
        let sccs = FixpointSolver<String, BoolFact>(graph: g) { _, _ in .bottom }
            .stronglyConnectedComponents()
        XCTAssertEqual(sccs.map { Set($0) }, [["c", "d"], ["b"], ["a"]], "callees-first; {c,d} merged")
    }

    // The solve is insensitive to edge insertion order.
    func testInsertionOrderDeterminism() {
        let a = solver(["a", "b", "c"], [("a", "b"), ("a", "c"), ("b", "c")], direct: ["c"]).solve()
        let b = solver(["a", "b", "c"], [("b", "c"), ("a", "c"), ("a", "b")], direct: ["c"]).solve()
        XCTAssertEqual(truthy(a), truthy(b))
    }
}
