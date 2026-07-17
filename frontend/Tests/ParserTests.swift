import XCTest
import frontend

final class ParserTests: XCTestCase {

    private func parse(_ source: String) -> Program {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        return parser.parse()
    }

    func testStructDecl() {
        let p = parse("struct Point { var x: Int var y: Int }")
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
        let p = parse("class Buffer { var data: Point }")
        guard case .classDecl(let c) = p.decls[0] else { XCTFail(); return }
        XCTAssertEqual(c.name, "Buffer")
        XCTAssertEqual(c.fields.count, 1)
    }

    func testActorDecl() {
        let p = parse("actor Counter { var count: Int = 0 on bump(by: Point) { count += by.x } }")
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

    func testSpawnAndSend() {
        let p = parse("fun main() { let c = spawn Counter() send c.bump(by: p) }")
        guard case .funcDecl(let f) = p.decls[0] else { XCTFail(); return }
        guard case .binding(let b) = f.body[0],
              case .spawn(let name, _, _) = b.value else { XCTFail(); return }
        XCTAssertEqual(name, "Counter")
        guard case .send(let expr, _) = f.body[1],
              case .call(let callee, let args, _) = expr,
              case .member(_, let handler, _) = callee else { XCTFail(); return }
        XCTAssertEqual(handler, "bump")
        XCTAssertEqual(args[0].label, "by")
    }
}
