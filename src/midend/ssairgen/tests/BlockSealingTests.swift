import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen
import ssairpasses   // verifySSAIR — regression guard for block-argument threading

// Block-sealing / direct-SSA-construction tests (ssair.md): nested loops, break/continue,
// and a value live across a back-edge. Each drives the real pipeline (source → parse → Sema → NOIR →
// SSAIR) and asserts on the dumped CFG.
final class BlockSealingTests: XCTestCase {

    // source → the SSAIR dump of its first function.
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

    private func blockHeaders(_ dump: String) -> [String] {
        dump.split(separator: "\n").map(String.init).filter { $0.hasPrefix("bb") && $0.hasSuffix(":") }
    }
    private func count(_ dump: String, _ needle: String) -> Int {
        dump.components(separatedBy: needle).count - 1
    }

    // A loop induction variable and accumulator are live across the back-edge: both must become header
    // block parameters (they differ between the entry edge and the back-edge). A parameter that is not
    // loop-carried (the read-only bound `n`) must be cleaned up by trivial-parameter elimination.
    func testValueLiveAcrossBackEdge() {
        let out = dump("""
        fun count(n: Int) -> Int {
            var i = 0
            var s = 0
            while i < n {
                s = s + i
                i = i + 1
            }
            return s
        }
        """)
        // entry, header, body, exit.
        XCTAssertEqual(blockHeaders(out).count, 4, out)
        XCTAssertEqual(count(out, "condBr"), 1, out)
        // The header carries exactly the two loop-carried values (i, s); `n` was trivially removed.
        let header = out.split(separator: "\n").first { $0.contains("(") && $0.contains("):") }.map(String.init)
        XCTAssertNotNil(header, out)
        XCTAssertEqual(count(header ?? "", ":"), 3, header ?? "")   // "bbN(%a : Int, %b : Int):" → three colons
        // Two back-edges into the loop region: entry→header and body→header.
        XCTAssertGreaterThanOrEqual(count(out, "br bb1("), 1, out)
    }

    // Two nested loops: an outer and an inner header, each with its own back-edge; the outer
    // accumulator flows through both headers.
    func testNestedLoops() {
        let out = dump("""
        fun nested(n: Int, m: Int) -> Int {
            var total = 0
            var i = 0
            while i < n {
                var j = 0
                while j < m {
                    total = total + 1
                    j = j + 1
                }
                i = i + 1
            }
            return total
        }
        """)
        XCTAssertEqual(count(out, "condBr"), 2, out)          // one per loop
        // entry + (outer header, body, exit) + (inner header, body, exit) = 7 blocks.
        XCTAssertEqual(blockHeaders(out).count, 7, out)
    }

    // Regression: a value carried on the *outer* back-edge and live across *two sequential inner
    // loops* must thread as a parameter through each inner header, with a matching argument on every
    // predecessor edge. The construction fixpoint once terminated on a per-block parameter-count
    // check, which misses a parameter added to a deeper block via single-predecessor forwarding; the
    // later `fillArgs` then grew a header's parameter set after its predecessors' arguments were
    // fixed, leaving an edge whose argument count disagreed with the target (verifier I3). Here the
    // accumulator `acc`/`i` are carried across both inner loops — the `binary-tree` shape, minimized.
    func testNestedLoopBackEdgeLiveInVerifies() {
        let src = """
        fun f(n: Int, m: Int) -> Int {
            var i = 0
            var acc = 0
            while i < n {
                var a = 0
                while a < m {
                    a = a + 1
                }
                var b = 0
                while b < m {
                    b = b + 1
                }
                acc = acc + i
                i = i + 1
            }
            return acc
        }
        """
        var lexer = Lexer(src, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        XCTAssertFalse(result.diagnostics.hasErrors, result.diagnostics.render())
        let gen = lowerToSSAIR(result.module)
        XCTAssertFalse(gen.diagnostics.hasErrors, gen.diagnostics.render())
        // Every CFG edge must pass exactly the target block's parameter count (I3).
        XCTAssertEqual(verifySSAIR(gen.module), [], dumpSSAIR(gen.module))
    }

    // `break` terminates its block with a branch to the loop exit; `continue` with a branch back to
    // the header. Both must land the exit block reachable and the CFG well-formed.
    func testBreakContinue() {
        let out = dump("""
        fun scan(n: Int) -> Int {
            var i = 0
            while i < n {
                if i == 4 {
                    break
                }
                if i == 2 {
                    i = i + 2
                    continue
                }
                i = i + 1
            }
            return i
        }
        """)
        XCTAssertFalse(out.isEmpty)
        // The loop condBr plus the two `if` condBrs.
        XCTAssertEqual(count(out, "condBr"), 3, out)
        XCTAssertTrue(out.contains("ret "), out)
    }

    // `&&` / `||` short-circuit: each lowers to a condBr on the left operand and a merge phi, never
    // an eager binary op. The right operand is evaluated only in the branch that needs it.
    func testShortCircuitLowersToBranches() {
        for src in ["fun f(a: Bool, b: Bool) -> Bool { return a && b }",
                    "fun f(a: Bool, b: Bool) -> Bool { return a || b }"] {
            let out = dump(src)
            XCTAssertEqual(count(out, "condBr"), 1, out)   // branch on the left operand
            XCTAssertFalse(out.contains("&&"), out)        // no eager logical op in the IR
            XCTAssertFalse(out.contains("||"), out)
        }
    }

    // The merge block's result parameter must be threaded from both predecessors (skip-value edge and
    // rhs edge) with the right argument count — the block-argument invariant.
    func testShortCircuitCFGVerifies() {
        let src = "fun f(a: Bool, b: Bool, c: Bool) -> Bool { return a && b || c }"
        var lexer = Lexer(src, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        let result = sema.check()
        XCTAssertFalse(result.diagnostics.hasErrors, result.diagnostics.render())
        let gen = lowerToSSAIR(result.module)
        XCTAssertFalse(gen.diagnostics.hasErrors, gen.diagnostics.render())
        XCTAssertEqual(verifySSAIR(gen.module), [], dumpSSAIR(gen.module))
    }
}
