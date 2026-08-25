import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Type-method bodies with `self`, concrete method calls, and unreachable-block pruning
// (ssair.md — lowering-in / SSA construction).
final class MethodTests: XCTestCase {
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

    // A class method reads a self field (bare name → `fieldAddr` off the self pointer) and a call site
    // dispatches `.direct` to the method symbol with `self` prepended.
    func testClassMethodAndCall() {
        let out = dump("""
        class Counter {
            var n: Int
            fun get() -> Int { return n }
        }
        fun use(c: Counter) -> Int {
            return c.get()
        }
        """)
        has(out, "fun m:Counter:get(")
        has(out, "fieldAddr")                    // self.n read inside the method
        has(out, "call m:Counter:get(")          // the call site, self prepended
    }

    // A mutating struct method writes a self field; `self` is passed by address at the call site, and
    // the self-field store into the (stack) slot carries no barrier.
    func testMutatingStructMethod() {
        let out = dump("""
        struct Point {
            var x: Int
            var y: Int
            fun bump() { x = x + 1 }
        }
        fun run() -> Int {
            var p = Point(x: 1, y: 2)
            p.bump()
            return p.x
        }
        """)
        has(out, "fun m:Point:bump(")
        has(out, "call m:Point:bump(")
        // The mutating method mutates its self slot with a plain store — no write barrier anywhere.
        XCTAssertFalse(out.contains("writeBarrier"), "a struct self store must not barrier:\n\(out)")
    }

    // An enum method that `switch`es over `self` and whose arms all return leaves no dead merge block.
    func testMatchSelfNoDeadBlock() {
        let out = dump("""
        enum Shape {
            case circle(radius: Int)
            case rect(w: Int, h: Int)
            fun area() -> Int {
                switch self {
                case .circle(let r): return 3 * r * r
                case .rect(let w, let h): return w * h
                }
            }
        }
        """)
        has(out, "fun m:Shape:area(")
        has(out, "enumTag")
        // Exactly one `unreachable` (the switch default); the all-arms-return merge block was pruned.
        XCTAssertEqual(out.components(separatedBy: "unreachable").count - 1, 1, out)
    }
}
