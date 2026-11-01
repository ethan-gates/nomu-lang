import Foundation
import yaml

// The declarative case list — the single source of truth for a case's settings, so a run can never
// silently forget or duplicate a flag (the silent-green hazard). The manifest is a directory: `suite.yaml`
// (defaults, dimensions, groups) and `cases/*.yaml`, each a `cases` list. Keys are snake_case in YAML; each
// type's `CodingKeys` maps them to its camelCase properties. `YAMLDecoder` rejects unknown keys, so a
// mistyped or retired field fails the load with its position.
//
// Two ways to declare runs: a flat `case` (one fixture, one configuration), and a `group`, which names
// fixtures by a directory glob and spans the `dimensions` it lists — one run per fixture and combination
// of dimension values, named `group/fixture/value/…`.

struct Manifest {
    var defaults: Defaults?
    var dimensions: [String: [DimensionValue]]?
    var groups: [Group]?
    var cases: [Case]
}

// `suite.yaml`.
struct SuiteFile: Decodable {
    var defaults: Defaults?
    var dimensions: [String: [DimensionValue]]?
    var groups: [Group]?
}

// One `cases/<area>.yaml`.
struct CasesFile: Decodable {
    var cases: [Case]
}

// A number written either way, `60` or `0.5`: YAML Core reads `60` as an integer, which `Double` refuses.
struct Number: Decodable, Equatable {
    var value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = Double(i) } else { value = try c.decode(Double.self) }
    }
}

struct Defaults: Decodable {
    var timeoutSec: Number?
    var compileTimeoutSec: Number?
    var iterations: Int?
    var carriers: [Int]?
    var heavy: Bool?
    enum CodingKeys: String, CodingKey {
        case timeoutSec = "timeout_sec", compileTimeoutSec = "compile_timeout_sec", iterations, carriers, heavy
    }
}

struct Expect: Decodable {
    var stdout: String?
    var stdoutFile: String?
    enum CodingKeys: String, CodingKey { case stdout, stdoutFile = "stdout_file" }
}

struct CompileSpec: Decodable {
    var expectError: String?
    enum CodingKeys: String, CodingKey { case expectError = "expect_error" }
}

struct StderrMatch: Decodable {
    var pattern: String
    var min: Int?
    var max: Int?
}

// A collection-count assertion, read from the run's collector report (`gc.record`, written into a directory
// the runner names through `NOMU_GC_REPORT_DIR`): the cycles of `kind` (a name from the report's `names.kinds`,
// e.g. `minor`), raised by `trigger` (a name from `names.triggers`, e.g. `program request`), and with exactly
// `roots` stack roots; an absent field matches every cycle. A case that asserts collections compiles with
// `gc_record`.
struct CollectionMatch: Decodable {
    var kind: String?
    var trigger: String?
    var roots: Int?
    var min: Int?
    var max: Int?
}

// A metric assertion, read from the same report: the value at `path` (dot-separated keys under the report's
// `metrics`, e.g. `allocation.objects`) equals `equals`, or lies within `min`/`max`; or, with `absent`, the
// path is not in the report (`allocation` below the `full` level). A case with one compiles with `gc_record`.
struct MetricMatch: Decodable {
    var path: String
    var equals: Number?
    var min: Number?
    var max: Number?
    var absent: Bool?
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

// One value of a dimension: the settings it adds, the collections a run under it must report, and its tier.
struct DimensionValue: Decodable {
    var name: String
    var compileSettings: Settings?
    var runSettings: Settings?
    var collections: [CollectionMatch]?
    var tier: Tier?
    enum CodingKeys: String, CodingKey {
        case name, compileSettings = "compile_settings", runSettings = "run_settings", collections, tier
    }
}

struct Group: Decodable {
    var name: String
    var fixtures: String          // a directory glob: `dir/*` (every subdirectory of `dir`)
    var exclude: [String]?        // subdirectories the glob leaves out, by name
    var across: [String]          // dimension names, in name order
    var expect: Expect?           // the default; a fixture's own `expected.txt` wins
    var compileSettings: Settings?
    var runSettings: Settings?
    var iterations: Int?
    var fullIterations: Int?
    var carriers: [Int]?
    var timeoutSec: Number?
    var weight: Int?
    var tier: Tier?
    var stderrMatch: [StderrMatch]?
    enum CodingKeys: String, CodingKey {
        case name, fixtures, exclude, across, expect, compileSettings = "compile_settings", runSettings = "run_settings",
             iterations, fullIterations = "full_iterations", carriers, timeoutSec = "timeout_sec", weight, tier,
             stderrMatch = "stderr_match"
    }
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
    var timeoutSec: Number?
    var compileTimeoutSec: Number?
    var heavy: Bool?
    var weight: Int?
    var compile: CompileSpec?
    var stderrMatch: [StderrMatch]?
    var collections: [CollectionMatch]?
    var reportMetrics: [MetricMatch]?
    var objectSymbols: [SymbolMatch]?
    var objectReferences: [SymbolMatch]?
    var stdinFile: String?
    var stdinAfter: String?
    var tier: Tier?
    enum CodingKeys: String, CodingKey {
        case name, fixture, compileArgs = "compile_args", compileSettings = "compile_settings",
             runSettings = "run_settings", expect, iterations, fullIterations = "full_iterations", carriers,
             timeoutSec = "timeout_sec", compileTimeoutSec = "compile_timeout_sec", heavy, weight, compile,
             stderrMatch = "stderr_match", collections, reportMetrics = "report_metrics",
             objectSymbols = "object_symbols", objectReferences = "object_references", stdinFile = "stdin_file",
             stdinAfter = "stdin_after", tier
    }
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
    var collections: [CollectionMatch]
    var reportMetrics: [MetricMatch]
    var objectSymbols: [SymbolMatch]
    var objectReferences: [SymbolMatch]
    var stdinFile: String?   // repo-relative file fed to the program's stdin (default: /dev/null)
    var stdinAfter: String?  // the file's bytes are written into the stdin pipe once stderr shows this text
    var tier: Tier
    var dims: [String: String]   // dimension → value, for a group run (selection by `--where`)

