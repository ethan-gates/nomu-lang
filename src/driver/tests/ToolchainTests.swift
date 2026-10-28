import XCTest
import Foundation
@testable import driver

// The toolchain record: the first build asks every tool; later builds read the record and run nothing while the
// selection and every resolved tool's file are unchanged; a changed file or selection asks again.
final class ToolchainTests: XCTestCase {
    private var dir = ""
    private var runs: [String] = []

    override func setUpWithError() throws {
        let tmp = ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory()
        dir = tmp + "/toolchain-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        for tool in Toolchain.tools { try write(tool.name, "\(tool.name) 1") }
        runs = []
    }

    private func write(_ tool: String, _ text: String) throws {
        try text.write(toFile: dir + "/bin/" + tool, atomically: false, encoding: .utf8)
    }

    // The identities, with tools found under `bin/` and each version report naming the tool's file content.
    private func identities(_ env: [String: String] = [:], missing: Set<String> = []) -> [String: String] {
        Toolchain.identities(
            cacheRoot: dir + "/cache", environment: env, selectLink: dir + "/no-link",
            resolve: { missing.contains($0) ? nil : self.dir + "/bin/" + $0 },
            run: { exe, _ in
                let name = (exe as NSString).lastPathComponent
                self.runs.append(name)
                return (try? String(contentsOfFile: self.dir + "/bin/" + name, encoding: .utf8)).map { $0 + "\nsecond\nthird" }
            })
    }

    func testRecordIsReusedUntilAToolChanges() throws {
        let first = identities()
        XCTAssertEqual(runs, ["cc", "ld", "dsymutil"])
        XCTAssertEqual(first["cc"], "cc 1")
        XCTAssertEqual(first["ld"], "ld 1 second")
        XCTAssertEqual(first["strip"]?.count, 16)

        runs = []
        XCTAssertEqual(identities(), first)
        XCTAssertEqual(runs, [])

        try write("ld", "ld 22")
        let updated = identities()
        XCTAssertEqual(updated["ld"], "ld 22 second")
        XCTAssertEqual(runs, ["cc", "ld", "dsymutil"])

        try write("strip", "strip 22")
        XCTAssertNotEqual(identities()["strip"], updated["strip"])
    }

    func testSelectionChangeAsksAgain() {
        _ = identities()
        runs = []
        _ = identities(["DEVELOPER_DIR": "/Applications/Other.app/Contents/Developer", "PATH": "/bin"])
        XCTAssertEqual(runs, ["cc", "ld", "dsymutil"])
        runs = []
        _ = identities(["DEVELOPER_DIR": "/Applications/Other.app/Contents/Developer", "PATH": "/usr/bin"])
        XCTAssertEqual(runs, [], "an unrelated variable asks nothing")
    }

    // A missing tool is absent, and asked for again on the next build.
    func testMissingToolIsAbsent() {
        XCTAssertEqual(identities(missing: ["dsymutil"])["dsymutil"], "absent")
        runs = []
        XCTAssertEqual(identities()["dsymutil"], "dsymutil 1")
        XCTAssertEqual(runs, ["cc", "ld", "dsymutil"])
    }
}
