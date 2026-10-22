import XCTest
import yaml

final class EditTests: XCTestCase {
    // Parses `source`, applies the edits `body` makes, and returns the new source text.
    private func edit(_ source: String, style: YAMLStyle = YAMLStyle(), file: StaticString = #filePath,
                      line: UInt = #line, _ body: (inout YAMLEdits, YAMLNode) -> Void) -> String {
        do {
            let doc = try YAMLDocument(parsing: source)
            var edits = YAMLEdits(doc, style: style)
            body(&edits, doc.root)
            return String(decoding: try edits.apply().bytes, as: UTF8.self)
        } catch {
            XCTFail("errors: \(error.errors.map(\.code))", file: file, line: line)
            return ""
        }
    }

    // MARK: Values

    func testSetKeepsEverythingElse() {
        XCTAssertEqual(edit("# head\na: 1  # c\n\nb: 2\n") { e, r in e.set(r["a"]!, to: 5) },
                       "# head\na: 5  # c\n\nb: 2\n")
        XCTAssertEqual(edit("- 1\n- 2\n") { e, r in e.set(r[1]!, to: "x") }, "- 1\n- x\n")
        XCTAssertEqual(edit("a: [] # e\n") { e, r in e.set(r["a"]!, to: [:]) }, "a: {} # e\n")
    }

    func testStringSpellings() {
        let cases: [(String, String)] = [
            ("x y", "x y"), ("true", "'true'"), ("42", "'42'"), ("a: b", "'a: b'"), ("it's", "it's"),
            (" lead", "' lead'"), ("#x", "'#x'"), ("", "''"), ("é", "é"), ("tab\there", "'tab\there'"),
            ("\u{1}", "\"\\x01\""), ("x # y", "'x # y'"), ("- x", "'- x'"), ("null", "'null'"), ("[]", "'[]'"),
            ("trail ", "'trail '"), ("\u{2028}", "\"\\L\""), ("q\"", "q\""), ("cr\rx", "\"cr\\rx\""),
        ]
        for (text, spelling) in cases {
            XCTAssertEqual(edit("v: 1\n") { e, r in e.set(r["v"]!, to: .string(text)) }, "v: \(spelling)\n", text)
        }
        let double = YAMLStyle(quoting: .doubleQuoted)
        XCTAssertEqual(edit("v: 1\n", style: double) { e, r in e.set(r["v"]!, to: "x") }, "v: \"x\"\n")
    }

