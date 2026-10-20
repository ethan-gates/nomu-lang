import support
import XCTest
import ssair

// Which frame slots the collector is told about (task 176.5): a slot with conditional content always; a slot
// with only plain managed words only once its address escapes (SROA promotes it otherwise).
final class RecordedSlotsTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private let structs: [String: [Type]] = [
        "String": [.stringBase],
        "Pair": [.named("String", .struct_), .int],
        "Bag": [.array(.int), .int],
        "Plain": [.int, .int],
    ]
    private func env() -> ShapeEnv { let s = structs; return ShapeEnv(structFields: { s[$0] }, enumCases: { _ in nil }) }
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private func fn(_ insts: [SSAInst]) -> SSAFunction {
        SSAFunction(name: "t", params: [], returnType: .void,
                    blocks: [SSABlock(id: 0, params: [], insts: insts, terminator: SSATerm(kind: .ret(nil), span: sp))],
                    isMutating: false, span: sp)
    }
    private func slot(_ id: Int, _ n: String) -> SSAInst {
        SSAInst(result: v(id, .named(n, .struct_)), kind: .stackAlloc(.named(n, .struct_)), span: sp)
    }
    private func call(_ args: [SSAValue]) -> SSAInst {
        SSAInst(result: nil, kind: .call(SSACall(kind: .direct("f"), args: args)), span: sp)
    }
    private func load(_ id: Int, _ addr: SSAValue) -> SSAInst {
        SSAInst(result: v(id, addr.type), kind: .load(addr), span: sp)
    }

    func testConditionalSlotAlwaysRecorded() {
        let s = v(0, .named("Pair", .struct_))
        let r = recordedSlots(fn([slot(0, "Pair"), load(1, s)]), env())
        XCTAssertNotNil(r.types[0], "a slot holding a String is recorded whether or not it escapes")
    }

    func testPlainManagedSlotRecordedOnlyWhenEscaped() {
        let b = v(0, .named("Bag", .struct_))
        let kept = recordedSlots(fn([slot(0, "Bag"), load(1, b)]), env())
        XCTAssertNil(kept.types[0], "a non-escaping slot of plain pointers is left to SROA")
        let escaped = recordedSlots(fn([slot(0, "Bag"), call([b])]), env())
        XCTAssertNotNil(escaped.types[0], "passed to a call, the slot stays in memory and is recorded")
        let plain = recordedSlots(fn([slot(0, "Plain"), call([v(0, .named("Plain", .struct_))])]), env())
        XCTAssertNil(plain.types[0], "a slot with no managed word is never recorded")
    }

    func testDerivedAddressEscapesItsSlot() {
        let b = v(0, .named("Bag", .struct_))
        let fa = v(1, .array(.int))
        let r = recordedSlots(fn([slot(0, "Bag"),
                                  SSAInst(result: fa, kind: .fieldAddr(base: b, fieldIndex: 0), span: sp),
                                  call([fa])]), env())
        XCTAssertNotNil(r.types[0], "a field address passed to a call escapes its slot")
        XCTAssertEqual(r.root[1], 0, "the derived address records its slot")
    }

    func testConditionalWords() {
        let e = env()
        XCTAssertEqual(e.shape(.named("Pair", .struct_)).conditionalWords, [0], "the String's word0")
        XCTAssertEqual(e.shape(.named("Bag", .struct_)).conditionalWords, [], "a plain pointer needs no volatile load")
        let en: [String: [[Type]]] = ["OptArr": [[.array(.int)], []]]
        let s = structs
        let withEnum = ShapeEnv(structFields: { s[$0] }, enumCases: { en[$0] })
        XCTAssertEqual(withEnum.shape(.named("OptArr", .enum_)).conditionalWords, [8], "an enum payload's managed word")
    }
}
