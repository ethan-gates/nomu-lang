import Foundation
import cli
import driver

// The `nomu` driver (task 173.5.1). Every entry is a subcommand; `compile` is the exposed primitive, the
// easy path is `build`/`run`/`test`/`query`. The command tree is declared here and parsed by `src/cli`;
// each subcommand owns its arguments, so compile's flags stay isolated from the orchestration flags.

let nomuVersion = "nomu 0.1.0-dev"

let tool = Command("nomu", summary: "The Nomu compiler and build driver.",
    subcommands: [
        Command("compile", summary: "compile source files into a binary (the primitive)",
            flags: [
                Flag("release", short: "O", help: "optimize (LLVM -O2); default is a debug build"),
                Flag("emit-ast", help: "also emit the parsed AST (<name>.ast)"),
                Flag("emit-noir", help: "also emit NOIR, the Nomu typed IR (<name>.noir)"),
                Flag("emit-ssair", help: "also emit SSAIR, the optimizer IR (<name>.ssair)"),
                Flag("emit-nmi", help: "also emit the module's public interface (<name>.nmi)"),
                Flag("emit-llvm", help: "also emit LLVM IR from the egress, pre-opt (<name>.ll)"),
            ],
            options: [
                Opt("output", short: "o", valueName: "path", help: "output binary path (artifacts derive from it)"),
                Opt("runtime-subset", valueName: "names", help: "functions compiled under the runtime subset",
                    isList: true, commaSplit: true),
                Opt("mono", valueName: "mode", help: "cross-module specialization depth",
                    choices: ["none", "edge", "all"]),
                Opt("stop", valueName: "stage", help: "halt after STAGE",
                    choices: ["ast", "noir", "ssair", "llvm", "binary"]),
            ],
            positionals: [Positional("files", help: "source files (one module)", variadic: true)]),
        Command("build", summary: "build a module or package",
            flags: [Flag("release", short: "O", help: "optimize (LLVM -O2); default is a debug build")],
            options: [Opt("mono", valueName: "mode", help: "cross-module specialization depth",
                          choices: ["none", "edge", "all"])],
            positionals: [Positional("targets", help: "module or package directories (default: .)",
                                     variadic: true, required: false)]),
        Command("run", summary: "build and run an executable module",
            flags: [Flag("release", short: "O", help: "optimize (LLVM -O2); default is a debug build")],
            options: [Opt("mono", valueName: "mode", help: "cross-module specialization depth",
                          choices: ["none", "edge", "all"])],
            positionals: [Positional("target", help: "executable module directory (default: .)",
                                     required: false)],
            passthrough: true),
        Command("test", summary: "build and run test modules",
            flags: [Flag("release", short: "O", help: "optimize (LLVM -O2); default is a debug build")],
            options: [Opt("mono", valueName: "mode", help: "cross-module specialization depth",
                          choices: ["none", "edge", "all"])],
            positionals: [Positional("target", help: "module, or package dir for its declared tests (default: .)",
                                     required: false)]),
        Command("query", summary: "print package metadata as JSON",
            positionals: [Positional("target", help: "module or package directory (default: .)",
                                     required: false)]),
    ])

switch parse(tool, Array(CommandLine.arguments.dropFirst()), version: nomuVersion) {
case .help(let text):
    print(text, terminator: "")
    exit(0)
case .version(let v):
    print(v)
    exit(0)
case .error(let message):
    fputs(message, stderr)
    exit(1)
case .run(let args):
    dispatch(args)
}

func dispatch(_ args: Parsed) {
    switch args.commandPath.last {
    case "compile":
        exit(runCompile(args) ? 0 : 1)
    case "build":
        exit(runBuild(args) ? 0 : 1)
    case "run":
        exit(runRun(args))
    case "test":
        exit(runTest(args) ? 0 : 1)
    case "query":
        exit(runQuery(args) ? 0 : 1)
    case let sub:
        fputs("nomu \(sub ?? "?"): not yet implemented\n", stderr)
        exit(1)
    }
}

// Translate the parsed `compile` arguments into `EmitOptions` and invoke the in-process primitive. Choice
// options (`--mono`, `--stop`) are already validated by the parser, so the rawValue conversions hold.
func runCompile(_ args: Parsed) -> Bool {
    var options = EmitOptions()
    options.optimize = args.has("release")
    options.ast = args.has("emit-ast")
    options.noir = args.has("emit-noir")
    options.ssair = args.has("emit-ssair")
    options.nmi = args.has("emit-nmi")
    options.llvm = args.has("emit-llvm")
    options.outputPath = args.value("output")
    options.subsetFuncs.formUnion(args.values("runtime-subset"))
    if let m = args.value("mono") { options.mono = MonoMode(rawValue: m) }
    if let s = args.value("stop") {
        switch s {
        case "ast":    options.stopAt = .ast
        case "noir":   options.stopAt = .noir
        case "ssair":  options.stopAt = .ssair
        case "llvm":   options.stopAt = .llvm
        default:       options.stopAt = .binary
        }
    }
    let files = args.positionals("files")
    guard !files.isEmpty else {
        fputs("error: no source files given\n", stderr)
        return false
    }
    return compile(paths: files, options: options)
}

// The build-shaped options (`-O`, `--mono`) shared by `build` and `run`.
func buildOptions(_ args: Parsed) -> EmitOptions {
    var options = EmitOptions()
    options.optimize = args.has("release")
    if let m = args.value("mono") { options.mono = MonoMode(rawValue: m) }
    return options
}

// `nomu build [targets…]` — resolve each target directory to a module and build it (default: the current
// directory). One module per target; `//path/...` expansion is the deferred label surface (173.5.2).
func runBuild(_ args: Parsed) -> Bool {
    let options = buildOptions(args)
    var targets = args.positionals("targets")
    if targets.isEmpty { targets = ["."] }
    var ok = true
    for target in targets where buildTarget(path: target, options: options) == nil { ok = false }
    return ok
}

// `nomu run [target] [-- args]` — build the target module (default: the current directory) and exec it,
// forwarding the post-`--` args and the exit status. A non-executable module (no `main`) fails the build.
func runRun(_ args: Parsed) -> Int32 {
    let target = args.positional("target") ?? "."
    return runTarget(path: target, args: args.passthrough, options: buildOptions(args))
}

// `nomu test [target]` — build and run test modules (default target: the current directory). A path
// resolves the same way `build`/`run` resolve it (a container package root runs its declared `tests` set).
// Each test module is a binary with white-box `test import` access; the case runner is task 161.
func runTest(_ args: Parsed) -> Bool {
    let target = args.positional("target") ?? "."
    return testPackage(target: target, options: buildOptions(args))
}

// `nomu query [target]` — print the package metadata (modules, dep edges, externals) as JSON on stdout.
func runQuery(_ args: Parsed) -> Bool {
    let target = args.positional("target") ?? "."
    return queryPackage(target: target)
}
