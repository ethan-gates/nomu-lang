import support
import XCTest
import ssair
@testable import ssairpasses

// Inlining (M7 · 7.5): a small single-block `ret` callee splices into the caller (params → args, the
// returned value replaces the call result); a multi-block callee is inlined by CFG surgery (blocks
// cloned, `ret` → branch into a continuation block whose parameter is the return φ). Self-recursion
// is not inlined.
final class InliningTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    // Callee `add(x, y) { return x + y }` — single block, ret, inlinable.
    private func addCallee() -> SSAFunction {
        let x = v(0, .int), y = v(1, .int), s = v(2, .int)
        return SSAFunction(name: "add", params: [x, y], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [SSAInst(result: s, kind: .binary(.add, x, y), span: sp)],
                     terminator: SSATerm(kind: .ret(s), span: sp))
        ], isMutating: false, span: sp)
    }

    private func directCallCount(_ f: SSAFunction) -> Int {
        var n = 0
        for b in f.blocks { for i in b.insts { if case .call(let c) = i.kind, case .direct = c.kind { n += 1 } } }
        return n
    }
    private func binaryCount(_ f: SSAFunction) -> Int {
        var n = 0
        for b in f.blocks { for i in b.insts { if case .binary = i.kind { n += 1 } } }
        return n
    }

    // A call to a single-block callee is replaced by the callee's body; no call remains, the body's
    // `binary` op is now in the caller, and the module verifies clean.
    func testSingleBlockCalleeInlines() {
        let a = v(10, .int), b = v(11, .int), r = v(12, .int), use = v(13, .int)
        let caller = SSAFunction(name: "f", params: [a, b], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: r, kind: .call(SSACall(kind: .direct("add"), args: [a, b])), span: sp),
                SSAInst(result: use, kind: .binary(.add, r, r), span: sp),
            ], terminator: SSATerm(kind: .ret(use), span: sp))
        ], isMutating: false, span: sp)
        var m = SSAModule(functions: [caller, addCallee()])
        Inline().run(&m)
        let f = m.functions[0]
        XCTAssertEqual(directCallCount(f), 0, "the add() call should be inlined away")
        XCTAssertEqual(binaryCount(f), 2, "the callee's `+` joins the caller's `+`")
        XCTAssertEqual(verifySSAIR(m), [], "inlined module verifies clean")
    }

    private func blockCount(_ f: SSAFunction) -> Int { f.blocks.count }

    // A multi-block callee is inlined by CFG surgery: the call is replaced by the callee's cloned
    // blocks, the caller block is split, and the module stays well-formed (verify checks edge arity).
    func testMultiBlockCalleeInlines() {
        let x = v(0, .int)
        let callee = SSAFunction(name: "two", params: [x], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .br(target: 1, args: []), span: sp)),
            SSABlock(id: 1, params: [], insts: [], terminator: SSATerm(kind: .ret(x), span: sp)),
        ], isMutating: false, span: sp)
        let a = v(10, .int), r = v(11, .int), use = v(12, .int)
        let caller = SSAFunction(name: "f", params: [a], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: r, kind: .call(SSACall(kind: .direct("two"), args: [a])), span: sp),
                SSAInst(result: use, kind: .binary(.add, r, r), span: sp),   // uses the call result
            ], terminator: SSATerm(kind: .ret(use), span: sp))
        ], isMutating: false, span: sp)
        var m = SSAModule(functions: [caller, callee])
        Inline().run(&m)
        let f = m.functions[0]
        XCTAssertEqual(directCallCount(f), 0, "the multi-block callee call should be inlined away")
        XCTAssertGreaterThan(blockCount(f), 1, "CFG surgery splits the caller and splices callee blocks")
        XCTAssertEqual(verifySSAIR(m), [], "inlined module verifies clean (edge arity, defined uses)")
    }

    // A callee with two return points: the return values join through the continuation block's
    // parameter (the return φ). The result must verify clean — every edge into the continuation
    // supplies exactly one argument, matching its one parameter.
    func testMultiBlockReturnPhiJoins() {
        let x = v(0, .int), zero = v(1, .int), lt = v(2, .int), neg = v(3, .int), pos = v(4, .int)
        // sign(x): if x < 0 { return -1 } else { return 1 }
        let callee = SSAFunction(name: "sign", params: [x], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: zero, kind: .constInt(0), span: sp),
                SSAInst(result: lt, kind: .binary(.lt, x, zero), span: sp),
            ], terminator: SSATerm(kind: .condBr(cond: lt, then: 1, thenArgs: [], else: 2, elseArgs: []), span: sp)),
            SSABlock(id: 1, params: [], insts: [SSAInst(result: neg, kind: .constInt(-1), span: sp)],
                     terminator: SSATerm(kind: .ret(neg), span: sp)),
            SSABlock(id: 2, params: [], insts: [SSAInst(result: pos, kind: .constInt(1), span: sp)],
                     terminator: SSATerm(kind: .ret(pos), span: sp)),
        ], isMutating: false, span: sp)
        let a = v(10, .int), r = v(11, .int)
        let caller = SSAFunction(name: "f", params: [a], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: r, kind: .call(SSACall(kind: .direct("sign"), args: [a])), span: sp),
            ], terminator: SSATerm(kind: .ret(r), span: sp))
        ], isMutating: false, span: sp)
        var m = SSAModule(functions: [caller, callee])
        Inline().run(&m)
        XCTAssertEqual(directCallCount(m.functions[0]), 0, "sign() should be inlined")
        XCTAssertEqual(verifySSAIR(m), [], "the two returns join cleanly through the continuation φ")
    }

    // A direct self-call is not inlined (would be unbounded).
    func testSelfCallNotInlined() {
        let x = v(0, .int), r = v(1, .int)
        let f = SSAFunction(name: "rec", params: [x], returnType: .int, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: r, kind: .call(SSACall(kind: .direct("rec"), args: [x])), span: sp),
            ], terminator: SSATerm(kind: .ret(r), span: sp))
        ], isMutating: false, span: sp)
        var m = SSAModule(functions: [f])
        Inline().run(&m)
        XCTAssertEqual(directCallCount(m.functions[0]), 1, "a self-call must not inline")
    }
}
