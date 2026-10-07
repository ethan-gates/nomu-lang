import Foundation
import driver

var options = EmitOptions()
var files: [String] = []
var expectingOutputPath = false

for arg in CommandLine.arguments.dropFirst() {
    if expectingOutputPath {
        options.outputPath = arg
        expectingOutputPath = false
        continue
    }
    switch arg {
    case "--help", "-h":
        print("""
            usage: nomuc [options] <file.nomu> [more.nomu ...]

            Multiple files compile as one module, sharing a namespace.

            Emit flags are additive — each writes an artifact under build/ and reports
            its path; the binary is still produced unless --stop halts the pipeline.

            options:
              --emit-ast         also emit the parsed AST (<name>.ast)
              --emit-noir        also emit NOIR, the Nomu typed IR (<name>.noir)
              --emit-ssair       also emit SSAIR, the optimizer IR (<name>.ssair)
              --emit-nmi         also emit the module's public interface (<name>.nmi)
              --emit-llvm        also emit LLVM IR from the egress, pre-opt (<name>.ll)
              --stop=STAGE       halt after STAGE (ast | noir | ssair | llvm | binary); default binary
              -O, --release      optimize (LLVM -O2); default is a debug build
              --mono=MODE        cross-module specialization depth (none | edge | all);
                                 default follows the build: none for debug, all for release
              -o PATH            output binary path (artifacts derive from it); default under build/
              -h, --help         show this help
            """)
        exit(0)
    case "--emit-ast":         options.ast = true
    case "--emit-noir":        options.noir = true
    case "--emit-ssair":       options.ssair = true
    case "--emit-nmi":         options.nmi = true
    case "--emit-llvm":        options.llvm = true
    case "-O", "--release":    options.optimize = true
    case "-o":                 expectingOutputPath = true
    case let a where a.hasPrefix("-o="):
        options.outputPath = String(a.dropFirst("-o=".count))
    case let a where a.hasPrefix("--runtime-subset="):
        let names = String(a.dropFirst("--runtime-subset=".count)).split(separator: ",").map(String.init)
        options.subsetFuncs.formUnion(names)
    case let a where a.hasPrefix("--mono="):
        guard let mode = MonoMode(rawValue: String(a.dropFirst("--mono=".count))) else {
            fputs("error: unknown mode '\(String(a.dropFirst("--mono=".count)))' for --mono (expected none, edge, or all)\n", stderr)
            exit(1)
        }
        options.mono = mode
    case let a where a.hasPrefix("--stop="):
        switch String(a.dropFirst("--stop=".count)) {
        case "ast":     options.stopAt = .ast
        case "noir":    options.stopAt = .noir
        case "ssair":   options.stopAt = .ssair
        case "llvm":    options.stopAt = .llvm
        case "binary":  options.stopAt = .binary
        case let s:
            fputs("error: unknown stage '\(s)' for --stop (expected ast, noir, ssair, llvm, or binary)\n", stderr)
            exit(1)
        }
    default:
        guard !arg.hasPrefix("-") else {
            fputs("error: unknown flag '\(arg)'\n", stderr)
            exit(1)
        }
        files.append(arg)
    }
}

guard !expectingOutputPath else {
    fputs("error: -o requires a path argument\n", stderr)
    exit(1)
}

guard !files.isEmpty else {
    fputs("usage: nomuc [options] <file.nomu> [more.nomu ...]\n", stderr)
    exit(1)
}

compile(paths: files, options: options)
