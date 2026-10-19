import midend
import parse
import noir
import ast
import support
import Foundation
import modules
import interface
import sema
import ssair
import ssairgen
import ssairpasses
import facts
import embedded
import LLVMBridge

// Returns whether compilation succeeded, rather than calling `exit`, so a subcommand (`nomu compile`) can
// turn it into an exit code and an in-process caller (`build`/`run`) can drive it without being killed.
// (Deep helper fatals — codegen/link — still `exit` today; hardened in 173.5.2 when the in-process build
// path exercises them.)
@discardableResult
public func compile(paths: [String], options: EmitOptions = EmitOptions()) -> Bool {
    guard let primary = paths.first else {
        fputs("error: no source files given\n", stderr)
        return false
    }

    // Per-stage timing; reported to stderr on the way out (success or error).
    let timings = Timings()
    timings.optimize = options.optimize
    // An external-workspace build (task 188; the embedded `nomu` workspace, or a pinned local external) runs
    // as nested `compile()` calls; silence their timing reports so they do not spam the user build's stderr.
    timings.silent = options.emitLibrary
    // The backend egress is the SSAIR tier (the sole path since M7.7 retired the NOIR tree-walk);
    // named in the timing header for context.
    timings.egress = "ssair"

    // The package root anchors mechanical `pkg/…` addressing and module identity: the nearest `pkg.json`
    // ancestor, falling back to the `nomu.yaml` workspace marker, then the entry's own directory.
    let input = URL(fileURLWithPath: primary).standardizedFileURL
    let root = findPackageRoot(for: input)
    let packageRoot = root.path
    // Build artifacts live under the **workspace** `build/` (the nearest `nomu.yaml` root), not the
    // package's — one workspace has a single build tree shared by its packages. Falls back to the package
    // root when there is no workspace marker. (Package identity + module IDs stay package-relative, above.)
    let workspaceRoot = findWorkspaceRoot(for: input)
    let wsRootPath = workspaceRoot.path
    // The workspace name (modules.md §Manifest): the first segment of every library symbol's canonical
    // identity, so a workspace's objects are safe to link into another workspace as an external. Read
    // minimally from the `nomu.yaml` `name:` line (full YAML is task 163); falls back to the workspace
    // directory's name when unset. External-workspace support (task 187.5) threads a dependency's own name
    // from its `.nmi`; within one workspace every module shares this name.
    let workspaceName = readWorkspaceName(wsRootPath) ?? workspaceRoot.lastPathComponent

    // A module's identity across the whole workspace: its directory path relative to the **workspace**
    // root (not its package). Two packages with a same-named module then never collide — in the compile
    // graph, in the `build/` intermediates, or in mangled symbols. The graph, every per-module table, and
    // the mangling origin are all keyed by this.
    func graphID(forDir dir: String) -> ModuleID { moduleID(forDir: dir, packageRoot: wsRootPath) }
    func graphID(forFile file: String) -> ModuleID { moduleID(forFile: file, packageRoot: wsRootPath) }
    // The canonical mangling/origin vocabulary of a module (task 187.3): `workspace-name` + the module's
    // workspace-relative path. The producer mangles its library symbols under this key and a consumer
    // derives the identical key for an imported symbol, so a cross-package (and, with 187.5, cross-
    // workspace) reference links to the one definition. Prelude/runtime symbols are exempt (bare, folded
    // weak-ODR); the entry binary is bare too — nothing imports it.
    // A module's canonical mangling vocabulary (task 187.3 / 188): its owning workspace's name + its
    // workspace-relative path. For an in-workspace module the name is the build's own `workspaceName`; a
    // module from an external workspace carries that workspace's name (via its `ModuleHome`), so a
    // cross-workspace reference mangles under the producer's identity. The `moduleHome` lookup resolves to
    // the build's name for every local module, so this is identical to the pre-188 single-name scheme
    // in-workspace.
    func mangleOrigin(_ id: ModuleID) -> [String] {
        if let home = moduleHome[id], home.isExternal { return id.components }   // id is already the full canonical path
        return [moduleHome[id]?.workspaceName ?? workspaceName] + id.components
    }

    // Dependency intermediates (`__mod_*.o` / `.bir`) share the workspace `build/`, so they are keyed by
    // the module's workspace-relative path — unique across every package in the workspace.
    func modArtifactStem(_ id: ModuleID) -> String {
        id.components.isEmpty ? "root" : id.components.joined(separator: "_")
    }

    // The package identity comes from the manifest (`pkg.json` at the root), or a default when there is
    // none. It anchors mangling and `.nmi` naming (consumed from task 100.2.6 on). A present-but-invalid
    // manifest is fatal.
    let manifest: Manifest?
    do { manifest = try loadManifest(packageRoot: packageRoot) }
    catch { fputs("error: \(error)\n", stderr); return false }
    let packageName = manifest?.name ?? defaultPackageName
    timings.package = packageName
    // A user package may not take a reserved name (`std`, `pkg`); the embedded `nomu` workspace's `std`
    // (a `compilingPrelude` build) is exempt.
    if !options.compilingPrelude, let m = manifest, reservedPackageNames.contains(m.name) {
        fputs("error: " + reservedPackageNameError(m.name, at: packageRoot) + "\n", stderr)
        return false
    }

    // Discover the module graph (task 100.2). The entry module is exactly the given files; a first-party
    // `pkg/…` import pulls in that module by directory scan and parses it too, transitively. External
    // imports await the manifest's dependency aliases (task 100.3), so they add no node here. Lexer and
    // parser share one sink and collect errors (the no-crash contract — frontend/README.md P0); the
    // driver is the exit boundary. Each file is parsed on its own SourceMap, so its module is later
    // recoverable from its span's file.
    let parseDiags = DiagnosticSink()
    var graph = ModuleGraph()
    // A module is kept as its files (task 100.2.3.1), so per-file imports survive rather than being
    // concatenated away. Module-wide passes take the union view (`files.flatMap(\.decls)`).
    var parsedByModule: [ModuleID: [SourceFile]] = [:]
    var seenModule = Set<ModuleID>()
    // Modules reached through a `test import` (modules.md §Tests). Their interfaces are built white-box
    // (internal/package exposed), so the test module reaches its target's non-public API. Any module not in
    // this set keeps its public-only interface, so the same target stays black-box to a plain importer.
    var testImportTargets = Set<ModuleID>()
    var totalBytes = 0, tokenCount = 0

    // Each discovered module's home (task 187.3): the package it lives in — anchoring `pkg/…` resolution
    // and carrying that package's cross-package dependency allow-list and name (for the `.nmi` identity and
    // the package-level DAG check).
    // `workspaceName`/`workspaceRoot` are the owning workspace's identity + root (task 188): for an
    // in-workspace module they are the build's own (every local module shares them); a module pulled in from
    // an external workspace carries *that* workspace's name and root, so its canonical identity mangles under
    // the producer's name and its path is measured from the producer's root.
    struct ModuleHome {
        let packageRoot: String; let packageName: String; let declaredDeps: [String]
        let workspaceName: String; let workspaceRoot: String
        // An external-workspace module (task 188): its graph `id` is already the full canonical path
        // (`[workspaceName] + relative`), so `mangleOrigin` uses it verbatim rather than prefixing the local
        // name, and the driver loads its interface/object from disk instead of compiling its source.
        var isExternal = false
    }
    var moduleHome: [ModuleID: ModuleHome] = [:]

    // Manifests, cached per package root (the entry's is already loaded). The in-workspace package registry
    // (task 187.2) is built once, lazily — only a cross-package import needs it, so a single-package build
    // never scans the tree. A duplicate package name surfaces as a resolution error on the first
    // `.package_` import.
    var manifestCache: [String: Manifest?] = [packageRoot: manifest]
    func manifestFor(_ pkgRoot: String) -> Manifest? {
        if let m = manifestCache[pkgRoot] { return m }
        let m = (try? loadManifest(packageRoot: pkgRoot)) ?? nil
        manifestCache[pkgRoot] = m
        return m
    }
    var packageRegistry: [String: String]? = nil
    var registryError: String? = nil
    func workspaceRegistry() -> [String: String]? {
        if let r = packageRegistry { return r }
        if registryError != nil { return nil }
        do {
            let r = try scanWorkspacePackages(workspaceRoot: wsRootPath)
            // A workspace package with a reserved name (`std`, `pkg`) fails the scan, the same as a duplicate.
            if let bad = r.keys.sorted().first(where: { reservedPackageNames.contains($0) }) {
                registryError = reservedPackageNameError(bad, at: r[bad]!); return nil
            }
            packageRegistry = r; return r
        }
        catch { registryError = "\(error)"; return nil }
    }

    // Local-path external-workspace pins from this workspace's `nomu.yaml` (task 188): external workspace
    // name → absolute root. A `.external` package import (declared but not in-workspace) resolves against the
    // packages these workspaces provide.
    let externalPins = readWorkspaceExternals(wsRootPath)
    // Each pinned external workspace's package registry (package name → package dir), scanned lazily + once.
    var externalRegistries: [String: [String: String]] = [:]
    func externalRegistry(_ extRoot: String) -> [String: String] {
        if let r = externalRegistries[extRoot] { return r }
        let r = (try? scanWorkspacePackages(workspaceRoot: extRoot)) ?? [:]
        externalRegistries[extRoot] = r
        return r
    }
    // External modules a build references (task 188): discovered here, then built + loaded from their
    // producer workspace's outputs in a pass after discovery (their interface tables are declared there). The
    // graph `id` is the full canonical path; `dir` the module's source dir in the producer; `ext` its owning
    // workspace.
    var externalModules: [(id: ModuleID, dir: String, ext: ExternalWorkspace)] = []
    var externalObjects: [String] = []
    // Modules whose public surface is ambient — visible in every module without an explicit import (task
    // 174.2). The embedded `nomu/core` package goes here, so prelude types/functions resolve bare. Populated
    // when the `nomu` workspace is loaded below; empty for a prelude/library build.
    var ambientModules: [ModuleID] = []

    // The inter-package dependency edges actually exercised (importer package → imported packages). The
    // package graph must be a DAG — a rule stronger than the module-import-acyclicity check (task 187.3):
    // `P` → `Q` → `P` is an error even when no single module cycle exists.
    var pkgDeps: [String: Set<String>] = [:]

    let buildRoot = workspaceRoot.appendingPathComponent("build").path
    // The embedded `nomu` workspace (task 174) is materialized before discovery for a final binary build (not a
    // library/prelude build), so discovery resolves `std` imports against it — the implicit `import std` every
    // file carries included. Its packages compile after discovery, below.
    var nomuScratch: String? = nil
    if !options.emitLibrary {
        let scratch = buildRoot + "/nomu/ws-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ..< .max))"
        nomuScratch = scratch
        guard materializeNomuWorkspace(inDir: scratch) else {
            try? FileManager.default.removeItem(atPath: scratch); return false
        }
    }
    defer { if let s = nomuScratch { try? FileManager.default.removeItem(atPath: s) } }

    // A resolved import's owning external workspace (task 188): nil for an in-workspace target. Carries the
    // producer workspace's name + root so the consumer mangles the reference under the producer's identity
    // and reads its artifacts from the producer's build tree.
    struct ExternalWorkspace { let name: String; let root: String }
    // Resolve one import from a module in `home` to its target module. A `pkg/…` import stays in the
    // importer's own package; a bare-package import resolves in-workspace (task 187.2) or, failing that, to a
    // pinned external workspace (task 188) — both enforcing the strict allow-list + product gate. `id` is the
    // target's graph identity (for an external target, its full canonical path under the producer's workspace
    // name, so it never collides with a local module and mangles identically to the producer). `crossPackage`
    // names the imported package, for the package edge; `external` is set when the target lives in a pinned
    // external workspace.
    enum ImportResolve {
        case ok(id: ModuleID, dir: String, packageRoot: String, crossPackage: String?, external: ExternalWorkspace?)
        case failed(String)
    }
    func resolveImport(_ imp: ImportDecl, from home: ModuleHome) -> ImportResolve {
        switch imp.root {
        case .pkg:
            let dir = ([home.packageRoot] + imp.path).joined(separator: "/")
            return .ok(id: graphID(forDir: dir), dir: dir, packageRoot: home.packageRoot,
                       crossPackage: nil, external: nil)
        case .package_(let name):
            // `std` names the embedded `nomu` workspace's standard library (task 174): bare `import std` is its
            // default module (`prelude`, the module every file imports implicitly) and `import std/<module>`
            // the rest. It needs no `dependencies` entry; a user package may not take the name.
            if name == "std", let nomuRoot = nomuScratch {
                return resolveInExternalWorkspace(extRoot: nomuRoot, package: name, subpath: imp.path)
            }
            // Workspace-alias-qualified external import (task 188.5): when the root token is a `nomu.yaml`
            // external pin key — a local alias for an external workspace — `import <alias>/<package>[/<module>]`
            // names that workspace explicitly, disambiguating a package name two pinned workspaces share. The
            // pin authorizes the reference; the symbol still mangles under the producer's own workspace name
            // (the alias rewrites only the local import root). An alias shadows a same-named in-workspace
            // package — the qualified form is the explicit one.
            if let extRoot = externalPins[name], let pkg = imp.path.first {
                return resolveInExternalWorkspace(extRoot: extRoot, package: pkg, subpath: Array(imp.path.dropFirst()))
            }
            guard let registry = workspaceRegistry() else {
                return .failed(registryError ?? "cannot resolve package '\(name)': no workspace")
            }
            switch resolvePackageImport(package: name, path: imp.path,
                                        declaredDeps: home.declaredDeps, registry: registry) {
            case .module(let dir):
                // Product gate (task 187.4.2; modules.md §Visibility): a cross-package import reaches a
                // module only if it is one of the target package's `products`. Match the imported module's
                // package-relative path against the list ("" is the single-module package's root). Products
                // gate permission, not identity — the path still names the module, the list only admits it.
                let pkgDir = registry[name] ?? home.packageRoot
                let relPath = moduleID(forDir: dir, packageRoot: pkgDir).components.joined(separator: "/")
                guard (manifestFor(pkgDir)?.products ?? []).contains(relPath) else {
                    let shown = relPath.isEmpty ? "(default module)" : relPath
                    return .failed("module '\(shown)' is not a product of package '\(name)' — list it "
                                 + "under 'products' in that package's pkg.json")
                }
                return .ok(id: graphID(forDir: dir), dir: dir, packageRoot: pkgDir,
                           crossPackage: name, external: nil)
            case .notDeclared(let p):
                return .failed("package '\(p)' is not listed in this package's 'dependencies'")
            case .external(let p):
                return resolveExternalImport(package: p, path: imp.path)
            case .noModule(let p):
                let sub = imp.path.isEmpty ? "(default module)" : imp.path.joined(separator: "/")
                return .failed("no module '\(sub)' in package '\(p)'")
            }
        }
    }

    // Resolve a package within a specific pinned external workspace (task 188). The product gate applies
    // across the boundary exactly as in-workspace; the resolved `id` is the module's full canonical path
    // under the *producer's* workspace name (read from its `nomu.yaml`), so it never collides with a local
    // module and mangles identically to the producer's own compile. A bare package name forwards to the
    // package's default/root module.
    func resolveInExternalWorkspace(extRoot: String, package name: String, subpath: [String]) -> ImportResolve {
        guard let pkgDir = externalRegistry(extRoot)[name] else {
            return .failed("external workspace at '\(extRoot)' has no package '\(name)'")
        }
        let moduleDir: String
        if subpath.isEmpty {
            if !scanModuleFiles(pkgDir).isEmpty { moduleDir = pkgDir }                            // single-module package
            else if let def = (try? loadManifest(packageRoot: pkgDir))??.defaultModule { moduleDir = pkgDir + "/" + def }
            else { return .failed("package '\(name)' names no default module to import") }
        } else {
            moduleDir = pkgDir + "/" + subpath.joined(separator: "/")
        }
        guard !scanModuleFiles(moduleDir).isEmpty else {
            return .failed("no module '\(subpath.joined(separator: "/"))' in external package '\(name)'")
        }
        let relPath = moduleID(forDir: moduleDir, packageRoot: pkgDir).components.joined(separator: "/")
        guard (manifestFor(pkgDir)?.products ?? []).contains(relPath) else {
            let shown = relPath.isEmpty ? "(default module)" : relPath
            return .failed("module '\(shown)' is not a product of external package '\(name)' — list it "
                         + "under 'products' in that package's pkg.json")
        }
        let extWsName = readWorkspaceName(extRoot) ?? URL(fileURLWithPath: extRoot).lastPathComponent
        let extID = ModuleID([extWsName] + moduleID(forDir: moduleDir, packageRoot: extRoot).components)
        return .ok(id: extID, dir: moduleDir, packageRoot: pkgDir, crossPackage: name,
                   external: ExternalWorkspace(name: extWsName, root: extRoot))
    }
    // Resolve an unqualified `.external` package (declared in the importer's `pkg.json`, absent from the
    // in-workspace registry) against the pinned workspaces (task 188): the first pinned workspace that
    // provides a package of that name wins. A same-package-name clash across two pinned workspaces is
    // disambiguated by the alias-qualified form (`import <alias>/<package>`, task 188.5) instead.
    func resolveExternalImport(package name: String, path: [String]) -> ImportResolve {
        for (_, extRoot) in externalPins.sorted(by: { $0.key < $1.key }) where externalRegistry(extRoot)[name] != nil {
            return resolveInExternalWorkspace(extRoot: extRoot, package: name, subpath: path)
        }
        return .failed("package '\(name)' is external but no workspace pinned in nomu.yaml provides it")
    }

    let entryID = graphID(forFile: primary)
    seenModule.insert(entryID); graph.addNode(entryID)
    moduleHome[entryID] = ModuleHome(packageRoot: packageRoot, packageName: packageName,
                                     declaredDeps: manifest?.dependencies ?? [],
                                     workspaceName: workspaceName, workspaceRoot: wsRootPath)
    var worklist: [(id: ModuleID, files: [String])] = [(entryID, paths)]
    while !worklist.isEmpty {
        let (modID, files) = worklist.removeFirst()
        let home = moduleHome[modID]
            ?? ModuleHome(packageRoot: packageRoot, packageName: packageName, declaredDeps: [],
                          workspaceName: workspaceName, workspaceRoot: wsRootPath)
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                fputs("error: cannot read '\(file)'\n", stderr)
                return false
            }
            totalBytes += text.utf8.count
            let tokens = timings.measure("parse", "lex") { () -> [Token] in
                var lexer = Lexer(text, file: file, diagnostics: parseDiags)
                return lexer.tokenize()
            }
            tokenCount += tokens.count
            let prog = timings.measure("parse", "parse") { () -> Program in
                var parser = Parser(tokens, diagnostics: parseDiags)
                return parser.parse()
            }
            // The implicit `import std` (task 174): every file of a binary build imports `std`'s default module
            // (the prelude) as if it began with an invisible `import std`. A file that names `std` bare itself
            // (to alias it, say) keeps its own import instead.
            var imports = prog.imports
            if nomuScratch != nil && !imports.contains(where: { imp in
                if case .package_("std") = imp.root { return imp.path.isEmpty } else { return false }
            }) {
                imports.insert(ImportDecl(root: .package_("std"), path: [], alias: nil, isPublic: false, isTest: false,
                                          span: Span(startOffset: 0, endOffset: 0, map: tokens.first?.span.map)),
                               at: 0)
            }
            parsedByModule[modID, default: []].append(SourceFile(path: file, decls: prog.decls, imports: imports))
            for imp in imports {
                switch resolveImport(imp, from: home) {
                case .failed(let msg):
                    parseDiags.error(msg, at: imp.span)
                case .ok(let depID, let dir, let depPkgRoot, let crossPackage, let external):
                    graph.addEdge(from: modID, to: depID)
                    if let crossPackage { pkgDeps[home.packageName, default: []].insert(crossPackage) }
                    // `test import` is same-package only (task 187.4.5): white-box widening into a foreign
                    // package's internals is forbidden — a cross-package import is always black-box, so a
                    // package's encapsulation holds even against a foreign test. A same-package test import
                    // (`pkg/…`, `crossPackage == nil`) grants the white-box target.
                    if imp.isTest {
                        if let crossPackage {
                            parseDiags.error("'test import' may not cross a package boundary — '\(crossPackage)' "
                                + "is a foreign package, always black-box; use a plain 'import'", at: imp.span)
                        } else {
                            testImportTargets.insert(depID)
                        }
                    }
                    // An external-workspace module (task 188) is loaded from the producer's outputs, not
                    // compiled here: record its external home and defer the build + interface load to the
                    // post-discovery pass (the interface tables are declared there). Its source is never
                    // scanned or worklisted.
                    if let external {
                        if seenModule.insert(depID).inserted {
                            moduleHome[depID] = ModuleHome(packageRoot: depPkgRoot,
                                                           packageName: crossPackage ?? defaultPackageName,
                                                           declaredDeps: [], workspaceName: external.name,
                                                           workspaceRoot: external.root, isExternal: true)
                            externalModules.append((id: depID, dir: dir, ext: external))
                        }
                        continue
                    }
                    if seenModule.insert(depID).inserted {
                        let depFiles = scanModuleFiles(dir)
                        if depFiles.isEmpty {
                            parseDiags.error("no module found at '\(imp.path.joined(separator: "/"))'", at: imp.span)
                        } else {
                            let m = manifestFor(depPkgRoot)
                            moduleHome[depID] = ModuleHome(packageRoot: depPkgRoot,
                                                           packageName: m?.name ?? defaultPackageName,
                                                           declaredDeps: m?.dependencies ?? [],
                                                           workspaceName: workspaceName, workspaceRoot: wsRootPath)
                            worklist.append((depID, depFiles))
                        }
                    }
                }
            }
        }
    }

    // Package-level dependency cycle (task 187.3): the inter-package graph must be a DAG.
    if let ring = packageDependencyCycle(pkgDeps) {
        fputs("error: package dependency cycle: " + ring.joined(separator: " → ") + "\n", stderr)
        timings.report()
        return false
    }
    timings.bytes = totalBytes
    timings.tokens = tokenCount
    timings.file = seenModule.count == 1 ? primary : "\(seenModule.count) modules"

    // A module import cycle is fatal (design: acyclic module graph). Reported before merging.
    if case .failure(.cycle(let ring)) = graph.topologicalOrder() {
        fputs("error: module import cycle: " + ring.map(\.pathString).joined(separator: " → ") + "\n", stderr)
        timings.report()
        return false
    }

    // The entry module's raw parse, for the --emit-ast debug view below (the per-module pipeline rebuilds
    // its own program from `parsedByModule`). Modules are never merged into one namespace (separate
    // compilation, task 100.4.2).
    let program = Program(decls: (parsedByModule[entryID] ?? []).flatMap(\.decls),
                          imports: (parsedByModule[entryID] ?? []).flatMap(\.imports))
    // The artifact stem: `-o <path>` gives it explicitly (its parent is created); otherwise it mirrors
    // the primary source's path under the workspace `build/`. All artifacts append an extension to the
    // stem, and the binary is the stem itself.
    let stem: String
    let outputDir: String
    if let out = options.outputPath {
        stem = out
        outputDir = URL(fileURLWithPath: out).deletingLastPathComponent().path
    } else {
        outputDir = outputDirectory(for: input, root: workspaceRoot)
        stem = outputDir + "/" + input.deletingPathExtension().lastPathComponent
    }
    do {
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } catch {
        fputs("error: failed to create output dir '\(outputDir)': \(error)\n", stderr)
        return false
    }

    // AST stage. Emit flags write a build/ artifact and report its path (the "emit"
    // style, like --emit-c) — nothing goes to stdout. --emit-ast writes the raw user
    // parse (pre-prelude); --stop=ast writes it and halts.
    if options.ast || options.stopAt == .ast {
        writeArtifact(dumpAST(program), toFile: stem + ".ast")
    }
    if options.stopAt == .ast {
        if !parseDiags.isEmpty { fputs(parseDiags.render() + "\n", stderr) }
        return true
    }
    // Lex/parse errors are fatal to compilation — the recovered AST has holes, so the
    // later phases would report noise. Report the collected diagnostics and stop here.
    if parseDiags.hasErrors {
        fputs(parseDiags.render() + "\n", stderr)
        timings.report()
        return false
    }

    // Separate compilation (task 100.4.2): compile each dependency in topological order (deps first)
    // to its own object + interface, then compile the entry module against those interfaces, then link.
    // A module sees a dependency only through its serialized interface, never its source.
    let preludeFiles: Set<String> = [EmbeddedSources.preludeName, EmbeddedSources.runtimePreludeName]
    let topo: [ModuleID] = { if case .success(let o) = graph.topologicalOrder() { return o }; return [entryID] }()
    var interfaces: [ModuleID: ModuleInterface] = [:]
    // Each compiled dependency's published per-definition escape summary (task 164.6), keyed per module.
    // Seeds a consumer's escape computation across the import boundary so its own published `.nmi` summary
    // reflects imported non-escaping callees rather than the conservative floor. Filled topologically.
    var depEscape: [ModuleID: [String: EscapeSummary]] = [:]
    var depObjects: [String] = []
    try? FileManager.default.createDirectory(atPath: buildRoot, withIntermediateDirectories: true)

    // Build + load each referenced external workspace (task 188). A producer workspace's products are
    // compiled once into home-qualified library objects (origin = the producer's own workspace name); the
    // consumer loads the imported modules' interfaces from the produced `.nmi` and links all the workspace's
    // objects (`-dead_strip` drops whatever a reference never reaches). The handoff is disk-only. No content
    // cache — task 172's CAS cache subsumes it.
    var builtExternalWorkspaces: [String: [ModuleID: String]] = [:]   // extRoot → (external module id → its `.nmi`)
    func buildExternalWorkspace(_ ext: ExternalWorkspace) -> [ModuleID: String]? {
        if let done = builtExternalWorkspaces[ext.root] { return done }
        var nmiByID: [ModuleID: String] = [:]
        let outDir = ext.root + "/build/__ext_lib"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for (pkgName, pkgDir) in externalRegistry(ext.root).sorted(by: { $0.key < $1.key }) {
            for prod in (manifestFor(pkgDir)?.products ?? []) {
                let prodDir = prod.isEmpty ? pkgDir : pkgDir + "/" + prod
                let files = scanModuleFiles(prodDir)
                if files.isEmpty { continue }
                let extID = ModuleID([ext.name] + moduleID(forDir: prodDir, packageRoot: ext.root).components)
                let stem = outDir + "/" + extID.components.joined(separator: "_")
                var opts = EmitOptions()
                opts.emitLibrary = true
                opts.outputPath = stem
                guard compile(paths: files, options: opts) else {
                    fputs("error: failed to build external workspace '\(ext.name)' package '\(pkgName)'\n", stderr)
                    return nil
                }
                nmiByID[extID] = stem + ".nmi"
                externalObjects.append(stem + ".o")
            }
        }
        // A product that imports a sibling package emits that dependency as a `__mod_*.o` under the external
        // build root; link those too so the external's own cross-package references resolve.
        let extBuild = ext.root + "/build"
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: extBuild)) ?? []).sorted()
        where f.hasPrefix("__mod_") && f.hasSuffix(".o") {
            externalObjects.append(extBuild + "/" + f)
        }
        builtExternalWorkspaces[ext.root] = nmiByID
        return nmiByID
    }
    // The embedded `nomu` workspace (task 174): for a final binary build, compile the materialized `core` /
    // `runtime` / `std` modules once and link every object. `core` and `runtime` load here as compiler-injected
    // external modules (origin `nomu/<pkg>`); `core` is ambient — its substrate (`ManagedBuffer`) is bare-
    // visible in every module. `std`'s modules load through the external-module pass below like any pinned
    // workspace's, for the files that import them (each file's implicit `import std` included); recording them
    // as the workspace's built outputs keeps that pass from rebuilding them. No cache — task 172's CAS cache
    // subsumes it.
    if let scratch = nomuScratch {
        guard let arts = timings.measure("nomu", "workspace", { compileNomuWorkspace(inDir: scratch) }) else {
            timings.report(); return false
        }
        var stdNMI: [ModuleID: String] = [:]
        for a in arts {
            externalObjects.append(a.obj)
            if a.package == "std" { stdNMI[ModuleID(["nomu", "std", a.module])] = a.nmi; continue }
            let id = ModuleID(["nomu", a.package])
            moduleHome[id] = ModuleHome(packageRoot: scratch + "/" + a.package, packageName: a.package,
                                        declaredDeps: [], workspaceName: "nomu", workspaceRoot: scratch,
                                        isExternal: true)
            if let text = try? String(contentsOfFile: a.nmi, encoding: .utf8), let nmi = parseNMI(text) {
                interfaces[id] = nmi.abi
                depEscape[id] = nmi.perf.escape
            }
            if a.package == "core" { ambientModules.append(id) }
        }
        builtExternalWorkspaces[scratch] = stdNMI
    }
    for em in externalModules {
        guard let nmiByID = buildExternalWorkspace(em.ext),
              let nmiPath = nmiByID[em.id],
              let text = try? String(contentsOfFile: nmiPath, encoding: .utf8),
              let nmi = parseNMI(text) else {
            fputs("error: cannot load external module '\(em.id.pathString)' from workspace '\(em.ext.name)'\n", stderr)
            timings.report(); return false
        }
        interfaces[em.id] = nmi.abi
        depEscape[em.id] = nmi.perf.escape
    }

    depObjects = externalObjects   // external objects link into the binary alongside the local dependency objects
    // A module plus everything it re-exports via `public import`, transitively (task 100.2.4).
    // Deterministic order. The unit of "what importing this module brings into scope."
    func reexportClosure(of dep: ModuleID) -> [ModuleID] {
        var seen = Set<ModuleID>()
        var order: [ModuleID] = []
        func walk(_ k: ModuleID) {
            guard seen.insert(k).inserted else { return }
            order.append(k)
            for r in interfaces[k]?.reexports ?? [] { walk(ModuleID(r.modulePath)) }
        }
        walk(dep)
        return order
    }
    // The modules whose public surface is visible to `m`: each direct dependency plus its re-export
    // closure. Deterministic order.
    func visibleModules(of m: ModuleID) -> [ModuleID] {
        var seen = Set<ModuleID>()
        var order: [ModuleID] = []
        // Ambient modules (task 174.2: `nomu/core`) are visible to every module without an import.
        for a in ambientModules where a != m && seen.insert(a).inserted { order.append(a) }
        for dep in graph.dependencies(of: m) {
            for k in reexportClosure(of: dep) where seen.insert(k).inserted { order.append(k) }
        }
        return order
    }
    // Two modules share a package iff they have the same package root (task 187.4.4).
    func sharePackage(_ a: ModuleID, _ b: ModuleID) -> Bool {
        guard let pa = moduleHome[a]?.packageRoot, let pb = moduleHome[b]?.packageRoot else { return a == b }
        return pa == pb
    }
    // The modules `m` reaches through a `test import` (white-box), resolved to graph IDs. Same-package
    // only (task 187.4.5): a cross-package test import (`crossPackage != nil`) grants no white-box access —
    // it is a discovery-time error, and never widens admission here.
    func testImports(of m: ModuleID) -> Set<ModuleID> {
        guard let home = moduleHome[m] else { return [] }
        var out = Set<ModuleID>()
        for f in parsedByModule[m] ?? [] {
            for imp in f.imports where imp.isTest {
                if case .ok(let id, _, _, let crossPackage, _) = resolveImport(imp, from: home), crossPackage == nil {
                    out.insert(id)
                }
            }
        }
        return out
    }
    // Whether consumer `m` admits a producer-`k` declaration of visibility `v` across the module boundary
    // (task 187.4.4). `public` is admitted by anyone; `package` only within the same package; `internal`
    // only by a white-box `test import` of `k` (same-package by construction). An older `.nmi` tags nothing
    // (nil → `public`), so it keeps the pre-tier behavior. `private` never crosses.
    func admits(consumer m: ModuleID, producer k: ModuleID, _ v: Visibility?, testTargets: Set<ModuleID>) -> Bool {
        switch v ?? .public {
        case .public:   return true
        case .package:  return sharePackage(m, k)
        case .internal: return testTargets.contains(k)
        case .private:  return false
        }
    }
    // `k`'s interface filtered to the declarations consumer `m` may admit (task 187.4.4) — the view `m`
    // compiles against. Keeps the pre-tier behavior for a same-package or public import; drops a `package`
    // symbol reached across a package boundary, and an `internal` one not reached through a test import.
    func admittedInterface(_ iface: ModuleInterface, producer k: ModuleID, consumer m: ModuleID) -> ModuleInterface {
        let tt = testImports(of: m)
        func ok(_ v: Visibility?) -> Bool { admits(consumer: m, producer: k, v, testTargets: tt) }
        var out = iface
        out.functions = iface.functions.filter { ok($0.visibility) }
        out.types = iface.types.filter { ok($0.visibility) }
        out.enums = iface.enums.filter { ok($0.visibility) }
        out.interfaces = iface.interfaces.filter { ok($0.visibility) }
        return out
    }
    // The imported generic templates visible to `m` (task 100.5.4): each visible dependency's shipped
    // `.bir` (task 100.5.1), parsed back to NOIR decls. A dependency with no `.bir` (no public generics),
    // or an unreadable / version-stale one, contributes nothing — that import then stays on the erased
    // witness path. Deterministic in `visibleModules` order.
    func importedTemplates(of m: ModuleID) -> [ImportedTemplate] {
        var out: [ImportedTemplate] = []
        for k in visibleModules(of: m) {
            let birPath = buildRoot + "/__mod_" + modArtifactStem(k) + ".bir"
            guard let text = try? String(contentsOfFile: birPath, encoding: .utf8),
                  let decls = parseBIR(text) else { continue }
            let origin = mangleOrigin(k).joined(separator: "/")
            out.append(contentsOf: decls.map { ImportedTemplate(origin: origin, decl: $0) })
        }
        return out
    }
    // The escape-summary seed for compiling `m` (task 164.6): the union of each visible dependency's
    // published per-definition summaries, re-keyed to the call names `m`'s SSA emits for them.
    func externalEscape(of m: ModuleID) -> [String: EscapeSummary] {
        var out: [String: EscapeSummary] = [:]
        for k in visibleModules(of: m) {
            guard let summ = depEscape[k] else { continue }
            out.merge(externalEscapeKeys(summ, origin: mangleOrigin(k).joined(separator: "/"))) { a, _ in a }
        }
        return out
    }
    // The function / type names each currently-known module exports, keyed by module path. Feed per-file
    // resolution + collision handling (tasks 100.2.3.1/100.2.3.2), separately by kind so a name can be
    // resolved as the right kind at a func vs type use site.
    // Filtered to what the module being compiled (`consumer`) may admit from each known module (task
    // 187.4.4), so name resolution never binds to a `package` symbol reached across a package boundary.
    func moduleFuncs(for consumer: ModuleID) -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for (id, iface) in interfaces {
            m[mangleOrigin(id).joined(separator: "/")] = Set(admittedInterface(iface, producer: id, consumer: consumer).functions.map(\.name))
        }
        return m
    }
    func moduleTypes(for consumer: ModuleID) -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for (id, iface) in interfaces {
            let adm = admittedInterface(iface, producer: id, consumer: consumer)
            m[mangleOrigin(id).joined(separator: "/")] = Set(adm.types.map(\.name)).union(adm.enums.map(\.name))
        }
        return m
    }
    // Per-file import scope. Imports are file-scoped (task 100.2.3.1), so a symbol is bare-visible only in
    // a file that imports its origin module. Returns, per file, the module paths it may reference bare
    // (each import plus its re-export closure) and the qualifier bindings for qualified access
    // (task 100.2.3.2), plus any leaf-name collisions (two imports sharing a qualifier in one file).
    func fileScopes(_ files: [SourceFile], home: ModuleHome) -> (fileVisible: [String: Set<String>],
                                               fileQualifiers: [String: [String: Set<String>]],
                                               leafCollisions: [(file: String, leaf: String, span: Span)]) {
        var fileVisible: [String: Set<String>] = [:]
        var fileQualifiers: [String: [String: Set<String>]] = [:]
        var leafCollisions: [(file: String, leaf: String, span: Span)] = []
        for f in files {
            var vis = Set<String>()
            var quals: [String: Set<String>] = [:]
            var seenLeaf = Set<String>()
            for imp in f.imports {
                guard case .ok(let id, _, _, _, _) = resolveImport(imp, from: home) else { continue }
                let closure = reexportClosure(of: id)
                    .map { mangleOrigin($0).joined(separator: "/") }
                vis.formUnion(closure)
                let q = imp.leafName
                if !seenLeaf.insert(q).inserted { leafCollisions.append((f.path, q, imp.span)) }
                quals[q, default: []].formUnion(closure)
            }
            // Ambient modules (task 174.2: `nomu/core`) are bare-visible in every file, no import needed.
            for a in ambientModules { vis.insert(mangleOrigin(a).joined(separator: "/")) }
            fileVisible[f.path] = vis
            fileQualifiers[f.path] = quals
        }
        return (fileVisible, fileQualifiers, leafCollisions)
    }
    // The external declarations visible to `m`, each rewritten to its per-origin identity (`origin@name`,
    // task 100.2.3.2) so two imported modules exporting the same name coexist. Type references inside a
    // module's own decls that name one of its own exported types are rewritten to that encoded identity
    // too, so a function's signature keeps pointing at the right type under a collision.
    func externals(of m: ModuleID) -> [TopDecl] {
        // One module's admitted declarations, origin-encoded: its own types under its origin, and each foreign
        // type its signatures name under that type's origin (`foreignTypes`, task 174.7).
        func decls(of k: ModuleID) -> (decls: [TopDecl], foreign: [String: String]) {
            guard let iface = interfaces[k] else { return ([], [:]) }
            let origin = mangleOrigin(k).joined(separator: "/")
            // Round-trip through the serialized form (the disk handoff a separate compile would read),
            // then admit only the tiers `m` may see (task 187.4.4).
            let seen = admittedInterface(parseInterface(serialize(iface)) ?? iface, producer: k, consumer: m)
            let ownTypes = Set(seen.types.map(\.name)).union(seen.enums.map(\.name))
            let foreign = seen.foreignTypes ?? [:]
            return (interfaceToDecls(seen).map { encodeExternalDecl($0, origin: origin, ownTypes: ownTypes, foreign: foreign) },
                    foreign)
        }
        let visible = visibleModules(of: m)
        var out: [TopDecl] = []
        var pending: [String] = []
        for k in visible {
            let d = decls(of: k)
            out += d.decls
            pending += d.foreign.values.sorted()
        }
        // Types a visible signature names from a module `m` does not import (task 174.7): their declarations
        // load so values of them type-check (fields, methods, matching), but the module stays out of `m`'s
        // scope, so the names stay unnameable in `m` — no implicit re-export (modules.md §Re-export). Only
        // types load, transitively through their own signatures; the hidden module's functions do not.
        let byOrigin = Dictionary(interfaces.keys.map { (mangleOrigin($0).joined(separator: "/"), $0) },
                                  uniquingKeysWith: { a, _ in a })
        var loaded = Set(visible.map { mangleOrigin($0).joined(separator: "/") } + [mangleOrigin(m).joined(separator: "/")])
        while let o = pending.popLast() {
            guard loaded.insert(o).inserted, let k = byOrigin[o] else { continue }
            let d = decls(of: k)
            out += d.decls.filter {
                switch $0 { case .structDecl, .classDecl, .enumDecl: return true; default: return false }
            }
            pending += d.foreign.values.sorted()
        }
        return out
    }
    // The origin of each foreign type `id`'s interface names (task 174.7): a signature type that is not one
    // of the module's own exported types, resolved against the modules its files import. A name exported by
    // more than one of them is left out (it stays bare, as before).
    func foreignTypeOrigins(_ iface: ModuleInterface, of id: ModuleID, fileVisible: [String: Set<String>]) -> [String: String]? {
        let own = Set(iface.types.map(\.name)).union(iface.enums.map(\.name))
        let inScope = fileVisible.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let exports = moduleTypes(for: id)
        var out: [String: String] = [:]
        for n in signatureTypeNames(iface) where !own.contains(n) {
            let origins = inScope.filter { exports[$0]?.contains(n) == true }
            if origins.count == 1, let o = origins.first { out[n] = o }
        }
        return out.isEmpty ? nil : out
    }
    // Imported methods inferred mutating in their producing module, keyed `origin@Type.method` to match
    // the consumer's call-site key (task 100.4.3.5.2). Sourced from each visible dependency's `.nmi`
    // (`InterfaceFunc.isMutating`); drives the consumer's mutable-receiver check + self-by-pointer ABI.
    func externalMutating(of m: ModuleID) -> Set<String> {
        var out: Set<String> = []
        for k in visibleModules(of: m) {
            guard let full = interfaces[k] else { continue }
            let iface = admittedInterface(full, producer: k, consumer: m)
            let origin = mangleOrigin(k).joined(separator: "/")
            func add(_ typeName: String, _ methods: [InterfaceFunc], _ properties: [InterfaceProperty]) {
                let key = ExternalName.encode(origin: origin, name: typeName)
                for mth in methods where mth.isMutating == true && !mth.isStatic {
                    out.insert("\(key).\(mth.name)")
                }
                // A computed property's accessors lower to `p.get` / `p.set` methods (task 100.4.3.5.4); a
                // mutating accessor (a setter that writes a stored field) needs the same self-by-pointer ABI
                // as a mutating method, so key it the same way the call site does.
                for p in properties {
                    if p.getterMutating == true { out.insert("\(key).\(p.name).get") }
                    if p.setterMutating == true { out.insert("\(key).\(p.name).set") }
                }
            }
            for t in iface.types { add(t.name, t.methods, t.properties) }
            for e in iface.enums { add(e.name, e.methods, e.properties) }
        }
        return out
    }
    // Compile one module through the full pipeline. The only fork is binary vs library (`isRoot`): the
    // root is the invocation target — it owns the program-wide GC type maps + unqualified symbols and
    // links an executable; a dependency emits a home-qualified object + its interface. Everything else —
    // prelude, checks, sema, interface, `.bir` shipping, specialization injection, mono, inference — runs
    // the same for every module. Dependencies are compiled first (topological order), so their interfaces
    // and `.bir` exist when a dependent reads them. Returns false on a fatal diagnostic (the caller exits).
    func compileModule(_ id: ModuleID, isRoot: Bool) -> Bool {
        let files = parsedByModule[id] ?? []
        var program = Program(decls: files.flatMap(\.decls), imports: files.flatMap(\.imports))
        // The pre-prelude, pre-merge surface — the interface + `.bir` own-name set are taken from it.
        let ownSurface = program
        let home = moduleHome[id]
            ?? ModuleHome(packageRoot: packageRoot, packageName: packageName, declaredDeps: [],
                          workspaceName: workspaceName, workspaceRoot: wsRootPath)
        let scopes = fileScopes(files, home: home)

        // Duplicate-symbol / visibility / leaf-collision checks (tasks 100.1.3 / 100.2.5), before the
        // prelude is prepended so they see only the module's own declarations. `isProduct` decides whether
        // this module may carry `public` (task 187.4.3): its package-relative path must be in its package's
        // `products`.
        let isProduct: Bool = {
            guard let f = files.first else { return false }
            let rel = moduleID(forFile: f.path, packageRoot: home.packageRoot).components.joined(separator: "/")
            return (manifestFor(home.packageRoot)?.products ?? []).contains(rel)
        }()
        let dupDiags = DiagnosticSink()
        timings.measure("noir", "duplicates") { checkDuplicates(program, into: dupDiags) }
        checkVisibilityConsistency(program, into: dupDiags, isProduct: isProduct)
        reportLeafCollisions(scopes.leafCollisions, into: dupDiags)
        if dupDiags.hasErrors { fputs(dupDiags.render() + "\n", stderr); return false }

        // Plain-extension merge (M4.12). The prelude prepend is fully retired (task 174.5/.5.1): the runtime
        // lives in the `runtime` package (referenced by bare symbol), the user-facing surface in `std`, and
        // `core`'s `ManagedBuffer` is an ambient `nomu/core` package type while its `EmptyHeader` header is a
        // compiler builtin (seeded in the egress). Nothing is prepended into an ordinary build.
        let runtimeSubsetNames: Set<String>
        if options.compilingPrelude {
            // The `runtime` package designates its own functions runtime-subset by membership (task 174.4):
            // every free function it defines is subset, sourced from the package rather than a prepend parse.
            runtimeSubsetNames = options.runtimeSubsetByMembership
                ? Set(program.decls.compactMap { if case .funcDecl(let f) = $0 { return f.name } else { return nil } })
                : []
        } else {
            // White-box runtime tests (`NOMU_RT_PRELUDE`) prepend the runtime prelude so a user fixture can
            // call runtime internals (`rtArenaNew`, the Immix ops) by name — the access the retired runtime
            // prepend used to give every build. The definitions are bare weak-ODR, so they fold with the
            // `runtime` package's own copies; no production build sets this.
            if ProcessInfo.processInfo.environment["NOMU_RT_PRELUDE"] != nil {
                (program, runtimeSubsetNames) = timings.measure("noir", "prelude") { prependRuntimePrelude(program) }
            } else {
                runtimeSubsetNames = []
            }
        }
        let mergeDiags = DiagnosticSink()
        program = timings.measure("noir", "merge") { mergeExtensions(program, into: mergeDiags) }
        if mergeDiags.hasErrors { fputs(mergeDiags.render() + "\n", stderr); return false }

        // Typecheck (POD + let/var, T2 §4).
        let typeDiags = DiagnosticSink()
        timings.measure("noir", "typecheck") { var checker = Typechecker(program, diagnostics: typeDiags); checker.check() }
        if typeDiags.hasErrors { fputs(typeDiags.render() + "\n", stderr); return false }

        // Semantic pass → typed NOIR (+ exhaustiveness, T4).
        let subset = options.subsetFuncs.union(runtimeSubsetNames)
        let semaResult = timings.measure("noir", "sema") { () -> SemaResult in
            var sema = Sema(program, externalDecls: externals(of: id), subsetFuncs: subset,
                            fileVisibleModules: scopes.fileVisible, fileQualifiers: scopes.fileQualifiers,
                            moduleFuncs: moduleFuncs(for: id), moduleTypes: moduleTypes(for: id),
                            externalMutatingMethods: externalMutating(of: id))
            let result = sema.check()
            checkExhaustiveness(result.module, into: result.diagnostics)
            return result
        }

        // NOIR debug view (root only): --emit-noir writes it; --stop=noir writes it and halts (reporting
        // diagnostics without failing — a debug view).
        if isRoot && (options.noir || options.stopAt == .noir) {
            writeArtifact(dumpNOIR(semaResult.module), toFile: stem + ".noir")
        }
        if isRoot && options.stopAt == .noir {
            if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr) }
            return true
        }
        // Proceeding to codegen: semantic errors are now fatal.
        if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr); return false }

        // Sema's structural facts (mutating-ness; task 164.1) into the shared store — read by the `.nmi`
        // emit (164.4) and the codegen promotion interposition (164.2/164.5).
        let factStore = collectFacts(semaResult.module)

        // Module interface — built for every module (dependents read it from `interfaces`), from the
        // pre-prelude surface, carrying the inferred facts (164.4). Its escape perf section is computed
        // only when a `.nmi` is wanted (164.6 seeding).
        var iface = buildInterface(ownSurface, package: home.packageName, module: id, moduleIDRoot: wsRootPath,
                                   workspace: workspaceName,
                                   facts: factStore, whiteBox: testImportTargets.contains(id),
                                   reexportModulePath: { imp in
                                       guard case .ok(let rid, _, _, _, _) = resolveImport(imp, from: home) else { return nil }
                                       return rid.components
                                   })
        iface.foreignTypes = foreignTypeOrigins(iface, of: id, fileVisible: scopes.fileVisible)
        let ownEscape = options.nmi
            ? escapePerfSection(iface, semaResult.module, subsetFuncs: subset, external: externalEscape(of: id)).escape
            : [:]
        interfaces[id] = iface
        depEscape[id] = ownEscape

        // `.nmi` emission — the library interface. `--emit-nmi` on the root is terminal (no codegen/link);
        // a module need not have an entry point to publish its interface.
        if isRoot && options.nmi {
            let perf = escapePerfSection(iface, semaResult.module, subsetFuncs: subset, external: externalEscape(of: id))
            writeArtifact(serialize(iface, perf: perf), toFile: stem + ".nmi")
            return true
        }

        // Object path: the root is the binary's stem object; a dependency is a qualified `__mod_*` object.
        let objPath = isRoot
            ? stem + ".o"
            : buildRoot + "/__mod_" + modArtifactStem(id) + ".o"

        // External-workspace build (task 188): publish the entry module's `.nmi` beside its library object so
        // a consumer in another workspace reads the interface from disk (the producer→consumer handoff is
        // disk-only — `.nmi` / `.bir` / `.o`). Non-terminal, unlike `--emit-nmi`; codegen still follows. The
        // perf section carries the escape summaries so the consumer seeds across the boundary (164.6).
        if options.emitLibrary && isRoot {
            let perf = escapePerfSection(iface, semaResult.module, subsetFuncs: subset, external: externalEscape(of: id))
            try? serialize(iface, perf: perf).write(toFile: stem + ".nmi", atomically: true, encoding: .utf8)
        }

        // Ship this module's `.bir` (public generic closure, references canonicalized to origin-keyed
        // names) so a dependent under `--mono` specializes the generics it imports (tasks 100.5.1 / 100.5.4).
        let ownNames = topDeclNames(ownSurface)
        let shipped = canonicalizeForExport(shippedTemplates(semaResult.module, ownNames: ownNames),
                                            origin: mangleOrigin(id).joined(separator: "/"), ownNames: ownNames)
        if !shipped.isEmpty {
            let birPath = objPath.hasSuffix(".o") ? String(objPath.dropLast(2)) + ".bir" : objPath + ".bir"
            try? serializeBIR(shipped).write(toFile: birPath, atomically: true, encoding: .utf8)
        }

        // Cross-module specialization (tasks 100.5.2 / 100.5.4): under `--mono != none`, inject the generic
        // templates each visible dependency shipped in its `.bir` so the monomorphizer specializes the
        // instances this module uses — recovering whole-program-mono performance across the boundary. This
        // runs for every module, so a dependency specializes its own imports too. `none` injects nothing
        // (erased witness path). A name specialized locally is dropped from the external sets so its call
        // sites bind to the local specialization, not the erased import.
        var moduleForMono = semaResult.module
        var localizedGenerics: Set<String> = []
        if options.effectiveMono != .none {
            let selected = selectForDial(importedTemplates(of: id), mode: options.effectiveMono, consumer: moduleForMono)
            let injection = injectImportedTemplates(into: moduleForMono, templates: selected)
            moduleForMono = injection.module
            localizedGenerics = injection.localizedNames
        }

        // Monomorphization (M5 5.4): specialize each instantiation into concrete decls; `any I` stays dynamic.
        let monoDiags = DiagnosticSink()
        let monoModule = timings.measure("noir", "mono") { monomorphize(moduleForMono, into: monoDiags) }
        if !monoDiags.isEmpty { fputs(monoDiags.render() + "\n", stderr); return false }

        // SSAIR debug view (root only): --emit-ssair writes it; --stop=ssair writes it and halts.
        if isRoot && (options.ssair || options.stopAt == .ssair) {
            let ssa = timings.measure("ssair", "gen") { lowerToSSAIR(monoModule) }
            writeArtifact(dumpSSAIR(ssa.module), toFile: stem + ".ssair")
            if options.stopAt == .ssair {
                if !ssa.diagnostics.isEmpty { fputs(ssa.diagnostics.render() + "\n", stderr) }
                return true
            }
        }

        let extFuncs = semaResult.externalFuncNames.subtracting(localizedGenerics)
        let extGenerics = semaResult.externalGenericSigs.filter { !localizedGenerics.contains($0.key) }

        // Backend (M8). The root goes through the binary path (object + runtime link); a dependency emits a
        // home-qualified object only (no entry point, no program-wide type maps). An external-workspace build
        // (task 188; the embedded `nomu` workspace included) emits even its entry module as a library object
        // — it has no `main` and is linked into a consumer, not run — so it falls through to the dependency
        // path below.
        if isRoot && !options.emitLibrary {
            emitLLVMBinary(monoModule, stem: stem, buildRoot: buildRoot, optimize: options.optimize,
                           subsetFuncs: subset, timings: timings,
                           emitLLVM: options.llvm || options.stopAt == .llvm, stopAfterLLVM: options.stopAt == .llvm,
                           extraObjects: depObjects, externalFuncNames: extFuncs, externalGenericSigs: extGenerics,
                           weakOriginFiles: preludeFiles, facts: factStore)
            return true
        }
        // Dependency object: gen SSAIR → inference (promotion) → emit, qualified + interface-invisible.
        let gen = timings.measure("ssair", "gen") { lowerToSSAIR(monoModule, subsetFuncs: subset) }
        if gen.diagnostics.hasErrors { fputs("error: SSAIR: " + gen.diagnostics.render() + "\n", stderr); return false }
        var store = factStore
        timings.measure("ssair", "inference") {
            let summaries = computeEscapeSummaries(gen.module.functions, aggregates: gen.module.aggregates)
            writeEscapeSummaries(summaries, into: &store)
        }
        // The `runtime` package is the C-ABI boundary (task 174.5): the C floor and codegen reference its
        // functions by bare mangled name (`nomu_fn_rt…`, Inventory B), so the package emits them **bare** and
        // weak-ODR — the single definitions the prepend used to supply in every object, now compiled once.
        // (`runtime.nomu` goes in the weak-origin set for its own package build.) A user build no longer
        // prepends the runtime (174.5 retired it), so `preludeFiles` here only matters for the core substrate
        // it still prepends — types, no function symbols — making the set inert for naming/linkage there.
        let weakOrigins: Set<String>
        if options.compilingPrelude {
            // The `runtime` package emits its own functions bare + weak-ODR (its source files are the
            // weak-origin set — keyed by their materialized path, which is what their spans carry).
            weakOrigins = options.runtimeSubsetByMembership ? Set(files.map(\.path)) : []
        } else {
            weakOrigins = preludeFiles
        }
        let err = emitObject(gen.module, from: monoModule, to: objPath, optimize: options.optimize,
                             onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                             requireMain: false, externalFuncNames: extFuncs, externalGenericSigs: extGenerics,
                             weakOriginFiles: weakOrigins, emitTypeMaps: false,
                             homeQualifier: Mangle.qualifier(module: mangleOrigin(id)), facts: store)
        if let err = err { fputs("error: \(err)\n", stderr); return false }
        depObjects.append(objPath)
        return true
    }

    // Compile every module in dependency order (leaves first); the entry module — the binary — is last and
    // links. Separate compilation (task 100.4.2): a module sees a dependency only through its interface. An
    // external-workspace module (task 188) is skipped — already built in its producer workspace and loaded
    // from its `.nmi`/`.o` above, never recompiled from source here.
    for m in topo where moduleHome[m]?.isExternal != true {
        guard compileModule(m, isRoot: m == entryID) else { timings.report(); return false }
    }
    timings.report()
    return true
}

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

