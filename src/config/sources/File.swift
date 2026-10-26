import yaml

// Reading a `cfg.yaml` (G5, G16, G20). Nested mappings are sections, joined into `<topic>.<key>` names; a key's
// words after the first are config names, and a qualifier goes on a section or on a key, never both on one
// path. `configs:` declares configs, and `externals:` holds blocks for external workspaces, keyed by `all` or
// pin alias. Which file may hold which section is checked when the file takes its place in a stack.

public struct ConfigFile {
    public let path: String
    public let declarations: [Declaration]
    public let configs: [ConfigDeclaration]
    public let externals: [ExternalsBlock]
    // Where `configs:` and `externals:` start, for an error when the file may not hold them.
    public let configsOrigin: Origin?
    public let externalsOrigin: Origin?

    // One block of `externals:`: `all` or a pin alias, and its declarations.
    public struct ExternalsBlock {
        public let target: String
        public let declarations: [Declaration]
        public let origin: Origin
    }

    // Reads `bytes` as the `cfg.yaml` at `path`, throwing every error found.
    public init(_ bytes: [UInt8], path: String) throws(ConfigErrors) {
        self.path = path
        let doc: YAMLDocument
        do {
            doc = try YAMLDocument(parsing: bytes)
        } catch {
            let lines = LineIndex(lineStarts: lineStarts(bytes))
            throw ConfigErrors(error.errors.map { e in
                let (line, column) = lines.location(of: e.span.start)
                return ConfigError(.syntax, .file(path: path, line: line, column: column), e.message, fix: e.fix)
            })
        }
        var reader = Reader(doc: doc, path: path)
        reader.readRoot()
        if !reader.errors.isEmpty { throw reader.errors }
        declarations = reader.declarations
        configs = reader.configs
        externals = reader.externals
        configsOrigin = reader.configsOrigin
        externalsOrigin = reader.externalsOrigin
    }
}

private struct Reader {
    let doc: YAMLDocument
    let path: String
    var errors = ConfigErrors()
    var declarations: [Declaration] = []
    var configs: [ConfigDeclaration] = []
    var externals: [ConfigFile.ExternalsBlock] = []
    var configsOrigin: Origin?
    var externalsOrigin: Origin?

    init(doc: YAMLDocument, path: String) {
        self.doc = doc
        self.path = path
    }

    func origin(_ offset: UInt32) -> Origin {
        let (line, column) = doc.location(of: offset)
        return .file(path: path, line: line, column: column)
    }

    mutating func readRoot() {
        let root = doc.root
        guard root.kind == .mapping else {
            errors.report(ConfigError(.malformedSection, origin(root.span.start), "a `cfg.yaml` is a mapping of sections"))
            return
        }
        for entry in root.entries {
            let at = origin(entry.keySpan.start)
            guard let words = self.words(entry.key, at) else { continue }
            switch words[0] {
            case "configs":
                guard reserved(words, at) else { continue }
                configsOrigin = at
                readConfigs(entry.value)
            case "externals":
                guard reserved(words, at) else { continue }
                externalsOrigin = at
                readExternals(entry.value)
            default:
                var out: [Declaration] = []
                readEntry(entry, words, path: [], qualifier: [], into: &out)
                declarations += out
            }
        }
    }

    // A key's words: a name, then config names, each a lowercase word, separated by single spaces.
    mutating func words(_ key: String, _ at: Origin) -> [String]? {
        let words = key.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if key.contains(".") {
            let parts = words[0].split(separator: ".").map(String.init)
            errors.report(ConfigError(.malformedKey, at, "`\(key)`: a name holds no dots",
                                      fix: "nest it: \(parts.map { "`\($0):`" }.joined(separator: " then "))"))
            return nil
        }
        guard words.allSatisfy(Schema.isWord) else {
            errors.report(ConfigError(.malformedKey, at,
                                      "`\(key)` is not a name followed by config names (lowercase words separated by single spaces)"))
            return nil
        }
        return words
    }

    mutating func reserved(_ words: [String], _ at: Origin) -> Bool {
        guard words.count == 1 else {
            errors.report(ConfigError(.malformedSection, at, "`\(words[0])` takes no config names"))
            return false
        }
        return true
    }

