import noir
import ast
import support
import Foundation

// Per-invocation compiler timing, categorized by pipeline phase. Every stage records under a phase
// (parse / noir / ssair / llvm / runtime / link); the report groups stages by phase with a per-phase
// subtotal + percentage, then a grand total, to stderr (stdout stays the artifact path). Stages
// measured deep in a module (SSAIR passes, LLVM sub-stages) report up through a `StageSink` (see
// `record`), so the `llvm`/`ssair` phases break down rather than showing one opaque `codegen` bucket.
public final class Timings {
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var stages: [(phase: String, name: String, seconds: Double)] = []

    // Context filled in as it becomes known; printed in the header.
    public var file = ""
    public var optimize = false
    public var bytes = 0
    public var tokens = 0
    public var egress = "ssair"   // the backend egress (SSAIR tier — the sole path since M7.7)

    public init() { started = clock.now }

    // Time `body`, record it under `phase`/`name`, and return its result.
    public func measure<T>(_ phase: String, _ name: String, _ body: () -> T) -> T {
        let t0 = clock.now
        let result = body()
        stages.append((phase, name, seconds(clock.now - t0)))
        return result
    }

    // Record a stage timed elsewhere (a `StageSink` target) — used for sub-stages inside the LLVM
    // bridge and the SSAIR pass pipeline, which time themselves and report up.
    public func record(phase: String, name: String, seconds: Double) {
        stages.append((phase, name, seconds))
    }

    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    // Print the phase-grouped breakdown to stderr. Called on the success path and before an error
    // exit, so every invocation reports (a failed run shows the phases it reached).
    public func report() {
        let total = seconds(clock.now - started)
        var out = "── nomu timings ───────────────────────────\n"
        let name = (file as NSString).lastPathComponent
        out += "  file:      \(name)  (\(bytes) bytes, \(tokens) tokens)\n"
        out += "  egress:    \(egress)\n"
        out += "  optimize:  \(optimize ? "yes" : "no")\n"

        // Group by phase in first-appearance order.
        var order: [String] = []
        var byPhase: [String: [(name: String, seconds: Double)]] = [:]
        for s in stages {
            if byPhase[s.phase] == nil { order.append(s.phase) }
            byPhase[s.phase, default: []].append((s.name, s.seconds))
        }

        // The ms column starts at a fixed offset (indent + label width) shared by phase and stage
        // lines — 2 + 20 for a phase, 4 + 18 for an indented stage — so every ms value aligns and
        // the trailing percentage column (phase lines only) never overlaps a stage's ms.
        for phase in order {
            let items = byPhase[phase]!
            let sub = items.reduce(0) { $0 + $1.seconds }
            let pct = total > 0 ? sub / total * 100 : 0
            out += "  " + pad(phase, 20) + String(format: "%8.2f ms  %5.1f%%", sub * 1000, pct) + "\n"
            // A single same-named stage adds nothing over the phase line; only break down when the
            // phase holds more than one stage.
            if items.count > 1 {
                for it in items {
                    out += "    " + pad(it.name, 18) + String(format: "%8.2f ms", it.seconds * 1000) + "\n"
                }
            }
        }
        out += "  " + String(repeating: "─", count: 30) + "\n"
        out += "  " + pad("total", 20) + String(format: "%8.2f ms", total * 1000) + "\n"
        FileHandle.standardError.write(Data(out.utf8))
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