// Resolve a target directory to a single module, or nil (with a diagnostic) if it is not a directory, names
// a container package with no `default-module`, or holds no `.nomu` source.
public func resolveModule(path rawPath: String) -> ResolvedModule? {
    let fm = FileManager.default
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        fputs("error: target '\(rawPath)' is not a directory\n", stderr)
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
public func buildTarget(path rawPath: String, options: EmitOptions = EmitOptions()) -> String? {
    guard let m = resolveModule(path: rawPath) else { return nil }
    return buildResolved(m, options: options)
}

// Build an already-resolved module and return its binary path. Names the binary after the module (its leaf
// directory) rather than the entry file — every module's entry is `main.nomu`, so the file-derived default
// would name every binary `main`. Places it under the package's `build/` tree mirroring the module path.
// (An explicit `-o` still wins.)
public func buildResolved(_ m: ResolvedModule, options: EmitOptions = EmitOptions()) -> String? {
    var options = options
    if options.outputPath == nil {
        // Anchor the binary under the **workspace** `build/` (the `nomu.yaml` root), at the module's own
        // path within the workspace — so every package shares one build tree and the binary is named after
        // the module (its directory's last component), with its sibling artifacts (`.o`/`.ll`/…) alongside.
        // (No workspace marker → the package is its own build root.)
        let workspaceRoot = findWorkspaceRoot(for: URL(fileURLWithPath: m.dir + "/_")).path
        var rel = m.dir.hasPrefix(workspaceRoot) ? String(m.dir.dropFirst(workspaceRoot.count)) : ""
        while rel.hasPrefix("/") { rel.removeFirst() }
        let leaf = URL(fileURLWithPath: m.dir).lastPathComponent
        options.outputPath = rel.isEmpty ? workspaceRoot + "/build/" + leaf
                                         : workspaceRoot + "/build/" + rel
    }
    return compile(paths: scanModuleFiles(m.dir), options: options) ? options.outputPath : nil
}

// `nomu run <path> [-- args]` (task 173.5.3): build the target module, then exec the produced binary,
// forwarding `args` and propagating its exit status. A module without a `main` is not executable — its
// build fails, which surfaces here as a non-zero exit. Returns the process exit code.
public func runTarget(path: String, args: [String], options: EmitOptions = EmitOptions()) -> Int32 {
    guard let binary = buildTarget(path: path, options: options) else { return 1 }
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
public func testPackage(target rawPath: String, options: EmitOptions = EmitOptions()) -> Bool {
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

    let label = m.id.components.isEmpty ? "(root)" : m.id.pathString
    guard let binary = buildResolved(m, options: options) else {
        fputs("FAIL  \(label) — build failed\n", stderr)
        return false
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: binary)
    do { try proc.run() } catch {
        fputs("FAIL  \(label) — cannot run '\(binary)': \(error)\n", stderr)
        return false
    }
    proc.waitUntilExit()
    if proc.terminationStatus == 0 {
        fputs("ok    \(label)\n", stderr)
        return true
    }
    fputs("FAIL  \(label) — exit \(proc.terminationStatus)\n", stderr)
    return false
}

// The module identity named by a manifest `tests`/`bin` entry: a package-root-relative, `/`-separated path,
// with "" naming the package's root module.
private func testModuleID(_ rel: String) -> ModuleID {
    rel.isEmpty ? ModuleID([]) : ModuleID(rel.split(separator: "/").map(String.init))
}

// `nomu query [target]` (task 173.6): print the package metadata rooted at a target module — the package
// identity plus the first-party module graph reachable from it (its modules, the importer→imported
// dependency edges, and any referenced external packages). Parse-only: it walks `pkg/…` imports exactly as
// `compile` discovers them, without compiling. Emits JSON on stdout for tooling (task 137 reasons over this
// graph). Resolution is the shared single-module resolver, so a path names the same module here as to
// `build`/`run`/`test`, and the graph is what that module reaches. A package-wide query over every module
// on disk (independent of reachability) waits on the label surface, with the rest of multi-module targeting.
public func queryPackage(target rawPath: String) -> Bool {
    guard let entry = resolveModule(path: rawPath) else { return false }
    let packageRoot = entry.packageRoot
    let packageName = ((try? loadManifest(packageRoot: packageRoot)) ?? nil)?.name ?? defaultPackageName

    // The graph spans packages (task 187.3), so module identity is workspace-relative — a `.package_`
    // import to an in-workspace package is followed as a real edge, mirroring `compile`'s discovery. A
    // declared package that is not in-workspace (an external), or one not listed in `dependencies`, stays
    // in `externals` rather than being walked.
    let wsRootPath = findWorkspaceRoot(for: URL(fileURLWithPath: entry.dir + "/_")).path
    func gid(forDir dir: String) -> ModuleID { moduleID(forDir: dir, packageRoot: wsRootPath) }
    let registry = (try? scanWorkspacePackages(workspaceRoot: wsRootPath)) ?? [:]
    func depsOf(_ pkgRoot: String) -> [String] { (((try? loadManifest(packageRoot: pkgRoot)) ?? nil)?.dependencies) ?? [] }

    var graph = ModuleGraph()
    var seen = Set<ModuleID>()
    var externals = Set<String>()
    let diags = DiagnosticSink()
    let entryGID = gid(forDir: entry.dir)
    graph.addNode(entryGID); seen.insert(entryGID)
    var worklist: [(id: ModuleID, pkgRoot: String, files: [String])] = [(entryGID, packageRoot, scanModuleFiles(entry.dir))]
    while !worklist.isEmpty {
        let (modID, pkgRoot, files) = worklist.removeFirst()
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            var lexer = Lexer(text, file: file, diagnostics: diags)
            var parser = Parser(lexer.tokenize(), diagnostics: diags)
            for imp in parser.parse().imports {
                let dir: String
                let depPkgRoot: String
                switch imp.root {
                case .pkg:
                    dir = ([pkgRoot] + imp.path).joined(separator: "/"); depPkgRoot = pkgRoot
                case .package_(let name):
                    switch resolvePackageImport(package: name, path: imp.path,
                                                declaredDeps: depsOf(pkgRoot), registry: registry) {
                    case .module(let d): dir = d; depPkgRoot = registry[name] ?? pkgRoot
                    default: externals.insert(name); continue
                    }
                }
                let depID = gid(forDir: dir)
                graph.addEdge(from: modID, to: depID)
                if seen.insert(depID).inserted {
                    let depFiles = scanModuleFiles(dir)
                    if !depFiles.isEmpty { worklist.append((depID, depPkgRoot, depFiles)) }
                }
            }
        }
    }

    // Module paths are workspace-root-relative, `/`-separated; the empty string names the root module.
    func pathOf(_ id: ModuleID) -> String { id.components.joined(separator: "/") }
    let ordered = seen.sorted { pathOf($0) < pathOf($1) }
    let edges = ordered.flatMap { from in
        graph.dependencies(of: from).map { QueryDep(from: pathOf(from), to: pathOf($0)) }
    }
    let out = QueryOutput(package: packageName, root: packageRoot, entry: pathOf(entryGID),
                          modules: ordered.map(pathOf), dependencies: edges, externals: externals.sorted())
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
    let package: String        // the package identity (manifest `name`, or the default)
    let root: String           // the package root directory (nearest `pkg.json` ancestor)
    let entry: String          // the queried module's path ("" = the root module)
    let modules: [String]      // every first-party module reachable from the entry
    let dependencies: [QueryDep]
    let externals: [String]    // external package names referenced (unresolved until cross-package linkage)
}
private struct QueryDep: Codable { let from: String; let to: String }

// The `.nmi` perf section (task 164.4.3): the per-definition escape summary of each exported definition.
// Computed over the module's **erased/template** bodies — the pre-mono SSA — so each definition is
// summarized once (the cross-module form a dependent reads, 164.6), distinct from the per-instance
// post-mono summary the promotion path consumes (164.2/164.5). The summary is re-keyed to the per-
// definition convention and projected onto the public surface, so only an exported definition carries
// one (no private symbol leaks, and the key matches the ABI facts). Best-effort: a body that fails to
// lower pre-mono simply carries no summary (read as "unknown", the conservative floor); lowering
// diagnostics are intentionally dropped — a valid interface's facts are advisory, never fatal here.
private func escapePerfSection(_ iface: ModuleInterface, _ module: NOIRModule,
                               subsetFuncs: Set<String>,
                               external: [String: EscapeSummary] = [:]) -> InterfacePerf {
    let gen = lowerToSSAIR(module, subsetFuncs: subsetFuncs)
    let perDef = perDefinitionEscapeSummaries(
        computeEscapeSummaries(gen.module.functions, aggregates: gen.module.aggregates, external: external))

    var surface = Set(iface.functions.map(\.name))
    for t in iface.types { for m in t.methods { surface.insert("\(t.name).\(m.name)") } }
    for e in iface.enums { for m in e.methods { surface.insert("\(e.name).\(m.name)") } }
    return InterfacePerf(escape: perDef.filter { surface.contains($0.key) })
}

// Re-key a dependency's published per-definition escape summaries to the call names an importer uses for
// them (task 164.6), so a consumer's escape computation finds the summary at the `.direct(name)` its SSA
// emits for an imported call: a free function `foo` → `origin@foo`, a method `Type.method` →
// `m:origin@Type:method` (mirrors `ExternalName.encode` + ssairgen's method symbol). The importer seeds
// `computeEscapeSummaries(external:)` with the union of these over its visible dependencies.
private func externalEscapeKeys(_ perDef: [String: EscapeSummary], origin: String) -> [String: EscapeSummary] {
    var out: [String: EscapeSummary] = [:]
    for (key, s) in perDef {
        if let dot = key.firstIndex(of: ".") {   // `Type.method` — a method on an imported type
            let type = String(key[..<dot]), method = String(key[key.index(after: dot)...])
            out[ssaMethodSymbol(ExternalName.encode(origin: origin, name: type), method)] = s
        } else {                                 // a bare free-function name
            out[ExternalName.encode(origin: origin, name: key)] = s
        }
    }
    return out
}

// Write a text artifact to `path` (or exit) and report its path to stderr — the "emit" style,
// consistent with --emit-c: outputs are build/ files, and the path report is a diagnostic (stderr), so
// stdout stays clean for a program's own output under `nomu run`.
private func writeArtifact(_ contents: String, toFile path: String) {
    guard (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write '\(path)'\n", stderr)
        exit(1)
    }
    fputs(path + "\n", stderr)
}

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

// The workspace root (modules.md §Manifest): the nearest ancestor of `input` carrying the `nomu.yaml`
// workspace marker — the unit the `build/` tree is anchored to, so every package in a workspace shares one
// build tree (nested workspaces resolve to the nearest marker). With no workspace marker anywhere, a loose
// package is its own build root (`findPackageRoot`).
private func findWorkspaceRoot(for input: URL) -> URL {
    let fm = FileManager.default
    var dir = input.deletingLastPathComponent().standardizedFileURL
    while true {
        if fm.fileExists(atPath: dir.appendingPathComponent("nomu.yaml").path) { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }   // reached the filesystem root
        dir = parent
    }
    return findPackageRoot(for: input)
}

// The workspace name (task 187.3 / 187.5): the `name:` field of the workspace's `nomu.yaml`. A minimal
// line scan — full YAML is task 163 — tolerant of surrounding whitespace and optional quotes; returns nil
// when there is no marker or no `name:`, so the caller can fall back to the directory name. The first
// segment of every library symbol's canonical identity, so it must be stable across a workspace's builds.
private func readWorkspaceName(_ workspaceRoot: String) -> String? {
    guard let text = try? String(contentsOfFile: workspaceRoot + "/nomu.yaml", encoding: .utf8) else { return nil }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("name:") else { continue }
        var value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    return nil
}

// Local-path external-workspace pins (task 188): a workspace's `nomu.yaml` names each external workspace it
// consumes and the local filesystem path it lives at. The real schema rides YAML (task 163); until then a
// minimal block reader — an `externals:` line, then indented `  <name>: <path>` entries, one per external,
// closed by the next non-indented line. A relative path resolves against the workspace root; the result maps
// the external's own `name` (the root token an `import <name>/…` uses) to its absolute workspace root. No
// version/source — a local path is a single already-present workspace (remote sources are task 189).
private func readWorkspaceExternals(_ workspaceRoot: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: workspaceRoot + "/nomu.yaml", encoding: .utf8) else { return [:] }
    var pins: [String: String] = [:]
    var inBlock = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let indented = raw.first == " " || raw.first == "\t"
        if !indented {
            inBlock = (trimmed == "externals:")   // a new top-level key ends any prior block
            continue
        }
        guard inBlock, let colon = trimmed.firstIndex(of: ":") else { continue }
        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        var path = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        if name.isEmpty || path.isEmpty { continue }
        let abs = (path as NSString).isAbsolutePath
            ? path
            : URL(fileURLWithPath: workspaceRoot).appendingPathComponent(path).standardizedFileURL.path
        pins[name] = abs
    }
    return pins
}

