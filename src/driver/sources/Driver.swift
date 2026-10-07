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

public func compile(paths: [String], options: EmitOptions = EmitOptions()) {
    guard let primary = paths.first else {
        fputs("error: no source files given\n", stderr)
        exit(1)
    }

    // Per-stage timing; reported to stderr on the way out (success or error).
    let timings = Timings()
    timings.optimize = options.optimize
    // The backend egress is the SSAIR tier (the sole path since M7.7 retired the NOIR tree-walk);
    // named in the timing header for context.
    timings.egress = "ssair"

    // The package root anchors mechanical `pkg/…` addressing (nearest `nomu.yaml` ancestor, else the
    // entry's own directory — the interim marker until the manifest lands, task 100.3).
    let input = URL(fileURLWithPath: primary).standardizedFileURL
    let root = projectRoot(for: input)
    let packageRoot = root.path

    // The package identity comes from the manifest (`pkg.json` at the root), or a default when there is
    // none. It anchors mangling and `.nmi` naming (consumed from task 100.2.6 on). A present-but-invalid
    // manifest is fatal.
    let manifest: Manifest?
    do { manifest = try loadManifest(packageRoot: packageRoot) }
    catch { fputs("error: \(error)\n", stderr); exit(1) }
    let packageName = manifest?.name ?? defaultPackageName
    timings.package = packageName

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
    var totalBytes = 0, tokenCount = 0

    let entryID = moduleID(forFile: primary, packageRoot: packageRoot)
    seenModule.insert(entryID); graph.addNode(entryID)
    var worklist: [(id: ModuleID, files: [String])] = [(entryID, paths)]
    while !worklist.isEmpty {
        let (modID, files) = worklist.removeFirst()
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                fputs("error: cannot read '\(file)'\n", stderr)
                exit(1)
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
            parsedByModule[modID, default: []].append(SourceFile(path: file, decls: prog.decls, imports: prog.imports))
            for imp in prog.imports {
                guard let dir = resolvePkgImportDir(imp, packageRoot: packageRoot) else { continue }
                let depID = moduleID(forDir: dir, packageRoot: packageRoot)
                graph.addEdge(from: modID, to: depID)
                if seenModule.insert(depID).inserted {
                    let depFiles = scanModuleFiles(dir)
                    if depFiles.isEmpty {
                        parseDiags.error("no module found at 'pkg/\(imp.path.joined(separator: "/"))'", at: imp.span)
                    } else {
                        worklist.append((depID, depFiles))
                    }
                }
            }
        }
    }
    timings.bytes = totalBytes
    timings.tokens = tokenCount
    timings.file = seenModule.count == 1 ? primary : "\(seenModule.count) modules"

    // A module import cycle is fatal (design: acyclic module graph). Reported before merging.
    if case .failure(.cycle(let ring)) = graph.topologicalOrder() {
        fputs("error: module import cycle: " + ring.map(\.pathString).joined(separator: " → ") + "\n", stderr)
        timings.report()
        exit(1)
    }

    // The entry module's raw parse, for the --emit-ast debug view below (the per-module pipeline rebuilds
    // its own program from `parsedByModule`). Modules are never merged into one namespace (separate
    // compilation, task 100.4.2).
    let program = Program(decls: (parsedByModule[entryID] ?? []).flatMap(\.decls),
                          imports: (parsedByModule[entryID] ?? []).flatMap(\.imports))
    let buildRoot = root.appendingPathComponent("build").path
    // The artifact stem: `-o <path>` gives it explicitly (its parent is created); otherwise it mirrors
    // the primary source's path under `build/`. All artifacts append an extension to the stem, and the
    // binary is the stem itself.
    let stem: String
    let outputDir: String
    if let out = options.outputPath {
        stem = out
        outputDir = URL(fileURLWithPath: out).deletingLastPathComponent().path
    } else {
        outputDir = outputDirectory(for: input, root: root)
        stem = outputDir + "/" + input.deletingPathExtension().lastPathComponent
    }
    do {
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } catch {
        fputs("error: failed to create output dir '\(outputDir)': \(error)\n", stderr)
        exit(1)
    }

    // AST stage. Emit flags write a build/ artifact and report its path (the "emit"
    // style, like --emit-c) — nothing goes to stdout. --emit-ast writes the raw user
    // parse (pre-prelude); --stop=ast writes it and halts.
    if options.ast || options.stopAt == .ast {
        writeArtifact(dumpAST(program), toFile: stem + ".ast")
    }
    if options.stopAt == .ast {
        if !parseDiags.isEmpty { fputs(parseDiags.render() + "\n", stderr) }
        return
    }
    // Lex/parse errors are fatal to compilation — the recovered AST has holes, so the
    // later phases would report noise. Report the collected diagnostics and stop here.
    if parseDiags.hasErrors {
        fputs(parseDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
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
        for dep in graph.dependencies(of: m) {
            for k in reexportClosure(of: dep) where seen.insert(k).inserted { order.append(k) }
        }
        return order
    }
    // The imported generic templates visible to `m` (task 100.5.4): each visible dependency's shipped
    // `.bir` (task 100.5.1), parsed back to NOIR decls. A dependency with no `.bir` (no public generics),
    // or an unreadable / version-stale one, contributes nothing — that import then stays on the erased
    // witness path. Deterministic in `visibleModules` order.
    func importedTemplates(of m: ModuleID) -> [ImportedTemplate] {
        var out: [ImportedTemplate] = []
        for k in visibleModules(of: m) {
            let birPath = buildRoot + "/__mod_" + (k.components.isEmpty ? "root" : k.components.joined(separator: "_")) + ".bir"
            guard let text = try? String(contentsOfFile: birPath, encoding: .utf8),
                  let decls = parseBIR(text) else { continue }
            let origin = k.components.joined(separator: "/")
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
            out.merge(externalEscapeKeys(summ, origin: k.components.joined(separator: "/"))) { a, _ in a }
        }
        return out
    }
    // The function / type names each currently-known module exports, keyed by module path. Feed per-file
    // resolution + collision handling (tasks 100.2.3.1/100.2.3.2), separately by kind so a name can be
    // resolved as the right kind at a func vs type use site.
    func moduleFuncs() -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for (id, iface) in interfaces { m[id.components.joined(separator: "/")] = Set(iface.functions.map(\.name)) }
        return m
    }
    func moduleTypes() -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for (id, iface) in interfaces { m[id.components.joined(separator: "/")] = Set(iface.types.map(\.name)).union(iface.enums.map(\.name)) }
        return m
    }
    // Per-file import scope. Imports are file-scoped (task 100.2.3.1), so a symbol is bare-visible only in
    // a file that imports its origin module. Returns, per file, the module paths it may reference bare
    // (each import plus its re-export closure) and the qualifier bindings for qualified access
    // (task 100.2.3.2), plus any leaf-name collisions (two imports sharing a qualifier in one file).
    func fileScopes(_ files: [SourceFile]) -> (fileVisible: [String: Set<String>],
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
                guard let dir = resolvePkgImportDir(imp, packageRoot: packageRoot) else { continue }
                let closure = reexportClosure(of: moduleID(forDir: dir, packageRoot: packageRoot))
                    .map { $0.components.joined(separator: "/") }
                vis.formUnion(closure)
                let q = imp.leafName
                if !seenLeaf.insert(q).inserted { leafCollisions.append((f.path, q, imp.span)) }
                quals[q, default: []].formUnion(closure)
            }
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
        visibleModules(of: m).flatMap { k -> [TopDecl] in
            guard let iface = interfaces[k] else { return [] }
            let origin = k.components.joined(separator: "/")
            let ownTypes = Set(iface.types.map(\.name)).union(iface.enums.map(\.name))
            return interfaceToDecls(parseInterface(serialize(iface)) ?? iface)
                .map { encodeExternalDecl($0, origin: origin, ownTypes: ownTypes) }
        }
    }
    // Imported methods inferred mutating in their producing module, keyed `origin@Type.method` to match
    // the consumer's call-site key (task 100.4.3.5.2). Sourced from each visible dependency's `.nmi`
    // (`InterfaceFunc.isMutating`); drives the consumer's mutable-receiver check + self-by-pointer ABI.
    func externalMutating(of m: ModuleID) -> Set<String> {
        var out: Set<String> = []
        for k in visibleModules(of: m) {
            guard let iface = interfaces[k] else { continue }
            let origin = k.components.joined(separator: "/")
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
        let scopes = fileScopes(files)

        // Duplicate-symbol / visibility / leaf-collision checks (tasks 100.1.3 / 100.2.5), before the
        // prelude is prepended so they see only the module's own declarations.
        let dupDiags = DiagnosticSink()
        timings.measure("noir", "duplicates") { checkDuplicates(program, into: dupDiags) }
        checkVisibilityConsistency(program, into: dupDiags)
        reportLeafCollisions(scopes.leafCollisions, into: dupDiags)
        if dupDiags.hasErrors { fputs(dupDiags.render() + "\n", stderr); return false }

        // Prelude (M4.13) + plain-extension merge (M4.12).
        let runtimeSubsetNames: Set<String>
        (program, runtimeSubsetNames) = timings.measure("noir", "prelude") { prependPrelude(program) }
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
                            moduleFuncs: moduleFuncs(), moduleTypes: moduleTypes(),
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
        let iface = buildInterface(ownSurface, package: packageName, module: id, packageRoot: packageRoot, facts: factStore)
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
            : buildRoot + "/__mod_" + (id.components.isEmpty ? "root" : id.components.joined(separator: "_")) + ".o"

        // Ship this module's `.bir` (public generic closure, references canonicalized to origin-keyed
        // names) so a dependent under `--mono` specializes the generics it imports (tasks 100.5.1 / 100.5.4).
        let ownNames = topDeclNames(ownSurface)
        let shipped = canonicalizeForExport(shippedTemplates(semaResult.module, ownNames: ownNames),
                                            origin: id.components.joined(separator: "/"), ownNames: ownNames)
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
        // home-qualified object only (no entry point, no program-wide type maps).
        if isRoot {
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
        let err = emitObject(gen.module, from: monoModule, to: objPath, optimize: options.optimize,
                             onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                             requireMain: false, externalFuncNames: extFuncs, externalGenericSigs: extGenerics,
                             weakOriginFiles: preludeFiles, emitTypeMaps: false,
                             homeQualifier: Mangle.qualifier(module: id.components), facts: store)
        if let err = err { fputs("error: \(err)\n", stderr); return false }
        depObjects.append(objPath)
        return true
    }

    // Compile every module in dependency order (leaves first); the entry module — the binary — is last and
    // links. Separate compilation (task 100.4.2): a module sees a dependency only through its interface.
    for m in topo {
        guard compileModule(m, isRoot: m == entryID) else { timings.report(); exit(1) }
    }
    timings.report()
}

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

// Write a text artifact to `path` (or exit) and report its path — the "emit" style,
// consistent with --emit-c: outputs are build/ files, not stdout.
private func writeArtifact(_ contents: String, toFile path: String) {
    guard (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write '\(path)'\n", stderr)
        exit(1)
    }
    print(path)
}

// The project root: the nearest ancestor of `input` containing a `nomu.yaml` marker;
// if none exists up to the filesystem root, the input's own directory. The output
// root is <project-root>/build/. (More rules — config, explicit flags — come later.)
private func projectRoot(for input: URL) -> URL {
    let fm = FileManager.default
    var dir = input.deletingLastPathComponent().standardizedFileURL
    while true {
        if fm.fileExists(atPath: dir.appendingPathComponent("nomu.yaml").path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }   // reached the filesystem root
        dir = parent
    }
    return input.deletingLastPathComponent().standardizedFileURL
}

// <root>/build/<input's directory relative to root>. Equal dirs yield <root>/build.
private func outputDirectory(for input: URL, root: URL) -> String {
    let inputDir = input.deletingLastPathComponent().standardizedFileURL.path
    var rel = inputDir.hasPrefix(root.path) ? String(inputDir.dropFirst(root.path.count)) : ""
    while rel.hasPrefix("/") { rel.removeFirst() }
    let build = root.appendingPathComponent("build").path
    return rel.isEmpty ? build : build + "/" + rel
}

// Lex + parse the embedded preludes and prepend their decls to the program (M4.13). Two preludes,
// both trusted source (a diagnostic here is a compiler bug): the **core** prelude (`core.nomu` — Option,
// Result, numeric helpers) and the **runtime** prelude (`runtime.nomu` — the self-hosted runtime tier,
// task 150). Every function in the runtime prelude is runtime-subset by default (task 149) — its names
// are returned so the subset checker treats them as designated, the interim "designated file" until the
// module system (task 100) lands.
private func prependPrelude(_ program: Program) -> (Program, Set<String>) {
    func parseEmbedded(_ source: String, _ name: String) -> Program {
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
    let core = parseEmbedded(EmbeddedSources.preludeSource, EmbeddedSources.preludeName)
    let runtime = parseEmbedded(EmbeddedSources.runtimePreludeSource, EmbeddedSources.runtimePreludeName)
    let runtimeSubset = Set(runtime.decls.compactMap { decl -> String? in
        if case .funcDecl(let f) = decl { return f.name }
        return nil
    })
    return (Program(decls: core.decls + runtime.decls + program.decls, imports: program.imports), runtimeSubset)
}

// Rewrite an imported declaration to its per-origin identity (`origin@name`, task 100.2.3.2), and any
// type reference inside it that names one of the module's own exported types to that type's identity.
private func encodeExternalDecl(_ decl: TopDecl, origin: String, ownTypes: Set<String>) -> TopDecl {
    func encT(_ r: TypeRef?) -> TypeRef? {
        guard let r = r else { return nil }
        let nm = ownTypes.contains(r.name) ? ExternalName.encode(origin: origin, name: r.name) : r.name
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
    func isPublic(_ t: ImportedTemplate) -> Bool {
        if case .funcDecl(let f) = t.decl { return f.visibility == .public }
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
    func isPublic(_ decl: NOIRDecl) -> Bool {
        if case .funcDecl(let f) = decl { return f.visibility == .public }
        return false
    }
    func isGeneric(_ decl: NOIRDecl) -> Bool {
        if case .funcDecl(let f) = decl { return !f.generics.isEmpty }
        return false
    }
    var shippedNames = Set<String>()
    var shipped: [NOIRDecl] = []
    var worklist: [NOIRDecl] = []
    // Seed: every public generic function.
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
    if emitLLVM { print(stem + ".ll") }
    if stopAfterLLVM { return }
    let archive = timings.measure("runtime", "archive") { cachedRuntimeArchive(buildRoot: buildRoot) }
    guard let archive = archive else { timings.report(); exit(1) }

    let binPath = stem
    // `-dead_strip` drops code unreachable from the program's entry — most of MMTk's plan/scheduler
    // machinery is never reached on the NoGC alloc path — and `-x` strips local symbols. (6.1.1 size.)
    // Dependency objects (separate compilation, task 100.4.2) link alongside the entry object.
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
    print(binPath)
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
