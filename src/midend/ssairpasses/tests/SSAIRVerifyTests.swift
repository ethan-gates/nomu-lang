import support
import XCTest
import ssair
@testable import ssairpasses

// The verifier must *catch* violations — "running without a crash is not a pass" (§7.0.5). Each case
// builds a module that breaks one invariant and asserts the verifier reports it, plus a well-formed
// module that passes clean.
final class SSAIRVerifyTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    private func fn(_ name: String, ret: Type, params: [SSAValue], _ blocks: [SSABlock]) -> SSAModule {
        SSAModule(functions: [SSAFunction(name: name, params: params, returnType: ret,
                                          blocks: blocks, isMutating: false, span: sp)])
    }

    func testWellFormedPassesClean() {
        let r = v(0, .int)
        let bb = SSABlock(id: 0, params: [],
                          insts: [SSAInst(result: r, kind: .constInt(1), span: sp)],
                          terminator: SSATerm(kind: .ret(r), span: sp))
        XCTAssertEqual(verifySSAIR(fn("f", ret: .int, params: [], [bb])), [])
    }

    // I3 — a use of a value that is never defined.
    func testUndefinedUseCaught() {
        let bb = SSABlock(id: 0, params: [], insts: [],
                          terminator: SSATerm(kind: .ret(v(99, .int)), span: sp))
        let errs = verifySSAIR(fn("f", ret: .int, params: [], [bb]))
        XCTAssertTrue(errs.contains { $0.contains("I3") && $0.contains("%99") }, "\(errs)")
    }

    // I3 — an edge passes the wrong number of block arguments.
    func testEdgeArityMismatchCaught() {
        let p = v(1, .int)
        let bb0 = SSABlock(id: 0, params: [], insts: [],
                           terminator: SSATerm(kind: .br(target: 1, args: []), span: sp))   // passes 0
        let bb1 = SSABlock(id: 1, params: [p], insts: [],                                    // wants 1
                           terminator: SSATerm(kind: .ret(nil), span: sp))
        let errs = verifySSAIR(fn("f", ret: .void, params: [], [bb0, bb1]))
        XCTAssertTrue(errs.contains { $0.contains("I3") && $0.contains("args") }, "\(errs)")
    }

    // I2 — a heap allocation of a non-managed (value) type.
    func testNonManagedAllocCaught() {
        let r = v(0, .int)
        let bb = SSABlock(id: 0, params: [],
                          insts: [SSAInst(result: r, kind: .alloc(.int), span: sp)],
                          terminator: SSATerm(kind: .ret(nil), span: sp))
        let errs = verifySSAIR(fn("f", ret: .void, params: [], [bb]))
        XCTAssertTrue(errs.contains { $0.contains("I2") }, "\(errs)")
    }

    // I4 — a reference-type `stackAlloc` (a promotion) whose value escapes (here: returned).
    func testEscapingStackPromotionCaught() {
        let obj = v(0, .named("C", .class_))
        let bb = SSABlock(id: 0, params: [],
                          insts: [SSAInst(result: obj, kind: .stackAlloc(.named("C", .class_)), span: sp)],
                          terminator: SSATerm(kind: .ret(obj), span: sp))   // returned → escapes
        let errs = verifySSAIR(fn("f", ret: .named("C", .class_), params: [], [bb]))
        XCTAssertTrue(errs.contains { $0.contains("I4") && $0.contains("%0") }, "\(errs)")
    }

    // I7 — a managed store into a heap object's field with no write barrier.
    func testMissingBarrierCaught() {
        let obj = v(0, .named("C", .class_))     // heap object (alloc)
        let fld = v(1, .named("D", .class_))     // &obj.f
        let val = v(2, .named("D", .class_))     // a managed value
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: obj, kind: .alloc(.named("C", .class_)), span: sp),
            SSAInst(result: fld, kind: .fieldAddr(base: obj, fieldIndex: 0), span: sp),
            SSAInst(result: val, kind: .alloc(.named("D", .class_)), span: sp),
            SSAInst(result: nil, kind: .store(addr: fld, value: val), span: sp),   // no writeBarrier
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        let errs = verifySSAIR(fn("f", ret: .void, params: [], [bb]))
        XCTAssertTrue(errs.contains { $0.contains("I7") }, "\(errs)")
    }

    // I7 — the same store *with* a preceding barrier passes clean (no false positive).
    func testBarrieredStorePassesClean() {
        let obj = v(0, .named("C", .class_))
        let fld = v(1, .named("D", .class_))
        let val = v(2, .named("D", .class_))
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: obj, kind: .alloc(.named("C", .class_)), span: sp),
            SSAInst(result: fld, kind: .fieldAddr(base: obj, fieldIndex: 0), span: sp),
            SSAInst(result: val, kind: .alloc(.named("D", .class_)), span: sp),
            SSAInst(result: nil, kind: .writeBarrier(object: obj, value: val), span: sp),
            SSAInst(result: nil, kind: .store(addr: fld, value: val), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        XCTAssertFalse(verifySSAIR(fn("f", ret: .void, params: [], [bb])).contains { $0.contains("I7") })
    }

    // I1 — a value id used at a type different from its definition.
    func testConflictingTypeCaught() {
        let def = v(0, .int)
        let bb = SSABlock(id: 0, params: [],
                          insts: [SSAInst(result: def, kind: .constInt(1), span: sp)],
                          terminator: SSATerm(kind: .ret(v(0, .bool)), span: sp))   // same id, wrong type
        let errs = verifySSAIR(fn("f", ret: .bool, params: [], [bb]))
        XCTAssertTrue(errs.contains { $0.contains("I1") && $0.contains("%0") }, "\(errs)")
    }
}
