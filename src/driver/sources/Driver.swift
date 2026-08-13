import Foundation
import frontend
import embedded
import LLVMBridge

public func compile(path: String, options: EmitOptions = EmitOptions()) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("error: cannot read '\(path)'\n", stderr)
        exit(1)
    }

    // Per-stage timing; reported to stderr on the way out (success or error).
    let timings = Timings()
    timings.file = path
    timings.optimize = options.optimize
    timings.bytes = source.utf8.count

    // Lexer and parser share one sink and collect errors rather than exiting on the first
    // (the no-crash contract — frontend/README.md P0); the driver is the exit boundary.
    let parseDiags = DiagnosticSink()
    let tokens = timings.measure("lex") { () -> [Token] in
        var lexer = Lexer(source, file: path, diagnostics: parseDiags)
        return lexer.tokenize()
    }
    timings.tokens = tokens.count

    var program = timings.measure("parse") { () -> Program in
        var parser = Parser(tokens, diagnostics: parseDiags)
        return parser.parse()
    }

    // Resolve the output location up front — every artifact lands under
    // <project-root>/build/, mirroring the source's path relative to the root (the
    // nearest ancestor holding a `nomu.yaml` marker, else the source's own directory).
    let input = URL(fileURLWithPath: path).standardizedFileURL
    let root = projectRoot(for: input)
    let outputDir = outputDirectory(for: input, root: root)
    let buildRoot = root.appendingPathComponent("build").path
    do {
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } catch {
        fputs("error: failed to create output dir '\(outputDir)': \(error)\n", stderr)
        exit(1)
    }
    let stem = outputDir + "/" + input.deletingPathExtension().lastPathComponent

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

    // Prepend the Nomu standard library, compiled with every program (M4.13). Under
    // the single compilation unit this is a decl concatenation; prelude symbols are
    // then callable from user code with no import. (Times the prelude's own lex+parse.)
    program = timings.measure("prelude") { prependPrelude(program) }

    // Fold plain extensions into their target types before any checking (M4.12);
    // downstream passes then see one type with all its methods.
    let mergeDiags = DiagnosticSink()
    program = timings.measure("merge") { mergeExtensions(program, into: mergeDiags) }
    if mergeDiags.hasErrors {
        fputs(mergeDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // Semantic pass → typed IR. POD + let/var checks (AST typechecker) run first (T2 §4).
    let typeDiags = DiagnosticSink()
    timings.measure("typecheck") {
        var checker = Typechecker(program, diagnostics: typeDiags)
        checker.check()
    }
    if typeDiags.hasErrors {
        fputs(typeDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    let semaResult = timings.measure("sema") { () -> SemaResult in
        var sema = Sema(program)
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

    // Monomorphization (M5 5.4): specialize every generic instantiation into concrete
    // decls (whole-program mono under the single compilation unit). An IR→IR pass; `any I`
    // stays dynamic. Runs only on error-free IR.
    let monoDiags = DiagnosticSink()
    let monoModule = timings.measure("mono") { monomorphize(semaResult.module, into: monoDiags) }
    if !monoDiags.isEmpty {
        fputs(monoDiags.render() + "\n", stderr)
        timings.report()
        exit(1)
    }

    // Backend (M8): lower the typed IR via LLVM's C API → object → link with the runtime .a.
    // (The C backend was the differential oracle through 8.2 and was retired at the 8.2 exit.)
    emitLLVMBinary(monoModule, stem: stem, buildRoot: buildRoot, optimize: options.optimize, timings: timings)
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

// Lex + parse the embedded prelude and prepend its decls to the program (M4.13). The
// prelude is trusted source, so a diagnostic here is a compiler bug, not user error.
private func prependPrelude(_ program: Program) -> Program {
    let preludeDiags = DiagnosticSink()
    var lexer = Lexer(EmbeddedSources.preludeSource, file: EmbeddedSources.preludeName, diagnostics: preludeDiags)
    var parser = Parser(lexer.tokenize(), diagnostics: preludeDiags)
    let prelude = parser.parse()
    if preludeDiags.hasErrors {
        fputs("internal error: failed to parse the embedded prelude\n" + preludeDiags.render() + "\n", stderr)
        exit(1)
    }
    return Program(decls: prelude.decls + program.decls)
}

// LLVM backend binary stage (8.1.4): emit a host object via the LLVM C API, build the runtime
// static archive, and link them into a native executable. Reports the binary path (like the C
// path). Everything LLVM stays behind `emitHelloWorldObject` in LLVMBridge — this only orchestrates
// object → .a → link.
private func emitLLVMBinary(_ module: NOIRModule, stem: String, buildRoot: String, optimize: Bool, timings: Timings) {
    let objPath = stem + ".o"
    // `codegen` is the whole LLVM path (IR lowering + transform passes + object emit) behind one
    // bridge call; splitting it needs timing hooks inside LLVMBridge (a follow-up).
    let err = timings.measure("codegen") { emitObject(module, to: objPath, optimize: optimize) }
    if let err = err {
        fputs("error: \(err)\n", stderr)
        timings.report()
        exit(1)
    }
    let archive = timings.measure("runtime") { cachedRuntimeArchive(buildRoot: buildRoot) }
    guard let archive = archive else { timings.report(); exit(1) }

    let binPath = stem
    // `-dead_strip` drops code unreachable from the program's entry — most of MMTk's plan/scheduler
    // machinery is never reached on the NoGC alloc path — and `-x` strips local symbols. (6.1.1 size.)
    var linkArgs = ["-o", binPath, "-Wl,-dead_strip", "-Wl,-x", objPath, archive]
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
    let linkStatus = timings.measure("link") { runProcess("/usr/bin/cc", linkArgs) }
    if linkStatus != 0 {
        fputs("error: link failed\n", stderr)
        timings.report()
        exit(1)
    }
    print(binPath)
}

// Compile the runtime C sources to objects and archive them into `libnomuruntime.a` (the
// `compiler.md` §6 "runtime library" item, real for the LLVM path). Replaces the C backend's
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
    mix(hostArch)
    mix("recipe-1")   // bump when the compile/archive commands below change
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
    // Rebuild from scratch so stale members never accumulate; `rcs` creates + indexes the archive.
    try? FileManager.default.removeItem(atPath: archive)
    if runProcess("/usr/bin/ar", ["rcs", archive, runtimeO, coreO]) != 0 {
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
    let files = [
        ("runtime.h", EmbeddedSources.runtimeHeader),
        ("runtime.c", EmbeddedSources.runtimeC),
        ("core.c",    EmbeddedSources.coreC),
    ]
    for (name, contents) in files {
        guard (try? contents.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: failed to write runtime source '\(name)'\n", stderr)
            exit(1)
        }
    }
}