    func testOtherScalars() {
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: 1.5) }, "v: 1.5\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: .float(-.infinity)) }, "v: -.inf\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: .float(1e20)) }, "v: 1e+20\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: false) }, "v: false\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: nil) }, "v: null\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: -7) }, "v: -7\n")
        do {
            var e = YAMLEdits(try YAMLDocument(parsing: "v: x\n"))
            e.set(e.document.root["v"]!, to: .float(.nan))
            _ = try e.apply()
            XCTFail("NaN was written")
        } catch {
            XCTAssertEqual(error.errors.map(\.code), [.notANumber])
        }
    }

    func testMultiLineStrings() {
        // New text: double-quoted while short, a block from two line breaks or past 40 bytes.
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: "a\nb") }, "v: \"a\\nb\"\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: "a\nb\nc\n") }, "v: |\n  a\n  b\n  c\n")
        XCTAssertEqual(edit("v: x\nw: 1\n") { e, r in e.set(r["v"]!, to: "a\nb\nc") }, "v: |-\n  a\n  b\n  c\nw: 1\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: "a\n\n") }, "v: |+\n  a\n\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: "a\nb\n\n\n") }, "v: |+\n  a\n  b\n\n\n")
        XCTAssertEqual(edit("v: x\n") { e, r in e.set(r["v"]!, to: .string(String(repeating: "w", count: 40) + "\nz")) },
                       "v: |-\n  " + String(repeating: "w", count: 40) + "\n  z\n")
        // Parsed style is kept.
        XCTAssertEqual(edit("v: |\n  old\n  text\nw: 1\n") { e, r in e.set(r["v"]!, to: "a\nb") }, "v: |-\n  a\n  b\nw: 1\n")
        XCTAssertEqual(edit("v: \"x\"\n") { e, r in e.set(r["v"]!, to: "a\nb\nc\nd") }, "v: \"a\\nb\\nc\\nd\"\n")
        // A block cannot start with a space or hold a carriage return.
        XCTAssertEqual(edit("v: |\n  x\n") { e, r in e.set(r["v"]!, to: " a\nb\n") }, "v: \" a\\nb\\n\"\n")
        // A block scalar replaced by a single-line value.
        XCTAssertEqual(edit("v: | # c\n  t\n\n  u\nw: 1\n") { e, r in e.set(r["v"]!, to: "x") }, "v: x # c\nw: 1\n")
        let block = YAMLStyle(multiLine: .block)
        XCTAssertEqual(edit("v: x\n", style: block) { e, r in e.set(r["v"]!, to: "a\nb") }, "v: |-\n  a\n  b\n")
    }

    func testCollectionsReplaceScalarsAndBack() {
        XCTAssertEqual(edit("a: 1 # c\nb: 2\n") { e, r in e.set(r["a"]!, to: ["x": 1, "y": [true]]) },
                       "a: # c\n  x: 1\n  y:\n    - true\nb: 2\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set(r["a"]!, to: ["x", "y"]) }, "a:\n  - x\n  - y\n")
        XCTAssertEqual(edit("a:\n  x: 1\n  # inside\n  y: 2\n# after\nb: 2\n") { e, r in e.set(r["a"]!, to: "v") },
                       "a: v\n# after\nb: 2\n")
        XCTAssertEqual(edit("a: # c\n  x: 1\n") { e, r in e.set(r["a"]!, to: "v") }, "a: v # c\n")
        XCTAssertEqual(edit("a:\n  x: 1\n") { e, r in e.set(r["a"]!, to: "p\nq\nr\n") }, "a: |\n  p\n  q\n  r\n")
        XCTAssertEqual(edit("a:\n  x: 1\n") { e, r in e.set(r["a"]!, to: [1]) }, "a:\n  - 1\n")
        XCTAssertEqual(edit("- 1\n") { e, r in e.set(r[0]!, to: ["k": "v", "j": 2]) }, "- k: v\n  j: 2\n")
        XCTAssertEqual(edit("- a: 1\n  b: 2\n- x\n") { e, r in e.set(r[0]!, to: "y") }, "- y\n- x\n")
        XCTAssertEqual(edit("- a: 1\n") { e, r in e.set(r[0]!, to: [1, 2]) }, "-\n  - 1\n  - 2\n")
        XCTAssertEqual(edit("-\n  - 1\n- 2\n") { e, r in e.set(r[0]!, to: "z") }, "- z\n- 2\n")
    }

    func testRoot() {
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set(r, to: [1, 2]) }, "- 1\n- 2\n")
        XCTAssertEqual(edit("# head\nx\n") { e, r in e.set(r, to: ["k": "v"]) }, "# head\nk: v\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set(r, to: "s") }, "s\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set(r, to: "p\nq\nr\n") }, "|\n  p\n  q\n  r\n")
    }

    // MARK: Entries

    func testSetKeyInsertsOrReplaces() {
        XCTAssertEqual(edit("a: 1\nb: 2\n") { e, r in e.set("c", to: 3, in: r) }, "a: 1\nb: 2\nc: 3\n")
        XCTAssertEqual(edit("a: 1\nb: 2\n") { e, r in e.set("a", to: 9, in: r) }, "a: 9\nb: 2\n")
        XCTAssertEqual(edit("m:\n  x: 1\n# trailing\n") { e, r in e.set("y", to: 2, in: r["m"]!) },
                       "m:\n  x: 1\n  y: 2\n# trailing\n")
        XCTAssertEqual(edit("m: {}\n") { e, r in
            e.set("y", to: 2, in: r["m"]!)
            e.set("z", to: [1], in: r["m"]!)
        }, "m:\n  y: 2\n  z:\n    - 1\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set("1", to: "x", in: r) }, "a: 1\n'1': x\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set("k: x", to: "y", in: r) }, "a: 1\n'k: x': y\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in e.set("two words", to: "y", in: r) }, "a: 1\ntwo words: y\n")
        XCTAssertEqual(edit("- a: 1\n") { e, r in e.set("b", to: 2, in: r[0]!) }, "- a: 1\n  b: 2\n")
        XCTAssertEqual(edit("a: 1") { e, r in e.set("b", to: 2, in: r) }, "a: 1\nb: 2\n")
        XCTAssertEqual(edit("a: 1\r\n") { e, r in e.set("b", to: ["c": 1], in: r) }, "a: 1\r\nb:\r\n  c: 1\r\n")
    }

    func testRemoveKeepsCommentsOutside() {
        XCTAssertEqual(edit("a: 1  # c\n# about b\nb:\n  x: 1\n  # inner\n  y: 2\nc: 3\n") { e, r in e.remove("b", from: r) },
                       "a: 1  # c\n# about b\nc: 3\n")
        XCTAssertEqual(edit("a: 1\nb: |\n  t\n\nc: 3\n") { e, r in e.remove("b", from: r) }, "a: 1\n\nc: 3\n")
        XCTAssertEqual(edit("m:\n  x: 1\n") { e, r in e.remove("x", from: r["m"]!) }, "m: {}\n")
        XCTAssertEqual(edit("a: 1\nb: 2") { e, r in e.remove("b", from: r) }, "a: 1\n")
        XCTAssertEqual(edit("- a: 1\n  b: 2\n") { e, r in e.remove("a", from: r[0]!) }, "- b: 2\n")
        XCTAssertEqual(edit("- a: 1\n  b: 2\n  c: 3\n") { e, r in
            e.remove("a", from: r[0]!)
            e.remove("b", from: r[0]!)
        }, "- c: 3\n")
        XCTAssertEqual(edit("a: 1\n") { e, r in XCTAssertFalse(e.remove("zz", from: r)) }, "a: 1\n")
    }

    func testSortKeys() {
        XCTAssertEqual(edit("c: 3 # three\n# mid\nb:\n  z: 1\na: 1\n") { e, r in e.sortKeys(of: r) },
                       "a: 1\n# mid\nb:\n  z: 1\nc: 3 # three\n")
        XCTAssertEqual(edit("- b: 1\n  a: 2\n") { e, r in e.sortKeys(of: r[0]!) }, "- a: 2\n  b: 1\n")
        XCTAssertEqual(edit("a: 1\nb: 2\n") { e, r in e.sortKeys(of: r) }, "a: 1\nb: 2\n")
        XCTAssertEqual(edit("a: 1\nb: 2\n") { e, r in e.sortKeys(of: r, by: >) }, "b: 2\na: 1\n")
    }

    // MARK: Sequences

    func testSequences() {
        XCTAssertEqual(edit("s:\n  - a\n") { e, r in e.append("b", to: r["s"]!) }, "s:\n  - a\n  - b\n")
        XCTAssertEqual(edit("s: []\n") { e, r in e.append("a", to: r["s"]!) }, "s:\n  - a\n")
        XCTAssertEqual(edit("s:\n  - a\n") { e, r in e.append(["k": 1, "j": [true]], to: r["s"]!) },
                       "s:\n  - a\n  - k: 1\n    j:\n      - true\n")
        XCTAssertEqual(edit("- a\n- b # c\n- c\n") { e, r in e.remove(at: 1, from: r) }, "- a\n- c\n")
        XCTAssertEqual(edit("s:\n  - a\n") { e, r in e.remove(at: 0, from: r["s"]!) }, "s: []\n")
        XCTAssertEqual(edit("- a\n- b\n") { e, r in
            e.remove(at: 1, from: r)
            e.append("c", to: r)
        }, "- a\n- c\n")
        XCTAssertEqual(edit("-\n  - 1\n- 2\n") { e, r in e.remove(at: 0, from: r) }, "- 2\n")
    }

    func testRawReplacements() throws {
        let doc = try YAMLDocument(parsing: "a: 1\n")
        let edited = try doc.replacing([YAMLDocument.Replacement(ByteSpan(start: 3, end: 4), Array("22".utf8))])
        XCTAssertEqual(edited.root["a"]?.integer, 22)
        XCTAssertThrowsError(try doc.replacing([YAMLDocument.Replacement(ByteSpan(start: 3, end: 4), Array("[x]".utf8))]))
    }
}