// A cycle in the inter-package dependency graph (task 187.3), importer→imported order closing on the
// first, or nil if the graph is a DAG. Distinct from the module-import-cycle check: a package cycle is an
// error even when no single module cycle exists. Deterministic (keys and successors visited sorted).
private func packageDependencyCycle(_ deps: [String: Set<String>]) -> [String]? {
    var state: [String: Int] = [:]   // 1 = on the current path, 2 = finished
    var path: [String] = []
    func visit(_ n: String) -> [String]? {
        if state[n] == 2 { return nil }
        if state[n] == 1 { let start = path.firstIndex(of: n) ?? 0; return Array(path[start...]) + [n] }
        state[n] = 1; path.append(n)
        for m in (deps[n] ?? []).sorted() { if let ring = visit(m) { return ring } }
        path.removeLast(); state[n] = 2
        return nil
    }
    for n in deps.keys.sorted() { if let ring = visit(n) { return ring } }
    return nil
}

// <root>/build/<input's directory relative to root>. Equal dirs yield <root>/build.
private func outputDirectory(for input: URL, root: URL) -> String {
    let inputDir = input.deletingLastPathComponent().standardizedFileURL.path
    var rel = inputDir.hasPrefix(root.path) ? String(inputDir.dropFirst(root.path.count)) : ""
    while rel.hasPrefix("/") { rel.removeFirst() }
    let build = root.appendingPathComponent("build").path
    return rel.isEmpty ? build : build + "/" + rel
}

