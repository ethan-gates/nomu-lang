// The schema (G8): every setting declared once, with its type, default, targets, granularity and merge rule,
// plus the builtin configs and the values they set. The library declares no settings; its user supplies a
// schema, and the schema makes the builtin layer.

// What a setting changes (G10). A setting may declare several.
public enum Target: String, CaseIterable, Comparable {
    case compile      // the compiler's output
    case build        // planning, linking, cache location
    case run          // the running program
    case diagnostics  // dumps and timing

    public static func < (a: Target, b: Target) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

// The scope a setting varies over (G18).
public enum Granularity: String {
    case module   // may differ per module
    case program  // one value per linked binary
    case build    // one value per build
}

// How a list setting combines declarations from several layers. Replace keeps the strongest layer's value;
// append joins every layer's value, weakest first. Within one layer only the winning declaration counts.
public enum Merge: Equatable {
    case replace, append
}

public struct Setting {
    // `<topic>.<key>` (G16).
    public let name: String
    public let type: ValueType
    public let defaultValue: Value
    public let doc: String
    public let targets: Set<Target>
    public let granularity: Granularity
    public let merge: Merge
    // Values the builtin configs set, as qualified declarations in the builtin layer.
    public let configValues: [ConfigValue]

    public struct ConfigValue {
        public let configs: [String]
        public let value: Value
        public init(_ configs: [String], _ value: Value) {
            self.configs = configs
            self.value = value
        }
    }

    // The first part of the name.
    public var topic: String { String(name.prefix { $0 != "." }) }

    public init(_ name: String, _ type: ValueType, default defaultValue: Value, doc: String,
                targets: Set<Target>, granularity: Granularity, merge: Merge = .replace,
                configValues: [ConfigValue] = []) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.doc = doc
        self.targets = targets
        self.granularity = granularity
        self.merge = merge
        self.configValues = configValues
    }
}

public struct Schema {
    // In declaration order, which reports follow.
    public let settings: [Setting]
    // The builtin config declarations (G4).
    public let configs: [ConfigDeclaration]
    private let index: [String: Int]

    // A schema is part of the program that supplies it, so a malformed one is a bug there and stops here.
    public init(settings: [Setting], configs: [(name: String, parent: String?)]) {
        self.settings = settings
        self.configs = configs.map { ConfigDeclaration($0.name, parent: $0.parent, origin: .builtin) }
        var index: [String: Int] = [:]
        for (i, s) in settings.enumerated() {
            precondition(Schema.isSettingName(s.name), "setting name `\(s.name)` is not `<topic>.<key>`")
            precondition(!Schema.reservedTopics.contains(s.topic), "`\(s.topic)` is a top-level `cfg.yaml` key, not a topic")
            precondition(index.updateValue(i, forKey: s.name) == nil, "setting `\(s.name)` declared twice")
            precondition(s.type.admits(s.defaultValue), "default of `\(s.name)` is not a \(s.type.description)")
            if case .list(let element) = s.type {
                if case .list = element { preconditionFailure("`\(s.name)` is a list of lists") }
            } else {
                precondition(s.merge == .replace, "`\(s.name)` appends but is not a list")
            }
            precondition(!s.targets.isEmpty, "`\(s.name)` declares no targets")
            precondition(!s.targets.contains(.run) || s.granularity == .program,
                         "`\(s.name)` targets `run`, so it is a program setting: a program has one runtime")
            for v in s.configValues {
                precondition(!v.configs.isEmpty, "builtin value of `\(s.name)` names no config")
                precondition(s.type.admits(v.value), "builtin value of `\(s.name)` is not a \(s.type.description)")
            }
        }
        self.index = index
        do {
            let table = try ConfigTable([builtinLayer])
            for s in settings {
                for v in s.configValues {
                    for c in v.configs { precondition(table.contains(c), "`\(s.name)` names undeclared config `\(c)`") }
                }
            }
        } catch {
            preconditionFailure("builtin configs: \(error.rendered)")
        }
    }

    public subscript(name: String) -> Setting? { index[name].map { settings[$0] } }

    public var names: [String] { settings.map(\.name) }

    // The builtin layer: every setting's default, the values the builtin configs set, and the builtin config
    // declarations. Resolution always finds a value here (G3).
    public var builtinLayer: Layer {
        var declarations: [Declaration] = []
        for s in settings {
            declarations.append(Declaration(s.name, s.defaultValue.raw, origin: .builtin))
            for v in s.configValues {
                declarations.append(Declaration(s.name, configs: v.configs, v.value.raw, origin: .builtin))
            }
        }
        return Layer(.builtin, name: "builtin", declarations: declarations, configs: configs)
    }

    // Top-level `cfg.yaml` keys other than topics (G4, G20).
    static let reservedTopics: Set<String> = ["configs", "externals"]

    // A topic and a key, or a topic, group and key (G16): lowercase words of letters, digits and `_`, joined
    // by dots, each starting with a letter.
    static func isSettingName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return (parts.count == 2 || parts.count == 3) && parts.allSatisfy(isWord)
    }

    // A lowercase word of letters, digits and `_`, starting with a letter: the form of a setting name's parts
    // and of a config name.
    static func isWord<S: StringProtocol>(_ s: S) -> Bool {
        guard let first = s.utf8.first, first >= 0x61 && first <= 0x7A else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }
}
