import XCTest
import yaml

final class DocumentTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> YAMLDocument? {
        do {
            return try YAMLDocument(parsing: text)
        } catch {
            XCTFail("unexpected errors: \(error.errors.map(\.code))", file: file, line: line)
            return nil
        }
    }

    private func text(_ doc: YAMLDocument, _ span: ByteSpan) -> String {
        String(decoding: doc.bytes[Int(span.start)..<Int(span.end)], as: UTF8.self)
    }

    func testParseThrowsEveryError() {
        do {
            _ = try YAMLDocument(parsing: "a: True\nb: 0x1\n")
            XCTFail("expected errors")
        } catch {
            XCTAssertEqual(error.errors.map(\.code), [.booleanCase, .nonDecimalInteger])
        }
        XCTAssertThrowsError(try YAMLDocument(parsing: "# only a comment\n"))
        XCTAssertThrowsError(try YAMLDocument(parsing: [0xFF]))
    }

    func testTypedValues() throws {
        guard let doc = parse("s: hello\nq: \"a\\tb\"\ni: -42\nf: 2.5\nb: false\nn: null\nr: 'it''s'\n") else { return }
        let root = doc.root
        XCTAssertEqual(root.kind, .mapping)
        XCTAssertEqual(root["s"]?.string, "hello")
        XCTAssertEqual(root["q"]?.string, "a\tb")
        XCTAssertEqual(root["r"]?.string, "it's")
        XCTAssertEqual(root["i"]?.integer, -42)
        XCTAssertEqual(root["f"]?.float, 2.5)
        XCTAssertEqual(root["b"]?.boolean, false)
        XCTAssertEqual(root["n"]?.isNull, true)
        XCTAssertEqual(root["n"]?.kind, .null)
        // Each accessor reads only its own type.
        XCTAssertNil(root["i"]?.float)
        XCTAssertNil(root["i"]?.string)
        XCTAssertNil(root["s"]?.integer)
        XCTAssertNil(root["missing"])
        XCTAssertNil(root["s"]?["x"])
    }

    func testCollections() {
        guard let doc = parse("list:\n  - 1\n  - two\n  - k: v\nempty: []\nnone: {}\n") else { return }
        let list = doc.root["list"]!
        XCTAssertEqual(list.kind, .sequence)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.items.map(\.kind), [.integer, .string, .mapping])
        XCTAssertEqual(list[1]?.string, "two")
        XCTAssertEqual(list[2]?["k"]?.string, "v")
        XCTAssertNil(list[3])
        XCTAssertNil(list[-1])
        XCTAssertEqual(doc.root["empty"]?.kind, .sequence)
        XCTAssertEqual(doc.root["empty"]?.count, 0)
        XCTAssertEqual(doc.root["none"]?.kind, .mapping)
        XCTAssertEqual(doc.root["none"]?.entries.map(\.key), [])
        XCTAssertEqual(doc.root.entries.map(\.key), ["list", "empty", "none"])
        XCTAssertEqual(doc.root.items.map(\.kind), [])
    }

    func testRootScalarAndBlock() {
        XCTAssertEqual(parse("42\n")?.root.integer, 42)
        guard let doc = parse("notes: |\n  one\n  two\n\nnext: >-\n  a\n  b\n") else { return }
        XCTAssertEqual(doc.root["notes"]?.string, "one\ntwo\n")
        XCTAssertEqual(doc.root["next"]?.string, "a b")
    }

    func testKeyLookupIsExactAfterDecoding() {
        guard let doc = parse("\"a b\": 1\n'q''': 2\nName: 3\n\"\": 4\n\"\\u00e9\": 5\n") else { return }
        XCTAssertEqual(doc.root["a b"]?.integer, 1)
        XCTAssertEqual(doc.root["q'"]?.integer, 2)
        XCTAssertEqual(doc.root["Name"]?.integer, 3)
        XCTAssertNil(doc.root["name"])
        XCTAssertEqual(doc.root[""]?.integer, 4)
        XCTAssertEqual(doc.root["é"]?.integer, 5)
        XCTAssertEqual(doc.root.entries.map(\.key), ["a b", "q'", "Name", "", "é"])
    }

    func testKeyLookupInLargeMappings() {
        var text = ""
        for k in 0..<100 { text += k % 3 == 0 ? "\"key \(k)\": \(k)\n" : "key_\(k): \(k)\n" }
        text += "\"\": -1\nKEY: -2\nÉté: -3\n"
        guard let doc = parse(text) else { return }
        for k in 0..<100 {
            XCTAssertEqual(doc.root[k % 3 == 0 ? "key \(k)" : "key_\(k)"]?.integer, Int64(k))
        }
        XCTAssertEqual(doc.root[""]?.integer, -1)
        XCTAssertEqual(doc.root["KEY"]?.integer, -2)
        XCTAssertEqual(doc.root["Été"]?.integer, -3)
        XCTAssertNil(doc.root["été"])
        XCTAssertNil(doc.root["key"])
        XCTAssertNil(doc.root["key_0"])
        XCTAssertNil(doc.root["Key_1"])
    }

    func testSpans() {
        let source = "a: 1\nb:\n  - x\n  - \"y\"  # c\nc:\n  d: |\n    t\n\n    u\n\n  e: {}\n"
        guard let doc = parse(source) else { return }
        let root = doc.root
        XCTAssertEqual(text(doc, root["a"]!.span), "1")
        XCTAssertEqual(text(doc, root["b"]!.span), "- x\n  - \"y\"")
        XCTAssertEqual(text(doc, root["b"]![1]!.span), "\"y\"")
        XCTAssertEqual(text(doc, root["c"]!["d"]!.span), "|\n    t\n\n    u")
        XCTAssertEqual(text(doc, root["c"]!["e"]!.span), "{}")
        XCTAssertEqual(text(doc, root["c"]!.span), "d: |\n    t\n\n    u\n\n  e: {}")
        XCTAssertEqual(text(doc, root.span), String(source.dropLast()))
        let entries = Array(root.entries)
        XCTAssertEqual(entries.map { text(doc, $0.keySpan) }, ["a", "b", "c"])
        XCTAssertTrue(root["c"]!.location == (6, 3))
        XCTAssertTrue(root["b"]![1]!.location == (4, 5))
    }

    func testBytesRoundTrip() {
        let source = "\u{FEFF}# head\r\na: 1  # trailing\r\n\r\nb: 'x'\r\n"
        XCTAssertEqual(parse(source)?.bytes, Array(source.utf8))
    }
}
