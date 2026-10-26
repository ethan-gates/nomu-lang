import XCTest
@testable import config

final class ValueTests: XCTestCase {
    private func read(_ type: ValueType, _ raw: RawValue) -> Value? {
        try? type.read(raw).get()
    }

    private func problem(_ type: ValueType, _ raw: RawValue) -> ValueProblem? {
        if case .failure(let p) = type.read(raw) { return p }
        return nil
    }

    func testBool() {
        XCTAssertEqual(read(.bool, .boolean(true)), .bool(true))
        XCTAssertEqual(read(.bool, .boolean(false)), .bool(false))
        XCTAssertNil(read(.bool, .string("true")))
    }

    func testInt() {
        XCTAssertEqual(read(.int(nil), .integer(-5)), .int(-5))
        XCTAssertNil(read(.int(nil), .float(5.0)))
        XCTAssertNil(read(.int(nil), .string("5")))
        XCTAssertNil(read(.int(0...10), .integer(11)))
        XCTAssertEqual(problem(.int(0...10), .integer(11))?.message, "11 is outside 0...10")
    }

    func testSize() {
        XCTAssertEqual(read(.size, .integer(4096)), .size(4096))
        XCTAssertEqual(read(.size, .string("64K")), .size(64 << 10))
        XCTAssertEqual(read(.size, .string("64M")), .size(64 << 20))
        XCTAssertEqual(read(.size, .string("2G")), .size(2 << 30))
        XCTAssertEqual(read(.size, .string("1T")), .size(1 << 40))
        XCTAssertEqual(read(.size, .string("512")), .size(512))
        XCTAssertNil(read(.size, .integer(-1)))
        XCTAssertNil(read(.size, .string("64m")))
        XCTAssertNil(read(.size, .string("64MB")))
        XCTAssertNil(read(.size, .string("M")))
        XCTAssertNil(read(.size, .string("9000000T")))
        XCTAssertNil(read(.size, .float(1.5)))
    }

    func testChoiceSuggestsTheNearest() {
        let type = ValueType.choice(["bake", "broil", "convect"])
        XCTAssertEqual(read(type, .string("broil")), .choice("broil"))
        XCTAssertEqual(read(type, .string("convect")), .choice("convect"))
        XCTAssertEqual(problem(type, .string("convec"))?.fix, "did you mean `convect`?")
    }

    // A YAML integer is not a string; the fix quotes it.
    func testStringKeepsCoreTypes() {
        XCTAssertEqual(read(.string, .string("x")), .string("x"))
        XCTAssertNil(read(.string, .integer(42)))
        XCTAssertEqual(problem(.string, .integer(42))?.fix, "quote it: \"42\"")
        XCTAssertNil(read(.string, .null))
    }

    func testList() {
        XCTAssertEqual(read(.list(.string), .list([.string("a"), .string("b")])), .list([.string("a"), .string("b")]))
        XCTAssertEqual(read(.list(.size), .list([])), .list([]))
        XCTAssertNil(read(.list(.string), .list([.integer(1)])))
        XCTAssertNil(read(.list(.string), .string("a")))
    }

    func testCanonicalAndDescription() {
        XCTAssertEqual(Value.size(64 << 20).canonical, "67108864")
        XCTAssertEqual(Value.size(64 << 20).description, "64M")
        XCTAssertEqual(Value.size(1536).description, "1536")
        XCTAssertEqual(Value.size(0).description, "0")
        XCTAssertEqual(Value.string("a\"b\\c\n").canonical, "\"a\\\"b\\\\c\\u{a}\"")
        XCTAssertEqual(Value.list([.string("a"), .int(1)]).canonical, "[\"a\", 1]")
    }

    // Every value reads back from its canonical form.
    func testCanonicalRoundTrip() {
        let cases: [(ValueType, Value)] = [
            (.bool, .bool(true)), (.int(nil), .int(-42)), (.size, .size(64 << 20)), (.choice(["a", "b"]), .choice("b")),
            (.string, .string("")), (.string, .string("a \"q\" \\ ,] \n\u{7f} é")),
            (.list(.string), .list([])), (.list(.string), .list([.string("a, b"), .string("]")])),
            (.list(.int(nil)), .list([.int(1), .int(-2)])),
        ]
        for (type, value) in cases { XCTAssertEqual(type.value(canonical: value.canonical), value, value.canonical) }
        XCTAssertNil(ValueType.int(0...5).value(canonical: "6"))
        XCTAssertNil(ValueType.string.value(canonical: "x"))
        XCTAssertNil(ValueType.bool.value(canonical: "true "))
        XCTAssertNil(ValueType.list(.int(nil)).value(canonical: "[1,2]"))
    }

    // Every value reads back as itself through its declaration form.
    func testRawRoundTrip() {
        let cases: [(ValueType, Value)] = [
            (.bool, .bool(false)), (.int(nil), .int(-3)), (.size, .size(1 << 20)),
            (.choice(["a", "b"]), .choice("b")), (.string, .string("s")), (.list(.size), .list([.size(1), .size(2)])),
        ]
        for (type, value) in cases { XCTAssertEqual(read(type, value.raw), value) }
    }
}
