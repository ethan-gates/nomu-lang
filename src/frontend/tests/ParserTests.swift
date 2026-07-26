import XCTest
import frontend

final class ParserTests: XCTestCase {

    private func parse(_ source: String) -> Program {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        return parser.parse()
    }

    func testStructDecl() {
        let p = parse("struct Point {\nvar x: Int\nvar y: Int\n}")
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.name, "Point")
        XCTAssertEqual(s.fields.count, 2)
        XCTAssertEqual(s.fields[0].name, "x")
        XCTAssertEqual(s.fields[1].type.name, "Int")
    }

    func testEnumDecl() {
        let p = parse("enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }")
        guard case .enumDecl(let e) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(e.name, "Shape")
        XCTAssertEqual(e.cases.count, 2)
        XCTAssertEqual(e.cases[0].name, "circle")
        XCTAssertEqual(e.cases[0].fields[0].name, "radius")
        XCTAssertEqual(e.cases[1].fields.count, 2)
    }

    func testClassDecl() {
        let p = parse("class Buffer {\nvar data: Point\n}")
        guard case .classDecl(let c) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(c.name, "Buffer")
        XCTAssertEqual(c.fields.count, 1)
    }

    func testStructWithMethod() {
        // A `fun` member on its own line parses as a method, fields stay intact.
        let p = parse("""
        struct Point {
            var x: Int
            var y: Int
            fun sum() -> Int { return x + y }
        }
        """)
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.fields.count, 2)
        XCTAssertEqual(s.methods.count, 1)
        XCTAssertEqual(s.methods[0].name, "sum")
        XCTAssertEqual(s.methods[0].returnType?.name, "Int")
    }

    func testClassWithMethod() {
        let p = parse("""
        class Counter {
            var n: Int
            fun get() -> Int { return n }
        }
        """)
        guard case .classDecl(let c) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(c.fields.count, 1)
        XCTAssertEqual(c.methods.count, 1)
        XCTAssertEqual(c.methods[0].name, "get")
    }

    func testLetAndVarFields() {
        let p = parse("""
        struct P {
            let x: Int
            var y: Int
        }
        """)
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.fields.count, 2)
        XCTAssertFalse(s.fields[0].isMutable)   // let
        XCTAssertTrue(s.fields[1].isMutable)    // var
    }

    func testLeadingDotParsesAsImplicitMember() {
        let p = parse("fun f() { let t: Shape = .rect(w: 2, h: 3) }")
        guard case .funcDecl(let f) = p.decls[0],
              case .binding(let b) = f.body[0],
              case .call(let callee, let args, _) = b.value,
              case .implicitMember(let name, _) = callee else { XCTFail(); return }
        XCTAssertEqual(name, "rect")
        XCTAssertEqual(args.count, 2)
    }

    func testActorDecl() {
        let p = parse("actor Counter {\nvar count: Int = 0\non bump(by: Point) { count += by.x } }")
        guard case .actorDecl(let a) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(a.name, "Counter")
        XCTAssertEqual(a.fields.count, 1)
        XCTAssertEqual(a.fields[0].name, "count")
        XCTAssertNotNil(a.fields[0].initializer)
        XCTAssertEqual(a.handlers.count, 1)
        XCTAssertEqual(a.handlers[0].name, "bump")
        XCTAssertEqual(a.handlers[0].params[0].label, "by")
    }

    func testFuncDecl() {
        let p = parse("fun area(s: Shape) -> Int { return 0 }")
        guard case .funcDecl(let f) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(f.name, "area")
        XCTAssertEqual(f.params[0].label, "s")
        XCTAssertEqual(f.params[0].type.name, "Shape")
        XCTAssertEqual(f.returnType?.name, "Int")
        XCTAssertEqual(f.body.count, 1)
    }

    func testSwitchStmt() {
        let src = """
        fun area(s: Shape) -> Int {
            switch s {
            case .circle(let r):      return 3 * r * r
            case .rect(let w, let h): return w * h
            }
        }
        """
        let p = parse(src)
        guard case .funcDecl(let f) = p.decls[0],
              case .switchStmt(let sw) = f.body[0] else { XCTFail(); return }
        XCTAssertEqual(sw.cases.count, 2)
        guard case .enumCase(let name, let bindings, _) = sw.cases[0].pattern else { XCTFail(); return }
        XCTAssertEqual(name, "circle")
        XCTAssertEqual(bindings, ["r"])
        guard case .enumCase(_, let bindings2, _) = sw.cases[1].pattern else { XCTFail(); return }
        XCTAssertEqual(bindings2, ["w", "h"])
    }

    func testBinaryExpr() {
        let p = parse("fun f() -> Int { return 3 * 4 + 1 }")
        guard case .funcDecl(let f) = p.decls[0],
              case .ret(let expr?, _) = f.body[0],
              case .binary(let op, _, _, _) = expr else { XCTFail(); return }
        XCTAssertEqual(op, .add)  // + binds looser than *, so top-level op is add
    }

    func testLabeledCall() {
        let p = parse("fun f() -> Int { return Point(x: 1, y: 2).x }")
        guard case .funcDecl(let f) = p.decls[0],
              case .ret(let expr?, _) = f.body[0],
              case .member(let inner, let field, _) = expr,
              case .call(_, let args, _) = inner else { XCTFail(); return }
        XCTAssertEqual(field, "x")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0].label, "x")
        XCTAssertEqual(args[1].label, "y")
    }

    func testActorMethodCall() {
        // Actor construction is a plain call; method calls are plain member-call expressions.
        let p = parse("fun main() { let c = Counter() c.bump(by: p) }")
        guard case .funcDecl(let f) = p.decls[0] else { XCTFail(); return }
        // Construction: Counter()
        guard case .binding(let b) = f.body[0],
              case .call(let ctor, _, _) = b.value,
              case .ident(let ctorName, _) = ctor else { XCTFail(); return }
        XCTAssertEqual(ctorName, "Counter")
        // Method call: c.bump(by: p)
        guard case .expr(let callExpr) = f.body[1],
              case .call(let callee, let args, _) = callExpr,
              case .member(_, let handler, _) = callee else { XCTFail(); return }
        XCTAssertEqual(handler, "bump")
        XCTAssertEqual(args[0].label, "by")
    }

    func testHandlerReturnType() {
        let p = parse("actor Counter {\nvar count: Int = 0\non getCount() -> Int { return count } }")
        guard case .actorDecl(let a) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(a.handlers[0].returnType?.name, "Int")
    }

    func testComputedProperty() {
        // A bare-body property is read-only; a get/set property records its setter param.
        let p = parse("""
        struct Rect {
            var w: Int
            var area: Int { w * w }
            var scale: Int {
                get { w }
                set(s) { w = s }
            }
        }
        """)
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.fields.count, 1)          // only `w` is stored
        XCTAssertEqual(s.properties.count, 2)
        XCTAssertEqual(s.properties[0].name, "area")
        XCTAssertNil(s.properties[0].setter)
        XCTAssertEqual(s.properties[1].name, "scale")
        XCTAssertEqual(s.properties[1].setter?.paramName, "s")
    }

    func testInterfaceDecl() {
        let p = parse("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
            var count: Int { get set }
            fun describe() -> String { return name }
        }
        """)
        guard case .interfaceDecl(let i) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(i.name, "Drawable")
        XCTAssertEqual(i.methods.count, 2)
        XCTAssertNil(i.methods[0].defaultBody)        // `draw` is a mandatory requirement
        XCTAssertNotNil(i.methods[1].defaultBody)     // `describe` is an overridable default
        XCTAssertEqual(i.properties.count, 2)
        XCTAssertFalse(i.properties[0].isSettable)    // name { get }
        XCTAssertTrue(i.properties[1].isSettable)     // count { get set }
    }

    func testConformanceClauseParses() {
        let p = parse("""
        struct Circle: Drawable {
            var name: String
            fun draw() -> String { return name }
        }
        extension Circle: Sized {
            fun size() -> Int { return 1 }
        }
        """)
        guard case .structDecl(let s) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.conformances.map(\.name), ["Drawable"])
        guard case .extensionDecl(let x) = p.decls[1] else { XCTFail(); return }
        XCTAssertEqual(x.conformance?.name, "Sized")
    }

    func testInterfaceRefinement() {
        let p = parse("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        """)
        guard case .interfaceDecl(let i) = p.decls[1] else { XCTFail(); return }
        XCTAssertEqual(i.name, "Drawable")
        XCTAssertEqual(i.refines.map(\.name), ["Named"])
    }
}