// Random value trees written through the edit renderer, read back, then edited at random paths and compared
// with a model edited the same way.
final class EditPropertyTests: XCTestCase {
    private var rng = SplitMix64(seed: 0xED17)

    private func pick<T>(_ xs: [T]) -> T { xs[Int(rng.next() % UInt64(xs.count))] }

    private static let strings = ["x", "two words", "true", "Null", "42", "-1.5", ".inf", "a: b", "a #b", "#c", "it's",
                                  "\"q\"", " lead", "trail ", "", "é", "tab\tin", "- dash", "[x]", "{}", "|", ">",
                                  "a\nb", "a\nb\nc\n", "line\n\n", "\n", " x\ny\n", "back\\slash", "\u{1}", "cr\rlf",
                                  String(repeating: "long ", count: 10) + "\nend", "~", "0x10", "1_000", "@x", "%y"]
    private static let keys = ["a", "b", "key with space", "1", "true", "k: v", "#k", "é", "É", "''", "\"", "x-y", "-k"]

    private func value(_ depth: Int) -> YAMLValue {
        switch rng.next() % (depth > 2 ? 6 : 9) {
        case 0: return .integer(Int64(bitPattern: rng.next()) >> Int64(rng.next() % 64))
        case 1: return .float(Double(Int64(bitPattern: rng.next() % 2_000_000) - 1_000_000) / 64)
        case 2: return .boolean(rng.next() % 2 == 0)
        case 3: return .null
        case 4, 5: return .string(pick(Self.strings))
        case 6: return .sequence((0..<Int(rng.next() % 4)).map { _ in value(depth + 1) })
        default:
            var entries: [(key: String, value: YAMLValue)] = []
            for _ in 0..<Int(rng.next() % 4) {
                let k = pick(Self.keys)
                if !entries.contains(where: { $0.key.lowercased() == k.lowercased() }) { entries.append((k, value(depth + 1))) }
            }
            return .mapping(entries)
        }
    }

