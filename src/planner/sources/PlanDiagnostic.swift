// A planning error: an unresolved import, a gate, a malformed manifest, an identity clash. Collected as data
// and rendered in the compiler's `file:line:col: error: message` form, so planner and compiler errors read
// alike. `file` is nil for an error with no source location; `line`/`column` (1-based) are nil for an error
// that names a whole file.
public struct PlanDiagnostic: Equatable, CustomStringConvertible {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(file: String? = nil, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.file = file; self.line = line; self.column = column; self.message = message
    }

    public var description: String {
        guard let file else { return "error: " + message }
        guard let line else { return "\(file): error: \(message)" }
        return "\(file):\(line):\(column ?? 1): error: \(message)"
    }
}

// The path-component rule (modules.md §Filesystem): `[a-z][a-z0-9_]*`. Module directories, package names,
// workspace scopes and names, and pin aliases all follow it, since each becomes a bare qualifier or a
// directory name.
public func isPathComponent(_ s: String) -> Bool {
    guard let first = s.utf8.first, first >= 0x61, first <= 0x7A else { return false }
    return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
}
