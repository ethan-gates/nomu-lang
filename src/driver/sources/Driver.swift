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

    // The entry module flows through the full pipeline below (its emit/stop flags apply). Its
    // dependencies are compiled separately after the parse gate — modules are never merged into one
    // namespace (separate compilation, task 100.4.2).
    var program = Program(decls: (parsedByModule[entryID] ?? []).flatMap(\.decls),
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
        for (id, iface) in interfaces { m[id.components.joined(separator: "/")] = Set(iface.types.map(\.name)) }
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
            let ownTypes = Set(iface.types.map(\.name))
            return interfaceToDecls(parseInterface(serialize(iface)) ?? iface)
                .map { encodeExternalDecl($0, origin: origin, ownTypes: ownTypes) }
        }
    }
    for m in topo where m != entryID {
        let objPath = buildRoot + "/__mod_" + (m.components.isEmpty ? "root" : m.components.joined(separator: "_")) + ".o"
        let scopes = fileScopes(parsedByModule[m] ?? [])
        guard let iface = compileDependency(files: parsedByModule[m] ?? [], module: m,
                                            externalDecls: externals(of: m),
                                            fileVisibleModules: scopes.fileVisible, fileQualifiers: scopes.fileQualifiers,
                                            moduleFuncs: moduleFuncs(), moduleTypes: moduleTypes(),
                                            leafCollisions: scopes.leafCollisions,
                                            packageName: packageName,
                                            packageRoot: packageRoot, objPath: objPath, buildRoot: buildRoot,
                                            options: options, weakFiles: preludeFiles, timings: timings) else {
            timings.report(); exit(1)
        }
        interfaces[m] = iface
        depObjects.append(objPath)
    }
    let entryExternals = externals(of: entryID)
    let entryScopes = fileScopes(parsedByModule[entryID] ?? [])

    // Duplicate-symbol detection across the module's files (task 100.1.3) — before the prelude is
    // prepended, so it sees only the module's own declarations.
    let dupDiags = DiagnosticSink()
    timings.measure("noir", "duplicates") { checkDuplicates(program, into: dupDiags) }
    // Signature visibility consistency (task 100.2.5): a public/package signature may not expose a
    // lesser-visibility type — guards the public surface before it becomes an interface.
    checkVisibilityConsistency(program, into: dupDiags)
    reportLeafCollisions(entryScopes.leafCollisions, into: dupDiags)
    if dupDiags.hasErrors {
        fputs(dupDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // Prepend the Nomu standard library, compiled with every program (M4.13). Under
    // the single compilation unit this is a decl concatenation; prelude symbols are
    // then callable from user code with no import. (Times the prelude's own lex+parse.)
    let runtimeSubsetNames: Set<String>
    (program, runtimeSubsetNames) = timings.measure("noir", "prelude") { prependPrelude(program) }

    // Fold plain extensions into their target types before any checking (M4.12);
    // downstream passes then see one type with all its methods.
    let mergeDiags = DiagnosticSink()
    program = timings.measure("noir", "merge") { mergeExtensions(program, into: mergeDiags) }
    if mergeDiags.hasErrors {
        fputs(mergeDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // Semantic pass → typed IR. POD + let/var checks (AST typechecker) run first (T2 §4).
    let typeDiags = DiagnosticSink()
    timings.measure("noir", "typecheck") {
        var checker = Typechecker(program, diagnostics: typeDiags)
        checker.check()
    }
    if typeDiags.hasErrors {
        fputs(typeDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    let semaResult = timings.measure("noir", "sema") { () -> SemaResult in
        var sema = Sema(program, externalDecls: entryExternals, subsetFuncs: options.subsetFuncs.union(runtimeSubsetNames),
                        fileVisibleModules: entryScopes.fileVisible, fileQualifiers: entryScopes.fileQualifiers,
                        moduleFuncs: moduleFuncs(), moduleTypes: moduleTypes())
        let result = sema.check()
        // T4: exhaustiveness as an IR pass over the typed module, into the same sink.
        checkExhaustiveness(result.module, into: result.diagnostics)
        return result
    }

    // NOIR stage. --emit-noir writes NOIR to build/; --stop=noir
    // writes it and halts (reporting diagnostics without failing — it is a debug view).
    if options.noir || options.stopAt == .noir {
        writeArtifact(dumpNOIR(semaResult.module), toFile: stem + ".noir")
    }
    if options.stopAt == .noir {
        if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr) }
        timings.report()
        return
    }
    // Proceeding to codegen: semantic errors are now fatal.
    if !semaResult.diagnostics.isEmpty {
        fputs(semaResult.diagnostics.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // Module interface (`.nmi`) emission (task 100.4.1). Built from the checked public surface of the
    // entry module. Terminal — a library module need not have an entry point or link, so this returns
    // rather than proceeding to codegen.
    if options.nmi {
        let iface = buildInterface(program, package: packageName, module: entryID, packageRoot: packageRoot)
        writeArtifact(serialize(iface), toFile: stem + ".nmi")
        timings.report()
        return
    }

    // Monomorphization (M5 5.4): specialize every generic instantiation into concrete
    // decls (whole-program mono under the single compilation unit). An IR→IR pass; `any I`
    // stays dynamic. Runs only on error-free IR.
    let monoDiags = DiagnosticSink()
    let monoModule = timings.measure("noir", "mono") { monomorphize(semaResult.module, into: monoDiags) }
    if !monoDiags.isEmpty {
        fputs(monoDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // SSAIR stage (M7 · 7.2.4). --emit-ssair writes the optimizer IR (post-mono NOIR → SSAIR) to
    // build/; --stop=ssair writes it and halts. A debug view, so ssairgen diagnostics report without
    // failing. The backend lowers SSAIR itself (the sole egress); this is the standalone inspectable dump.
    if options.ssair || options.stopAt == .ssair {
        let ssa = timings.measure("ssair", "gen") { lowerToSSAIR(monoModule) }
        writeArtifact(dumpSSAIR(ssa.module), toFile: stem + ".ssair")
        if options.stopAt == .ssair {
            if !ssa.diagnostics.isEmpty { fputs(ssa.diagnostics.render() + "\n", stderr) }
            timings.report()
            return
        }
    }

    // Backend (M8): lower the typed IR via LLVM's C API → object → link with the runtime .a.
    // (The C backend was the differential oracle through 8.2 and was retired at the 8.2 exit.)
    emitLLVMBinary(monoModule, stem: stem, buildRoot: buildRoot, optimize: options.optimize,
                   subsetFuncs: options.subsetFuncs.union(runtimeSubsetNames), timings: timings,
                   emitLLVM: options.llvm || options.stopAt == .llvm, stopAfterLLVM: options.stopAt == .llvm,
                   extraObjects: depObjects, externalFuncNames: semaResult.externalFuncNames,
                   externalGenericSigs: semaResult.externalGenericSigs,
                   weakOriginFiles: preludeFiles)
    timings.report()
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
    let key = { ExternalName.encode(origin: origin, name: $0) }
    switch decl {
    case .funcDecl(let f):
        return .funcDecl(FuncDecl(name: key(f.name), generics: f.generics,
            params: f.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
            returnType: encT(f.returnType), body: f.body, isStatic: f.isStatic, visibility: f.visibility, span: f.span))
    case .structDecl(let s):
        return .structDecl(StructDecl(name: key(s.name), generics: s.generics,
            fields: s.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: s.properties, methods: s.methods, conformances: s.conformances, visibility: s.visibility, span: s.span))
    case .classDecl(let c):
        return .classDecl(ClassDecl(name: key(c.name), generics: c.generics,
            fields: c.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: c.properties, methods: c.methods, conformances: c.conformances, visibility: c.visibility, span: c.span))
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
private func compileDependency(files: [SourceFile], module: ModuleID, externalDecls: [TopDecl],
                               fileVisibleModules: [String: Set<String>],
                               fileQualifiers: [String: [String: Set<String>]],
                               moduleFuncs: [String: Set<String>], moduleTypes: [String: Set<String>],
                               leafCollisions: [(file: String, leaf: String, span: Span)],
                               packageName: String, packageRoot: String, objPath: String,
                               buildRoot: String, options: EmitOptions, weakFiles: Set<String>,
                               timings: Timings) -> ModuleInterface? {
    var program = Program(decls: files.flatMap(\.decls), imports: files.flatMap(\.imports))

    let dupDiags = DiagnosticSink()
    checkDuplicates(program, into: dupDiags)
    checkVisibilityConsistency(program, into: dupDiags)
    reportLeafCollisions(leafCollisions, into: dupDiags)
    if dupDiags.hasErrors { fputs(dupDiags.render() + "\n", stderr); return nil }

    let iface = buildInterface(program, package: packageName, module: module, packageRoot: packageRoot)

    let runtimeSubsetNames: Set<String>
    (program, runtimeSubsetNames) = prependPrelude(program)

    let mergeDiags = DiagnosticSink()
    program = mergeExtensions(program, into: mergeDiags)
    if mergeDiags.hasErrors { fputs(mergeDiags.render() + "\n", stderr); return nil }

    let typeDiags = DiagnosticSink()
    var checker = Typechecker(program, diagnostics: typeDiags)
    checker.check()
    if typeDiags.hasErrors { fputs(typeDiags.render() + "\n", stderr); return nil }

    var sema = Sema(program, externalDecls: externalDecls,
                    subsetFuncs: options.subsetFuncs.union(runtimeSubsetNames),
                    fileVisibleModules: fileVisibleModules, fileQualifiers: fileQualifiers,
                    moduleFuncs: moduleFuncs, moduleTypes: moduleTypes)
    let semaResult = sema.check()
    checkExhaustiveness(semaResult.module, into: semaResult.diagnostics)
    if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr); return nil }

    let monoDiags = DiagnosticSink()
    let monoModule = monomorphize(semaResult.module, into: monoDiags)
    if !monoDiags.isEmpty { fputs(monoDiags.render() + "\n", stderr); return nil }

    // A dependency's own symbols carry its module-path qualifier (task 100.4), so they cannot collide
    // with another module's same-named symbols at link.
    // Gen SSAIR in the driver so the stage sequence is explicit (task 165.1); `emitObject` lowers it.
    let gen = lowerToSSAIR(monoModule, subsetFuncs: options.subsetFuncs.union(runtimeSubsetNames))
    if gen.diagnostics.hasErrors { fputs("error: SSAIR: " + gen.diagnostics.render() + "\n", stderr); return nil }
    let err = emitObject(gen.module, from: monoModule, to: objPath, optimize: options.optimize,
                         requireMain: false, externalFuncNames: semaResult.externalFuncNames,
                         externalGenericSigs: semaResult.externalGenericSigs,
                         weakOriginFiles: weakFiles, emitTypeMaps: false,
                         homeQualifier: Mangle.qualifier(module: module.components))
    if let err = err { fputs("error: \(err)\n", stderr); return nil }
    return iface
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
                            weakOriginFiles: Set<String> = []) {
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
    let err = emitObject(gen.module, from: module, to: objPath, optimize: optimize,
                         onStage: { timings.record(phase: $0, name: $1, seconds: $2) },
                         emitLLVMTo: emitLLVM ? stem + ".ll" : nil, stopAfterEgress: stopAfterLLVM,
                         externalFuncNames: externalFuncNames, externalGenericSigs: externalGenericSigs,
                         weakOriginFiles: weakOriginFiles)
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
