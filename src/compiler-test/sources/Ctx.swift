import Foundation

// Ctx — everything about the invocation: parsed CLI args, resolved paths (project root, the compiler),
// the loaded manifest, and the resolved case list. Immutable once built by `fromArgs`, so it is safe to
// share across the worker threads. Path derivation and case selection also live here, since both hang
// off the project root and the manifest.

let USAGE = """
    usage: compiler-test <config> [--enable a,b,*] [--disable a,b,*] [--deadline SEC]

    config           manifest path (required)
    --enable LIST    run only these cases (base becomes empty, then these are added)
    --disable LIST   run everything except these
    --deadline SEC   overall wall-clock backstop (default 300)
    --jobs N         pool capacity in cores (default: host cores − 2)

    LIST entries match a case name; `all` is the wildcard; a trailing `*` matches by prefix.
    The pool holds `--jobs` cores; a case occupies `weight` of them (its advertised core saturation —
    a carrier matrix peaks at its largest carrier count, a self-threading fixture at the runtime's 4),
    so concurrent work never oversubscribes the host. Every run is bounded.
    """

struct Ctx {
    let enableList: [String]
    let disableList: [String]
    let deadline: Double
    let poolCapacity: Int   // concurrent cores the run pool admits (host cores − buffer, or --jobs)
    let configPath: String
    let manifest: Manifest
    let projectRoot: String
    let nomuc: String
    let cases: [ResolvedCase]

    // base = all cases, or empty if --enable was given; add --enable; remove --disable.
    func selectedCases() -> [ResolvedCase] {
        cases.filter { c in
            let inBase = enableList.isEmpty
            return (inBase || anyMatch(c.name, enableList)) && !anyMatch(c.name, disableList)
        }
    }

    func fixturePath(_ fixture: String) -> String {
        (fixture as NSString).isAbsolutePath ? fixture : projectRoot + "/" + fixture
    }
    // Binary lands under <root>/build/<fixture dir>/<stem>, mirroring the compiler's output layout.
    func binaryPath(_ fixture: String) -> String {
        let dir = (fixture as NSString).deletingLastPathComponent
        var p = projectRoot + "/build"
        if !dir.isEmpty { p += "/" + dir }
        return p + "/" + fixtureStem(fixture)
    }
    func fixtureStem(_ fixture: String) -> String {
        ((fixture as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // A fixture that is a directory is one module (1 dir == 1 module): the harness passes its `.nomu`
    // files as the file list. A file fixture is a single-file module.
    func isModuleDir(_ fixture: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fixturePath(fixture), isDirectory: &isDir) && isDir.boolValue
    }
    // The module's source files, sorted for a deterministic command (and stable compile key).
    func moduleSources(_ fixture: String) -> [String] {
        let dir = fixturePath(fixture)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.filter { $0.hasSuffix(".nomu") }.sorted().map { dir + "/" + $0 }
    }
    // The compiler input arguments for a fixture: a module directory expands to an explicit `-o <bin>`
    // plus its source files; a single-file fixture is just its path.
    func compileInputs(_ fixture: String) -> [String] {
        isModuleDir(fixture) ? ["-o", binaryPath(fixture)] + moduleSources(fixture)
                             : [fixturePath(fixture)]
    }

    static func fromArgs() -> Ctx {
        let argv = Array(CommandLine.arguments.dropFirst())
        var configArg: String? = nil
        var enableList: [String] = []
        var disableList: [String] = []
        var deadline = 300.0   // suite-level wall-clock backstop (seconds)
        var jobs: Int? = nil   // pool capacity override; default derives from host cores below

        var i = 0
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--help", "-h":
                print(USAGE); exit(0)
            case "--enable":
                i += 1; guard i < argv.count else { die("--enable needs a list") }
                enableList += splitList(argv[i])
            case "--disable":
                i += 1; guard i < argv.count else { die("--disable needs a list") }
                disableList += splitList(argv[i])
            case "--deadline":
                i += 1; guard i < argv.count, let v = Double(argv[i]) else { die("--deadline needs a number") }
                deadline = v
            case "--jobs":
                i += 1; guard i < argv.count, let v = Int(argv[i]), v >= 1 else { die("--jobs needs a positive integer") }
                jobs = v
            case let f where f.hasPrefix("--jobs="):
                guard let v = Int(f.dropFirst("--jobs=".count)), v >= 1 else { die("--jobs needs a positive integer") }
                jobs = v
            case let f where f.hasPrefix("--enable="):
                enableList += splitList(String(f.dropFirst("--enable=".count)))
            case let f where f.hasPrefix("--disable="):
                disableList += splitList(String(f.dropFirst("--disable=".count)))
            case let f where f.hasPrefix("--deadline="):
                guard let v = Double(f.dropFirst("--deadline=".count)) else { die("--deadline needs a number") }
                deadline = v
            case let f where f.hasPrefix("-"):
                die("unknown flag '\(f)'")
            default:
                guard configArg == nil else { die("unexpected extra argument '\(a)'") }
                configArg = a
            }
            i += 1
        }

        guard let configPath = configArg else { die("no config given — specify a manifest path\n\n" + USAGE) }
        let manifest: Manifest
        do { manifest = try loadManifest(configPath) }
        catch { die("failed to read manifest \(configPath): \(error)") }

        let root = findProjectRoot()
        // Default the pool to the host's cores minus a small buffer (the harness's own I/O / timer threads
        // and each running test's idle main/GC threads), so the sum of concurrently-running cases' advertised
        // weights never oversubscribes the CPU — oversubscription starves the cooperative scheduler/STW and
        // wedges a run. `--jobs` overrides.
        let capacity = jobs ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        return Ctx(enableList: enableList, disableList: disableList, deadline: deadline,
                   poolCapacity: capacity, configPath: configPath, manifest: manifest, projectRoot: root,
                   nomuc: resolveNomuc(projectRoot: root), cases: manifest.resolvedCases(capacity: capacity))
    }
}

