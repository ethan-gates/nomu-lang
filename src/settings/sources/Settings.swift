import config

// The compiler's settings (G8) and its builtin configs (G4). `build` and `run` select `debug` by default,
// `test` selects `test`; externals and the language workspace build under `debug` when nothing is selected.
public enum CompilerSettings {
    public static let schema = Schema(
        settings: [
            Setting("opt.level", .choice(["none", "o2"]), default: .choice("none"),
                    doc: "The LLVM pipeline: `none` runs only what the GC statepoint rewrite needs and keeps debug info; `o2` runs `default<O2>`.",
                    targets: [.compile], granularity: .module,
                    configValues: [.init(["release"], .choice("o2"))]),
            Setting("opt.mono", .choice(["none", "edge", "all"]), default: .choice("none"),
                    doc: "Cross-module specialization: `none` calls imported generics through witnesses, `edge` specializes the ones this module calls directly, `all` every one it reaches.",
                    targets: [.compile], granularity: .module,
                    configValues: [.init(["release"], .choice("all"))]),
            // The SSAIR optimizer passes, each on by default; turning one off gives a baseline for bisecting.
            Setting("opt.devirt", .bool, default: .bool(true),
                    doc: "Devirtualization in the SSAIR optimizer.", targets: [.compile], granularity: .module),
            Setting("opt.inline", .bool, default: .bool(true),
                    doc: "Inlining in the SSAIR optimizer.", targets: [.compile], granularity: .module),
            Setting("opt.escape", .bool, default: .bool(true),
                    doc: "Escape analysis and stack promotion; off also turns off scalar promotion.",
                    targets: [.compile], granularity: .module),
            Setting("opt.scalar", .bool, default: .bool(true),
                    doc: "Scalar promotion of loop-carried non-escaping objects (needs `opt.escape`).",
                    targets: [.compile], granularity: .module),
            Setting("opt.escape_provider", .choice(["legacy", "graph", "graph_precise"]), default: .choice("legacy"),
                    doc: "What answers escape queries: `legacy` (escapingValues), `graph` (the points-to graph, reproducing legacy), `graph_precise` (its field-sensitive query).",
                    targets: [.compile], granularity: .module),
            Setting("opt.inline_alloc", .bool, default: .bool(true),
                    doc: "The inline TLAB bump fast path; off sends every allocation to the runtime call.",
                    targets: [.compile], granularity: .module),
            Setting("test.runtime_prelude", .bool, default: .bool(false),
                    doc: "Prepend the runtime prelude, so a white-box test calls runtime internals by name.",
                    targets: [.compile], granularity: .module),
        ],
        configs: [("debug", nil), ("release", nil), ("test", "debug")])

    // Interim: `release` once the build cache (172) makes optimized externals cheap to keep.
    public static let externalDefault = ["debug"]

    // The settings the runtime reads, each with the symbol of the global it reads (G14): the name with each
    // `.` as `_`, under `nomu_setting_` (`gc.stress` would be `nomu_setting_gc_stress`).
    public static let runSettings: [(setting: Setting, symbol: String)] = {
        let run = schema.settings.filter { $0.targets.contains(.run) }.map { s in
            (setting: s, symbol: "nomu_setting_" + s.name.split(separator: ".").joined(separator: "_"))
        }
        precondition(Set(run.map(\.symbol)).count == run.count, "two run settings share a runtime symbol")
        return run
    }()
}

// The settings a job received (G12), by name. A setting the job did not receive reads as its default.
public struct JobSettings {
    let values: [String: Value]

    // Reads canonical values as the driver writes them; a name the schema does not know, or a value that is
    // not canonical for its setting, is a driver bug.
    public init(_ canonical: [String: String]) {
        var values: [String: Value] = [:]
        for (name, text) in canonical {
            guard let setting = CompilerSettings.schema[name], let v = setting.type.value(canonical: text) else {
                preconditionFailure("job setting `\(name)=\(text)` does not read under the schema")
            }
            values[name] = v
        }
        self.values = values
    }

    public func value(_ name: String) -> Value {
        guard let setting = CompilerSettings.schema[name] else { preconditionFailure("unknown setting `\(name)`") }
        return values[name] ?? setting.defaultValue
    }

    public func string(_ name: String) -> String {
        guard case .string(let s) = value(name) else { preconditionFailure("`\(name)` is not a string setting") }
        return s
    }

    public func choice(_ name: String) -> String {
        guard case .choice(let s) = value(name) else { preconditionFailure("`\(name)` is not a choice setting") }
        return s
    }

    public func bool(_ name: String) -> Bool {
        guard case .bool(let b) = value(name) else { preconditionFailure("`\(name)` is not a bool setting") }
        return b
    }

    // `opt.level`: whether the job runs the optimizing pipeline.
    public var optimize: Bool { choice("opt.level") == "o2" }
}
