import Foundation

// LPT (longest-processing-time-first) dispatch order, persisted per machine in `build/compiler-test/order.txt`
// (one case name per line, longest first). Timings belong to the machine that measured them, so the file stays
// out of the repository; a missing file means every case is unranked.
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

func orderPath(projectRoot: String) -> String { projectRoot + "/build/compiler-test/order.txt" }

func readOrder(projectRoot: String) -> [String] {
    guard let text = try? String(contentsOfFile: orderPath(projectRoot: projectRoot), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

func writeOrder(_ order: [String], projectRoot: String) {
    let path = orderPath(projectRoot: projectRoot)
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try? (order.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}