    private func model(_ n: YAMLNode) -> YAMLValue {
        switch n.kind {
        case .mapping: return .mapping(n.entries.map { (key: $0.key, value: model($0.value)) })
        case .sequence: return .sequence(n.items.map(model))
        case .string: return .string(n.string!)
        case .integer: return .integer(n.integer!)
        case .float: return .float(n.float!)
        case .boolean: return .boolean(n.boolean!)
        case .null: return .null
        }
    }

    private func same(_ a: YAMLValue, _ b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.integer(let x), .integer(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y
        case (.boolean(let x), .boolean(let y)): return x == y
        case (.null, .null): return true
        case (.sequence(let x), .sequence(let y)): return x.count == y.count && zip(x, y).allSatisfy(same)
        case (.mapping(let x), .mapping(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && same($0.value, $1.value) }
        default: return false
        }
    }

    // Every node with its path (keys and indexes from the root).
    private func nodes(_ n: YAMLNode, _ path: [Step] = []) -> [(YAMLNode, [Step])] {
        var out = [(n, path)]
        for e in n.entries { out += nodes(e.value, path + [.key(e.key)]) }
        for (k, item) in n.items.enumerated() { out += nodes(item, path + [.index(k)]) }
        return out
    }

    private enum Step { case key(String), index(Int) }

    // Applies `change` to the value at `path` in `v`.
    private func update(_ v: YAMLValue, _ path: ArraySlice<Step>, _ change: (YAMLValue) -> YAMLValue) -> YAMLValue {
        guard let step = path.first else { return change(v) }
        switch (v, step) {
        case (.mapping(var entries), .key(let k)):
            let i = entries.firstIndex { $0.key == k }!
            entries[i].value = update(entries[i].value, path.dropFirst(), change)
            return .mapping(entries)
        case (.sequence(var items), .index(let i)):
            items[i] = update(items[i], path.dropFirst(), change)
            return .sequence(items)
        default:
            preconditionFailure("bad path")
        }
    }

    func testRoundTripAndEdits() throws {
        var edited = 0
        for round in 0..<400 {
            let tree: YAMLValue = .mapping([(key: "root", value: value(0))])
            var e = YAMLEdits(try YAMLDocument(parsing: "x\n"))
            e.set(e.document.root, to: tree)
            var doc = try e.apply()
            XCTAssertTrue(same(model(doc.root), tree), "round \(round): \(String(decoding: doc.bytes, as: UTF8.self))")
            var expected = tree

            for _ in 0..<4 {
                let (target, path) = pick(nodes(doc.root))
                let before = String(decoding: doc.bytes, as: UTF8.self)
                var edits = YAMLEdits(doc)
                switch (target.kind, rng.next() % 3) {
                case (.mapping, 0) where target.count > 0:
                    let key = pick(Array(target.entries)).key
                    edits.remove(key, from: target)
                    expected = update(expected, path[...]) { v in
                        guard case .mapping(let es) = v else { return v }
                        return .mapping(es.filter { $0.key != key })
                    }
                case (.mapping, 1):
                    let key = pick(Self.keys), new = value(2)
                    let clash = target.entries.contains { $0.key != key && $0.key.lowercased() == key.lowercased() }
                    if clash { continue }
                    edits.set(key, to: new, in: target)
                    expected = update(expected, path[...]) { v in
                        guard case .mapping(var es) = v else { return v }
                        if let i = es.firstIndex(where: { $0.key == key }) { es[i].value = new } else { es.append((key, new)) }
                        return .mapping(es)
                    }
                case (.mapping, 2) where target.count > 1:
                    edits.sortKeys(of: target)
                    expected = update(expected, path[...]) { v in
                        guard case .mapping(let es) = v else { return v }
                        return .mapping(es.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element))
                    }
                case (.sequence, 0) where target.count > 0:
                    let i = Int(rng.next() % UInt64(target.count))
                    edits.remove(at: i, from: target)
                    expected = update(expected, path[...]) { v in
                        guard case .sequence(var items) = v else { return v }
                        items.remove(at: i)
                        return .sequence(items)
                    }
                case (.sequence, 1):
                    let new = value(2)
                    edits.append(new, to: target)
                    expected = update(expected, path[...]) { v in
                        guard case .sequence(let items) = v else { return v }
                        return .sequence(items + [new])
                    }
                default:
                    guard !path.isEmpty else { continue }
                    let new = value(1)
                    edits.set(target, to: new)
                    expected = update(expected, path[...]) { _ in new }
                }
                do {
                    doc = try edits.apply()
                } catch {
                    XCTFail("round \(round): \(error.errors.map(\.code)) editing\n\(before)")
                    return
                }
                edited += 1
                guard same(model(doc.root), expected) else {
                    XCTFail("round \(round): edit of\n\(before)\ngave\n\(String(decoding: doc.bytes, as: UTF8.self))")
                    return
                }
            }
        }
        XCTAssertGreaterThan(edited, 1000)
    }
}
