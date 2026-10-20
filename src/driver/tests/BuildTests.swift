import XCTest
import Foundation

// Builds of real suite fixtures with the `nomu` binary (190.5.2): each module compiles once per build, the
// host cache serves the embedded workspace on the next build, and a planning error stops the build before
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

    private func build(_ fixture: String) throws -> BuildResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nomu)
        p.arguments = ["build", "--report-jobs", repo + "/" + fixture]
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

    // The second build takes every embedded module from the host cache and compiles only the workspace's own.
    func testHostCacheServesTheEmbeddedWorkspace() throws {
        let first = try build("tests/fixtures/std_module_import")
        XCTAssertNotNil(first.binary)
        let embedded = first.compiled.filter { $0.hasPrefix("nomu.nomu:") }
        XCTAssertTrue(embedded.contains("nomu.nomu:std/prelude"))
        XCTAssertTrue(embedded.contains("nomu.nomu:runtime"))

        let second = try build("tests/fixtures/std_module_import")
        XCTAssertNotNil(second.binary)
        XCTAssertEqual(second.cached, embedded)
        XCTAssertEqual(second.compiled, first.compiled.filter { !$0.hasPrefix("nomu.nomu:") })
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

    // The GC frame index (task 195): a built binary carries it, version 2 with entries, and collects
    // correctly across modules; with the index erased, the first stack walk aborts with a message instead of
    // missing roots. A run that never collects never walks, so it still runs.
    func testBinaryWithoutFrameIndexAborts() throws {
        let r = try build("tests/fixtures/gc_roots_across_modules")
        let binary = try XCTUnwrap(r.binary)
        let gc = ["NOMU_GC_PLAN": "immix", "NOMU_GC_STRESS": "65536"]
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
        XCTAssertEqual(try run(binary).stdout, "2014000\n6042\n")
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
