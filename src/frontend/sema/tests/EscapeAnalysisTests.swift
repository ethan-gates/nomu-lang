import midend
import parse
import noir
import ast
import support
import XCTest
import sema

final class EscapeAnalysisTests: XCTestCase {

    // parse → Sema → escape analysis; assert no sema errors, return the side table.
    private func analyze(_ source: String) -> EscapeResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        XCTAssertFalse(result.diagnostics.hasErrors, result.diagnostics.render())
        return analyzeEscapes(result.module)
    }

    private func count(_ r: EscapeResult, _ kind: AllocSite.Kind) -> Int {
        r.nonEscaping.filter { $0.kind == kind }.count
    }

    // A class instance used only through field reads never escapes.
    func testLocalClassFieldReadsNonEscaping() {
        let r = analyze("""
        class Box { var v: Int }
        fun main() {
            let b = Box(v: 7)
            print(b.v)
        }
        """)
        XCTAssertEqual(count(r, .classInstance), 1)
    }

    // Passing a class instance to a call leaks it.
    func testClassPassedToCallEscapes() {
        let r = analyze("""
        class Box { var v: Int }
        fun take(b: Box) -> Int { return b.v }
        fun main() {
            let b = Box(v: 7)
            print(take(b))
        }
        """)
        XCTAssertEqual(count(r, .classInstance), 0)
    }

    // Returning a class instance leaks it.
    func testReturnedClassEscapes() {
        let r = analyze("""
        class Box { var v: Int }
        fun make() -> Box {
            let b = Box(v: 7)
            return b
        }
        """)
        XCTAssertEqual(count(r, .classInstance), 0)
    }

    // A method call on a class instance is treated as an escape (self may leak).
    func testMethodCallReceiverEscapes() {
        let r = analyze("""
        class Box { var v: Int
            fun get() -> Int { return self.v }
        }
        fun main() {
            let b = Box(v: 7)
            print(b.get())
        }
        """)
        XCTAssertEqual(count(r, .classInstance), 0)
    }

    // A closure allocated and only invoked locally never escapes.
    func testLocalClosureCalledNonEscaping() {
        let r = analyze("""
        fun main() {
            let base = 100
            let add = { (x : Int) -> Int in return x + base }
            print(add(5))
        }
        """)
        XCTAssertEqual(count(r, .closure), 1)
    }

    // A closure passed as an argument escapes.
    func testClosurePassedAsArgEscapes() {
        let r = analyze("""
        fun apply(f : (Int)->Int, x : Int) -> Int { return f(x) }
        fun main() {
            let add = { (x : Int) -> Int in return x + 1 }
            print(apply(add, 10))
        }
        """)
        XCTAssertEqual(count(r, .closure), 0)
    }

    // The gc_smoke shape: c, dead, f are frame-local in inner; b is frame-local in main; a escapes.
    func testMixedShape() {
        let r = analyze("""
        class Box { var v: Int }
        fun inner(x: Box) -> Int {
            let c = Box(v: 333)
            let dead = Box(v: 999)
            print(dead.v)
            let k = 444
            let f = {() -> Int in return k}
            return c.v + x.v + f()
        }
        fun main() {
            let a = Box(v: 111)
            let b = Box(v: 222)
            let r = inner(a)
            print(r)
            print(b.v)
        }
        """)
        // inner: c, dead non-escaping (2 class) + f (1 closure); main: b non-escaping (1 class), a escapes.
        XCTAssertEqual(count(r, .classInstance), 3)
        XCTAssertEqual(count(r, .closure), 1)
    }

    // Disabling the analysis (an empty table) is always correct — the query is a pure lookup.
    func testEmptyTableQuery() {
        let empty = EscapeResult(nonEscaping: [])
        let span = Span(startOffset: 0, endOffset: 1, map: nil)
        XCTAssertFalse(empty.isNonEscaping(span, .closure))
    }
}
