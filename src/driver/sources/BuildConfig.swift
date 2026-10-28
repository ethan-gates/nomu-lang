import LLVMBridge
import buildinfo
import config
import planner
import settings

// The configs a build selects (`-c`, G4) and the subcommand's default when none is given.
public struct ConfigSelection {
    public var names: [String]
    public var defaultConfig: String

    public init(_ names: [String] = [], defaultConfig: String = "debug") {
        self.names = names
        self.defaultConfig = defaultConfig
    }
}

// A build's configuration, resolved once (G12): every workspace's `cfg.yaml` files under the selection, and
// each module's place in its stack.
struct ResolvedBuildConfiguration {
    let build: BuildConfiguration
    let places: [ModuleKey: ModulePlace]

    // The settings a module's compile receives: those that change compiled output.
    func jobSettings(_ key: ModuleKey) -> [String: String] {
        build.configuration(for: places[key]!).canonicalValues(for: [.compile])
    }

    // Where the binary's debug info lives (`link.debug_info_storage`), one value per build's binaries.
    var debugInfoStorage: String {
        guard case .choice(let c)? = build.buildWideSettings["link.debug_info_storage"] else { return "objects" }
        return c
    }

    // The values the runtime reads, as the settings object's globals (G14). Run settings are program settings,
    // so the build has one value for each.
    var runtimeGlobals: [(symbol: String, value: RuntimeGlobal)] {
        let settings = build.buildWideSettings
        return CompilerSettings.runSettings.map { run in
            let global: RuntimeGlobal
            switch settings[run.setting.name]! {
            case .bool(let b): global = .bool(b)
            case .int(let v), .size(let v): global = .int(v)
            case .choice(let s), .string(let s): global = .string(s)
            case .list: preconditionFailure("run setting `\(run.setting.name)` is a list; the runtime reads scalars")
            }
            return (run.symbol, global)
        }
    }

    // The record's short form a binary carries in its `__nomu_config` section (G13).
    var summary: String { build.summary(compiler: BuildInfo.gitCommit) }

    // The canonical settings every language-workspace module compiles under. The language workspace reads no
    // files, so its modules share one configuration, and it enters the workspace's host-cache key (G2).
    var languageCanonical: String {
        let place = ModulePlace(LanguageWorkspace.identity.description, package: nil, module: "")
        let c = build.configuration(for: place)
        return c.canonical(c.settings.filter { $0.setting.targets.contains(.compile) }.map(\.setting.name))
    }
}

// Reads the `cfg.yaml` at each workspace, package and module root the build reaches, and resolves them under
// `selection`. Returns the rendered errors when a file or the selection is wrong.
func resolveConfiguration(_ table: ModuleTable, _ workspaces: WorkspaceSet,
                          _ selection: ConfigSelection) -> Result<ResolvedBuildConfiguration, ConfigErrors> {
    var errors = ConfigErrors()
    func read(_ w: Workspace, _ dir: String) -> ConfigFile? {
        let path = dir + "/cfg.yaml"
        guard let bytes = w.tree.read(path) else { return nil }
        do { return try ConfigFile(bytes, path: path) }
        catch { errors.errors += error.errors; return nil }
    }
    func relative(_ dir: String, to root: String) -> String {
        dir == root ? "" : dir.hasPrefix(root + "/") ? String(dir.dropFirst(root.count + 1)) : dir
    }

    let entry = workspaces.root.identity
    var places: [ModuleKey: ModulePlace] = [:]
    var files: [WorkspaceFiles] = []
    for (identity, w) in workspaces.byIdentity.sorted(by: { $0.key < $1.key }) {
        var packages: [String: ConfigFile] = [:]
        var modules: [String: ConfigFile] = [:]
        var seenPackages: Set<String> = []
        for (key, m) in table.modules where key.workspace == identity {
            let package = relative(m.package.root, to: w.root)
            let module = key.path.joined(separator: "/")
            places[key] = ModulePlace(identity.description, package: package, module: module)
            if seenPackages.insert(package).inserted, let f = read(w, m.package.root) { packages[package] = f }
            if m.dir != m.package.root, let f = read(w, m.dir) { modules[module] = f }
        }
        let role: WorkspaceFiles.Role = identity == entry ? .entry : w.isLanguageWorkspace ? .language : .external
        files.append(WorkspaceFiles(identity.description, role: role, workspace: read(w, w.root),
                                    packages: packages, modules: modules))
    }
    if !errors.isEmpty { return .failure(errors) }
    do {
        let build = try BuildConfiguration(
            CompilerSettings.schema, workspaces: files,
            pins: workspaces.root.pins.mapValues(\.description),
            selection: try config.selection(selection.names),
            defaultSelection: [selection.defaultConfig],
            externalDefault: CompilerSettings.externalDefault)
        return .success(ResolvedBuildConfiguration(build: build, places: places))
    } catch {
        return .failure(error)
    }
}
