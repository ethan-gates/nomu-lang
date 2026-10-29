import Foundation

// The build's timeline (task 193): `build/_perf/trace.json` in the Chrome trace-event format (Bazel's
// `--profile`, Clang's `-ftime-trace`), for Perfetto (ui.perfetto.dev) or `chrome://tracing`. One track per unit
// of work, named after it. On each track, one complete event (`ph: X`, `ts` + `dur` in µs) spans the unit; inside
// it, one per run of consecutive stages in the same phase; inside that, one per stage. Viewers nest events by
// containment, so stages are placed one after another inside their unit (a stage timed elsewhere and reported as
// it ends lands a microsecond late). The unit's facts (outcome, cost, reason, bytes, whether it is on the critical
// path) are the unit event's `args`. Written from the same data as `report.json`; the derived totals stay there.
enum TraceFile {
    static let fileName = "trace.json"

    // One trace event. Absent fields are left out of the JSON.
    struct Event: Encodable {
        var ph: String
        var pid = 1
        var tid: Int? = nil
        var name: String
        var cat: String? = nil
        var ts: Int? = nil
        var dur: Int? = nil
        var args: Args? = nil
    }
    // An event's `args`: a track's name or sort index, or a unit's facts.
    struct Args: Encodable {
        var name: String? = nil
        var sort_index: Int? = nil
        var kind: String? = nil
        var outcome: String? = nil
        var bytes: Int? = nil
        var tokens: Int? = nil
        var critical: Bool? = nil
        var cost_us: Int? = nil
        var reason: String? = nil
        var dependencies: [String]? = nil
    }
    struct File: Encodable {
        struct Other: Encodable {
            var started: String, status: String, package: String, critical_path_us: Int, wall_us: Int
        }
        var traceEvents: [Event]
        var displayTimeUnit = "ms"
        var otherData: Other
    }

    static func events(_ report: PerfReport) -> [Event] {
        let critical = Set(report.criticalPath.units)
        var events = [Event(ph: "M", name: "process_name", args: Args(name: "nomu build"))]
        for (i, u) in report.units.enumerated() {
            let tid = i + 1
            events.append(Event(ph: "M", tid: tid, name: "thread_name", args: Args(name: u.name)))
            events.append(Event(ph: "M", tid: tid, name: "thread_sort_index", args: Args(sort_index: tid)))
            let args = Args(kind: u.kind, outcome: u.outcome, bytes: u.bytes, tokens: u.tokens,
                            critical: critical.contains(u.name), cost_us: u.cost, reason: u.reason,
                            dependencies: u.dependencies.isEmpty ? nil : u.dependencies)
            let unitEnd = u.start + u.dur
            events.append(Event(ph: "X", tid: tid, name: u.name, cat: u.kind, ts: u.start, dur: u.dur, args: args))

            // A unit's stages run one after another; a stage reported as it ends (a `StageSink`) is placed a moment
            // late, so each starts no earlier than the one before it ends, and none leaves the unit.
            var placed: [(phase: String, name: String, start: Int, end: Int)] = []
            var cursor = u.start
            for s in u.spans.sorted(by: { ($0.start, $0.dur) < ($1.start, $1.dur) }) {
                let start = min(max(s.start, cursor), unitEnd)
                let end = min(max(s.start + s.dur, start), unitEnd)
                placed.append((s.phase, s.name, start, end))
                cursor = end
            }
            // Runs of consecutive stages in one phase.
            var i = 0
            while i < placed.count {
                var j = i
                while j + 1 < placed.count && placed[j + 1].phase == placed[i].phase { j += 1 }
                let run = placed[i...j]
                events.append(Event(ph: "X", tid: tid, name: placed[i].phase, cat: "phase", ts: run.first!.start,
                                    dur: run.last!.end - run.first!.start))
                for s in run {
                    events.append(Event(ph: "X", tid: tid, name: s.name, cat: s.phase, ts: s.start, dur: s.end - s.start))
                }
                i = j + 1
            }
        }
        return events
    }

    // Write `trace.json` into `dir`, replacing the last build's in one rename.
    static func write(_ report: PerfReport, to dir: String) -> Bool {
        let file = File(traceEvents: events(report),
                        otherData: .init(started: report.started, status: report.status, package: report.package,
                                         critical_path_us: report.criticalPath.dur, wall_us: report.dur))
        guard let data = try? JSONEncoder().encode(file) else {
            fputs("error: cannot encode the build trace\n", stderr); return false
        }
        return PerfReport.replace(dir + "/" + fileName, with: data)
    }
}
