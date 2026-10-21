import modules

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

// A `pkg.json` at a workspace's root: packages live in subdirectories (modules.md §Manifest).
func packageAtWorkspaceRootError(_ ws: Workspace) -> String {
    "a package may not sit at the root of workspace '\(ws.identity)' — move its pkg.json and modules into a "
        + "subdirectory"
}

// What is wrong with a user package's declared name, or nil: it must follow the path-component rule and not
// be reserved (`std`, `pkg`).
func packageNameProblem(_ name: String, at root: String) -> String? {
    if reservedPackageNames.contains(name) { return reservedPackageNameError(name, at: root) }
    if !isPathComponent(name) {
        return "package name '\(name)' must match [a-z][a-z0-9_]* — rename the package in '\(root)/pkg.json'"
    }
    return nil
}
