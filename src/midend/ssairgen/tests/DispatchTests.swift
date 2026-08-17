import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Dynamic dispatch + indirect calls (m7-spec.md §7.2.2c-i): boxing to `any I`, witness dispatch
// through a box, `some I` static dispatch, and calls through a function value.
final class DispatchTests: XCTestCase {
    private func dump(_ source: String) -> String {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        XCTAssertFalse(result.diagnostics.hasErrors, result.diagnostics.render())
        let gen = lowerToSSAIR(result.module)
        XCTAssertFalse(gen.diagnostics.hasErrors, gen.diagnostics.render())
        return dumpSSAIR(gen.module)
    }
    private func has(_ d: String, _ s: String) { XCTAssertTrue(d.contains(s), "missing `\(s)` in:\n\(d)") }

    // Boxing a conformer to `any I`, then a requirement call through the box's witness slot.
    func testBoxAndWitnessDispatch() {
        let out = dump("""
        interface Shape { fun area() -> Int }
        struct Circle: Shape {
            var r: Int
            fun area() -> Int { return r * r }
        }
        fun use(s: any Shape) -> Int {
            return s.area()
        }
        fun mk() -> Int {
            let c = Circle(r: 3)
            let s: any Shape = c
            return use(s)
        }
        """)
        has(out, "box ")                                  // `let s: any Shape = c`
        has(out, "call witness ")                         // `s.area()` inside `use`
        has(out, "Shape::area")
    }

    // A call through a function-typed parameter is `.indirect`.
    func testIndirectCall() {
        let out = dump("""
        fun apply(f: () -> Int) -> Int {
            return f()
        }
        """)
        // `call %f()` — an indirect call through the value, not a named `.direct` call.
        XCTAssertTrue(out.contains("call %"), out)
    }

    // `some I` dispatches statically on the hidden concrete underlying (a direct method call).
    func testOpaqueStaticDispatch() {
        let out = dump("""
        interface Shape { fun area() -> Int }
        struct Circle: Shape {
            var r: Int
            fun area() -> Int { return r * r }
        }
        fun mkc() -> some Shape { return Circle(r: 2) }
        fun useOpaque() -> Int {
            let s = mkc()
            return s.area()
        }
        """)
        has(out, "call m:Circle:area")                    // devirtualized to the concrete underlying
    }
}
