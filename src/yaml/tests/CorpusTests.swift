import Foundation
import XCTest
import yaml

// The equivalence corpus (`tests/corpus`, spec §26 "YAML semantic compatibility"). Each accepted document has
// the value a YAML 1.2 Core parser gives it, written by hand from the spec as an indented tree: `map` and `seq`
// (or `map {}` and `seq []`), entries as `"key": value`, items as `- value`, and scalars as `int 42`,
// `float 1.5`, `str "text"`, `bool true` or `null`, so `42`, `42.0` and `"42"` differ. Strings and keys are
// written with JSON escapes. Each rejected document lists every error the parse reports, as `line code`.
final class CorpusTests: XCTestCase {
    private func corpus(_ kind: String) throws -> (String, [String]) {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        let dir = srcdir + "/_main/src/yaml/tests/corpus/" + kind
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".yaml") }.map { String($0.dropLast(5)) }.sorted()
        return (dir, names)
    }

    private func read(_ path: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: path) ?? Data()) }

    func testAcceptedDocumentsHaveTheirCoreValues() throws {
        let (dir, names) = try corpus("accept")
        XCTAssertGreaterThan(names.count, 30)
        for name in names {
            let expected = String(decoding: read("\(dir)/\(name).expected"), as: UTF8.self)
            do {
                let doc = try YAMLDocument(parsing: read("\(dir)/\(name).yaml"))
                var lines: [String] = []
                CorpusTests.render(doc.root, "", "", &lines)
                XCTAssertEqual(lines.joined(separator: "\n") + "\n", expected, name)
            } catch {
                XCTFail("\(name): \(error.errors.map(\.code))")
            }
        }
    }

    func testRejectedDocumentsReportTheirErrors() throws {
        let (dir, names) = try corpus("reject")
        XCTAssertGreaterThan(names.count, 50)
        for name in names {
            let expected = String(decoding: read("\(dir)/\(name).errors"), as: UTF8.self)
            do {
                _ = try YAMLDocument(parsing: read("\(dir)/\(name).yaml"))
                XCTFail("\(name): accepted")
            } catch {
                let doc = read("\(dir)/\(name).yaml")
                let actual = error.errors.map { "\(CorpusTests.line(doc, $0.span.start)) \($0.code)" }
                XCTAssertEqual(actual.joined(separator: "\n") + "\n", expected, name)
            }
        }
    }

    // The 1-based line holding byte `offset`.
    private static func line(_ bytes: [UInt8], _ offset: UInt32) -> Int {
        bytes[..<min(Int(offset), bytes.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    private static func render(_ n: YAMLNode, _ prefix: String, _ indent: String, _ lines: inout [String]) {
        let head: String
        switch n.kind {
        case .mapping: head = n.count == 0 ? "map {}" : "map"
        case .sequence: head = n.count == 0 ? "seq []" : "seq"
        case .string: head = "str " + quote(n.string!)
        case .integer: head = "int \(n.integer!)"
        case .float: head = "float \(n.float!)"
        case .boolean: head = "bool \(n.boolean!)"
        case .null: head = "null"
        }
        lines.append(indent + prefix + head)
        let inner = prefix.isEmpty && indent.isEmpty ? "  " : indent + "  "
        for e in n.entries { render(e.value, quote(e.key) + ": ", inner, &lines) }
        for item in n.items { render(item, "- ", inner, &lines) }
    }

    // JSON escapes: `\"`, `\\`, `\n`, `\t`, and `\uXXXX` for other controls, U+0085, U+00A0, U+2028 and U+2029.
    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0..<0x20, 0x7F...0xA0, 0x2028, 0x2029, 0xFEFF:
                let hex = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