// Lex + parse an embedded prelude source (trusted — a diagnostic here is a compiler bug).
private func parseEmbeddedPrelude(_ source: String, _ name: String) -> Program {
    let diags = DiagnosticSink()
    var lexer = Lexer(source, file: name, diagnostics: diags)
    var parser = Parser(lexer.tokenize(), diagnostics: diags)
    let parsed = parser.parse()
    if diags.hasErrors {
        fputs("internal error: failed to parse the embedded prelude '\(name)'\n" + diags.render() + "\n", stderr)
        exit(1)
    }
    return parsed
}

// Prepend the `runtime` prelude for a white-box runtime test (`NOMU_RT_PRELUDE`, task 174.5): the fixture
// calls runtime internals directly, so they must be local decls. Returns the runtime function names as the
// runtime-subset designation (its functions compile `noSafepoint`, like the package). The bare weak-ODR
// definitions fold with the `runtime` package's, so this adds no runtime duplication to the test binary.
private func prependRuntimePrelude(_ program: Program) -> (Program, Set<String>) {
    let runtime = parseEmbeddedPrelude(EmbeddedSources.runtimePreludeSource, EmbeddedSources.runtimePreludeName)
    let subset = Set(runtime.decls.compactMap { decl -> String? in
        if case .funcDecl(let f) = decl { return f.name }
        return nil
    })
    return (Program(decls: runtime.decls + program.decls, imports: program.imports), subset)
}

