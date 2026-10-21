import Foundation

// The declarative case list — the single source of truth for a case's settings, so a run can never
// silently forget or duplicate a flag (the silent-green hazard). Keys are snake_case in JSON;
// `.convertFromSnakeCase` maps them to these camelCase properties. Unknown keys are rejected
// (`checkKeys`), so a mistyped or retired field fails the load rather than being ignored.
//
// Two ways to declare runs: a flat `case` (one fixture, one configuration), and a `group`, which names
// fixtures by a directory glob and spans the `dimensions` it lists — one run per fixture and combination
// of dimension values, named `group/fixture/value/…`.

struct Manifest: Decodable {
    var defaults: Defaults?
    var dimensions: [String: [DimensionValue]]?
    var groups: [Group]?
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

// A symbol-count assertion over the fixture's own object (`<binary>.o`): lines naming a symbol that contains
// `pattern`. `object_symbols` counts defined symbols (`nm -U`) — what the object defines, e.g. that no
// runtime / `std` definition is duplicated into it; `object_references` counts undefined ones (`nm -u`) —
// what the object calls out to, e.g. whether a safepoint slow path is reachable from its code.
struct SymbolMatch: Decodable {
    var pattern: String
    var min: Int?
    var max: Int?
}

// A run's tier: `fast` runs by default, `full` adds the expensive legs (`--tier full`).
enum Tier: String, Decodable, Comparable {
    case fast, full
    static func < (a: Tier, b: Tier) -> Bool { a == .fast && b == .full }
    // Wall-clock budget for a run of the tier; exceeding it is reported.
    var budgetSec: Double { self == .fast ? 60 : 300 }
}

// One value of a dimension: the settings it adds, the collections a run under it must log, and its tier.
struct DimensionValue: Decodable {
    var name: String
    var compileSettings: Settings?
    var runSettings: Settings?
    var requireCollections: Int?
    var tier: Tier?
}

struct Group: Decodable {
    var name: String
    var fixtures: String          // a directory glob: `dir/*` (every subdirectory of `dir`)
    var across: [String]          // dimension names, in name order
    var expect: Expect?           // the default; a fixture's own `expected.txt` wins
    var compileSettings: Settings?
    var runSettings: Settings?
    var iterations: Int?
    var fullIterations: Int?
    var carriers: [Int]?
    var timeoutSec: Double?
    var weight: Int?
    var tier: Tier?
    var stderrMatch: [StderrMatch]?
}

struct Case: Decodable {
    var name: String
    var fixture: String
    var compileArgs: [String]?
    var compileSettings: Settings?
    var runSettings: Settings?
    var expect: Expect?
    var iterations: Int?
    // Repetitions under `--tier full`, when more than `iterations`: a case repeated to catch a timing-dependent
    // race runs a few times in the fast tier and its full count in the full tier.
    var fullIterations: Int?
    var carriers: [Int]?
    var timeoutSec: Double?
    var compileTimeoutSec: Double?
    var heavy: Bool?
    var weight: Int?
    var compile: CompileSpec?
    var stderrMatch: [StderrMatch]?
    var objectSymbols: [SymbolMatch]?
    var objectReferences: [SymbolMatch]?
    var stdinFile: String?
    var stdinDelayMs: Int?
    var tier: Tier?
    // Run alone, after the pool drains, with the host otherwise idle: a case whose result depends on
    // timing (a delayed stdin feed racing other fibers).
    var timingSensitive: Bool?
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
    var objectSymbols: [SymbolMatch]
    var objectReferences: [SymbolMatch]
    var stdinFile: String?   // repo-relative file fed to the program's stdin (default: /dev/null)
    var stdinDelayMs: Int    // how long after start the file's bytes are written into the stdin pipe
    var tier: Tier
    var timingSensitive: Bool
    var dims: [String: String]   // dimension → value, for a group run (selection by `--where`)

