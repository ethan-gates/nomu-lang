import XCTest
@testable import yaml

final class ResolveTests: XCTestCase {
    private struct Parsed {
        let bytes: [UInt8]
        let records: [LineRecord]
        let arena: NodeArena
        let types: [ScalarType]
        let errors: [YAMLError]

        var codes: [YAMLError.Code] { errors.map(\.code) }

        // The first scalar node, which holds the value of a one-line document like `v: 42`.
        var firstScalar: UInt32 { UInt32(arena.nodes.firstIndex { $0.kind == .scalar }!) }

        func value(_ node: UInt32) -> String {
            bytes.withUnsafeBufferPointer { b in
                String(decoding: ScalarText.value(b, records, line: Int(arena[node].line)), as: UTF8.self)
            }
        }
    }

    private func parse(_ text: String) -> Parsed {
        let bytes = Array(text.utf8)
        assertPathsAgree(bytes)
        let v = validate(bytes)
        let l = lexLines(bytes, v.source!, errors: v.errors)
        let s = buildStructure(bytes, l)
        let r = resolveScalars(bytes, l, s)
        return Parsed(bytes: bytes, records: l.records.lines, arena: s.arena, types: r.types, errors: r.errors.errors)
    }

    // Types `v: <spelling>` and checks its type, or its one error.
    private func assertType(_ spelling: String, _ type: ScalarType, file: StaticString = #filePath, line: UInt = #line) {
        let p = parse("v: \(spelling)\n")
        XCTAssertEqual(p.codes, [], spelling, file: file, line: line)
        if p.codes.isEmpty { XCTAssertEqual(p.types[Int(p.firstScalar)], type, spelling, file: file, line: line) }
    }

    private func assertRejected(_ spelling: String, _ code: YAMLError.Code, file: StaticString = #filePath,
                                line: UInt = #line) {
        let p = parse("v: \(spelling)\n")
        XCTAssertEqual(p.codes, [code], spelling, file: file, line: line)
        XCTAssertEqual(p.errors.first?.span, ByteSpan(start: 3, end: UInt32(3 + spelling.utf8.count)), spelling,
                       file: file, line: line)
    }

    // MARK: Typing (spec §11–§16)

    func testIntegers() {
        for s in ["42", "-42", "001", "0", "-0", "9223372036854775807", "-9223372036854775808", "010"] {
            assertType(s, .integer)
        }
        for s in ["9223372036854775808", "-9223372036854775809", "99999999999999999999"] {
            assertRejected(s, .integerOutOfRange)
        }
    }

    func testFloats() {
        for s in ["3.14", ".5", "1.", "1e10", "-2.5E+03", "1e-400", "-.5", "0.0", ".inf", "-.inf", "1E5"] {
            assertType(s, .float)
        }
        assertRejected("1e400", .floatOutOfRange)
        assertRejected("-1.8e308", .floatOutOfRange)
    }

    func testBooleansAndNull() {
        assertType("true", .boolean)
        assertType("false", .boolean)
        assertType("null", .null)
        for s in ["True", "TRUE", "False", "FALSE", "tRUE"] { assertRejected(s, .booleanCase) }
        for s in ["Null", "NULL", "~", "nULL"] { assertRejected(s, .nullSpelling) }
    }

    func testRejectedNumericSpellings() {
        for s in ["+42", "+1.5", "+.inf", "+0x2a", "+1_000", "+.Inf"] { assertRejected(s, .unaryPlus) }
        for s in ["0x2a", "0o52", "-0x2a", "0X2a", "0b1010", "0B11", "0x_ff", "0O7"] {
            assertRejected(s, .nonDecimalInteger)
        }
        for s in ["1_000", "-1_000", "1_000.5", "1.0_1", "1e1_0", "1__"] { assertRejected(s, .numericUnderscore) }
        for s in [".nan", ".NaN", ".NAN", "-.nan", "+.nan", ".Nan"] { assertRejected(s, .notANumber) }
        for s in [".Inf", ".INF", "-.Inf", ".iNf"] { assertRejected(s, .infinityCase) }
    }

    func testStrings() {
        for s in ["yes", "no", "on", "off", "12:30:00", "2026-10-04", "<<", "1.2.3", "0x", "0xyz", "hello", "fast",
                  "nil", "truex", "nullable", ".5.5", "1e", "1e+", ".e1", "_1", "0o8", "0b2", "~a", "-a", "+a", ".",
                  "e5", "inf", "nan", "v1.0", "1,000", "--", "+", "2026_report", "trueish", "falsey",
                  "Nulls", "..inf", ".infinity", "café"] {
            assertType(s, .string)
        }
        assertType("\"true\"", .string)
        assertType("'42'", .string)
        assertType("|\n  42", .string)
    }

    // MARK: Keys

