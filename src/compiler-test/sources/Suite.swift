import Foundation

// A fixed-capacity pool where each case occupies `weight` lanes. A self-parallelizing case (a carrier
// matrix, or a fixture that spawns its own threads) declares more lanes so the pool packs cases
// without oversubscribing. Weights above capacity are clamped, so a case never deadlocks the pool.
final class WeightedGate {
    private let cond = NSCondition()
    private let capacity: Int
    private var inFlight = 0
    init(capacity: Int) { self.capacity = capacity }

    func acquire(_ w: Int) {
        let weight = min(w, capacity)
        cond.lock(); while inFlight + weight > capacity { cond.wait() }
        inFlight += weight; cond.unlock()
    }
    func release(_ w: Int) {
        let weight = min(w, capacity)
        cond.lock(); inFlight -= weight; cond.broadcast(); cond.unlock()
    }
}

// Suite — owns the run: the pool gate, the live progress display, the compile cache, and the collected
// results. Drives compile → run → order-writeback → report and returns the process exit code.
final class Suite {
    private let ctx: Ctx
    private let gate = WeightedGate(capacity: 8)
    private let progress = Progress(StatusRenderer())
    private let cache = CompileCache()
    private let start = Date()
    private var results: [CaseResult] = []
    private let resultsLock = NSLock()

    init(_ ctx: Ctx) { self.ctx = ctx }

    func run() -> Int32 {
        let selected = lptSort(ctx.selectedCases(), order: ctx.manifest.computedOrder ?? [])
        if selected.isEmpty { die("no cases selected") }

        cache.compileAll(selected, ctx: ctx, gate: gate, progress: progress)
        guard runPhase(selected) else {
            FileHandle.standardError.write(Data(
                "error: suite deadline (\(fmt(ctx.deadline))) exceeded — a case cap failed to fire\n".utf8))
            return 3
        }
        writeBackOrder(ran: selected)
        return report()
    }

    // Dispatch the run matrix across the pool. Returns false if the suite-level deadline fires.
    //
    // Each case's lane is acquired **before** it is dispatched — not inside the async block.
    // `DispatchQueue.global().async` eagerly spins up a worker thread for every block that then blocks,
    // so acquiring inside would leave N blocked threads and, past libdispatch's worker soft limit
    // (~80), starve the pool: the running cases can't get a thread for their own pipe I/O / timeout
    // timer, never release a lane, and the whole run deadlocks. Acquiring first bounds live async
    // blocks to the pool capacity regardless of case count; the unreached tail is the "queue", held
    // back by the producer parking in `acquire`. Admission is then strictly LPT-ordered.
    //
    // The producer runs off the calling thread so the `group.wait` deadline backstop still fires even
    // if the producer parks in `acquire` (a wedged case that never releases a lane). A held enter/leave
    // pair spans the whole dispatch loop so `wait` cannot observe a momentarily-empty group between
    // dispatches and return early.
    private func runPhase(_ selected: [ResolvedCase]) -> Bool {
        let runner = CaseRunner(ctx: ctx)
        let group = DispatchGroup()
        progress.beginPhase("running", total: selected.count)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for c in selected {
                let weight = max(1, c.weight)
                self.gate.acquire(weight)
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave(); self.gate.release(weight) }
                    self.progress.start(c.name)
                    let r = runner.run(c, compile: self.cache.result(for: c.compileKey))
                    self.resultsLock.lock(); self.results.append(r); self.resultsLock.unlock()
                    // On a TTY, stream each case as it finishes (above the live status line). Off a TTY the
                    // batch report prints a sorted, deterministic list at the end instead.
                    if self.progress.interactive {
                        self.progress.logLine(r.line())
                        for line in r.detail { self.progress.logLine(line) }
                    }
                    self.progress.finishCase(c.name, r.status)
                }
            }
        }
        let backstop = DispatchTime.now() + .milliseconds(Int(ctx.deadline * 1000))
        let finished = group.wait(timeout: backstop) != .timedOut
        progress.endPhase()
        return finished
    }

    // Persist the longest-first order into the manifest — only on a full run (every manifest case ran),
    // so a subset run reads the order but never rewrites it from partial data.
    private func writeBackOrder(ran selected: [ResolvedCase]) {
        guard Set(selected.map { $0.name }) == Set(ctx.cases.map { $0.name }) else { return }
        writeComputedOrder(computeOrder(results), to: ctx.configPath)
    }

    private func report() -> Int32 {
        results.sort { $0.name < $1.name }
        if !progress.interactive {
            for r in results { print(r.line()); for line in r.detail { print(line) } }
        }
        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        let timedOut = results.filter { $0.status == .timeout }.count
        print("")
        print("== \(passed) passed, \(failed) failed, \(timedOut) timed out in \(fmt(Date().timeIntervalSince(start))) ==")
        return failed + timedOut == 0 ? 0 : 1
    }
}
