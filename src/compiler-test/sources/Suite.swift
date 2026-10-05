import Foundation

// A core-budgeted pool where each case occupies `weight` cores (its advertised saturation). Capacity is the
// host's cores minus a buffer (or `--jobs`), so the sum of concurrently-running cases never oversubscribes
// the CPU — a self-parallelizing case (a carrier matrix, or a fixture that spawns its own threads) declares
// more cores so the pool packs without starving the cooperative scheduler/STW. Weights above capacity are
// clamped, so a case never deadlocks the pool.
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

    // Dispatch `items` across the pool, admitting at most `capacity` cores of concurrent work. THE one place
    // the acquire-before-dispatch discipline lives — both the compile phase and the run phase route through
    // it, so the discipline can never be half-applied again (it shipped broken once because the two phases
    // had separate hand-written loops and only one was fixed).
    //
    // A lane is acquired on a producer thread *before* each item is dispatched — never inside the async
    // block. `DispatchQueue.global().async` eagerly spins up a worker thread per block that then blocks, so
    // acquiring inside would leave one blocked worker per *queued* item; past libdispatch's worker soft limit
    // (~80, which the suite reaches once it has that many items) the pool starves — the running items can't
    // get a worker for their own pipe I/O / timeout timer, never release a lane, and the wait wedges forever
    // (a 0-CPU, no-child hang). Acquiring first bounds live async blocks to the pool capacity regardless of
    // item count; the unreached tail is the "queue", held back by the producer parking in `acquire`.
    //
    // The producer runs off the calling thread so the `group.wait` deadline backstop still fires even if the
    // producer parks in `acquire` (a wedged item that never releases a lane). A held enter/leave pair spans
    // the whole dispatch loop so `wait` cannot observe a momentarily-empty group between dispatches and return
    // early. Returns false iff `deadline` elapses before every item finishes (nil = wait indefinitely).
    @discardableResult
    func dispatch<T>(_ items: [T], weight: @escaping (T) -> Int = { _ in 1 }, deadline: DispatchTime? = nil,
                     _ body: @escaping (T) -> Void) -> Bool {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for item in items {
                let w = max(1, weight(item))
                self.acquire(w)
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave(); self.release(w) }
                    body(item)
                }
            }
        }
        if let deadline = deadline { return group.wait(timeout: deadline) != .timedOut }
        group.wait(); return true
    }
}

// Suite — owns the run: the pool gate, the live progress display, the compile cache, and the collected
// results. Drives compile → run → order-writeback → report and returns the process exit code.
final class Suite {
    private let ctx: Ctx
    private let gate: WeightedGate
    private let progress = Progress(StatusRenderer())
    private let cache = CompileCache()
    private let start = Date()
    private var results: [CaseResult] = []
    private let resultsLock = NSLock()

    init(_ ctx: Ctx) { self.ctx = ctx; self.gate = WeightedGate(capacity: ctx.poolCapacity) }

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

    // Dispatch the run matrix across the pool (LPT-ordered admission). Each case occupies `weight` cores.
    // The acquire-before-dispatch discipline that keeps this from wedging lives once, in `WeightedGate.dispatch`.
    // Returns false if the suite-level deadline fires.
    private func runPhase(_ selected: [ResolvedCase]) -> Bool {
        let runner = CaseRunner(ctx: ctx)
        progress.beginPhase("running", total: selected.count)
        let backstop = DispatchTime.now() + .milliseconds(Int(ctx.deadline * 1000))
        let finished = gate.dispatch(selected, weight: { max(1, $0.weight) }, deadline: backstop) { c in
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
