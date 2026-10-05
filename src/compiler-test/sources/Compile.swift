import Foundation

struct CompileResult {
    var ok: Bool
    var timedOut: Bool
    var stderr: String
    var duration: Double
}

// Compiles each distinct (fixture, compile_env, compile_args) once, in parallel across the pool, into a
// keyed cache the run phase reads. Two cases sharing a compile config (e.g. a nogc leg and an
// immix-evacuation leg) build a single binary.
final class CompileCache {
    private var results: [String: CompileResult] = [:]
    private let lock = NSLock()

    func result(for key: String) -> CompileResult {
        lock.lock(); defer { lock.unlock() }
        return results[key]!
    }

    func compileAll(_ selected: [ResolvedCase], ctx: Ctx, gate: WeightedGate, progress: Progress) {
        var seen = Set<String>()
        let jobs = selected.filter { seen.insert($0.compileKey).inserted }
        progress.beginPhase("compiling", total: jobs.count)
        // The acquire-before-dispatch discipline that keeps a large job count from wedging the pool lives
        // once, in `WeightedGate.dispatch`; both phases route through it so it can't be half-applied. Each
        // compile is one lane. No deadline here — a single hung compile is bounded by its own `runProcess`
        // timeout, and the bounded dispatch prevents the worker-starvation wedge the old eager loop had.
        gate.dispatch(jobs) { job in
            let stem = ctx.fixtureStem(job.fixture)
            progress.start(stem)
            let r = runProcess(path: ctx.nomuc,
                               args: job.compileArgs + ctx.compileInputs(job.fixture),
                               env: job.compileEnv, timeout: job.compileTimeout)
            let res = CompileResult(ok: r.succeeded, timedOut: r.timedOut, stderr: r.stderr, duration: r.duration)
            self.lock.lock(); self.results[job.compileKey] = res; self.lock.unlock()
            progress.finishCompile(stem)
        }
        progress.endPhase()
    }
}
