import parse
import noir
import ast
import support
import XCTest
import sema

final class ExhaustivenessTests: XCTestCase {

    // parse → Sema → exhaustiveness pass; returns the collected diagnostics.
    private func check(_ source: String) -> DiagnosticSink {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        checkExhaustiveness(result.module, into: result.diagnostics)
        return result.diagnostics
    }

    func testExhaustiveSwitchAccepted() {
        let d = check("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun area(s: Shape) -> Int {
            switch s {
            case .circle(let r):      return 3 * r * r
            case .rect(let w, let h): return w * h
            }
        }
        """)
        XCTAssertFalse(d.hasErrors, d.render())
    }

    func testNonExhaustiveSwitchDiagnostic() {
        let d = check("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun area(s: Shape) -> Int {
            switch s {
            case .circle(let r): return 3 * r * r
            }
        }
        """)
        XCTAssertTrue(d.hasErrors)
        XCTAssertTrue(d.render().contains("'rect'"), d.render())
    }

    // The pass must reach switches inside method bodies (T3), not just top-level funcs.
    func testNonExhaustiveSwitchInMethod() {
        let d = check("""
        enum E { case a case b
            fun rank() -> Int {
                switch self {
                case .a: return 1
                }
            }
        }
        """)
        XCTAssertTrue(d.hasErrors)
        XCTAssertTrue(d.render().contains("'b'"), d.render())
    }
}
