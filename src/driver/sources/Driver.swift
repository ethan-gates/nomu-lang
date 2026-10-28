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
import store

// Build a program from one module's files (task 190): plan the build, run each module's compile job in
// order, and link. The planner reads the workspaces, resolves every import and places every output (D2, D4);
// each job sees only its own inputs (`compile(_:options:timings:)`); the link takes every object the plan
// built plus the runtime archive. Every output goes where the plan puts it (D2, D4).
// What a build did: the binary it produced (nil on failure), and which module jobs it compiled and which it
// took from the host cache, in plan order (modules named `<scope>.<name>:<path>`).
public struct BuildResult {
    // The first target's binary (or output stem, for a stop before the link); nil on failure.
    public var binary: String? = nil
    // Every target's binary, in the targets' order (task 211).
    public var binaries: [String] = []
    public var compiled: [String] = []
    public var cached: [String] = []
    // Each module this build compiled, with why, compared with the last build (212).
    public var reasons: [(module: String, reason: String)] = []
    // The binaries this build linked and those it took from the host cache (214), and why each linked one did,
    // each binary workspace-relative.
    public var linked: [String] = []
    public var linkCached: [String] = []
    public var linkReasons: [(binary: String, reason: String)] = []
    // Under `--verify-cache`: each module whose cache entry differs from its fresh compile, with the key's
    // inputs.
    public var cacheMismatches: [String] = []
}

// Returns the entry's output stem (the binary, for a binary build); nil on failure.
public func buildProgram(paths: [String], options: EmitOptions = EmitOptions(),
                         selection: ConfigSelection = ConfigSelection()) -> String? {
    build(paths: paths, options: options, selection: selection).binary
}

public func build(paths: [String], options: EmitOptions = EmitOptions(),
                  selection: ConfigSelection = ConfigSelection()) -> BuildResult {
    build(targets: [paths], options: options, selection: selection)
}

