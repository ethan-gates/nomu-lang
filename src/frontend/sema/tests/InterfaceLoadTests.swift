import parse
import noir
import ast
import support
import XCTest
import sema

// Task 100.4.2 — a consumer resolves imported symbols against external declarations (the in-memory
// stand-in for a dependency's `.nmi`). Externals are registered for resolution but never lowered.
final class InterfaceLoadTests: XCTestCase {

    private func decls(_ source: String) -> [TopDecl] {
        var lexer = Lexer(source, file: "dep.nomu")
        var parser = Parser(lexer.tokenize())
        return parser.parse().decls
    }

    private func sema(_ source: String, externals: [TopDecl]) -> SemaResult {
        var lexer = Lexer(source, file: "app.nomu")
        var parser = Parser(lexer.tokenize())
        var s = Sema(parser.parse(), externalDecls: externals)
        return s.check()
    }

    func testExternalFunctionResolves() {
        let ext = decls("fun greet() -> Int { return 42 }")
        let r = sema("fun main() -> Int { return greet() }", externals: ext)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertTrue(r.externalFuncNames.contains("greet"))
    }

    func testWithoutExternalUnresolved() {
        let r = sema("fun main() -> Int { return greet() }", externals: [])
        XCTAssertFalse(r.diagnostics.isEmpty)   // 'greet' is undefined without the import
    }

    func testExternalTypeResolves() {
        let ext = decls("struct Point {\n    var x: Int\n    var y: Int\n}")
        let r = sema("fun area(p: Point) -> Int { return p.x }", externals: ext)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    // An external function's body is never lowered — only its signature is registered.
    func testExternalBodyNotLowered() {
        let ext = decls("fun greet() -> Int { return 42 }")
        let r = sema("fun main() -> Int { return greet() }", externals: ext)
        XCTAssertFalse(r.module.decls.contains { if case .funcDecl(let f) = $0 { return f.name == "greet" } else { return false } })
    }
}
