import Foundation
import planner

// The build's performance report (task 193): `build/_perf/report.json`, written on every build that reaches its
// workspace lock. It holds everything the build recorded — each unit's spans, outcome and reason, the stage and
// phase totals over the build, the planner's steps and counts, the cache's hits, the binaries — and is what a
// tool reads to learn what a build did (tools read files, never `nomu`'s output). The other report files are
// views of the same data. Times are integer microseconds: a span's `start` counts from the build's start
// (`started`, wall clock), and `dur` is its duration, as the Chrome trace format writes a complete event.
struct PerfReport: Codable {
    struct Counts: Codable {
        var total = 0, compiled = 0, cached = 0, failed = 0
        var hitRate = 0.0   // cached / (compiled + cached); 0 when nothing ran
    }
    struct Planner: Codable {
        var steps: [String: Int]      // step → exclusive µs
        var directoriesListed: Int, filesScanned: Int, modules: Int
    }
    struct Stage: Codable {           // one (phase, name) summed over every unit
        var phase: String, name: String, dur: Int, count: Int
    }
    struct Phase: Codable { var phase: String, dur: Int }
    struct Span: Codable { var phase: String, name: String, start: Int, dur: Int }
    // The longest chain of units through their dependencies, each weighted by its cost — what building it takes,
    // whether or not the cache served it — so the path is the build's time on unlimited cores with nothing
    // cached. A unit whose cost was not recorded weighs its duration. Beside it, the build's own work before
    // the first unit (configuration, planning), every unit's cost added, and this build's wall time from the
    // first unit's start to the last one's end.
    struct CriticalPath: Codable {
        var dur: Int
        var units: [String]           // first to last
        var setup: Int                // the build's own work before the first unit
        var summed: Int               // every unit's cost, added
        var wall: Int                 // this build: first unit's start to last unit's end
        var unrecorded: [String]      // units weighed by their duration, their cost not recorded
    }
    struct Unit: Codable {
        var kind: String              // build | module | archive | link
        var name: String              // a module's `<scope>.<name>:<path>`, a link's workspace-relative binary
        var outcome: String           // compiled | cached | failed
        var reason: String?           // why it compiled, compared with the last build
        var start: Int, dur: Int
        var cost: Int?                // what building it costs, cached or not; absent when not recorded
        var dependencies: [String]    // the units it waited for
        var bytes: Int, tokens: Int
        var phases: [Phase]           // its spans summed by phase, in first-appearance order
        var spans: [Span]
    }

    var version = 1
    var status: String                // built | stopped | failed
    var package: String
    var optimize: Bool
    var started: String               // the build's start, ISO 8601 wall clock
    var dur: Int                      // wall time
    var bytes: Int, tokens: Int
    var modules: Counts
    var links: Counts
    var binaries: [String]            // absolute paths, in the targets' order
    var planner: Planner?
    var phases: [Phase]               // over every unit
    var stages: [Stage]               // over every unit, in first-appearance order
    var criticalPath: CriticalPath
    var units: [Unit]

    init(_ profile: BuildProfile, binaries: [String]) {
        func status(_ s: BuildProfile.Status) -> String {
            switch s { case .built: "built"; case .stopped: "stopped"; case .failed: "failed" }
        }
        func counts(_ kind: Track.Kind) -> Counts {
            let ts = profile.tracks.filter { $0.kind == kind }
            var c = Counts(total: ts.count)
            c.compiled = ts.filter { $0.outcome == .compiled }.count
            c.cached = ts.filter { $0.outcome == .cached }.count
            c.failed = ts.filter { $0.outcome == .failed }.count
            c.hitRate = c.compiled + c.cached > 0 ? Double(c.cached) / Double(c.compiled + c.cached) : 0
            return c
        }
        func phases(_ spans: [TimedSpan]) -> [Phase] {
            var order: [String] = [], sums: [String: Double] = [:]
            for s in spans {
                if sums[s.phase] == nil { order.append(s.phase) }
                sums[s.phase, default: 0] += s.seconds
            }
            return order.map { Phase(phase: $0, dur: us(sums[$0]!)) }
        }

        self.status = status(profile.status)
        package = profile.package
        optimize = profile.optimize
        started = iso8601(profile.startedAt)
        dur = us(profile.build.end)
        bytes = profile.bytes
        tokens = profile.tokens
        modules = counts(.module)
        links = counts(.link)
        self.binaries = binaries
        planner = profile.planner.map { p in
            Planner(steps: Dictionary(uniqueKeysWithValues: PlanTimings.Step.allCases.map { ($0.rawValue, us(p.seconds[$0] ?? 0)) }),
                    directoriesListed: p.directoriesListed, filesScanned: p.filesScanned, modules: p.modules)
        }
        let all = profile.tracks.flatMap(\.timings.spans)
        self.phases = phases(all)
        var order: [String] = [], totals: [String: (phase: String, name: String, seconds: Double, count: Int)] = [:]
        for s in all {
            let key = s.phase + "/" + s.name
            if totals[key] == nil { order.append(key); totals[key] = (s.phase, s.name, 0, 0) }
            totals[key]!.seconds += s.seconds
            totals[key]!.count += 1
        }
        stages = order.map { let t = totals[$0]!; return Stage(phase: t.phase, name: t.name, dur: us(t.seconds), count: t.count) }
        units = profile.tracks.map { t in
            Unit(kind: t.kind.rawValue, name: t.name, outcome: t.outcome.rawValue, reason: t.reason,
                 start: us(t.begin), dur: usSpan(t.begin, t.seconds), cost: t.cost.map(us), dependencies: t.dependencies,
                 bytes: t.timings.bytes, tokens: t.timings.tokens, phases: phases(t.timings.spans),
                 spans: t.timings.spans.map { Span(phase: $0.phase, name: $0.name, start: us($0.start), dur: usSpan($0.start, $0.seconds)) })
        }
        criticalPath = PerfReport.criticalPath(profile.tracks.filter { $0.kind != .build })
    }

