import Foundation
import modules
import planner

// A target path resolved to a single module — the shared resolution `build`, `run`, and `test` all use, so
// a path means the same module to every command (modules.md §First-party addressing):
//   • a package root (`pkg.json` present) with root-level source → that root module (a single-module package);
//   • a package root that is a pure container → its manifest `default-module` (error if none designated);
//   • any other directory → that leaf module.
// Resolution yields exactly one module per path — directory expansion (`//path/...`) that would name many
// modules is the deferred label surface. A command then acts on the resolved module, filtered by its own
// role predicate (`run` wants an executable, `test` wants a declared test module).
public struct ResolvedModule {
    public let dir: String          // the module's source directory
    public let packageRoot: String  // the nearest `pkg.json` ancestor — anchors module identity + `build/`
    public let id: ModuleID         // the module's identity, package-root-relative
}

// Resolve a target directory to a single module, or nil (with a diagnostic) if it is not a directory, lies in
// no workspace (no `nomu.yaml` at or above it; modules.md §Manifest), names a container package with no
// `default-module`, or holds no `.nomu` source.
public func resolveModule(path rawPath: String) -> ResolvedModule? {
    let fm = FileManager.default
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        fputs("error: target '\(rawPath)' is not a directory\n", stderr)
        return nil
    }
    guard WorkspaceSet.workspaceRoot(above: path) != nil else {
        fputs("error: \(WorkspaceSet.missingWorkspaceMessage(path))\n", stderr)
        return nil
    }

    let moduleDir: String
    if fm.fileExists(atPath: path + "/pkg.json") {
        if !scanModuleFiles(path).isEmpty {
            moduleDir = path                      // single-module package: the root is the module
        } else {
            let manifest = try? loadManifest(packageRoot: path)
            guard let def = manifest?.defaultModule else {
                fputs("error: package '\(rawPath)' designates no default-module; name a module "
                    + "(e.g. '\(rawPath)/<module>')\n", stderr)
                return nil
            }
            moduleDir = path + "/" + def          // container package: forward to the default module
        }
    } else {
        moduleDir = path                          // a leaf module directory
    }

    let files = scanModuleFiles(moduleDir)
    guard !files.isEmpty else {
        fputs("error: no '.nomu' source in module '\(moduleDir)'\n", stderr)
        return nil
    }
    let packageRoot = findPackageRoot(for: URL(fileURLWithPath: files[0]).standardizedFileURL).path
    return ResolvedModule(dir: moduleDir, packageRoot: packageRoot,
                          id: moduleID(forDir: moduleDir, packageRoot: packageRoot))
}

// `nomu build <path>` (task 173.5.2): resolve a target directory to a single module and compile it (its
// `pkg/…` dependencies follow via module discovery). Returns the produced binary's path on success, nil on
// failure (so `run` can exec it).
@discardableResult

public func buildTarget(path rawPath: String, options: EmitOptions = EmitOptions(),
                        selection: ConfigSelection = ConfigSelection()) -> String? {
    buildTargetResult(path: rawPath, options: options, selection: selection).binary
}

// The same build, reporting what it did (the binary, and the jobs compiled and taken from the host cache).
public func buildTargetResult(path rawPath: String, options: EmitOptions = EmitOptions(),
                              selection: ConfigSelection = ConfigSelection()) -> BuildResult {
    guard let m = resolveModule(path: rawPath) else { return BuildResult() }
    return build(paths: scanModuleFiles(m.dir), options: options, selection: selection)
}

// Build several target paths as one plan (task 211): each resolves to a module as `buildTarget`'s does. An
// unresolvable path fails the build before anything is planned.
public func buildTargetsResult(paths: [String], options: EmitOptions = EmitOptions(),
                               selection: ConfigSelection = ConfigSelection()) -> BuildResult {
    var targets: [[String]] = []
    for path in paths {
        guard let m = resolveModule(path: path) else { return BuildResult() }
        targets.append(scanModuleFiles(m.dir))
    }
    return build(targets: targets, options: options, selection: selection)
}

