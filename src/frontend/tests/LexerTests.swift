import XCTest
import frontend

final class LexerTests: XCTestCase {

    private func lex(_ source: String) -> [TokenKind] {
        var lexer = Lexer(source)
        return lexer.tokenize().map(\.kind)
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
}
