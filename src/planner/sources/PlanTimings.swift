#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Where planning time goes, per step, with the counts that explain it. Each step's time is exclusive: a
// directory listing taken during the package walk counts toward `listings`, not `registry`.
public struct PlanTimings: Equatable {
    public enum Step: String, CaseIterable {
        case workspaces   // reading `nomu.yaml` files and following pins
        case registry     // walking workspaces for packages, reading manifests
        case listings     // listing directories
        case scan         // scanning files' import blocks
        case resolve      // resolving imports and checking them
        case plan         // cycle checks, job order, outputs
    }
    public private(set) var seconds: [Step: Double] = [:]
    public internal(set) var directoriesListed = 0
    public internal(set) var filesScanned = 0
    public internal(set) var modules = 0

    public var total: Double { seconds.values.reduce(0, +) }

    mutating func add(_ step: Step, _ s: Double) { seconds[step, default: 0] += s }
}

// A stopwatch over nested steps: entering a step pauses the one it is nested in, so every step's time is
// exclusive. Shared by the parts of one planning run.
public final class PlanClock {
    public private(set) var timings = PlanTimings()
    private var stack: [(step: PlanTimings.Step, since: Double)] = []

    public init() {}

    @discardableResult
    func measure<T>(_ step: PlanTimings.Step, _ body: () throws -> T) rethrows -> T {
        let now = Self.now()
        if let top = stack.last { timings.add(top.step, now - top.since) }
        stack.append((step, now))
        defer {
            let end = Self.now()
            let done = stack.removeLast()
            timings.add(done.step, end - done.since)
            if !stack.isEmpty { stack[stack.count - 1].since = end }
        }
        return try body()
    }

    func count(listed: Int = 0, scanned: Int = 0) {
        timings.directoriesListed += listed
        timings.filesScanned += scanned
    }
    func setModules(_ n: Int) { timings.modules = n }

    static func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}
