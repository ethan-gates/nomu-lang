import Foundation

struct CompileResult {
    var ok: Bool
    var timedOut: Bool
    var stderr: String
    var duration: Double
}

// Compiles each distinct (fixture, compile settings) once into a keyed cache the run phase reads. Two cases
// sharing a compile config (e.g. a default leg and a stress leg) build a single binary.
//
// `nomu build` writes a fixture's outputs to one place whatever its settings, so the configurations of one
// fixture compile one after another, and each binary (with its object, for the symbol checks) is copied to
// its configuration's own path (`Ctx.configBinaryPath`) before the next build overwrites it. Different
// fixtures compile in parallel. Task 198 places outputs by configuration in the driver; then configurations
// of one fixture compile in parallel too and the copy goes away.
final class CompileCache {
    private var results: [String: CompileResult] = [:]
    private let lock = NSLock()

    func result(for key: String) -> CompileResult {
        lock.lock(); defer { lock.unlock() }
        return results[key]!
    }

    func compileAll(_ selected: [ResolvedCase], ctx: Ctx, gate: WeightedGate, progress: Progress) {
        var seen = Set<String>()
        var byFixture: [String: [ResolvedCase]] = [:]
        var fixtureOrder: [String] = []
        for c in selected where seen.insert(c.compileKey).inserted {
            if byFixture[c.fixture] == nil { fixtureOrder.append(c.fixture) }
            byFixture[c.fixture, default: []].append(c)
        }
        progress.beginPhase("compiling", total: seen.count)
        // The acquire-before-dispatch discipline that keeps a large job count from wedging the pool lives
        // once, in `WeightedGate.dispatch`; both phases route through it so it can't be half-applied. Each
        // fixture is one lane. No deadline here — a single hung compile is bounded by its own `runProcess`
        // timeout, and the bounded dispatch prevents the worker-starvation wedge the old eager loop had.
        gate.dispatch(fixtureOrder) { fixture in
            let stem = ctx.fixtureStem(fixture)
            for job in byFixture[fixture]! {
                progress.start(stem)
                // `nomu build <fixture dir>`: plans the fixture's build, compiles every module, and links.
                let r = runProcess(path: ctx.nomu,
                                   args: ["build"] + job.compileArgs + ctx.compileInputs(fixture),
                                   env: job.compileEnv, timeout: job.compileTimeout)
                var res = CompileResult(ok: r.succeeded, timedOut: r.timedOut, stderr: r.stderr, duration: r.duration)
                if res.ok, job.compile?.expectError == nil, let err = keepBinary(ctx.binaryPath(fixture), at: ctx.configBinaryPath(job)) {
                    res.ok = false
                    res.stderr += "compiler-test: " + err + "\n"
                }
                self.lock.lock(); self.results[job.compileKey] = res; self.lock.unlock()
                progress.finishCompile(stem)
            }
        }
        progress.endPhase()
    }
}

// Copy a built binary and its object to a configuration's path. Returns an error message on failure.
private func keepBinary(_ built: String, at dest: String) -> String? {
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for (from, to) in [(built, dest), (built + ".o", dest + ".o")] {
            if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
            if fm.fileExists(atPath: from) { try fm.copyItem(atPath: from, toPath: to) }
        }
        guard fm.fileExists(atPath: dest) else { return "no binary at '\(built)' after the build" }
        return nil
    } catch {
        return "cannot keep binary '\(built)' at '\(dest)': \(error)"
    }
}
