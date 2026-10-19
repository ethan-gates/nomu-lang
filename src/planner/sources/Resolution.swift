import modules
import scanner

// A module's identity in a build (D6): its workspace's identity and its directory path relative to that
// workspace's root. `[]` is a module at the workspace root.
public struct ModuleKey: Hashable, Comparable, CustomStringConvertible {
    public let workspace: WorkspaceIdentity
    public let path: [String]
    public init(_ workspace: WorkspaceIdentity, _ path: [String]) { self.workspace = workspace; self.path = path }
    public var description: String { path.isEmpty ? "\(workspace):(root)" : "\(workspace):" + path.joined(separator: "/") }
    public static func < (a: Self, b: Self) -> Bool {
        a.workspace != b.workspace ? a.workspace < b.workspace : a.path.lexicographicallyPrecedes(b.path)
    }
}

// The package a module belongs to.
public struct PackageRef: Hashable {
    public let workspace: WorkspaceIdentity
    public let name: String
    public let root: String
}

// One import, resolved. `file` is the importing file; `line`/`column` locate the import (nil for the implicit
// `import std`). `crossPackage` names the imported package when it is another package than the importer's.
public struct ResolvedImport: Equatable {
    public let file: String
    // The import as written (`pkg/…` or a named root, and the components after it).
    public let root: ScannedImport.Root
    public let path: [String]
    public let line: Int?
    public let column: Int?
    public let target: ModuleKey
    public let alias: String?
    public let isPublic: Bool
    public let isTest: Bool
    public var isImplicit: Bool { line == nil }
    public let crossPackage: PackageRef?
}

// One module of the build: where it lives, which package owns it, its files and its resolved imports.
public struct PlannedModule {
    public let key: ModuleKey
    public let dir: String
    public let package: PackageRef
    // The package's `dependencies` (the allow-list for its imports).
    public let declaredDeps: [String]
    public let files: [String]
    // Its package lists it as a product (so it may carry `public` declarations).
    public let isProduct: Bool
    public internal(set) var imports: [ResolvedImport] = []
}

// Every module the build reaches from its entry, with each import resolved and checked. Resolution follows
// imports breadth-first from the entry module across every workspace in `workspaces`; each module's files are
// scanned once. All errors are collected in `diagnostics` (the workspace set's own come first).
public struct ModuleTable {
    public let entry: ModuleKey
    // Modules the build needs without any import naming them: the embedded `runtime` package, whose
    // functions `std` and generated code call by their bare names. Planned before the entry.
    public private(set) var implicitRoots: [ModuleKey] = []
    public private(set) var modules: [ModuleKey: PlannedModule] = [:]
    // Modules in the order resolution reached them (the entry first).
    public private(set) var order: [ModuleKey] = []
    // Modules reached through a same-package `test import`: their interfaces are built white-box.
    public private(set) var testImportTargets: Set<ModuleKey> = []
    public private(set) var diagnostics: [PlanDiagnostic] = []

    public init(workspaces: WorkspaceSet, entryFiles: [String], options: PlanOptions = PlanOptions()) {
        var r = Resolver(workspaces: workspaces, options: options)
        entry = workspaces.clock.measure(.resolve) { r.run(entryFiles: entryFiles) }
        implicitRoots = r.implicitRoots
        workspaces.clock.setModules(r.modules.count)
        modules = r.modules
        order = r.order
        testImportTargets = r.testImportTargets
        diagnostics = workspaces.diagnostics + r.diagnostics
    }
}

// One import to resolve: a scanned one, or the implicit `import std` (no location).
private struct ImportRequest {
    let root: ScannedImport.Root
    let path: [String]
    let alias: String?
    let isPublic: Bool
    let isTest: Bool
    let line: Int?
    let column: Int?

    init(_ s: ScannedImport) {
        root = s.root; path = s.path; alias = s.alias; isPublic = s.isPublic; isTest = s.isTest
        line = s.start.line; column = s.start.column
    }
    init(implicitStd: ()) {
        root = .package("std"); path = []; alias = nil; isPublic = false; isTest = false; line = nil; column = nil
    }
}