// Build an already-resolved module and return its binary path. The binary is named after the module and
// placed in its own unit directory under the workspace `build/` (D2), unless an explicit `-o` names it.
public func buildResolved(_ m: ResolvedModule, options: EmitOptions = EmitOptions(),
                          selection: ConfigSelection = ConfigSelection()) -> String? {
    buildProgram(paths: scanModuleFiles(m.dir), options: options, selection: selection)
}

// `nomu run <path> [-- args]` (task 173.5.3): build the target module, then exec the produced binary,
// forwarding `args` and propagating its exit status. A module without a `main` is not executable — its
// build fails, which surfaces here as a non-zero exit. Returns the process exit code.
public func runTarget(path: String, args: [String], options: EmitOptions = EmitOptions(),
                      selection: ConfigSelection = ConfigSelection()) -> Int32 {
    guard let binary = buildTarget(path: path, options: options, selection: selection) else { return 1 }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: binary)
    proc.arguments = args
    do { try proc.run() } catch {
        fputs("error: cannot run '\(binary)': \(error)\n", stderr)
        return 1
    }
    proc.waitUntilExit()
    return proc.terminationStatus
}

// `nomu test [target]` (task 173.5.4): build and run a test module. Resolution is the shared single-module
// resolver (`resolveModule`), identical to `build`/`run`; `test` then applies its **role predicate** — the
// resolved module must be a declared test module (manifest `tests`), just as `run` requires an executable.
// A test module is built exactly like a binary — its only distinction is a `test import`, which widens its
// visibility into the target (white-box access, handled in `compile`). The real case framework —
// test-case designation, assertions, discovery, isolation — is task 161; today a test module is a plain
// executable whose `main` drives its own checks, so this builds it and runs it, reporting an `ok`/`FAIL`
// line. (Running a whole package's tests from one path is the deferred label surface, shared with `build`.)
@discardableResult

public func testPackage(target rawPath: String, options: EmitOptions = EmitOptions(),
                        selection: ConfigSelection = ConfigSelection(defaultConfig: "test")) -> Bool {
    testPackages(targets: [rawPath], options: options, selection: selection)
}

// Several test targets: each is checked to be a declared test module, all build as one plan (task 211), and
// each binary runs in turn. True when every one builds and passes.
@discardableResult

public func testPackages(targets rawPaths: [String], options: EmitOptions = EmitOptions(),
                         selection: ConfigSelection = ConfigSelection(defaultConfig: "test")) -> Bool {
    var modules: [ResolvedModule] = []
    for rawPath in rawPaths {
        guard let m = resolveModule(path: rawPath) else { return false }
        // Role predicate: a test module is one declared in the package manifest's `tests` (modules.md §Tests —
        // test identity is module-level and manifest-declared).
        let manifest: Manifest?
        do { manifest = try loadManifest(packageRoot: m.packageRoot) }
        catch { fputs("error: \(error)\n", stderr); return false }
        let declared = (manifest?.tests ?? []).map { testModuleID($0.module) }
        guard declared.contains(m.id) else {
            let name = m.id.components.isEmpty ? "(root)" : m.id.pathString
            fputs("error: '\(name)' is not a declared test module — list it under 'tests' in "
                + "'\(m.packageRoot)/pkg.json'\n", stderr)
            return false
        }
        modules.append(m)
    }
    func label(_ m: ResolvedModule) -> String { m.id.components.isEmpty ? "(root)" : m.id.pathString }

    let built = build(targets: modules.map { scanModuleFiles($0.dir) }, options: options, selection: selection)
    guard built.binary != nil, built.binaries.count == modules.count else {
        for m in modules { fputs("FAIL  \(label(m)) — build failed\n", stderr) }
        return false
    }
    var passed = true
    for (m, binary) in zip(modules, built.binaries) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        do { try proc.run() } catch {
            fputs("FAIL  \(label(m)) — cannot run '\(binary)': \(error)\n", stderr)
            passed = false
            continue
        }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { fputs("ok    \(label(m))\n", stderr) }
        else { fputs("FAIL  \(label(m)) — exit \(proc.terminationStatus)\n", stderr); passed = false }
    }
    return passed
}

