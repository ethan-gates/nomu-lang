import Foundation

// Ctx — everything about the invocation: parsed CLI args, resolved paths (project root, the compiler),
// the loaded manifest, and the resolved case list. Immutable once built by `fromArgs`, so it is safe to
// share across the worker threads. Path derivation and case selection also live here, since both hang
// off the project root and the manifest.

let USAGE = """
    usage: compiler-test <config> [--enable a,b,*] [--disable a,b,*] [--where axis=value,…] [--tier fast|full]
                         [--repeat N] [--compiler PATH] [--deadline SEC] [--jobs N]

    config           manifest path (required)
    --enable LIST    run only these cases (base becomes empty, then these are added)
    --disable LIST   run everything except these
    --where LIST     run only group runs with these dimension values (axis=value, comma-separated)
    --tier T         the tier to run: fast (default) or full (fast plus the expensive legs)
    --repeat N       run the selection N times and report each case's pass rate (for flakes)
    --compiler PATH  the nomu to test (default: the newest release build)
    --deadline SEC   overall wall-clock backstop (default 300; scaled by --repeat)
    --jobs N         pool capacity in cores (default: host cores − 2)

    LIST entries match a case name; `all` is the wildcard; a trailing `*` matches by prefix. A group run is
    named group/fixture/value/… (e.g. shape/local_string/debug/stress-minor).
    The pool holds `--jobs` cores; a case occupies `weight` of them (its advertised core saturation —
    a carrier matrix peaks at its largest carrier count, a self-threading fixture at the runtime's 4),
    so concurrent work never oversubscribes the host. Every run is bounded.
    """

struct Ctx {
    let enableList: [String]
    let disableList: [String]
    let whereList: [(String, String)]   // dimension → value filters (`--where`)
    let tier: Tier
    let repeatCount: Int
    let deadline: Double
    let poolCapacity: Int   // concurrent cores the run pool admits (host cores − buffer, or --jobs)
    let configPath: String
    let manifest: Manifest
    let projectRoot: String
    let nomu: String
    let cases: [ResolvedCase]

    // The tier's cases; base = all of them, or empty if --enable was given; add --enable; remove --disable;
    // keep only group runs matching every --where.
    func selectedCases() -> [ResolvedCase] {
        cases.filter { c in
            let inBase = enableList.isEmpty
            return c.tier <= tier
                && (inBase || anyMatch(c.name, enableList)) && !anyMatch(c.name, disableList)
                && whereList.allSatisfy { c.dims[$0.0] == $0.1 }
        }
    }

    // Whether the selection is the whole tier (no name or dimension filter): only then does a run rewrite
    // the persisted order.
    var selectsWholeTier: Bool { enableList.isEmpty && disableList.isEmpty && whereList.isEmpty }

