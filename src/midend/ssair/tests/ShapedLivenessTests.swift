import support
import XCTest
import ssair

// Shaped-value liveness (task 176 Stage 2): a `String` value that spans a call must be reported live
// after that call (it crosses the safepoint), while a `String` that never spans one must not be.
final class ShapedLivenessTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    private func fn(_ blocks: [SSABlock]) -> SSAFunction {
        SSAFunction(name: "t", params: [], returnType: .void, blocks: blocks, isMutating: false, span: sp)
    }

    private func call(_ name: String, _ args: [SSAValue]) -> SSACall {
        SSACall(kind: .direct(name), args: args)
    }

    // s0 = "hi"; call sideEffect(); s1 = concat(s0, s0); ret. s0 spans the sideEffect call.
    func testStringCrossesCall() {
        let s0 = v(0, .string), s1 = v(1, .string)
        let bb0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: s0, kind: .constString("hi"), span: sp),
            SSAInst(result: nil, kind: .call(call("sideEffect", [])), span: sp),           // inst 1: a safepoint
            SSAInst(result: s1, kind: .call(call("concat", [s0, s0])), span: sp),           // inst 2: uses s0
        ], terminator: SSATerm(kind: .ret(nil), span: sp))

        let live = computeShapedLiveness(fn([bb0]))
        XCTAssertTrue(live.liveOutInst[0]![1].contains(s0.id), "s0 must be live across the call it spans")
        XCTAssertFalse(live.liveOutInst[0]![2].contains(s0.id), "s0 is dead after its last use")
        XCTAssertFalse(live.liveOutInst[0]![2].contains(s1.id), "s1 is unused, dead immediately")
    }

    // s0 = "hi"; s1 = concat(s0, s0); ret — no safepoint spans s0 (both uses before any call completes).
    func testStringNeverCrossesSafepoint() {
        let s0 = v(0, .string), s1 = v(1, .string)
        let bb0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: s0, kind: .constString("hi"), span: sp),
            SSAInst(result: s1, kind: .call(call("concat", [s0, s0])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))

        let live = computeShapedLiveness(fn([bb0]))
        // After the concat (inst 1), nothing shaped is live.
        XCTAssertTrue(live.liveOutInst[0]![1].isEmpty)
    }

    // A loop-carried String (a block param reached by a back-edge) is live at the loop header, so it
    // crosses the loop-header poll: acc is the header's param, rebuilt and carried on the back-edge.
    func testLoopCarriedStringLiveAtHeader() {
        let acc = v(0, .string)       // header block param
        let acc2 = v(1, .string)      // rebuilt in the body
        let cond = v(2, .bool)
        // bb0: entry -> br header(initial "")
        let initStr = v(3, .string)
        let bb0 = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: initStr, kind: .constString(""), span: sp),
        ], terminator: SSATerm(kind: .br(target: 1, args: [initStr]), span: sp))
        // bb1 header(acc): cond = loop?; condBr -> body / exit
        let bb1 = SSABlock(id: 1, params: [acc], insts: [
            SSAInst(result: cond, kind: .call(call("more", [])), span: sp),
        ], terminator: SSATerm(kind: .condBr(cond: cond, then: 2, thenArgs: [], else: 3, elseArgs: []), span: sp))
        // bb2 body: acc2 = concat(acc, acc); br header(acc2)  (back-edge)
        let bb2 = SSABlock(id: 2, params: [], insts: [
            SSAInst(result: acc2, kind: .call(call("concat", [acc, acc])), span: sp),
        ], terminator: SSATerm(kind: .br(target: 1, args: [acc2]), span: sp))
        // bb3 exit: ret
        let bb3 = SSABlock(id: 3, params: [], insts: [],
                           terminator: SSATerm(kind: .ret(nil), span: sp))

        let live = computeShapedLiveness(fn([bb0, bb1, bb2, bb3]))
        // acc is live at the header entry (used by the body, carried around the back-edge) — it crosses
        // the header poll and the `more()` call in the header.
        XCTAssertTrue(live.liveInBlock[1]!.contains(acc.id), "loop-carried acc is live at the header")
        XCTAssertTrue(live.liveOutInst[1]![0].contains(acc.id), "acc spans the header-block call")
    }
}
