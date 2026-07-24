import XCTest
import frontend

// M4.12 — plain extensions. The merge pass folds `extension T { … }` methods into
// the target type's member set before Sema; these tests drive lex → parse → merge →
// Sema and assert both the merge diagnostics and the resulting typed IR.
final class ExtensionTests: XCTestCase {

    // Runs the front-end through the merge pass and Sema, returning the typed result
    // plus the merge-pass sink (parser-fatal errors like a stored property or a
    // conformance clause exit the process and are covered by end-to-end tests).
    private func run(_ source: String) -> (sema: SemaResult, merge: DiagnosticSink) {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        let mergeDiags = DiagnosticSink()
        let merged = mergeExtensions(parser.parse(), into: mergeDiags)
        var s = Sema(merged)
        return (s.check(), mergeDiags)
    }

    private func methods(of decl: IRDecl?) -> [IRFunc] {
        switch decl {
        case .structDecl(let s): return s.methods
        case .enumDecl(let e):   return e.methods
        case .classDecl(let c):  return c.methods
        default: return []
        }
    }

    func testStructExtensionMethodMerged() {
        let (r, m) = run("""
        struct Rect {
            var width: Int
            var height: Int
        }
        extension Rect {
            fun area() -> Int { return width * height }
        }
        """)
        XCTAssertTrue(m.isEmpty, m.render())
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        // The extension method now lives on Rect, typed like a body method.
        let ms = methods(of: r.module.decls.first)
        guard let area = ms.first(where: { $0.name == "area" }) else { XCTFail("area not merged"); return }
        XCTAssertEqual(area.returnType, .int)
    }

    func testEnumAndClassExtensionMethods() {
        let (r, m) = run("""
        enum Dir {
            case north
            case south
        }
        class Box {
            var n: Int
        }
        extension Dir {
            fun code() -> Int { return 0 }
        }
        extension Box {
            fun get() -> Int { return n }
        }
        """)
        XCTAssertTrue(m.isEmpty, m.render())
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertTrue(methods(of: r.module.decls[0]).contains { $0.name == "code" })
        XCTAssertTrue(methods(of: r.module.decls[1]).contains { $0.name == "get" })
    }

    func testMethodCallResolvesToMergedMethod() {
        // A call to an extension method type-checks and takes the method's return type.
        let (r, m) = run("""
        struct Rect {
            var width: Int
            var height: Int
        }
        extension Rect {
            fun area() -> Int { return width * height }
        }
        fun f(rect: Rect) -> Int { return rect.area() }
        """)
        XCTAssertTrue(m.isEmpty, m.render())
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .methodCall(_, let method, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "area")
        XCTAssertEqual(e.type, .int)
    }

    func testMutatingExtensionMethodInferred() {
        // An extension method writing a field of self is inferred mutating; calling it
        // on a `let` receiver is rejected, exactly like a body method (M4.11 path).
        let bad = run("""
        struct C {
            var n: Int
        }
        extension C {
            fun bump() { n = n + 1 }
        }
        fun f() {
            let c = C(n: 0)
            c.bump()
        }
        """)
        XCTAssertTrue(bad.sema.diagnostics.diagnostics.contains { $0.message.contains("mutating") },
                      bad.sema.diagnostics.render())

        // On a `var` receiver it is accepted.
        let good = run("""
        struct C {
            var n: Int
        }
        extension C {
            fun bump() { n = n + 1 }
        }
        fun f() {
            var c = C(n: 0)
            c.bump()
        }
        """)
        XCTAssertTrue(good.merge.isEmpty, good.merge.render())
        XCTAssertTrue(good.sema.diagnostics.isEmpty, good.sema.diagnostics.render())
    }

    func testBodyExtensionCollisionErrors() {
        let (_, m) = run("""
        struct C {
            var n: Int
            fun area() -> Int { return n }
        }
        extension C {
            fun area() -> Int { return n + n }
        }
        """)
        XCTAssertTrue(m.diagnostics.contains { $0.message.contains("collides") }, m.render())
    }

    func testExtensionExtensionCollisionErrors() {
        let (_, m) = run("""
        struct C {
            var n: Int
        }
        extension C {
            fun f() -> Int { return n }
        }
        extension C {
            fun f() -> Int { return n + 1 }
        }
        """)
        XCTAssertTrue(m.diagnostics.contains { $0.message.contains("collides") }, m.render())
    }

    func testOverloadByArgTypeIsNotACollision() {
        // Same name, different nominal argument types → distinct members, no collision.
        let (_, m) = run("""
        struct C {
            var n: Int
        }
        extension C {
            fun f() -> Int { return n }
        }
        extension C {
            fun f(by: Int) -> Int { return n + by }
        }
        """)
        XCTAssertTrue(m.isEmpty, m.render())
    }

    func testUnknownTypeExtensionErrors() {
        let (_, m) = run("""
        extension Nope {
            fun f() -> Int { return 1 }
        }
        """)
        XCTAssertTrue(m.diagnostics.contains { $0.message.contains("unknown type") }, m.render())
    }

    func testActorExtensionRejected() {
        let (_, m) = run("""
        actor A {
            var n: Int = 0
        }
        extension A {
            fun f() -> Int { return 1 }
        }
        """)
        XCTAssertTrue(m.diagnostics.contains { $0.message.contains("actor") }, m.render())
    }
}
