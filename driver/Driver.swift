import Foundation
import frontend
import codegen

public func compile(path: String, emit: EmitMode = .binary) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("error: cannot read '\(path)'\n", stderr)
        exit(1)
    }

    var lexer = Lexer(source)
    let tokens = lexer.tokenize()

    var parser = Parser(tokens)
    let program = parser.parse()

    // --emit-ast: dump the parsed tree and stop (pre-typecheck by design)
    if emit == .ast {
        print(dumpAST(program))
        return
    }

    var checker = Typechecker(program)
    checker.check()

    var gen = Codegen(program)
    let cCode = gen.emit()

    // --emit-c: print generated C and stop
    if emit == .c {
        print(cCode)
        return
    }

    // Default: write to temp file, compile with cc
    let tmpC = NSTemporaryDirectory() + "nomu_\(UUID().uuidString).c"
    guard (try? cCode.write(toFile: tmpC, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write temp C file\n", stderr)
        exit(1)
    }
    defer { try? FileManager.default.removeItem(atPath: tmpC) }

    let outPath = URL(fileURLWithPath: path).deletingPathExtension().path

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-o", outPath, tmpC]
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

    print("\(outPath)")
}
