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
import planner
import buildinfo
import LLVMBridge
import settings

// Build a program from one module's files (task 190): plan the build, run each module's compile job in
// order, and link. The planner reads the workspaces, resolves every import and places every output (D2, D4);
// each job sees only its own inputs (`compile(_:options:timings:)`); the link takes every object the plan
// built plus the runtime archive. Every output goes where the plan puts it (D2, D4).
// What a build did: the binary it produced (nil on failure), and which module jobs it compiled and which it
// took from the host cache, in plan order (modules named `<scope>.<name>:<path>`).
public struct BuildResult {
    public var binary: String? = nil
    public var compiled: [String] = []
    public var cached: [String] = []
}

// Returns the entry's output stem (the binary, for a binary build); nil on failure.
public func buildProgram(paths: [String], options: EmitOptions = EmitOptions(),
                         selection: ConfigSelection = ConfigSelection()) -> String? {
    build(paths: paths, options: options, selection: selection).binary
}

public func build(paths: [String], options: EmitOptions = EmitOptions(),
                  selection: ConfigSelection = ConfigSelection()) -> BuildResult {
    var result = BuildResult()
    guard let primary = paths.first else {
        fputs("error: no source files given\n", stderr)
        return result
    }
    let timings = Timings()
    timings.egress = "ssair"

    var planOptions = PlanOptions()
    planOptions.allowCoreImport = options.allowCoreImport
    planOptions.compilerIdentity = BuildInfo.gitCommit
    planOptions.runtimeRecipe = runtimeArchiveRecipe
    // The configuration resolves once, between reading the module table and planning: the language
    // workspace's settings enter its host-cache key, which places its outputs.
    let workspaces = WorkspaceSet(entry: primary, disk: DiskTree(), includeLanguageWorkspace: planOptions.product == .binary)
    let moduleTable = ModuleTable(workspaces: workspaces, entryFiles: paths, options: planOptions)
    var configuration: ResolvedBuildConfiguration? = nil
    if moduleTable.diagnostics.isEmpty {
        switch timings.measure("plan", "configuration", { resolveConfiguration(moduleTable, workspaces, selection) }) {
        case .success(let c):
            configuration = c
            planOptions.outputOptions = [c.languageCanonical]
            planOptions.outputConfig = c.outputDirectory
            timings.optimize = JobSettings(c.jobSettings(moduleTable.entry)).optimize
        case .failure(let errors):
            fputs(errors.rendered + "\n", stderr)
            timings.report()
            return result
        }
    }
    let plan = Plan(modules: moduleTable, workspaces: workspaces, options: planOptions)
    for step in PlanTimings.Step.allCases {
        timings.record(phase: "plan", name: step.rawValue, seconds: plan.timings.seconds[step] ?? 0)
    }
    if options.stopAt == .plan {
        print(plan.dump(), terminator: "")
        if plan.diagnostics.isEmpty { result.binary = plan.jobs.last?.binary ?? "" }
        return result
    }
    if !plan.diagnostics.isEmpty {
        fputs(plan.diagnostics.map(\.description).joined(separator: "\n") + "\n", stderr)
        timings.report()
        return result
    }
    let table = plan.modules
    guard let entryJob = plan.jobs.first(where: { $0.module == table.entry }) else { return result }
    timings.package = table.modules[table.entry]?.package.name ?? ""
    timings.file = plan.jobs.count == 1 ? primary : "\(plan.jobs.count) modules"

    let stem = entryJob.binary
    func makeDirectory(_ dir: String) -> Bool {
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); return true }
        catch { fputs("error: failed to create output dir '\(dir)': \(error)\n", stderr); return false }
    }
    guard makeDirectory((stem as NSString).deletingLastPathComponent) else { return result }

    // AST debug view of the entry module: --emit-ast writes it; --stop=ast writes it and halts.
    if options.ast || options.stopAt == .ast {
        let diags = DiagnosticSink()
        var decls: [TopDecl] = [], imports: [ImportDecl] = []
        for f in entryJob.files {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            var lexer = Lexer(text, file: f, diagnostics: diags)
            var parser = Parser(lexer.tokenize(), diagnostics: diags)
            let prog = parser.parse()
            decls += prog.decls; imports += prog.imports
        }
        writeArtifact(dumpAST(Program(decls: decls, imports: imports)), toFile: stem + ".ast")
        if options.stopAt == .ast {
            if !diags.isEmpty { fputs(diags.render() + "\n", stderr) }
            if !diags.hasErrors { result.binary = stem }
            return result
        }
    }

    // A module's canonical identity (D6): its workspace's scope and name, then its path. Library symbols
    // mangle under it.
    func origin(_ k: ModuleKey) -> [String] { [k.workspace.scope, k.workspace.name] + k.path }
    func packageKey(_ k: ModuleKey) -> String {
        let p = table.modules[k]!.package
        return "\(p.workspace)|\(p.root)"
    }
    let jobByKey = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.module, $0) })
    // The language workspace's sources on disk, for reporting (diagnostics, debug info): kept current
    // whenever a build uses that workspace, compiled or cached.
    let sourceCopy = plan.jobs.contains(where: \.inHostCache)
        ? timings.measure("plan", "source copy") { LanguageSourceCopy.ensure(cacheRoot: plan.cacheRoot) } : nil
    var objects: [String] = []
    for j in plan.jobs {
        let m = table.modules[j.module]!
        let isEntry = j.module == table.entry
        // A host-cache entry (D4) is complete once its directory exists: it is published whole by one rename.
        if j.inHostCache && FileManager.default.fileExists(atPath: j.outputDir) {
            objects.append(j.object)
            result.cached.append(j.module.description)
            continue
        }
        // A cached job compiles into a private directory first, then publishes it.
        let staging = j.inHostCache
            ? (j.outputDir as NSString).deletingLastPathComponent
              + "/.staging-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ..< .max))"
            : j.outputDir
        func staged(_ path: String) -> String { staging + String(path.dropFirst(j.outputDir.count)) }
        guard makeDirectory(staging) else { return result }
        var imports: [String: [CompileJob.Import]] = [:]
        for imp in m.imports {
            let root: ImportRoot
            switch imp.root { case .pkg: root = .pkg; case .package(let n): root = .package_(n) }
            imports[imp.file, default: []].append(CompileJob.Import(
                root: root, path: imp.path, alias: imp.alias, isPublic: imp.isPublic, isTest: imp.isTest,
                isImplicit: imp.isImplicit, target: origin(imp.target)))
        }
        let dependencies = j.visibleDependencies.map { d -> CompileJob.Dependency in
            let dj = jobByKey[d]!
            return CompileJob.Dependency(origin: origin(d), interface: dj.interface, bir: dj.bir, packageKey: packageKey(d))
        }
        let outputs = CompileJob.Outputs(object: staged(j.object), interface: staged(j.interface), bir: staged(j.bir),
                                         debugStem: isEntry ? stem : nil)
        var job = CompileJob(origin: origin(j.module), files: j.files, packageName: m.package.name,
                             packageKey: packageKey(j.module), isProduct: m.isProduct, imports: imports,
                             dependencies: dependencies, product: j.product == .binary ? .binary : .library,
                             whiteBox: j.whiteBox, runtimeSubsetByMembership: j.runtimeSubsetByMembership,
                             outputs: outputs)
        if j.inHostCache, let sourceCopy { job.reportedPaths = LanguageSourceCopy.reportedPaths(j.files, copy: sourceCopy) }
        job.settings = configuration?.jobSettings(j.module) ?? [:]
        // The building workspace's modules take the build's options; another workspace's modules, and the
        // language workspace's, compile with the defaults.
        var jobOptions = EmitOptions()
        if j.module.workspace == table.entry.workspace { jobOptions = options }
        jobOptions.compilingPrelude = j.inHostCache
        if options.emitJobs, let data = JobFile(job: job, options: jobOptions).encoded() {
            try? data.write(to: URL(fileURLWithPath: staged(j.outputDir + "/" + j.stem + ".job.json")))
        }
        guard compile(job, options: jobOptions, timings: timings) else {
            if j.inHostCache { try? FileManager.default.removeItem(atPath: staging) }
            timings.report(); return result
        }
        if j.inHostCache && rename(staging, j.outputDir) != 0 {
            // Another build published this entry first; it is the same content, so keep it.
            try? FileManager.default.removeItem(atPath: staging)
            guard FileManager.default.fileExists(atPath: j.outputDir) else {
                fputs("error: cannot publish '\(j.outputDir)': \(String(cString: strerror(errno)))\n", stderr)
                timings.report(); return result
            }
        }
        objects.append(j.object)
        result.compiled.append(j.module.description)
    }
    timings.jobs = (compiled: result.compiled.count, cached: result.cached.count)

    // A binary links every object the plan built with the runtime archive. A debug stop or a terminal
    // `--emit-nmi` ends the build before the link.
    if let link = plan.link, let archive = plan.runtimeArchive, !options.nmi, options.stopAt == .binary {
        // The entry object links first: it owns the program-wide definitions (GC type and root maps), which
        // must win over any weak copy in a library object.
        let objectsInOrder = [entryJob.object] + link.objects.filter { $0 != entryJob.object }
        guard let configuration else { preconditionFailure("a planned build has a configuration") }
        guard linkBinary(objects: objectsInOrder, output: stem, runtimeArchive: archive.archive,
                         runtimeGlobals: configuration.runtimeGlobals, record: configuration.summary,
                         timings: timings) else {
            timings.report(); return result
        }
    }
    timings.report()
    result.binary = stem
    return result
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
    guard let binary = buildResolved(m, options: options, selection: selection) else {
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

// The `.nmi` perf section (task 164.4.3): the per-definition escape summary of each exported definition.
// Computed over the module's **erased/template** bodies — the pre-mono SSA — so each definition is
// summarized once (the cross-module form a dependent reads, 164.6), distinct from the per-instance
// post-mono summary the promotion path consumes (164.2/164.5). The summary is re-keyed to the per-
// definition convention and projected onto the public surface, so only an exported definition carries
// one (no private symbol leaks, and the key matches the ABI facts). Best-effort: a body that fails to
// lower pre-mono simply carries no summary (read as "unknown", the conservative floor); lowering
// diagnostics are intentionally dropped — a valid interface's facts are advisory, never fatal here.
func escapePerfSection(_ iface: ModuleInterface, _ module: NOIRModule,
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
func externalEscapeKeys(_ perDef: [String: EscapeSummary], origin: String) -> [String: EscapeSummary] {
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
func writeArtifact(_ contents: String, toFile path: String) {
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

// Prepend the `runtime` prelude for a white-box runtime test (`test.runtime_prelude`, task 174.5): the fixture
// calls runtime internals directly, so they must be local decls. Returns the runtime function names as the
// runtime-subset designation (its functions compile `noSafepoint`, like the package). The bare weak-ODR
// definitions fold with the `runtime` package's, so this adds no runtime duplication to the test binary.
func prependRuntimePrelude(_ program: Program) -> (Program, Set<String>) {
    let runtime = parseEmbeddedPrelude(EmbeddedSources.runtimePreludeSource, EmbeddedSources.runtimePreludeName)
    let subset = Set(runtime.decls.compactMap { decl -> String? in
        if case .funcDecl(let f) = decl { return f.name }
        return nil
    })
    return (Program(decls: runtime.decls + program.decls, imports: program.imports), subset)
}

// Rewrite an imported declaration to its per-origin identity (`origin@name`, task 100.2.3.2), and any
// type reference inside it that names one of the module's own exported types to that type's identity.
func encodeExternalDecl(_ decl: TopDecl, origin: String, ownTypes: Set<String>,
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
func reportLeafCollisions(_ collisions: [(file: String, leaf: String, span: Span)], into diags: DiagnosticSink) {
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
func selectForDial(_ templates: [ImportedTemplate], mode: MonoMode, consumer: NOIRModule) -> [ImportedTemplate] {
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
func topDeclNames(_ program: Program) -> Set<String> {
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
func shippedTemplates(_ module: NOIRModule, ownNames: Set<String>) -> [NOIRDecl] {
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

// Link a binary: the entry object, every dependency object, the settings object and the runtime archive.
// The settings object holds `runtimeGlobals`, the values the runtime reads (G14 of the build-configuration
// design); `record`, the configuration's short form, goes in the `__TEXT,__nomu_config` section (G13).
// Returns false on failure (message on stderr).
func linkBinary(objects: [String], output binPath: String, runtimeArchive: String,
                runtimeGlobals: [(symbol: String, value: RuntimeGlobal)], record: String, timings: Timings) -> Bool {
    let archive = timings.measure("runtime", "archive") { cachedRuntimeArchive(at: runtimeArchive) }
    guard let archive = archive else { return false }
    // `-dead_strip` drops code unreachable from the program's entry, and `-x` strips local symbols.
    // The binary is linked, indexed and signed in a temporary directory beside the output, then renamed into
    // place, so it appears complete in one step (two builds of one program can share the output path). It
    // keeps its final name there, since the linker's signature takes its identifier from the output name.
    let outputDir = (binPath as NSString).deletingLastPathComponent
    let stagingDir = (outputDir.isEmpty ? "." : outputDir) + "/.link-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
    guard (try? FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)) != nil else {
        fputs("error: cannot create '\(stagingDir)'\n", stderr)
        return false
    }
    defer { try? FileManager.default.removeItem(atPath: stagingDir) }
    let staging = stagingDir + "/" + (binPath as NSString).lastPathComponent
    let scratch = NSTemporaryDirectory() + "nomu-link-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let settingsObject = scratch + "/settings.o", recordFile = scratch + "/config.yaml"
    if let error = timings.measure("link", "settings", { emitSettingsObject(runtimeGlobals, to: settingsObject) }) {
        fputs("error: settings object: \(error)\n", stderr)
        return false
    }
    guard FileManager.default.createFile(atPath: recordFile, contents: Data(record.utf8)) else {
        fputs("error: cannot write '\(recordFile)'\n", stderr)
        return false
    }
    var linkArgs = ["-o", staging, "-Wl,-dead_strip", "-Wl,-x"] + objects + [settingsObject, archive]
    linkArgs.append("-Wl,-sectcreate,__TEXT,__nomu_config,\(recordFile)")
    // The GC frame index (FrameIndex.swift): the link reserves its section and writes a link map; afterwards
    // the index is written into the binary and its signature's page hashes are redone (CodeSignature.swift).
    let reserveFile = scratch + "/frameidx.bin", mapFile = scratch + "/link.map"
    do {
        let size = try FrameIndex.reserveSize(objects: objects)
        guard FileManager.default.createFile(atPath: reserveFile, contents: Data(count: size)) else {
            fputs("error: cannot write '\(reserveFile)'\n", stderr)
            return false
        }
    } catch {
        fputs("error: frame index: \(error)\n", stderr)
        return false
    }
    linkArgs += ["-Wl,-sectcreate,\(FrameIndex.segment),\(FrameIndex.section),\(reserveFile)",
                 "-Wl,-map,\(mapFile)"]
    let linkStatus = timings.measure("link", "cc") { runProcess("/usr/bin/cc", linkArgs) }
    if linkStatus != 0 {
        fputs("error: link failed\n", stderr)
        return false
    }
    let indexed = timings.measure("link", "frame index") { Result { try FrameIndex.write(binary: staging, linkMap: mapFile) } }
    if case .failure(let error) = indexed {
        fputs("error: frame index: \(error)\n", stderr)
        return false
    }
    let resigned = timings.measure("link", "sign") { Result { try CodeSignature.resign(binary: staging) } }
    switch resigned {
    case .failure(let error):
        fputs("error: signing: \(error)\n", stderr)
        return false
    case .success(.signed):
        break
    case .success(.unsupported):
        // A signature in a form the driver does not rewrite: sign with `codesign`, under the same identifier.
        let identifier = (binPath as NSString).lastPathComponent
        let signStatus = timings.measure("link", "codesign") {
            runProcess("/usr/bin/codesign", ["-s", "-", "-f", "-i", identifier, staging])
        }
        if signStatus != 0 {
            fputs("error: codesign failed for '\(binPath)'\n", stderr)
            return false
        }
    }
    guard rename(staging, binPath) == 0 else {
        fputs("error: cannot move the linked binary to '\(binPath)': \(String(cString: strerror(errno)))\n", stderr)
        return false
    }
    fputs(binPath + "\n", stderr)
    return true
}

// Compile the runtime C sources to objects and archive them into `libnomuruntime.a` (the
// `backend.md` "runtime library" item, real for the LLVM path). Replaces the C backend's
// per-file `cc` co-compile. Returns the archive path, or nil on failure (message on stderr).
// The runtime `.a` is identical across programs (the C floor is embedded in nomuc), so it lives in the
// per-host cache at the path the plan gives (D4), under a key over the embedded runtime sources, the host
// architecture and `runtimeArchiveRecipe` (`HostCache.runtimeArchiveKey`): editing the runtime rebuilds the
// compiler, which changes the key, and so does editing a command. A present archive is reused.
private func cachedRuntimeArchive(at cached: String) -> String? {
    let fm = FileManager.default
    let dir = (cached as NSString).deletingLastPathComponent
    if fm.fileExists(atPath: cached) { return cached }   // hit

    // Miss: build in a pid-unique scratch dir, then publish atomically under the content key so a
    // crash or a concurrent compile never leaves a partial archive at the shared path.
    let scratch = dir + "/build-\(ProcessInfo.processInfo.processIdentifier)"
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: scratch) }
    writeRuntimeSources(toDir: scratch)
    guard let built = buildRuntimeArchive(inDir: scratch) else { return nil }
    // `rename` replaces an archive another compile published meanwhile in one atomic step (same key, same
    // contents), so a concurrent link never finds the path missing.
    guard rename(built, cached) == 0 else {
        fputs("error: failed to publish runtime archive: \(String(cString: strerror(errno)))\n", stderr)
        return nil
    }
    return cached
}

// The commands that build the runtime archive, run in order in a directory holding the runtime sources
// (`writeRuntimeSources`). The plan hashes them into the archive's key, so changing one rebuilds the archive.
let runtimeArchiveRecipe: [[String]] = {
    var commands = [["/usr/bin/cc", "-w", "-I", ".", "-c", "runtime.c", "-o", "runtime.o"],
                    ["/usr/bin/cc", "-w", "-I", ".", "-c", "core.c", "-o", "core.o"]]
    var members = ["runtime.o", "core.o"]
    // The asm floor (task 128.2): assemble the per-arch `.s` (clang assembles `.s` directly) and archive
    // it beside the C objects, so its symbols (rtSwitch, rtFiberInit) resolve in every emitted binary.
    if HostCache.hostArch == "arm64" {
        commands.append(["/usr/bin/cc", "-c", "rtasm.s", "-o", "rtasm.o"])
        members.append("rtasm.o")
    }
    // `rcs` creates + indexes the archive; the directory is fresh, so no stale members accumulate.
    commands.append(["/usr/bin/ar", "rcs", "libnomuruntime.a"] + members)
    return commands
}()

private func buildRuntimeArchive(inDir dir: String) -> String? {
    for command in runtimeArchiveRecipe {
        if runProcess(command[0], Array(command.dropFirst()), in: dir) != 0 {
            fputs("error: failed to build the runtime archive: \(command.joined(separator: " "))\n", stderr)
            return nil
        }
    }
    return dir + "/libnomuruntime.a"
}

// Run `exe args` (in `dir` when given), wait, and return its exit status (or 1 if it could not be launched).
private func runProcess(_ exe: String, _ args: [String], in dir: String? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
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
    if HostCache.hostArch == "arm64" { files.append(("rtasm.s", EmbeddedSources.rtAsmArm64)) }
    for (name, contents) in files {
        guard (try? contents.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: failed to write runtime source '\(name)'\n", stderr)
            exit(1)
        }
    }
}