    // Key for shared compilation — a fixture built once per distinct (compile-env, compile-args).
    var compileKey: String {
        let env = compileEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return fixture + "\u{0}" + env + "\u{0}" + compileArgs.joined(separator: " ")
    }
}

// A case that reads the collector's report (asserting collections or metrics) records: its compile settings gain
// `gc_record`, unless they already record at `full` (the later config would win and lower the level).
func recording(_ settings: Settings, reads: Bool) -> Settings {
    if !reads || settings["gc_record_full"] == .bool(true) { return settings }
    var s = settings
    s["gc_record"] = .bool(true)
    return s
}

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
            let reads = !(c.collections ?? []).isEmpty || !(c.reportMetrics ?? []).isEmpty
            let compile = lower(recording(c.compileSettings ?? [:], reads: reads), at: .compile, in: owner)
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
                runTimeout: (c.timeoutSec ?? d?.timeoutSec)?.value ?? 60,
                compileTimeout: (c.compileTimeoutSec ?? d?.compileTimeoutSec)?.value ?? 120,
                weight: Manifest.weight(explicit: c.weight, heavy: c.heavy ?? d?.heavy ?? false,
                                        carriers: carriers, capacity: capacity),
                compile: c.compile,
                stderrMatch: c.stderrMatch ?? [],
                collections: c.collections ?? [],
                reportMetrics: c.reportMetrics ?? [],
                objectSymbols: c.objectSymbols ?? [],
                objectReferences: c.objectReferences ?? [],
                stdinFile: c.stdinFile,
                stdinAfter: c.stdinAfter,
                tier: c.tier ?? .fast,
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
        let excluded = Set(g.exclude ?? [])
        let fixtures = expandFixtureGlob(g.fixtures, group: g.name, projectRoot: projectRoot)
        for name in excluded where !fixtures.contains(where: { ($0 as NSString).lastPathComponent == name }) {
            die("group '\(g.name)': excludes '\(name)', which its glob does not name")
        }
        for fixture in fixtures where !excluded.contains((fixture as NSString).lastPathComponent) {
            let leaf = (fixture as NSString).lastPathComponent
            let own = projectRoot + "/" + fixture + "/expected.txt"
            let expect = FileManager.default.fileExists(atPath: own)
                ? Expect(stdout: nil, stdoutFile: fixture + "/expected.txt") : g.expect
            for combo in combos {
                let name = ([g.name, leaf] + combo.map { $0.1.name }).joined(separator: "/")
                var compileSettings = g.compileSettings ?? [:]
                var runSettings = g.runSettings ?? [:]
                let match = g.stderrMatch ?? []
                var collections: [CollectionMatch] = []
                var tier = g.tier ?? .fast
                for (_, v) in combo {
                    compileSettings.merge(v.compileSettings ?? [:]) { _, new in new }
                    runSettings.merge(v.runSettings ?? [:]) { _, new in new }
                    collections += v.collections ?? []
                    tier = max(tier, v.tier ?? .fast)
                }
                let owner = "group '\(g.name)'"
                let compile = lower(recording(compileSettings, reads: !collections.isEmpty), at: .compile, in: owner)
                let run = lower(runSettings, at: .run, in: owner)
                out.append(ResolvedCase(
                    name: name, fixture: fixture,
                    compileArgs: compile.args, compileEnv: compile.env, runEnv: run.env,
                    expect: expect,
                    iterations: iterations(g.iterations, g.fullIterations, tier: runTier),
                    carriers: carriers,
                    runTimeout: (g.timeoutSec ?? d?.timeoutSec)?.value ?? 60,
                    compileTimeout: d?.compileTimeoutSec?.value ?? 120,
                    weight: Manifest.weight(explicit: g.weight, heavy: false, carriers: carriers, capacity: capacity),
                    compile: nil, stderrMatch: match, collections: collections, reportMetrics: [],
                    objectSymbols: [], objectReferences: [],
                    stdinFile: nil, stdinAfter: nil,
                    tier: tier,
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

// Load the manifest directory: `suite.yaml`, then every `cases/*.yaml` in name order. A YAML or schema error
// stops the load with its file, line and column.
func loadManifest(_ dir: String) -> Manifest {
    let suite = decodeFile(SuiteFile.self, dir + "/suite.yaml")
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir + "/cases") else { die("\(dir): no cases directory") }
    var cases: [Case] = []
    for name in names.sorted() where name.hasSuffix(".yaml") {
        cases += decodeFile(CasesFile.self, dir + "/cases/" + name).cases
    }
    return Manifest(defaults: suite.defaults, dimensions: suite.dimensions, groups: suite.groups, cases: cases)
}

private func decodeFile<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    guard let bytes = FileManager.default.contents(atPath: path).map(Array.init) else { die("cannot read \(path)") }
    do {
        return try YAMLDecoder().decode(T.self, from: bytes)
    } catch {
        var starts: [UInt32] = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(UInt32(i + 1)) }
        let lines = LineIndex(lineStarts: starts)
        // A rendered YAML error carries its own `error:` prefix.
        var text = "error: \(path): \(error)"
        if let e = error as? YAMLErrors { text = e.render(file: path, lines: lines) }
        if let e = error as? YAMLError { text = e.render(file: path, lines: lines) }
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