// Rewrite an imported declaration to its per-origin identity (`origin@name`, task 100.2.3.2), and any
// type reference inside it that names one of the module's own exported types to that type's identity.
private func encodeExternalDecl(_ decl: TopDecl, origin: String, ownTypes: Set<String>,
                                foreign: [String: String] = [:]) -> TopDecl {
    func encT(_ r: TypeRef?) -> TypeRef? {
        guard let r = r else { return nil }
        let nm = ownTypes.contains(r.name) ? ExternalName.encode(origin: origin, name: r.name)
               : foreign[r.name].map { ExternalName.encode(origin: $0, name: r.name) } ?? r.name
        let fn = r.fn.map { FnType(params: $0.params.compactMap { encT($0) }, ret: encT($0.ret)) }
        return TypeRef(name: nm, fn: fn, existentialOf: r.existentialOf, opaqueOf: r.opaqueOf,
                       genericArgs: r.genericArgs?.compactMap { encT($0) }, qualifier: r.qualifier, span: r.span)
    }
    // A reconstructed computed property's declared type references an imported type by its bare name;
    // origin-encode it like a field's (task 100.4.3.5.4). The accessor bodies are empty placeholders.
    func encP(_ p: ComputedProperty) -> ComputedProperty {
        ComputedProperty(name: p.name, type: encT(p.type)!, getter: p.getter, setter: p.setter, span: p.span)
    }
    // A reconstructed method's (instance or `static`) signature may name an imported type — encode its
    // param/return types like a field's, so a static method's `-> Rect` return resolves to the right
    // per-origin identity (task 100.4.3.5.4). Bodies are empty (they live in the producer).
    func encM(_ m: FuncDecl) -> FuncDecl {
        FuncDecl(name: m.name, generics: m.generics,
                 params: m.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
                 returnType: encT(m.returnType), body: m.body, isStatic: m.isStatic,
                 visibility: m.visibility, span: m.span)
    }
    let key = { ExternalName.encode(origin: origin, name: $0) }
    switch decl {
    case .funcDecl(let f):
        return .funcDecl(FuncDecl(name: key(f.name), generics: f.generics,
            params: f.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
            returnType: encT(f.returnType), body: f.body, isStatic: f.isStatic, visibility: f.visibility, span: f.span))
    case .structDecl(let s):
        return .structDecl(StructDecl(name: key(s.name), generics: s.generics,
            fields: s.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: s.properties.map(encP), methods: s.methods.map(encM), conformances: s.conformances, visibility: s.visibility, span: s.span))
    case .classDecl(let c):
        return .classDecl(ClassDecl(name: key(c.name), generics: c.generics,
            fields: c.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: c.properties.map(encP), methods: c.methods.map(encM), conformances: c.conformances, visibility: c.visibility, span: c.span))
    case .enumDecl(let e):
        return .enumDecl(EnumDecl(name: key(e.name), generics: e.generics,
            cases: e.cases.map { EnumCaseDecl(name: $0.name,
                fields: $0.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
                span: $0.span) },
            properties: e.properties.map(encP), methods: e.methods.map(encM), conformances: e.conformances, visibility: e.visibility, span: e.span))
    default:
        return decl
    }
}

