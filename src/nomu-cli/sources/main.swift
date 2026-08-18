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
              --emit-ast         also emit the parsed AST (<name>.ast)
              --emit-noir        also emit NOIR, the Nomu typed IR (<name>.noir)
              --emit-ssair       also emit SSAIR, the optimizer IR (<name>.ssair)
              --stop=STAGE       halt after STAGE (ast | noir | ssair | binary); default binary
              -O, --release      optimize (LLVM -O2); default is a debug build
              -h, --help         show this help
            """)
        exit(0)
    case "--emit-ast":         options.ast = true
    case "--emit-noir":        options.noir = true
    case "--emit-ssair":       options.ssair = true
    case "-O", "--release":    options.optimize = true
    case let a where a.hasPrefix("--stop="):
        switch String(a.dropFirst("--stop=".count)) {
        case "ast":     options.stopAt = .ast
        case "noir":    options.stopAt = .noir
        case "ssair":   options.stopAt = .ssair
        case "binary":  options.stopAt = .binary
        case let s:
            fputs("error: unknown stage '\(s)' for --stop (expected ast, noir, ssair, or binary)\n", stderr)
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
