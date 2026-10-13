import Foundation

// Cross-package import resolution within a workspace (task 187.2). A `.package_(name)` import names another
// package by its own name; this resolves it to a module directory, enforcing the two rules the dependency
// model settled (modules.md §Manifest): imports are **strict** (a module may import only packages its own
// `pkg.json` declares), and a package name maps to **one location** workspace-wide.
//
// External-workspace resolution (a declared package that is not an in-workspace package — pinned by version
// in `nomu.yaml`) is a later increment; such a name resolves to `.external` here, which the caller reports
// as not-yet-supported. The compile-path wiring (a graph that spans packages, package-aware mangling, and
// linkage) rides task 187.3; this is the reusable resolution core it builds on.

// The in-workspace package registry: each package's declared `name` → its package-root directory, built by
// scanning the workspace tree for `pkg.json` markers (packages do not nest, so a marker is a leaf for the
// scan). A package belongs to its nearest-ancestor workspace, so the scan prunes any nested workspace (a
// subtree carrying its own `nomu.yaml`), plus `build/` and dot-directories.
public func scanWorkspacePackages(workspaceRoot: String) throws -> [String: String] {
    let fm = FileManager.default
    var registry: [String: String] = [:]
    func walk(_ dir: String, isRoot: Bool) throws {
        if !isRoot && fm.fileExists(atPath: dir + "/nomu.yaml") { return }   // a nested workspace boundary
        if fm.fileExists(atPath: dir + "/pkg.json") {
            if let manifest = try loadManifest(packageRoot: dir) {
                if let prev = registry[manifest.name], prev != dir {
                    throw WorkspaceError.duplicatePackageName(name: manifest.name, a: prev, b: dir)
                }
                registry[manifest.name] = dir
            }
            return   // packages do not nest; a package root's subtree is its modules
        }
        for entry in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            if entry.hasPrefix(".") || entry == "build" { continue }
            var isDir: ObjCBool = false
            let child = dir + "/" + entry
            if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                try walk(child, isRoot: false)
            }
        }
    }
    try walk(workspaceRoot, isRoot: true)
    return registry
}

// The outcome of resolving one `.package_` import.
public enum ImportResolution: Equatable {
    case module(dir: String)            // resolved to an in-workspace package's module directory
    case notDeclared(package: String)   // the importer did not list this package in its `dependencies`
    case external(package: String)      // declared, but not an in-workspace package (external — deferred)
    case noModule(package: String)      // package found, but the named module (or its default) does not exist
}

// Resolve a `.package_(name)` import against the importer package's declared dependencies and the workspace
// registry. `path` is the import's components after the package name (`import libfoo/sub` → ["sub"];
// `import libfoo` → []). A bare package name forwards to the package's `default-module` (or its root module
// when the package root carries source, a single-module package).
public func resolvePackageImport(package name: String, path: [String],
                                 declaredDeps: [String],
                                 registry: [String: String]) -> ImportResolution {
    guard declaredDeps.contains(name) else { return .notDeclared(package: name) }
    guard let pkgDir = registry[name] else { return .external(package: name) }

    let moduleDir: String
    if path.isEmpty {
        if !scanModuleFiles(pkgDir).isEmpty {
            moduleDir = pkgDir                                   // single-module package: its root is the module
        } else if let def = (try? loadManifest(packageRoot: pkgDir))??.defaultModule {
            moduleDir = pkgDir + "/" + def                       // container package: its default module
        } else {
            return .noModule(package: name)                      // a bare name with no default to forward to
        }
    } else {
        moduleDir = pkgDir + "/" + path.joined(separator: "/")   // a named submodule within the package
    }
    guard !scanModuleFiles(moduleDir).isEmpty else { return .noModule(package: name) }
    return .module(dir: moduleDir)
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case duplicatePackageName(name: String, a: String, b: String)
    public var description: String {
        switch self {
        case .duplicatePackageName(let name, let a, let b):
            return "two packages in the workspace are both named '\(name)': '\(a)' and '\(b)'"
        }
    }
}
