import ast
import parse
import noir
import sema
import ssair
import support
import XCTest
import ssairgen

// Block-sealing / direct-SSA-construction tests (m7-spec.md §7.2.2): nested loops, break/continue,
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
}
