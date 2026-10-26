import Foundation

// One module's compile job (task 190): its sources, the modules it imports (whose artifacts it receives), and
// the directory its outputs go to. Outputs share the stem `stem` within `outputDir`.
public struct ModuleJob: Equatable {
    public enum Product: Equatable { case library, binary }
    public let module: ModuleKey
    public let files: [String]
    // The modules this one imports directly, in first-import order, each once.
    public let dependencies: [ModuleKey]
    // Every module this one imports, directly or not, in dependency order: the modules whose artifacts its
    // compile can see (a re-exported module, or one whose types a dependency's signatures name, is among
    // them, since a module can only re-export or name what it imports).
    public let visibleDependencies: [ModuleKey]
    public let product: Product
    public let outputDir: String
    public let stem: String
    // Built with its white-box interface: some module in the build `test import`s it.
    public let whiteBox: Bool
    // A module of the language workspace's `runtime` package: its functions are a runtime subset by
    // membership.
    public let runtimeSubsetByMembership: Bool
    // Outputs live in the per-host cache (D4); a present entry means the job can be skipped.
    public let inHostCache: Bool

    public var object: String { outputDir + "/" + stem + ".o" }
    public var interface: String { outputDir + "/" + stem + ".nmi" }
    public var bir: String { outputDir + "/" + stem + ".bir" }
    // The executable, for a binary job.
    public var binary: String { outputDir + "/" + stem }
}

// The runtime archive (D4), built from the embedded runtime sources into the per-host cache.
public struct RuntimeArchiveJob: Equatable {
    public let outputDir: String
    public var archive: String { outputDir + "/nomu-runtime.a" }
}

// The final link: every object the plan builds, plus the runtime archive.
public struct LinkJob: Equatable {
    public let objects: [String]
    public let runtimeArchive: String
    public let output: String
}

// A build plan: every job, in an order where each job's dependencies come before it, and the errors found
// while planning. With any error the plan holds no jobs; every planner error is reported before anything
// compiles.
public struct Plan {
    public let modules: ModuleTable
    public let jobs: [ModuleJob]
    public let runtimeArchive: RuntimeArchiveJob?
    public let link: LinkJob?
    public let diagnostics: [PlanDiagnostic]
    public let timings: PlanTimings
    // The workspaces the plan spans: each one's root directory and pins (alias → identity). For rendering
    // the plan (`dump()`).
    public let workspaceRoots: [WorkspaceIdentity: String]
    public let workspacePins: [WorkspaceIdentity: [String: WorkspaceIdentity]]
    public let cacheRoot: String
}

public struct PlanOptions {
    // Lift the `core` import gate (the hidden `--allow-core-import`, for suite fixtures that test `core`).
    public var allowCoreImport = false
    // The entry module's product; a binary build also archives the runtime and links.
    public var product: ModuleJob.Product = .binary
    // The per-host cache root (D4).
    public var cacheRoot: String = HostCache.root(environment: ProcessInfo.processInfo.environment)
    // The compiler's identity for the language workspace's cache key: the git commit it was built from.
    public var compilerIdentity = "unstamped"
    // Every option that changes compiled output (e.g. `-O`), as it enters the language workspace's key.
    public var outputOptions: [String] = []
    // The commands that build the runtime archive, as the driver runs them; they enter the archive's key.
    public var runtimeRecipe: [[String]] = []
    // The directory under the entry workspace's `build/` that holds this configuration's outputs, so builds
    // under different configurations keep their own (empty: `build/` itself).
    public var outputConfig = ""
    public init() {}
}

extension Plan {
    // Plan a build from a resolved module table.
    // Plan a build entered at `entryFiles` (one module's files), reading from `disk`. A binary build includes
    // the language workspace.
    public init(entryFiles: [String], options: PlanOptions = PlanOptions(), disk: SourceTree = DiskTree()) {
        let workspaces = WorkspaceSet(entry: entryFiles.first ?? ".", disk: disk,
                                      includeLanguageWorkspace: options.product == .binary)
        self.init(modules: ModuleTable(workspaces: workspaces, entryFiles: entryFiles, options: options),
                  workspaces: workspaces, options: options)
    }

    public init(modules table: ModuleTable, workspaces: WorkspaceSet, options settings: PlanOptions = PlanOptions()) {
        let clock = workspaces.clock
        let (jobs, archive, link, diagnostics) = clock.measure(.plan) {
            Self.build(table, workspaces, settings)
        }
        self.init(modules: table, jobs: jobs, runtimeArchive: archive, link: link, diagnostics: diagnostics,
                  timings: clock.timings,
                  workspaceRoots: workspaces.byIdentity.mapValues(\.root),
                  workspacePins: workspaces.byIdentity.mapValues(\.pins),
                  cacheRoot: settings.cacheRoot)
    }

