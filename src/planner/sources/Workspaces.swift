import Foundation
import modules

// One workspace in a build: its identity, where its files live, and what has been read from it. Every read
// goes through the workspace's tree and is cached, so each directory is listed at most once per build.
public final class Workspace {
    public let identity: WorkspaceIdentity
    public let root: String
    public let tree: SourceTree
    public let isEmbedded: Bool
    // The `nomu.yaml` it was read from; nil for a loose build.
    public let configFile: String?
    // This workspace's pins: alias → the pinned workspace's identity. Filled as pins load.
    public internal(set) var pins: [String: WorkspaceIdentity] = [:]
    let configPins: [WorkspaceConfig.Pin]

    private var listings: [String: [DirEntry]] = [:]
    private var missing: Set<String> = []
    let clock: PlanClock

    init(identity: WorkspaceIdentity, root: String, tree: SourceTree, isEmbedded: Bool, configFile: String?,
         configPins: [WorkspaceConfig.Pin], clock: PlanClock) {
        self.identity = identity; self.root = root; self.tree = tree; self.isEmbedded = isEmbedded
        self.configFile = configFile; self.configPins = configPins; self.clock = clock
    }

    // A directory's entries, listed once; nil when it is not a directory.
    public func entries(_ dir: String) -> [DirEntry]? {
        if let e = listings[dir] { return e }
        if missing.contains(dir) { return nil }
        clock.count(listed: 1)
        guard let e = clock.measure(.listings, { tree.list(dir) }) else { missing.insert(dir); return nil }
        listings[dir] = e
        return e
    }

    // A module directory's `.nomu` files, sorted; empty when it holds none.
    public func moduleFiles(_ dir: String) -> [String] {
        (entries(dir) ?? []).filter { $0.kind == .file && $0.name.hasSuffix(".nomu") }.map { dir + "/" + $0.name }
    }
}

// A package found in a workspace: its declared name, its root directory, and its manifest.
public struct Package {
    public let name: String
    public let root: String
    public let manifest: Manifest
}

// The workspaces a build reaches: the one it starts in, every workspace pinned from there (pins at any depth,
// D6), and the embedded `nomu` workspace. Loading reads each `nomu.yaml` once and checks identities;
// packages and module listings are read on demand and cached. Every error is collected in `diagnostics`.
public final class WorkspaceSet {
    public private(set) var root: Workspace
    public private(set) var byIdentity: [WorkspaceIdentity: Workspace] = [:]
    public private(set) var diagnostics: [PlanDiagnostic] = []

    private let disk: SourceTree
    private var byRoot: [String: Workspace] = [:]
    private var manifests: [String: Manifest?] = [:]
    private var registries: [WorkspaceIdentity: [String: Package]] = [:]

    public let clock: PlanClock

    // Load the workspaces for a build entered at `entry` (a source file or a module directory on `disk`).
    // `includeEmbedded` adds the embedded `nomu` workspace.
    public init(entry: String, disk: SourceTree = DiskTree(), includeEmbedded: Bool, clock: PlanClock = PlanClock()) {
        self.disk = disk
        self.clock = clock
        let start = Self.directory(of: entry, in: disk)
        // A placeholder until the real root loads.
        root = Workspace(identity: looseWorkspaceIdentity, root: start, tree: disk, isEmbedded: false,
                         configFile: nil, configPins: [], clock: clock)
        clock.measure(.workspaces) { load(from: start, includeEmbedded: includeEmbedded) }
    }

    private func load(from start: String, includeEmbedded: Bool) {
        if let wsRoot = Self.ancestor(of: start, containing: "nomu.yaml", in: disk) {
            let canonical = disk.canonical(wsRoot) ?? wsRoot
            if let ws = loadDiskWorkspace(at: canonical, pinnedFrom: nil) { root = ws }
        } else {
            // A loose build: rooted at the entry's package (its nearest `pkg.json`), else the entry's directory.
            let looseRoot = Self.ancestor(of: start, containing: "pkg.json", in: disk) ?? start
            root = Workspace(identity: looseWorkspaceIdentity, root: looseRoot, tree: disk, isEmbedded: false,
                             configFile: nil, configPins: [], clock: clock)
            register(root, claimedAt: nil)
        }
        if includeEmbedded { loadEmbedded() }
        loadPins()
    }

    // MARK: - Loading

    private func loadDiskWorkspace(at canonicalRoot: String, pinnedFrom pin: (Workspace, WorkspaceConfig.Pin)?)
        -> Workspace?
    {
        if let ws = byRoot[canonicalRoot] { return ws }
        let file = canonicalRoot + "/nomu.yaml"
        guard let bytes = disk.read(file) else {
            if let (from, p) = pin {
                report(PlanDiagnostic(file: from.configFile, line: p.line, column: p.column,
                                      "pinned workspace '\(p.alias)' at '\(p.path)' has no nomu.yaml"))
            }
            return nil
        }
        let (config, errors) = WorkspaceConfig.parse(bytes, file: file)
        diagnostics += errors
        guard let config else { return nil }
        let ws = Workspace(identity: config.identity, root: canonicalRoot, tree: disk, isEmbedded: false,
                           configFile: file, configPins: config.pins, clock: clock)
        guard register(ws, claimedAt: pin) else { return nil }
        return ws
    }

