import Foundation
import driver

var emit = EmitMode.binary
var file: String? = nil

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--help", "-h":
        print("""
            usage: nomuc [options] <file.nomu>

            options:
              -c, --emit-c       emit C source to <file>.c beside the source (no binary)
              --emit-ast         dump the parsed AST to stdout (pre-typecheck)
              --dump-typed-ast   dump the typed IR to stdout (after the semantic pass)
              -h, --help         show this help
            """)
        exit(0)
    case "--emit-ast":         emit = .ast
    case "--dump-typed-ast":   emit = .typedAST
    case "--emit-c", "-c":    emit = .c
    default:
        guard !arg.hasPrefix("-") else {
            fputs("error: unknown flag '\(arg)'\n", stderr)
            exit(1)
        }
        file = arg
    }
}

guard let path = file else {
    fputs("usage: nomuc [--emit-ast | -c] <file.nomu>\n", stderr)
    exit(1)
}

compile(path: path, emit: emit)