    static func build(_ table: ModuleTable, _ workspaces: WorkspaceSet, _ settings: PlanOptions)
        -> ([ModuleJob], RuntimeArchiveJob?, LinkJob?, [PlanDiagnostic]) {
        var diagnostics = table.diagnostics
        let order = Self.moduleOrder(table, &diagnostics)
        Self.checkPackageCycles(table, &diagnostics)
        guard diagnostics.isEmpty else { return ([], nil, nil, diagnostics) }

        let root = workspaces.root
        let languageDir = settings.cacheRoot + "/nomu/"
            + HostCache.languageWorkspaceKey(compilerIdentity: settings.compilerIdentity,
                                             outputOptions: settings.outputOptions)
        let build = root.root + "/build" + (settings.outputConfig.isEmpty ? "" : "/" + settings.outputConfig)
        func outputDir(_ key: ModuleKey) -> String {
            let base: String
            if key.workspace == LanguageWorkspace.identity { base = languageDir }
            else if key.workspace == root.identity { base = build }
            else { base = build + "/_external/\(key.workspace)" }
            return key.path.isEmpty ? base : base + "/" + key.path.joined(separator: "/")
        }

        // Each module's transitive imports, in job order.
        var closure: [ModuleKey: Set<ModuleKey>] = [:]
        for key in order {
            var c = Set<ModuleKey>()
            for imp in table.modules[key]!.imports { c.insert(imp.target); c.formUnion(closure[imp.target] ?? []) }
            closure[key] = c
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        var jobs: [ModuleJob] = []
        for key in order {
            let m = table.modules[key]!
            var deps: [ModuleKey] = []
            for imp in m.imports where !deps.contains(imp.target) { deps.append(imp.target) }
            let isLanguageWorkspace = key.workspace == LanguageWorkspace.identity
            jobs.append(ModuleJob(
                module: key, files: m.files, dependencies: deps,
                visibleDependencies: closure[key]!.sorted { position[$0]! < position[$1]! },
                product: key == table.entry ? settings.product : .library,
                // A module is named by its last path component. Every module has one: packages, and so modules,
                // live below their workspace's root (resolution rejects a module at the root).
                outputDir: outputDir(key), stem: key.path.last!,
                whiteBox: table.testImportTargets.contains(key),
                runtimeSubsetByMembership: isLanguageWorkspace && m.package.name == "runtime",
                inHostCache: isLanguageWorkspace))
        }

        var archive: RuntimeArchiveJob? = nil
        var link: LinkJob? = nil
        if settings.product == .binary {
            let a = RuntimeArchiveJob(outputDir: settings.cacheRoot + "/runtime/"
                                  + HostCache.runtimeArchiveKey(recipe: settings.runtimeRecipe))
            let entry = jobs.last { $0.module == table.entry }!
            archive = a
            link = LinkJob(objects: jobs.map(\.object), runtimeArchive: a.archive, output: entry.binary)
        }
        return (jobs, archive, link, [])
    }

    // Modules in dependency order (each after everything it imports), by a depth-first walk from the entry in
    // import order. A cycle is reported at the import that closes it.
    static func moduleOrder(_ t: ModuleTable, _ diagnostics: inout [PlanDiagnostic]) -> [ModuleKey] {
        var state: [ModuleKey: Bool] = [:]   // false: on the current path; true: done
        var path: [ModuleKey] = []
        var order: [ModuleKey] = []
        var reported = false
        func visit(_ k: ModuleKey) {
            state[k] = false; path.append(k)
            for imp in t.modules[k]?.imports ?? [] {
                switch state[imp.target] {
                case .some(true): continue
                case .some(false):
                    guard !reported else { continue }
                    reported = true
                    let ring = path[path.firstIndex(of: imp.target)!...] + [imp.target]
                    diagnostics.append(PlanDiagnostic(file: imp.file, line: imp.line, column: imp.column,
                        "module import cycle: " + ring.map { display($0, t) }.joined(separator: " → ")))
                case .none: visit(imp.target)
                }
            }
            path.removeLast(); state[k] = true
            order.append(k)
        }
        for root in t.implicitRoots + [t.entry] where state[root] == nil { visit(root) }
        return order
    }

    // The package graph must be a DAG even when no module cycle exists (`P` → `Q` → `P` through different
    // modules). Reported once, at an import on the cycle.
    static func checkPackageCycles(_ t: ModuleTable, _ diagnostics: inout [PlanDiagnostic]) {
        var edges: [PackageRef: [(PackageRef, ResolvedImport)]] = [:]
        for key in t.order {
            let m = t.modules[key]!
            for imp in m.imports {
                guard let to = imp.crossPackage, !(edges[m.package] ?? []).contains(where: { $0.0 == to }) else { continue }
                edges[m.package, default: []].append((to, imp))
            }
        }
        var state: [PackageRef: Bool] = [:]
        var path: [PackageRef] = []
        func visit(_ p: PackageRef) -> Bool {
            state[p] = false; path.append(p)
            for (to, imp) in edges[p] ?? [] {
                if state[to] == true { continue }
                if state[to] == false {
                    let ring = path[path.firstIndex(of: to)!...] + [to]
                    let names = ring.map { $0.workspace == t.entry.workspace ? $0.name : "\($0.workspace):\($0.name)" }
                    diagnostics.append(PlanDiagnostic(file: imp.file, line: imp.line, column: imp.column,
                        "package dependency cycle: " + names.joined(separator: " → ")))
                    return true
                }
                if visit(to) { return true }
            }
            path.removeLast(); state[p] = true
            return false
        }
        for key in t.order {
            let p = t.modules[key]!.package
            if state[p] == nil, visit(p) { return }
        }
    }

    // A module as shown in messages: its path within the entry's workspace, else qualified by its workspace.
    static func display(_ k: ModuleKey, _ t: ModuleTable) -> String {
        let path = k.path.isEmpty ? "(root)" : k.path.joined(separator: "/")
        return k.workspace == t.entry.workspace ? path : "\(k.workspace):\(path)"
    }
}