    private func loadEmbedded() {
        let tree = EmbeddedWorkspace.tree
        let ws = Workspace(identity: EmbeddedWorkspace.identity, root: EmbeddedWorkspace.root, tree: tree,
                           isEmbedded: true, configFile: EmbeddedWorkspace.root + "/nomu.yaml", configPins: [], clock: clock)
        register(ws, claimedAt: nil)
    }

    // Record a loaded workspace. Two distinct workspaces with one identity are an error (D6): the identity
    // is the build's key for a workspace and the prefix of its symbols.
    @discardableResult
    private func register(_ ws: Workspace, claimedAt pin: (Workspace, WorkspaceConfig.Pin)?) -> Bool {
        if let other = byIdentity[ws.identity] {
            let message = "two workspaces in this build are both '\(ws.identity)': '\(other.root)' and '\(ws.root)'"
            if let (from, p) = pin {
                report(PlanDiagnostic(file: from.configFile, line: p.line, column: p.column, message))
            } else {
                report(PlanDiagnostic(file: ws.configFile, message))
            }
            return false
        }
        byIdentity[ws.identity] = ws
        byRoot[ws.root] = ws
        return true
    }

    // Follow every pin, breadth-first from the root. A pin's path is relative to the pinning workspace's
    // root unless absolute; two pins resolving to one directory name one workspace.
    private func loadPins() {
        var queue = [root]
        var seen: Set<String> = [root.root]
        while !queue.isEmpty {
            let ws = queue.removeFirst()
            for p in ws.configPins {
                let path = p.path.hasPrefix("/") ? p.path : ws.root + "/" + p.path
                guard let canonical = disk.canonical(path) else {
                    report(PlanDiagnostic(file: ws.configFile, line: p.line, column: p.column,
                                          "pinned workspace '\(p.alias)' at '\(p.path)' does not exist"))
                    continue
                }
                guard let pinned = loadDiskWorkspace(at: canonical, pinnedFrom: (ws, p)) else { continue }
                ws.pins[p.alias] = pinned.identity
                if seen.insert(pinned.root).inserted { queue.append(pinned) }
            }
        }
    }

    // MARK: - Packages

    // A package root's manifest, read once; nil when absent or malformed (malformed is reported).
    public func manifest(in ws: Workspace, packageRoot: String) -> Manifest? {
        let path = packageRoot + "/pkg.json"
        if let m = manifests[path] { return m }
        var m: Manifest? = nil
        if let bytes = ws.tree.read(path) {
            do { m = try decodeManifest(Data(bytes), path: path) }
            catch { report(PlanDiagnostic(file: path, "\(error)")) }
        }
        manifests[path] = m
        return m
    }

    // The workspace's packages by name, found by one walk of its tree the first time they are needed. The
    // walk stops at each package root (packages do not nest) and at nested workspaces, and skips `build/`,
    // dot-directories and symlinks. A duplicate package name, or a reserved one outside the embedded
    // workspace, is reported and the later package dropped.
    public func packages(in ws: Workspace) -> [String: Package] {
        if let r = registries[ws.identity] { return r }
        return clock.measure(.registry) { walkPackages(of: ws) }
    }

    private func walkPackages(of ws: Workspace) -> [String: Package] {
        var registry: [String: Package] = [:]
        func walk(_ dir: String, isRoot: Bool) {
            guard let entries = ws.entries(dir) else { return }
            if !isRoot, entries.contains(where: { $0.name == "nomu.yaml" && $0.kind == .file }) { return }
            if entries.contains(where: { $0.name == "pkg.json" && $0.kind == .file }) {
                guard let m = manifest(in: ws, packageRoot: dir) else { return }
                if let prev = registry[m.name] {
                    report(PlanDiagnostic(file: dir + "/pkg.json", "two packages in workspace '\(ws.identity)' are "
                                          + "both named '\(m.name)': '\(prev.root)' and '\(dir)'"))
                } else if !ws.isEmbedded, reservedPackageNames.contains(m.name) {
                    report(PlanDiagnostic(file: dir + "/pkg.json", reservedPackageNameError(m.name, at: dir)))
                } else {
                    registry[m.name] = Package(name: m.name, root: dir, manifest: m)
                }
                return
            }
            for e in entries where e.kind == .directory && !e.name.hasPrefix(".") && e.name != "build" {
                walk(dir + "/" + e.name, isRoot: false)
            }
        }
        walk(ws.root, isRoot: true)
        registries[ws.identity] = registry
        return registry
    }

    // MARK: - Helpers

    private func report(_ d: PlanDiagnostic) { diagnostics.append(d) }

    // The directory an entry names: the entry itself if it is a directory, else its parent.
    private static func directory(of entry: String, in tree: SourceTree) -> String {
        let abs = entry.hasPrefix("/") ? entry : FileManager.default.currentDirectoryPath + "/" + entry
        let path = URL(fileURLWithPath: abs).standardizedFileURL.path
        return tree.kind(of: path) == .directory ? path : (path as NSString).deletingLastPathComponent
    }

    // The nearest directory at or above `dir` that holds a file named `marker`.
    private static func ancestor(of dir: String, containing marker: String, in tree: SourceTree) -> String? {
        var d = dir
        while true {
            if tree.kind(of: d + "/" + marker) == .file { return d }
            let parent = (d as NSString).deletingLastPathComponent
            if parent == d || parent.isEmpty { return nil }
            d = parent
        }
    }
}