    // `configs:` maps each name to its parent, or `null` for none.
    mutating func readConfigs(_ node: YAMLNode) {
        guard node.kind == .mapping else {
            errors.report(ConfigError(.malformedSection, origin(node.span.start), "`configs` maps each config name to its parent or `null`"))
            return
        }
        for entry in node.entries {
            let at = origin(entry.keySpan.start)
            guard Schema.isWord(entry.key) else {
                errors.report(ConfigError(.malformedKey, at, "config name `\(entry.key)` is not a lowercase word"))
                continue
            }
            let value = entry.value
            if value.isNull {
                configs.append(ConfigDeclaration(entry.key, parent: nil, origin: at))
            } else if let parent = value.string, Schema.isWord(parent) {
                configs.append(ConfigDeclaration(entry.key, parent: parent, origin: at))
            } else {
                errors.report(ConfigError(.malformedSection, origin(value.span.start),
                                          "the parent of `\(entry.key)` is a config name or `null`"))
            }
        }
    }

    // `externals:` maps `all` or a pin alias to a block of sections.
    mutating func readExternals(_ node: YAMLNode) {
        guard node.kind == .mapping else {
            errors.report(ConfigError(.malformedSection, origin(node.span.start), "`externals` maps `all` or a pin alias to sections"))
            return
        }
        for entry in node.entries {
            let at = origin(entry.keySpan.start)
            guard Schema.isWord(entry.key) else {
                errors.report(ConfigError(.malformedKey, at, "`\(entry.key)` is not `all` or a pin alias"))
                continue
            }
            guard entry.value.kind == .mapping else {
                errors.report(ConfigError(.malformedSection, origin(entry.value.span.start), "`\(entry.key)` holds sections"))
                continue
            }
            var out: [Declaration] = []
            for inner in entry.value.entries {
                let innerAt = origin(inner.keySpan.start)
                guard let words = self.words(inner.key, innerAt) else { continue }
                if words[0] == "configs" || words[0] == "externals" {
                    errors.report(ConfigError(.malformedSection, innerAt, "`\(words[0])` belongs at the top of the file"))
                    continue
                }
                readEntry(inner, words, path: [], qualifier: [], into: &out)
            }
            externals.append(ConfigFile.ExternalsBlock(target: entry.key, declarations: out, origin: at))
        }
    }

    // A section (a mapping value) or a declaration (anything else), under the section path `path`.
    mutating func readEntry(_ entry: YAMLEntry, _ words: [String], path: [String], qualifier: [String],
                            into out: inout [Declaration]) {
        let at = origin(entry.keySpan.start)
        let own = Array(words.dropFirst())
        if !own.isEmpty && !qualifier.isEmpty {
            errors.report(ConfigError(.qualifierTwice, at,
                                      "`\(entry.key)` is qualified inside a section qualified by `\(qualifier.joined(separator: " "))`",
                                      fix: "qualify the section or the key, not both"))
            return
        }
        let names = path + [words[0]]
        let configs = qualifier.isEmpty ? own : qualifier
        let value = entry.value
        if value.kind == .mapping {
            for inner in value.entries {
                guard let innerWords = self.words(inner.key, origin(inner.keySpan.start)) else { continue }
                readEntry(inner, innerWords, path: names, qualifier: configs, into: &out)
            }
            return
        }
        guard let raw = raw(value) else { return }
        out.append(Declaration(names.joined(separator: "."), configs: configs, raw, origin: at))
    }

    mutating func raw(_ node: YAMLNode) -> RawValue? {
        switch node.kind {
        case .string: return .string(node.string!)
        case .integer: return .integer(node.integer!)
        case .float: return .float(node.float!)
        case .boolean: return .boolean(node.boolean!)
        case .null: return .null
        case .sequence:
            var items: [RawValue] = []
            for item in node.items {
                guard let r = raw(item) else { return nil }
                items.append(r)
            }
            return .list(items)
        case .mapping:
            errors.report(ConfigError(.invalidValue, origin(node.span.start), "a list item cannot be a mapping"))
            return nil
        }
    }
}

// The offset each line starts at, for placing errors of a file that did not parse.
private func lineStarts(_ bytes: [UInt8]) -> [UInt32] {
    var starts: [UInt32] = [0]
    for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(UInt32(i + 1)) }
    return starts
}
