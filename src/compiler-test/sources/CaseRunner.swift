import Foundation

enum Status { case pass, fail, timeout }

struct CaseResult {
    var name: String
    var status: Status
    var compileTime: Double
    var runTime: Double
    var detail: [String]     // failure diagnostics (empty on pass)
    var passes = 1           // rounds passed, under `--repeat`
    var rounds = 1

    func line() -> String {
        let tag: String
        switch status {
        case .pass:    tag = "PASS"
        case .fail:    tag = "FAIL"
        case .timeout: tag = "TIMEOUT"
        }
        let padded = name.padding(toLength: max(24, name.count + 1), withPad: " ", startingAt: 0)
        let rate = rounds > 1 ? "  passed \(passes)/\(rounds)" : ""
        return "\(tag.padding(toLength: 8, withPad: " ", startingAt: 0)) \(padded) compile \(fmt(compileTime))  run \(fmt(runTime))\(rate)"
    }
}

// Runs one case: interprets its (already computed) compile result, then the run matrix
// (run_env × carriers × iterations) against the golden output and any stderr assertions, and enforces
// the per-run timeout. Produces a single CaseResult, short-circuiting on the first failure.
struct CaseRunner {
    let ctx: Ctx

    func run(_ c: ResolvedCase, compile: CompileResult) -> CaseResult {
        let bin = ctx.configBinaryPath(c)
        let fixArg = ctx.compileInputs(c.fixture).joined(separator: " ")
        let compileArgsStr = c.compileArgs.joined(separator: " ")
        let compileRepro = "\(envPrefix(c.compileEnv)) \(ctx.nomu) build \(compileArgsStr) \(fixArg)"
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)

        func result(_ status: Status, _ detail: [String] = [], runTime: Double = 0) -> CaseResult {
            CaseResult(name: c.name, status: status, compileTime: compile.duration, runTime: runTime, detail: detail,
                       passes: status == .pass ? 1 : 0)
        }

        // Negative case: the compile itself is the test.
        if let want = c.compile?.expectError {
            if compile.timedOut {
                return result(.timeout, ["  compile timed out (expected error '\(want)')", "  repro: \(compileRepro)"])
            }
            if !compile.ok && compile.stderr.contains(want) { return result(.pass) }
            var d = compile.ok ? ["  compile succeeded but expected error '\(want)'"]
                               : ["  compile error did not contain '\(want)'"]
            d += ["  stderr:"] + indented(compile.stderr)
            d += ["  repro: \(compileRepro)"]
            return result(.fail, d)
        }

        // Positive case: compile must have succeeded before any run.
        if compile.timedOut {
            return result(.timeout, ["  compile timed out", "  repro: \(compileRepro)"])
        }
        if !compile.ok {
            return result(.fail, ["  compile failed", "  stderr:"] + indented(compile.stderr) + ["  repro: \(compileRepro)"])
        }

        // Object-symbol assertions: checked once against the fixture's own object, before any run —
        // defined symbols (`nm -U`) and undefined references (`nm -u`).
        for (flag, kind, matches) in [("-U", "symbol", c.objectSymbols), ("-u", "reference", c.objectReferences)]
            where !matches.isEmpty {
            let obj = bin + ".o"
            let nm = runProcess(path: "/usr/bin/nm", args: [flag, obj], env: [:], timeout: 30)
            if !nm.succeeded {
                return result(.fail, ["  nm failed on '\(obj)'"] + indented(nm.stderr))
            }
            for m in matches {
                let n = countOccurrences(nm.stdout, m.pattern)
                let bad = (m.min.map { n < $0 } ?? false) ? "min \(m.min!)"
                        : (m.max.map { n > $0 } ?? false) ? "max \(m.max!)" : nil
                if let bound = bad {
                    let hits = nm.stdout.split(separator: "\n").filter { $0.contains(m.pattern) }.prefix(10).map(String.init)
                    return result(.fail, ["  object \(kind) assertion failed: '\(m.pattern)' matched \(n)× (\(bound)) in \(obj)"]
                                         + hits.map { "    " + $0 } + ["  repro: nm \(flag) \(obj)"])
                }
            }
        }

        guard let want = loadGolden(c.expect) else {
            return result(.fail, ["  golden file missing for expect.stdout_file"])
        }
        var wantSignal: Int32? = nil
        if let name = c.expect?.signal {
            guard let n = signalNumber(name) else { return result(.fail, ["  expect.signal: unknown signal '\(name)'"]) }
            wantSignal = n
        }

