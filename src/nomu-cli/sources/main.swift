import Foundation
import driver

var options = EmitOptions()
var file: String? = nil

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--help", "-h":
        print("""
            usage: nomuc [options] <file.nomu>

            Emit flags are additive — each writes an artifact under build/ and reports
            its path; the binary is still produced unless --stop halts the pipeline.

            options:
              -c, --emit-c       also emit the generated C (<name>.c)
              --emit-ast         also emit the parsed AST (<name>.ast)
              --emit-typedir     also emit the typed IR (<name>.typedir)
              --stop=STAGE       halt after STAGE (ast | typedir | binary); default binary
              --backend=NAME     code path to the binary (c | llvm); default c
              -h, --help         show this help
            """)
        exit(0)
    case "--emit-ast":         options.ast = true
    case "--emit-typedir":     options.typedIR = true
    case "--emit-c", "-c":     options.c = true
    case let a where a.hasPrefix("--backend="):
        switch String(a.dropFirst("--backend=".count)) {
        case "c":    options.backend = .c
        case "llvm": options.backend = .llvm
        case let s:
            fputs("error: unknown backend '\(s)' for --backend (expected c or llvm)\n", stderr)
            exit(1)
        }
    case let a where a.hasPrefix("--stop="):
        switch String(a.dropFirst("--stop=".count)) {
        case "ast":     options.stopAt = .ast
        case "typedir": options.stopAt = .typedIR
        case "binary":  options.stopAt = .binary
        case let s:
            fputs("error: unknown stage '\(s)' for --stop (expected ast, typedir, or binary)\n", stderr)
            exit(1)
        }
    default:
        guard !arg.hasPrefix("-") else {
            fputs("error: unknown flag '\(arg)'\n", stderr)
            exit(1)
        }
        file = arg
    }
}

guard let path = file else {
    fputs("usage: nomuc [options] <file.nomu>\n", stderr)
    exit(1)
}

compile(path: path, options: options)