    func testKeysMustBeStrings() {
        for k in ["42", "true", "null", "1.5", ".inf", "-1"] {
            let p = parse("\(k): x\n")
            XCTAssertEqual(p.codes, [.nonStringKey], k)
            XCTAssertEqual(p.errors.first?.span, ByteSpan(start: 0, end: UInt32(k.utf8.count)), k)
        }
        XCTAssertEqual(parse("True: x\n").codes, [.booleanCase])
        XCTAssertEqual(parse("+1: x\n").codes, [.unaryPlus])
        XCTAssertEqual(parse("\"42\": x\n'true': y\nyes: z\n").codes, [])
    }

    // MARK: Escapes (spec §18)

    func testEscapesDecode() {
        let p = parse(#"v: "\0\a\b\t\n\v\f\r\e\ \"\/\\\N\_\L\P\x41é\U0001F600""# + "\n")
        XCTAssertEqual(p.codes, [])
        XCTAssertEqual(p.value(p.firstScalar),
                       "\u{0}\u{7}\u{8}\t\n\u{B}\u{C}\r\u{1B} \"/\\\u{85}\u{A0}\u{2028}\u{2029}Aé😀")
    }

    func testMalformedEscapes() {
        let p = parse(#"v: "a\qb\x4\u12G4\uD800\U00110000""# + "\n")
        XCTAssertEqual(p.codes, [.invalidEscape, .invalidEscape, .invalidEscape, .invalidUnicodeEscape,
                                 .invalidUnicodeEscape])
        XCTAssertEqual(p.errors[0].span, ByteSpan(start: 5, end: 7))
        XCTAssertEqual(parse(#""\q": 1"#).codes, [.invalidEscape])
        XCTAssertEqual(parse(#"v: "end\\""#).codes, [])
    }

    func testQuotedAndPlainDecode() {
        let p = parse("a: 'O''Brien'\nb: plain # c\nc: \"x'y\"\nd: ''\n")
        let scalars = p.arena.nodes.indices.filter { p.arena.nodes[$0].kind == .scalar }.map { p.value(UInt32($0)) }
        XCTAssertEqual(scalars, ["O'Brien", "plain", "x'y", ""])
    }

    // MARK: Block scalars (spec §20, §21)

    private func block(_ text: String) -> String {
        let p = parse(text)
        XCTAssertEqual(p.codes, [], text)
        return p.value(p.firstScalar)
    }

    func testLiteralChomping() {
        XCTAssertEqual(block("v: |\n  a\n\n  b\n\n\n"), "a\n\nb\n")
        XCTAssertEqual(block("v: |-\n  a\n\n  b\n\n\n"), "a\n\nb")
        XCTAssertEqual(block("v: |+\n  a\n\n  b\n\n\n"), "a\n\nb\n\n\n")
        XCTAssertEqual(block("v: |\n  a"), "a")
        XCTAssertEqual(block("v: |+\n  a"), "a")
        XCTAssertEqual(block("v: |\n  a\nw: 1\n"), "a\n")
    }

    func testLiteralKeepsIndentationAndSpaces() {
        XCTAssertEqual(block("v: |\n  a\n    b\n  c\n"), "a\n  b\nc\n")
        XCTAssertEqual(block("v: |\n\n  a\n"), "\na\n")
        XCTAssertEqual(block("v: |\n  a\n    \n  b\n"), "a\n  \nb\n")
        XCTAssertEqual(block("v: |\n  a # not a comment\n  \tb\n"), "a # not a comment\n\tb\n")
    }

    func testFolding() {
        XCTAssertEqual(block("v: >\n  a\n  b\n\n  c\n"), "a b\nc\n")
        XCTAssertEqual(block("v: >\n  a\n    b\n  c\n"), "a\n  b\nc\n")
        XCTAssertEqual(block("v: >\n\n  a\n  b\n"), "\na b\n")
        XCTAssertEqual(block("v: >-\n  a\n  b\n\n"), "a b")
        XCTAssertEqual(block("v: >\n  a\n\n\n  b\n"), "a\n\nb\n")
        XCTAssertEqual(block("v: >\n  a\n   b\n\n  c\n"), "a\n b\n\nc\n")
        XCTAssertEqual(block("v: >+\n  a\n\n"), "a\n\n")
        // YAML 1.2.2 example 8.10, after its leading empty line. These cases also match Ruby's Psych.
        XCTAssertEqual(block("v: >\n  folded\n  line\n\n  next\n  line\n    * bullet\n\n    * list\n    * lines\n\n  last\n  line\n"),
                       "folded line\nnext line\n  * bullet\n\n  * list\n  * lines\n\nlast line\n")
    }

    func testBlockOwnersAndLineEndings() {
        XCTAssertEqual(block("- |\n  a\n"), "a\n")
        XCTAssertEqual(block("- k: >\n    a\n    b\n"), "a b\n")
        XCTAssertEqual(block("|\n  root\n"), "root\n")
        XCTAssertEqual(block("k: |\r\n  a\r\n  b\r\n"), "a\nb\n")
    }

    func testTypesOfCollectionsAndRootScalar() {
        XCTAssertEqual(parse("42\n").types, [.integer])
        let p = parse("a: [1]\n")
        XCTAssertEqual(p.codes, [.flowCollection])
    }
}
