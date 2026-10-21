import embedded

// The language workspace (task 174): the language's own Nomu sources, carried in the compiler binary.
// The planner reads it as an in-memory tree with the same layout an on-disk workspace has (a `nomu.yaml`,
// one `pkg.json` per package), so it is planned like any other workspace.
//
// Three packages. `core` and `runtime` are single-module packages rooted at their own source file; `std` is
// a multi-module package (one leaf directory per module) whose `default-module` is `prelude`, the module the
// implicit `import std` names. Every module is a product, and `std` lists `core` in its `dependencies`
// (only `std` may import `core`).
public enum LanguageWorkspace {
    public static let identity = WorkspaceIdentity(scope: "nomu", name: "nomu")
    // The tree's root. Never a real directory: the tree serves every path under it from memory.
    public static let root = "<nomu>"

    // One module file: its package-relative directory ("" for a single-module package's root), file name
    // and source. A module may span several files.
    public struct ModuleFile { public let dir: String; public let file: String; public let source: String }
    public struct Package {
        public let name: String
        public let files: [ModuleFile]
        public let defaultModule: String?
        // The package's module directories, in first-seen order.
        public var moduleDirs: [String] {
            var seen = Set<String>()
            return files.map(\.dir).filter { seen.insert($0).inserted }
        }
    }

    public static let packages: [Package] = [
        Package(name: "core",
                files: [ModuleFile(dir: "", file: EmbeddedSources.preludeName, source: EmbeddedSources.preludeSource)],
                defaultModule: nil),
        Package(name: "runtime",
                files: [ModuleFile(dir: "", file: EmbeddedSources.runtimePreludeName,
                                   source: EmbeddedSources.runtimePreludeSource)],
                defaultModule: nil),
        Package(name: "std",
                files: EmbeddedSources.stdModules.map { ModuleFile(dir: $0.module, file: $0.name, source: $0.source) },
                defaultModule: "prelude"),
    ]

    // The workspace's files, keyed by path relative to the workspace root: `nomu.yaml`, and per package its
    // `pkg.json` and module sources.
    public static func files() -> [(path: String, text: String)] {
        var out: [(path: String, text: String)] = [("nomu.yaml", "scope: \(identity.scope)\nname: \(identity.name)\n")]
        for p in packages {
            let products = p.moduleDirs.map { "\"\($0)\"" }.joined(separator: ", ")
            let def = p.defaultModule.map { ", \"default-module\": \"\($0)\"" } ?? ""
            let deps = p.name == "std" ? ", \"dependencies\": [\"core\"]" : ""
            out.append(("\(p.name)/pkg.json", "{ \"name\": \"\(p.name)\", \"products\": [\(products)]\(def)\(deps) }\n"))
            for f in p.files {
                out.append(((f.dir.isEmpty ? p.name : "\(p.name)/\(f.dir)") + "/" + f.file, f.source))
            }
        }
        return out
    }

    // The workspace as an in-memory tree rooted at `root`, built once per process (it never changes).
    public static let tree: MemoryTree = {
        let tree = MemoryTree()
        for f in files() { tree.add(root + "/" + f.path, f.text) }
        return tree
    }()
}