// Report leaf-name collisions (task 100.2.3.2): two imports in one file addressed by the same qualifier
// (a shared module leaf with no disambiguating alias). The remedy is to alias one with `as`.
private func reportLeafCollisions(_ collisions: [(file: String, leaf: String, span: Span)], into diags: DiagnosticSink) {
    for c in collisions {
        diags.error("two imports in this file share the qualifier '\(c.leaf)' — alias one with 'as' (e.g. 'import … as \(c.leaf)2')", at: c.span)
    }
}

// Compile one dependency module to its own object and return its public interface (task 100.4.2). The
// same pipeline the entry uses, but it emits an object with no entry point (no link here) and reports
// its own diagnostics; returns nil on any error. The interface is built from the module's own public
// surface before the prelude is prepended.
// The imported templates to inject for the consumer dial (task 100.5.2/100.5.4). `all` injects the whole
// shipped closure (whole-tree specialization). `edge` injects only the generics the consumer's own code
// calls **directly**, plus the non-public callees those reach — so a nested public generic (one reached
// only through another specialized body) stays on the erased witness path. The producer ships bodies with
// their original visibility, so a `.public` template is a generic others may call directly while a
// non-public one is a private callee that must travel with its caller. The direct-call scan reads the
// consumer's own function bodies (origin-keyed call targets); a call from inside a type's method is not
// scanned yet, so it conservatively stays erased under `edge`.
private func selectForDial(_ templates: [ImportedTemplate], mode: MonoMode, consumer: NOIRModule) -> [ImportedTemplate] {
    guard mode != .none else { return [] }
    if mode == .all { return templates }
    func encoded(_ t: ImportedTemplate) -> String { ExternalName.encode(origin: t.origin, name: noirDeclName(t.decl)) }
    // An "exported" template is one a consumer may call directly — `public` (cross-package) or `package`
    // (same-package, task 187.4.4); either seeds the edge dial. A sub-`package` template is a private callee,
    // pulled in only when a selected body reaches it.
    func isPublic(_ t: ImportedTemplate) -> Bool {
        if case .funcDecl(let f) = t.decl { return f.visibility >= .package }
        return false
    }
    var byEncoded: [String: ImportedTemplate] = [:]
    for t in templates { byEncoded[encoded(t)] = t }
    // The generic names the consumer's own code calls directly (origin-keyed, as resolved in its NOIR).
    var direct = Set<String>()
    for decl in consumer.decls { direct.formUnion(collectReferencedNames(decl)) }

    var selectedNames = Set<String>()
    var selected: [ImportedTemplate] = []
    var worklist: [ImportedTemplate] = []
    for t in templates where isPublic(t) && direct.contains(encoded(t)) {
        if selectedNames.insert(encoded(t)).inserted { selected.append(t); worklist.append(t) }
    }
    // Pull in the non-public callees the selected bodies reach (they cannot be erased-linked); leave a
    // referenced public generic un-injected so it stays on the witness path.
    while let t = worklist.popLast() {
        for ref in collectReferencedNames(t.decl) {
            guard let u = byEncoded[ref], !isPublic(u), selectedNames.insert(ref).inserted else { continue }
            selected.append(u); worklist.append(u)
        }
    }
    return selected
}

