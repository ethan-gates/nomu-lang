// A plan as text (190.5.1): one block per job, one line per fact, in plan order, so a test compares a whole
// plan against a checked-in golden file and a reviewer reads its diff. Paths are machine-independent: a
// workspace's files render under `@<scope>.<name>` (the language workspace's under `@nomu.nomu`), the host
// cache's under `$cache`, and cache keys as `<key>`, so a golden holds on any machine and across compiler
// changes.
//
//     plan for me.app:app/cli
//
//     workspaces
//       me.app  pins prov → them.prov
//       nomu.nomu
//
//     job nomu.nomu:std/prelude
//       package std at @nomu.nomu/std (product)
//       files prelude.nomu
//       library, host-cache
//       out $cache/nomu/<key>/std/prelude/prelude
//     job me.app:app/cli
//       …
//       import main.nomu (implicit) std → nomu.nomu:std/prelude
//       import main.nomu:1:1 pkg/util → me.app:app/util
//       sees nomu.nomu:std/prelude, me.app:app/util
//
//     runtime archive $cache/runtime/<key>/nomu-runtime.a
//     link @me.app/build/app/cli/cli from 2 objects
//
// A plan with errors lists them in place of jobs.
extension Plan {
    public func dump() -> String {
        var out = "plan for \(modules.roots.map(\.description).joined(separator: ", "))\n\nworkspaces\n"
        for id in workspaceRoots.keys.sorted() {
            let pins = (workspacePins[id] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
            out += "  \(id)" + (pins.isEmpty ? "" : "  pins " + pins.joined(separator: ", ")) + "\n"
        }

        if !diagnostics.isEmpty {
            out += "\n"
            for d in diagnostics { out += "error " + render(diagnostic: d) + "\n" }
            return out
        }

        out += "\n"
        for j in jobs {
            let m = modules.modules[j.module]!
            out += "job \(j.module)\n"
            out += "  package \(m.package.name) at \(render(m.package.root))" + (m.isProduct ? " (product)" : "") + "\n"
            out += "  files " + j.files.map(basename).joined(separator: " ") + "\n"
            var kind = [j.product == .binary ? "binary" : "library"]
            if j.inHostCache { kind.append("host-cache") }
            if j.runtimeSubsetByMembership { kind.append("runtime-subset") }
            if j.whiteBox { kind.append("white-box") }
            out += "  " + kind.joined(separator: ", ") + "\n"
            out += "  out \(render(j.outputDir + "/" + j.stem))\n"
            for imp in m.imports {
                let at = imp.line.map { "\(basename(imp.file)):\($0):\(imp.column ?? 1)" } ?? "\(basename(imp.file)) (implicit)"
                var text: [String] = []
                if imp.isPublic { text.append("public") }
                if imp.isTest { text.append("test") }
                let root: String
                switch imp.root { case .pkg: root = "pkg"; case .package(let n): root = n }
                text.append(([root] + imp.path).joined(separator: "/"))
                if let a = imp.alias { text.append("as \(a)") }
                out += "  import \(at) " + text.joined(separator: " ") + " → \(imp.target)"
                    + (imp.crossPackage.map { " (package \($0.name))" } ?? "") + "\n"
            }
            if !j.visibleDependencies.isEmpty {
                out += "  sees " + j.visibleDependencies.map(\.description).joined(separator: ", ") + "\n"
            }
        }
        if let a = runtimeArchive { out += "\nruntime archive \(render(a.archive))\n" }
        for l in links { out += "link \(render(l.output)) from \(l.objects.count) objects\n" }
        return out
    }

    // A path relative to the root it lies under, with cache keys elided.
    func render(_ path: String) -> String {
        if path == cacheRoot || path.hasPrefix(cacheRoot + "/") {
            var parts = String(path.dropFirst(cacheRoot.count)).split(separator: "/").map(String.init)
            // `<cache>/ac/<key>` and `<cache>/cas/<digest>`
            if parts.count >= 2, parts[0] == "ac" || parts[0] == "cas" { parts[1] = "<key>" }
            return "$cache" + (parts.isEmpty ? "" : "/" + parts.joined(separator: "/"))
        }
        // The deepest workspace root holding the path (a workspace may sit inside another's directory).
        let holder = workspaceRoots
            .filter { path == $0.value || path.hasPrefix($0.value + "/") }
            .max { $0.value.count < $1.value.count }
        guard let (id, root) = holder else { return path }
        return "@\(id)" + path.dropFirst(root.count)
    }

    func render(diagnostic d: PlanDiagnostic) -> String {
        guard let file = d.file else { return d.message }
        let loc = d.line.map { ":\($0):\(d.column ?? 1)" } ?? ""
        return render(file) + loc + ": " + d.message
    }

    private func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
