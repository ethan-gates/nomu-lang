import Foundation
import ast
import support
import parse
import noir
import sema
import interface
import midend
import ssair
import ssairgen
import ssairpasses
import facts
import LLVMBridge
import embedded
import planner
import settings

// One module's compilation (task 190, 190.4): everything `compile(_:options:timings:)` reads and writes. The
// compile knows nothing beyond this value: no plan, workspaces, manifests or other modules' sources. Each
// dependency arrives as artifacts on disk.
public struct CompileJob: Codable {
    public enum Product: String, Codable { case library, binary }

    // A module this one can see: a direct import, a module a direct import re-exports, or a module whose
    // types a visible signature names. Its artifacts are read from disk.
    public struct Dependency: Codable {
        // The module's canonical identity (its mangling origin), e.g. `["nomu", "std", "prelude"]`.
        public let origin: [String]
        public let interface: String
        // Its shipped generic templates. Every library writes one, empty when it ships none; nil when they are
        // not offered.
        public let bir: String?
        // Its package, compared with the job's for `package` visibility.
        public let packageKey: String
        public init(origin: [String], interface: String, bir: String?, packageKey: String) {
            self.origin = origin; self.interface = interface; self.bir = bir; self.packageKey = packageKey
        }
    }

    // One import of one file, resolved to the dependency it names. Explicit imports appear in source order;
    // an implicit one (the implicit `import std`) has `isImplicit` and comes first.
    public struct Import: Codable {
        public let root: ImportRoot
        public let path: [String]
        public let alias: String?
        public let isPublic: Bool
        public let isTest: Bool
        public let isImplicit: Bool
        public let target: [String]
        public init(root: ImportRoot, path: [String], alias: String?, isPublic: Bool, isTest: Bool,
                    isImplicit: Bool, target: [String]) {
            self.root = root; self.path = path; self.alias = alias; self.isPublic = isPublic
            self.isTest = isTest; self.isImplicit = isImplicit; self.target = target
        }

        // `root` is encoded as the root package's name, absent for `pkg/…`.
        private enum CodingKeys: String, CodingKey { case root, path, alias, isPublic, isTest, isImplicit, target }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decodeIfPresent(String.self, forKey: .root)
            root = name.map { .package_($0) } ?? .pkg
            path = try c.decode([String].self, forKey: .path)
            alias = try c.decodeIfPresent(String.self, forKey: .alias)
            isPublic = try c.decode(Bool.self, forKey: .isPublic)
            isTest = try c.decode(Bool.self, forKey: .isTest)
            isImplicit = try c.decode(Bool.self, forKey: .isImplicit)
            target = try c.decode([String].self, forKey: .target)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if case .package_(let name) = root { try c.encode(name, forKey: .root) }
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(alias, forKey: .alias)
            try c.encode(isPublic, forKey: .isPublic)
            try c.encode(isTest, forKey: .isTest)
            try c.encode(isImplicit, forKey: .isImplicit)
            try c.encode(target, forKey: .target)
        }
    }

    // Where the job writes. `debugStem` names the debug views (`.noir`, `.ssair`, `.ll`, a terminal `.nmi`)
    // for the build's entry module; nil for every other job.
    public struct Outputs: Codable {
        public let object: String
        public let interface: String
        public let bir: String
        public let debugStem: String?
        public init(object: String, interface: String, bir: String, debugStem: String?) {
            self.object = object; self.interface = interface; self.bir = bir; self.debugStem = debugStem
        }
    }

    public var origin: [String]
    public var files: [String]
    public var packageName: String
    public var packageKey: String
    // May carry `public` declarations (its package lists it as a product).
    public var isProduct: Bool
    public var imports: [String: [Import]]
    public var dependencies: [Dependency]
    public var product: Product
    // Publish the white-box interface: some module in the build `test import`s this one.
    public var whiteBox: Bool
    // A module of the language workspace's `runtime` package: its functions are the runtime subset by
    // membership, and emit bare and weak.
    public var runtimeSubsetByMembership: Bool
    public var outputs: Outputs
    // The path to report for a file in `files` whose reported path differs from it: a language-workspace
    // `<nomu>/…` file's on-disk copy (Driver, `LanguageSourceCopy`). Diagnostics and debug info use it; the job
    // still reads the file by its `files` path. Nil or missing entries report the path itself.
    public var reportedPaths: [String: String]?
    // The path debug info records for each file in `files` (`DebugPaths`): independent of where the sources and
    // the host cache live, so an object is the same bytes from any checkout. Missing entries record the
    // reported path.
    public var debugPaths: [String: String]?
    // The settings this job receives, by name, in canonical form (G12): values only, never config names.
    public var settings: [String: String] = [:]

    public init(origin: [String], files: [String], packageName: String, packageKey: String, isProduct: Bool,
                imports: [String: [Import]], dependencies: [Dependency], product: Product, whiteBox: Bool,
                runtimeSubsetByMembership: Bool, outputs: Outputs) {
        self.origin = origin; self.files = files; self.packageName = packageName; self.packageKey = packageKey
        self.isProduct = isProduct; self.imports = imports; self.dependencies = dependencies
        self.product = product; self.whiteBox = whiteBox
        self.runtimeSubsetByMembership = runtimeSubsetByMembership; self.outputs = outputs
    }
}

