import XCTest
@testable import yaml

final class StructureTests: XCTestCase {
    private struct Built {
        let bytes: [UInt8]
        let records: LineRecords
        let arena: NodeArena
        let errors: [YAMLError]

        var codes: [YAMLError.Code] { errors.map(\.code) }

        // The tree in a compact form: `{key: value, ...}`, `[item, ...]`, scalars as written, and `∅` for an
        // entry left without a value by an error.
        var tree: String { arena.root == Node.none ? "" : render(arena.root) }

        private func text(_ start: UInt32, _ end: UInt32) -> String {
            String(decoding: bytes[Int(start)..<Int(end)], as: UTF8.self)
        }

        private func render(_ n: UInt32) -> String {
            let node = arena[n]
            let r = records[Int(node.line)]
            switch node.kind {
            case .scalar:
                return text(r.valueStart, r.valueEnd)
            case .entry:
                return text(r.keyStart, r.keyEnd) + ": " + (node.firstChild == Node.none ? "∅" : render(node.firstChild))
            case .mapping:
                return "{" + arena.children(of: n).map(render).joined(separator: ", ") + "}"
            case .sequence:
                return "[" + arena.children(of: n).map(render).joined(separator: ", ") + "]"
            }
        }
    }

    private func build(_ text: String) -> Built {
        let bytes = Array(text.utf8)
        assertPathsAgree(bytes)
        let v = validate(bytes)
        let l = lexLines(bytes, v.source!, errors: v.errors)
        let s = buildStructure(bytes, l)
        return Built(bytes: bytes, records: l.records, arena: s.arena, errors: s.errors.errors)
    }

    private func assertTree(_ text: String, _ tree: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = build(text)
        XCTAssertEqual(b.codes, [], text, file: file, line: line)
        XCTAssertEqual(b.tree, tree, text, file: file, line: line)
    }

    private func assertErrors(_ text: String, _ codes: [YAMLError.Code], at start: UInt32? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        let b = build(text)
        XCTAssertEqual(b.codes, codes, text, file: file, line: line)
        if let start { XCTAssertEqual(b.errors.first?.span.start, start, text, file: file, line: line) }
    }

    // MARK: Valid structure

    func testMappings() {
        assertTree("a: 1\nb: 2\n", "{a: 1, b: 2}")
        assertTree("a:\n  b:\n    c: 1\n  d: 2\ne: 3\n", "{a: {b: {c: 1}, d: 2}, e: 3}")
        assertTree("name: # the parts\n  first: Alice\n", "{name: {first: Alice}}")
        assertTree("\"q\": 1\n'r': 2\n", "{\"q\": 1, 'r': 2}")
    }

    func testSequences() {
        assertTree("- a\n- b\n", "[a, b]")
        assertTree("items:\n  - one\n  - two\n", "{items: [one, two]}")
        assertTree("m:\n  -\n    - a\n    - b\n  - c\n", "{m: [[a, b], c]}")
    }

    func testSequencesOfMappings() {
        assertTree("u:\n  - name: A\n    age: 1\n  - name: B\n", "{u: [{name: A, age: 1}, {name: B}]}")
        assertTree("u:\n  -\n    name: A\n    age: 1\n  -\n    name: B\n", "{u: [{name: A, age: 1}, {name: B}]}")
        assertTree("- a:\n    - x\n  b: 2\n- c\n", "[{a: [x], b: 2}, c]")
    }

    func testScalarsAndEmptyCollections() {
        assertTree("hello\n", "hello")
        assertTree("\"quoted\" # c\n", "\"quoted\"")
        assertTree("a: []\nb: {}\nc: \"\"\n", "{a: [], b: {}, c: \"\"}")
        XCTAssertEqual(build("[]\n").arena[0].kind, .sequence)
    }

    func testBlockScalars() {
        assertTree("m: |\n  x\n\n    y\nn: >-\n  z\n", "{m: |, n: >-}")
        assertTree("- |\n  x\n- k: |\n    y\n  j: 2\n", "[|, {k: |, j: 2}]")
        assertTree("|\n  root\n", "|")
    }

    func testCommentsAndBlankLinesCarryNoStructure() {
        assertTree("# top\na:\n\n  # inside\n     # any indent\n  b: 1\n\n# end\n", "{a: {b: 1}}")
    }

