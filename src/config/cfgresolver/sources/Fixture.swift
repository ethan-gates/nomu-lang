import Foundation
import config
import yaml

// A fixture tree read the way a build reads its workspaces, without the planner: a directory holding
// `nomu.yaml` is a workspace (its `scope`, `name` and `externals:` pins), one holding `pkg.json` is a package,
// one holding a `.nomu` file is a module, and a `cfg.yaml` belongs to the workspace, package or module whose
// root holds it. Pins are followed to every transitive external.
struct Fixture {
    var workspaces: [WorkspaceFiles] = []
    var places: [ModulePlace] = []
    // The entry workspace's pin aliases, by alias.
    var pins: [String: String] = [:]

    // `display` turns an absolute path into the one messages show.
    static func load(entry: String, language: String?, display: @escaping (String) -> String) throws(Failure) -> Fixture {
        var reader = FixtureReader(display: display)
        var fixture = Fixture()
        guard let first = reader.workspace(at: entry, role: .entry) else { throw reader.failure }
        var queue = first.pins.map { $0.path }
        var found = [first]
        var seenRoots: Set<String> = [first.root]
        while !queue.isEmpty {
            let root = queue.removeFirst()
            guard seenRoots.insert(root).inserted else { continue }
            guard let w = reader.workspace(at: root, role: .external) else { continue }
            found.append(w)
            queue += w.pins.map { $0.path }
        }
        if let language, let w = reader.workspace(at: language, role: .language) { found.append(w) }
        guard reader.failure.lines.isEmpty else { throw reader.failure }
        for pin in first.pins { fixture.pins[pin.alias] = found.first { $0.root == pin.path }?.identity }
        for w in found {
            fixture.workspaces.append(w.files)
            fixture.places += w.places
        }
        return fixture
    }
}

// Errors the tool prints, one per line.
struct Failure: Error {
    var lines: [String] = []
}

private struct FoundWorkspace {
    let identity: String
    let root: String
    let pins: [(alias: String, path: String)]
    let files: WorkspaceFiles
    let places: [ModulePlace]
}

private struct FixtureReader {
    let display: (String) -> String
    var failure = Failure()
    let fm = FileManager.default

    init(display: @escaping (String) -> String) { self.display = display }

    mutating func workspace(at root: String, role: WorkspaceFiles.Role) -> FoundWorkspace? {
        let manifest = root + "/nomu.yaml"
        guard let bytes = fm.contents(atPath: manifest).map(Array.init) else {
            failure.lines.append("error: \(display(root)) holds no nomu.yaml")
            return nil
        }
        let doc: YAMLDocument
        do {
            doc = try YAMLDocument(parsing: bytes)
        } catch {
            var starts: [UInt32] = [0]
            for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(UInt32(i + 1)) }
            failure.lines.append(error.render(file: display(manifest), lines: LineIndex(lineStarts: starts)))
            return nil
        }
        func place(_ node: YAMLNode) -> String {
            let (line, column) = node.location
            return "\(display(manifest)):\(line):\(column)"
        }
        guard let scope = doc.root["scope"]?.string, let name = doc.root["name"]?.string else {
            failure.lines.append("\(display(manifest)): error: a workspace declares its `scope` and `name`")
            return nil
        }
        if name == "all", let node = doc.root["name"] {
            failure.lines.append("\(place(node)): error: `all` is reserved for the `externals:` block that covers every external")
        }
        var pins: [(alias: String, path: String)] = []
        for entry in doc.root["externals"].map({ Array($0.entries) }) ?? [] {
            if entry.key == "all" {
                failure.lines.append("\(place(entry.value)): error: `all` is reserved and cannot be a pin alias")
                continue
            }
            guard let path = entry.value.string else { continue }
            pins.append((entry.key, standardized(root + "/" + path)))
        }
        let identity = scope + "." + name

        // Packages, modules and `cfg.yaml` files, by path within the workspace.
        var packages: Set<String> = []
        var modules: [String] = []
        var cfgDirs: [String] = []
        walk("", root, &packages, &modules, &cfgDirs)

        var workspaceFile: ConfigFile?
        var packageFiles: [String: ConfigFile] = [:]
        var moduleFiles: [String: ConfigFile] = [:]
        for dir in cfgDirs {
            let path = root + (dir.isEmpty ? "" : "/" + dir) + "/cfg.yaml"
            let file: ConfigFile
            do {
                file = try ConfigFile(Array(fm.contents(atPath: path) ?? Data()), path: display(path))
            } catch {
                failure.lines += error.errors.map(\.rendered)
                continue
            }
            if dir.isEmpty { workspaceFile = file }
            else if packages.contains(dir) { packageFiles[dir] = file }
            else if modules.contains(dir) { moduleFiles[dir] = file }
            else { failure.lines.append("\(display(path)): error: a `cfg.yaml` belongs at a workspace, package or module root") }
        }
        let places = modules.map { m in
            ModulePlace(identity, package: owner(m, packages), module: m)
        }
        return FoundWorkspace(identity: identity, root: root, pins: pins,
                              files: WorkspaceFiles(identity, role: role, workspace: workspaceFile,
                                                    packages: packageFiles, modules: moduleFiles),
                              places: places)
    }

    private func walk(_ rel: String, _ root: String, _ packages: inout Set<String>, _ modules: inout [String], _ cfgDirs: inout [String]) {
        let dir = rel.isEmpty ? root : root + "/" + rel
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        if !rel.isEmpty && names.contains("nomu.yaml") { return }
        if names.contains("pkg.json") { packages.insert(rel) }
        if names.contains(where: { $0.hasSuffix(".nomu") }) { modules.append(rel) }
        if names.contains("cfg.yaml") { cfgDirs.append(rel) }
        for name in names where !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/" + name, isDirectory: &isDir), isDir.boolValue {
                walk(rel.isEmpty ? name : rel + "/" + name, root, &packages, &modules, &cfgDirs)
            }
        }
    }

    // The package a module belongs to: the nearest package root at or above it.
    private func owner(_ module: String, _ packages: Set<String>) -> String? {
        var parts = module.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            let p = parts.joined(separator: "/")
            if packages.contains(p) { return p }
            parts.removeLast()
        }
        return packages.contains("") ? "" : nil
    }
}

func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
