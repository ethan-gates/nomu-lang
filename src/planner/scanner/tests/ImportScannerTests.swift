import XCTest
import Foundation
import ast
import embedded
import parse
import support
@testable import scanner

final class ImportScannerTests: XCTestCase {

    private func scan(_ source: String) -> FileImports { ImportScanner.scan(Array(source.utf8)) }

    // MARK: - Grammar

    func testImportForms() {
        let r = scan("""
            // header comment
            import pkg/util/parse
            import std
            public import net/http as web
            test import pkg/core

            fun main() {}
            """)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.imports.count, 4)
        XCTAssertEqual(r.imports[0].root, .pkg)
        XCTAssertEqual(r.imports[0].path, ["util", "parse"])
        XCTAssertEqual(r.imports[1].root, .package("std"))
        XCTAssertEqual(r.imports[1].path, [])
        XCTAssertEqual(r.imports[2].root, .package("net"))
        XCTAssertEqual(r.imports[2].alias, "web")
        XCTAssertTrue(r.imports[2].isPublic)
        XCTAssertTrue(r.imports[3].isTest)
        XCTAssertFalse(r.imports[3].isPublic)
    }

    func testLocations() {
        let r = scan("// c\n  import pkg/a as b\n")
        let imp = r.imports[0]
        XCTAssertEqual(imp.start, SourceLocation(offset: 7, line: 2, column: 3))
        XCTAssertEqual(imp.end, SourceLocation(offset: 24, line: 2, column: 20))
    }

    func testStopsAtFirstDeclaration() {
        // `public` and `test` are a prefix only before `import`; a later `import` is the parser's error.
        let r = scan("import a\npublic fun f() {}\nimport b\n")
        XCTAssertEqual(r.imports.map(\.root), [.package("a")])
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(scan("test struct S {}\n").imports, [])
        XCTAssertEqual(scan("fun main() {}\n").imports, [])
        XCTAssertEqual(scan("").imports, [])
    }

    func testWhitespaceAroundSlash() {
        XCTAssertEqual(scan("import a / b /c\n").imports.first?.path, ["b", "c"])
    }

    func testMalformedImportsReportAndStop() {
        let missing = scan("import\nfun main() {}\n")
        XCTAssertEqual(missing.imports, [])
        XCTAssertEqual(missing.errors.first?.message, "expected a name after 'import', got keyword 'fun'")
        // Reported just past `import`, on the import's own line.
        XCTAssertEqual(missing.errors.first?.location.line, 1)
        XCTAssertEqual(missing.errors.first?.location.column, 7)

        let slash = scan("import a/\n")
        XCTAssertEqual(slash.errors.first?.message, "expected a name after '/'")

        let alias = scan("import a as 3\nimport b\n")
        XCTAssertEqual(alias.errors.first?.message, "expected a name after 'as'")
        XCTAssertEqual(alias.imports, [])
    }

    // MARK: - Reading only the header

    private func withTempFile(_ contents: String, _ body: (String) throws -> Void) rethrows {
        let path = NSTemporaryDirectory() + "scan-\(UUID().uuidString).nomu"
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    func testHeaderLongerThanFirstRead() throws {
        let pad = String(repeating: "// padding padding padding padding padding padding padding\n", count: 200)
        try withTempFile(pad + "import pkg/late\nfun main() {}\n") { path in
            let r = try ImportScanner.scan(path: path)
            XCTAssertEqual(r.imports.map(\.path), [["late"]])
        }
    }

    // Every split point around the first read's boundary, so a token or comment straddles it.
    func testTokensStraddlingReadBoundary() throws {
        let n = ImportScanner.initialReadSize
        for shift in -24 ... 24 {
            let lead = String(repeating: " ", count: max(0, n + shift - 7))
            let source = lead + "import alpha/beta as gamma // trailing\nimport pkg/delta\nfun main() {}\n"
            try withTempFile(source) { path in
                let r = try ImportScanner.scan(path: path)
                XCTAssertEqual(r, scan(source), "shift \(shift)")
                XCTAssertEqual(r.imports.count, 2, "shift \(shift)")
            }
        }
    }

    // A multi-byte character in a header comment, split at every byte across the first read's boundary.
    func testMultiByteCommentStraddlingReadBoundary() throws {
        let n = ImportScanner.initialReadSize
        for shift in -8 ... 8 {
            let lead = String(repeating: " ", count: n + shift - 3)
            let source = lead + "// 🎉日本é\nimport pkg/after\nfun main() {}\n"
            try withTempFile(source) { path in
                let r = try ImportScanner.scan(path: path)
                XCTAssertEqual(r, scan(source), "shift \(shift)")
                XCTAssertEqual(r.imports.map(\.path), [["after"]], "shift \(shift)")
            }
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try ImportScanner.scan(path: "/nonexistent/x.nomu"))
    }

    // MARK: - Conformance with the parser

    // The parser's imports for a file, or nil when the file doesn't parse cleanly (the scanner's behavior on
    // malformed files is covered above).
    private func parsedImports(_ source: String, file: String) -> [ImportDecl]? {
        let diags = DiagnosticSink()
        var lexer = Lexer(source, file: file, diagnostics: diags)
        var parser = Parser(lexer.tokenize(), diagnostics: diags)
        let program = parser.parse()
        return diags.hasErrors ? nil : program.imports
    }

    private func assertConforms(_ scanned: FileImports, _ parsed: [ImportDecl], _ file: String) {
        XCTAssertEqual(scanned.errors, [], file)
        XCTAssertEqual(scanned.imports.count, parsed.count, file)
        for (s, p) in zip(scanned.imports, parsed) {
            switch (s.root, p.root) {
            case (.pkg, .pkg): break
            case (.package(let a), .package_(let b)): XCTAssertEqual(a, b, file)
            default: XCTFail("root mismatch in \(file)")
            }
            XCTAssertEqual(s.path, p.path, file)
            XCTAssertEqual(s.alias, p.alias, file)
            XCTAssertEqual(s.isPublic, p.isPublic, file)
            XCTAssertEqual(s.isTest, p.isTest, file)
            XCTAssertEqual(s.start.offset, p.span.startOffset, file)
            XCTAssertEqual(s.end.offset, p.span.endOffset, file)
            XCTAssertEqual(s.start.line, p.span.begin.line, file)
            XCTAssertEqual(s.start.column, p.span.begin.col, file)
        }
    }

    // UTF-8 in header comments (1- to 4-byte sequences), before, between and after imports. Offsets and
    // columns are bytes in both the scanner and the parser.
    func testConformsOnUTF8Comments() {
        let source = """
            // Copyright © 2026 — Nomu 日本語 🎉
            import std // naïve trailing comment ✓
            // 🎉🎉 between
              import pkg/util as u_free // 中文
            fun main() {}
            """
        guard let parsed = parsedImports(source, file: "utf8") else { return XCTFail("does not parse") }
        let scanned = scan(source)
        XCTAssertEqual(scanned.imports.count, 2)
        assertConforms(scanned, parsed, "utf8")
    }

    // Identifiers are ASCII; a non-ASCII character outside a comment stops the scan with the lexer's error,
    // at the lexer's position.
    func testNonASCIIOutsideCommentsMatchesLexer() {
        for source in ["import café\n", "import a/日本\n", "import a as b€\nimport c\n", "// ok é\n🎉\nimport a\n",
                       "import a\ntest é\n"] {
            let diags = DiagnosticSink()
            var lexer = Lexer(source, file: "t", diagnostics: diags)
            _ = lexer.tokenize()
            guard let lexed = diags.diagnostics.first else { XCTFail("lexer accepted \(source)"); continue }
            let scanned = scan(source)
            XCTAssertEqual(scanned.errors.count, 1, source)
            XCTAssertEqual(scanned.errors.first?.message, lexed.message, source)
            XCTAssertEqual(scanned.errors.first?.location.offset, lexed.span.startOffset, source)
        }
        XCTAssertEqual(scan("import a as b€\nimport c\n").imports.map(\.root), [.package("a")])
        XCTAssertEqual(scan("import café\n").imports, [])
    }

    // Malformed import headers: the scanner and the parser reject each one with the same message at the same
    // position (just past the token that wants a name). The planner reports the scanner's error, so this is
    // what a user sees; the parser must agree for files that reach it another way.
    func testMalformedHeadersMatchParser() {
        let sources = [
            "import a/",
            "import a/\n\nfun main() {}\n",
            "import a as\nfun main() {}\n",
            "import fun\n",
            "import\n",
            "public import\nfun main() {}\n",
            "test import a/true\n",
            "import a as 3\nimport b\n",
            "import a/ /b\n",
            "import pkg/{\n",
        ]
        for source in sources {
            let diags = DiagnosticSink()
            var lexer = Lexer(source, file: "t", diagnostics: diags)
            var parser = Parser(lexer.tokenize(), diagnostics: diags)
            _ = parser.parse()
            guard let parsed = diags.diagnostics.first else { XCTFail("parser accepted \(source)"); continue }
            let scanned = scan(source)
            XCTAssertEqual(scanned.errors.count, 1, source)
            XCTAssertEqual(scanned.errors.first?.message, parsed.message, source)
            XCTAssertEqual(scanned.errors.first?.location.offset, parsed.span.startOffset, source)
            XCTAssertEqual(scanned.errors.first?.location.line, parsed.span.begin.line, source)
            XCTAssertEqual(scanned.errors.first?.location.column, parsed.span.begin.col, source)
            XCTAssertEqual(scanned.errors.first?.location.line, 1, source)
        }
    }

    // The suite's fixtures and examples, through runfiles.
    func testConformsOnCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let srcdir = env["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        let root = srcdir + "/_main"
        var checked = 0
        for dir in ["tests/fixtures", "examples"] {
            guard let walk = FileManager.default.enumerator(atPath: root + "/" + dir) else { continue }
            for case let rel as String in walk where rel.hasSuffix(".nomu") {
                let path = root + "/" + dir + "/" + rel
                let source = try String(contentsOfFile: path, encoding: .utf8)
                guard let parsed = parsedImports(source, file: path) else { continue }
                assertConforms(try ImportScanner.scan(path: path), parsed, path)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    // The language workspace's sources, which the compiler carries (`core`, `runtime`, `std`).
    func testConformsOnEmbeddedSources() {
        var sources = [(EmbeddedSources.preludeName, EmbeddedSources.preludeSource),
                       (EmbeddedSources.runtimePreludeName, EmbeddedSources.runtimePreludeSource)]
        sources += EmbeddedSources.stdModules.map { ("std/\($0.module)/\($0.name)", $0.source) }
        for (name, source) in sources {
            guard let parsed = parsedImports(source, file: name) else { XCTFail("\(name) does not parse"); continue }
            assertConforms(ImportScanner.scan(Array(source.utf8)), parsed, name)
        }
    }
}
