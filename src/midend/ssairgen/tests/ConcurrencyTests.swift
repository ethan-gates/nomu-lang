import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Actors + structured concurrency (ssair.md): actor construction + mailbox, fire-and-forget
// sends, and `spawn let` (start + join-on-read + join-at-scope-exit).
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

    // `spawn let` starts a fiber over a lifted body; reading the binding joins it; the value's capture
    // rides in a spawn env.
    func testSpawnAndJoinOnRead() {
        let out = dump("""
        fun work(n: Int) -> Int { return n * n }
        fun run(n: Int) -> Int {
            spawn let a = work(n)
            return a
        }
        """)
        has(out, "spawn #0 spawn:0")               // start the fiber over the lifted body
        has(out, "spawnJoin #0")                   // reading `a` joins
        has(out, "fun spawn:0(")                   // the lifted spawn body
        has(out, "spawn.0.env")                    // the capture env (captures `n`)
    }

    // A `spawn let` whose result is never read still joins at scope exit (structured concurrency).
    func testSpawnJoinsAtScopeExit() {
        let out = dump("""
        fun work() -> Int { return 7 }
        fun run() {
            spawn let a = work()
        }
        """)
        has(out, "spawn #0 spawn:0")
        has(out, "spawnJoin #0")                   // joined at the implicit fall-off return, though never read
    }
}
