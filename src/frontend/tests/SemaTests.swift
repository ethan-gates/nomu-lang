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

    func testEnumConstructionQualified() {
        let r = sema("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun f() -> Shape { return Shape.circle(radius: 10) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .enumInit(let t, let c, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(t, "Shape")
        XCTAssertEqual(c, "circle")
        XCTAssertEqual(args.count, 1)
        XCTAssertEqual(e.type, .named("Shape", .enum_))
    }

    func testEnumConstructionLeadingDot() {
        // Enum inferred from the return type.
        let r = sema("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun f() -> Shape { return .rect(w: 2, h: 3) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .enumInit(_, let c, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(c, "rect")
        XCTAssertEqual(e.type, .named("Shape", .enum_))
    }

    func testLeadingDotNoContextDiagnostic() {
        let r = sema("""
        enum Color { case red case blue }
        fun f() { let c = .red }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testLetFieldMutabilityOnIR() {
        let r = sema("""
        struct P {
            let x: Int
            var y: Int
        }
        """)
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertFalse(s.fields[0].isMutable)
        XCTAssertTrue(s.fields[1].isMutable)
    }

    func testAssignToLetFieldDiagnostic() {
        let r = sema("""
        struct P {
            let x: Int
            var y: Int
        }
        fun f(p: P) { p.x = 5 }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testMutatingMethodInferred() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
            fun get() -> Int { return count }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertTrue(s.methods.first { $0.name == "bump" }!.isMutating)
        XCTAssertFalse(s.methods.first { $0.name == "get" }!.isMutating)
    }

    func testTransitiveMutatingInferred() {
        // A method that calls a mutating method on `self` is itself mutating.
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
            fun twice() { self.bump()  self.bump() }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertTrue(s.methods.first { $0.name == "twice" }!.isMutating)
    }

    func testMutatingCallOnLetRejected() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
        }
        fun f() { let c = C(count: 0)  c.bump() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testMutatingCallOnVarAccepted() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
        }
        fun f() { var c = C(count: 0)  c.bump() }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testReassignSelfRejected() {
        let r = sema("""
        struct C {
            var count: Int
            fun replace(o: C) { self = o }
        }
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
