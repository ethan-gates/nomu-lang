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
        // Timing-sensitive cases run after the rest, one at a time, each taking the whole pool, so no other
        // run competes with them for the host.
        let pooled = selected.filter { !$0.timingSensitive }
        let alone = selected.filter { $0.timingSensitive }
        var rounds: [[CaseResult]] = []
        for _ in 0..<ctx.repeatCount {
            results = []
            guard runPhase(pooled, weight: { max(1, $0.weight) }),
                  runPhase(alone, weight: { _ in self.ctx.poolCapacity }) else {
                FileHandle.standardError.write(Data(
                    "error: suite deadline (\(fmt(ctx.deadline))) exceeded — a case cap failed to fire\n".utf8))
                return 3
            }
            rounds.append(results)
        }
        results = merge(rounds)
        writeBackOrder(ran: selected)
        return report()
    }

    // One result per case across `--repeat` rounds: the worst status, the detail of its first failure, the
    // mean times, and the count of rounds it passed.
    private func merge(_ rounds: [[CaseResult]]) -> [CaseResult] {
        guard rounds.count > 1 else { return rounds.first ?? [] }
        var byName: [String: [CaseResult]] = [:]
        for round in rounds { for r in round { byName[r.name, default: []].append(r) } }
        return byName.map { name, rs in
            let failed = rs.first { $0.status != .pass }
            let n = Double(rs.count)
            return CaseResult(name: name, status: failed?.status ?? .pass,
                              compileTime: rs[0].compileTime, runTime: rs.reduce(0) { $0 + $1.runTime } / n,
                              detail: failed?.detail ?? [],
                              passes: rs.filter { $0.status == .pass }.count, rounds: rs.count)
        }
    }

    // Dispatch the run matrix across the pool (LPT-ordered admission). Each case occupies `weight` cores.
    // The acquire-before-dispatch discipline that keeps this from wedging lives once, in `WeightedGate.dispatch`.
    // Returns false if the suite-level deadline fires.
    private func runPhase(_ selected: [ResolvedCase], weight: @escaping (ResolvedCase) -> Int) -> Bool {
        guard !selected.isEmpty else { return true }
        let runner = CaseRunner(ctx: ctx)
        progress.beginPhase("running", total: selected.count)
        let backstop = DispatchTime.now() + .milliseconds(Int(ctx.deadline * 1000))
        let finished = gate.dispatch(selected, weight: weight, deadline: backstop) { c in
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

    // Persist the longest-first order into the manifest — only when the selection is a whole tier, so a
    // filtered run reads the order but never rewrites it from partial data. Cases the tier did not run (the
    // `full` tier's extra legs, on a `fast` run) keep their earlier ranking, after the measured ones.
    private func writeBackOrder(ran selected: [ResolvedCase]) {
        guard ctx.selectsWholeTier, ctx.repeatCount == 1 else { return }
        let measured = computeOrder(results)
        let ran = Set(measured)
        let known = Set(ctx.cases.map { $0.name })
        let rest = (ctx.manifest.computedOrder ?? []).filter { !ran.contains($0) && known.contains($0) }
        writeComputedOrder(measured + rest, to: ctx.configPath)
    }

    private func report() -> Int32 {
        results.sort { $0.name < $1.name }
        if !progress.interactive {
            for r in results { print(r.line()); for line in r.detail { print(line) } }
        }
        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        let timedOut = results.filter { $0.status == .timeout }.count
        let wall = Date().timeIntervalSince(start)
        let slowest = results.sorted { $0.runTime > $1.runTime }.prefix(5)
        print("")
        print("slowest: " + slowest.map { "\($0.name) \(fmt($0.runTime))" }.joined(separator: ", "))
        if ctx.repeatCount > 1 {
            let flaky = results.filter { $0.passes > 0 && $0.passes < $0.rounds }
            if !flaky.isEmpty {
                print("flaky: " + flaky.map { "\($0.name) \($0.passes)/\($0.rounds)" }.joined(separator: ", "))
            }
        }
        if ctx.selectsWholeTier, ctx.repeatCount == 1, wall > ctx.tier.budgetSec {
            print("note: the \(ctx.tier.rawValue) tier took \(fmt(wall)), over its \(fmt(ctx.tier.budgetSec)) budget")
        }
        print("== \(passed) passed, \(failed) failed, \(timedOut) timed out in \(fmt(wall)) (tier \(ctx.tier.rawValue)) ==")
        return failed + timedOut == 0 ? 0 : 1
    }
}