// The module identity named by a manifest `tests`/`bin` entry: a package-root-relative, `/`-separated path,
// with "" naming the package's root module.
private func testModuleID(_ rel: String) -> ModuleID {
    rel.isEmpty ? ModuleID([]) : ModuleID(rel.split(separator: "/").map(String.init))
}

// `nomu query [target]` (task 173.6): print the package metadata rooted at a target module — the package
// identity plus the module graph of its workspace reachable from it (its modules, the importer→imported
// edges, and the packages it uses from other workspaces). Read from the planner's module table (task 190),
// so the graph is exactly what a build of that module plans; nothing compiles. Emits JSON on stdout for
// tooling (task 137 reasons over this graph); planning errors go to stderr. Resolution is the shared
// single-module resolver, so a path names the same module here as to `build`/`run`/`test`.
public func queryPackage(target rawPath: String) -> Bool {
    guard let entry = resolveModule(path: rawPath) else { return false }
    let files = scanModuleFiles(entry.dir)
    let workspaces = WorkspaceSet(entry: files.first ?? entry.dir, includeLanguageWorkspace: true)
    let table = ModuleTable(workspaces: workspaces, entryFiles: files)
    for d in table.diagnostics { fputs(d.description + "\n", stderr) }

    // Module paths are workspace-relative, `/`-separated; the empty string names the workspace's root module.
    let home = table.entry.workspace
    func pathOf(_ k: ModuleKey) -> String { k.path.joined(separator: "/") }
    let local = table.modules.keys.filter { $0.workspace == home }.sorted()
    var edges = Set<[String]>()
    var externals = Set<String>()
    for k in local {
        for imp in table.modules[k]!.imports where !imp.isImplicit {
            if imp.target.workspace == home { edges.insert([pathOf(k), pathOf(imp.target)]) }
            else if let p = imp.crossPackage { externals.insert(p.name) }
        }
    }
    let entryModule = table.modules[table.entry]
    let out = QueryOutput(package: entryModule?.package.name ?? "",
                          root: entryModule?.package.root ?? entry.packageRoot, entry: pathOf(table.entry),
                          modules: local.map(pathOf),
                          dependencies: edges.sorted { $0.lexicographicallyPrecedes($1) }.map { QueryDep(from: $0[0], to: $0[1]) },
                          externals: externals.sorted())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(out), let json = String(data: data, encoding: .utf8) else {
        fputs("error: failed to encode query output\n", stderr)
        return false
    }
    print(json)
    return true
}

// The `nomu query` JSON shape (task 173.6). Deterministic: modules + edges are emitted in sorted order and
// keys are sorted, so the output is stable for tooling and golden comparison.
private struct QueryOutput: Codable {
    let package: String        // the package identity (manifest `name`)
    let root: String           // the package root directory (nearest `pkg.json` ancestor)
    let entry: String          // the queried module's path ("" = the root module)
    let modules: [String]      // every module of the entry's workspace reachable from the entry
    let dependencies: [QueryDep]
    let externals: [String]    // packages of other workspaces imported explicitly (`std` included)
}

private struct QueryDep: Codable { let from: String; let to: String }

// The package root (modules.md §Manifest, §First-party addressing): the nearest ancestor of `input`
// containing a package manifest (`pkg.json`). Failing that, the nearest ancestor carrying the workspace
// marker (`nomu.yaml`) — the interim fallback for a tree not yet carrying a package manifest. Failing
// both, the input's own directory. It anchors mechanical `pkg/…` addressing and module identity (a
// module is its path relative to this root), and the output root is <package-root>/build/.
//
// `pkg.json` (package) and `nomu.yaml` (workspace) sit at different levels, so the package root prefers
// the package manifest; the workspace marker is only a fallback until every tree carries a `pkg.json`.
private func findPackageRoot(for input: URL) -> URL {
    let fm = FileManager.default
    func nearestAncestor(containing marker: String) -> URL? {
        var dir = input.deletingLastPathComponent().standardizedFileURL
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }   // reached the filesystem root
            dir = parent
        }
    }
    return nearestAncestor(containing: "pkg.json")
        ?? nearestAncestor(containing: "nomu.yaml")
        ?? input.deletingLastPathComponent().standardizedFileURL
}