// Build several targets, each given as one module's files, as one plan (task 211): a module they share compiles
// once, and each target links its own binary.
public func build(targets: [[String]], options: EmitOptions = EmitOptions(),
                  selection: ConfigSelection = ConfigSelection()) -> BuildResult {
    var result = BuildResult()
    guard let primary = targets.first(where: { !$0.isEmpty })?.first else {
        fputs("error: no source files given\n", stderr)
        return result
    }
    let timings = Timings()
    timings.egress = "ssair"

    var planOptions = PlanOptions()
    planOptions.allowCoreImport = options.allowCoreImport
    planOptions.runtimeRecipe = runtimeArchiveRecipe
    // The configuration resolves once, between reading the module table and planning.
    let workspaces = WorkspaceSet(entry: primary, disk: DiskTree(), includeLanguageWorkspace: planOptions.product == .binary)
    let moduleTable = ModuleTable(workspaces: workspaces, roots: targets, options: planOptions)
    var configuration: ResolvedBuildConfiguration? = nil
    if moduleTable.diagnostics.isEmpty {
        switch timings.measure("plan", "configuration", { resolveConfiguration(moduleTable, workspaces, selection) }) {
        case .success(let c):
            configuration = c
            planOptions.cacheRoot = HostCache.root(environment: ProcessInfo.processInfo.environment,
                                                   configured: c.cacheRoot, workspaceRoot: workspaces.root.root)
            timings.optimize = JobSettings(c.jobSettings(moduleTable.entry)).optimize
        case .failure(let errors):
            fputs(errors.rendered + "\n", stderr)
            timings.report()
            return result
        }
    }
    // The system tools' identities (`Toolchain`), for the runtime archive's key and each link's, recorded under
    // the cache root the configuration chose.
    let toolchain = timings.measure("plan", "toolchain") { Toolchain.identities(cacheRoot: planOptions.cacheRoot) }
    planOptions.runtimeToolchain = toolchain.filter { ["cc", "ar", "sdk"].contains($0.key) }
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
    let rootJobs = table.roots.compactMap { root in plan.jobs.first { $0.module == root } }
    guard rootJobs.count == table.roots.count else { return result }
    timings.package = table.modules[table.entry]?.package.name ?? ""
    timings.file = plan.jobs.count == 1 ? primary : "\(plan.jobs.count) modules"

    // One building invocation per workspace (210): held from the first write until the build returns.
    guard let lock = WorkspaceLock.acquire(workspaceRoot: workspaces.root.root) else { return result }
    defer { withExtendedLifetime(lock) {} }

    let buildRoot = workspaces.root.root + "/build"
    func makeDirectory(_ dir: String) -> Bool { Layout.makeDirectory(dir, buildRoot: buildRoot) }
    for r in rootJobs { guard makeDirectory(r.outputDir) else { return result } }

    // AST debug view of each target: --emit-ast writes it; --stop=ast writes it and halts.
    if options.ast || options.stopAt == .ast {
        var failed = false
        for r in rootJobs {
            let diags = DiagnosticSink()
            var decls: [TopDecl] = [], imports: [ImportDecl] = []
            for f in r.files {
                guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
                var lexer = Lexer(text, file: f, diagnostics: diags)
                var parser = Parser(lexer.tokenize(), diagnostics: diags)
                let prog = parser.parse()
                decls += prog.decls; imports += prog.imports
            }
            writeArtifact(dumpAST(Program(decls: decls, imports: imports)), toFile: r.binary + ".ast")
            if options.stopAt == .ast, !diags.isEmpty { fputs(diags.render() + "\n", stderr) }
            failed = failed || diags.hasErrors
        }
        if options.stopAt == .ast {
            if !failed { result.binary = rootJobs[0].binary }
            return result
        }
    }

    // A module's canonical identity (D6): its workspace's scope and name, then its path. Library symbols
    // mangle under it.
    func origin(_ k: ModuleKey) -> [String] { [k.workspace.scope, k.workspace.name] + k.path }
    // A package's key: its workspace and its root within the workspace, so it reads the same from any checkout.
    func packageKey(_ k: ModuleKey) -> String {
        let p = table.modules[k]!.package
        guard let wsRoot = plan.workspaceRoots[p.workspace], p.root == wsRoot || p.root.hasPrefix(wsRoot + "/") else {
            return "\(p.workspace)|\(p.root)"
        }
        return "\(p.workspace)|\(p.root.dropFirst(wsRoot.count))"
    }
    let jobByKey = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.module, $0) })
    // The language workspace's sources on disk, for reporting (diagnostics, debug info): kept current
    // whenever a build uses that workspace, compiled or cached.
    let sourceCopy = plan.jobs.contains(where: \.inLanguageWorkspace)
        ? timings.measure("plan", "source copy") { LanguageSourceCopy.ensure(cacheRoot: plan.cacheRoot) } : nil
    let store = HostCache.store(cacheRoot: plan.cacheRoot)
    let verification = options.verifyCache ? CacheVerification() : nil
    let keyer = JobKeyer()
    // The last-build record (212): every job's key, and under `--explain` its inputs, for the next build's reasons.
    var record = BuildRecord.load(buildRoot: buildRoot)
    defer { record.save(buildRoot: buildRoot) }
    var objects: [String] = []
    for j in plan.jobs {
        let m = table.modules[j.module]!
        let isRoot = table.roots.contains(j.module)
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
        let outputs = CompileJob.Outputs(object: j.object, interface: j.interface, bir: j.bir,
                                         debugStem: isRoot ? j.binary : nil)
        var job = CompileJob(origin: origin(j.module), files: j.files, packageName: m.package.name,
                             packageKey: packageKey(j.module), isProduct: m.isProduct, imports: imports,
                             dependencies: dependencies, product: j.product == .binary ? .binary : .library,
                             whiteBox: j.whiteBox, runtimeSubsetByMembership: j.runtimeSubsetByMembership,
                             outputs: outputs)
        if j.inLanguageWorkspace, let sourceCopy { job.reportedPaths = LanguageSourceCopy.reportedPaths(j.files, copy: sourceCopy) }
        if let wsRoot = plan.workspaceRoots[j.module.workspace] {
            job.debugPaths = DebugPaths.paths(j.files, workspace: j.module.workspace, workspaceRoot: wsRoot)
        }
        job.settings = configuration?.jobSettings(j.module) ?? [:]
        // The building workspace's modules take the build's options; another workspace's modules, and the
        // language workspace's, compile with the defaults.
        var jobOptions = EmitOptions()
        if j.module.workspace == table.entry.workspace { jobOptions = options }
        jobOptions.compilingPrelude = j.inLanguageWorkspace

        // The job's key, over everything it reads (208), and under `--explain` what its dependency inputs hold.
        let jobKey = keyer.key(job, options: jobOptions)
        let details = options.explain ? keyer.details(job) : nil
        let previous = record.modules[j.module.description]
        record.update(j.module.description, key: jobKey, details: details, explain: options.explain)

        // The files a job writes, by name within its output directory.
        let outputNames = j.product == .library ? [j.stem + ".o", j.stem + ".nmi", j.stem + ".bir"] : [j.stem + ".o"]
        guard makeDirectory(j.outputDir) else { return result }
        if options.emitJobs, let data = JobFile(job: job, options: jobOptions).encoded() {
            try? data.write(to: URL(fileURLWithPath: j.outputDir + "/" + j.stem + ".job.json"))
        }
        // A target asked for its debug views (`--emit-noir`, `--emit-llvm`, a `--stop`) compiles in place and
        // stays out of the store: the views are no output of the key, and a stop writes no object.
        let viewing = outputs.debugStem != nil
            && (jobOptions.noir || jobOptions.ssair || jobOptions.llvm || jobOptions.nmi || jobOptions.stopAt != .binary)

        // An entry at the job's key whose blobs match their digests is materialized into the job's output
        // directory and the compile skipped; a damaged one is discarded and rebuilt. Under `--verify-cache`
        // nothing is served: every job compiles.
        if !viewing, verification == nil, let cached = store.lookup(jobKey.key) {
            do { try store.materialize(cached, into: j.outputDir) } catch {
                fputs("error: \(error)\n", stderr)
                timings.report(); return result
            }
            objects.append(j.object)
            result.cached.append(j.module.description)
            continue
        }
        // The job compiles into a private scratch directory; its outputs reach `build/` by materializing the
        // published result, file by file through a rename, so a concurrent build of the same workspace never
        // reads a half-written output.
        let scratch = viewing ? nil
            : NSTemporaryDirectory() + "nomu-job-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        defer { if let scratch { try? FileManager.default.removeItem(atPath: scratch) } }
        var compiled = job
        if let scratch {
            guard makeDirectory(scratch) else { return result }
            compiled.outputs = CompileJob.Outputs(object: scratch + "/" + j.stem + ".o",
                                                  interface: scratch + "/" + j.stem + ".nmi",
                                                  bir: scratch + "/" + j.stem + ".bir", debugStem: outputs.debugStem)
        }
        let compileStart = Date()
        guard compile(compiled, options: jobOptions, timings: timings) else {
            timings.report(); return result
        }
        timings.compileSeconds += Date().timeIntervalSince(compileStart)
        result.reasons.append((j.module.description,
                               viewing ? "debug views asked for" : CompileReason.of(previous: previous, key: jobKey, details: details)))
        if let scratch {
            let published: ActionResult
            if let verification, let cached = store.lookup(jobKey.key) {
                // `--verify-cache`: the entry already at this key must hold what this compile produced.
                verification.compare(module: j.module.description, fresh: scratch, names: outputNames,
                                     cached: cached, store: store, inputs: jobKey.inputs)
                published = cached
            } else {
                // The entry records the job's key and module; its named inputs are computed when asked for
                // (`--verify-cache`).
                do {
                    published = try store.publish(jobKey.key, outputsIn: scratch, files: outputNames,
                                                  inputs: ["key": jobKey.key, "module": j.module.description])
                } catch {
                    fputs("error: \(error)\n", stderr)
                    timings.report(); return result
                }
            }
            do { try store.materialize(published, into: j.outputDir) } catch {
                fputs("error: \(error)\n", stderr)
                timings.report(); return result
            }
        }
        objects.append(j.object)
        result.compiled.append(j.module.description)
    }
    timings.jobs = (compiled: result.compiled.count, cached: result.cached.count)
    if options.explain && !result.reasons.isEmpty {
        let width = result.reasons.map(\.module.count).max()!
        var out = "nomu: why each module compiled\n"
        for (module, reason) in result.reasons {
            out += "  " + module.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + reason + "\n"
        }
        fputs(out, stderr)
    }
    // A cache entry that differs from its key's fresh compile fails the build before the link.
    if let verification, !verification.failures.isEmpty {
        result.cacheMismatches = verification.failures
        timings.report(); return result
    }

    // Each target links its binary from its objects and the runtime archive. A debug stop or a terminal
    // `--emit-nmi` ends the build before the link.
    if let archiveJob = plan.runtimeArchive, !options.nmi, options.stopAt == .binary {
        guard let configuration else { preconditionFailure("a planned build has a configuration") }
        let archive = timings.measure("runtime", "archive") { cachedRuntimeArchive(archiveJob, store: store) }
        guard let archive else { timings.report(); return result }
        // The debugger's map from recorded source paths to this machine's (`DebugPaths`), beside each binary.
        var sourceRoots: [(WorkspaceIdentity, String)] = []
        for (workspace, root) in plan.workspaceRoots {
            if workspace == LanguageWorkspace.identity { if let sourceCopy { sourceRoots.append((workspace, sourceCopy)) } }
            else { sourceRoots.append((workspace, root)) }
        }
        for link in plan.links {
            // The target's object links first (`LinkJob`): it owns the program-wide definitions (GC type and root
            // maps), which must win over any weak copy in a library object.
            let inputs = LinkInputs(objects: link.objects, runtimeArchive: archive,
                                    runtimeGlobals: configuration.runtimeGlobals, record: configuration.summary,
                                    debugInfoStorage: configuration.debugInfoStorage, output: link.output,
                                    workspaceRoot: workspaces.root.root, toolchain: toolchain)
            let binary = inputs.recorded(link.output)
            let linkKey = keyer.key(inputs)
            let previous = record.links[binary]
            record.updateLink(binary, key: linkKey, explain: options.explain)
            // A cached link, like a cached compile, is materialized at the binary's path; under `--verify-cache`
            // every binary links.
            if verification == nil, let cached = store.lookup(linkKey.key) {
                guard materializeLink(cached, store: store, output: link.output) else { timings.report(); return result }
                result.linkCached.append(binary)
            } else {
                let scratch = NSTemporaryDirectory() + "nomu-link-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: scratch) }
                guard let names = linkBinary(inputs, into: scratch, timings: timings) else {
                    timings.report(); return result
                }
                result.linkReasons.append((binary, CompileReason.of(previous: previous, key: linkKey, details: nil)))
                let published: ActionResult
                if let verification, let cached = store.lookup(linkKey.key) {
                    verification.compare(module: "link of " + binary, fresh: scratch, names: names, cached: cached,
                                         store: store, inputs: linkKey.inputs)
                    published = cached
                } else {
                    do {
                        published = try store.publish(linkKey.key, outputsIn: scratch, files: names,
                                                      inputs: ["key": linkKey.key, "binary": binary])
                    } catch {
                        fputs("error: \(error)\n", stderr)
                        timings.report(); return result
                    }
                }
                guard materializeLink(published, store: store, output: link.output) else { timings.report(); return result }
                result.linked.append(binary)
            }
            fputs(link.output + "\n", stderr)
            try? DebugPaths.lldbInit(sourceRoots).write(toFile: link.output + ".lldbinit", atomically: true, encoding: .utf8)
        }
        if options.explain && !result.linkReasons.isEmpty {
            var out = "nomu: why each binary linked\n"
            for (binary, reason) in result.linkReasons { out += "  \(binary)  \(reason)\n" }
            fputs(out, stderr)
        }
        // A cached binary that differs from its fresh link fails the build.
        if let verification, !verification.failures.isEmpty {
            result.cacheMismatches = verification.failures
            timings.report(); return result
        }
    }
    timings.report()
    result.binaries = rootJobs.map(\.binary)
    result.binary = result.binaries.first
    return result
}
