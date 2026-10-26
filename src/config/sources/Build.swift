// A build's configuration (G4, G5, G18, G20): the files of every workspace in the build, the selection, and
// the stack each module resolves through.
//
// The entry workspace resolves under the flattened selection. Externals and the language workspace resolve
// under that list cut to builtin names, or, with no selection, under the externals' default. An external's
// stack ends with the entry's `externals:` blocks, `all` then its pin alias, whose qualifiers are the entry's.
// Program and build settings resolve once, from the builtin layer and the entry workspace's file, and every
// module takes those values.

// A workspace's `cfg.yaml` files, as the caller found them.
public struct WorkspaceFiles {
    public enum Role: Equatable { case entry, external, language }

    // `scope.name`.
    public let identity: String
    public let role: Role
    public let workspace: ConfigFile?
    // By path within the workspace. A `cfg.yaml` at a package root that is also its root module is the
    // package's.
    public let packages: [String: ConfigFile]
    public let modules: [String: ConfigFile]

    public init(_ identity: String, role: Role, workspace: ConfigFile? = nil,
                packages: [String: ConfigFile] = [:], modules: [String: ConfigFile] = [:]) {
        self.identity = identity
        self.role = role
        self.workspace = workspace
        self.packages = packages
        self.modules = modules
    }
}

// Where a module sits: its workspace, and the paths of its package and of itself within the workspace.
public struct ModulePlace: Hashable {
    public let workspace: String
    public let package: String?
    public let module: String

    public init(_ workspace: String, package: String?, module: String) {
        self.workspace = workspace
        self.package = package
        self.module = module
    }

    // `acme.app/net/tls`, as the configuration record names modules.
    public var name: String { module.isEmpty ? workspace : workspace + "/" + module }
}

public struct BuildConfiguration {
    public let schema: Schema
    // The flattened lists: the entry workspace's, and the one externals and the language workspace share.
    public let entryActive: [String]
    public let externalActive: [String]
    let workspaces: [String: WorkspaceFiles]
    let order: [String]  // workspace identities, entry first, then as given
    let entry: String
    let tables: [String: ConfigTable]
    let builtin: Layer
    let externalsAll: Layer?
    let externalsByWorkspace: [String: Layer]
    let externalsBlocks: [Layer]  // in file order, for the record
    let buildWide: Configuration

    // Reads the build's files and selection, checking every file once. `pins` maps the entry workspace's pin
    // aliases to workspace identities. `defaultSelection` is the subcommand's default, used when `selection`
    // is empty; `externalDefault` is the externals' list then.
    public init(_ schema: Schema, workspaces given: [WorkspaceFiles], pins: [String: String],
                selection: [(name: String, origin: Origin)], defaultSelection: [String],
                externalDefault: [String]) throws(ConfigErrors) {
        precondition(given.filter { $0.role == .entry }.count == 1, "a build has one entry workspace")
        self.schema = schema
        builtin = schema.builtinLayer
        var errors = ConfigErrors()
        let entryFiles = given.first { $0.role == .entry }!
        entry = entryFiles.identity
        order = [entry] + given.filter { $0.role != .entry }.map(\.identity)
        workspaces = Dictionary(uniqueKeysWithValues: given.map { ($0.identity, $0) })

        // Sections a file may not hold.
        for w in given {
            for (_, f) in w.packages.sorted(by: { $0.key < $1.key }) + w.modules.sorted(by: { $0.key < $1.key }) {
                if let at = f.configsOrigin {
                    errors.report(ConfigError(.configInWrongLayer, at, "configs are declared only in a workspace `cfg.yaml`"))
                }
                if let at = f.externalsOrigin {
                    errors.report(ConfigError(.malformedSection, at, "`externals` belongs in the entry workspace's `cfg.yaml`"))
                }
            }
        }

        // Config tables: each workspace's own, so its qualifiers name its configs.
        var tables: [String: ConfigTable] = [:]
        for w in given {
            do {
                tables[w.identity] = try ConfigTable([builtin, BuildConfiguration.workspaceLayer(w)])
            } catch {
                errors.errors += error.errors
            }
        }
        let builtinTable = try ConfigTable([builtin])
        self.tables = tables
        guard errors.isEmpty, let entryTable = tables[entry] else { throw errors }

        let chosen = selection.isEmpty ? defaultSelection.map { (name: $0, origin: Origin.builtin) } : selection
        entryActive = try entryTable.flatten(chosen)
        if selection.isEmpty {
            externalActive = try builtinTable.flatten(externalDefault.map { (name: $0, origin: Origin.builtin) })
        } else {
            externalActive = entryActive.filter(builtinTable.contains)
        }

        // The entry's `externals:` blocks.
        var all: Layer?
        var byWorkspace: [String: Layer] = [:]
        var blocks: [Layer] = []
        for block in entryFiles.workspace?.externals ?? [] {
            let layer = Layer(.externals, name: block.target, declarations: block.declarations)
            if block.target == "all" {
                all = layer
            } else if let identity = pins[block.target] {
                byWorkspace[identity] = layer
            } else {
                errors.report(ConfigError(.unknownExternal, block.origin, "`\(block.target)` is not `all` or a pin alias",
                                          fix: closest(block.target, Array(pins.keys)).map { "did you mean `\($0)`?" }))
                continue
            }
            blocks.append(layer)
        }
        externalsAll = all
        externalsByWorkspace = byWorkspace
        externalsBlocks = blocks

        // Program and build settings, once, from the builtin layer and the entry workspace's file.
        let entryLayer = BuildConfiguration.workspaceLayer(entryFiles)
        do {
            buildWide = try resolve(schema, layers: [builtin, entryLayer], configs: entryTable, active: entryActive)
        } catch {
            errors.errors += error.errors
            buildWide = Configuration(active: [], settings: [])
        }

        // Every other file, once, in the scope it resolves in.
        for layer in blocks {
            BuildConfiguration.check(schema, builtin, ScopedLayer(layer, configs: entryTable, active: entryActive), &errors)
        }
        for identity in order {
            let w = workspaces[identity]!
            let configs = tables[identity]!
            let active = w.role == .entry ? entryActive : externalActive
            var layers = BuildConfiguration.packageLayers(w) + BuildConfiguration.moduleLayers(w)
            if w.role != .entry { layers.insert(BuildConfiguration.workspaceLayer(w), at: 0) }
            for layer in layers {
                BuildConfiguration.check(schema, builtin, ScopedLayer(layer, configs: configs, active: active), &errors)
            }
        }
        if !errors.isEmpty { throw errors }
    }