    func testDocumentMarkers() {
        assertTree("---\na: 1\n...\n# after\n\n", "{a: 1}")
        assertTree("# c\n--- # start\n- x\n", "[x]")
    }

    func testArenaLinks() {
        let b = build("a:\n  - x\nb: y\n")
        let root = b.arena.root
        let entries = b.arena.children(of: root)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(b.arena[entries[0]].parent, root)
        XCTAssertEqual(b.arena[entries[0]].line, 0)
        let seq = b.arena[entries[0]].firstChild
        XCTAssertEqual(b.arena[seq].kind, .sequence)
        XCTAssertEqual(b.arena[seq].parent, entries[0])
        XCTAssertEqual(b.arena[seq].line, 1)
        XCTAssertEqual(b.arena[b.arena[seq].firstChild].parent, seq)
        XCTAssertEqual(b.arena[entries[1]].line, 2)
        XCTAssertEqual(b.arena[root].parent, Node.none)
    }

    // MARK: Documents

    func testEmptyDocument() {
        assertErrors("", [.emptyDocument])
        assertErrors("# only a comment\n\n", [.emptyDocument])
        assertErrors("---\n...\n", [.emptyDocument])
    }

    func testMultipleDocuments() {
        assertErrors("a: 1\n---\nb: 2\n", [.multipleDocuments], at: 5)
        assertErrors("---\n---\n", [.multipleDocuments], at: 4)
        assertErrors("a: 1\n...\n---\n", [.multipleDocuments])
    }

    func testContentAfterDocumentEnd() {
        assertErrors("a: 1\n...\nb: 2\nc: 3\n", [.contentAfterDocumentEnd], at: 9)
        assertErrors("a: 1\n...\n...\n", [.contentAfterDocumentEnd])
    }

    func testContentAfterRootScalar() {
        assertErrors("\"q\"\na: 1\n", [.contentAfterRootScalar], at: 4)
        assertErrors("hello\na: 1\nb: 2\n", [.contentAfterRootScalar])
    }

    // MARK: Values

    func testMissingValue() {
        assertErrors("name:\n", [.missingValue], at: 0)
        assertErrors("name: # no value\n", [.missingValue])
        assertErrors("a:\nb: 1\n", [.missingValue], at: 0)
        assertErrors("a:\n  b:\nc: 1\n", [.missingValue], at: 5)
        assertErrors("-\n", [.missingValue], at: 0)
        assertErrors("items:\n  - # c\n", [.missingValue], at: 9)
        assertErrors("a:\n...\n", [.missingValue])
    }

    func testValueOnNextLine() {
        assertErrors("key:\n  value\n", [.valueOnNextLine], at: 7)
        assertErrors("-\n  value\n", [.valueOnNextLine])
        // A block header on the next line takes the lines below as its content, so one error covers them.
        assertErrors("d:\n  |\n  text\n    more\n\n  last\ne: 1\n", [.valueOnNextLine], at: 5)
        assertErrors("d:\n  >\ne: 1\n", [.valueOnNextLine])
    }

    func testMultilinePlainScalar() {
        assertErrors("key: hello\n  world\n", [.multilinePlainScalar], at: 13)
        assertErrors("hello\nworld\n", [.multilinePlainScalar])
        assertErrors("- a\n  b\n  c\n- d\n", [.multilinePlainScalar])
        // A deeper line with a key or dash cannot continue a plain scalar: it is nesting under a complete value.
        assertErrors("a: b\n  c: d\ne: f\n", [.indentationJump])
        assertErrors("a: b\n  - c\n", [.indentationJump])
    }

    // MARK: Indentation and collections

    func testIndentationJump() {
        assertErrors("a:\n    b: 1\n", [.indentationJump], at: 3)
        assertErrors("  a: 1\n", [.indentationJump])
        assertErrors("a: \"x\"\n  b: 1\n", [.indentationJump])
        assertErrors("a: []\n  - x\n", [.indentationJump])
    }

    func testIndentlessSequenceReportedOnce() {
        let b = build("items:\n- one\n- two\nnext: 1\n")
        XCTAssertEqual(b.codes, [.indentlessSequence])
        XCTAssertEqual(b.errors[0].span, ByteSpan(start: 7, end: 8))
        XCTAssertEqual(b.tree, "{items: ∅, next: 1}")
        assertErrors("- k:\n  - x\n", [.indentlessSequence])
    }

