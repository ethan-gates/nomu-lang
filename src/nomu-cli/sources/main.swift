import Foundation
import cli
import driver

// The `nomu` driver (task 173.5.1). Every entry is a subcommand: `build`/`run`/`test`/`query` for people,
// and `compile`, the per-module job for tools that divide a build into processes (task 190, D9). The command
// tree is declared here and parsed by `src/cli`.

let nomuVersion = "nomu 0.1.0-dev"

// The flags and options every building command (`build`, `run`, `test`) takes. The debug views apply to the
// entry module; the hidden switches serve the test suite.
let buildFlags: [Flag] = [
    Flag("release", short: "O", help: "optimize (LLVM -O2); default is a debug build"),
    Flag("emit-ast", help: "also emit the entry module's parsed AST (<name>.ast)"),
    Flag("emit-noir", help: "also emit the entry module's NOIR, the Nomu typed IR (<name>.noir)"),
    Flag("emit-ssair", help: "also emit the entry module's SSAIR, the optimizer IR (<name>.ssair)"),
    Flag("emit-nmi", help: "emit the entry module's public interface (<name>.nmi) and stop"),
    Flag("emit-llvm", help: "also emit the entry module's LLVM IR from the egress, pre-opt (<name>.ll)"),
    Flag("allow-core-import", help: "let user code import the embedded `core` package (test suite only)",
         hidden: true),
    Flag("emit-jobs", help: "write each module's job file beside its outputs", hidden: true),
    Flag("report-jobs", help: "print each job as `compiled <module>` or `cached <module>`, then `binary <path>`",
         hidden: true),
]
let buildOptionList: [Opt] = [
    Opt("mono", valueName: "mode", help: "cross-module specialization depth", choices: ["none", "edge", "all"]),
    Opt("runtime-subset", valueName: "names", help: "functions compiled under the runtime subset",
        isList: true, commaSplit: true),
    Opt("stop", valueName: "stage", help: "halt after STAGE (`plan` prints the build plan)",
        choices: ["plan", "ast", "noir", "ssair", "llvm", "binary"]),
]

let tool = Command("nomu", summary: "The Nomu compiler and build driver.",
    subcommands: [
        Command("compile", summary: "compile one module from a job file (a tool interface; builds use `build`)",
            positionals: [Positional("job", help: "the job file: one module's inputs, outputs and options")]),
        Command("build", summary: "build a module or package",
            flags: buildFlags, options: buildOptionList,
            positionals: [Positional("targets", help: "module or package directories (default: .)",
                                     variadic: true, required: false)]),
        Command("run", summary: "build and run an executable module",
            flags: buildFlags, options: buildOptionList,
            positionals: [Positional("target", help: "executable module directory (default: .)",
                                     required: false)],
            passthrough: true),
        Command("test", summary: "build and run test modules",
            flags: buildFlags, options: buildOptionList,
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

// `nomu compile <job file>` — the per-module job (D9 of task 190): compile exactly one module from the
// inputs, outputs and options its job file names. No planning, discovery or linking.
func runCompile(_ args: Parsed) -> Bool {
    guard let path = args.positional("job") else { fputs("error: no job file given\n", stderr); return false }
    let file: JobFile
    do { file = try JobFile.decode(Data(contentsOf: URL(fileURLWithPath: path))) }
    catch { fputs("error: cannot read job file '\(path)': \(error)\n", stderr); return false }
    let timings = Timings()
    timings.optimize = file.options.optimize
    return compile(file.job, options: file.options, timings: timings)
}

// The options shared by `build`, `run` and `test`. Choice options (`--mono`, `--stop`) are already validated
// by the parser, so the rawValue conversions hold.
func buildOptions(_ args: Parsed) -> EmitOptions {
    var options = EmitOptions()
    options.optimize = args.has("release")
    options.ast = args.has("emit-ast")
    options.noir = args.has("emit-noir")
    options.ssair = args.has("emit-ssair")
    options.nmi = args.has("emit-nmi")
    options.llvm = args.has("emit-llvm")
    options.allowCoreImport = args.has("allow-core-import")
    options.emitJobs = args.has("emit-jobs")
    options.subsetFuncs.formUnion(args.values("runtime-subset"))
    if let m = args.value("mono") { options.mono = MonoMode(rawValue: m) }
    if let s = args.value("stop") { options.stopAt = Stage(rawValue: s) ?? .binary }
    return options
}

// `nomu build [targets…]` — resolve each target directory to a module and build it (default: the current
// directory). One module per target; `//path/...` expansion is the deferred label surface (173.5.2).
func runBuild(_ args: Parsed) -> Bool {
    let options = buildOptions(args)
    var targets = args.positionals("targets")
    if targets.isEmpty { targets = ["."] }
    var ok = true
    for target in targets {
        let r = buildTargetResult(path: target, options: options)
        if args.has("report-jobs") {
            for m in r.compiled { print("compiled \(m)") }
            for m in r.cached { print("cached \(m)") }
            if let b = r.binary { print("binary \(b)") }
        }
        if r.binary == nil { ok = false }
    }
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
