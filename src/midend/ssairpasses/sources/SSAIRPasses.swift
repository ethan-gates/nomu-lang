import ssair
import support
import Foundation

// The pass manager + the M7 passes over SSAIR (m7-spec.md §7.3–§7.5). Build order is EA-first (7.3),
// then devirt (7.4), then inlining/specialization + bounds-check elimination (7.5).
//
// Shape (7.3): passes mutate the module **in place**. SSAIR is value-type structs over copy-on-write
// arrays, so a pass taking `inout SSAModule` has exclusive access and mutates nested arrays through
// indices without copying — no arena, no reference-typed IR. SSAIR is tiny next to LLVM object-gen and
// link (measured ~2 ms to build a whole module vs ~50 ms each downstream), so the driver optimizes for
// correctness and debuggability, not raw speed: it verifies the GC-precision invariants after every
// pass by default, and can dump the IR entering each pass.
//
// A transform pass rewrites the IR. (Analyses — side tables that mutate nothing, with explicit
// dependency/invalidation — arrive with EA at 7.3, which is analysis-then-transform.)
public protocol SSAPass {
    var name: String { get }
    func run(_ module: inout SSAModule)
}

public struct PassPipeline {
    public let passes: [SSAPass]
    public init(_ passes: [SSAPass]) { self.passes = passes }

    // Run every pass in order over `module`, in place. After each pass the GC-precision invariants
    // (§7.0.5) are re-checked when `verify` is set — cheap insurance against a silent miscompile —
    // and the returned list holds any violations (empty means clean). With `NOMU_DUMP_SSAIR_PASSES`
    // set and a `stem`, the IR entering each pass is written to `<stem>.<n>-before-<pass>.ssair` (and
    // the final IR to `<stem>.final.ssair`) for inspection.
    // `onStage` (a `StageSink`) reports each pass's wall time under the `ssair` phase, plus the total
    // post-pass verification time as one `ssair`/`verify` line — so a phase breakdown shows per-pass
    // cost. Nil in tests / non-timed runs.
    @discardableResult
    public func run(_ module: inout SSAModule, stem: String? = nil, verify: Bool = true,
                    onStage: StageSink? = nil) -> [String] {
        let dumpStem = ProcessInfo.processInfo.environment["NOMU_DUMP_SSAIR_PASSES"] != nil ? stem : nil
        var violations: [String] = []
        var verifySecs = 0.0
        for (i, pass) in passes.enumerated() {
            if let stem = dumpStem { writeDump(module, "\(stem).\(i)-before-\(pass.name).ssair") }
            let t0 = Date()
            pass.run(&module)
            onStage?("ssair", pass.name, Date().timeIntervalSince(t0))
            if verify {
                let v0 = Date()
                violations += verifySSAIR(module).map { "after \(pass.name): \($0)" }
                verifySecs += Date().timeIntervalSince(v0)
            }
        }
        // An empty pipeline still gets verified once — this validates the lowered module the egress
        // will consume (ssairgen's output), the useful check before any pass exists.
        if verify && passes.isEmpty {
            let v0 = Date()
            violations += verifySSAIR(module)
            verifySecs += Date().timeIntervalSince(v0)
        }
        if verify { onStage?("ssair", "verify", verifySecs) }
        if let stem = dumpStem { writeDump(module, "\(stem).final.ssair") }
        return violations
    }

    private func writeDump(_ module: SSAModule, _ path: String) {
        try? dumpSSAIR(module).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
