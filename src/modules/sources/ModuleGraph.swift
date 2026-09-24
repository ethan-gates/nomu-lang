import ast
import support
import Foundation

// The module/package model (task 100.2; modules.md). A module is a directory of `.nomu` files, its
// identity the directory path relative to the package root. Addressing is mechanical — a `pkg/…`
// import maps straight to a directory, with no name→location map. External-package imports await the
// manifest's dependency aliases (task 100.3), so they are not resolved here.

// A module's identity: its directory path relative to the package root, as components. `[]` is the
// package's root module; the last component is the leaf name (the default import qualifier).
public struct ModuleID: Hashable {
    public let components: [String]
    public init(_ components: [String]) { self.components = components }
    public var pathString: String { components.isEmpty ? "(root)" : components.joined(separator: "/") }
    public var leaf: String { components.last ?? "" }
}

// A discovery failure, rendered by the driver.
public enum ModuleError: Error {
    case cycle([ModuleID])   // an import cycle, importer→imported order, closing back on the first
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

// The directory a first-party (`pkg/…`) import addresses. External imports (a named package) return
// nil — resolving them needs the manifest's dependency aliases (task 100.3).
public func resolvePkgImportDir(_ imp: ImportDecl, packageRoot: String) -> String? {
    guard case .pkg = imp.root else { return nil }
    return ([packageRoot] + imp.path).joined(separator: "/")
}

// A module directory's `.nomu` files, sorted for a deterministic file list.
public func scanModuleFiles(_ dir: String) -> [String] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return entries.filter { $0.hasSuffix(".nomu") }.sorted().map { dir + "/" + $0 }
}

// A directed module dependency graph; edges point from importer to imported.
public struct ModuleGraph {
    public private(set) var nodes: Set<ModuleID> = []
    private var edges: [ModuleID: Set<ModuleID>] = [:]
    public init() {}

    public mutating func addNode(_ id: ModuleID) { nodes.insert(id) }
    public mutating func addEdge(from: ModuleID, to: ModuleID) {
        nodes.insert(from); nodes.insert(to)
        edges[from, default: []].insert(to)
    }

    // The modules a module directly imports (its immediate dependencies). Sorted for determinism.
    public func dependencies(of id: ModuleID) -> [ModuleID] {
        (edges[id] ?? []).sorted { $0.pathString < $1.pathString }
    }

    // Dependencies before dependents, or the first cycle found. Nodes and successors are visited in a
    // stable path order so the order (and any reported cycle) is independent of insertion timing.
    public func topologicalOrder() -> Result<[ModuleID], ModuleError> {
        var state: [ModuleID: Int] = [:]   // 1 = on the current path, 2 = finished
        var order: [ModuleID] = []
        var path: [ModuleID] = []

        func visit(_ n: ModuleID) -> ModuleError? {
            if state[n] == 2 { return nil }
            if state[n] == 1 {
                let start = path.firstIndex(of: n) ?? 0
                return .cycle(Array(path[start...]) + [n])
            }
            state[n] = 1; path.append(n)
            for m in (edges[n] ?? []).sorted(by: { $0.pathString < $1.pathString }) {
                if let e = visit(m) { return e }
            }
            path.removeLast(); state[n] = 2; order.append(n)
            return nil
        }

        for n in nodes.sorted(by: { $0.pathString < $1.pathString }) {
            if let e = visit(n) { return .failure(e) }
        }
        return .success(order)
    }
}
