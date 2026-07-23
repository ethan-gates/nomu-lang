import Foundation
import frontend
import codegen

public func compile(path: String, emit: EmitMode = .binary) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("error: cannot read '\(path)'\n", stderr)
        exit(1)
    }

    var lexer = Lexer(source, file: path)
    let tokens = lexer.tokenize()

    var parser = Parser(tokens)
    let program = parser.parse()

    // --emit-ast: dump the parsed tree and stop (pre-typecheck by design)
    if emit == .ast {
        print(dumpAST(program))
        return
    }

    // --dump-typed-ast: run the semantic pass and dump the typed IR (T1 debug view)
    if emit == .typedAST {
        var sema = Sema(program)
        let result = sema.check()
        checkExhaustiveness(result.module, into: result.diagnostics)
        if !result.diagnostics.isEmpty { fputs(result.diagnostics.render() + "\n", stderr) }
        print(dumpTypedIR(result.module))
        return
    }

    // POD + let/var checks stay in the AST typechecker; run before Sema (T2 §4).
    var checker = Typechecker(program)
    checker.check()

    var sema = Sema(program)
    let semaResult = sema.check()
    // T4: exhaustiveness as an IR pass over the typed module, into the same sink.
    checkExhaustiveness(semaResult.module, into: semaResult.diagnostics)
    if !semaResult.diagnostics.isEmpty {
        fputs(semaResult.diagnostics.render() + "\n", stderr)
        exit(1)
    }

    var gen = CodegenIR(semaResult.module)
    let cCode = gen.emit()

    if !gen.diagnostics.isEmpty {
        for d in gen.diagnostics { fputs("\(d)\n", stderr) }
        exit(1)
    }

    let base = URL(fileURLWithPath: path).deletingPathExtension().path

    if emit == .c {
        let cPath = base + ".c"
        guard (try? cCode.write(toFile: cPath, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: failed to write '\(cPath)'\n", stderr)
            exit(1)
        }
        print(cPath)
        return
    }

    let tmpC = NSTemporaryDirectory() + "nomu_\(UUID().uuidString).c"
    guard (try? cCode.write(toFile: tmpC, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write temp C file\n", stderr)
        exit(1)
    }
    defer { try? FileManager.default.removeItem(atPath: tmpC) }

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    // Warnings on generated C are noise to the Nomu user (inspect via -c instead).
    cc.arguments = ["-w", "-o", base, tmpC]
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

    print(base)
}