    // The longest path over the units' dependency graph (acyclic: a unit depends only on units the build ran
    // before it), each unit weighted by its cost. A dependency the build never reached is skipped.
    static func criticalPath(_ units: [Track]) -> CriticalPath {
        let byName = Dictionary(units.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Each unit's longest chain ending at it, and the dependency that chain comes through.
        var best: [String: (dur: Double, via: String?)] = [:]
        for u in units {   // in the order the build ran them, so every dependency is already solved
            var via: String? = nil, longest = 0.0
            for d in u.dependencies {
                guard byName[d] != nil, let b = best[d], b.dur > longest else { continue }
                longest = b.dur; via = d
            }
            best[u.name] = (longest + (u.cost ?? u.seconds), via)
        }
        var path: [String] = []
        var cursor = best.max { $0.value.dur < $1.value.dur }?.key
        while let c = cursor { path.append(c); cursor = best[c]?.via }
        let first = units.map(\.begin).min() ?? 0, last = units.map(\.end).max() ?? 0
        return CriticalPath(dur: us(path.first.flatMap { best[$0]?.dur } ?? 0), units: path.reversed(),
                            setup: us(first), summed: us(units.reduce(0) { $0 + ($1.cost ?? $1.seconds) }),
                            wall: us(max(0, last - first)),
                            unrecorded: units.filter { $0.cost == nil && $0.outcome != .failed }.map(\.name))
    }

    // The report's encoding: compact JSON with sorted keys.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { fputs("error: cannot encode the build report\n", stderr); return nil }
        return data
    }

    // Replace the file at `path` with `data` in one rename, so a reader never sees half a file. Returns false (with
    // a message) on failure.
    static func replace(_ path: String, with data: Data) -> Bool {
        let temp = (path as NSString).deletingLastPathComponent + "/.tmp-" + (path as NSString).lastPathComponent
            + ".\(getpid())"
        let fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        var ok = fd >= 0
        if ok {
            ok = data.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            ok = close(fd) == 0 && ok
        }
        guard ok, rename(temp, path) == 0 else {
            unlink(temp)
            fputs("error: cannot write '\(path)'\n", stderr)
            return false
        }
        return true
    }

    static let directory = "_perf"
    static let fileName = "report.json"
}

// Seconds as integer microseconds.
private func us(_ seconds: Double) -> Int { Int((seconds * 1e6).rounded()) }

// A span's duration in µs as its rounded end less its rounded start, so spans that touch still touch after rounding.
private func usSpan(_ start: Double, _ seconds: Double) -> Int { us(start + seconds) - us(start) }

// A wall-clock time as ISO 8601 in UTC with milliseconds (`2026-10-28T18:21:51.448Z`), formatted directly: a
// date formatter costs most of a millisecond to set up.
private func iso8601(_ date: Date) -> String {
    let t = date.timeIntervalSince1970
    var secs = time_t(t.rounded(.down))
    var tm = tm()
    gmtime_r(&secs, &tm)
    let ms = min(999, Int(((t - Double(secs)) * 1000).rounded(.down)))
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1,
                  Int(tm.tm_mday), Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec), ms)
}
