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
}