    // Checks one layer by resolving it over the builtin layer.
    private static func check(_ schema: Schema, _ builtin: Layer, _ layer: ScopedLayer, _ errors: inout ConfigErrors) {
        do {
            _ = try resolve(schema, layers: [ScopedLayer(builtin, configs: layer.configs, active: layer.active), layer],
                            active: layer.active)
        } catch {
            errors.errors += error.errors
        }
    }

    // The layers a module resolves through, weakest first, each with its config scope.
    public func stack(for place: ModulePlace) -> [ScopedLayer] {
        guard let w = workspaces[place.workspace] else { preconditionFailure("unknown workspace `\(place.workspace)`") }
        let table = tables[place.workspace]!
        let active = w.role == .entry ? entryActive : externalActive
        var layers: [Layer] = [builtin, BuildConfiguration.workspaceLayer(w)]
        if let p = place.package, let f = w.packages[p] {
            layers.append(Layer(.package, name: BuildConfiguration.join(w.identity, p), declarations: f.declarations))
        }
        if place.module != place.package, let f = w.modules[place.module] {
            layers.append(Layer(.module, name: BuildConfiguration.join(w.identity, place.module), declarations: f.declarations))
        }
        var scoped = layers.map { ScopedLayer($0, configs: table, active: active) }
        if w.role == .external {
            let entryTable = tables[entry]!
            for block in [externalsAll, externalsByWorkspace[w.identity]].compactMap({ $0 }) {
                scoped.append(ScopedLayer(block, configs: entryTable, active: entryActive))
            }
        }
        return scoped
    }

    // The program and build settings, which every module shares. Its module settings hold the entry
    // workspace's values and belong to no module.
    public var buildWideSettings: Configuration { buildWide }

    // The configuration a module compiles under. Its program and build settings are the build's.
    public func configuration(for place: ModulePlace) -> Configuration {
        let w = workspaces[place.workspace]!
        let active = w.role == .entry ? entryActive : externalActive
        // Every file was checked when the build was read, so resolution cannot fail here.
        let own: Configuration
        do {
            own = try resolve(schema, layers: stack(for: place), active: active)
        } catch {
            preconditionFailure("a checked stack failed to resolve: \(error.rendered)")
        }
        let settings = own.settings.map { r in
            r.setting.granularity == .module ? r : buildWide.resolved(r.setting.name)!
        }
        return Configuration(active: active, settings: settings)
    }

    // MARK: Layers

    static func workspaceLayer(_ w: WorkspaceFiles) -> Layer {
        Layer(w.role == .entry ? .entryWorkspace : .workspace, name: w.identity,
              declarations: w.workspace?.declarations ?? [], configs: w.workspace?.configs ?? [])
    }

    static func packageLayers(_ w: WorkspaceFiles) -> [Layer] {
        w.packages.sorted { $0.key < $1.key }.map { Layer(.package, name: join(w.identity, $0.key), declarations: $0.value.declarations) }
    }

    static func moduleLayers(_ w: WorkspaceFiles) -> [Layer] {
        w.modules.sorted { $0.key < $1.key }.map { Layer(.module, name: join(w.identity, $0.key), declarations: $0.value.declarations) }
    }

    static func join(_ identity: String, _ path: String) -> String { path.isEmpty ? identity : identity + "/" + path }
}