private func noirDeclName(_ d: NOIRDecl) -> String {
    switch d {
    case .funcDecl(let f):   return f.name
    case .structDecl(let s): return s.name
    case .enumDecl(let e):   return e.name
    case .classDecl(let c):  return c.name
    case .actorDecl(let a):  return a.name
    }
}

// The names of a module's own top-level declarations (task 100.5.4): the set a shipped `.bir` body's
// references are canonicalized against — a reference to one of these is this module's, so it is rewritten
// to an origin-keyed name; anything else (prelude, builtins, locals, type params) stays bare. Taken from
// the pre-prelude own-surface snapshot, so prelude names are excluded.
private func topDeclNames(_ program: Program) -> Set<String> {
    var names = Set<String>()
    for decl in program.decls {
        switch decl {
        case .funcDecl(let f):      names.insert(f.name)
        case .structDecl(let s):    names.insert(s.name)
        case .classDecl(let c):     names.insert(c.name)
        case .enumDecl(let e):      names.insert(e.name)
        case .interfaceDecl(let i): names.insert(i.name)
        default:                    break
        }
    }
    return names
}

// The decls a dependency ships in its `.bir` (tasks 100.5.1 / 100.5.4): its **public generic** free
// functions, plus the transitive closure of **non-public** functions those bodies reach — the automatic
// transitive closure (§100.5). A non-public callee is absent from the `.nmi` (interface-invisible), so the
// consumer's Sema never sees it; shipping its body lets the consumer emit it locally (internal, origin-
// keyed) under `--mono`. A public callee is left out: a public generic is already seeded here, and a public
// non-generic links through the ordinary import path. `ownNames` excludes the prelude (pre-prelude
// snapshot), so a prelude/builtin callee is never pulled in. Generic **types**/methods ride a later
// 100.5.4 increment.
private func shippedTemplates(_ module: NOIRModule, ownNames: Set<String>) -> [NOIRDecl] {
    // This module's own functions, by name (excludes prelude, which `ownNames` already filters out).
    var ownFuncs: [String: NOIRDecl] = [:]
    for decl in module.decls {
        if case .funcDecl(let f) = decl, ownNames.contains(f.name) { ownFuncs[f.name] = decl }
    }
    // An exported generic — `public` (cross-package) or `package` (same-package, task 187.4.4) — seeds the
    // shipped `.bir` so a consumer that may call it specializes it; a sub-`package` generic ships only as a
    // private callee of a seeded body. (A cross-package consumer never instantiates a `package` generic, so
    // shipping it in the one `.bir` is harmless — it stays unspecialized there.)
    func isPublic(_ decl: NOIRDecl) -> Bool {
        if case .funcDecl(let f) = decl { return f.visibility >= .package }
        return false
    }
    func isGeneric(_ decl: NOIRDecl) -> Bool {
        if case .funcDecl(let f) = decl { return !f.generics.isEmpty }
        return false
    }
    var shippedNames = Set<String>()
    var shipped: [NOIRDecl] = []
    var worklist: [NOIRDecl] = []
    // Seed: every exported (`public`/`package`) generic function.
    for (name, decl) in ownFuncs where isPublic(decl) && isGeneric(decl) {
        shippedNames.insert(name); shipped.append(decl); worklist.append(decl)
    }
    // Close over the non-public functions the shipped bodies reach, transitively.
    while let decl = worklist.popLast() {
        for ref in collectReferencedNames(decl) {
            guard let callee = ownFuncs[ref], !isPublic(callee), shippedNames.insert(ref).inserted else { continue }
            shipped.append(callee); worklist.append(callee)
        }
    }
    return shipped
}

// LLVM backend binary stage (8.1.4): emit a host object via the LLVM C API, build the runtime
// static archive, and link them into a native executable. Reports the binary path (like the C
// path). Everything LLVM stays behind `emitHelloWorldObject` in LLVMBridge — this only orchestrates
// object → .a → link.
private func emitLLVMBinary(_ module: NOIRModule, stem: String, buildRoot: String, optimize: Bool,
                            subsetFuncs: Set<String>, timings: Timings,
                            emitLLVM: Bool = false, stopAfterLLVM: Bool = false,
                            extraObjects: [String] = [], externalFuncNames: Set<String> = [],
                            externalGenericSigs: [String: ExternalGenericSig] = [:],
                            weakOriginFiles: Set<String> = [], facts: FactStore = FactStore()) {
    let objPath = stem + ".o"
    // The LLVM path (SSAIR gen + passes, IR egress, LLVM opt, object emit) reports its sub-stages up
    // through the `StageSink`, so the timing table's `ssair`/`llvm` phases break down rather than
    // showing one opaque `codegen` bucket. `--emit-llvm` writes the egress module (pre-opt) to
    // `<stem>.ll`; `--stop=llvm` writes it and skips object emission + linking.
    // Gen SSAIR here so the driver owns the stage sequence (task 165.1): gen → [inference + `.nmi` emit,
    // task 164] → transforms → lower. `emitObject` takes the gen'd SSA and lowers it.
    let gen = timings.measure("ssair", "gen") { lowerToSSAIR(module, subsetFuncs: subsetFuncs) }
    if gen.diagnostics.hasErrors {
        fputs("error: SSAIR: " + gen.diagnostics.render() + "\n", stderr)
        timings.report(); exit(1)
    }
    // Inference stage (task 164.2): over the raw, pre-transform SSA, compute the interprocedural escape
    // summary (169) and write it into the fact store's perf section — the real `gen → inference → emit →
    // transforms` ordering. Keyed by post-mono SSA function name (the per-instance summary the promotion
    // path reads in 164.5), alongside the per-definition ABI facts 164.1 wrote. Still behavior-preserving:
    // written, not yet consumed (promotion reads it at 164.5, the `.nmi` serializes it at 164.4).
    var store = facts
    timings.measure("ssair", "inference") {
        let summaries = computeEscapeSummaries(gen.module.functions, aggregates: gen.module.aggregates)
        writeEscapeSummaries(summaries, into: &store)
    }
    let err = emitObject(gen.module, from: module, to: objPath, optimize: optimize,
                         onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                         emitLLVMTo: emitLLVM ? stem + ".ll" : nil, stopAfterEgress: stopAfterLLVM,
                         externalFuncNames: externalFuncNames, externalGenericSigs: externalGenericSigs,
                         weakOriginFiles: weakOriginFiles, facts: store)
    if let err = err {
        fputs("error: \(err)\n", stderr)
        timings.report()
        exit(1)
    }
    if emitLLVM { fputs(stem + ".ll\n", stderr) }
    if stopAfterLLVM { return }
    let archive = timings.measure("runtime", "archive") { cachedRuntimeArchive(buildRoot: buildRoot) }
    guard let archive = archive else { timings.report(); exit(1) }

    let binPath = stem
    // `-dead_strip` drops code unreachable from the program's entry — most of MMTk's plan/scheduler
    // machinery is never reached on the NoGC alloc path — and `-x` strips local symbols. (6.1.1 size.)
    // Dependency objects (separate compilation, task 100.4.2) link alongside the entry object; the embedded
    // `nomu`-workspace objects (task 174) ride in `extraObjects` too, injected by the driver before codegen.
    var linkArgs = ["-o", binPath, "-Wl,-dead_strip", "-Wl,-x", objPath] + extraObjects + [archive]
    // M6 · 6.1.1 — make the GC archive available to the emitted-program link. It rides inside nomuc
    // as an embedded Mach-O section (nomuc stays one atomic file) and is extracted to a cache file
    // here; a dev override via NOMU_GC_ARCHIVE wins if set. A static archive pulls in only the
    // members that resolve referenced symbols, so until `rt_alloc` routes through MMTk the archive
    // contributes nothing to a binary. MMTk's deps (sysinfo → CoreFoundation/IOKit/objc) are named
    // so those members can resolve once they are referenced. (No `-u` force-link — that dragged the
    // whole MMTk closure into every binary regardless of use.)
    if let gcArchive = ProcessInfo.processInfo.environment["NOMU_GC_ARCHIVE"] ?? embeddedGCArchivePath() {
        linkArgs += [gcArchive,
                     "-framework", "CoreFoundation", "-framework", "IOKit", "-lobjc"]
    }
    let linkStatus = timings.measure("link", "cc") { runProcess("/usr/bin/cc", linkArgs) }
    if linkStatus != 0 {
        fputs("error: link failed\n", stderr)
        timings.report()
        exit(1)
    }
    fputs(binPath + "\n", stderr)
}

