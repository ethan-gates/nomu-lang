// Layers and declarations (G5). A layer is one source of declarations: the builtin layer (made from the
// schema), a workspace, package or module `cfg.yaml`, or a block of the entry workspace's `externals:` section
// (G20). Resolution walks them weakest first, in the order given.

public enum LayerKind: String, Equatable {
    case builtin
    case entryWorkspace  // the entry workspace's `cfg.yaml`
    case workspace       // another workspace's `cfg.yaml`
    case package, module
    case externals       // an `externals:` block of the entry workspace's `cfg.yaml`

    // Configs are declared only in the builtin layer and workspace files (G4).
    public var declaresConfigs: Bool { self == .builtin || self == .entryWorkspace || self == .workspace }

    // Program and build settings are set only in the builtin layer and workspace files (G18). Only the entry
    // workspace's values apply, so every module of a program agrees; another workspace's are its own builds'.
    public func admits(_ granularity: Granularity) -> Bool {
        granularity == .module || self == .builtin || self == .entryWorkspace || self == .workspace
    }
}

// Where a declaration came from (G1).
public enum Origin: Equatable {
    case builtin
    case file(path: String, line: Int, column: Int)
    // A command-line argument as written (a config selection).
    case commandLine(String)

    public var description: String {
        switch self {
        case .builtin: return "builtin"
        case let .file(path, line, column): return "\(path):\(line):\(column)"
        case let .commandLine(argument): return argument
        }
    }
}

// One declared value: `oven.temp release: 220` declares setting `oven.temp`, qualified by `release`.
public struct Declaration: Equatable {
    public let setting: String
    // The configs the declaration applies under, any of them (G16); empty for an unqualified declaration.
    public let configs: [String]
    public let value: RawValue
    public let origin: Origin

    public init(_ setting: String, configs: [String] = [], _ value: RawValue, origin: Origin) {
        self.setting = setting
        self.configs = configs
        self.value = value
        self.origin = origin
    }
}

// A config declaration: a name and at most one parent (G4).
public struct ConfigDeclaration: Equatable {
    public let name: String
    public let parent: String?
    public let origin: Origin

    public init(_ name: String, parent: String?, origin: Origin) {
        self.name = name
        self.parent = parent
        self.origin = origin
    }
}

public struct Layer: Equatable {
    public let kind: LayerKind
    // Where the layer applies, as the configuration record names it: a workspace identity (`acme.app`), a
    // package or module path (`acme.app/net`), `all` or a pin alias for an `externals:` block.
    public let name: String
    public let declarations: [Declaration]
    public let configs: [ConfigDeclaration]

    public init(_ kind: LayerKind, name: String = "", declarations: [Declaration] = [], configs: [ConfigDeclaration] = []) {
        self.kind = kind
        self.name = name
        self.declarations = declarations
        self.configs = configs
    }
}

// A layer with the config table its qualifiers are checked against and the flattened list they match. Most
// layers of a stack share one; an `externals:` block uses the entry workspace's (G20).
public struct ScopedLayer {
    public let layer: Layer
    public let configs: ConfigTable
    public let active: [String]

    public init(_ layer: Layer, configs: ConfigTable, active: [String]) {
        self.layer = layer
        self.configs = configs
        self.active = active
    }
}