private struct Resolver {
    let workspaces: WorkspaceSet
    let options: PlanOptions
    var modules: [ModuleKey: PlannedModule] = [:]
    var order: [ModuleKey] = []
    var testImportTargets: Set<ModuleKey> = []
    var diagnostics: [PlanDiagnostic] = []
    var queue: [ModuleKey] = []
    var implicitRoots: [ModuleKey] = []

    init(workspaces: WorkspaceSet, options: PlanOptions) {
        self.workspaces = workspaces; self.options = options
    }

    // MARK: - Driving

    mutating func run(entryFiles: [String]) -> ModuleKey {
        let ws = workspaces.root
        guard let given = entryFiles.first else {
            diagnostics.append(PlanDiagnostic("no source files given"))
            return ModuleKey(ws.identity, [])
        }
        let rawDir = given.pathParent
        let dir = ws.tree.canonical(rawDir) ?? rawDir
        let files = entryFiles.map { dir + "/" + $0.pathLastComponent }
        let pkgRoot = packageRoot(containing: dir, in: ws)
        let key = ModuleKey(ws.identity, relativePath(dir, in: ws) ?? [])
        add(key, dir: dir, files: files, package: package(at: pkgRoot, in: ws))
        if let embedded = workspaces.byIdentity[EmbeddedWorkspace.identity],
           case .success(let rt) = inPackage("runtime", path: [], of: embedded, external: true) {
            if modules[rt.key] == nil { add(rt.key, dir: rt.dir, files: embedded.moduleFiles(rt.dir), package: (rt.package, rt.deps)) }
            implicitRoots = [rt.key]
        }
        while !queue.isEmpty { resolveImports(of: queue.removeFirst()) }
        return key
    }

    mutating func add(_ key: ModuleKey, dir: String, files: [String], package: (PackageRef, [String])) {
        let products = workspaces.byIdentity[key.workspace].flatMap {
            workspaces.manifest(in: $0, packageRoot: package.0.root)?.products
        } ?? []
        let isProduct = products.contains(relative(dir, to: package.0.root).joined(separator: "/"))
        modules[key] = PlannedModule(key: key, dir: dir, package: package.0, declaredDeps: package.1, files: files,
                                     isProduct: isProduct)
        order.append(key)
        queue.append(key)
    }

    // Scan a module's files and resolve each import, adding newly reached modules to the queue.
    mutating func resolveImports(of key: ModuleKey) {
        guard var m = modules[key], let ws = workspaces.byIdentity[key.workspace] else { return }
        for file in m.files {
            workspaces.clock.count(scanned: 1)
            guard let scanned = workspaces.clock.measure(.scan, { ws.tree.scanImports(file) }) else {
                diagnostics.append(PlanDiagnostic(file: file, "cannot read '\(file)'"))
                continue
            }
            for e in scanned.errors {
                diagnostics.append(PlanDiagnostic(file: file, line: e.location.line, column: e.location.column, e.message))
            }
            // The implicit `import std` (modules.md §Imports): every file outside the embedded workspace imports
            // `std`'s default module, unless it names `std` bare itself.
            if !ws.isEmbedded, workspaces.byIdentity[EmbeddedWorkspace.identity] != nil,
               !scanned.imports.contains(where: { $0.root == .package("std") && $0.path.isEmpty }) {
                if let r = resolve(ImportRequest(implicitStd: ()), from: m, in: ws, file: file) { m.imports.append(r) }
            }
            for imp in scanned.imports {
                if let r = resolve(ImportRequest(imp), from: m, in: ws, file: file) { m.imports.append(r) }
            }
        }
        modules[key] = m
    }

    // MARK: - One import

