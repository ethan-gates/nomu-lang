import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Closure literals + closure conversion (m7-spec.md §7.2.2): captures → a synthesized env struct, the
// body lifted to a top-level `SSAFunction`, the value produced by `makeClosure`.
final class ClosureTests: XCTestCase {
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

    // A closure that captures an enclosing local: the capture is stored into an env struct, the body is
    // lifted, and the closure value is `makeClosure` over that env.
    func testCapturingClosure() {
        let out = dump("""
        fun make() -> (Int) -> Int {
            let base = 100
            let add = { (x: Int) -> Int in
                return x + base
            }
            return add
        }
        """)
        has(out, "clo.0.env { ")                 // synthesized env layout, with the captured field
        has(out, "base : Int")                    // the capture is a field of the env
        has(out, "alloc clo.0.env")               // env built at the site
        has(out, "closure clo:0 env ")            // the closure value = makeClosure(clo:0, env)
        has(out, "fun clo:0(")                    // the lifted body
    }

    // A non-capturing closure needs no environment: `makeClosure` with no env, an empty env layout.
    func testNonCapturingClosure() {
        let out = dump("""
        fun make() -> (Int) -> Int {
            let sq = { (n: Int) -> Int in return n * n }
            return sq
        }
        """)
        has(out, "closure clo:0")                 // the closure value
        XCTAssertFalse(out.contains("closure clo:0 env"), "a non-capturing closure carries no env:\n\(out)")
        has(out, "fun clo:0(")
    }

    // The lifted body reads its capture back from the env (env is parameter 0).
    func testLiftedBodyReadsCapture() {
        let out = dump("""
        fun make(seed: Int) -> () -> Int {
            let f = { () -> Int in return seed }
            return f
        }
        """)
        // Inside `clo:0`, the capture is loaded from the env parameter via fieldAddr.
        let lifted = out.components(separatedBy: "fun clo:0(").last ?? ""
        XCTAssertTrue(lifted.contains("fieldAddr") && lifted.contains("load"), lifted)
    }
}
