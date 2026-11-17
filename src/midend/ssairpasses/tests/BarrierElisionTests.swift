import support
import XCTest
import ssair
@testable import ssairpasses

// Barrier elision drops a barrier only into an object allocated earlier in the block with no safepoint between.
final class BarrierElisionTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private let c = Type.named("C", .class_), d = Type.named("D", .class_)

    // Two objects: the first stored into right after its allocation, the second after a call.
    private func module() -> SSAModule {
        let val = v(0, d)
        let a = v(1, c), fa = v(2, d)
        let b = v(3, c), fb = v(4, d)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: a, kind: .alloc(c), span: sp),
            SSAInst(result: fa, kind: .fieldAddr(base: a, fieldIndex: 0), span: sp),
            SSAInst(result: nil, kind: .writeBarrier(object: a, value: val), span: sp),
            SSAInst(result: nil, kind: .store(addr: fa, value: val), span: sp),
            SSAInst(result: b, kind: .alloc(c), span: sp),
            SSAInst(result: nil, kind: .call(SSACall(kind: .direct("g"), args: [])), span: sp),   // safepoint
            SSAInst(result: fb, kind: .fieldAddr(base: b, fieldIndex: 0), span: sp),
            SSAInst(result: nil, kind: .writeBarrier(object: b, value: val), span: sp),
            SSAInst(result: nil, kind: .store(addr: fb, value: val), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        return SSAModule(functions: [SSAFunction(name: "f", params: [val], returnType: .void, blocks: [bb],
                                                 isMutating: false, span: sp)])
    }

    private func barriered(_ m: SSAModule) -> [Int] {
        m.functions[0].blocks[0].insts.compactMap {
            if case .writeBarrier(let object, _) = $0.kind { return object.id }
            return nil
        }
    }

    func testDropsBarrierIntoFreshObjectOnly() {
        var m = module()
        BarrierElision().run(&m)
        XCTAssertEqual(barriered(m), [3])   // the store after the call keeps its barrier
        XCTAssertEqual(verifySSAIR(m), [])
    }
}