    // Where a configuration's binary is kept: each (fixture, compile settings) gets its own directory under
    // `build/compiler-test/`, so builds of one fixture under different settings never share a path. The
    // compile phase copies the binary (and its object) here after each build.
    func configBinaryPath(_ c: ResolvedCase) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in c.compileKey.utf8 { h ^= UInt64(b); h = h &* 0x00000100000001B3 }
        let slug = c.fixture.replacingOccurrences(of: "/", with: "_")
        let leaf = (binaryPath(c.fixture) as NSString).lastPathComponent
        return projectRoot + "/build/compiler-test/" + slug + "-" + String(h, radix: 16) + "/" + leaf
    }

    func fixturePath(_ fixture: String) -> String {
        (fixture as NSString).isAbsolutePath ? fixture : projectRoot + "/" + fixture
    }
    // Binary lands in the fixture module's own build directory, named after the module, under the build/
    // of the workspace holding it (its nearest `nomu.yaml`): <workspace>/build/<module path>/<leaf> (the
    // compiler's layout, task 190 D2).
    func binaryPath(_ fixture: String) -> String {
        let dir = fixturePath(fixture)
        var ws = dir
        while ws != "/" && !FileManager.default.fileExists(atPath: ws + "/nomu.yaml") {
            ws = (ws as NSString).deletingLastPathComponent
        }
        if ws == "/" { ws = projectRoot }
        let rel = dir == ws ? "" : String(dir.dropFirst(ws.count + 1))
        let leaf = rel.isEmpty ? fixtureStem(fixture) : (rel as NSString).lastPathComponent
        return ws + "/build/" + (rel.isEmpty ? "" : rel + "/") + leaf
    }
    func fixtureStem(_ fixture: String) -> String {
        ((fixture as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // The build target for a fixture: its module directory (`nomu build <dir>`; the compiler names and
    // places the binary).
    func compileInputs(_ fixture: String) -> [String] { [fixturePath(fixture)] }

    static func fromArgs() -> Ctx {
        let argv = Array(CommandLine.arguments.dropFirst())
        var configArg: String? = nil
        var enableList: [String] = []
        var disableList: [String] = []
        var whereList: [(String, String)] = []
        var tier = Tier.fast
        var repeatCount = 1
        var compiler: String? = nil
        var deadline = 300.0   // suite-level wall-clock backstop (seconds)
        var jobs: Int? = nil   // pool capacity override; default derives from host cores below

        func parseValued(_ flag: String, _ v: String) {
            switch flag {
            case "--where":
                for item in splitList(v) {
                    let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { die("--where takes axis=value, got '\(item)'") }
                    whereList.append((parts[0], parts[1]))
                }
            case "--tier":
                guard let t = Tier(rawValue: v) else { die("--tier takes fast or full") }
                tier = t
            case "--repeat":
                guard let n = Int(v), n >= 1 else { die("--repeat needs a positive integer") }
                repeatCount = n
            default:
                compiler = v
            }
        }

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
            case "--where", "--tier", "--repeat", "--compiler":
                i += 1; guard i < argv.count else { die("\(a) needs a value") }
                parseValued(a, argv[i])
            case let f where f.hasPrefix("--where=") || f.hasPrefix("--tier=") || f.hasPrefix("--repeat=")
                || f.hasPrefix("--compiler="):
                let eq = f.firstIndex(of: "=")!
                parseValued(String(f[..<eq]), String(f[f.index(after: eq)...]))
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
        let cases = manifest.resolvedCases(capacity: capacity, projectRoot: root, tier: tier)
        let axes = Set(manifest.dimensions?.keys.map { $0 } ?? [])
        for (axis, value) in whereList {
            guard axes.contains(axis) else { die("--where: unknown dimension '\(axis)'") }
            guard manifest.dimensions![axis]!.contains(where: { $0.name == value }) else {
                die("--where: dimension '\(axis)' has no value '\(value)'")
            }
        }
        return Ctx(enableList: enableList, disableList: disableList, whereList: whereList, tier: tier,
                   repeatCount: repeatCount, deadline: deadline * Double(repeatCount),
                   poolCapacity: capacity, configPath: configPath, manifest: manifest, projectRoot: root,
                   nomu: resolveNomu(projectRoot: root, override: compiler), cases: cases)
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

// Resolve the `nomu` compiler once, preferring a release (opt) build. bazel writes an opt build under
// bazel-out/<platform>-opt/bin/… ; the bazel-bin symlink only points there if the last build was
// -c opt, so we look for the opt config directly (platform-agnostic, no bazel subprocess). Order:
// --compiler → newest -opt build → bazel-bin (with a warning that it may be debug).
private func resolveNomu(projectRoot: String, override: String?) -> String {
    let fm = FileManager.default
    if let path = override {
        guard fm.fileExists(atPath: path) else { die("--compiler \(path) does not exist") }
        return (path as NSString).isAbsolutePath ? path : fm.currentDirectoryPath + "/" + path
    }
    let bazelOut = projectRoot + "/bazel-out"
    let rel = "/bin/src/nomu-cli/nomu"
    if let entries = try? fm.contentsOfDirectory(atPath: bazelOut) {
        let optBins = entries.filter { $0.hasSuffix("-opt") }
            .map { bazelOut + "/" + $0 + rel }
            .filter { fm.fileExists(atPath: $0) }
        if let newest = optBins.max(by: { mtime($0) < mtime($1) }) { return newest }   // newest opt build wins
    }
    let fallback = projectRoot + "/bazel-bin/src/nomu-cli/nomu"
    guard fm.fileExists(atPath: fallback) else {
        die("nomu not found — build it (bazel build -c opt //src/nomu-cli:nomu) or pass --compiler")
    }
    FileHandle.standardError.write(Data(
        "note: no release (-c opt) nomu found; using bazel-bin (may be a debug build). For faster compiles: bazel build -c opt //src/nomu-cli:nomu\n".utf8))
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