        var stdinFeed: StdinFeed? = nil
        if let f = c.stdinFile {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ctx.fixturePath(f))) else {
                return result(.fail, ["  stdin_file '\(f)' missing"])
            }
            stdinFeed = StdinFeed(data: data, after: c.stdinAfter)
        }

        var totalRun = 0.0
        // An empty carriers list means "run once without setting NOMU_CARRIERS" — for fixtures that
        // manage their own threads (the self-hosted scheduler/actor cases).
        let carrierRuns: [Int?] = c.carriers.isEmpty ? [nil] : c.carriers.map { Optional($0) }
        for carrier in carrierRuns {
            for iter in 1...c.iterations {
                var env = c.runEnv
                if let carrier = carrier { env["NOMU_CARRIERS"] = String(carrier) }
                // A case asserting collections reads them from the run's collector report, written into a
                // directory of its own (cases share binaries and run concurrently).
                let reportDir = c.collections.isEmpty && c.reportMetrics.isEmpty ? nil
                    : NSTemporaryDirectory() + "nomu-gc-report-" + UUID().uuidString
                if let dir = reportDir {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    env["NOMU_GC_REPORT_DIR"] = dir
                }
                defer { if let dir = reportDir { try? FileManager.default.removeItem(atPath: dir) } }
                let r = runProcess(path: bin, args: [], env: env, timeout: c.runTimeout, stdin: stdinFeed)
                totalRun += r.duration
                let runRepro = "\(envPrefix(env)) \(bin)".trimmingCharacters(in: .whitespaces)
                let at = "carrier=\(carrier.map(String.init) ?? "-") iter=\(iter)"

                if r.timedOut {
                    return result(.timeout,
                                  ["  run TIMEOUT (\(at)) after \(fmt(r.duration))"] + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if let sig = r.signal, sig != wantSignal {
                    let expected = wantSignal.map { ", expected \(c.expect?.signal ?? "") (\($0))" } ?? ""
                    return result(.fail,
                                  ["  run crashed (\(at), signal \(sig)\(expected))"] + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if r.signal == nil, let w = wantSignal {
                    return result(.fail,
                                  ["  run exited \(r.exitCode ?? -1) (\(at)), expected \(c.expect?.signal ?? "") (\(w))"]
                                      + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if r.signal == nil, r.exitCode != 0 {
                    return result(.fail,
                                  ["  run exited \(r.exitCode ?? -1) (\(at))"] + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if let want = want, r.stdout != want {
                    var d = ["  stdout mismatch (\(at))"] + diffBlock(want: want, got: r.stdout)
                    if !r.stderr.isEmpty { d += ["  stderr:"] + indented(r.stderr) }
                    d += ["  repro: \(runRepro)"]
                    return result(.fail, d, runTime: totalRun)
                }
                for m in c.stderrMatch {
                    let n = countOccurrences(r.stderr, m.pattern)
                    let bad = (m.min.map { n < $0 } ?? false) ? "min \(m.min!)"
                            : (m.max.map { n > $0 } ?? false) ? "max \(m.max!)" : nil
                    if let bound = bad {
                        var d = ["  stderr assertion failed (\(at)): '\(m.pattern)' matched \(n)× (\(bound))"]
                        if !r.stderr.isEmpty { d += ["  stderr:"] + indented(r.stderr) }
                        d += ["  repro: \(runRepro)"]
                        return result(.fail, d, runTime: totalRun)
                    }
                }
                if let dir = reportDir {
                    switch reportCycles(in: dir) {
                    case .failure(let why):
                        return result(.fail, ["  collector report (\(at)): \(why)", "  repro: \(runRepro)"],
                                      runTime: totalRun)
                    case .success(let cycles):
                        if let why = metricFailure(c.reportMetrics, in: dir) {
                            return result(.fail, ["  metric assertion failed (\(at)): \(why)", "  repro: \(runRepro)"],
                                          runTime: totalRun)
                        }
                        for m in c.collections {
                            let n = cycles.filter { cy in
                                (m.kind.map { $0 == cy.kind } ?? true) && (m.trigger.map { $0 == cy.trigger } ?? true)
                                    && (m.roots.map { $0 == cy.roots } ?? true)
                            }.count
                            let what = ([m.kind, m.trigger.map { "'\($0)'" }, m.roots.map { "\($0)-root" }]
                                .compactMap { $0 } + ["cycles"]).joined(separator: " ")
                            let bad = (m.min.map { n < $0 } ?? false) ? "min \(m.min!)"
                                    : (m.max.map { n > $0 } ?? false) ? "max \(m.max!)" : nil
                            if let bound = bad {
                                let seen = cycles.map { "\($0.kind) '\($0.trigger)' \($0.roots.map(String.init) ?? "-") roots" }
                                    .joined(separator: ", ")
                                return result(.fail, ["  collection assertion failed (\(at)): \(n) \(what) (\(bound));"
                                                      + " report: \(seen.isEmpty ? "no cycles" : seen)",
                                                      "  repro: \(runRepro)"], runTime: totalRun)
                            }
                        }
                    }
                }
            }
        }
        return result(.pass, runTime: totalRun)
    }

    // stdout golden: literal, a golden file, or nil (no assertion). Returns nil to signal a broken
    // stdout_file reference.
    private func loadGolden(_ expect: Expect?) -> String?? {
        guard let e = expect else { return .some(nil) }   // no stdout assertion
        if let s = e.stdout { return .some(s) }
        if let f = e.stdoutFile {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ctx.fixturePath(f))) else { return nil }
            return .some(String(decoding: data, as: UTF8.self))
        }
        return .some(nil)
    }
}

// --- pure formatting helpers ---------------------------------------------------------------

func envPrefix(_ env: [String: String]) -> String {
    env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
}

private func indented(_ s: String) -> [String] {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }
}

private func diffBlock(want: String, got: String) -> [String] {
    ["  --- want ---"] + indented(want) + ["  --- got ---"] + indented(got)
}

private func partial(_ r: RunOutcome) -> [String] {
    var d: [String] = []
    if !r.stdout.isEmpty { d += ["  stdout:"] + indented(r.stdout) }
    if !r.stderr.isEmpty { d += ["  stderr:"] + indented(r.stderr) }
    return d
}

// Count lines containing the substring, matching the drivers' `grep -c`.
private func countOccurrences(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.split(separator: "\n", omittingEmptySubsequences: false)
        .reduce(0) { $0 + ($1.contains(needle) ? 1 : 0) }
}

// The cycles in the report written into `dir` (which must hold exactly one): each one's kind and trigger, by
// name, and its stack-root count (the `roots` counter; nil when the cycle recorded none).
struct ReportCycle {
    var kind: String
    var trigger: String
    var roots: Int?
}

func reportCycles(in dir: String) -> Result<[ReportCycle], CollectionReportError> {
    struct Report: Decodable {
        struct Names: Decodable { var kinds: [String: String]; var triggers: [String: String]; var counters: [String: String] }
        struct Cycle: Decodable { var kind: Int; var trigger: Int; var counters: [[Int]] }
        var names: Names
        var cycles: [Cycle]
    }
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".trace.json") }
    guard files.count == 1 else {
        return .failure(CollectionReportError(files.isEmpty ? "no report written (built with gc_record?)"
                                                            : "\(files.count) reports written"))
    }
    guard let data = FileManager.default.contents(atPath: dir + "/" + files[0]),
          let report = try? JSONDecoder().decode(Report.self, from: data) else {
        return .failure(CollectionReportError("cannot read \(files[0])"))
    }
    let rootsId = report.names.counters.first { $0.value == "roots" }.flatMap { Int($0.key) }
    return .success(report.cycles.map { c in
        ReportCycle(kind: report.names.kinds[String(c.kind)] ?? "kind \(c.kind)",
                    trigger: report.names.triggers[String(c.trigger)] ?? "trigger \(c.trigger)",
                    roots: c.counters.first { $0.count == 3 && $0[0] == rootsId }.map { $0[2] })
    })
}

// The first failed metric assertion over the report in `dir` (whose single report `reportCycles` has
// already checked), described, or nil when all hold.
func metricFailure(_ matches: [MetricMatch], in dir: String) -> String? {
    if matches.isEmpty { return nil }
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".trace.json") }
    guard let file = files.first, let data = FileManager.default.contents(atPath: dir + "/" + file),
          let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let metrics = report["metrics"] as? [String: Any] else { return "cannot read the report's metrics" }
    for m in matches {
        var node: Any? = metrics
        for key in m.path.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
        if m.absent == true {
            if node != nil { return "'\(m.path)' present (expected absent)" }
            continue
        }
        guard let v = (node as? NSNumber)?.doubleValue else { return "'\(m.path)' missing or not a number" }
        let show = v == v.rounded() ? String(Int(v)) : String(v)
        if let e = m.equals?.value, v != e { return "'\(m.path)' is \(show), expected \(e == e.rounded() ? String(Int(e)) : String(e))" }
        if let lo = m.min?.value, v < lo { return "'\(m.path)' is \(show) (min \(lo))" }
        if let hi = m.max?.value, v > hi { return "'\(m.path)' is \(show) (max \(hi))" }
    }
    return nil
}

struct CollectionReportError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
