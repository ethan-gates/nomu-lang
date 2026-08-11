import Foundation

// Per-stage compiler timing. Every invocation records how long each pipeline stage takes and prints
// a breakdown to stderr (stdout stays the artifact path). A first cut toward compiler-performance
// visibility — the LLVM sub-stages (IR lowering, transform passes, object emit) are one `codegen`
// bucket for now, since they live behind a single LLVMBridge call; splitting them needs timing hooks
// in that bridge (a follow-up). Basic context (input size, optimization level) rides along.
public final class Timings {
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var stages: [(name: String, seconds: Double)] = []

    // Context filled in as it becomes known; printed in the header.
    public var file = ""
    public var optimize = false
    public var bytes = 0
    public var tokens = 0

    public init() { started = clock.now }

    // Time `body`, record it under `name`, and return its result.
    public func measure<T>(_ name: String, _ body: () -> T) -> T {
        let t0 = clock.now
        let result = body()
        stages.append((name, seconds(clock.now - t0)))
        return result
    }

    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    // Print the breakdown to stderr. Called on the success path and before an error exit, so every
    // invocation reports (a failed run shows the stages it reached).
    public func report() {
        let total = seconds(clock.now - started)
        var out = "── nomu timings ───────────────────────────\n"
        let name = (file as NSString).lastPathComponent
        out += "  file:      \(name)  (\(bytes) bytes, \(tokens) tokens)\n"
        out += "  optimize:  \(optimize ? "yes" : "no")\n"
        for (stage, secs) in stages {
            let ms = secs * 1000
            let pct = total > 0 ? secs / total * 100 : 0
            out += "  " + pad(stage, 11) + String(format: "%8.2f ms  %5.1f%%", ms, pct) + "\n"
        }
        out += "  " + String(repeating: "─", count: 30) + "\n"
        out += "  " + pad("total", 11) + String(format: "%8.2f ms", total * 1000) + "\n"
        FileHandle.standardError.write(Data(out.utf8))
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
