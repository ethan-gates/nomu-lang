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

        var stdinFeed: StdinFeed? = nil
        if let f = c.stdinFile {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ctx.fixturePath(f))) else {
                return result(.fail, ["  stdin_file '\(f)' missing"])
            }
            stdinFeed = StdinFeed(data: data, delayMs: c.stdinDelayMs)
        }

        var totalRun = 0.0
        // An empty carriers list means "run once without setting NOMU_CARRIERS" — for fixtures that
        // manage their own threads (the self-hosted scheduler/actor cases).
        let carrierRuns: [Int?] = c.carriers.isEmpty ? [nil] : c.carriers.map { Optional($0) }
        for carrier in carrierRuns {
            for iter in 1...c.iterations {
                var env = c.runEnv
                if let carrier = carrier { env["NOMU_CARRIERS"] = String(carrier) }
                let r = runProcess(path: bin, args: [], env: env, timeout: c.runTimeout, stdin: stdinFeed)
                totalRun += r.duration
                let runRepro = "\(envPrefix(env)) \(bin)".trimmingCharacters(in: .whitespaces)
                let at = "carrier=\(carrier.map(String.init) ?? "-") iter=\(iter)"

                if r.timedOut {
                    return result(.timeout,
                                  ["  run TIMEOUT (\(at)) after \(fmt(r.duration))"] + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if let sig = r.signal {
                    return result(.fail,
                                  ["  run crashed (\(at), signal \(sig))"] + partial(r) + ["  repro: \(runRepro)"],
                                  runTime: totalRun)
                }
                if r.exitCode != 0 {
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
