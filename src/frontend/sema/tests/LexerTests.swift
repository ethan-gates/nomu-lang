import parse
import noir
import ast
import support
import XCTest
import sema

final class LexerTests: XCTestCase {

    private func lex(_ source: String) -> [TokenKind] {
        var lexer = Lexer(source)
        return lexer.tokenize().map(\.kind)
    }

    // A file's reported path (`displayName`) is what diagnostics print; its identity (`file`) is what spans
    // compare.
    func testDiagnosticsReportTheDisplayName() {
        let diags = DiagnosticSink()
        var lexer = Lexer("import café\n", file: "<nomu>/std/x/x.nomu", displayName: "/cache/source/std/x/x.nomu",
                          diagnostics: diags)
        let tokens = lexer.tokenize()
        XCTAssertEqual(tokens.first?.span.file, "<nomu>/std/x/x.nomu")
        XCTAssertTrue(diags.render().hasPrefix("/cache/source/std/x/x.nomu:1:11: error:"), diags.render())
    }

    func testKeywords() {
        let kinds = lex("struct enum class actor fun let var on spawn switch case return if else")
        XCTAssertEqual(kinds, [
            .kwStruct, .kwEnum, .kwClass, .kwActor,
            .kwFunc, .kwLet, .kwVar,
            .kwOn, .kwSpawn,
            .kwSwitch, .kwCase, .kwReturn,
            .kwIf, .kwElse, .eof,
        ])
    }

    func testIntLiteral() {
        XCTAssertEqual(lex("42"), [.intLit(42), .eof])
    }

    func testBoolLiterals() {
        XCTAssertEqual(lex("true false"), [.boolLit(true), .boolLit(false), .eof])
    }

    func testPunctuation() {
        XCTAssertEqual(lex("{ } ( ) : . ,"), [
            .lBrace, .rBrace, .lParen, .rParen, .colon, .dot, .comma, .eof,
        ])
    }

    func testOperators() {
        XCTAssertEqual(lex("= += -> + - * /"), [
            .eq, .plusEq, .arrow, .plus, .minus, .star, .slash, .eof,
        ])
        XCTAssertEqual(lex("== != < > <= >="), [
            .eqEq, .bangEq, .lt, .gt, .ltEq, .gtEq, .eof,
        ])
    }

    func testLineComment() {
        XCTAssertEqual(lex("42 // ignored\n99"), [.intLit(42), .intLit(99), .eof])
    }

    func testStructDecl() {
        let kinds = lex("struct Point { var x: Int var y: Int }")
        XCTAssertEqual(kinds, [
            .kwStruct, .ident("Point"), .lBrace,
            .kwVar, .ident("x"), .colon, .ident("Int"),
            .kwVar, .ident("y"), .colon, .ident("Int"),
            .rBrace, .eof,
        ])
    }

    func testEnumCase() {
        let kinds = lex("case .circle(let r)")
        XCTAssertEqual(kinds, [
            .kwCase, .dot, .ident("circle"), .lParen, .kwLet, .ident("r"), .rParen, .eof,
        ])
    }

    func testActorMethodCall() {
        // Actor calls are plain method-call syntax — no send/join keywords.
        let kinds = lex("c.bump(by: p)")
        XCTAssertEqual(kinds, [
            .ident("c"), .dot, .ident("bump"),
            .lParen, .ident("by"), .colon, .ident("p"), .rParen, .eof,
        ])
    }

    func testTokenSpans() {
        // "ab" on line 1 (cols 1..3), "cd" on line 2 after two spaces (cols 3..5).
        // Spans are half-open [begin, end): end col is one past the last char.
        var lexer = Lexer("ab\n  cd", file: "t.nomu")
        let toks = lexer.tokenize()
        // Spans carry byte offsets; line/column/file resolve lazily through the SourceMap.
        XCTAssertEqual(toks[0].span.file, "t.nomu")
        XCTAssertEqual(toks[0].span.begin.line, 1); XCTAssertEqual(toks[0].span.begin.col, 1)
        XCTAssertEqual(toks[0].span.end.line, 1);   XCTAssertEqual(toks[0].span.end.col, 3)
        XCTAssertEqual(toks[1].span.begin.line, 2); XCTAssertEqual(toks[1].span.begin.col, 3)
        XCTAssertEqual(toks[1].span.end.line, 2);   XCTAssertEqual(toks[1].span.end.col, 5)
        XCTAssertEqual(toks[2].kind, .eof)
    }

    // An unexpected character is reported and skipped; lexing continues (no crash),
    // so the surrounding tokens still come through.
    func testUnexpectedCharacterIsSkipped() {
        let diags = DiagnosticSink()
        var lexer = Lexer("a # b", diagnostics: diags)
        let kinds = lexer.tokenize().map(\.kind)
        XCTAssertTrue(diags.hasErrors)
        XCTAssertEqual(kinds, [.ident("a"), .ident("b"), .eof])
    }

    // An unterminated string reports and returns what it read, up to EOF.
    func testUnterminatedStringRecovers() {
        let diags = DiagnosticSink()
        var lexer = Lexer("\"hello", diagnostics: diags)
        let kinds = lexer.tokenize().map(\.kind)
        XCTAssertTrue(diags.hasErrors)
        XCTAssertEqual(kinds, [.stringLit("hello"), .eof])
    }

    // A triple-quoted block literal strips the closing delimiter's indentation from each line and drops the
    // newlines adjacent to the delimiters: `"""⏎    a⏎    b⏎    """` → `"a\nb"`.
    func testBlockStringStripsIndent() {
        XCTAssertEqual(lex("\"\"\"\n    a\n    b\n    \"\"\""), [.stringLit("a\nb"), .eof])
    }

    // Inside a block literal a bare `"` needs no escape, and `\t`/`\n` escapes still apply; indentation is
    // stripped to the closing delimiter's column.
    func testBlockStringEscapesAndBareQuotes() {
        XCTAssertEqual(lex("\"\"\"\n  a \"q\" b\n  c\\td\n  \"\"\""),
                       [.stringLit("a \"q\" b\nc\td"), .eof])
    }

    // A blank content line survives as an empty line (no indentation to strip).
    func testBlockStringBlankLine() {
        XCTAssertEqual(lex("\"\"\"\n  a\n\n  b\n  \"\"\""), [.stringLit("a\n\nb"), .eof])
    }

    // A block literal with no closing `"""` reports and recovers.
    func testBlockStringUnterminatedRecovers() {
        let diags = DiagnosticSink()
        var lexer = Lexer("\"\"\"\n  hi\n", diagnostics: diags)
        _ = lexer.tokenize()
        XCTAssertTrue(diags.hasErrors)
    }
}