// A job file (D9): one job and the options it compiles under, as `nomu compile` reads it.
public struct JobFile: Codable {
    public var job: CompileJob
    public var options: EmitOptions
    public init(job: CompileJob, options: EmitOptions) { self.job = job; self.options = options }

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? e.encode(self)
    }
    public static func decode(_ data: Data) throws -> JobFile { try JSONDecoder().decode(JobFile.self, from: data) }
}

// The job's dependencies, loaded: interfaces, escape summaries and template paths by origin key
// (`a/b/c`), and the views a module's checks need.
private struct LoadedDependencies {
    var interfaces: [String: ModuleInterface] = [:]
    var escape: [String: [String: EscapeSummary]] = [:]
    var bir: [String: String] = [:]
    var packageKey: [String: String] = [:]

    init?(_ job: CompileJob) {
        for d in job.dependencies {
            let key = d.origin.joined(separator: "/")
            guard let text = try? String(contentsOfFile: d.interface, encoding: .utf8), let nmi = parseNMI(text) else {
                fputs("error: cannot read the interface of '\(key)' at '\(d.interface)'\n", stderr)
                return nil
            }
            interfaces[key] = nmi.abi
            escape[key] = nmi.perf.escape
            packageKey[key] = d.packageKey
            if let b = d.bir {
                guard FileManager.default.fileExists(atPath: b) else {
                    fputs("error: missing the templates of '\(key)' at '\(b)'\n", stderr)
                    return nil
                }
                bir[key] = b
            }
        }
    }
}

