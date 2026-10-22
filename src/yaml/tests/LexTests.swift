import XCTest
@testable import yaml

final class LexTests: XCTestCase {
    private struct Lexed {
        let bytes: [UInt8]
        let source: ValidatedSource
        let records: LineRecords
        let errors: [YAMLError]

        var codes: [YAMLError.Code] { errors.map(\.code) }

        func text(_ start: UInt32, _ end: UInt32) -> String {
            String(decoding: bytes[Int(start)..<Int(end)], as: UTF8.self)
        }
        func key(_ line: Int) -> String { text(records[line].keyStart, records[line].keyEnd) }
        func value(_ line: Int) -> String { text(records[line].valueStart, records[line].valueEnd) }
        func comment(_ line: Int) -> String? {
            let start = records[line].commentStart
            return start == LineRecord.none ? nil : text(start, records[line].contentEnd)
        }
    }

    private func lex(_ text: String) -> Lexed { lex(Array(text.utf8)) }

    private func lex(_ bytes: [UInt8]) -> Lexed {
        assertPathsAgree(bytes)
        let v = validate(bytes)
        let source = v.source!
        let l = lexLines(bytes, source, errors: v.errors)
        return Lexed(bytes: bytes, source: source, records: l.records, errors: l.errors.errors)
    }

    private func assertError(_ text: String, _ code: YAMLError.Code, at start: UInt32? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        let l = lex(text)
        XCTAssertEqual(l.codes, [code], text, file: file, line: line)
        if let start { XCTAssertEqual(l.errors.first?.span.start, start, text, file: file, line: line) }
    }

    // MARK: Line kinds

