import Foundation
import driver

// M6 · 6.1.0 — toolchain bring-up probe (temporary; removed once the real binding lands at 6.1.1).
// Binds the Rust GC-binding symbol so it links into the nomuc build; `--gc-probe` prints its
// sentinel to confirm the archive both linked and executes.
@_silgen_name("nomu_gc_probe")
func nomu_gc_probe() -> UInt64

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
              --emit-typedir     also emit the typed IR (<name>.typedir)
              --stop=STAGE       halt after STAGE (ast | typedir | binary); default binary
              -O, --release      optimize (LLVM -O2); default is a debug build
              -h, --help         show this help
            """)
        exit(0)
    case "--gc-probe":
        print(String(format: "0x%016llX", nomu_gc_probe()))
        exit(0)
    case "--emit-ast":         options.ast = true
    case "--emit-typedir":     options.typedIR = true
    case "-O", "--release":    options.optimize = true
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