    // Key for shared compilation — a fixture built once per distinct (compile-env, compile-args).
    var compileKey: String {
        let env = compileEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return fixture + "\u{0}" + env + "\u{0}" + compileArgs.joined(separator: " ")
    }
}

// The line the runtime logs per collection (`gc_log`), counted by a dimension's `require_collections`.
let collectionLogPattern = "nomu-gc-sync: collection"

extension Manifest {
    // The number of cores a case saturates — its pool weight (task: CPU-aware scheduling). A case advertises
    // this so the run pool never admits more concurrent cores than the host has (minus a buffer). Default it
    // from the run shape: a carrier matrix peaks at its largest carrier count (each carrier is a scheduler
    // worker thread the runtime pins to a core); an **empty** carriers list is a self-threading fixture, which
    // the runtime boots with its own default of 4 carriers. Explicit `weight` overrides; legacy `heavy` takes
    // the whole pool. Clamped to the pool so a case can never deadlock it.
    static let selfThreadingCarriers = 4   // the runtime's default carrier count when NOMU_CARRIERS is unset
    private static func weight(explicit: Int?, heavy: Bool, carriers: [Int], capacity: Int) -> Int {
        if let w = explicit { return min(max(1, w), capacity) }
        if heavy { return capacity }
        let peak = carriers.isEmpty ? selfThreadingCarriers : (carriers.max() ?? 1)
        return max(1, min(peak, capacity))
    }

    // A case's repetitions for the tier being run: `full_iterations` under `--tier full`, else `iterations`.
    private func iterations(_ fast: Int?, _ full: Int?, tier: Tier) -> Int {
        let base = fast ?? defaults?.iterations ?? 1
        return tier == .full ? max(base, full ?? base) : base
    }

    func resolvedCases(capacity: Int, projectRoot: String, tier: Tier) -> [ResolvedCase] {
        let d = defaults
        var out: [ResolvedCase] = cases.map { c in
            let carriers = c.carriers ?? d?.carriers ?? [1]
            let owner = "case '\(c.name)'"
            let compile = lower(c.compileSettings ?? [:], at: .compile, in: owner)
            let run = lower(c.runSettings ?? [:], at: .run, in: owner)
            return ResolvedCase(
                name: c.name,
                fixture: c.fixture,
                compileArgs: compile.args + (c.compileArgs ?? []),
                compileEnv: compile.env,
                runEnv: run.env,
                expect: c.expect,
                iterations: iterations(c.iterations, c.fullIterations, tier: tier),
                carriers: carriers,
                runTimeout: c.timeoutSec ?? d?.timeoutSec ?? 60,
                compileTimeout: c.compileTimeoutSec ?? d?.compileTimeoutSec ?? 120,
                weight: Manifest.weight(explicit: c.weight, heavy: c.heavy ?? d?.heavy ?? false,
                                        carriers: carriers, capacity: capacity),
                compile: c.compile,
                stderrMatch: c.stderrMatch ?? [],
                objectSymbols: c.objectSymbols ?? [],
                objectReferences: c.objectReferences ?? [],
                stdinFile: c.stdinFile,
                stdinDelayMs: c.stdinDelayMs ?? 0,
                tier: c.tier ?? .fast,
                timingSensitive: c.timingSensitive ?? false,
                dims: [:]
            )
        }
        for g in groups ?? [] { out += expand(g, capacity: capacity, projectRoot: projectRoot, tier: tier) }
        var seen = Set<String>()
        for c in out where !seen.insert(c.name).inserted { die("duplicate case name '\(c.name)'") }
        return out
    }