// Compile one module. Returns false on a fatal diagnostic (reported on stderr).
public func compile(_ job: CompileJob, options: EmitOptions, timings: Timings) -> Bool {
    let originKey = job.origin.joined(separator: "/")
    guard let deps = LoadedDependencies(job) else { return false }

    // Parse the module's files (D8: each job parses its own module).
    let parseDiags = DiagnosticSink()
    var files: [SourceFile] = []
    for path in job.files {
        guard let text = readSource(path) else {
            fputs("error: cannot read '\(path)'\n", stderr); return false
        }
        let tokens = timings.measure("parse", "lex") { () -> [Token] in
            var lexer = Lexer(text, file: path, displayName: job.reportedPaths?[path], debugName: job.debugPaths?[path],
                              diagnostics: parseDiags)
            return lexer.tokenize()
        }
        timings.bytes += text.utf8.count
        timings.tokens += tokens.count
        let prog = timings.measure("parse", "parse") { () -> Program in
            var parser = Parser(tokens, diagnostics: parseDiags)
            return parser.parse()
        }
        files.append(SourceFile(path: path, decls: prog.decls, imports: prog.imports))
    }
    if parseDiags.hasErrors { fputs(parseDiags.render() + "\n", stderr); return false }

    // Each file's imports, paired with the job's resolution of them: the implicit ones first, then the
    // explicit ones in source order. A source import the job does not resolve is a build-system error.
    var resolved: [(decl: ImportDecl, imp: CompileJob.Import)] = []
    var importsByFile: [String: [(decl: ImportDecl, imp: CompileJob.Import)]] = [:]
    for i in files.indices {
        let f = files[i]
        let given = job.imports[f.path] ?? []
        let implicit = given.filter(\.isImplicit)
        let explicit = given.filter { !$0.isImplicit }
        guard explicit.count == f.imports.count,
              zip(explicit, f.imports).allSatisfy({ $0.path == $1.path && sameRoot($0.root, $1.root) }) else {
            fputs("error: the build's imports for '\(f.path)' do not match the file\n", stderr); return false
        }
        let firstMap = f.imports.first?.span.map
        var pairs = implicit.map { imp in
            (decl: ImportDecl(root: imp.root, path: imp.path, alias: imp.alias, isPublic: imp.isPublic,
                              isTest: imp.isTest, span: Span(startOffset: 0, endOffset: 0, map: firstMap)), imp: imp)
        }
        pairs += zip(f.imports, explicit).map { (decl: $0, imp: $1) }
        importsByFile[f.path] = pairs
        resolved += pairs
        files[i] = SourceFile(path: f.path, decls: f.decls, imports: pairs.map(\.decl))
    }

    var program = Program(decls: files.flatMap(\.decls), imports: files.flatMap(\.imports))
    // The pre-prelude, pre-merge surface — the interface + `.bir` own-name set are taken from it.
    let ownSurface = program

    // MARK: Visibility over the loaded dependencies

    func target(of decl: ImportDecl) -> String? {
        resolved.first { $0.decl.span.startOffset == decl.span.startOffset && $0.decl.span.map === decl.span.map
                         && $0.decl.path == decl.path }?.imp.target.joined(separator: "/")
    }
    // A module plus everything it re-exports via `public import`, transitively. The unit of "what importing
    // this module brings into scope."
    func reexportClosure(of dep: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        func walk(_ k: String) {
            guard seen.insert(k).inserted else { return }
            order.append(k)
            for r in deps.interfaces[k]?.reexports ?? [] { walk(r.modulePath.joined(separator: "/")) }
        }
        walk(dep)
        return order
    }
    // Each direct dependency plus its re-export closure. Deterministic order.
    let direct: [String] = {
        var seen = Set<String>()
        return resolved.map { $0.imp.target.joined(separator: "/") }.filter { seen.insert($0).inserted }.sorted()
    }()
    let visible: [String] = {
        var seen = Set<String>()
        var order: [String] = []
        for d in direct { for k in reexportClosure(of: d) where seen.insert(k).inserted { order.append(k) } }
        return order
    }()
    // The modules reached through a `test import` (white-box). The build guarantees each is same-package.
    let testTargets = Set(resolved.filter(\.imp.isTest).map { $0.imp.target.joined(separator: "/") })
    // Whether this module admits a producer-`k` declaration of visibility `v` across the module boundary.
    func admits(_ k: String, _ v: Visibility?) -> Bool {
        switch v ?? .public {
        case .public:   return true
        case .package:  return deps.packageKey[k] == job.packageKey
        case .internal: return testTargets.contains(k)
        case .private:  return false
        }
    }
    func admitted(_ iface: ModuleInterface, producer k: String) -> ModuleInterface {
        var out = iface
        out.functions = iface.functions.filter { admits(k, $0.visibility) }
        out.types = iface.types.filter { admits(k, $0.visibility) }
        out.enums = iface.enums.filter { admits(k, $0.visibility) }
        out.interfaces = iface.interfaces.filter { admits(k, $0.visibility) }
        return out
    }
    // The templates the visible dependencies ship; nil (reported) when an offered `.bir` cannot be read.
    func importedTemplates() -> [ImportedTemplate]? {
        var out: [ImportedTemplate] = []
        for k in visible {
            guard let path = deps.bir[k] else { continue }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), let decls = parseBIR(text) else {
                fputs("error: cannot read the templates of '\(k)' at '\(path)'\n", stderr)
                return nil
            }
            out.append(contentsOf: decls.map { ImportedTemplate(origin: k, decl: $0) })
        }
        return out
    }
    func externalEscape() -> [String: EscapeSummary] {
        var out: [String: EscapeSummary] = [:]
        for k in visible {
            guard let summ = deps.escape[k] else { continue }
            out.merge(externalEscapeKeys(summ, origin: k)) { a, _ in a }
        }
        return out
    }
    let moduleFuncs: [String: Set<String>] = deps.interfaces.reduce(into: [:]) { m, e in
        m[e.key] = Set(admitted(e.value, producer: e.key).functions.map(\.name))
    }
    let moduleTypes: [String: Set<String>] = deps.interfaces.reduce(into: [:]) { m, e in
        let adm = admitted(e.value, producer: e.key)
        m[e.key] = Set(adm.types.map(\.name)).union(adm.enums.map(\.name))
    }
    // Per-file import scope: the modules a file may reference bare, its qualifier bindings, and any leaf-name
    // collisions (two imports sharing a qualifier in one file).
    var fileVisible: [String: Set<String>] = [:]
    var fileQualifiers: [String: [String: Set<String>]] = [:]
    var leafCollisions: [(file: String, leaf: String, span: Span)] = []
    for f in files {
        var vis = Set<String>()
        var quals: [String: Set<String>] = [:]
        var seenLeaf = Set<String>()
        for (decl, imp) in importsByFile[f.path] ?? [] {
            let closure = reexportClosure(of: imp.target.joined(separator: "/"))
            vis.formUnion(closure)
            let q = decl.leafName
            if !seenLeaf.insert(q).inserted { leafCollisions.append((f.path, q, decl.span)) }
            quals[q, default: []].formUnion(closure)
        }
        fileVisible[f.path] = vis
        fileQualifiers[f.path] = quals
    }
    // The external declarations visible to this module, each rewritten to its per-origin identity
    // (`origin@name`), plus the types (only) a visible signature names from a module it does not import, so
    // values of them type-check while the names stay out of scope.
    func externals() -> [TopDecl] {
        func decls(of k: String) -> (decls: [TopDecl], foreign: [String: String]) {
            guard let iface = deps.interfaces[k] else { return ([], [:]) }
            let seen = admitted(iface, producer: k)
            let ownTypes = Set(seen.types.map(\.name)).union(seen.enums.map(\.name))
            let foreign = seen.foreignTypes ?? [:]
            return (interfaceToDecls(seen).map { encodeExternalDecl($0, origin: k, ownTypes: ownTypes, foreign: foreign) },
                    foreign)
        }
        var out: [TopDecl] = []
        var pending: [String] = []
        for k in visible {
            let d = decls(of: k)
            out += d.decls
            pending += d.foreign.values.sorted()
        }
        var loaded = Set(visible + [originKey])
        while let o = pending.popLast() {
            guard loaded.insert(o).inserted, deps.interfaces[o] != nil else { continue }
            let d = decls(of: o)
            out += d.decls.filter {
                switch $0 { case .structDecl, .classDecl, .enumDecl: return true; default: return false }
            }
            pending += d.foreign.values.sorted()
        }
        return out
    }
    // The origin of each foreign type this module's interface names: a signature type that is not one of its
    // own, exported by exactly one module its files import.
    func foreignTypeOrigins(_ iface: ModuleInterface) -> [String: String]? {
        let own = Set(iface.types.map(\.name)).union(iface.enums.map(\.name))
        let inScope = fileVisible.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var out: [String: String] = [:]
        for n in signatureTypeNames(iface) where !own.contains(n) {
            let origins = inScope.filter { moduleTypes[$0]?.contains(n) == true }
            if origins.count == 1, let o = origins.first { out[n] = o }
        }
        return out.isEmpty ? nil : out
    }
    // Imported methods inferred mutating in their producing module, keyed `origin@Type.method`.
    func externalMutating() -> Set<String> {
        var out: Set<String> = []
        for k in visible {
            guard let full = deps.interfaces[k] else { continue }
            let iface = admitted(full, producer: k)
            func add(_ typeName: String, _ methods: [InterfaceFunc], _ properties: [InterfaceProperty]) {
                let key = ExternalName.encode(origin: k, name: typeName)
                for mth in methods where mth.isMutating == true && !mth.isStatic { out.insert("\(key).\(mth.name)") }
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

    // MARK: Checks

    let dupDiags = DiagnosticSink()
    timings.measure("noir", "duplicates") { checkDuplicates(program, into: dupDiags) }
    checkVisibilityConsistency(program, into: dupDiags, isProduct: job.isProduct)
    reportLeafCollisions(leafCollisions, into: dupDiags)
    if dupDiags.hasErrors { fputs(dupDiags.render() + "\n", stderr); return false }

    // The `runtime` package designates its own functions runtime-subset by membership. White-box runtime
    // tests (`test.runtime_prelude`) prepend the runtime prelude so a user fixture can call runtime internals
    // by name; the definitions are bare weak-ODR, so they fold with the `runtime` package's own copies.
    let jobSettings = JobSettings(job.settings)
    let runtimeSubsetNames: Set<String>
    if job.runtimeSubsetByMembership {
        runtimeSubsetNames = Set(program.decls.compactMap { if case .funcDecl(let f) = $0 { return f.name } else { return nil } })
    } else if !options.compilingPrelude, jobSettings.bool("test.runtime_prelude") {
        (program, runtimeSubsetNames) = timings.measure("noir", "prelude") { prependRuntimePrelude(program) }
    } else {
        runtimeSubsetNames = []
    }
    let mergeDiags = DiagnosticSink()
    program = timings.measure("noir", "merge") { mergeExtensions(program, into: mergeDiags) }
    if mergeDiags.hasErrors { fputs(mergeDiags.render() + "\n", stderr); return false }

    let typeDiags = DiagnosticSink()
    timings.measure("noir", "typecheck") { var checker = Typechecker(program, diagnostics: typeDiags); checker.check() }
    if typeDiags.hasErrors { fputs(typeDiags.render() + "\n", stderr); return false }

    let subset = options.subsetFuncs.union(runtimeSubsetNames)
    let semaResult = timings.measure("noir", "sema") { () -> SemaResult in
        var sema = Sema(program, externalDecls: externals(), subsetFuncs: subset,
                        fileVisibleModules: fileVisible, fileQualifiers: fileQualifiers,
                        moduleFuncs: moduleFuncs, moduleTypes: moduleTypes,
                        externalMutatingMethods: externalMutating())
        let result = sema.check()
        checkExhaustiveness(result.module, into: result.diagnostics)
        return result
    }

    // NOIR debug view (entry only): --emit-noir writes it; --stop=noir writes it and halts.
    let debugStem = job.outputs.debugStem
    if let stem = debugStem, options.noir || options.stopAt == .noir {
        writeArtifact(dumpNOIR(semaResult.module), toFile: stem + ".noir")
    }
    if debugStem != nil && options.stopAt == .noir {
        if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr) }
        return true
    }
    if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr); return false }

    let factStore = collectFacts(semaResult.module)

    // The module's interface, from the pre-merge surface, carrying the inferred facts.
    let ownFiles = Set(job.files)
    var iface = buildInterface(ownSurface, package: job.packageName, modulePath: job.origin, ownFiles: ownFiles,
                               facts: factStore, whiteBox: job.whiteBox,
                               reexportModulePath: { imp in target(of: imp).map { $0.split(separator: "/").map(String.init) } })
    iface.foreignTypes = foreignTypeOrigins(iface)

    // `--emit-nmi` on the entry is terminal: it publishes the interface and stops.
    if let stem = debugStem, options.nmi {
        let perf = escapePerfSection(iface, semaResult.module, subsetFuncs: subset, external: externalEscape())
        writeArtifact(serialize(iface, perf: perf), toFile: stem + ".nmi")
        return true
    }
    // A library publishes its interface (with escape summaries, so a consumer seeds across the boundary) and
    // its shipped generic templates.
    if job.product == .library {
        let perf = timings.measure("interface", "escape") {
            escapePerfSection(iface, semaResult.module, subsetFuncs: subset, external: externalEscape())
        }
        let text = timings.measure("interface", "serialize") { serialize(iface, perf: perf) }
        guard timings.measure("interface", "write", {
            (try? text.write(toFile: job.outputs.interface, atomically: true, encoding: .utf8)) != nil
        }) else {
            fputs("error: cannot write '\(job.outputs.interface)'\n", stderr); return false
        }
    }
    let ownNames = topDeclNames(ownSurface)
    let shipped = canonicalizeForExport(shippedTemplates(semaResult.module, ownNames: ownNames),
                                        origin: originKey, ownNames: ownNames)
    // A library always writes its `.bir`, empty when it ships no templates, so a dependent can rely on it.
    if job.product == .library {
        guard (try? serializeBIR(shipped).write(toFile: job.outputs.bir, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: cannot write '\(job.outputs.bir)'\n", stderr); return false
        }
    }

    // Cross-module specialization: unless `opt.mono` is `none`, inject the generic templates visible
    // dependencies ship so the monomorphizer specializes the instances this module uses.
    let mono = MonoMode(rawValue: jobSettings.choice("opt.mono"))!
    var moduleForMono = semaResult.module
    var localizedGenerics: Set<String> = []
    if mono != .none {
        guard let templates = importedTemplates() else { return false }
        let selected = selectForDial(templates, mode: mono, consumer: moduleForMono)
        let injection = injectImportedTemplates(into: moduleForMono, templates: selected)
        moduleForMono = injection.module
        localizedGenerics = injection.localizedNames
    }
    let monoDiags = DiagnosticSink()
    let monoModule = timings.measure("noir", "mono") { monomorphize(moduleForMono, into: monoDiags) }
    if !monoDiags.isEmpty { fputs(monoDiags.render() + "\n", stderr); return false }

    if let stem = debugStem, options.ssair || options.stopAt == .ssair {
        let ssa = timings.measure("ssair", "gen") { lowerToSSAIR(monoModule) }
        writeArtifact(dumpSSAIR(ssa.module), toFile: stem + ".ssair")
        if options.stopAt == .ssair {
            if !ssa.diagnostics.isEmpty { fputs(ssa.diagnostics.render() + "\n", stderr) }
            return true
        }
    }

    let extFuncs = semaResult.externalFuncNames.subtracting(localizedGenerics)
    let extGenerics = semaResult.externalGenericSigs.filter { !localizedGenerics.contains($0.key) }

    // Codegen: gen SSAIR → inference (escape summaries) → emit. A binary owns the program-wide type maps and
    // bare names; a library emits a home-qualified object.
    let gen = timings.measure("ssair", "gen") { lowerToSSAIR(monoModule, subsetFuncs: subset) }
    if gen.diagnostics.hasErrors { fputs("error: SSAIR: " + gen.diagnostics.render() + "\n", stderr); return false }
    var store = factStore
    timings.measure("ssair", "inference") {
        let summaries = computeEscapeSummaries(gen.module.functions, aggregates: gen.module.aggregates)
        writeEscapeSummaries(summaries, into: &store)
    }
    // The `runtime` package emits its functions bare and weak-ODR (its files are the weak-origin set); an
    // ordinary module marks the embedded prelude file names weak, which matters only for a white-box
    // `test.runtime_prelude` prepend.
    let weakOrigins: Set<String> = job.runtimeSubsetByMembership ? ownFiles
        : options.compilingPrelude ? [] : [EmbeddedSources.preludeName, EmbeddedSources.runtimePreludeName]
    var optimizer = OptimizerSettings()
    optimizer.devirt = jobSettings.bool("opt.devirt")
    optimizer.inline = jobSettings.bool("opt.inline")
    optimizer.escape = jobSettings.bool("opt.escape")
    optimizer.scalar = jobSettings.bool("opt.scalar")
    optimizer.inlineAlloc = jobSettings.bool("opt.inline_alloc")
    switch jobSettings.choice("opt.escape_provider") {
    case "graph": optimizer.escapeProvider = .graph
    case "graph_precise": optimizer.escapeProvider = .graphPrecise
    default: optimizer.escapeProvider = .legacy
    }
    let err: String?
    if job.product == .binary {
        let emitLLVM = debugStem != nil && (options.llvm || options.stopAt == .llvm)
        err = emitObject(gen.module, from: monoModule, to: job.outputs.object, optimize: jobSettings.optimize,
                         onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                         emitLLVMTo: emitLLVM ? debugStem! + ".ll" : nil, stopAfterEgress: options.stopAt == .llvm,
                         externalFuncNames: extFuncs, externalGenericSigs: extGenerics,
                         weakOriginFiles: weakOrigins, homeModule: job.origin, facts: store, optimizer: optimizer)
        if err == nil, emitLLVM { fputs(debugStem! + ".ll\n", stderr) }
    } else {
        err = emitObject(gen.module, from: monoModule, to: job.outputs.object, optimize: jobSettings.optimize,
                         onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                         requireMain: false, externalFuncNames: extFuncs, externalGenericSigs: extGenerics,
                         weakOriginFiles: weakOrigins, emitTypeMaps: false,
                         homeModule: job.origin, facts: store, optimizer: optimizer)
    }
    if let err { fputs("error: \(err)\n", stderr); return false }
    return true
}

// A source file's text. A path under the language workspace's root (`<nomu>/…`) is served from the sources
// the compiler carries, so a job can name the language workspace's files in any process.
func readSource(_ path: String) -> String? {
    if path.hasPrefix(LanguageWorkspace.root + "/") {
        return LanguageWorkspace.tree.read(path).map { String(decoding: $0, as: UTF8.self) }
    }
    return try? String(contentsOfFile: path, encoding: .utf8)
}

private func sameRoot(_ a: ImportRoot, _ b: ImportRoot) -> Bool {
    switch (a, b) {
    case (.pkg, .pkg): return true
    case (.package_(let x), .package_(let y)): return x == y
    default: return false
    }
}
