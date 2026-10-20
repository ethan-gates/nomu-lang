import Foundation
import XCTest

// One shape per type (task 176.5): only the leaf registry (`Shape.swift`) names a shaped leaf. A consumer that
// matches `StringBase` or the `String` wrapper itself would decide shapedness on its own and could disagree
// with the others, which is how the missed reload happened. This reads each consumer's source (comments
// stripped) and fails on a direct match.
final class ShapeConsumerTests: XCTestCase {
    private let consumers = [
        "src/midend/ssair/sources/ShapedLiveness.swift",
        "src/midend/ssairpasses/sources/SSAIRVerify.swift",
        "src/llvmgen/LLVMGenActor.swift",
        "src/llvmgen/LLVMGenGCMaps.swift",
        "src/llvmgen/LLVMGenLayoutCheck.swift",
        "src/llvmgen/LLVMGenValueWitness.swift",
    ]
    private let forbidden = [".stringBase", "\"String\"", "strTy"]

    func testConsumersNameNoLeaf() throws {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        for path in consumers {
            let text = try String(contentsOfFile: srcdir + "/_main/" + path, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
                for f in forbidden where code.contains(f) {
                    XCTFail("\(path):\(n + 1) names a shaped leaf directly (\(f)); read `shape(T)` instead")
                }
            }
        }
    }
}
