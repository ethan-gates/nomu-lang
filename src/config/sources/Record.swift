import yaml

// The configuration record (G1), one module's final values, and the builtin dump (G19), each as YAML.

extension BuildConfiguration {
    // The record: what resolution read, each layer once with exactly what it declared. `command`, `compiler`
    // and `source` are the caller's (the command line, the compiler's identity, the project's revision).
    public func record(command: String, compiler: String, source: String) -> String {
        var top: [(key: String, value: YAMLValue)] = [
            ("command", .string(command)),
            ("compiler", .string(compiler)),
            ("source", .string(source)),
        ]
        top.append(("active", activeLists))
        top.append(("builtin", body(builtin.declarations)))

        var spaces: [(key: String, value: YAMLValue)] = []
        var packages: [(key: String, value: YAMLValue)] = []
        var modules: [(key: String, value: YAMLValue)] = []
        for identity in order.sorted() {
            let w = workspaces[identity]!
            let ws = BuildConfiguration.workspaceLayer(w)
            if !ws.declarations.isEmpty { spaces.append((ws.name, body(ws.declarations))) }
            for l in BuildConfiguration.packageLayers(w) where !l.declarations.isEmpty { packages.append((l.name, body(l.declarations))) }
            for l in BuildConfiguration.moduleLayers(w) where !l.declarations.isEmpty { modules.append((l.name, body(l.declarations))) }
        }
        let blocks = externalsBlocks.filter { !$0.declarations.isEmpty }.sorted { ($0.name == "all" ? 0 : 1, $0.name) < ($1.name == "all" ? 0 : 1, $1.name) }
        for (key, section) in [("workspaces", spaces), ("packages", packages), ("modules", modules),
                               ("externals", blocks.map { (key: $0.name, value: body($0.declarations)) })] where !section.isEmpty {
            top.append((key, .mapping(section)))
        }
        return render(.mapping(top))
    }

    // The record's short form, which a binary carries (G13): the compiler and the active lists. With the
    // project's revision, these give back every value.
    public func summary(compiler: String) -> String {
        render(.mapping([("compiler", .string(compiler)), ("active", activeLists)]))
    }

    // The flattened list each kind of workspace resolved under.
    private var activeLists: YAMLValue {
        var active: [(key: String, value: YAMLValue)] = [(entry, list(entryActive))]
        let roles = Set(workspaces.values.map(\.role))
        if roles.contains(.external) { active.append(("externals", list(externalActive))) }
        if roles.contains(.language) { active.append(("language", list(externalActive))) }
        return .mapping(active)
    }

    // A module's final value for every setting, in schema order.
    public func values(for place: ModulePlace) -> String {
        let c = configuration(for: place)
        return render(.mapping(c.settings.map { (key: $0.setting.name, value: yamlValue($0.value)) }))
    }

    // A layer's declarations as flat keys, `<setting>( <config>)*`, in schema order and then by qualifier.
    private func body(_ declarations: [Declaration]) -> YAMLValue {
        let position = Dictionary(uniqueKeysWithValues: schema.names.enumerated().map { ($1, $0) })
        let sorted = declarations.sorted {
            (position[$0.setting] ?? .max, $0.configs.count, $0.configs.joined(separator: " "))
                < (position[$1.setting] ?? .max, $1.configs.count, $1.configs.joined(separator: " "))
        }
        return .mapping(sorted.map { d in
            let value = schema[d.setting].flatMap { try? $0.type.read(d.value).get() }
            return (key: ([d.setting] + d.configs).joined(separator: " "), value: value.map(yamlValue) ?? .null)
        })
    }
}

extension Schema {
    // The builtin layer as a `cfg.yaml` (G19): the builtin configs, then every setting at its default under its
    // topic, each commented with its meaning, type, targets and granularity, followed by the values builtin
    // configs set.
    public func builtinFile() -> String {
        var out = "# The builtin layer: every setting at its default, and the values the builtin configs set.\n"
        out += "configs:\n"
        for c in configs { out += "  \(c.name): \(c.parent ?? "null")\n" }
        var topics: [String] = []
        var byTopic: [String: [Setting]] = [:]
        for s in settings {
            if byTopic[s.topic] == nil { topics.append(s.topic) }
            byTopic[s.topic, default: []].append(s)
        }
        for topic in topics {
            out += "\(topic):\n"
            for s in byTopic[topic]! {
                let key = String(s.name.dropFirst(topic.count + 1))
                let targets = Target.allCases.filter(s.targets.contains).map(\.rawValue).joined(separator: ", ")
                out += "  # \(s.doc)\n"
                out += "  # \(s.type.description); targets: \(targets); granularity: \(s.granularity.rawValue)"
                out += s.merge == .append ? "; appends\n" : "\n"
                out += line(key, s.defaultValue, indent: 2)
                for v in s.configValues { out += line(([key] + v.configs).joined(separator: " "), v.value, indent: 2) }
            }
        }
        return out
    }

    private func line(_ key: String, _ value: Value, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        if case .list(let items) = value {
            if items.isEmpty { return "\(pad)\(key): []\n" }
            return "\(pad)\(key):\n" + items.map { "\(pad)  - \(scalarText(yamlValue($0)))\n" }.joined()
        }
        return "\(pad)\(key): \(scalarText(yamlValue(value)))\n"
    }
}

// A value as YAML: a size in its readable form (`64M`), as an integer when no unit divides it.
func yamlValue(_ value: Value) -> YAMLValue {
    switch value {
    case .bool(let b): return .boolean(b)
    case .int(let v): return .integer(v)
    case .size(let v):
        let text = value.description
        return text.last.map { $0.isLetter } == true ? .string(text) : .integer(v)
    case .choice(let s), .string(let s): return .string(s)
    case .list(let items): return .sequence(items.map(yamlValue))
    }
}

private func list(_ names: [String]) -> YAMLValue { .sequence(names.map { .string($0) }) }

// A value written as a whole document.
private func render(_ value: YAMLValue) -> String {
    do {
        var edits = YAMLEdits(try YAMLDocument(parsing: "x\n"))
        edits.set(edits.document.root, to: value)
        return String(decoding: try edits.apply().bytes, as: UTF8.self)
    } catch {
        preconditionFailure("rendering a configuration document: \(error)")
    }
}

// A scalar's spelling, quoted when its plain form would read as something else.
private func scalarText(_ value: YAMLValue) -> String {
    var text = render(value)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}
