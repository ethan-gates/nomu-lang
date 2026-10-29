import noir
import ast
import support
import planner
import Foundation

// Compiler timing (task 193). A build gathers one `Timings` per unit of work — a module's job, the runtime
// archive, a link, and the build's own planning and bookkeeping — into a `BuildProfile`. Each recorder keeps
// spans: a phase (parse / noir / ssair / inference / interface / cache / llvm / runtime / link / plan), a
// stage name, the span's start as an offset from the build's start, and its duration. Stages measured deep
// in a module (SSAIR passes, LLVM sub-stages) report up through a `StageSink` (see `record`), so the
// `llvm`/`ssair` phases break down rather than showing one opaque `codegen` bucket.

// One timed stage.
public struct TimedSpan {
    public let phase: String
    public let name: String
    public let start: Double     // seconds from the build's start
    public let seconds: Double
}

// One unit of work's recorder. A recorder belongs to one unit, which runs on one thread at a time, so it
// takes no lock; the build gathers the recorders when the units finish.
public final class Timings {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    public private(set) var spans: [TimedSpan] = []
    // The source this unit read: bytes and tokens over its files.
    public var bytes = 0
    public var tokens = 0

    // A recorder whose offsets count from `origin` (the build's start); standalone, from its own creation.
    public init(origin: ContinuousClock.Instant? = nil) { self.origin = origin ?? clock.now }

    // Seconds from the origin to now.
    public var now: Double { seconds(clock.now - origin) }

    // Time `body`, record it under `phase`/`name`, and return its result (or rethrow its error, recorded too).
    public func measure<T>(_ phase: String, _ name: String, _ body: () throws -> T) rethrows -> T {
        let t0 = clock.now
        defer {
            let t1 = clock.now
            spans.append(TimedSpan(phase: phase, name: name, start: seconds(t0 - origin), seconds: seconds(t1 - t0)))
        }
        return try body()
    }

    // Record a stage timed elsewhere (a `StageSink` target) — used for sub-stages inside the LLVM bridge and
    // the SSAIR pass pipeline, which time themselves and report up as each stage ends. The span is placed
    // by its end, now, less its duration.
    public func record(phase: String, name: String, seconds s: Double) {
        spans.append(TimedSpan(phase: phase, name: name, start: max(0, now - s), seconds: s))
    }

    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

// What became of a unit of work.
public enum TrackOutcome: String {
    case compiled   // a module compiled, or a link or archive built
    case cached     // served by the host cache
    case failed
}

// One unit of work in a build: what it is, when it ran, what it recorded, what became of it, and the units
// it waited for (the edges of the build's critical path).
public final class Track {
    public enum Kind: String { case build, module, archive, link }
    public let kind: Kind
    public let name: String
    public let timings: Timings
    public let dependencies: [String]
    public var begin = 0.0
    public var end = 0.0
    public var outcome: TrackOutcome = .compiled
    // What building the unit costs, in seconds, cached or not: its own time when it compiled, the time its cache
    // entry's build recorded when the cache served it; nil when that was not recorded.
    public var cost: Double? = nil
    // Why the unit compiled, compared with the last build (finer under `--explain`); nil when cached.
    public var reason: String? = nil

    init(kind: Kind, name: String, timings: Timings, dependencies: [String]) {
        self.kind = kind; self.name = name; self.timings = timings; self.dependencies = dependencies
    }
    public var seconds: Double { max(0, end - begin) }   // 0 for a track an error left open
}

// A build's timings: every unit of work's track, the planner's step totals and counts, and the context the
// summary names.
public final class BuildProfile {
    private let clock = ContinuousClock()
    public let started: ContinuousClock.Instant
    private let lock = NSLock()
    public private(set) var tracks: [Track] = []
    // The build's own work: configuration, planning, source copy.
    public let build: Track
    // The planner's steps (exclusive times) and counts, and when planning started.
    public var planner: PlanTimings? = nil
    public var plannerStart = 0.0

    // Context the report records.
    public var package = ""   // the entry's package identity (manifest name, or the default)
    public var optimize = false
    // How the build ended; the summary line says so.
    public enum Status { case built, stopped, failed }
    public var status: Status = .failed
    // The workspace's `build/`, once known, and whether this build holds its lock (and so may write the report).
    public var buildRoot: String? = nil
    public var holdsLock = false

