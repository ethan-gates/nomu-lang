// A workspace's identity (modules.md §Manifest; task 189 §Decided — workspace identity): its `scope` and
// `name`, both declared in its own `nomu.yaml`. Two workspaces with one identity are the same project.
public struct WorkspaceIdentity: Hashable, Comparable, CustomStringConvertible {
    public let scope: String
    public let name: String
    public init(scope: String, name: String) { self.scope = scope; self.name = name }
    public var description: String { "\(scope).\(name)" }
    public static func < (a: Self, b: Self) -> Bool { (a.scope, a.name) < (b.scope, b.name) }
}

// A workspace's `nomu.yaml`: its identity and its pins. Read with a minimal line reader until the manifest
// moves to real YAML (task 163): top-level `key: value` lines, and an `externals:` block of indented
// `<alias>: <path>` entries. `#` starts a comment line; a value may be double-quoted.
public struct WorkspaceConfig: Equatable {
    // One pin: a local alias for another workspace and the path it lives at, as written.
    public struct Pin: Equatable {
        public let alias: String
        public let path: String
        public let line: Int
        public let column: Int
    }

    public let identity: WorkspaceIdentity
    public let pins: [Pin]

    // Parse the config at `file`. Returns nil when it has errors (each reported).
    public static func parse(_ bytes: [UInt8], file: String) -> (WorkspaceConfig?, [PlanDiagnostic]) {
        var diags: [PlanDiagnostic] = []
        var fields: [String: (value: String, line: Int, column: Int)] = [:]
        var pins: [Pin] = []
        var inExternals = false

        let text = String(decoding: bytes, as: UTF8.self)
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = index + 1
            let content = raw.drop { $0 == " " || $0 == "\t" }
            if content.isEmpty || content.hasPrefix("#") { continue }
            let indent = raw.count - content.count
            guard let colon = content.firstIndex(of: ":") else {
                diags.append(PlanDiagnostic(file: file, line: line, column: indent + 1, "expected 'key: value'"))
                continue
            }
            let key = String(content[..<colon]).trimmingTrailingSpaces()
            let afterColon = content[content.index(after: colon)...]
            let valueStart = afterColon.drop { $0 == " " || $0 == "\t" }
            let column = indent + content.distance(from: content.startIndex, to: valueStart.startIndex) + 1
            var value = String(valueStart).trimmingTrailingSpaces()
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }

            if indent == 0 {
                inExternals = (key == "externals")
                if inExternals { continue }
                if fields[key] != nil {
                    diags.append(PlanDiagnostic(file: file, line: line, column: 1, "'\(key)' is set more than once"))
                }
                fields[key] = (value, line, column)
            } else if inExternals {
                guard isPathComponent(key) else {
                    diags.append(PlanDiagnostic(file: file, line: line, column: indent + 1,
                                                "pin alias '\(key)' must match [a-z][a-z0-9_]*"))
                    continue
                }
                if pins.contains(where: { $0.alias == key }) {
                    diags.append(PlanDiagnostic(file: file, line: line, column: indent + 1,
                                                "pin alias '\(key)' is declared more than once"))
                    continue
                }
                if value.isEmpty {
                    diags.append(PlanDiagnostic(file: file, line: line, column: column, "pin '\(key)' has no path"))
                    continue
                }
                pins.append(Pin(alias: key, path: value, line: line, column: column))
            }
        }

        // `scope` and `name` are required and follow the path-component rule.
        func identityField(_ key: String, _ example: String) -> String? {
            guard let f = fields[key] else {
                diags.append(PlanDiagnostic(file: file, "missing '\(key):' — every workspace declares its \(key) "
                                                       + "(e.g. '\(key): \(example)')"))
                return nil
            }
            guard isPathComponent(f.value) else {
                diags.append(PlanDiagnostic(file: file, line: f.line, column: f.column,
                                            "workspace \(key) '\(f.value)' must match [a-z][a-z0-9_]*"))
                return nil
            }
            return f.value
        }
        let scope = identityField("scope", "my_handle")
        let name = identityField("name", "my_project")
        guard diags.isEmpty, let scope, let name else { return (nil, diags) }
        return (WorkspaceConfig(identity: WorkspaceIdentity(scope: scope, name: name), pins: pins), [])
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s.removeLast() }
        return String(s)
    }
}