    func testMixedCollection() {
        assertErrors("a: 1\n- b\n", [.mixedCollection], at: 5)
        assertErrors("- a\nb: 1\n", [.mixedCollection], at: 4)
        assertErrors("- k: 1\n  - x\n", [.mixedCollection])
    }

    func testBareScalar() {
        assertErrors("a: 1\nfoo\n", [.bareScalar], at: 5)
        assertErrors("- a\nfoo\n", [.bareScalar])
    }

    // MARK: Duplicate keys

    func testDuplicateKeys() {
        assertErrors("name: A\n\"name\": B\n", [.duplicateKey], at: 8)
        assertErrors("name: A\nName: B\n", [.duplicateKey])
        assertErrors("- a: 1\n  A: 2\n", [.duplicateKey])
        assertErrors("\"\\u0061\": 1\na: 2\n", [.duplicateKey])
        assertErrors("'a''b': 1\n\"a'b\": 2\n", [.duplicateKey])
        assertErrors("a:\n  x: 1\nb:\n  x: 2\n", [])
        assertErrors("a:\n  x: 1\n  y:\n    x: 2\n", [])
    }

    // Plain ASCII keys hash straight from the source a word at a time; other keys hash their decoded, folded
    // text. Both must agree.
    func testDuplicateKeyHashingPaths() {
        assertErrors("\"NAME\": 1\nname: 2\n", [.duplicateKey])
        assertErrors("abcdefghijklmnopq: 1\nABCDEFGHIJKLMNOPQ: 2", [.duplicateKey])     // last key ends the input
        assertErrors("abcdefgh: 1\n'ABCDEFGH': 2\n", [.duplicateKey])                 // exactly one word
        assertErrors("abcdefgh: 1\nabcdefgi: 2\nabcdefg: 3\nabcdefgh_: 4\n", [])
        assertErrors("café: 1\nCAFÉ: 2\n", [.duplicateKey])
        assertErrors("\"caf\\u00C9\": 1\ncafé: 2\n", [.duplicateKey])
        assertErrors("@: 1\n`: 2\n[: 3\n{: 4\n", [.reservedIndicator, .reservedIndicator, .flowCollection,
                                                    .flowCollection])
        assertErrors("\"@\": 1\n\"`\": 2\n\"[\": 3\n\"{\": 4\n\"Z\": 5\n\"z\": 6\n", [.duplicateKey])
    }

    func testDuplicateKeysUseSimpleCaseFolding() {
        assertErrors("ſ: 1\ns: 2\n", [.duplicateKey])         // long s folds to s
        assertErrors("ẞ: 1\nß: 2\n", [.duplicateKey])         // capital sharp s folds to ß
        assertErrors("Ω: 1\nω: 2\n", [.duplicateKey])
        assertErrors("Straße: 1\nSTRASSE: 2\n", [])           // full folding would match these; simple does not
    }

    func testDuplicateKeysInLargeMappings() {
        let many = (0..<40).map { "k\($0): \($0)\n" }.joined()
        assertErrors(many, [])
        assertErrors(many + "K7: x\n", [.duplicateKey])
        assertErrors(many + "K39: x\nk40: y\nk40: z\n", [.duplicateKey, .duplicateKey])
    }

    func testMalformedEscapeInKeyIsLeftToScalarStage() {
        assertErrors("\"\\q\": 1\n\"\\q\": 2\n", [])
    }

    // MARK: Recovery

    func testErrorsDoNotCascade() {
        assertErrors("a:\n  b : 1\n  c: 2\nd: 3\n", [.spaceBeforeColon])
        assertErrors("a:\n  m: |\nb: 1\n", [.emptyBlockScalar])
        assertErrors("a:\n  - x\n  y: 1\n    deeper: 2\n  - z\nb: 1\n", [.mixedCollection])
        assertErrors("a:\n  b\n  c: 1\nd: 2\n", [.valueOnNextLine])
        assertErrors("a:\n    b: 1\n  c: 2\n", [.indentationJump])
    }

    func testIndependentErrorsAreAllReported() {
        assertErrors("a:\nb: 1\nb: 2\n- c\n", [.missingValue, .duplicateKey, .mixedCollection])
    }
}