    func testMappingEntries() {
        let l = lex("name: Alice\nage: 30\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.records.kinds, [.node, .node])
        XCTAssertEqual(l.key(0), "name")
        XCTAssertEqual(l.value(0), "Alice")
        XCTAssertEqual(l.records[0].keyKind, .plain)
        XCTAssertEqual(l.records[0].valueKind, .plain)
        XCTAssertFalse(l.records[0].hasDash)
        XCTAssertEqual(l.key(1), "age")
        XCTAssertEqual(l.value(1), "30")
    }

    func testNestedLevels() {
        let l = lex("root:\n  child:\n    value: 42\n")
        XCTAssertEqual(l.records.lines.map(\.level), [0, 1, 2])
        XCTAssertEqual(l.records[0].valueKind, ValueKind.none)
        XCTAssertEqual(l.records[2].valueKind, .plain)
    }

    func testSequenceItems() {
        let l = lex("items:\n  - one\n  -\n    - two\n  - name: Alice\n    age: 30\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertTrue(l.records[1].hasDash)
        XCTAssertEqual(l.value(1), "one")
        XCTAssertEqual(l.records[1].keyKind, KeyKind.none)
        XCTAssertTrue(l.records[2].hasDash)
        XCTAssertEqual(l.records[2].valueKind, ValueKind.none)
        XCTAssertEqual(l.records[3].level, 2)
        XCTAssertTrue(l.records[4].hasDash)
        XCTAssertEqual(l.key(4), "name")
        XCTAssertEqual(l.value(4), "Alice")
        XCTAssertEqual(l.records[5].level, 2)
    }

    func testComments() {
        let l = lex("# top\nname: Alice   # display name\n   # indented by three\nitems: # list\n  - a # x\n  - # empty\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.records.kinds, [.comment, .node, .comment, .node, .node, .node])
        XCTAssertEqual(l.comment(0), "# top")
        XCTAssertEqual(l.value(1), "Alice")
        XCTAssertEqual(l.comment(1), "# display name")
        XCTAssertEqual(l.comment(3), "# list")
        XCTAssertEqual(l.records[3].valueKind, ValueKind.none)
        XCTAssertEqual(l.value(4), "a")
        XCTAssertEqual(l.comment(5), "# empty")
    }

    func testPlainScalarContents() {
        let l = lex("url: https://example.com/path#frag\nname: Alice:Bob\nv: -foo\nw: foo#bar\nx: a  b\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.value(0), "https://example.com/path#frag")
        XCTAssertEqual(l.value(1), "Alice:Bob")
        XCTAssertEqual(l.value(2), "-foo")
        XCTAssertEqual(l.value(3), "foo#bar")
        XCTAssertEqual(l.value(4), "a  b")
    }

    func testKeysWithSpaces() {
        let l = lex("opt release:\n  inline: true\ncollection_time test release: 120\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.key(0), "opt release")
        XCTAssertEqual(l.key(2), "collection_time test release")
    }

    func testQuotedScalars() {
        let l = lex("\"a b\": 'it''s'\nk: \"say \\\"hi\\\"\" # c\n'': \"\"\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.records[0].keyKind, .doubleQuoted)
        XCTAssertEqual(l.key(0), "\"a b\"")
        XCTAssertEqual(l.records[0].valueKind, .singleQuoted)
        XCTAssertEqual(l.value(0), "'it''s'")
        XCTAssertEqual(l.value(1), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(l.comment(1), "# c")
        XCTAssertEqual(l.key(2), "''")
        XCTAssertEqual(l.value(2), "\"\"")
    }

    func testQuotedValueWithColonInside() {
        let l = lex("k: \"a: b\"\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.value(0), "\"a: b\"")
    }

    func testEmptyCollections() {
        let l = lex("items: []\noptions: {} # none\n- []\n")
        XCTAssertEqual(l.records[0].valueKind, .emptySequence)
        XCTAssertEqual(l.records[1].valueKind, .emptyMapping)
        XCTAssertEqual(l.comment(1), "# none")
        XCTAssertEqual(l.records[2].valueKind, .emptySequence)
    }

    func testRootScalar() {
        let l = lex("hello\n")
        XCTAssertEqual(l.records.kinds, [.node])
        XCTAssertEqual(l.records[0].keyKind, KeyKind.none)
        XCTAssertEqual(l.value(0), "hello")
    }

    func testDocumentMarkers() {
        let l = lex("--- # start\nname: Alice\n...\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.records.kinds, [.documentStart, .node, .documentEnd])
        XCTAssertEqual(l.comment(0), "# start")
    }

    func testPlainScalarStartingWithDashes() {
        let l = lex("---x\n")
        XCTAssertEqual(l.records.kinds, [.node])
        XCTAssertEqual(l.value(0), "---x")
    }

    func testBlankLines() {
        let l = lex("a: 1\n\nb: 2\n")
        XCTAssertEqual(l.records.kinds, [.node, .blank, .node])
    }

    func testCRLFContentExcludesBreak() {
        let l = lex("a: 1\r\nb: 2\r\n")
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.value(0), "1")
        XCTAssertEqual(l.records[0].contentEnd, 4)
    }

    func testByteOrderMarkIsSkipped() {
        let l = lex([0xEF, 0xBB, 0xBF] + Array("a: 1\n".utf8))
        XCTAssertTrue(l.errors.isEmpty)
        XCTAssertEqual(l.records[0].contentStart, 3)
        XCTAssertEqual(l.key(0), "a")
    }

    // MARK: Block scalars

    func testBlockHeaders() {
        let l = lex("a: |\n  x\nb: >-\n  y\nc: |+ # keep\n  z\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.records[0].valueKind, .literal)
        XCTAssertEqual(l.records[0].chomping, .clip)
        XCTAssertEqual(l.records[2].valueKind, .folded)
        XCTAssertEqual(l.records[2].chomping, .strip)
        XCTAssertEqual(l.records[4].chomping, .keep)
        XCTAssertEqual(l.comment(4), "# keep")
        XCTAssertEqual(l.records.kinds, [.node, .blockContent, .node, .blockContent, .node, .blockContent])
    }

    func testBlockContentIsVerbatim() {
        let l = lex("m: |\n  # not a comment\n    deeper\t tab\n\n  key: not a key\nnext: 1\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.records.kinds, [.node, .blockContent, .blockContent, .blockContent, .blockContent, .node])
    }

    func testBlankLinesWithSpacesInsideBlock() {
        let l = lex("m: |\n  a\n \n     \n  b\n")
        XCTAssertTrue(l.errors.isEmpty, "\(l.codes)")
        XCTAssertEqual(l.records.kinds, [.node, .blockContent, .blockContent, .blockContent, .blockContent])
    }

    func testBlockOwnerColumns() {
        // `- |`: the dash owns it, so content is at 2 + 2.
        XCTAssertTrue(lex("s:\n  - |\n    text\n").errors.isEmpty)
        // `- key: |`: the key, two columns right of the dash, owns it.
        XCTAssertTrue(lex("s:\n  - key: |\n      text\n").errors.isEmpty)
        // A root block scalar's content is at 2.
        XCTAssertTrue(lex("|\n  text\n").errors.isEmpty)
        // Under `- key: |`, a line at the dash's depth plus two is not content: it ends the block, which is then
        // empty, and lexes as a node.
        let l = lex("s:\n  - key: |\n    text\n")
        XCTAssertEqual(l.codes, [.emptyBlockScalar])
        XCTAssertEqual(l.records.kinds, [.node, .invalid, .node])
    }

    func testBlockContentIndentedWrongly() {
        assertError("m: |\n    hello\n", .blockScalarIndentation)
        assertError("m: |\n     \n  hello\n", .blockScalarIndentation)  // leading blank too deep
    }

    func testEmptyBlockScalar() {
        let l = lex("m: |\nn: 1\n")
        XCTAssertEqual(l.codes, [.emptyBlockScalar])
        XCTAssertEqual(l.errors.first?.span, ByteSpan(start: 3, end: 4))
        XCTAssertEqual(l.records.kinds, [.invalid, .node])
        assertError("m: >-\n\n\nn: 1\n", .emptyBlockScalar, at: 3)
        assertError("- |+ # c\n- x\n", .emptyBlockScalar, at: 2)
        assertError("a:\n  m: |\n", .emptyBlockScalar, at: 8)
        assertError("m: |\n\n", .emptyBlockScalar, at: 3)
        assertError("m: |", .emptyBlockScalar, at: 3)
    }

    func testBlockEndsAtLessIndentedLine() {
        let l = lex("a:\n  m: |\n    x\n  n: 1\n")
        XCTAssertEqual(l.records.kinds, [.node, .node, .blockContent, .node])
    }

    // MARK: Errors

    func testWhitespaceErrors() {
        assertError("a: 1\n  \nb: 2\n", .whitespaceOnlyLine, at: 5)
        assertError("a: 1 \n", .trailingWhitespace, at: 4)
        assertError("a: 1 # c \n", .trailingWhitespace, at: 8)
        assertError("\ta: 1\n", .tabOutsideScalar, at: 0)
        assertError("a:\t1\n", .tabOutsideScalar, at: 2)
        assertError("a: x\ty\n", .tabOutsideScalar, at: 4)
        assertError("-\tx\n", .tabOutsideScalar, at: 1)
        assertError("a: \"x\"\t# c\n", .tabOutsideScalar, at: 6)
    }

    func testTabsInsideQuotesAndComments() {
        XCTAssertTrue(lex("a: \"x\ty\"\nb: 'p\tq'\n# c\td\nc: 1 # e\tf\n- # g\th\nd: | # i\tj\n  k\n").errors.isEmpty)
    }

    func testIndentationErrors() {
        assertError("a:\n   b: 1\n", .oddIndentation, at: 3)
        assertError(String(repeating: " ", count: 512) + "a: 1\n", .nestingTooDeep)
    }

    func testSpacingErrors() {
        assertError("-  x\n", .dashSpacing, at: 1)
        assertError("a:  1\n", .colonSpacing, at: 2)
        assertError("a : 1\n", .spaceBeforeColon, at: 1)
        assertError("\"a\" : 1\n", .spaceBeforeColon, at: 3)
        XCTAssertTrue(lex("-   # c\na:    # c\n  b: 1\n").errors.isEmpty)
    }

    func testNestingOnOneLine() {
        assertError("- - a\n", .sequenceOnItemLine, at: 2)
        assertError("a: - b\n", .sequenceOnKeyLine, at: 3)
        assertError("a: b: c\n", .mappingOnValueLine, at: 4)
        assertError("- a: b: c\n", .mappingOnValueLine, at: 6)
    }

    func testUnsupportedFeatures() {
        assertError("? a\n", .complexKey)
        assertError(": a\n", .emptyKey)
        assertError("a: &x 1\n", .anchor)
        assertError("a: *x\n", .alias)
        assertError("a: !!str 1\n", .tag)
        assertError("a: [1, 2]\n", .flowCollection)
        assertError("a: { }\n", .flowCollection)
        assertError("a: []x\n", .flowCollection)
        assertError("a: ,x\n", .flowCollection)
        assertError("a: @x\n", .reservedIndicator)
        assertError("a: `x\n", .reservedIndicator)
        assertError("a: %x\n", .reservedIndicator)
        assertError("%YAML 1.2\n", .directive)
    }

    func testQuoteErrors() {
        assertError("a: \"x\n", .unterminatedQuote, at: 3)
        assertError("a: 'x''\n", .unterminatedQuote, at: 3)
        assertError("a: \"x\"y\n", .contentAfterQuote, at: 6)
        assertError("a: \"x\" y\n", .contentAfterQuote, at: 7)
    }

    func testBlockHeaderErrors() {
        assertError("a: |2\n  x\n", .blockIndentationIndicator, at: 4)
        assertError("a: |-2\n  x\n", .blockIndentationIndicator, at: 5)
        assertError("a: | x\n", .contentOnBlockHeader, at: 5)
    }

    func testMarkerErrors() {
        assertError("--- a\n", .contentOnMarkerLine, at: 4)
        assertError("... a\n", .contentOnMarkerLine, at: 4)
    }

    func testKeyTooLong() {
        let long = String(repeating: "é", count: 1025)
        assertError("\(long): 1\n", .keyTooLong)
        XCTAssertTrue(lex(String(repeating: "é", count: 1024) + ": 1\n").errors.isEmpty)
    }

    func testOneErrorPerLineAndAllLinesReported() {
        let l = lex("a:  1  \nb : 2\nc: ok\n- - x\n")
        XCTAssertEqual(l.codes, [.trailingWhitespace, .spaceBeforeColon, .sequenceOnItemLine])
        XCTAssertEqual(l.records.kinds, [.invalid, .invalid, .node, .invalid])
    }

    // MARK: Block boundaries

    // An invalid line's token spans hold whatever was set before its error; only its kind and bounds count.
    private func significant(_ r: LineRecord) -> LineRecord {
        r.kind == .invalid ? LineRecord(kind: .invalid, contentStart: r.contentStart, contentEnd: r.contentEnd) : r
    }

    // Scans jump through 64-byte block masks, so every token must lex the same at every offset within a block.
    // Each document is lexed behind comment lines of every length from 2 to 131 bytes; its records and errors
    // must match the unshifted ones, moved by the prefix length.
    func testLexingIsTheSameAtEveryBlockOffset() {
        let long = String(repeating: "k", count: 100)
        let documents = [
            "name: Alice\nage: 30 # c\nurl: http://x:80/a#b\n- a:b\n  - x # y\n",
            "\(long): \(long) # \(long)\n\(long)#x: 1\n",
            "s: \"\(long)\\\"\(long)\" # c\nt: '\(long)''\(long)'\nu: \"a\\\\\"\n",
            "a: 1\r\nb:\r\n  - x\r\nc: d #e\r\n",
            "msg: |-\n  one: two # three\n\n  \t\n\(long):\n",
            "a:\tb\nc : d\ne: \"open\nf: x\ty\n  - g\n x: 1\nh: [a]\n",
            "last:",
            "last: value #",
        ]
        for text in documents {
            let base = lex(text)
            for k in 0..<130 {
                let lineBreak = text.utf8.contains(0x0D) ? "\r\n" : "\n"
                let prefix = "#" + String(repeating: "x", count: k) + lineBreak
                let d = UInt32(prefix.utf8.count)
                let l = lex(prefix + text)
                XCTAssertEqual(l.records.count, base.records.count + 1, "\(text) at +\(d)")
                XCTAssertEqual(l.codes, base.codes, "\(text) at +\(d)")
                for (e, b) in zip(l.errors, base.errors) {
                    XCTAssertEqual(e.span, ByteSpan(start: b.span.start + d, end: b.span.end + d), "\(text) at +\(d)")
                }
                for line in 0..<base.records.count {
                    var expected = significant(base.records[line])
                    expected.contentStart += d
                    expected.contentEnd += d
                    if expected.keyKind != .none { expected.keyStart += d; expected.keyEnd += d }
                    if expected.valueKind != .none { expected.valueStart += d; expected.valueEnd += d }
                    if expected.hasComment { expected.commentStart += d }
                    let actual = significant(l.records[line + 1])
                    XCTAssertEqual(actual, expected, "\(text) line \(line) at +\(d)")
                }
            }
        }
    }

    // MARK: Lossless records

    // Rebuilds a document from its line records alone: indentation from the level, `- ` and `: ` from the
    // shape, token bytes from their spans, comment gaps from the comment offset, block content verbatim, and
    // the line break from the source. Any byte the records fail to account for makes it differ.
    private func rebuild(_ l: Lexed) -> [UInt8] {
        var out: [UInt8] = l.source.hasByteOrderMark ? [0xEF, 0xBB, 0xBF] : []
        let breakBytes: [UInt8] = l.source.lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A]
        func span(_ s: UInt32, _ e: UInt32) -> [UInt8] { Array(l.bytes[Int(s)..<Int(e)]) }
        func spaces(_ n: Int) -> [UInt8] { Array(repeating: 0x20, count: n) }

        for line in 0..<l.records.count {
            let r = l.records[line]
            let start = Int(r.contentStart)
            var cursor = start
            switch r.kind {
            case .blank:
                break
            case .comment:
                out += span(r.contentStart, r.contentEnd)
                cursor = Int(r.contentEnd)
            case .documentStart, .documentEnd:
                out += Array((r.kind == .documentStart ? "---" : "...").utf8)
                cursor = start + 3
            case .blockContent:
                out += span(r.contentStart, r.contentEnd)
                cursor = Int(r.contentEnd)
            case .node:
                out += spaces(Int(r.level) * 2)
                cursor = start + Int(r.level) * 2
                if r.hasDash {
                    let alone = r.keyKind == .none && r.valueKind == .none
                    out += Array((alone ? "-" : "- ").utf8)
                    cursor += alone ? 1 : 2
                }
                if r.keyKind != .none {
                    out += span(r.keyStart, r.keyEnd) + [0x3A]
                    cursor = Int(r.keyEnd) + 1
                    if r.valueKind != .none { out += [0x20]; cursor += 1 }
                }
                if r.valueKind != .none {
                    out += span(r.valueStart, r.valueEnd)
                    cursor = Int(r.valueEnd)
                }
            case .invalid:
                XCTFail("rebuild is defined for valid documents")
            }
            if r.hasComment && r.kind != .comment {
                out += spaces(Int(r.commentStart) - cursor)
                out += span(r.commentStart, r.contentEnd)
            }
            let lineBreakEnd = line + 1 < l.records.count ? Int(l.source.lines.lineStarts[line + 1]) : l.bytes.count
            if lineBreakEnd > Int(r.contentEnd) { out += breakBytes }
        }
        return out
    }

    func testRecordsRebuildTheInput() {
        let documents = [
            "name: Alice\nage: 30\n",
            "# leading\nroot:   # spaced comment\n  child:\n    value: 42 # c\n   # odd comment\n\nitems:\n  - one\n  -\n    - two\n  - k: v\n    w: x\n  - # c\n    z: 1\n",
            "s: \"q \\\" t\"  # c\nt: 'a''b'\n\"\": []\nm: {}\n",
            "--- # doc\nmsg: |-\n  line one\n    indented\n\n  # kept\nnext: >+\n  folded\n\n...\n",
            "a: 1\r\nb:\r\n  - x\r\n",
            "no: trailing break",
            "- |\n  root item\n- key: >\n    owned by key\n",
        ]
        for text in documents {
            let l = lex(text)
            XCTAssertTrue(l.errors.isEmpty, "\(text): \(l.codes)")
            XCTAssertEqual(String(decoding: rebuild(l), as: UTF8.self), text)
        }
        let bom = [0xEF, 0xBB, 0xBF] + Array("a: 1\n".utf8)
        XCTAssertEqual(rebuild(lex(bom)), bom)
    }
}
