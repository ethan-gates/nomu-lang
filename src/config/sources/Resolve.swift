// Resolution (G5, G9): the layers' declarations and the flattened config list in, one value per setting out,
// each with the declarations that produced it (G1).
//
// Layer order decides first: a stronger layer's value replaces a weaker one's, or follows it for an appending
// list. Within one layer, a qualified declaration matches when it names a config in the list; the one naming
// the latest config wins, then the unqualified one. The order of declarations never matters.

// The configuration in force for one compile, link or run.
public struct Configuration {
    // The flattened config list it was resolved under.
    public let active: [String]
    // One entry per setting, in schema order.
    public let settings: [Resolved]
    private let index: [String: Int]

    init(active: [String], settings: [Resolved]) {
        self.active = active
        self.settings = settings
        var index: [String: Int] = [:]
        for (i, r) in settings.enumerated() { index[r.setting.name] = i }
        self.index = index
    }

    public subscript(name: String) -> Value? { index[name].map { settings[$0].value } }

    public func resolved(_ name: String) -> Resolved? { index[name].map { settings[$0] } }

    // `name=value` lines sorted by name, values in canonical form: the form a job file carries and the cache
    // key hashes (G2). It holds values only, never config names (G12).
    public func canonical(_ names: [String]? = nil) -> String {
        let chosen = names.map(Set.init)
        return settings.filter { chosen?.contains($0.setting.name) ?? true }
            .sorted { $0.setting.name < $1.setting.name }
            .map { "\($0.setting.name)=\($0.value.canonical)\n" }
            .joined()
    }
}

extension Configuration {
    // The canonical value of every setting whose targets include one of `targets`, by name: what a job
    // receives (G10, G12).
    public func canonicalValues(for targets: Set<Target>) -> [String: String] {
        var out: [String: String] = [:]
        for r in settings where !r.setting.targets.isDisjoint(with: targets) { out[r.setting.name] = r.value.canonical }
        return out
    }
}

// One setting's resolved value and every declaration of it, weakest layer first.
public struct Resolved {
    public let setting: Setting
    public let value: Value
    public let candidates: [Candidate]
}

public struct Candidate {
    public enum Status: Equatable {
        case won         // its value is the result, or part of an appended one
        case overridden  // won its layer, but a stronger layer's value replaced it
        case outranked   // matched, but lost in its layer to a declaration naming a later config
        case unmatched   // its qualifier names no config in the list
    }

    // The layer's position in the list resolved, and its kind.
    public let layerIndex: Int
    public let layer: LayerKind
    public let declaration: Declaration
    public let value: Value
    public let status: Status
}

// Resolves every setting of `schema` through `layers` (weakest first, the builtin layer among them) under the
// flattened config list `active`. Qualifiers are checked against `configs`, the table of the workspace whose
// files these are; `active` may name configs it does not declare, which match nothing. Throws every error found.
public func resolve(_ schema: Schema, layers: [Layer], configs: ConfigTable, active: [String]) throws(ConfigErrors) -> Configuration {
    try resolve(schema, layers: layers.map { ScopedLayer($0, configs: configs, active: active) }, active: active)
}

