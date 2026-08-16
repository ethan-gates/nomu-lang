import parse
import noir
import ast
import support
import XCTest
import sema

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

    // The following inputs once hung the parser: a loop whose sub-parser consumed no token and
    // whose recovery set already held the offending token, so neither made progress. Each must
    // now *terminate* (if it regresses, the test run hangs) and report the error. The
    // progress-guard (`if pos == before { advance() }`) in every such loop is what guarantees it.

    func testMissingParamParensTerminates() {
        // `fun main {` — no `()`; recovery once spun in the function-type parameter loop.
        let (_, diags) = parse("fun main {\n  print(2 + 3)\n}")
        XCTAssertTrue(diags.hasErrors)
    }

    func testStrayMemberBoundaryTokenTerminates() {
        // `on`/`case` are member introducers for *other* body kinds, so they sit in the member
        // recovery set; encountering one in a struct/actor body must not spin.
        for src in ["struct S { on x }", "struct S { case y }", "actor A { case z }",
                    "interface I { on q }"] {
            let (_, diags) = parse(src)
            XCTAssertTrue(diags.hasErrors, "expected errors for \(src)")
        }
    }

    func testFunctionTypeWithNonTypeTokenTerminates() {
        // A literal where a type is expected inside a function type `( … )` consumed nothing.
        let (_, diags) = parse("fun f(g: (2) -> Int) {}")
        XCTAssertTrue(diags.hasErrors)
    }
}
