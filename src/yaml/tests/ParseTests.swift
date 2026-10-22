import XCTest
@testable import yaml

// Checks the parser against the diagnostic path on `bytes`: it accepts exactly the documents the diagnostic
// path accepts, with identical records, nodes and types. The Lex, Structure and Resolve tests call this on
// every document they build, valid or not.
func assertPathsAgree(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
    let v = validate(bytes)
    guard let source = v.source else { return }
    let l = lexLines(bytes, source, errors: v.errors)
    let s = buildStructure(bytes, l)
    let r = resolveScalars(bytes, l, s)
    let parsed = v.errors.isEmpty ? bytes.withUnsafeBufferPointer { parse($0, source) } : nil
    let text = String(decoding: bytes, as: UTF8.self).debugDescription
    guard r.errors.isEmpty else {
        XCTAssertNil(parsed, "the parser accepted an invalid document \(text)", file: file, line: line)
        return
    }
    guard let parsed else {
        XCTFail("the parser stopped on a valid document \(text)", file: file, line: line)
        return
    }
    XCTAssertEqual(parsed.records, l.records.lines, "records of \(text)", file: file, line: line)
    XCTAssertEqual(parsed.arena, s.arena, "nodes of \(text)", file: file, line: line)
    XCTAssertEqual(parsed.types, r.types, "types of \(text)", file: file, line: line)
    XCTAssertEqual(Set(parsed.keyTables.keys), Set(s.keyTables.keys), "key tables of \(text)", file: file, line: line)
}

final class ParseTests: XCTestCase {
    // Documents built line by line from a model of the open collections, so most are valid, with mutations
    // (rejected spellings, bad spacing, tabs, odd indentation, duplicate keys) now and then, so every decline is
    // exercised too. The count of valid ones guards against a generator that only makes errors.
    func testGeneratedDocumentsAgree() {
        var rng = SplitMix64(seed: 0xFA57)
        func pick<T>(_ xs: [T]) -> T { xs[Int(rng.next() % UInt64(xs.count))] }
        func chance(_ n: UInt64) -> Bool { rng.next() % n == 0 }

        let goodKeys = ["a", "name", "key with space", "\"q\"", "'s''q'", "\"e\\u00e9\"", "\"\"", "é", "x-y",
                        "k:x", "über", "-x", "\"1\"", "a b", "trueish"]
        let badKeys = ["true", "1", "\"a\\q\"", "Null", "+1", ".5"]
        let goodValues = ["x", "42", "-7", "001", "1.5", "-.5", ".inf", "true", "false", "null", "fast", "nullable",
                          "\"s\"", "\"\\t\\u263A\"", "'it''s'", "[]", "{}", "12:30", "a #c", "a # c", "\"x\" # c",
                          "café", "-0", "trueish", "0o7", "-x", "?x", ":x", "a:b", "1e5", "0x", "9223372036854775807"]
        let badValues = ["True", "NULL", "~", "0x1", "1_0", "+1", ".Inf", "\"bad\\q\"", "[1]", "a: b", "-", "|2",
                         "&a", "*a", "!t", "@x", "`x", "%x", "? x", ": x", "99999999999999999999", "1e400", "\"open"]
        var valid = 0
        for _ in 0..<8000 {
            var lines: [String] = []
            // The kind of the collection open at each level (true for a sequence); empty before the root.
            var kinds: [Bool] = []
            var owed = false        // the last line owes a value one level deeper
            var used: [Set<String>] = []
            var serial = 0
            if chance(8) { lines.append("---" + (chance(3) ? " # start" : "")) }
            for _ in 0..<Int(rng.next() % 16) + 1 {
                if chance(9) { lines.append(pick(["", "# comment", "  # indented", "#\tx"])) }
                var level: Int
                if owed || kinds.isEmpty {
                    level = kinds.count
                    kinds.append(chance(3))
                    used.append([])
                } else {
                    level = Int(rng.next() % UInt64(kinds.count))
                    kinds.removeLast(kinds.count - level - 1)
                    used.removeLast(used.count - level - 1)
                }
                if chance(60) { level += 1 }                                  // an indentation jump
                let sequence = kinds[min(level, kinds.count - 1)]
                var text = String(repeating: " ", count: level * 2 + (chance(80) ? 1 : 0))
                var hasKey = !sequence
                if sequence {
                    text += chance(50) ? "-  " : "- "
                    if chance(3) {                                            // `- key: value` opens a mapping
                        hasKey = true
                        kinds.append(false)
                        used.append([])
                    }
                }
                var key = ""
                if hasKey {
                    key = chance(25) ? pick(badKeys) : pick(goodKeys)
                    serial += 1
                    if !chance(30) { key = key.hasPrefix("\"") || key.hasPrefix("'") ? key : key + "\(serial)" }
                    text += key + (chance(60) ? " :" : ":")
                }
                owed = chance(4)
                if owed {
                    if !hasKey { text = String(text.dropLast()) }              // a bare `-`
                    if chance(5) { text += pick([" # owes", "  # owes"]) }
                } else {
                    let value = chance(12) ? pick(badValues) : pick(goodValues)
                    text += (hasKey ? (chance(60) ? "  " : " ") : "") + value
                    if chance(6) { text += pick(["  # c", " # c", "\t# c"]) }
                    if chance(15), hasKey {
                        text = String(text.prefix(text.count - value.count)) + pick(["|", "|-", ">", ">+"])
                        let depth = level * 2 + (sequence ? 4 : 2)
                        for _ in 0..<Int(rng.next() % 3) + (chance(10) ? 0 : 1) {
                            lines.append(text)
                            text = chance(5) ? "" : String(repeating: " ", count: depth) + pick(["text", "  more", "#x", "a: b", "t\ta"])
                        }
                    }
                }
                if chance(80) { text += " " }
                lines.append(text)
            }
            if chance(10) { lines.append(pick(["...", "... # end", "---"])) }
            let ending = chance(10) ? "\r\n" : "\n"
            let text = lines.joined(separator: ending) + (chance(10) ? "" : ending)
            let bytes = (chance(20) ? [0xEF, 0xBB, 0xBF] : []) + Array(text.utf8)
            assertPathsAgree(bytes)
            let v = validate(bytes)
            if let source = v.source, v.errors.isEmpty {
                let l = lexLines(bytes, source, errors: YAMLErrors())
                if resolveScalars(bytes, l, buildStructure(bytes, l)).errors.isEmpty { valid += 1 }
            }
        }
        XCTAssertGreaterThan(valid, 1000)
    }

    // Large mappings index their keys; the parser must build the same tables.
    func testLargeMappingsAgree() {
        var text = ""
        for k in 0..<40 { text += "k\(k):\n  - v\n  - n\(k): \(k)\n" }
        text += "dup:\n" + (0..<40).map { "  \"x\($0)\": 1\n" }.joined() + "  X0: 2\n"
        assertPathsAgree(Array(text.utf8))
        assertPathsAgree(Array(text.replacingOccurrences(of: "  X0: 2\n", with: "  zz: 2\n").utf8))
    }

    func testDocumentParses() throws {
        let doc = try YAMLDocument(parsing: "a:\n  - 1\n  - \"two\"\nb: |\n  text\n")
        XCTAssertEqual(doc.root["a"]?[1]?.string, "two")
        XCTAssertEqual(doc.root["b"]?.string, "text\n")
    }
}
