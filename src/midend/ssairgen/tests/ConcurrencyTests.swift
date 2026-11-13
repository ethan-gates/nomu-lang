import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Actors + fibers (ssair.md): actor construction + mailbox, fire-and-forget sends, and `fiber f(x)`.
final class ConcurrencyTests: XCTestCase {
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

    // Actor construction is an `alloc` + a `mailboxInit`; a method call on the actor is a fire-and-forget
    // `send`; the handler body lowers with an actor `self` (a self-field compound-assign barriers).
    func testActorConstructSendHandler() {
        let out = dump("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
            on report() { print(count) }
        }
        fun use() {
            let c = Counter()
            c.bump(by: 5)
        }
        """)
        has(out, "alloc Counter")
        has(out, "mailboxInit")
        has(out, "send ")                          // c.bump(by: 5)
        has(out, "fun m:Counter:bump(")            // the handler body
        has(out, "writeBarrier")                   // self-field store in the handler (managed self)
    }

    // `fiber f(x)` evaluates the argument on the starting fiber, captures it in a fiber env, and starts a
    // fiber over a lifted body that makes the call.
    func testFiberStart() {
        let out = dump("""
        fun work(n: Int) -> Int { return n * n }
        fun run(n: Int) {
            fiber work(n + 1)
        }
        """)
        has(out, "fiber fiber:0")                  // start the fiber over the lifted body
        has(out, "fun fiber:0(")                   // the lifted fiber body
        has(out, "fiber.0.env")                    // the capture env (the evaluated argument)
    }
}
