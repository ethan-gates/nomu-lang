// Errors are values: the library never prints. Each error carries a stable code, so tests assert codes and
// messages can be reworded freely, and the origin of the declaration it concerns.

public struct ConfigError: Error, Equatable {
    public enum Code: Equatable, Hashable {
        // Settings.
        case unknownSetting
        case invalidValue               // a value that does not read as the setting's type
        case settingInWrongLayer        // a program or build setting in a package or module file (G18)
        case duplicateDeclaration       // two spellings of one declaration in one layer (G9)
        case conflict                   // two declarations in one layer win under one config with different values

        // Files.
        case syntax                     // a `cfg.yaml` that is not valid YAML
        case malformedKey               // a key that is not a name followed by config names
        case qualifierTwice             // a qualifier on a section and on a key inside it (G16)
        case malformedSection           // `configs:` or `externals:` misplaced, qualified or of the wrong shape
        case unknownExternal            // an `externals:` key that is neither `all` nor a pin alias (G20)

        // Configs (G4).
        case unknownConfig              // a qualifier, parent or selection naming no declared config
        case duplicateConfig
        case configInWrongLayer         // a config declared outside the builtin and workspace layers
        case configCycle
    }

    public let code: Code
    public let origin: Origin
    public let message: String
    // A suggested fix, shown after the message ("did you mean `oven.temp`?").
    public let fix: String?

    public init(_ code: Code, _ origin: Origin, _ message: String, fix: String? = nil) {
        self.code = code
        self.origin = origin
        self.message = message
        self.fix = fix
    }

    // `file:line:col: error: message; fix` for a file, matching the compiler's diagnostic format; the flag
    // or the builtin layer leads otherwise.
    public var rendered: String {
        let suffix = fix.map { "; \($0)" } ?? ""
        switch origin {
        case let .file(path, line, column): return "\(path):\(line):\(column): error: \(message)\(suffix)"
        case let .commandLine(argument): return "error: \(argument): \(message)\(suffix)"
        case .builtin: return "error: builtin: \(message)\(suffix)"
        }
    }
}

// Every error from one step, in the order found.
public struct ConfigErrors: Error, Equatable {
    public var errors: [ConfigError] = []

    public init(_ errors: [ConfigError] = []) { self.errors = errors }

    public var isEmpty: Bool { errors.isEmpty }
    public var codes: [ConfigError.Code] { errors.map(\.code) }

    mutating func report(_ error: ConfigError) { errors.append(error) }

    public var rendered: String { errors.map(\.rendered).joined(separator: "\n") }
}

// The candidate nearest `name` by edit distance, when it is near enough to be a likely typo.
func closest(_ name: String, _ candidates: [String]) -> String? {
    let a = Array(name.lowercased().unicodeScalars)
    var best: (String, Int)?
    for c in candidates {
        let b = Array(c.lowercased().unicodeScalars)
        guard !a.isEmpty && !b.isEmpty else { continue }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        let distance = row[b.count]
        if distance <= max(2, a.count / 3) && distance < (best?.1 ?? .max) { best = (c, distance) }
    }
    return best?.0
}