// Compile the runtime C sources to objects and archive them into `libnomuruntime.a` (the
// `backend.md` "runtime library" item, real for the LLVM path). Replaces the C backend's
// per-file `cc` co-compile. Returns the archive path, or nil on failure (message on stderr).
// The runtime `.a` is identical across programs (the C floor is embedded in nomuc), so it is content-
// addressed and cached under `build/runtime/`. The key hashes the embedded runtime sources + host
// arch + a recipe version, so it invalidates automatically whenever any of those change — editing the
// runtime rebuilds nomuc, which changes the embedded content and thus the key. Nobody clears the
// cache; clearing `build/` is enough if ever needed. (Local `cc` version is deliberately not in the
// key: a stale archive built by an older cc still links and runs — the C ABI is stable — so reuse is
// correct; the C floor is transitional anyway.)
private func cachedRuntimeArchive(buildRoot: String) -> String? {
    let fm = FileManager.default
    let dir = buildRoot + "/runtime"
    let cached = dir + "/nomu-runtime-\(runtimeArchiveKey()).a"
    if fm.fileExists(atPath: cached) { return cached }   // hit

    // Miss: build in a pid-unique scratch dir, then publish atomically under the content key so a
    // crash or a concurrent compile never leaves a partial archive at the shared path.
    let scratch = dir + "/build-\(ProcessInfo.processInfo.processIdentifier)"
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: scratch) }
    writeRuntimeSources(toDir: scratch)
    guard let built = buildRuntimeArchive(inDir: scratch) else { return nil }
    try? fm.removeItem(atPath: cached)
    do { try fm.moveItem(atPath: built, toPath: cached) } catch {
        fputs("error: failed to publish runtime archive: \(error)\n", stderr)
        return nil
    }
    return cached
}

// ─── The embedded `nomu` workspace (task 174) ───────────────────────────────────────────────────────
//
// `core` / `runtime` / `std` are ordinary Nomu packages whose source is embedded in the compiler. The
// driver materializes them to a scratch workspace and compiles each module into a home-qualified library
// object (origin `nomu/<pkg>[/<module>]`), linked into the user binary. Every prelude reference is external
// (the prepend is retired, 174.5/.5.1): `std` resolves through the implicit `import std` (its `prelude`
// module) or an explicit `import std/<module>`, `core`'s `ManagedBuffer` resolves as an ambient package type,
// and the `runtime` package's functions link by bare symbol. There is deliberately no content cache
// here — the cross-build CAS cache (task 172, next) subsumes it, so until then each build recompiles the
// workspace.

// The three embedded packages. `core` and `runtime` are single-module packages rooted at their own source
// file; `std` is a multi-module package (one leaf directory per module) whose `default-module` is `prelude`,
// the module the implicit `import std` names. Each module is (package-relative dir — "" for a single-module
// package's root —, file name, source); a module may span several files.
private struct NomuModuleSource { let dir: String; let file: String; let source: String }
private struct NomuPackageSource { let name: String; let modules: [NomuModuleSource]; let defaultModule: String? }
private let nomuPackageSources: [NomuPackageSource] = [
    NomuPackageSource(name: "core",
                      modules: [NomuModuleSource(dir: "", file: EmbeddedSources.preludeName,
                                                 source: EmbeddedSources.preludeSource)],
                      defaultModule: nil),
    NomuPackageSource(name: "runtime",
                      modules: [NomuModuleSource(dir: "", file: EmbeddedSources.runtimePreludeName,
                                                 source: EmbeddedSources.runtimePreludeSource)],
                      defaultModule: nil),
    NomuPackageSource(name: "std",
                      modules: EmbeddedSources.stdModules.map { NomuModuleSource(dir: $0.module, file: $0.name,
                                                                                 source: $0.source) },
                      defaultModule: "prelude"),
]

// The module directories of a package, in first-seen (deterministic) order.
private func moduleDirs(_ p: NomuPackageSource) -> [String] {
    var seen = Set<String>()
    return p.modules.map(\.dir).filter { seen.insert($0).inserted }
}

// Materialize the embedded `nomu` workspace into `dir`: a `nomu.yaml` workspace marker named `nomu`, plus one
// package per embedded source set, each with a `pkg.json` listing every module as a product. Materialization
// precedes discovery so a user build resolves `std` imports against these files; compilation follows it
// (`compileNomuWorkspace`). Returns false on failure (message on stderr). The caller owns `dir`'s lifecycle.
private func materializeNomuWorkspace(inDir dir: String) -> Bool {
    let fm = FileManager.default
    func write(_ contents: String, _ path: String) -> Bool {
        do { try contents.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { fputs("error: failed to write '\(path)': \(error)\n", stderr); return false }
    }
    func mkdir(_ path: String) -> Bool {
        do { try fm.createDirectory(atPath: path, withIntermediateDirectories: true); return true }
        catch { fputs("error: failed to create dir '\(path)': \(error)\n", stderr); return false }
    }
    guard mkdir(dir), write("name: nomu\n", dir + "/nomu.yaml") else { return false }
    for p in nomuPackageSources {
        let pkgDir = dir + "/" + p.name
        let products = moduleDirs(p).map { "\"\($0)\"" }.joined(separator: ", ")
        let def = p.defaultModule.map { ", \"default-module\": \"\($0)\"" } ?? ""
        guard mkdir(pkgDir),
              write("{ \"name\": \"\(p.name)\", \"products\": [\(products)]\(def) }\n", pkgDir + "/pkg.json")
        else { return false }
        for m in p.modules {
            let modDir = m.dir.isEmpty ? pkgDir : pkgDir + "/" + m.dir
            guard mkdir(modDir), write(m.source, modDir + "/" + m.file) else { return false }
        }
    }
    return true
}

// Compile each module of the materialized `nomu` workspace in `dir` into a home-qualified library object +
// interface. Returns one artifact per module, or nil on failure (message on stderr). A module's canonical
// path is `nomu/<package>[/<module>]` (the workspace name + its workspace-relative dir). A `std` module that
// imports a sibling (`import pkg/prelude`) also emits that sibling as a `__mod_*` intermediate under the
// workspace `build/`; only the per-module objects returned here are linked, so each module links once.
private struct NomuArtifact { let package: String; let module: String; let obj: String; let nmi: String }
private func compileNomuWorkspace(inDir dir: String) -> [NomuArtifact]? {
    var artifacts: [NomuArtifact] = []
    for p in nomuPackageSources {
        let pkgDir = dir + "/" + p.name
        for modDir in moduleDirs(p) {
            let srcDir = modDir.isEmpty ? pkgDir : pkgDir + "/" + modDir
            let files = p.modules.filter { $0.dir == modDir }.map { srcDir + "/" + $0.file }
            var opts = EmitOptions()
            opts.compilingPrelude = true                     // the prelude build: skip prepend, strong linkage
            opts.emitLibrary = true                          // emit the entry module as a library object + `.nmi`
            opts.runtimeSubsetByMembership = (p.name == "runtime")  // runtime-subset by package membership (174.4)
            opts.outputPath = srcDir + "/" + (modDir.isEmpty ? p.name : modDir)  // `<srcDir>/<leaf>.o`
            guard compile(paths: files, options: opts) else {
                let shown = modDir.isEmpty ? p.name : p.name + "/" + modDir
                fputs("error: failed to compile embedded nomu module '\(shown)'\n", stderr)
                return nil
            }
            artifacts.append(NomuArtifact(package: p.name, module: modDir,
                                          obj: opts.outputPath! + ".o", nmi: opts.outputPath! + ".nmi"))
        }
    }
    return artifacts
}

// A stable (cross-run) FNV-1a key over everything that determines the archive's contents.
private func runtimeArchiveKey() -> String {
    var h: UInt64 = 0xcbf29ce484222325
    func mix(_ s: String) { for b in s.utf8 { h ^= UInt64(b); h = h &* 0x00000100000001B3 } }
    mix(EmbeddedSources.runtimeHeader)
    mix(EmbeddedSources.runtimeC)
    mix(EmbeddedSources.coreC)
    mix(EmbeddedSources.rtAsmArm64)   // the asm floor is archived in (task 128.2)
    mix(hostArch)
    mix("recipe-2")   // bump when the compile/archive commands below change
    return String(h, radix: 16)
}

private var hostArch: String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

private func buildRuntimeArchive(inDir dir: String) -> String? {
    let runtimeO = dir + "/runtime.o"
    let coreO = dir + "/core.o"
    let archive = dir + "/libnomuruntime.a"
    if runProcess("/usr/bin/cc", ["-w", "-I", dir, "-c", dir + "/runtime.c", "-o", runtimeO]) != 0 {
        fputs("error: failed to compile runtime.c\n", stderr); return nil
    }
    if runProcess("/usr/bin/cc", ["-w", "-I", dir, "-c", dir + "/core.c", "-o", coreO]) != 0 {
        fputs("error: failed to compile core.c\n", stderr); return nil
    }
    var members = [runtimeO, coreO]
    // The asm floor (task 128.2): assemble the per-arch `.s` (clang assembles `.s` directly) and archive
    // it beside the C objects, so its symbols (rtSwitch, rtFiberInit) resolve in every emitted binary.
    if hostArch == "arm64" {
        let asmO = dir + "/rtasm.o"
        if runProcess("/usr/bin/cc", ["-c", dir + "/rtasm.s", "-o", asmO]) != 0 {
            fputs("error: failed to assemble rtasm.s\n", stderr); return nil
        }
        members.append(asmO)
    }
    // Rebuild from scratch so stale members never accumulate; `rcs` creates + indexes the archive.
    try? FileManager.default.removeItem(atPath: archive)
    if runProcess("/usr/bin/ar", ["rcs"] + [archive] + members) != 0 {
        fputs("error: failed to archive runtime\n", stderr); return nil
    }
    return archive
}

// M6 · 6.1.0 — the embedded-section reader (src/gcembed): pointer to nomuc's `__DATA,__nomu_gc`
// bytes (nil if absent), *size = length. Bound by symbol name to avoid a module import.
@_silgen_name("nomu_gc_embedded_section")
private func nomu_gc_embedded_section(_ size: UnsafeMutablePointer<UInt>) -> UnsafeRawPointer?

// Materialize nomuc's embedded GC archive to a cache file (once) and return its path, or nil if
// this nomuc carries no embedded archive. The external linker needs a file path, so the section
// bytes are written to a temp cache and reused across invocations. (6.1.0; real binding at 6.1.1.)
private func embeddedGCArchivePath() -> String? {
    var size: UInt = 0
    guard let base = nomu_gc_embedded_section(&size), size > 0 else { return nil }
    let cache = NSTemporaryDirectory() + "nomu-gc-\(size).a"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: cache),
       (attrs[.size] as? Int) == Int(size) {
        return cache  // already extracted at this size — reuse
    }
    let data = Data(bytes: base, count: Int(size))
    guard (try? data.write(to: URL(fileURLWithPath: cache))) != nil else {
        fputs("error: failed to extract embedded GC archive to \(cache)\n", stderr)
        return nil
    }
    return cache
}

// Run `exe args`, wait, and return its exit status (or 1 if it could not be launched).
private func runProcess(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fputs("error: failed to launch \(exe): \(error)\n", stderr)
        return 1
    }
    return p.terminationStatus
}

// Write the embedded runtime/core C sources + ABI header into `dir` (M4.13).
private func writeRuntimeSources(toDir dir: String) {
    var files = [
        ("runtime.h", EmbeddedSources.runtimeHeader),
        ("runtime.c", EmbeddedSources.runtimeC),
        ("core.c",    EmbeddedSources.coreC),
    ]
    // The asm floor (task 128.2), per-arch. arm64 only for now; x86-64 is deferred, and core.c's
    // self-test degrades to a stub there, so no `.s` is needed to link.
    if hostArch == "arm64" { files.append(("rtasm.s", EmbeddedSources.rtAsmArm64)) }
    for (name, contents) in files {
        guard (try? contents.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: failed to write runtime source '\(name)'\n", stderr)
            exit(1)
        }
    }
}
