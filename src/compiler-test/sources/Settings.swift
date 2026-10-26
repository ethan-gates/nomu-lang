import Foundation

// Named settings — the manifest's only way to change how a fixture is compiled or how its binary runs.
// A case, group or dimension value names a setting by meaning (`gc_stress_bytes: 4096`); this table maps
// each name to its stage and to the mechanism that carries it: a config selected on `nomu build` (declared
// in the repository's root `cfg.yaml`) for compile settings, an environment variable for run settings. A
// name missing from the table is a manifest error, so a mistyped or retired knob cannot pass silently.

enum Stage { case compile, run }

// A setting's manifest value: a boolean, an integer or a string.
enum SettingValue: Decodable, Equatable {
    case bool(Bool), int(Int), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }

    var text: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}

typealias Settings = [String: SettingValue]

// How a setting reaches its stage. `configWhen`: the config selected when the value equals the given
// boolean. `envWhen`: the variable set to `1` when the value equals the given boolean. `envValue`: the
// variable set to the value.
enum Carrier {
    case configWhen(Bool, String)
    case envWhen(Bool, String)
    case envValue(String)
}

struct SettingDef {
    let stage: Stage
    let carrier: Carrier
    let help: String
}

let settingTable: [String: SettingDef] = [
    // Compile settings.
    "optimize":           SettingDef(stage: .compile, carrier: .configWhen(true, "release"),
                                     help: "release pipeline (LLVM -O2)"),
    "inline":             SettingDef(stage: .compile, carrier: .configWhen(false, "no_inline"),
                                     help: "SSAIR inlining (default on)"),
    "escape":             SettingDef(stage: .compile, carrier: .configWhen(false, "no_escape"),
                                     help: "escape analysis and stack promotion (default on)"),
    "scalar":             SettingDef(stage: .compile, carrier: .configWhen(false, "no_scalar"),
                                     help: "scalar promotion (default on)"),
    "devirt":             SettingDef(stage: .compile, carrier: .configWhen(false, "no_devirt"),
                                     help: "devirtualization (default on)"),
    "rt_prelude":         SettingDef(stage: .compile, carrier: .configWhen(true, "rt_prelude"),
                                     help: "compile against the runtime prelude (fixtures that call rt* directly)"),
    // Run settings.
    "gc_log":             SettingDef(stage: .run, carrier: .envWhen(true, "NOMU_GC_DEBUG_PRESSURE"),
                                     help: "log each collection to stderr (`nomu-gc-sync: collection N`)"),
    "gc_stress_bytes":    SettingDef(stage: .run, carrier: .envValue("NOMU_GC_STRESS"),
                                     help: "a collection every N bytes a carrier allocates"),
    "nursery_blocks":     SettingDef(stage: .run, carrier: .envValue("NOMU_NURSERY_RESERVE"),
                                     help: "minor collection when the nursery fills N 32 KiB blocks"),
    "mature_floor":       SettingDef(stage: .run, carrier: .envValue("NOMU_MATURE_FLOOR"),
                                     help: "mature-space size below which every collection is major"),
    "gc_trigger_reserve": SettingDef(stage: .run, carrier: .envValue("NOMU_GC_TRIGGER_RESERVE"),
                                     help: "free-block reserve that triggers a collection"),
    "gc_pressure_driver": SettingDef(stage: .run, carrier: .envWhen(true, "NOMU_GC_PRESSURE"),
                                     help: "external heap-pressure defrag driver thread"),
    "stw_collect_driver": SettingDef(stage: .run, carrier: .envWhen(true, "NOMU_STW_COLLECT"),
                                     help: "external timed forced-evacuation driver thread"),
    "stw_selfhost_driver": SettingDef(stage: .run, carrier: .envWhen(true, "NOMU_STW_SELFHOST"),
                                      help: "external timed root-walk STW driver thread"),
]

// The manifest decoder's snake_case conversion also rewrites dictionary keys (`gc_log` arrives as `gcLog`),
// so a setting is looked up with underscores and case ignored.
private func normalized(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "").lowercased() }
private let settingName: [String: String] =
    Dictionary(uniqueKeysWithValues: settingTable.keys.map { (normalized($0), $0) })

// What a stage's settings become: arguments and environment variables. Fails on an unknown name, a
// setting used at the wrong stage, or a value of the wrong kind.
func lower(_ settings: Settings, at stage: Stage, in owner: String) -> (args: [String], env: [String: String]) {
    var args: [String] = []
    var env: [String: String] = [:]
    for (raw, value) in settings.sorted(by: { $0.key < $1.key }) {
        guard let name = settingName[normalized(raw)], let def = settingTable[name] else {
            let name = raw
            die("\(owner): unknown setting '\(name)' (known: \(settingTable.keys.sorted().joined(separator: ", ")))")
        }
        guard def.stage == stage else {
            die("\(owner): '\(name)' is a \(def.stage == .compile ? "compile" : "run") setting")
        }
        switch def.carrier {
        case .configWhen(let when, let config):
            guard case .bool(let b) = value else { die("\(owner): '\(name)' takes true or false") }
            if b == when { args.append("--config=" + config) }
        case .envWhen(let when, let variable):
            guard case .bool(let b) = value else { die("\(owner): '\(name)' takes true or false") }
            if b == when { env[variable] = "1" }
        case .envValue(let variable):
            env[variable] = value.text
        }
    }
    return (args, env)
}
