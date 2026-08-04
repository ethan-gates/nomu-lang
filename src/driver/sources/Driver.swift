import Foundation
import frontend
import embedded
import LLVMBridge

public func compile(path: String, options: EmitOptions = EmitOptions()) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("error: cannot read '\(path)'\n", stderr)
        exit(1)
    }

    // Lexer and parser share one sink and collect errors rather than exiting on the first
    // (the no-crash contract — frontend/README.md P0); the driver is the exit boundary.
    let parseDiags = DiagnosticSink()
    var lexer = Lexer(source, file: path, diagnostics: parseDiags)
    let tokens = lexer.tokenize()

    var parser = Parser(tokens, diagnostics: parseDiags)
    var program = parser.parse()

    // Resolve the output location up front — every artifact lands under
    // <project-root>/build/, mirroring the source's path relative to the root (the
    // nearest ancestor holding a `nomu.yaml` marker, else the source's own directory).
    let input = URL(fileURLWithPath: path).standardizedFileURL
    let outputDir = outputDirectory(for: input, root: projectRoot(for: input))
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
        exit(1)
    }

    // Prepend the Nomu standard library, compiled with every program (M4.13). Under
    // the single compilation unit this is a decl concatenation; prelude symbols are
    // then callable from user code with no import.
    program = prependPrelude(program)

    // Fold plain extensions into their target types before any checking (M4.12);
    // downstream passes then see one type with all its methods.
    let mergeDiags = DiagnosticSink()
    program = mergeExtensions(program, into: mergeDiags)
    if mergeDiags.hasErrors {
        fputs(mergeDiags.render() + "\n", stderr)
        exit(1)
    }

    // Semantic pass → typed IR. POD + let/var checks (AST typechecker) run first (T2 §4).
    let typeDiags = DiagnosticSink()
    var checker = Typechecker(program, diagnostics: typeDiags)
    checker.check()
    if typeDiags.hasErrors {
        fputs(typeDiags.render() + "\n", stderr)
        exit(1)
    }

    var sema = Sema(program)
    let semaResult = sema.check()
    // T4: exhaustiveness as an IR pass over the typed module, into the same sink.
    checkExhaustiveness(semaResult.module, into: semaResult.diagnostics)

    // Typed-IR stage. --emit-typedir writes the typed IR to build/; --stop=typedir
    // writes it and halts (reporting diagnostics without failing — it is a debug view).
    if options.typedIR || options.stopAt == .typedIR {
        writeArtifact(dumpTypedIR(semaResult.module), toFile: stem + ".typedir")
    }
    if options.stopAt == .typedIR {
        if !semaResult.diagnostics.isEmpty { fputs(semaResult.diagnostics.render() + "\n", stderr) }
        return
    }
    // Proceeding to codegen: semantic errors are now fatal.
    if !semaResult.diagnostics.isEmpty {
        fputs(semaResult.diagnostics.render() + "\n", stderr)
        exit(1)
    }

    // Monomorphization (M5 5.4): specialize every generic instantiation into concrete
    // decls (whole-program mono under the single compilation unit). An IR→IR pass; `any I`
    // stays dynamic. Runs only on error-free IR.
    let monoDiags = DiagnosticSink()
    let monoModule = monomorphize(semaResult.module, into: monoDiags)
    if !monoDiags.isEmpty {
        fputs(monoDiags.render() + "\n", stderr)
        exit(1)
    }

    // Backend (M8): lower the typed IR via LLVM's C API → object → link with the runtime .a.
    // (The C backend was the differential oracle through 8.2 and was retired at the 8.2 exit.)
    emitLLVMBinary(monoModule, stem: stem, outputDir: outputDir, optimize: options.optimize)
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
private func emitLLVMBinary(_ module: IRModule, stem: String, outputDir: String, optimize: Bool) {
    let objPath = stem + ".o"
    if let err = emitObject(module, to: objPath, optimize: optimize) {
        fputs("error: \(err)\n", stderr)
        exit(1)
    }
    writeRuntimeSources(toDir: outputDir)
    guard let archive = buildRuntimeArchive(inDir: outputDir) else { exit(1) }

    let binPath = stem
    if runProcess("/usr/bin/cc", ["-o", binPath, objPath, archive]) != 0 {
        fputs("error: link failed\n", stderr)
        exit(1)
    }
    print(binPath)
}

// Compile the runtime C sources to objects and archive them into `libnomuruntime.a` (the
// `compiler.md` §6 "runtime library" item, real for the LLVM path). Replaces the C backend's
// per-file `cc` co-compile. Returns the archive path, or nil on failure (message on stderr).
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
