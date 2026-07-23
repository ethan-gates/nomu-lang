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
        struct Point {
            var x: Int
            var y: Int
        }
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
        struct Point {
            var x: Int
            var y: Int
        }
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

    func testMethodCallTypes() {
        // `s.method()` resolves to a methodCall and takes the method's return type.
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
            fun sum() -> Int { return x + y }
        }
        fun f(p: Point) -> Int { return p.sum() }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .methodCall(let recv, let method, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "sum")
        XCTAssertEqual(args.count, 0)
        XCTAssertEqual(e.type, .int)
        XCTAssertEqual(recv.type, .named("Point", .struct_))
    }

    func testMethodBodySeesFieldsAndSelf() {
        // Inside a method, fields resolve by bare name and `self` is in scope.
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
            fun scaled(by: Int) -> Int { return self.x + y * by }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.methods.count, 1)
        XCTAssertEqual(s.methods[0].returnType, .int)
    }

    func testMissingMethodDiagnostic() {
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun f(p: Point) -> Int { return p.nope() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
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
