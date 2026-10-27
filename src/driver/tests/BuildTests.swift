import XCTest
import Foundation
import store

// Builds of real suite fixtures with the `nomu` binary (190.5.2): each module compiles once per build, the
// host cache serves the language workspace on the next build, and a planning error stops the build before
// any module compiles. Each test runs `nomu build --report-jobs` on a copy of the fixtures (a build writes
// under their `build/`) with its own host cache.
final class BuildTests: XCTestCase {
    private var repo = ""
    private var cache = ""
    private var nomu = ""

    // What one `nomu build` did, read from its `--report-jobs` lines.
    struct BuildResult {
        var binary: String? = nil
        var compiled: [String] = []
        var cached: [String] = []
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let srcdir = env["TEST_SRCDIR"], let tmp = env["TEST_TMPDIR"] else { throw XCTSkip("not under bazel test") }
        let unique = UUID().uuidString
        repo = tmp + "/repo-" + unique
        cache = tmp + "/cache-" + unique
        try copyTree(from: srcdir + "/_main", to: repo, entries: ["nomu.yaml", "tests/fixtures"])
        nomu = srcdir + "/_main/" + (env["NOMU_BINARY"] ?? "src/nomu-cli/nomu")
    }

    private func build(_ fixture: String, _ args: [String] = []) throws -> BuildResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nomu)
        p.arguments = ["build", "--report-jobs"] + args + [repo + "/" + fixture]
        p.environment = ProcessInfo.processInfo.environment.merging(["NOMU_CACHE_DIR": cache]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var r = BuildResult()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "compiled": r.compiled.append(parts[1])
            case "cached": r.cached.append(parts[1])
            case "binary": r.binary = parts[1]
            default: break
            }
        }
        if p.terminationStatus != 0 { r.binary = nil }
        return r
    }

    private func output(of binary: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // A diamond (`data` under both `left` and `right`) plus the implicit `std`: every module compiles exactly
    // once, `data` and `std/prelude` included.
    func testEachModuleCompilesOnce() throws {
        let r = try build("tests/fixtures/module_link_diamond")
        let binary = try XCTUnwrap(r.binary)
        XCTAssertEqual(r.compiled.count, Set(r.compiled).count, "a module compiled twice: \(r.compiled)")
        XCTAssertEqual(r.cached, [])
        let mine = r.compiled.filter { $0.hasPrefix("nomu.nomu_lang:") }
        XCTAssertEqual(mine, ["nomu.nomu_lang:tests/fixtures/module_link_diamond/data",
                              "nomu.nomu_lang:tests/fixtures/module_link_diamond/left",
                              "nomu.nomu_lang:tests/fixtures/module_link_diamond/right",
                              "nomu.nomu_lang:tests/fixtures/module_link_diamond"])
        XCTAssertEqual(r.compiled.filter { $0 == "nomu.nomu:std/prelude" }.count, 1)
        XCTAssertEqual(try output(of: binary), "23\n")
    }

    // The second build takes every language-workspace module from the host cache and compiles only the
    // workspace's own.
    func testHostCacheServesTheLanguageWorkspace() throws {
        let first = try build("tests/fixtures/std_module_import")
        XCTAssertNotNil(first.binary)
        let language = first.compiled.filter { $0.hasPrefix("nomu.nomu:") }
        XCTAssertTrue(language.contains("nomu.nomu:std/prelude"))
        XCTAssertTrue(language.contains("nomu.nomu:runtime"))

        let second = try build("tests/fixtures/std_module_import")
        XCTAssertNotNil(second.binary)
        XCTAssertEqual(second.cached, language)
        XCTAssertEqual(second.compiled, first.compiled.filter { !$0.hasPrefix("nomu.nomu:") })
    }

    // Every library writes its `.bir`, empty when it ships no templates; a compile that finds a dependency's
    // `.bir` missing fails.
    func testMissingDependencyBIRFailsTheCompile() throws {
        XCTAssertNotNil(try build("tests/fixtures/module_link_diamond", ["--emit-jobs"]).binary)
        let unit = repo + "/build/tests/fixtures/module_link_diamond"
        let files = FileManager.default.enumerator(atPath: unit)?.compactMap { $0 as? String } ?? []
        for library in ["data", "left", "right"] {
            XCTAssertTrue(files.contains { $0 == "\(library)/\(library).bir" }, library)
        }
        let leftJob = unit + "/" + (try XCTUnwrap(files.first { $0 == "left/left.job.json" }))
        let dataBIR = unit + "/" + (try XCTUnwrap(files.first { $0 == "data/data.bir" }))
        XCTAssertEqual(try run(nomu, ["compile", leftJob]).status, 0)
        try FileManager.default.removeItem(atPath: dataBIR)
        let r = try run(nomu, ["compile", leftJob])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("missing the templates of"), r.stderr)
    }

    // `--verify-cache` compiles every module, taking nothing from the cache, and passes when each entry
    // already under a module's key matches its compile. An entry whose object differs, under a manifest that
    // still matches (an input outside the key), fails the build, naming the module and the key's inputs.
    func testVerifyCache() throws {
        let fixture = "tests/fixtures/std_module_import"
        let first = try build(fixture)
        XCTAssertNotNil(first.binary)
        let checked = try build(fixture, ["--verify-cache"])
        XCTAssertNotNil(checked.binary)
        XCTAssertEqual(checked.cached, [])
        XCTAssertEqual(Set(checked.compiled), Set(first.compiled))
        // Store a changed object in the CAS and point the result at it, so the entry is served.
        let resultPath = try result(holding: "prelude.o")
        var object = try Data(contentsOf: URL(fileURLWithPath: try blob(of: "prelude.o")))
        object[object.count / 2] ^= 0xff
        try object.write(to: URL(fileURLWithPath: cache + "/cas/" + ContentHash.of(object)))
        var result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: resultPath))) as? [String: Any])
        var files = try XCTUnwrap(result["files"] as? [[String: Any]])
        for i in files.indices where files[i]["path"] as? String == "prelude.o" { files[i]["hash"] = ContentHash.of(object) }
        result["files"] = files
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: resultPath))

        let r = try run(nomu, ["build", "--verify-cache", repo + "/" + fixture], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("error: --verify-cache: nomu.nomu:std/prelude: differs from its cache entry"
                                        + " (prelude.o at byte"), r.stderr)
        XCTAssertTrue(r.stderr.contains("; the key covers:\n    compiler = "), r.stderr)
        XCTAssertTrue(r.stderr.contains("\n    source:/nomu-src/nomu.nomu/std/prelude/prelude.nomu = "), r.stderr)
        XCTAssertEqual(r.stderr.components(separatedBy: "differs from its cache entry").count, 2, r.stderr)
    }

    // A second build in a workspace waits while another holds its lock, naming the holder's pid (210).
    func testSecondBuildWaitsForTheLock() throws {
        let lockPath = repo + "/build/.nomu-lock"
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        _ = "4242\n".withCString { pwrite(fd, $0, 5, 0) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: nomu)
        p.arguments = ["build", repo + "/tests/fixtures/module_link_diamond"]
        p.environment = ProcessInfo.processInfo.environment.merging(["NOMU_CACHE_DIR": cache]) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(p.isRunning, "the build went ahead while the lock was held")
        close(fd)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, stderr)
        XCTAssertTrue(stderr.contains("nomu: waiting for another nomu (pid 4242) building in workspace '\(repo)'"), stderr)
    }

    // A lock file naming a holder that is gone (no process holds the `flock`) does not delay a build.
    func testDeadHolderDoesNotBlock() throws {
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try write(repo + "/build/.nomu-lock", "999999\n")
        let r = try run(nomu, ["build", repo + "/tests/fixtures/module_link_diamond"], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(r.stderr.contains("waiting"), r.stderr)
    }

    // A file where the layout puts a directory, and a directory where it puts the binary, are reported and
    // removed (210.3).
    func testStaleLayoutIsCleared() throws {
        let fixture = repo + "/tests/fixtures/module_link_diamond"
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try write(repo + "/build/tests", "an old binary")
        let first = try run(nomu, ["build", fixture], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(first.stderr.contains("nomu: removed '\(repo)/build/tests', a file left by an earlier build"), first.stderr)

        let binary = repo + "/build/tests/fixtures/module_link_diamond/module_link_diamond"
        try FileManager.default.removeItem(atPath: binary)
        try FileManager.default.createDirectory(atPath: binary + "/old", withIntermediateDirectories: true)
        let second = try run(nomu, ["build", fixture], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertTrue(second.stderr.contains("nomu: removed '\(binary)', a directory left by an earlier build"), second.stderr)
        XCTAssertEqual(try output(of: binary), "23\n")
    }

    // A planning error stops the build before any job: nothing compiles and nothing is written.
    func testPlanningErrorsPrecedeEveryCompile() throws {
        for fixture in ["tests/fixtures/multipackage_undeclared/app", "tests/fixtures/multipackage_cycle/p"] {
            let r = try build(fixture)
            XCTAssertNil(r.binary, fixture)
            XCTAssertEqual(r.compiled, [], fixture)
            XCTAssertEqual(r.cached, [], fixture)
            let workspace = repo + "/" + fixture.split(separator: "/").prefix(3).joined(separator: "/")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/build"), fixture)
        }
    }

    // A pinned workspace's modules compile as jobs of the consumer's build, into its `build/_external/`.
    func testPinnedWorkspaceModulesAreJobs() throws {
        let r = try build("tests/fixtures/xworkspace_basic/consumer/app")
        let binary = try XCTUnwrap(r.binary)
        XCTAssertTrue(r.compiled.contains("nomu.prov:greet"))
        let consumer = repo + "/tests/fixtures/xworkspace_basic/consumer"
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer + "/build/_external/nomu.prov/greet/greet.o"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/tests/fixtures/xworkspace_basic/provider/build"))
        XCTAssertEqual(try output(of: binary), "42\n")
    }

    // Settings resolve once per build and reach each module's compile (task 198), read here from the job
    // files. An external takes its own file's value, and the entry's `externals: all` block over it when its
    // config is selected; the language workspace's settings do not change with the selection, so its
    // host-cache entry is shared. `build/` shows the last build, whatever its configuration (210).
    func testSettingsReachEachModulesCompile() throws {
        let root = repo + "/tests/fixtures/xworkspace_basic"
        try write(root + "/consumer/cfg.yaml", """
            configs:
              tagged: debug
            opt tagged:
              inline: false
            externals:
              all:
                opt tagged:
                  scalar: true

            """)
        try write(root + "/provider/cfg.yaml", "opt:\n  scalar: false\n")

        let plain = try build("tests/fixtures/xworkspace_basic/consumer/app", ["--emit-jobs"])
        XCTAssertEqual(plain.binary, root + "/consumer/build/app/app")
        let language = languageEntries()
        let before = try jobSettings([root + "/consumer/build"])
        XCTAssertEqual(before["nomu/cons/app"]?["opt.inline"], "true")
        XCTAssertEqual(before["nomu/prov/greet"]?["opt.scalar"], "false")

        let tagged = try build("tests/fixtures/xworkspace_basic/consumer/app", ["--emit-jobs", "-c", "tagged"])
        XCTAssertEqual(tagged.binary, root + "/consumer/build/app/app")
        XCTAssertEqual(try output(of: XCTUnwrap(tagged.binary)), "42\n")
        let after = try jobSettings([root + "/consumer/build"])
        XCTAssertEqual(after["nomu/cons/app"]?["opt.inline"], "false")
        XCTAssertEqual(after["nomu/prov/greet"]?["opt.inline"], "true")
        XCTAssertEqual(after["nomu/prov/greet"]?["opt.scalar"], "true")
        XCTAssertEqual(tagged.cached, plain.compiled.filter { $0.hasPrefix("nomu.nomu:") })
        XCTAssertEqual(languageEntries(), language)
        for (origin, settings) in before where origin.hasPrefix("nomu/nomu/") {
            XCTAssertEqual(settings["opt.inline"], "true", origin)
        }
    }

    // The binary carries the compiler and the active configs in its `__nomu_config` section (task 198).
    func testBinaryCarriesItsConfiguration() throws {
        func record(_ binary: String) throws -> String {
            let data = try Data(contentsOf: URL(fileURLWithPath: binary))
            let (_, offset, size) = try XCTUnwrap(section(of: data, "__TEXT", "__nomu_config"))
            let text = String(decoding: data.subdata(in: offset..<(offset + size)), as: UTF8.self)
            // The compiler line is the build's commit; the rest is fixed.
            return text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        }
        let plain = try XCTUnwrap(build("tests/fixtures/xworkspace_basic/consumer/app").binary)
        XCTAssertEqual(try record(plain), """
            active:
              nomu.cons:
                - debug
              externals:
                - debug
              language:
                - debug

            """)
        let release = try XCTUnwrap(build("tests/fixtures/xworkspace_basic/consumer/app", ["-c", "release"]).binary)
        XCTAssertEqual(try output(of: release), "42\n")
        XCTAssertEqual(try record(release), """
            active:
              nomu.cons:
                - release
              externals:
                - release
              language:
                - release

            """)
    }

    // The optimization level and mono reach every job, externals' and the language workspace's included
    // (190.6 F4): with nothing selected each module compiles under `debug`, and `-c release` gives every
    // module `release`'s values, in its own language-workspace cache entry.
    func testReleaseReachesEveryJob() throws {
        let root = repo + "/tests/fixtures/xworkspace_basic"
        let plain = try build("tests/fixtures/xworkspace_basic/consumer/app", ["--emit-jobs"])
        XCTAssertEqual(try output(of: XCTUnwrap(plain.binary)), "42\n")
        let debugEntries = languageEntries()
        XCTAssertEqual(debugEntries.count, plain.compiled.filter { $0.hasPrefix("nomu.nomu:") }.count)
        let debug = try jobSettings([root + "/consumer/build"])
        let release = try build("tests/fixtures/xworkspace_basic/consumer/app", ["--emit-jobs", "-c", "release"])
        XCTAssertEqual(try output(of: XCTUnwrap(release.binary)), "42\n")
        XCTAssertEqual(release.cached, [])
        XCTAssertEqual(languageEntries().subtracting(debugEntries).count, debugEntries.count)
        let optimized = try jobSettings([root + "/consumer/build"])
        for origin in ["nomu/cons/app", "nomu/prov/greet", "nomu/nomu/std/prelude", "nomu/nomu/runtime"] {
            XCTAssertEqual(debug[origin]?["opt.level"], "none", origin)
            XCTAssertEqual(debug[origin]?["opt.mono"], "none", origin)
            XCTAssertEqual(optimized[origin]?["opt.level"], "o2", origin)
            XCTAssertEqual(optimized[origin]?["opt.mono"], "all", origin)
        }
    }

    // Each job's settings, by origin (`scope/name/path`), from the job files `--emit-jobs` wrote under `dirs`.
    private func jobSettings(_ dirs: [String]) throws -> [String: [String: String]] {
        var found: [String: [String: String]] = [:]
        for dir in dirs {
            for case let rel as String in FileManager.default.enumerator(atPath: dir)! where rel.hasSuffix(".job.json") {
                let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + rel))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let job = try XCTUnwrap(json["job"] as? [String: Any])
                let origin = try XCTUnwrap(job["origin"] as? [String]).joined(separator: "/")
                found[origin] = try XCTUnwrap(job["settings"] as? [String: String])
            }
        }
        return found
    }

    // The host cache's action results (`ac/<key>`), each parsed.
    private func cacheResults() throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cache + "/ac")) ?? [] where !name.hasPrefix(".") {
            let data = try Data(contentsOf: URL(fileURLWithPath: cache + "/ac/" + name))
            out[name] = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        return out
    }

    private func fileNames(_ result: [String: Any]) -> [String] {
        ((result["files"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }
    }

    // The keys of the language-workspace modules' results: one per module per distinct set of its settings.
    private func languageEntries() -> Set<String> {
        Set(((try? cacheResults()) ?? [:]).filter { !fileNames($0.value).contains("nomu-runtime.a") }.keys)
    }

    // The path of the action result that holds the output `file`.
    private func result(holding file: String) throws -> String {
        let key = try XCTUnwrap(try cacheResults().first { fileNames($0.value).contains(file) }?.key, file)
        return cache + "/ac/" + key
    }

    // The CAS blob of the output `file`.
    private func blob(of file: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: try result(holding: file)))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try XCTUnwrap((result["files"] as? [[String: Any]])?.first { $0["path"] as? String == file })
        return cache + "/cas/" + (try XCTUnwrap(entry["hash"] as? String))
    }

    // A host-cache action result records the job's key and its outputs; the key's named inputs are computed only
    // when asked for (`--verify-cache`).
    func testHostCacheEntryRecordsItsKey() throws {
        XCTAssertNotNil(try build("tests/fixtures/std_module_import").binary)
        for key in languageEntries() {
            let result = try XCTUnwrap(try cacheResults()[key])
            XCTAssertEqual(Array((try XCTUnwrap(result["inputs"] as? [String: String])).keys), ["key"], key)
            XCTAssertFalse(fileNames(result).isEmpty, key)
        }
    }

    // A host-cache entry naming a blob that no longer matches its digest is discarded and recompiled; the other
    // entries are served. A leftover temporary file changes nothing.
    func testDamagedHostCacheEntryIsRebuilt() throws {
        let first = try build("tests/fixtures/std_module_import")
        XCTAssertNotNil(first.binary)
        let language = first.compiled.filter { $0.hasPrefix("nomu.nomu:") }
        let preludeBlob = try blob(of: "prelude.o")
        var object = try Data(contentsOf: URL(fileURLWithPath: preludeBlob))
        object[object.count / 2] ^= 0xff
        try object.write(to: URL(fileURLWithPath: preludeBlob))
        try write(cache + "/cas/.tmp-leftover", "partial")

        let second = try build("tests/fixtures/std_module_import")
        XCTAssertEqual(try output(of: XCTUnwrap(second.binary)), try output(of: XCTUnwrap(first.binary)))
        XCTAssertEqual(second.compiled.filter { $0.hasPrefix("nomu.nomu:") }, ["nomu.nomu:std/prelude"])
        XCTAssertEqual(second.cached, language.filter { $0 != "nomu.nomu:std/prelude" })

        // A damaged runtime archive is rebuilt the same way.
        try write(try blob(of: "nomu-runtime.a"), "ruined")
        let third = try build("tests/fixtures/std_module_import")
        XCTAssertEqual(try output(of: XCTUnwrap(third.binary)), try output(of: XCTUnwrap(first.binary)))
        XCTAssertEqual(third.cached, language)
    }

    // A wrong `cfg.yaml` or selection stops the build before any compile, with the file's position.
    func testConfigurationErrorsPrecedeEveryCompile() throws {
        let root = repo + "/tests/fixtures/xworkspace_basic"
        try write(root + "/consumer/cfg.yaml", "opt:\n  inlin: false\n")
        let r = try run(nomu, ["build", "--report-jobs", root + "/consumer/app"], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("consumer/cfg.yaml:2:3: error: unknown setting `opt.inlin`; did you mean `opt.inline`?"), r.stderr)
        XCTAssertEqual(r.stdout, "")
        try FileManager.default.removeItem(atPath: root + "/consumer/cfg.yaml")
        let unknown = try run(nomu, ["build", "-c", "nope", root + "/consumer/app"], env: ["NOMU_CACHE_DIR": cache])
        XCTAssertNotEqual(unknown.status, 0)
        XCTAssertTrue(unknown.stderr.contains("error: -c nope: `nope` is not a declared config"), unknown.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/consumer/build"))
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // The GC frame index (task 195): a built binary carries it, version 2 with entries, and collects
    // correctly across modules; with the index erased, the program aborts at startup with a message instead
    // of missing roots, whether or not it would collect.
    func testBinaryWithoutFrameIndexAborts() throws {
        let r = try build("tests/fixtures/gc_roots_across_modules")
        let binary = try XCTUnwrap(r.binary)
        let gc = ["NOMU_GC_STRESS": "65536"]
        XCTAssertEqual(try run(binary, env: gc).stdout, "2014000\n6042\n")

        var data = try Data(contentsOf: URL(fileURLWithPath: binary))
        let (address, fileOffset, size) = try XCTUnwrap(section(of: data, "__DATA_CONST", "__nomu_frameidx"))
        let at = fileOffset + Int((8 - address % 8) % 8)
        XCTAssertLessThanOrEqual(at + 16, fileOffset + size)
        XCTAssertEqual(data.subdata(in: at..<(at + 4)), Data("NFIX".utf8), "index magic")
        XCTAssertEqual(data[at + 4], 2, "index version")
        XCTAssertGreaterThan(data[at + 8], 0, "index entries")

        data.replaceSubrange(at..<(at + 16), with: Data(count: 16))
        try data.write(to: URL(fileURLWithPath: binary))
        XCTAssertEqual(try run("/usr/bin/codesign", ["-f", "-s", "-", binary]).status, 0)
        let erased = try run(binary, env: gc)
        XCTAssertNotEqual(erased.status, 0)
        XCTAssertTrue(erased.stderr.contains("no GC frame index"), erased.stderr)
        let quiet = try run(binary)
        XCTAssertNotEqual(quiet.status, 0)
        XCTAssertTrue(quiet.stderr.contains("no GC frame index"), quiet.stderr)
    }

    // The driver redoes the linker's signature after writing the frame index (CodeSignature.swift): the
    // signature verifies, stays linker-signed ad hoc, and names the binary.
    func testBinarySignatureVerifies() throws {
        let r = try build("tests/fixtures/gc_roots_across_modules")
        let binary = try XCTUnwrap(r.binary)
        let verify = try run("/usr/bin/codesign", ["-v", "--strict", binary])
        XCTAssertEqual(verify.status, 0, verify.stderr)
        let details = try run("/usr/bin/codesign", ["-d", "-v", binary]).stderr
        XCTAssertTrue(details.contains("Identifier=\((binary as NSString).lastPathComponent)\n"), details)
        XCTAssertTrue(details.contains("adhoc,linker-signed"), details)
    }

    // The language workspace's sources are copied under the host cache for reporting. Its modules' debug info
    // records `/nomu-src/nomu.nomu/…` (`DebugPaths`), and the binary's `.lldbinit` maps that prefix to the copy;
    // a copy holding other sources (a `.digest` mismatch) is replaced.
    func testLanguageSourcesCopiedForReporting() throws {
        let r = try build("tests/fixtures/gc_roots_across_modules")
        let binary = try XCTUnwrap(r.binary)
        let copy = cache + "/source"
        let prelude = copy + "/std/prelude/prelude.nomu"
        XCTAssertTrue(FileManager.default.fileExists(atPath: prelude))
        let digest = try String(contentsOfFile: copy + "/.digest", encoding: .utf8)
        let object = try Data(contentsOf: URL(fileURLWithPath: repo + "/build/_external/nomu.nomu/std/prelude/prelude.o"))
        XCTAssertNotNil(object.range(of: Data("/nomu-src/nomu.nomu/std/prelude".utf8)), "debug info records the fixed form")
        XCTAssertNil(object.range(of: Data(cache.utf8)), "no host-cache path in debug info")
        XCTAssertNil(object.range(of: Data("<nomu>/".utf8)), "no virtual path in debug info")
        let lldbInit = try String(contentsOfFile: binary + ".lldbinit", encoding: .utf8)
        XCTAssertTrue(lldbInit.contains("settings append target.source-map /nomu-src/nomu.nomu \"\(copy)\"\n"), lldbInit)
        XCTAssertTrue(lldbInit.contains("settings append target.source-map /nomu-src/nomu.nomu_lang \"\(repo)\"\n"), lldbInit)

        try "stale".write(toFile: copy + "/.digest", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: prelude)
        XCTAssertNotNil(try build("tests/fixtures/gc_roots_across_modules").binary)
        XCTAssertEqual(try String(contentsOfFile: copy + "/.digest", encoding: .utf8), digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prelude))
    }

    // `build`, `run`, `test` and `query` need a workspace (modules.md §Manifest): a package with no `nomu.yaml`
    // above it fails with one message and compiles nothing.
    func testCommandsRequireAWorkspace() throws {
        let dir = (repo as NSString).deletingLastPathComponent + "/loose-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{ \"name\": \"loose\" }".write(toFile: dir + "/pkg.json", atomically: true, encoding: .utf8)
        try "fun main() {}\n".write(toFile: dir + "/main.nomu", atomically: true, encoding: .utf8)
        for command in ["build", "run", "test", "query"] {
            let r = try run(nomu, [command, dir], env: ["NOMU_CACHE_DIR": cache])
            XCTAssertNotEqual(r.status, 0, command)
            XCTAssertTrue(r.stderr.contains("no nomu.yaml found at or above"), "\(command): \(r.stderr)")
            XCTAssertEqual(r.stdout, "", command)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/build"))
    }

    private func run(_ exe: String, _ args: [String] = [], env: [String: String] = [:]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    // A 64-bit Mach-O section's address, file offset and size.
    private func section(of d: Data, _ segment: String, _ name: String) -> (UInt64, Int, Int)? {
        func u32(_ o: Int) -> UInt32 { d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { d.subdata(in: o..<(o + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        func str(_ o: Int) -> String { String(decoding: d.subdata(in: o..<(o + 16)).prefix { $0 != 0 }, as: UTF8.self) }
        var off = 32
        for _ in 0..<Int(u32(16)) {
            if u32(off) == 0x19 {   // LC_SEGMENT_64
                var s = off + 72
                for _ in 0..<Int(u32(off + 64)) {
                    if str(s) == name && str(s + 16) == segment { return (u64(s + 32), Int(u32(s + 48)), Int(u64(s + 40))) }
                    s += 80
                }
            }
            off += Int(u32(off + 4))
        }
        return nil
    }

    // Copy `entries` of `from` (files and trees, following symlinks) into `to`.
    private func copyTree(from: String, to: String, entries: [String]) throws {
        let fm = FileManager.default
        for entry in entries {
            let src = from + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir) else { continue }
            let files = isDir.boolValue
                ? (fm.enumerator(atPath: src)?.allObjects as? [String] ?? []).map { entry + "/" + $0 } : [entry]
            for f in files {
                var fileIsDir: ObjCBool = false
                guard fm.fileExists(atPath: from + "/" + f, isDirectory: &fileIsDir), !fileIsDir.boolValue else { continue }
                let dst = to + "/" + f
                try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(contentsOf: URL(fileURLWithPath: from + "/" + f)).write(to: URL(fileURLWithPath: dst))
            }
        }
    }
}
