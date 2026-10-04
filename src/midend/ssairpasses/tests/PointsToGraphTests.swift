import support
import XCTest
import ssair
@testable import ssairpasses

// Points-to / reachability graph builder (task 166.1). These assert the graph's *structure* — objects,
// parameter phantoms, field edges keyed by source name, interior pointers, value-flow, and the sink tags
// that mirror `EscapeAnalysis` operand by operand. The escape query over this graph is task 166.2.
final class PointsToGraphTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private let objTy = Type.named("Obj", .class_)

    private func fn(params: [SSAValue] = [], ret: Type = .void, _ blocks: [SSABlock]) -> SSAFunction {
        SSAFunction(name: "f", params: params, returnType: ret, blocks: blocks, isMutating: false, span: sp)
    }

    // Allocation sites become objects; a returned alloc is a return root and carries a `.ret` sink.
    func testObjectsAndReturnRoot() {
        let a = v(0, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .ret(a), span: sp))
        let g = buildPointsToGraph(fn(ret: objTy, [bb]))
        XCTAssertTrue(g.objects.contains(a.id), "an alloc result names an object")
        XCTAssertEqual(g.returnValues, [a.id], "the returned value is a return root")
        XCTAssertEqual(g.sinks[a.id], [.ret], "the returned value carries a .ret sink")
    }

    // Each parameter gets a phantom object, addressable by index.
    func testParamPhantoms() {
        let p0 = v(0, objTy), p1 = v(1, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        let g = buildPointsToGraph(fn(params: [p0, p1], [bb]))
        XCTAssertEqual(g.paramObjects, [p0.id, p1.id], "params are phantom objects in order")
        XCTAssertTrue(g.objects.isSuperset(of: [p0.id, p1.id]))
    }

    // A store through a `fieldAddr` interior pointer becomes a field edge keyed by the field's source
    // name; the interior pointer records its base for the escape fixpoint.
    func testFieldStoreKeyedBySourceName() {
        let agg = SSAAggregate(name: "Obj", kind: .class_, fields: [
            SSAField(name: "x", type: .int, isMutable: true),
            SSAField(name: "next", type: objTy, isMutable: true),
        ], span: sp)
        let base = v(0, objTy), fieldPtr = v(1, objTy), stored = v(2, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: base, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: base, fieldIndex: 1), span: sp),
            SSAInst(result: stored, kind: .alloc(objTy), span: sp),
            SSAInst(result: nil, kind: .store(addr: fieldPtr, value: stored), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let g = buildPointsToGraph(fn([bb]), aggregates: [agg])
        XCTAssertEqual(g.interior[fieldPtr.id], PTGFieldRef(base: base.id, field: .field("next")))
        XCTAssertEqual(g.fieldStores[PTGFieldRef(base: base.id, field: .field("next"))], [stored.id])
        XCTAssertEqual(g.sinks[stored.id], [.store], "the stored value is a .store sink")
    }

    // An absent layout collapses a field to `.opaque` (the sound conservative merge), and an
    // `elementAddr` collapses to `.element`.
    func testUnknownLayoutAndElementCollapse() {
        let base = v(0, objTy), fieldPtr = v(1, objTy), idx = v(2, .int), elemPtr = v(3, objTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: base, kind: .alloc(objTy), span: sp),
            SSAInst(result: fieldPtr, kind: .fieldAddr(base: base, fieldIndex: 0), span: sp),
            SSAInst(result: idx, kind: .constInt(0), span: sp),
            SSAInst(result: elemPtr, kind: .elementAddr(base: base, index: idx), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let g = buildPointsToGraph(fn([bb]))   // no aggregates supplied
        XCTAssertEqual(g.interior[fieldPtr.id]?.field, .opaque)
        XCTAssertEqual(g.interior[elemPtr.id]?.field, .element)
    }

    // A block argument flows into the target block's matching parameter and is tagged `.edgeArg`.
    func testEdgeArgFlowsIntoParam() {
        let a = v(0, objTy), p = v(1, objTy)
        let b0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
        ], terminator: SSATerm(kind: .br(target: 1, args: [a]), span: sp))
        let b1 = SSABlock(id: 1, params: [p], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        let g = buildPointsToGraph(fn([b0, b1]))
        XCTAssertEqual(g.flow[p.id], [a.id], "the edge arg flows into the target param")
        XCTAssertEqual(g.sinks[a.id], [.edgeArg], "the edge arg is conservatively tagged")
    }

    // A call tags each argument with the callee it feeds and the parameter index.
    func testCallArgSinks() {
        let a = v(0, objTy), r = v(1, .int)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(objTy), span: sp),
            SSAInst(result: r, kind: .call(SSACall(kind: .direct("g"), args: [a])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let g = buildPointsToGraph(fn(ret: .int, [bb]))
        XCTAssertEqual(g.sinks[a.id], [.callArg(callee: .direct("g"), paramIndex: 0)])
    }
}