// Walk up from the current directory for the nomu.yaml marker (same root the compiler uses).
private func findProjectRoot() -> String {
    var dir = FileManager.default.currentDirectoryPath
    while true {
        if FileManager.default.fileExists(atPath: dir + "/nomu.yaml") { return dir }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return FileManager.default.currentDirectoryPath
}

// Resolve nomuc once, preferring a release (opt) build of the compiler. bazel writes an opt build under
// bazel-out/<platform>-opt/bin/… ; the bazel-bin symlink only points there if the last build was
// -c opt, so we look for the opt config directly (platform-agnostic, no bazel subprocess). Order:
// COMPILER_TEST_NOMUC override → newest -opt build → bazel-bin (with a warning that it may be debug).
private func resolveNomuc(projectRoot: String) -> String {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["COMPILER_TEST_NOMUC"] {
        guard fm.fileExists(atPath: override) else { die("COMPILER_TEST_NOMUC=\(override) does not exist") }
        return override
    }
    let bazelOut = projectRoot + "/bazel-out"
    let rel = "/bin/src/nomu-cli/nomuc"
    if let entries = try? fm.contentsOfDirectory(atPath: bazelOut) {
        let optBins = entries.filter { $0.hasSuffix("-opt") }
            .map { bazelOut + "/" + $0 + rel }
            .filter { fm.fileExists(atPath: $0) }
        if let newest = optBins.max(by: { mtime($0) < mtime($1) }) { return newest }   // newest opt build wins
    }
    let fallback = projectRoot + "/bazel-bin/src/nomu-cli/nomuc"
    guard fm.fileExists(atPath: fallback) else {
        die("nomuc not found — build it (bazel build -c opt //src/nomu-cli:nomuc) or set COMPILER_TEST_NOMUC")
    }
    FileHandle.standardError.write(Data(
        "note: no release (-c opt) nomuc found; using bazel-bin (may be a debug build). For faster compiles: bazel build -c opt //src/nomu-cli:nomuc\n".utf8))
    return fallback
}

func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
private func matches(_ name: String, _ token: String) -> Bool {
    if token == "all" { return true }
    if token.hasSuffix("*") { return name.hasPrefix(String(token.dropLast())) }
    return name == token
}
private func anyMatch(_ name: String, _ tokens: [String]) -> Bool { tokens.contains { matches(name, $0) } }