    // One run per fixture the glob names and per combination of the group's dimension values.
    private func expand(_ g: Group, capacity: Int, projectRoot: String, tier runTier: Tier) -> [ResolvedCase] {
        let d = defaults
        let axes: [(String, [DimensionValue])] = g.across.map { axis in
            guard let values = dimensions?[axis], !values.isEmpty else {
                die("group '\(g.name)': unknown dimension '\(axis)'")
            }
            return (axis, values)
        }
        var combos: [[(String, DimensionValue)]] = [[]]
        for (axis, values) in axes {
            combos = combos.flatMap { prefix in values.map { prefix + [(axis, $0)] } }
        }
        let carriers = g.carriers ?? d?.carriers ?? [1]
        var out: [ResolvedCase] = []
        for fixture in expandFixtureGlob(g.fixtures, group: g.name, projectRoot: projectRoot) {
            let leaf = (fixture as NSString).lastPathComponent
            let own = projectRoot + "/" + fixture + "/expected.txt"
            let expect = FileManager.default.fileExists(atPath: own)
                ? Expect(stdout: nil, stdoutFile: fixture + "/expected.txt") : g.expect
            for combo in combos {
                let name = ([g.name, leaf] + combo.map { $0.1.name }).joined(separator: "/")
                var compileSettings = g.compileSettings ?? [:]
                var runSettings = g.runSettings ?? [:]
                var match = g.stderrMatch ?? []
                var tier = g.tier ?? .fast
                for (_, v) in combo {
                    compileSettings.merge(v.compileSettings ?? [:]) { _, new in new }
                    runSettings.merge(v.runSettings ?? [:]) { _, new in new }
                    if let n = v.requireCollections {
                        runSettings["gc_log"] = .bool(true)
                        match.append(StderrMatch(pattern: collectionLogPattern, min: n, max: nil))
                    }
                    tier = max(tier, v.tier ?? .fast)
                }
                let owner = "group '\(g.name)'"
                let compile = lower(compileSettings, at: .compile, in: owner)
                let run = lower(runSettings, at: .run, in: owner)
                out.append(ResolvedCase(
                    name: name, fixture: fixture,
                    compileArgs: compile.args, compileEnv: compile.env, runEnv: run.env,
                    expect: expect,
                    iterations: iterations(g.iterations, g.fullIterations, tier: runTier),
                    carriers: carriers,
                    runTimeout: g.timeoutSec ?? d?.timeoutSec ?? 60,
                    compileTimeout: d?.compileTimeoutSec ?? 120,
                    weight: Manifest.weight(explicit: g.weight, heavy: false, carriers: carriers, capacity: capacity),
                    compile: nil, stderrMatch: match, objectSymbols: [], objectReferences: [],
                    stdinFile: nil, stdinDelayMs: 0,
                    tier: tier, timingSensitive: false,
                    dims: Dictionary(uniqueKeysWithValues: combo.map { ($0.0, $0.1.name) })))
            }
        }
        return out
    }
}

// The fixture directories a group glob names: `dir/*` is every subdirectory of `dir` (repo-relative), in
// name order.
private func expandFixtureGlob(_ glob: String, group: String, projectRoot: String) -> [String] {
    guard glob.hasSuffix("/*") else { die("group '\(group)': fixtures must be a `dir/*` glob, got '\(glob)'") }
    let dir = String(glob.dropLast(2))
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: projectRoot + "/" + dir) else {
        die("group '\(group)': no directory '\(dir)'")
    }
    var isDir: ObjCBool = false
    return entries.sorted().filter { e in
        !e.hasPrefix(".") && fm.fileExists(atPath: projectRoot + "/" + dir + "/" + e, isDirectory: &isDir) && isDir.boolValue
    }.map { dir + "/" + $0 }
}

func loadManifest(_ path: String) throws -> Manifest {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    checkKeys(try JSONSerialization.jsonObject(with: data), path: path)
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(Manifest.self, from: data)
}

// Reject keys the schema does not define, at every level that has a fixed set.
private let topKeys: Set<String> = ["defaults", "dimensions", "groups", "cases", "computed_order"]
private let defaultsKeys: Set<String> = ["timeout_sec", "compile_timeout_sec", "iterations", "carriers", "heavy"]
private let caseKeys: Set<String> = [
    "name", "fixture", "compile_args", "compile_settings", "run_settings", "expect", "iterations",
    "full_iterations", "carriers",
    "timeout_sec", "compile_timeout_sec", "heavy", "weight", "compile", "stderr_match", "object_symbols",
    "object_references", "stdin_file", "stdin_delay_ms", "tier", "timing_sensitive",
]
private let groupKeys: Set<String> = [
    "name", "fixtures", "across", "expect", "compile_settings", "run_settings", "iterations", "full_iterations",
    "carriers",
    "timeout_sec", "weight", "tier", "stderr_match",
]
private let dimensionValueKeys: Set<String> = ["name", "compile_settings", "run_settings", "require_collections", "tier"]

private func checkKeys(_ json: Any, path: String) {
    func check(_ obj: Any?, _ allowed: Set<String>, _ owner: String) {
        guard let o = obj as? [String: Any] else { return }
        for k in o.keys where !allowed.contains(k) { die("\(path): \(owner): unknown key '\(k)'") }
    }
    guard let top = json as? [String: Any] else { return }
    check(top, topKeys, "manifest")
    check(top["defaults"], defaultsKeys, "defaults")
    for c in top["cases"] as? [[String: Any]] ?? [] { check(c, caseKeys, "case '\(c["name"] ?? "?")'") }
    for g in top["groups"] as? [[String: Any]] ?? [] { check(g, groupKeys, "group '\(g["name"] ?? "?")'") }
    for (axis, values) in top["dimensions"] as? [String: Any] ?? [:] {
        for v in values as? [[String: Any]] ?? [] { check(v, dimensionValueKeys, "dimension '\(axis)'") }
    }
}
