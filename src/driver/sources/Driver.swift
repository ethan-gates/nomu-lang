import Foundation
import frontend
import codegen
import embedded

public func compile(path: String, options: EmitOptions = EmitOptions()) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("error: cannot read '\(path)'\n", stderr)
        exit(1)
    }

    var lexer = Lexer(source, file: path)
    let tokens = lexer.tokenize()

    var parser = Parser(tokens)
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
    if options.stopAt == .ast { return }

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
    var checker = Typechecker(program)
    checker.check()

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

    var gen = CodegenIR(monoModule)
    let cCode = gen.emit()

    if !gen.diagnostics.isEmpty {
        for d in gen.diagnostics { fputs("\(d)\n", stderr) }
        exit(1)
    }

    // Binary stage: the generated user code + the runtime sources, side by side; the
    // header resolves via -I on this dir. The .c persists as an inspectable intermediate.
    let userC = stem + ".c"
    writeRuntimeSources(toDir: outputDir)
    guard (try? cCode.write(toFile: userC, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write '\(userC)'\n", stderr)
        exit(1)
    }

    // Additive: --emit-c reports the generated C path; the binary is still produced.
    if options.c {
        print(userC)
    }

    let binPath = stem
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    // Warnings on generated C are noise to the Nomu user (inspect via -c instead).
    cc.arguments = ["-w", "-I", outputDir, "-o", binPath,
                    userC, outputDir + "/runtime.c", outputDir + "/core.c"]
    do {
        try cc.run()
        cc.waitUntilExit()
    } catch {
        fputs("error: failed to launch cc: \(error)\n", stderr)
        exit(1)
    }

    guard cc.terminationStatus == 0 else {
        fputs("error: cc failed\n", stderr)
        exit(1)
    }

    print(binPath)
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

// Lex + parse the embedded prelude and prepend its decls to the program (M4.13).
private func prependPrelude(_ program: Program) -> Program {
    var lexer = Lexer(EmbeddedSources.preludeSource, file: EmbeddedSources.preludeName)
    var parser = Parser(lexer.tokenize())
    let prelude = parser.parse()
    return Program(decls: prelude.decls + program.decls)
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
