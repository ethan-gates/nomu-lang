import XCTest
import frontend

final class SemaTests: XCTestCase {

    private func sema(_ source: String) -> SemaResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var s = Sema(parser.parse())
        return s.check()
    }

    func testInfersIntBinding() {
        let r = sema("fun f() -> Int { let x = 1 + 2 return x }")
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[0],
              case .letBinding(_, _, let value) = f.body[0].kind else { XCTFail(); return }
        XCTAssertEqual(value.type, .int)
        guard case .ret(let e?) = f.body[1].kind else { XCTFail(); return }
        XCTAssertEqual(e.type, .int)   // `x` resolves to Int
    }

    func testStructFieldAccess() {
        let r = sema("""
        struct Point { var x: Int var y: Int }
        fun f(p: Point) -> Int { return p.x }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .fieldAccess(let base, let field) = e.kind else { XCTFail(); return }
        XCTAssertEqual(field, "x")
        XCTAssertEqual(e.type, .int)
        XCTAssertEqual(base.type, .named("Point", .struct_))
    }

    func testConstruction() {
        let r = sema("""
        struct Point { var x: Int var y: Int }
        fun f() -> Point { return Point(x: 1, y: 2) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .construct(let typeName, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(typeName, "Point")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(e.type, .named("Point", .struct_))
    }

    func testUndefinedNameDiagnostic() {
        let r = sema("fun f() -> Int { return zzz }")
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testUnknownTypeDiagnostic() {
        let r = sema("fun f(x: Nope) -> Int { return 0 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
    }
}
