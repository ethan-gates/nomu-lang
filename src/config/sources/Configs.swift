// Configs (G4): declared names with at most one parent, collected from the builtin and workspace layers, and
// the selection's flattening into one ordered list.

public struct ConfigTable {
    public private(set) var declarations: [String: ConfigDeclaration] = [:]

    // Collects the config declarations of `layers`. Redeclaring a name, naming an undeclared parent, a cycle
    // of parents, and a declaration outside the builtin and workspace layers are errors.
    public init(_ layers: [Layer]) throws(ConfigErrors) {
        var errors = ConfigErrors()
        for layer in layers {
            for c in layer.configs {
                guard layer.kind.declaresConfigs else {
                    errors.report(ConfigError(.configInWrongLayer, c.origin,
                                              "configs are declared only in the workspace `cfg.yaml`"))
                    continue
                }
                if let first = declarations[c.name] {
                    errors.report(ConfigError(.duplicateConfig, c.origin,
                                              "config `\(c.name)` is already declared (\(first.origin.description))"))
                    continue
                }
                declarations[c.name] = c
            }
        }
        for c in declarations.values.sorted(by: { $0.name < $1.name }) {
            if let parent = c.parent, declarations[parent] == nil {
                errors.report(ConfigError(.unknownConfig, c.origin, "parent `\(parent)` of `\(c.name)` is not a declared config",
                                          fix: closest(parent, Array(declarations.keys)).map { "did you mean `\($0)`?" }))
            }
        }
        // A cycle is reported once, at the member whose name sorts first.
        var reported: Set<String> = []
        for name in declarations.keys.sorted() where !reported.contains(name) {
            var path: [String] = []
            var current: String? = name
            while let c = current, let d = declarations[c] {
                if let start = path.firstIndex(of: c) {
                    let cycle = Array(path[start...])
                    if !cycle.contains(where: reported.contains), let first = cycle.min() {
                        reported.formUnion(cycle)
                        let i = cycle.firstIndex(of: first)!
                        let ordered = Array(cycle[i...] + cycle[..<i]) + [first]
                        errors.report(ConfigError(.configCycle, declarations[first]!.origin,
                                                  "config parents form a cycle: \(ordered.joined(separator: " -> "))"))
                    }
                    break
                }
                path.append(c)
                current = d.parent
            }
        }
        if !errors.isEmpty { throw errors }
    }

    public func contains(_ name: String) -> Bool { declarations[name] != nil }

    public var names: [String] { declarations.keys.sorted() }

    // The config's chain from its root down to itself.
    public func chain(_ name: String) -> [String] {
        var chain: [String] = []
        var current: String? = name
        while let c = current {
            chain.append(c)
            current = declarations[c]?.parent
        }
        return chain.reversed()
    }

    // The selection as one ordered list: each selected config's chain, in selection order, keeping the first
    // appearance of a repeated name. A later config beats an earlier one (G9).
    public func flatten(_ selection: [(name: String, origin: Origin)]) throws(ConfigErrors) -> [String] {
        var errors = ConfigErrors()
        var list: [String] = []
        var seen: Set<String> = []
        for s in selection {
            guard contains(s.name) else {
                errors.report(ConfigError(.unknownConfig, s.origin, "`\(s.name)` is not a declared config",
                                          fix: closest(s.name, names).map { "did you mean `\($0)`?" }))
                continue
            }
            for c in chain(s.name) where seen.insert(c).inserted { list.append(c) }
        }
        if !errors.isEmpty { throw errors }
        return list
    }
}

// The `-c`/`--config` values as a selection: each value may name several configs, separated by commas
// (`-c release,gc_fast` is `-c release -c gc_fast`). An empty name is an error.
public func selection(_ values: [String]) throws(ConfigErrors) -> [(name: String, origin: Origin)] {
    var errors = ConfigErrors()
    var out: [(name: String, origin: Origin)] = []
    for v in values {
        let origin = Origin.commandLine("-c \(v)")
        for name in v.split(separator: ",", omittingEmptySubsequences: false) {
            if name.isEmpty {
                errors.report(ConfigError(.unknownConfig, origin, "empty config name"))
            } else {
                out.append((String(name), origin))
            }
        }
    }
    if !errors.isEmpty { throw errors }
    return out
}