    mutating func resolve(_ imp: ImportRequest, from m: PlannedModule, in ws: Workspace, file: String)
        -> ResolvedImport? {
        func fail(_ message: String) -> ResolvedImport? {
            diagnostics.append(PlanDiagnostic(file: file, line: imp.line, column: imp.column, message))
            return nil
        }
        let found: Found
        switch target(of: imp, from: m, in: ws) {
        case .failure(let message): return fail(message.text)
        case .success(let f): found = f
        }
        let crossPackage = found.package == m.package ? nil : found.package
        // `test import` is same-package only: a foreign package stays black-box, even to a test.
        if imp.isTest {
            if let crossPackage {
                return fail("'test import' may not cross a package boundary — '\(crossPackage.name)' is a foreign "
                          + "package, always black-box; use a plain 'import'")
            }
            testImportTargets.insert(found.key)
        }
        if modules[found.key] == nil {
            if let bad = found.key.path.first(where: { !isPathComponent($0) }) {
                return fail("module path component '\(bad)' must match [a-z][a-z0-9_]*")
            }
            guard let targetWs = workspaces.byIdentity[found.key.workspace] else { return nil }
            add(found.key, dir: found.dir, files: targetWs.moduleFiles(found.dir), package: (found.package, found.deps))
        }
        return ResolvedImport(file: file, root: imp.root, path: imp.path, line: imp.line, column: imp.column,
                              target: found.key, alias: imp.alias, isPublic: imp.isPublic, isTest: imp.isTest,
                              crossPackage: crossPackage)
    }

    struct Found {
        let key: ModuleKey
        let dir: String
        let package: PackageRef
        let deps: [String]
    }

    // Where an import points. `pkg/…` stays in the importer's package; a bare root names `std`, `core`, a pin
    // alias, or a package (in-workspace, else from a pinned workspace).
    mutating func target(of imp: ImportRequest, from m: PlannedModule, in ws: Workspace) -> Result<Found, Message> {
        switch imp.root {
        case .pkg:
            let dir = ([m.package.root] + imp.path).joined(separator: "/")
            guard !ws.moduleFiles(dir).isEmpty else {
                return .failure(Message("no module found at '\(imp.path.joined(separator: "/"))'"))
            }
            return found(dir: dir, in: ws, package: m.package, deps: m.declaredDeps)

        case .package(let name):
            let embedded = workspaces.byIdentity[EmbeddedWorkspace.identity]
            // `std` is the embedded standard library: it needs no `dependencies` entry, and a user package
            // may not take the name.
            if name == "std", !ws.isEmbedded {
                guard let embedded else { return .failure(Message("this build has no standard library")) }
                return inPackage("std", path: imp.path, of: embedded, external: true)
            }
            // `core` is importable only from `std` (modules.md §Imports). A package that lists `core` in its
            // `dependencies` names its workspace's own `core` package, resolved below like any other.
            if name == "core", !ws.isEmbedded, !m.declaredDeps.contains("core"), let embedded {
                guard options.allowCoreImport else {
                    return .failure(Message("package 'core' is internal to the standard library — use 'std' instead"))
                }
                return inPackage("core", path: imp.path, of: embedded, external: true)
            }
            // A pin alias names another workspace explicitly: `import <alias>/<package>[/<module>]`.
            if let pinned = ws.pins[name], let other = workspaces.byIdentity[pinned] {
                guard let pkg = imp.path.first else {
                    return .failure(Message("'\(name)' names a pinned workspace — import one of its packages "
                                          + "('import \(name)/<package>')"))
                }
                return inPackage(pkg, path: Array(imp.path.dropFirst()), of: other, external: true)
            }
            // A package: strict allow-list first, then this workspace, then the pinned workspaces.
            guard m.declaredDeps.contains(name) else {
                return .failure(Message("package '\(name)' is not listed in this package's 'dependencies'"))
            }
            if workspaces.packages(in: ws)[name] != nil {
                return inPackage(name, path: imp.path, of: ws, external: false)
            }
            for alias in ws.pins.keys.sorted() {
                if let other = workspaces.byIdentity[ws.pins[alias]!], workspaces.packages(in: other)[name] != nil {
                    return inPackage(name, path: imp.path, of: other, external: true)
                }
            }
            return .failure(Message("package '\(name)' is external but no workspace pinned in nomu.yaml provides it"))
        }
    }

