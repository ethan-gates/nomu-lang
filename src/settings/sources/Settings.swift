import config

// The compiler's settings (G8) and its builtin configs (G4). `build` and `run` select `debug` by default,
// `test` selects `test`; externals and the language workspace build under `release` when nothing is selected.
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
            // Measurement only (task 243.1): each removes a cost of finding roots, unsoundly, to bound what a
            // different frame mechanism could save. A binary built with any of them is correct only while no
            // collection runs.
            Setting("measure.no_statepoints", .bool, default: .bool(false),
                    doc: "Measurement only, unsound: skip the statepoint rewrite, so references are not spilled and reloaded at calls. Correct only while nothing collects.",
                    targets: [.compile], granularity: .module),
            Setting("measure.no_shaped_homes", .bool, default: .bool(false),
                    doc: "Measurement only, unsound: keep shaped values (`String`) in registers across calls, with no frame home and no volatile reload. Correct only while nothing collects.",
                    targets: [.compile], granularity: .module),
            Setting("measure.no_loop_polls", .bool, default: .bool(false),
                    doc: "Measurement only, unsound: emit no safepoint poll at loop headers, so a fiber in a call-free loop never stops for a collection.",
                    targets: [.compile], granularity: .module),
            Setting("measure.gc_value_regs", .choice(["0", "4", "8", "16"]), default: .choice("0"),
                    doc: "Measurement only: let up to this many references stay in registers across a statepoint, callee-saved registers included (LLVM `max-registers-for-gc-values`, `fixup-allow-gcptr-in-csr`). The stack walkers read only stack slots, so nonzero is correct only while nothing collects. Process-wide: the first module compiled sets it.",
                    targets: [.compile], granularity: .module),
            Setting("gc.record", .choice(["off", "limited", "full"]), default: .choice("off"),
                    doc: "The collector's recorder, for tuning the collector: `off` compiles it out; `limited` records pauses, phases, cycles, heap snapshots and counters kept on slow paths; `full` also counts on the allocation fast path, which slows allocation.",
                    targets: [.compile], granularity: .program),
            Setting("gc.plan", .choice(["genimmix", "immix"]), default: .choice("genimmix"),
                    doc: "The collector, chosen at build time: `genimmix` is generational Immix (minor collections of a nursery, a write barrier on every managed store); `immix` collects the whole heap only, so it has no nursery and no write barrier. The plan not chosen is not compiled in.",
                    targets: [.compile], granularity: .program),
            Setting("link.debug_info_storage", .choice(["objects", "dsym"]), default: .choice("objects"),
                    doc: "Where a binary's debug info lives: `objects` leaves it in the object files, which the binary names by workspace-relative path; `dsym` gathers it into `<binary>.dSYM` and leaves no paths in the binary.",
                    targets: [.build], granularity: .program,
                    configValues: [.init(["release"], .choice("dsym"))]),
            Setting("cache.root", .string, default: .string(""),
                    doc: "The per-host build cache's directory: absolute, `~/`-relative, or relative to the entry workspace; empty is the platform's cache directory. `NOMU_CACHE_DIR` takes precedence.",
                    targets: [.build], granularity: .build),
            Setting("test.runtime_prelude", .bool, default: .bool(false),
                    doc: "Prepend the runtime prelude, so a white-box test calls runtime internals by name.",
                    targets: [.compile], granularity: .module),
            Setting("test.runtime_tier", .bool, default: .bool(false),
                    doc: "Admit the module to the runtime tier, so a test may call the runtime intrinsics on `Runtime` without the runtime prelude.",
                    targets: [.compile], granularity: .module),
        ],
        configs: [("debug", nil), ("release", nil), ("test", "debug")])

    // The configs externals and the language workspace build under when nothing is selected: `release`, since the
    // build cache (172) compiles each once per key, so optimized dependencies cost one compile.
    public static let externalDefault = ["release"]

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