    // The build's start on the wall clock, which the report's offsets count from.
    public let startedAt = Date()

    public init() {
        started = clock.now
        build = Track(kind: .build, name: "build", timings: Timings(origin: started), dependencies: [])
        tracks.append(build)
    }

    // Seconds from the build's start to now.
    public var now: Double { let c = (clock.now - started).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }

    // Start a unit of work's track, recording against the build's clock.
    public func begin(_ kind: Track.Kind, _ name: String, dependencies: [String] = []) -> Track {
        let t = Track(kind: kind, name: name, timings: Timings(origin: started), dependencies: dependencies)
        t.begin = now
        lock.lock(); tracks.append(t); lock.unlock()
        return t
    }

    // Close a track. A unit that compiled cost its own time.
    public func finish(_ t: Track, _ outcome: TrackOutcome) {
        t.end = now
        t.outcome = outcome
        if outcome == .compiled { t.cost = t.seconds }
    }

    // The unit's time so far: what it cost, when its outputs are about to enter the cache.
    public func elapsed(_ t: Track) -> Double { max(0, now - t.begin) }

    // Module tracks by outcome, and the time spent compiling.
    public var modules: [Track] { tracks.filter { $0.kind == .module } }
    public var bytes: Int { tracks.reduce(0) { $0 + $1.timings.bytes } }
    public var tokens: Int { tracks.reduce(0) { $0 + $1.timings.tokens } }

    // The build's one-line summary, e.g. `built app in 1.72 s · 6 modules: 1 compiled, 5 cached · link cached`.
    public var summary: String {
        let links = tracks.filter { $0.kind == .link }
        let names = links.map { ($0.name as NSString).lastPathComponent }
        var line: String
        switch status {
        case .built: line = names.isEmpty ? "built" : "built " + names.joined(separator: ", ")
        case .stopped: line = "stopped"
        case .failed: line = "build failed"
        }
        line += (status == .built ? " in " : " after ") + duration(build.end)
        let mods = modules
        if !mods.isEmpty {
            let compiled = mods.filter { $0.outcome == .compiled }.count
            let cached = mods.filter { $0.outcome == .cached }.count
            let failed = mods.filter { $0.outcome == .failed }.count
            line += " · \(mods.count) module\(mods.count == 1 ? "" : "s"): \(compiled) compiled, \(cached) cached"
                + (failed > 0 ? ", \(failed) failed" : "")
        }
        if !links.isEmpty {
            let cached = links.filter { $0.outcome == .cached }.count
            let linked = links.filter { $0.outcome == .compiled }.count
            if links.count == 1 { line += cached == 1 ? " · link cached" : linked == 1 ? " · linked" : "" }
            else { line += " · \(links.count) links: \(linked) linked, \(cached) cached" }
        }
        return line
    }

    // End the build's record, write its report under `build/_perf/`, and print its summary and the report page's
    // link to stderr. Called on the success path and before an error exit, so every invocation reports. A build
    // that stops before taking the workspace's lock writes no report and removes the last build's, so no tool
    // reads it as this build's.
    public func report(_ status: Status = .failed, binaries: [String] = []) {
        build.end = now
        self.status = status
        var page: String? = nil
        if let buildRoot {
            let dir = buildRoot + "/" + PerfReport.directory
            if holdsLock {
                let report = PerfReport(self, binaries: binaries)
                if Layout.makeDirectory(dir, buildRoot: buildRoot), let json = report.encoded(),
                   PerfReport.replace(dir + "/" + PerfReport.fileName, with: json) {
                    _ = TraceFile.write(report, to: dir)
                    if ReportPage.write(json: json, to: dir) { page = dir + "/" + ReportPage.fileName }
                }
            } else {
                for name in [PerfReport.fileName, TraceFile.fileName, ReportPage.fileName] {
                    try? FileManager.default.removeItem(atPath: dir + "/" + name)
                }
            }
        }
        var out = summary + "\n"
        if let page { out += "report: " + URL(fileURLWithPath: page).absoluteString + "\n" }
        FileHandle.standardError.write(Data(out.utf8))
    }

    private func duration(_ s: Double) -> String {
        s < 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.2f s", s)
    }
}
