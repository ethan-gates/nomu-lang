import support
import ast
import XCTest
import ssair
@testable import ssairpasses

// Scalar promotion for the loop-carried φ-web (ssair.md). A non-escaping class that is reassigned
// to a fresh allocation each iteration flows through a loop block parameter (an object φ); the pass
// decomposes it into per-field SSA values — the object `alloc` disappears and the φ widens into one φ
// per field. An escaping loop-carried object stays heap (the whole web is atomic). Shapes below mirror
// the IR ssairgen emits (see /tmp/phi-spike dumps).
final class ScalarPromotionTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private let pointTy = Type.named("Point", .class_)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    private func mod(_ blocks: [SSABlock], ret: Type = .int) -> SSAModule {
        SSAModule(functions: [SSAFunction(name: "f", params: [], returnType: ret,
                                          blocks: blocks, isMutating: false, span: sp)])
    }
    private func i(_ r: SSAValue?, _ k: SSAInstKind) -> SSAInst { SSAInst(result: r, kind: k, span: sp) }
    private func term(_ k: SSATermKind) -> SSATerm { SSATerm(kind: k, span: sp) }

    // How many `alloc` of a class remain in the module.
    private func allocCount(_ m: SSAModule) -> Int {
        var n = 0
        for f in m.functions { for b in f.blocks { for inst in b.insts {
            if case .alloc = inst.kind { n += 1 }
        } } }
        return n
    }
    private func params(_ m: SSAModule, block: Int) -> [SSAValue] {
        m.functions[0].blocks.first { $0.id == block }?.params ?? []
    }

    // Construct `Point(x, y)` into a fresh alloc `%alloc`: two barriered field stores. `fa0`/`fa1` are
    // the fieldAddr result ids.
    private func construct(_ alloc: SSAValue, _ fa0: Int, _ x: SSAValue, _ fa1: Int, _ y: SSAValue) -> [SSAInst] {
        [i(alloc, .alloc(pointTy)),
         i(v(fa0, .int), .fieldAddr(base: alloc, fieldIndex: 0)),
         i(nil, .writeBarrier(object: alloc, value: x)),
         i(nil, .store(addr: v(fa0, .int), value: x)),
         i(v(fa1, .int), .fieldAddr(base: alloc, fieldIndex: 1)),
         i(nil, .writeBarrier(object: alloc, value: y)),
         i(nil, .store(addr: v(fa1, .int), value: y))]
    }

    // A loop-carried `Point` reassigned to `Point(p.x + 1, p.y)` each iteration; only `p.x` read after
    // the loop. Optionally publish the φ as a call argument (escapes). Returns the module.
    private func carriedModule(escape: Bool) -> SSAModule {
        var bb2insts: [SSAInst] = [
            i(v(11, .int), .fieldAddr(base: v(10, pointTy), fieldIndex: 0)),
            i(v(12, .int), .load(v(11, .int))),
            i(v(13, .int), .constInt(1)),
            i(v(14, .int), .binary(.add, v(12, .int), v(13, .int))),
            i(v(15, .int), .fieldAddr(base: v(9, pointTy), fieldIndex: 0)),
            i(nil, .writeBarrier(object: v(9, pointTy), value: v(14, .int))),
            i(nil, .store(addr: v(15, .int), value: v(14, .int))),
            i(v(16, .int), .fieldAddr(base: v(10, pointTy), fieldIndex: 1)),
            i(v(17, .int), .load(v(16, .int))),
            i(v(18, .int), .fieldAddr(base: v(9, pointTy), fieldIndex: 1)),
            i(nil, .writeBarrier(object: v(9, pointTy), value: v(17, .int))),
            i(nil, .store(addr: v(18, .int), value: v(17, .int))),
        ]
        // The fresh Point alloc heads bb2 (so it dominates its field stores).
        bb2insts.insert(i(v(9, pointTy), .alloc(pointTy)), at: 0)
        if escape {
            bb2insts.append(i(v(30, .int), .call(SSACall(kind: .direct("sink"), args: [v(10, pointTy)]))))
        }
        bb2insts.append(i(v(19, .int), .constInt(1)))
        bb2insts.append(i(v(20, .int), .binary(.add, v(6, .int), v(19, .int))))

        let bb0 = SSABlock(id: 0, params: [],
            insts: construct(v(0, pointTy), 2, v(1, .int), 4, v(3, .int))
                + [i(v(1, .int), .constInt(0)), i(v(3, .int), .constInt(0)), i(v(5, .int), .constInt(0))],
            terminator: term(.br(target: 1, args: [v(5, .int), v(0, pointTy)])))
        let bb1 = SSABlock(id: 1, params: [v(6, .int), v(10, pointTy)],
            insts: [i(v(7, .int), .constInt(3)), i(v(8, .bool), .binary(.lt, v(6, .int), v(7, .int)))],
            terminator: term(.condBr(cond: v(8, .bool), then: 2, thenArgs: [], else: 3, elseArgs: [])))
        let bb2 = SSABlock(id: 2, params: [], insts: bb2insts,
            terminator: term(.br(target: 1, args: [v(20, .int), v(9, pointTy)])))
        let bb3 = SSABlock(id: 3, params: [],
            insts: [i(v(21, .int), .fieldAddr(base: v(10, pointTy), fieldIndex: 0)),
                    i(v(22, .int), .load(v(21, .int)))],
            terminator: term(.ret(v(22, .int))))
        return mod([bb0, bb1, bb2, bb3])
    }

    // A non-escaping loop-carried Point scalarizes: the alloc disappears and the object φ widens into a
    // field φ per field (2 fields → the header's 1 object param becomes 2 int params, alongside the loop
    // counter → 3 params).
    func testLoopCarriedClassScalarizes() {
        var m = carriedModule(escape: false)
        XCTAssertEqual(allocCount(m), 2, "before: two heap Point allocs")
        ScalarPromotion().run(&m)
        XCTAssertEqual(allocCount(m), 0, "the loop-carried Point is scalarized away")
        XCTAssertEqual(params(m, block: 1).count, 3, "the object φ widened into per-field φs (i, x, y)")
        XCTAssertTrue(params(m, block: 1).allSatisfy { $0.type == .int }, "the widened params are the scalar fields")
        XCTAssertEqual(verifySSAIR(m), [], "the scalarized module verifies clean")
    }

    // The φ published as a call argument escapes → the whole web stays heap (atomic).
    func testEscapingLoopCarriedStaysHeap() {
        var m = carriedModule(escape: true)
        ScalarPromotion().run(&m)
        XCTAssertEqual(allocCount(m), 2, "an escaping loop-carried object is not scalarized")
        XCTAssertEqual(params(m, block: 1).count, 2, "the object φ is left intact")
        XCTAssertEqual(verifySSAIR(m), [], "unchanged module verifies clean")
    }

    // Two distinct allocations, both carried and swapped each iteration, neither escaping: the web
    // unifies {a, b} and promotes all-or-nothing → both allocs scalarize.
    func testSwapWebScalarizesAllOrNothing() {
        // bb0: build a=Point(1,0), b=Point(2,0); br bb1(0, a, b)
        let bb0 = SSABlock(id: 0, params: [],
            insts: construct(v(0, pointTy), 2, v(1, .int), 4, v(3, .int))
                + [i(v(1, .int), .constInt(1)), i(v(3, .int), .constInt(0))]
                + construct(v(5, pointTy), 7, v(6, .int), 9, v(8, .int))
                + [i(v(6, .int), .constInt(2)), i(v(8, .int), .constInt(0)), i(v(10, .int), .constInt(0))],
            terminator: term(.br(target: 1, args: [v(10, .int), v(0, pointTy), v(5, pointTy)])))
        // bb1(i, a, b): if i < 3 → bb2 else bb3
        let bb1 = SSABlock(id: 1, params: [v(11, .int), v(14, pointTy), v(15, pointTy)],
            insts: [i(v(12, .int), .constInt(3)), i(v(13, .bool), .binary(.lt, v(11, .int), v(12, .int)))],
            terminator: term(.condBr(cond: v(13, .bool), then: 2, thenArgs: [], else: 3, elseArgs: [])))
        // bb2: i+1; swap → br bb1(i+1, b, a)
        let bb2 = SSABlock(id: 2, params: [],
            insts: [i(v(16, .int), .constInt(1)), i(v(17, .int), .binary(.add, v(11, .int), v(16, .int)))],
            terminator: term(.br(target: 1, args: [v(17, .int), v(15, pointTy), v(14, pointTy)])))
        // bb3: ret a.x
        let bb3 = SSABlock(id: 3, params: [],
            insts: [i(v(18, .int), .fieldAddr(base: v(14, pointTy), fieldIndex: 0)),
                    i(v(19, .int), .load(v(18, .int)))],
            terminator: term(.ret(v(19, .int))))
        var m = mod([bb0, bb1, bb2, bb3])
        XCTAssertEqual(allocCount(m), 2)
        ScalarPromotion().run(&m)
        XCTAssertEqual(allocCount(m), 0, "both swapped objects scalarize (one web, all-or-nothing)")
        XCTAssertEqual(params(m, block: 1).count, 5, "i + a{x,y} + b{x,y}")
        XCTAssertEqual(verifySSAIR(m), [], "the scalarized swap module verifies clean")
    }
}
