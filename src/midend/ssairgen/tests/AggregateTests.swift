import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Value-aggregate (Option B — slots), class, enum-match, and array-literal lowering
// (ssair.md — IR shape). Drives source → parse → Sema → NOIR → SSAIR and asserts on the dumped ops.
final class AggregateTests: XCTestCase {
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

    // A struct local lives in a stack slot: construction is `makeStruct` stored into the slot, and
    // both field writes and reads address the slot through `fieldAddr` (stack — never a barrier).
    func testStructSlotAndFields() {
        let out = dump("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun f(a: Int) -> Int {
            var p = Point(x: a, y: 2)
            p.x = 5
            return p.x + p.y
        }
        """)
        has(out, "stackAlloc Point")
        has(out, "makeStruct Point")
        has(out, "fieldAddr")            // slot field addressing for the write and the reads
        XCTAssertFalse(out.contains("writeBarrier"), "a struct slot store must not barrier:\n\(out)")
    }

    // A struct with no address — a by-value parameter — reads a field by projection (`extractField`),
    // not through a slot.
    func testStructByValueParam() {
        let out = dump("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun getx(p: Point) -> Int {
            return p.x
        }
        """)
        has(out, "extractField")
        XCTAssertFalse(out.contains("stackAlloc"), "a read-only by-value struct needs no slot:\n\(out)")
    }

    // A class is a managed heap object: construction is an explicit `alloc` (the EA site) with a
    // barriered store per field; a field read GEPs off the pointer and loads; a field write barriers.
    func testClassAllocAndBarrier() {
        let out = dump("""
        class Counter {
            var n: Int
        }
        fun g() -> Int {
            var c = Counter(n: 0)
            c.n = 7
            return c.n
        }
        """)
        has(out, "alloc Counter")
        has(out, "writeBarrier")
        has(out, "fieldAddr")
    }

    // An enum match reads the tag, dispatches with `switchOn`, and extracts payload fields per arm;
    // the exhaustive default is `unreachable`.
    func testEnumMatch() {
        let out = dump("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun area(s: Shape) -> Int {
            switch s {
            case .circle(let r): return 3 * r * r
            case .rect(let w, let h): return w * h
            }
        }
        """)
        has(out, "enumTag")
        has(out, "switch ")
        has(out, "extractPayload")
        has(out, "unreachable")
    }

    // Enum construction is `makeEnum` with the case index and payload values.
    func testEnumInit() {
        let out = dump("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun mk(r: Int) -> Shape {
            return Shape.circle(radius: r)
        }
        """)
        has(out, "makeEnum Shape#0")
    }

    // An array literal is the `arrayLit` op; a subscript read lowers to an explicit bounds check.
    func testArrayLitAndIndex() {
        let out = dump("""
        fun sum() -> Int {
            let xs = [10, 20, 30]
            return xs[1]
        }
        """)
        has(out, "arrayLit")
        has(out, "boundscheck")
        has(out, "elementAddr")
    }
}
