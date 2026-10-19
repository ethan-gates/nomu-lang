import Foundation

// The module model (task 100.2; modules.md). A module is a directory of `.nomu` files, its identity the
// directory path relative to a root. Resolving imports and planning a build is the planner's (task 190).

// A module's identity: its directory path relative to the package root, as components. `[]` is the
// package's root module; the last component is the leaf name (the default import qualifier).
public struct ModuleID: Hashable {
    public let components: [String]
    public init(_ components: [String]) { self.components = components }
    public var pathString: String { components.isEmpty ? "(root)" : components.joined(separator: "/") }
    public var leaf: String { components.last ?? "" }
}

// The module a source file belongs to: its directory relative to the package root.
public func moduleID(forFile file: String, packageRoot: String) -> ModuleID {
    moduleID(forDir: (file as NSString).deletingLastPathComponent, packageRoot: packageRoot)
}
public func moduleID(forDir dir: String, packageRoot: String) -> ModuleID {
    let d = URL(fileURLWithPath: dir).standardizedFileURL.path
    let root = URL(fileURLWithPath: packageRoot).standardizedFileURL.path
    guard d.hasPrefix(root) else { return ModuleID([]) }
    var rel = String(d.dropFirst(root.count))
    while rel.hasPrefix("/") { rel.removeFirst() }
    return rel.isEmpty ? ModuleID([]) : ModuleID(rel.split(separator: "/").map(String.init))
}

// A module directory's `.nomu` files, sorted for a deterministic file list.
public func scanModuleFiles(_ dir: String) -> [String] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return entries.filter { $0.hasSuffix(".nomu") }.sorted().map { dir + "/" + $0 }
}