    // A module of package `name` in workspace `ws`: a bare package name forwards to its root module (a
    // single-module package) or its `default-module`. The module must be one of the package's products.
    mutating func inPackage(_ name: String, path: [String], of ws: Workspace, external: Bool) -> Result<Found, Message> {
        let ext = external ? "external " : ""
        guard let pkg = workspaces.packages(in: ws)[name] else {
            return .failure(Message("workspace '\(ws.identity)' has no package '\(name)'"))
        }
        let dir: String
        if path.isEmpty {
            if !ws.moduleFiles(pkg.root).isEmpty { dir = pkg.root }
            else if let def = pkg.manifest.defaultModule { dir = pkg.root + "/" + def }
            else { return .failure(Message("package '\(name)' names no default module to import")) }
        } else {
            dir = pkg.root + "/" + path.joined(separator: "/")
        }
        guard !ws.moduleFiles(dir).isEmpty else {
            let sub = path.isEmpty ? "(default module)" : path.joined(separator: "/")
            return .failure(Message("no module '\(sub)' in \(ext)package '\(name)'"))
        }
        let rel = relative(dir, to: pkg.root).joined(separator: "/")
        guard pkg.manifest.products.contains(rel) else {
            let shown = rel.isEmpty ? "(default module)" : rel
            return .failure(Message("module '\(shown)' is not a product of \(ext)package '\(name)' — list it under "
                                  + "'products' in that package's pkg.json"))
        }
        return found(dir: dir, in: ws, package: PackageRef(workspace: ws.identity, name: name, root: pkg.root),
                     deps: pkg.manifest.dependencies)
    }

    func found(dir: String, in ws: Workspace, package: PackageRef, deps: [String]) -> Result<Found, Message> {
        guard let path = relativePath(dir, in: ws) else {
            return .failure(Message("'\(dir)' lies outside workspace '\(ws.identity)'"))
        }
        return .success(Found(key: ModuleKey(ws.identity, path), dir: dir, package: package, deps: deps))
    }

    // MARK: - Packages and paths

    // The package root holding `dir`: its nearest ancestor (within the workspace) with a `pkg.json`, else the
    // workspace root.
    func packageRoot(containing dir: String, in ws: Workspace) -> String {
        var d = dir
        while d.count >= ws.root.count {
            if ws.tree.kind(of: d + "/pkg.json") == .file { return d }
            if d == ws.root { break }
            d = d.pathParent
        }
        return ws.root
    }

    // The entry's package and its dependencies; a root with no manifest is the default package. Other packages
    // come from the package walk, which checks their names; the entry's is checked here.
    mutating func package(at root: String, in ws: Workspace) -> (PackageRef, [String]) {
        let m = workspaces.manifest(in: ws, packageRoot: root)
        if let m, !ws.isEmbedded, reservedPackageNames.contains(m.name) {
            diagnostics.append(PlanDiagnostic(file: root + "/pkg.json", reservedPackageNameError(m.name, at: root)))
        }
        return (PackageRef(workspace: ws.identity, name: m?.name ?? defaultPackageName, root: root), m?.dependencies ?? [])
    }

    func relativePath(_ dir: String, in ws: Workspace) -> [String]? {
        if dir == ws.root { return [] }
        guard dir.hasPrefix(ws.root + "/") else { return nil }
        return relative(dir, to: ws.root)
    }

    func relative(_ dir: String, to root: String) -> [String] {
        dir == root ? [] : dir.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }
}

struct Message: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

// Path helpers on `/`-separated strings, without Foundation's URL normalization.
private extension String {
    var pathParent: String {
        guard let slash = lastIndex(of: "/") else { return "." }
        return slash == startIndex ? "/" : String(self[..<slash])
    }
    var pathLastComponent: String {
        guard let slash = lastIndex(of: "/") else { return self }
        return String(self[index(after: slash)...])
    }
}
