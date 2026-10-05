import Foundation

// The declarative case list — the single source of truth for a case's env, so a run can never
// silently forget or duplicate a flag (the silent-green hazard). Keys are snake_case in JSON;
// `.convertFromSnakeCase` maps them to these camelCase properties.

struct Manifest: Decodable {
    var defaults: Defaults?
    var cases: [Case]
    // Persisted longest-first dispatch order (see Ordering.swift). Optional: absent on a fresh manifest,
    // written back by full runs.
    var computedOrder: [String]?
}

struct Defaults: Decodable {
    var timeoutSec: Double?
    var compileTimeoutSec: Double?
    var iterations: Int?
    var carriers: [Int]?
    var heavy: Bool?
}

struct Expect: Decodable {
    var stdout: String?
    var stdoutFile: String?
}

struct CompileSpec: Decodable {
    var expectError: String?
}

struct StderrMatch: Decodable {
    var pattern: String
    var min: Int?
    var max: Int?
}

struct Case: Decodable {
    var name: String
    var fixture: String
    var compileArgs: [String]?
    var compileEnv: [String: String]?
    var runEnv: [String: String]?
    var expect: Expect?
    var iterations: Int?
    var carriers: [Int]?
    var timeoutSec: Double?
    var compileTimeoutSec: Double?
    var heavy: Bool?
    var weight: Int?
    var compile: CompileSpec?
    var stderrMatch: [StderrMatch]?
}

// A case with all defaults folded in — what the runner actually executes.
struct ResolvedCase {
    var name: String
    var fixture: String
    var compileArgs: [String]
    var compileEnv: [String: String]
    var runEnv: [String: String]
    var expect: Expect?
    var iterations: Int
    var carriers: [Int]
    var runTimeout: Double
    var compileTimeout: Double
    var weight: Int   // cores this case saturates (its pool lanes); derived from the run shape, below
    var compile: CompileSpec?
    var stderrMatch: [StderrMatch]

    // Key for shared compilation — a fixture built once per distinct (compile-env, compile-args).
    var compileKey: String {
        let env = compileEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return fixture + "\u{0}" + env + "\u{0}" + compileArgs.joined(separator: " ")
    }
}

extension Manifest {
    // The number of cores a case saturates — its pool weight (task: CPU-aware scheduling). A case advertises
    // this so the run pool never admits more concurrent cores than the host has (minus a buffer). Default it
    // from the run shape: a carrier matrix peaks at its largest carrier count (each carrier is a scheduler
    // worker thread the runtime pins to a core); an **empty** carriers list is a self-threading fixture, which
    // the runtime boots with its own default of 4 carriers. Explicit `weight` overrides; legacy `heavy` takes
    // the whole pool. Clamped to the pool so a case can never deadlock it.
    static let selfThreadingCarriers = 4   // the runtime's default carrier count when NOMU_CARRIERS is unset
    private static func weight(_ c: Case, _ d: Defaults?, carriers: [Int], capacity: Int) -> Int {
        if let w = c.weight { return min(max(1, w), capacity) }
        if c.heavy ?? d?.heavy ?? false { return capacity }
        let peak = carriers.isEmpty ? selfThreadingCarriers : (carriers.max() ?? 1)
        return max(1, min(peak, capacity))
    }

    func resolvedCases(capacity: Int) -> [ResolvedCase] {
        let d = defaults
        return cases.map { c in
            let carriers = c.carriers ?? d?.carriers ?? [1]
            return ResolvedCase(
                name: c.name,
                fixture: c.fixture,
                compileArgs: c.compileArgs ?? [],
                compileEnv: c.compileEnv ?? [:],
                runEnv: c.runEnv ?? [:],
                expect: c.expect,
                iterations: c.iterations ?? d?.iterations ?? 1,
                carriers: carriers,
                runTimeout: c.timeoutSec ?? d?.timeoutSec ?? 60,
                compileTimeout: c.compileTimeoutSec ?? d?.compileTimeoutSec ?? 120,
                weight: Manifest.weight(c, d, carriers: carriers, capacity: capacity),
                compile: c.compile,
                stderrMatch: c.stderrMatch ?? []
            )
        }
    }
}

func loadManifest(_ path: String) throws -> Manifest {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(Manifest.self, from: data)
}
