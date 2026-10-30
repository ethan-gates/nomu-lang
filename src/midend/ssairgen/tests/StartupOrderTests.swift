import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// The startup-global order (globals design, `tasks/224-globals.md` item 3a): each initializer runs after the
// globals it reads through its calls, and a cycle is an error naming the globals in it.
final class StartupOrderTests: XCTestCase {
    private func lower(_ source: String) -> SSAGenResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        XCTAssertFalse(result.diagnostics.hasErrors, result.diagnostics.render())
        return lowerToSSAIR(result.module)
    }

    private func order(_ source: String) -> [String] {
        let gen = lower(source)
        XCTAssertFalse(gen.diagnostics.hasErrors, gen.diagnostics.render())
        return gen.module.globals.map(\.name)
    }

    func testDirectCallOrdersReadsFirst() {
        XCTAssertEqual(order("""
        fun id(n: Int) -> Int { return n }
        fun twice() -> Int { return base * 2 }
        let doubled = twice()
        let base = id(21)
        """), ["base", "doubled"])
    }

    // Independent startup globals keep declaration order, and constant globals keep their places.
    func testDeclarationOrderWhenIndependent() {
        XCTAssertEqual(order("""
        fun id(n: Int) -> Int { return n }
        let a = id(1)
        let k = 4
        let b = id(2)
        """), ["a", "k", "b"])
    }

    func testWitnessCallReachesEveryImplementation() {
        XCTAssertEqual(order("""
        interface Source { fun value() -> Int }
        struct One: Source {
            let n: Int
            fun value() -> Int { return late }
        }
        fun id(n: Int) -> Int { return n }
        fun read(s: any Source) -> Int { return s.value() }
        let early = read(One(n: 1))
        let late = id(5)
        """), ["late", "early"])
    }

    func testClosureCallReachesEveryClosure() {
        XCTAssertEqual(order("""
        fun id(n: Int) -> Int { return n }
        fun applyTo(f: (Int) -> Int, x: Int) -> Int { return f(x) }
        let early = applyTo({ (x: Int) -> Int in return x * late }, 2)
        let late = id(3)
        """), ["late", "early"])
    }

    func testCycleThroughCallsIsAnError() {
        let gen = lower("""
        fun fromB() -> Int { return b + 1 }
        fun fromC() -> Int { return c + 1 }
        fun fromA() -> Int { return a + 1 }
        let a = fromB()
        let b = fromC()
        let c = fromA()
        """)
        XCTAssertTrue(gen.diagnostics.render().contains("initialization cycle: 'a' reads 'b', 'b' reads 'c', and 'c' reads 'a'"),
                      gen.diagnostics.render())
    }

    func testSelfReadThroughCallIsAnError() {
        let gen = lower("""
        fun next() -> Int { return a + 1 }
        let a = next()
        """)
        XCTAssertTrue(gen.diagnostics.render().contains("initialization cycle: global 'a' reads its own value through a call"),
                      gen.diagnostics.render())
    }
}
