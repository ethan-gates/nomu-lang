import ast
import support
import XCTest
import ssair

final class SSAIRDumpTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    // A hand-built `max(a, b)` exercising: a binary op, a `condBr`, `br` with a block argument,
    // a block parameter (the SSA join), and `ret` — plus a struct layout. Serves as a golden for
    // the dump and a smoke test for the value/instruction/block/terminator types.
    private func maxModule() -> SSAModule {
        let a = v(0, .int), b = v(1, .int)
        let cmp = v(2, .bool)
        let join = v(3, .int)

        let bb0 = SSABlock(
            id: 0, params: [],
            insts: [SSAInst(result: cmp, kind: .binary(.gt, a, b), span: sp)],
            terminator: SSATerm(kind: .condBr(cond: cmp, then: 1, thenArgs: [], else: 2, elseArgs: []), span: sp))
        let bb1 = SSABlock(id: 1, params: [], insts: [],
                           terminator: SSATerm(kind: .br(target: 3, args: [a]), span: sp))
        let bb2 = SSABlock(id: 2, params: [], insts: [],
                           terminator: SSATerm(kind: .br(target: 3, args: [b]), span: sp))
        let bb3 = SSABlock(id: 3, params: [join], insts: [],
                           terminator: SSATerm(kind: .ret(join), span: sp))

        let fn = SSAFunction(name: "max", params: [a, b], returnType: .int,
                             blocks: [bb0, bb1, bb2, bb3], isMutating: false, span: sp)
        let point = SSAAggregate(name: "Point", kind: .struct_, fields: [
            SSAField(name: "x", type: .int, isMutable: false),
            SSAField(name: "y", type: .int, isMutable: false),
        ], span: sp)
        return SSAModule(functions: [fn], aggregates: [point])
    }

    func testDumpShape() {
        let out = dumpSSAIR(maxModule())
        let expect = [
            "struct Point { let x : Int, let y : Int }",
            "fun max(%0 : Int, %1 : Int) -> Int {",
            "bb0:",
            "  %2 = %0 > %1 : Bool",
            "  condBr %2, bb1, bb2",
            "  br bb3(%0)",
            "bb3(%3 : Int):",
            "  ret %3",
            "}",
        ]
        for line in expect {
            XCTAssertTrue(out.contains(line), "missing `\(line)` in:\n\(out)")
        }
    }

    // Void ops print without a `%id =` prefix; the memory/GC vocabulary renders as expected.
    func testVoidAndMemoryOps() {
        let obj = v(0, .named("Counter", .class_))
        let idx = v(1, .int), len = v(2, .int)
        let field = v(3, .int)
        let bb0 = SSABlock(
            id: 0, params: [obj, idx, len],
            insts: [
                SSAInst(result: nil, kind: .boundscheck(index: idx, length: len), span: sp),
                SSAInst(result: field, kind: .fieldAddr(base: obj, fieldIndex: 0), span: sp),
                SSAInst(result: nil, kind: .writeBarrier(object: obj, value: idx), span: sp),
                SSAInst(result: nil, kind: .store(addr: field, value: idx), span: sp),
            ],
            terminator: SSATerm(kind: .unreachable, span: sp))
        let fn = SSAFunction(name: "f", params: [obj, idx, len], returnType: .void,
                             blocks: [bb0], isMutating: false, span: sp)
        let out = dumpSSAIR(SSAModule(functions: [fn]))
        XCTAssertTrue(out.contains("  boundscheck %1, %2"), out)
        XCTAssertTrue(out.contains("  %3 = fieldAddr %0, #0 : Int"), out)
        XCTAssertTrue(out.contains("  writeBarrier %0, %1"), out)
        XCTAssertTrue(out.contains("  store %3, %1"), out)
        XCTAssertTrue(out.contains("  unreachable"), out)
    }
}
