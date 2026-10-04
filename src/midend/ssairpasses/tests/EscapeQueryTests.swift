import support
import XCTest
import ssair
@testable import ssairpasses

// Faithful escape query over the points-to graph (task 166.2). Each case asserts the graph-backed
// `graphEscaping` equals the legacy `escapingValues` exactly — the unit-level form of 166.3's suite-wide
// differential oracle. "Faithful" means identical by construction, so any divergence is a builder bug.
final class EscapeQueryTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private let objTy = Type.named("Obj", .class_)
    private let cloTy = Type.function(params: [.int], ret: .int)

    private func fn(params: [SSAValue] = [], ret: Type = .void, _ blocks: [SSABlock]) -> SSAFunction {
        SSAFunction(name: "f", params: params, returnType: ret, blocks: blocks, isMutating: false, span: sp)
    }

    // The oracle: the two providers must agree on every function.
    private func assertFaithful(_ f: SSAFunction, _ msg: String) {
        XCTAssertEqual(graphEscaping(f), escapingValues(f), msg)
    }

    // A local alloc that is never published does not escape (both report empty).
    func testLocalAllocDoesNotEscape() {
        let a = v(0, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn([bb])
        XCTAssertEqual(graphEscaping(f), [], "a dead local alloc does not escape")
        assertFaithful(f, "local alloc")
    }

    // A returned alloc escapes.
    func testReturnedAllocEscapes() {
        let a = v(0, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .ret(a), span: sp))
        assertFaithful(fn(ret: objTy, [bb]), "returned alloc")
    }

    // An interior pointer that escapes marks its base escaping (the fixpoint).
    func testInteriorPointerEscapeMarksBase() {
        let base = v(0, objTy), fieldPtr = v(1, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: base, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: base, fieldIndex: 0), span: sp),
        ], terminator: SSATerm(kind: .ret(fieldPtr), span: sp))   // the interior pointer escapes
        let f = fn(ret: objTy, [bb])
        XCTAssertTrue(graphEscaping(f).contains(base.id), "the base escapes through its interior pointer")
        assertFaithful(f, "interior pointer → base")
    }

    // Chained interior pointers propagate escape to the root (fixpoint iterates).
    func testChainedInteriorPropagates() {
        let base = v(0, objTy), p1 = v(1, objTy), p2 = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: base, kind: .alloc(objTy), span: sp),
            SSAInst(result: p1, kind: .fieldAddr(base: base, fieldIndex: 0), span: sp),
            SSAInst(result: p2, kind: .fieldAddr(base: p1, fieldIndex: 0), span: sp),
        ], terminator: SSATerm(kind: .ret(p2), span: sp))
        let f = fn(ret: objTy, [bb])
        XCTAssertTrue(graphEscaping(f).isSuperset(of: [base.id, p1.id, p2.id]), "escape reaches the root")
        assertFaithful(f, "chained interior")
    }

    // A value stored *into* a local object still escapes under the faithful rule (the value is a sink);
    // the container object does not. Faithful ⇒ both providers agree.
    func testStoredValueEscapesContainerDoesNot() {
        let box = v(0, objTy), fieldPtr = v(1, objTy), val = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: box, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: box, fieldIndex: 0), span: sp),
            SSAInst(result: val, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .store(addr: fieldPtr, value: val), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn([bb])
        let e = graphEscaping(f)
        XCTAssertTrue(e.contains(val.id), "the stored value escapes (faithful rule)")
        XCTAssertFalse(e.contains(box.id), "the container does not escape")
        assertFaithful(f, "store value into local")
    }

    // Call arguments escape; the result does not merely by being produced.
    func testCallArgsEscape() {
        let a = v(0, objTy), r = v(1, .int)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
            SSAInst(result: r, kind: .call(SSACall(kind: .direct("g"), args: [a])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        assertFaithful(fn([bb]), "call args")
    }

    // Aggregate / closure / box / actorSend / spawn publishing operands all escape identically.
    func testCompositePublishingSites() {
        let env = v(0, objTy), clo = v(1, cloTy), s = v(2, objTy), b = v(3, objTy)
        let recv = v(4, objTy), msg = v(5, objTy), senv = v(6, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: env, kind: .alloc(objTy), span: sp),
            SSAInst(result: clo, kind: .makeClosure(funcName: "clo:0", env: env, onStack: false), span: sp),
            SSAInst(result: s, kind: .alloc(objTy), span: sp),
            SSAInst(result: b, kind: .box(value: s, interfaces: ["I"], onStack: false), span: sp),
            SSAInst(result: recv, kind: .alloc(objTy), span: sp),
            SSAInst(result: msg, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .actorSend(receiver: recv, handler: "h", args: [msg]), span: sp),
            SSAInst(result: senv, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .spawn(binding: 0, startFn: "s:0", env: senv, resultType: .void), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        assertFaithful(fn([bb]), "composite publishing sites")
    }

    // A block argument across a CFG edge is conservatively escaping (faithful rule).
    func testEdgeArgEscapes() {
        let a = v(0, objTy), p = v(1, objTy)
        let b0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .br(target: 1, args: [a]), span: sp))
        let b1 = SSABlock(id: 1, params: [p], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn([b0, b1])
        XCTAssertTrue(graphEscaping(f).contains(a.id), "edge arg escapes conservatively")
        assertFaithful(f, "edge arg")
    }

    // MARK: - Precise query (166.4)

    private func precise(_ f: SSAFunction) -> Set<Int> { buildPointsToGraph(f).preciseEscaping() }
    // The precise set must never exceed the faithful set — so promotion only ever grows.
    private func assertSubset(_ f: SSAFunction, _ msg: String) {
        XCTAssertTrue(precise(f).isSubset(of: escapingValues(f)), "precise ⊆ faithful: \(msg)")
    }

    // The headline win: a value stored into a non-escaping local class object stays local. Faithful
    // escapes the stored value (a `.store` sink); precise keeps it local because its container does not
    // escape.
    func testStoreIntoNonEscapingLocalStaysLocal() {
        let a = v(0, objTy), fieldPtr = v(1, objTy), b = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: a, fieldIndex: 0), span: sp),
            SSAInst(result: b, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .store(addr: fieldPtr, value: b), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn([bb])
        XCTAssertTrue(escapingValues(f).contains(b.id), "faithful escapes the stored value")
        XCTAssertFalse(precise(f).contains(b.id), "precise keeps it local — its container does not escape")
        XCTAssertFalse(precise(f).contains(a.id), "the container itself stays local")
        assertSubset(f, "store into non-escaping local")
    }

    // When the container escapes, its stored contents escape too (containment propagates).
    func testStoreIntoEscapingLocalEscapes() {
        let a = v(0, objTy), fieldPtr = v(1, objTy), b = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: a, fieldIndex: 0), span: sp),
            SSAInst(result: b, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .store(addr: fieldPtr, value: b), span: sp),
        ], terminator: SSATerm(kind: .ret(a), span: sp))   // the container escapes
        let f = fn(ret: objTy, [bb])
        let e = precise(f)
        XCTAssertTrue(e.contains(a.id) && e.contains(b.id), "an escaping container leaks its contents")
        assertSubset(f, "store into escaping local")
    }

    // A box payload stays escaping even when the box does not escape — a stack-promoted payload hits the
    // addrspace wall, so this containment is deliberately not relaxed.
    func testBoxPayloadStaysEscaping() {
        let s = v(0, objTy), b = v(1, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: s, kind: .alloc(objTy), span: sp),
            SSAInst(result: b, kind: .box(value: s, interfaces: ["I"], onStack: false), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))   // the box does not escape
        let f = fn([bb])
        XCTAssertTrue(precise(f).contains(s.id), "the box payload stays escaping (addrspace boundary)")
        assertSubset(f, "box payload")
    }

    // A store into a *parameter* object is not relaxed (the parameter is held by the caller), so the
    // stored value escapes under precise too.
    func testStoreIntoParamEscapes() {
        let p = v(0, objTy), fieldPtr = v(1, objTy), b = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: p, fieldIndex: 0), span: sp),
            SSAInst(result: b, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .store(addr: fieldPtr, value: b), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn(params: [p], [bb])
        XCTAssertTrue(precise(f).contains(b.id), "a value stored into a parameter escapes")
        assertSubset(f, "store into param")
    }

    // A block argument flowing into a non-escaping parameter stays local under precise (faithful escapes
    // it unconditionally).
    func testEdgeArgRelaxedByFlow() {
        let a = v(0, objTy), p = v(1, objTy)
        let b0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .br(target: 1, args: [a]), span: sp))
        let b1 = SSABlock(id: 1, params: [p], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        let f = fn([b0, b1])
        XCTAssertTrue(escapingValues(f).contains(a.id), "faithful escapes the edge arg")
        XCTAssertFalse(precise(f).contains(a.id), "precise keeps it local — the target param does not escape")
        assertSubset(f, "edge arg relaxed")
    }
}