// Resolves through layers that each carry their own config table and list. `active` is the list the
// configuration reports: its module's workspace's.
public func resolve(_ schema: Schema, layers scoped: [ScopedLayer], active: [String]) throws(ConfigErrors) -> Configuration {
    let layers = scoped.map(\.layer)
    precondition(layers.contains { $0.kind == .builtin }, "resolution needs the builtin layer")
    let checked = try check(schema, scoped)
    let ranks = scoped.map { s in Dictionary(uniqueKeysWithValues: s.active.enumerated().map { ($1, $0) }) }
    var errors = ConfigErrors()
    var resolved: [Resolved] = []

    for setting in schema.settings {
        var candidates: [Candidate] = []
        var layerWinners: [Int] = []  // indices into candidates, weakest layer first
        for (l, layer) in layers.enumerated() {
            let declared = checked[l][setting.name] ?? []
            guard !declared.isEmpty else { continue }
            // Rank -1 is unqualified; nil is unmatched.
            let rank = ranks[l]
            let ranks: [Int?] = declared.map { d in
                d.declaration.configs.isEmpty ? -1 : d.declaration.configs.compactMap { rank[$0] }.max()
            }
            let top = ranks.compactMap { $0 }.max()
            let under = top.flatMap { $0 >= 0 ? " under `\(scoped[l].active[$0])`" : nil } ?? ""
            let base = candidates.count
            var winner: Int?
            for (i, d) in declared.enumerated() {
                let status: Candidate.Status = ranks[i] == nil ? .unmatched : ranks[i] == top ? .won : .outranked
                if status == .won {
                    if let w = winner, candidates[w].value != d.value {
                        let other = candidates[w]
                        errors.report(ConfigError(.conflict, d.declaration.origin,
                                                  "`\(setting.name)` is also set to \(other.value.description)\(under) at \(other.declaration.origin.description)"))
                    }
                    if winner == nil { winner = base + i }
                }
                candidates.append(Candidate(layerIndex: l, layer: layer.kind, declaration: d.declaration, value: d.value, status: status))
            }
            if let w = winner { layerWinners.append(w) }
        }

        // The builtin layer declares every setting unqualified, so some layer always has a winner (G3).
        let value: Value
        switch setting.merge {
        case .replace:
            // Equal declarations tied in one layer all win it; only the strongest layer's stay won.
            let strongest = candidates[layerWinners.last!].layerIndex
            for i in candidates.indices where candidates[i].status == .won && candidates[i].layerIndex != strongest {
                candidates[i] = candidates[i].with(.overridden)
            }
            value = candidates[layerWinners.last!].value
        case .append:
            value = .list(layerWinners.flatMap { w -> [Value] in
                if case .list(let items) = candidates[w].value { return items }
                return []
            })
        }
        resolved.append(Resolved(setting: setting, value: value, candidates: candidates))
    }
    if !errors.isEmpty { throw errors }
    return Configuration(active: active, settings: resolved)
}

private struct Checked {
    let declaration: Declaration
    let value: Value
}

// Checks each layer's declarations: a known setting, qualifiers naming declared configs, a setting the layer
// may set, a value of the setting's type, and no two spellings of one declaration in one layer. Returns each
// layer's declarations by setting, with their values.
private func check(_ schema: Schema, _ scoped: [ScopedLayer]) throws(ConfigErrors) -> [[String: [Checked]]] {
    var errors = ConfigErrors()
    var result: [[String: [Checked]]] = []
    for s in scoped {
        let layer = s.layer, configs = s.configs
        var bySetting: [String: [Checked]] = [:]
        var seen: [String: [Set<String>: Origin]] = [:]
        for d in layer.declarations {
            guard let setting = schema[d.setting] else {
                errors.report(ConfigError(.unknownSetting, d.origin, "unknown setting `\(d.setting)`",
                                          fix: closest(d.setting, schema.names).map { "did you mean `\($0)`?" }))
                continue
            }
            var ok = true
            for c in d.configs where !configs.contains(c) {
                errors.report(ConfigError(.unknownConfig, d.origin, "`\(c)` is not a declared config",
                                          fix: closest(c, configs.names).map { "did you mean `\($0)`?" }))
                ok = false
            }
            if !layer.kind.admits(setting.granularity) {
                errors.report(ConfigError(.settingInWrongLayer, d.origin,
                                          "`\(d.setting)` is a \(setting.granularity.rawValue) setting, set only in the entry workspace's `cfg.yaml`"))
                ok = false
            }
            let qualifier = Set(d.configs)
            if let first = seen[d.setting]?[qualifier] {
                errors.report(ConfigError(.duplicateDeclaration, d.origin,
                                          "`\(describe(d))` is already declared at \(first.description)"))
                ok = false
            } else {
                seen[d.setting, default: [:]][qualifier] = d.origin
            }
            switch setting.type.read(d.value) {
            case .success(let v):
                if ok { bySetting[d.setting, default: []].append(Checked(declaration: d, value: v)) }
            case .failure(let problem):
                errors.report(ConfigError(.invalidValue, d.origin, "`\(d.setting)`: \(problem.message)", fix: problem.fix))
            }
        }
        result.append(bySetting)
    }
    if !errors.isEmpty { throw errors }
    return result
}

// A declaration's name and qualifier as a file spells them: `oven.temp release`.
private func describe(_ d: Declaration) -> String {
    ([d.setting] + d.configs).joined(separator: " ")
}

extension Candidate {
    func with(_ status: Status) -> Candidate {
        Candidate(layerIndex: layerIndex, layer: layer, declaration: declaration, value: value, status: status)
    }
}
