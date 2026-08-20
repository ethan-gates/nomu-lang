import parse
import noir
import ast
import support
import XCTest
import sema

// Bitwise / shift / unary operators and the UInt8 type (operator-surface + byte slice).
final class BitwiseTests: XCTestCase {

    private func parse(_ source: String) -> Program {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        return parser.parse()
    }

    private func sema(_ source: String) -> SemaResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        let merged = mergeExtensions(parser.parse(), into: DiagnosticSink())
        var s = Sema(merged)
        return s.check()
    }

    // The single expression of a one-statement function body.
    private func bodyExpr(_ src: String) -> NOIRExpr? {
        let r = sema(src)
        guard !r.diagnostics.hasErrors else { XCTFail(r.diagnostics.render()); return nil }
        guard case .funcDecl(let f) = r.module.decls.last,
              case .ret(let e?) = f.body.last?.kind else { XCTFail("no return expr"); return nil }
        return e
    }

    // MARK: - Parsing / precedence

    func testBitwiseAndParses() {
        let p = parse("fun f() -> Int { return 6 & 3 }")
        guard case .funcDecl(let f) = p.decls[0], case .ret(let e?, _) = f.body[0],
              case .binary(let op, _, _, _) = e else { XCTFail(); return }
        XCTAssertEqual(op, .bitAnd)
    }

    func testShiftLexesFromTwoAngles() {
        let p = parse("fun f() -> Int { return 1 << 4 }")
        guard case .funcDecl(let f) = p.decls[0], case .ret(let e?, _) = f.body[0],
              case .binary(let op, _, _, _) = e else { XCTFail(); return }
        XCTAssertEqual(op, .shl)
    }

    // Bitwise binds tighter than comparison (Go-style): `a & b == c` is `(a & b) == c`.
    func testBitwiseBindsTighterThanComparison() {
        let p = parse("fun f() -> Bool { return 6 & 3 == 2 }")
        guard case .funcDecl(let f) = p.decls[0], case .ret(let e?, _) = f.body[0],
              case .binary(let top, let l, _, _) = e else { XCTFail(); return }
        XCTAssertEqual(top, .eq)                 // the comparison is the root
        guard case .binary(.bitAnd, _, _, _) = l else { XCTFail("lhs should be the & expr"); return }
    }

    // `>>` as a shift must not disturb nested generic close (`Box<Box<Int>>` still parses).
    func testNestedGenericStillParses() {
        let r = sema("""
        struct Box<T> { var v: T }
        fun f(b: Box<Box<Int>>) -> Box<Int> { return b.v }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testUnaryParses() {
        let p = parse("fun f() -> Int { return -x }")
        guard case .funcDecl(let f) = p.decls[0], case .ret(let e?, _) = f.body[0],
              case .unary(let op, _, _) = e else { XCTFail(); return }
        XCTAssertEqual(op, .neg)
    }

    // MARK: - Sema: types

    func testBitwiseOnIntYieldsInt() {
        guard let e = bodyExpr("fun f() -> Int { return 12 | 3 }") else { return }
        XCTAssertEqual(e.type, .int)
    }

    func testBitwiseRejectsDouble() {
        let r = sema("fun f() -> Double { return 1.0 & 2.0 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("Int or UInt8"), r.diagnostics.render())
    }

    // `-x`, `!x`, `~x` lower to binary forms in Sema (no unary node reaches NOIR).
    func testUnaryNegLowersToSub() {
        guard let e = bodyExpr("fun f() -> Int { return -5 }") else { return }
        guard case .binary(.sub, _, _) = e.kind else { XCTFail("neg should be 0 - x"); return }
        XCTAssertEqual(e.type, .int)
    }

    func testLogicalNotLowersToEq() {
        guard let e = bodyExpr("fun f() -> Bool { let t = true return !t }") else { return }
        guard case .binary(.eq, _, _) = e.kind else { XCTFail("not should be x == false"); return }
        XCTAssertEqual(e.type, .bool)
    }

    func testBitNotLowersToXor() {
        guard let e = bodyExpr("fun f() -> Int { return ~7 }") else { return }
        guard case .binary(.bitXor, _, _) = e.kind else { XCTFail("bitNot should be x ^ -1"); return }
        XCTAssertEqual(e.type, .int)
    }

    func testLogicalNotRejectsInt() {
        let r = sema("fun f() -> Bool { return !5 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("requires Bool"), r.diagnostics.render())
    }

    // MARK: - UInt8

    func testUInt8BindingFromLiteral() {
        guard let e = bodyExpr("fun f() -> UInt8 { let b: UInt8 = 200 return b }") else { return }
        XCTAssertEqual(e.type, .uint8)
    }

    func testUInt8LiteralOutOfRangeRejected() {
        let r = sema("fun f() { let b: UInt8 = 300 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("out of range for UInt8"), r.diagnostics.render())
    }

    func testUInt8ArithmeticStaysUInt8() {
        guard let e = bodyExpr("fun f(b: UInt8) -> UInt8 { return b + 1 }") else { return }
        XCTAssertEqual(e.type, .uint8)   // the `1` literal adopts UInt8
    }

    func testUInt8ToIntConversion() {
        guard let e = bodyExpr("fun f(b: UInt8) -> Int { return b.int }") else { return }
        XCTAssertEqual(e.type, .int)
    }

    func testIntToUInt8Conversion() {
        guard let e = bodyExpr("fun f(i: Int) -> UInt8 { return i.uint8 }") else { return }
        XCTAssertEqual(e.type, .uint8)
    }

    func testUInt8MixedWithIntRejected() {
        let r = sema("fun f(b: UInt8, i: Int) -> UInt8 { return b + i }")
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("must match"), r.diagnostics.render())
    }
}
