import XCTest
@testable import planner

// Whole plans against checked-in goldens (`tests/golden/<case>.plan`, the `Plan.dump()` text). To accept a
// change in planning, rewrite the goldens in the source tree (unsandboxed, so the test can write there):
//
//     bazel test //src/planner:planner_tests --spawn_strategy=local \
//         --test_env=NOMU_UPDATE_GOLDENS=$PWD/src/planner/tests/golden
//
// On a mismatch under `bazel test`, the actual plan is written to the test's undeclared outputs.
final class PlanGoldenTests: XCTestCase {

    // MARK: - In memory

    private let app: [String: String] = [
        "/w/nomu.yaml": "scope: me\nname: app\nexternals:\n  prov: ../p\n",
        "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"greet\"], \"products\": [\"util\"]}",
        "/w/app/cli/main.nomu": "import pkg/util\nimport greet as g\nimport std/time\n\nfun main() {}\n",
        "/w/app/util/u.nomu": "public import pkg/util/inner\n",
        "/w/app/util/inner/i.nomu": "",
        "/w/app/tests/t.nomu": "test import pkg/util\n",
        "/p/nomu.yaml": "scope: them\nname: prov\n",
        "/p/greet/pkg.json": "{\"name\": \"greet\", \"products\": [\"\"]}",
        "/p/greet/g.nomu": "import pkg/inner\n",
        "/p/greet/inner/i.nomu": "",
    ]

    func testBinaryAcrossWorkspaces() throws {
        try check("binary_across_workspaces", plan(app, ["/w/app/cli/main.nomu"]))
    }

    func testLibrary() throws {
        try check("library", plan(app, ["/w/app/util/u.nomu"], product: .library))
    }

    func testWhiteBoxTestModule() throws {
        try check("white_box_test_module", plan(app, ["/w/app/tests/t.nomu"]))
    }

    func testCoreImportLifted() throws {
        let files = ["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}",
                     "/w/app/main.nomu": "import core\n"]
        try check("core_import_lifted", plan(files, ["/w/app/main.nomu"], allowCore: true))
    }

    func testResolutionErrors() throws {
        var files = app
        files["/w/app/cli/main.nomu"] = "import pkg/none\nimport other\nimport greet/inner\ntest import greet\nimport core\n"
        try check("resolution_errors", plan(files, ["/w/app/cli/main.nomu"]))
    }

    func testModuleCycle() throws {
        try check("module_cycle", plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                                         "/w/app/pkg.json": "{\"name\": \"app\"}",
                                         "/w/app/main.nomu": "import pkg/a\n",
                                         "/w/app/a/a.nomu": "import pkg/b\n",
                                         "/w/app/b/b.nomu": "import pkg/a\n"], ["/w/app/main.nomu"]))
    }

    func testPackageCycle() throws {
        try check("package_cycle", plan([
            "/w/nomu.yaml": "scope: me\nname: app\n",
            "/w/p/pkg.json": "{\"name\": \"p\", \"dependencies\": [\"q\"], \"products\": [\"extra\"]}",
            "/w/p/main/m.nomu": "import q\n",
            "/w/p/extra/e.nomu": "",
            "/w/q/pkg.json": "{\"name\": \"q\", \"dependencies\": [\"p\"], \"products\": [\"\"]}",
            "/w/q/q.nomu": "import p/extra\n",
        ], ["/w/p/main/m.nomu"]))
    }

    func testWorkspaceErrors() throws {
        try check("workspace_errors", plan([
            "/w/nomu.yaml": "scope: me\nname: app\nexternals:\n  dup: ../d\n  gone: ../nowhere\n",
            "/w/app/pkg.json": "{\"name\": \"app\"}",
            "/w/app/main.nomu": "",
            "/d/nomu.yaml": "scope: me\nname: app\n",
        ], ["/w/app/main.nomu"]))
    }

    // MARK: - Suite fixtures on disk

    func testFixtureCrossWorkspaceAlias() throws {
        try check("fixture_xworkspace_alias", try planFixture("tests/fixtures/xworkspace_alias/consumer/app"))
    }

    func testFixtureMultiPackage() throws {
        try check("fixture_multipackage_basic", try planFixture("tests/fixtures/multipackage_basic/app"))
    }

    func testFixtureStdModuleImport() throws {
        try check("fixture_std_module_import", try planFixture("tests/fixtures/std_module_import"))
    }

    // MARK: - Helpers

    private func plan(_ files: [String: String], _ entry: [String], product: ModuleJob.Product = .binary,
                      allowCore: Bool = false) -> Plan {
        var options = PlanOptions()
        options.product = product
        options.allowCoreImport = allowCore
        options.cacheRoot = "/cache"
        return Plan(entryFiles: entry, options: options, disk: MemoryTree(files))
    }

    private func planFixture(_ dir: String) throws -> Plan {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel") }
        let path = srcdir + "/_main/" + dir
        let files = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".nomu") }
            .sorted().map { path + "/" + $0 }
        var options = PlanOptions()
        options.cacheRoot = "/cache"
        return Plan(entryFiles: files, options: options)
    }

    // Compare `plan` with the golden `name`, or rewrite the golden when asked.
    private func check(_ name: String, _ plan: Plan, file: StaticString = #filePath, line: UInt = #line) throws {
        let env = ProcessInfo.processInfo.environment
        let actual = plan.dump()
        let rel = "src/planner/tests/golden/\(name).plan"
        if let dir = env["NOMU_UPDATE_GOLDENS"] {
            try actual.write(toFile: dir + "/\(name).plan", atomically: true, encoding: .utf8)
            return
        }
        guard let srcdir = env["TEST_SRCDIR"] else { throw XCTSkip("not under bazel") }
        let expected = (try? String(contentsOfFile: srcdir + "/_main/" + rel, encoding: .utf8)) ?? ""
        if actual != expected {
            if let outs = env["TEST_UNDECLARED_OUTPUTS_DIR"] {
                try? actual.write(toFile: outs + "/\(name).plan", atomically: true, encoding: .utf8)
            }
            XCTFail("plan '\(name)' differs from \(rel):\n\(actual)", file: file, line: line)
        }
    }
}
