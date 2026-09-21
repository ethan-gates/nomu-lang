import Foundation

// LPT (longest-processing-time-first) dispatch order, persisted in the manifest as `computed_order`.
// Dispatching the long tails first keeps the fixed-8 pool saturated — they overlap instead of trailing
// the fast cases and draining the lanes at the end.

// Order `cases` by the persisted ranking (longest first). Cases absent from the ranking (new / never
// measured) sort first, so a brand-new case runs early and gets a timing next run.
func lptSort(_ cases: [ResolvedCase], order: [String]) -> [ResolvedCase] {
    var rank: [String: Int] = [:]
    for (i, name) in order.enumerated() { rank[name] = i }
    return cases.sorted {
        let a = rank[$0.name] ?? -1   // unknown → -1, sorts before rank 0 (the current longest)
        let b = rank[$1.name] ?? -1
        return a != b ? a < b : $0.name < $1.name
    }
}

// The longest-first ranking implied by a run's measured durations. Failures and timeouts carry their
// elapsed time, so a slow-failing case keeps its front-of-line slot next run.
func computeOrder(_ results: [CaseResult]) -> [String] {
    results
        .sorted { $0.runTime != $1.runTime ? $0.runTime > $1.runTime : $0.name < $1.name }
        .map { $0.name }
}

// Splice a single-line `computed_order` into the manifest, preserving all other formatting. Only that
// one line changes (or is inserted right after the opening brace), so the hand-authored file stays
// intact and the git diff stays to one line.
func writeComputedOrder(_ order: [String], to configPath: String) {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
    var lines = text.components(separatedBy: "\n")
    lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"computed_order\"") }
    guard let brace = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "{" }) else { return }
    let arr = order.map { "\"\($0)\"" }.joined(separator: ", ")
    lines.insert("  \"computed_order\": [\(arr)],", at: brace + 1)
    try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
}
