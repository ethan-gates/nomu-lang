import XCTest
import frontend

// Error recovery: the parser reports into a sink and keeps going, never exiting, and
// yields a usable AST from broken input (the no-crash contract — frontend/README.md P0).
final class ParserRecoveryTests: XCTestCase {

    // Parse, returning both the tree and the collected diagnostics.
    private func parse(_ source: String) -> (Program, DiagnosticSink) {
        let diags = DiagnosticSink()
        var lexer = Lexer(source, diagnostics: diags)
        var parser = Parser(lexer.tokenize(), diagnostics: diags)
        return (parser.parse(), diags)
    }

    func testGarbageTopLevelTokenIsSkippedToNextDecl() {
        // `let a = 1` is not a declaration; recovery skips it and still parses `Point`.
        let (p, diags) = parse("let a = 1\nstruct Point { var x: Int }")
        XCTAssertTrue(diags.hasErrors)
        let names = p.decls.compactMap { decl -> String? in
            if case .structDecl(let s) = decl { return s.name }
            return nil
        }
        XCTAssertEqual(names, ["Point"])
    }

    func testBadMemberDoesNotDropLaterMembers() {
        // `var x Int` is missing its colon; the field still recovers and `y` follows.
        let (p, diags) = parse("""
        struct P {
            var x Int
            var y: Int
        }
        """)
        XCTAssertTrue(diags.hasErrors)
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.fields.map(\.name), ["x", "y"])
    }

    func testErrorsInSeparateDeclsAreAllReported() {
        // Two independent broken constructs → two diagnostics (parsing continues past each),
        // and the valid declaration between them survives.
        let (p, diags) = parse("""
        let a = 1
        struct Good { var x: Int }
        return 5
        """)
        XCTAssertGreaterThanOrEqual(diags.diagnostics.count, 2)
        let names = p.decls.compactMap { decl -> String? in
            if case .structDecl(let s) = decl { return s.name }
            return nil
        }
        XCTAssertEqual(names, ["Good"])
    }

    func testUnexpectedTokenInExpressionYieldsErrorNode() {
        // A statement position with no valid expression recovers to an `.error` node.
        let (p, diags) = parse("fun f() { let x = }")
        XCTAssertTrue(diags.hasErrors)
        guard case .funcDecl(let f) = p.decls[0],
              case .binding(let b) = f.body[0],
              case .error = b.value else { XCTFail(); return }
        XCTAssertEqual(b.name, "x")
    }

    func testPureGarbageDoesNotCrashAndReportsErrors() {
        // The point is that this returns at all (no exit/crash) with diagnostics collected.
        let (_, diags) = parse("}{ )( : > , struct")
        XCTAssertTrue(diags.hasErrors)
    }
}
