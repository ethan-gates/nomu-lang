import XCTest
@testable import planner

final class ResolutionTests: XCTestCase {

    private let me = WorkspaceIdentity(scope: "me", name: "app")
    private let nomu = LanguageWorkspace.identity

    private func plan(_ files: [String: String], entry: [String], languageWorkspace: Bool = true,
                      allowCore: Bool = false) -> ModuleTable {
        let ws = WorkspaceSet(entry: entry[0], disk: MemoryTree(files), includeLanguageWorkspace: languageWorkspace)
        var options = PlanOptions()
        options.allowCoreImport = allowCore
        return ModuleTable(workspaces: ws, entryFiles: entry, options: options)
    }

    private func errors(_ t: ModuleTable) -> [String] { t.diagnostics.map(\.description) }
    private func key(_ ws: WorkspaceIdentity, _ path: String) -> ModuleKey {
        ModuleKey(ws, path.isEmpty ? [] : path.split(separator: "/").map(String.init))
    }

    // MARK: - Within a package

    func testPkgImportsAndImplicitStd() {
        let t = plan([
            "/w/nomu.yaml": "scope: me\nname: app\n",
            "/w/app/main.nomu": "import pkg/util/parse\nfun main() {}\n",
            "/w/app/b.nomu": "// second entry file\n",
            "/w/app/util/parse/p.nomu": "import pkg/util/lex\n",
            "/w/app/util/lex/l.nomu": "",
            "/w/app/pkg.json": "{\"name\": \"app\"}",
        ], entry: ["/w/app/main.nomu", "/w/app/b.nomu"])
        XCTAssertEqual(errors(t), [])
        XCTAssertEqual(t.entry, key(me, "app"))
        XCTAssertEqual(t.order, [key(me, "app"), key(nomu, "runtime"), key(nomu, "std/prelude"), key(me, "app/util/parse"),
                                 key(me, "app/util/lex")])
        let entry = t.modules[t.entry]!
        XCTAssertEqual(entry.files, ["/w/app/main.nomu", "/w/app/b.nomu"])
        XCTAssertEqual(entry.package.name, "app")
        // Each entry file carries the implicit `import std`, then its own imports.
        XCTAssertEqual(entry.imports.map(\.target), [key(nomu, "std/prelude"), key(me, "app/util/parse"),
                                                     key(nomu, "std/prelude")])
        XCTAssertTrue(entry.imports[0].isImplicit)
        XCTAssertEqual(entry.imports[1].line, 1)
        XCTAssertNil(entry.imports[1].crossPackage)
        // The language workspace's modules carry no implicit import.
        XCTAssertEqual(t.modules[key(nomu, "std/prelude")]?.imports, [])
    }

    func testExplicitBareStdReplacesImplicit() {
        let t = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/main.nomu": "import std as s\n"],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), [])
        XCTAssertEqual(t.modules[t.entry]?.imports.count, 1)
        XCTAssertEqual(t.modules[t.entry]?.imports.first?.alias, "s")
    }

    func testStdModulesResolveTheirOwnImports() {
        let t = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/main.nomu": "import std/time\n"],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), [])
        let time = t.modules[key(nomu, "std/time")]
        XCTAssertEqual(time?.imports.map(\.target), [key(nomu, "std/prelude")])
        XCTAssertEqual(time?.package.name, "std")
    }

    func testMissingPkgModuleAndScanErrors() {
        let t = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}",
                      "/w/app/main.nomu": "import pkg/nope\nimport pkg/Bad\n",
                      "/w/app/Bad/x.nomu": ""],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), [
            "/w/app/main.nomu:1:1: error: no module found at 'nope'",
            "/w/app/main.nomu:2:1: error: module path component 'Bad' must match [a-z][a-z0-9_]*",
        ])
        let s = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/main.nomu": "import a/\n"], entry: ["/w/app/main.nomu"])
        // A scan error is reported just past the token that wants a name, on the import's own line.
        XCTAssertEqual(errors(s), ["/w/app/main.nomu:1:10: error: expected a name after '/'"])
    }

    func testSamePackageTestImport() {
        let t = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}",
                      "/w/app/tests/t.nomu": "test import pkg/lib\n",
                      "/w/app/lib/l.nomu": ""],
                     entry: ["/w/app/tests/t.nomu"])
        XCTAssertEqual(errors(t), [])
        XCTAssertEqual(t.testImportTargets, [key(me, "app/lib")])
    }

    // MARK: - Across packages

    private let twoPackages: [String: String] = [
        "/w/nomu.yaml": "scope: me\nname: app\n",
        "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"greet\", \"multi\"]}",
        "/w/greet/pkg.json": "{\"name\": \"greet\", \"products\": [\"\"]}",
        "/w/greet/g.nomu": "",
        "/w/multi/pkg.json": "{\"name\": \"multi\", \"default-module\": \"core\", \"products\": [\"core\"]}",
        "/w/multi/core/c.nomu": "",
        "/w/multi/hidden/h.nomu": "",
        "/w/other/pkg.json": "{\"name\": \"other\", \"products\": [\"\"]}",
        "/w/other/o.nomu": "",
    ]

    func testCrossPackageImports() {
        var files = twoPackages
        files["/w/app/main.nomu"] = "import greet\nimport multi\nimport multi/core as c2\n"
        let t = plan(files, entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), [])
        let imports = t.modules[t.entry]!.imports.filter { !$0.isImplicit }
        XCTAssertEqual(imports.map(\.target), [key(me, "greet"), key(me, "multi/core"), key(me, "multi/core")])
        XCTAssertEqual(imports.map { $0.crossPackage?.name }, ["greet", "multi", "multi"])
        XCTAssertEqual(t.modules[key(me, "multi/core")]?.package.name, "multi")
    }

    // Every module is in a package (modules.md §Manifest): with no `pkg.json` at or above the entry within its
    // workspace, planning stops at one error.
    func testModuleInNoPackage() {
        let t = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/main.nomu": "import pkg/a\n"],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), ["error: module '/w/app' is in no package — a module needs a pkg.json declaring "
                                   + "its package's 'name', at or above it within workspace 'me.app'"])
        XCTAssertTrue(t.modules.isEmpty)
    }

    // Packages live in subdirectories of their workspace: a `pkg.json` at the root is reported once and stops
    // planning, and a module at the root is in no package.
    func testNothingAtTheWorkspaceRoot() {
        let rooted = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/pkg.json": "{\"name\": \"app\"}",
                           "/w/main.nomu": "import pkg/a\n", "/w/a/a.nomu": ""], entry: ["/w/main.nomu"])
        XCTAssertEqual(errors(rooted), ["/w/pkg.json: error: a package may not sit at the root of workspace 'me.app' — "
                                        + "move its pkg.json and modules into a subdirectory"])
        XCTAssertTrue(rooted.modules.isEmpty)
        let bare = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/main.nomu": ""], entry: ["/w/main.nomu"])
        XCTAssertEqual(errors(bare), ["error: module '/w' sits at the root of workspace 'me.app' — modules live in "
                                      + "packages, in subdirectories of the workspace"])
    }

    // A package name follows the path-component rule, for the entry's package and for one found by the walk.
    func testPackageNamesFollowThePathComponentRule() {
        let entry = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"My-App\"}",
                          "/w/app/main.nomu": ""], entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(entry), ["/w/app/pkg.json: error: package name 'My-App' must match [a-z][a-z0-9_]* — "
                                       + "rename the package in '/w/app/pkg.json'"])
        let walked = plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                           "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"lib\"]}",
                           "/w/app/main.nomu": "import lib\n",
                           "/w/lib/pkg.json": "{\"name\": \"2lib\", \"products\": [\"\"]}",
                           "/w/lib/l.nomu": ""], entry: ["/w/app/main.nomu"])
        XCTAssertTrue(errors(walked).contains("/w/lib/pkg.json: error: package name '2lib' must match "
                                              + "[a-z][a-z0-9_]* — rename the package in '/w/lib/pkg.json'"),
                      "\(errors(walked))")
    }

    func testCrossPackageErrors() {
        var files = twoPackages
        files["/w/app/main.nomu"] = "import other\nimport multi/hidden\nimport multi/none\ntest import greet\n"
        let t = plan(files, entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(t), [
            "/w/app/main.nomu:1:1: error: package 'other' is not listed in this package's 'dependencies'",
            "/w/app/main.nomu:2:1: error: module 'hidden' is not a product of package 'multi' — list it under "
                + "'products' in that package's pkg.json",
            "/w/app/main.nomu:3:1: error: no module 'none' in package 'multi'",
            "/w/app/main.nomu:4:1: error: 'test import' may not cross a package boundary — 'greet' is a foreign "
                + "package, always black-box; use a plain 'import'",
        ])
    }

    // MARK: - `core`

    // The language workspace's `core` does not exist to a user workspace: `import core` fails as any unlisted
    // name does, and no diagnostic names the language workspace's package.
    func testCoreGate() {
        let files = ["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/main.nomu": "import core\n"]
        XCTAssertEqual(errors(plan(files, entry: ["/w/app/main.nomu"])),
                       ["/w/app/main.nomu:1:1: error: package 'core' is not listed in this package's 'dependencies'"])
        let lifted = plan(files, entry: ["/w/app/main.nomu"], allowCore: true)
        XCTAssertEqual(errors(lifted), [])
        XCTAssertEqual(lifted.modules[lifted.entry]?.imports.last?.target, key(nomu, "core"))

        // A workspace's own package named `core` is an ordinary package: listed, it resolves; unlisted, it
        // gets the ordinary message.
        var ownFiles = ["/w/nomu.yaml": "scope: me\nname: app\n",
                        "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"core\"]}",
                        "/w/app/main.nomu": "import core\n",
                        "/w/core/pkg.json": "{\"name\": \"core\", \"products\": [\"\"]}",
                        "/w/core/c.nomu": ""]
        let own = plan(ownFiles, entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(own), [])
        XCTAssertEqual(own.modules[own.entry]?.imports.last?.target, key(me, "core"))
        ownFiles["/w/app/pkg.json"] = "{\"name\": \"app\"}"
        XCTAssertEqual(errors(plan(ownFiles, entry: ["/w/app/main.nomu"])),
                       ["/w/app/main.nomu:1:1: error: package 'core' is not listed in this package's 'dependencies'"])
        // Listed but present in no workspace: the ordinary message for a missing package.
        let missing = plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                            "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"core\"]}",
                            "/w/app/main.nomu": "import core\n"],
                           entry: ["/w/app/main.nomu"])
        XCTAssertEqual(errors(missing),
                       ["/w/app/main.nomu:1:1: error: package 'core' is external but no workspace pinned in nomu.yaml provides it"])
    }

    // MARK: - Across workspaces

    private let pinned: [String: String] = [
        "/c/nomu.yaml": "scope: me\nname: app\nexternals:\n  wsa: ../pa\n  wsb: ../pb\n",
        "/c/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"only_b\"]}",
        "/pa/nomu.yaml": "scope: s\nname: pa\n",
        "/pa/util/pkg.json": "{\"name\": \"util\", \"products\": [\"\"]}",
        "/pa/util/u.nomu": "import pkg/inner\n",
        "/pa/util/inner/i.nomu": "",
        "/pb/nomu.yaml": "scope: s\nname: pb\n",
        "/pb/util/pkg.json": "{\"name\": \"util\", \"products\": [\"\"]}",
        "/pb/util/u.nomu": "",
        "/pb/only_b/pkg.json": "{\"name\": \"only_b\", \"products\": [\"\"]}",
        "/pb/only_b/o.nomu": "",
    ]

    func testPinnedWorkspaces() {
        var files = pinned
        files["/c/app/main.nomu"] = "import wsa/util\nimport wsb/util as util2\nimport only_b\n"
        let t = plan(files, entry: ["/c/app/main.nomu"])
        XCTAssertEqual(errors(t), [])
        let pa = WorkspaceIdentity(scope: "s", name: "pa"), pb = WorkspaceIdentity(scope: "s", name: "pb")
        XCTAssertEqual(t.modules[t.entry]!.imports.filter { !$0.isImplicit }.map(\.target),
                       [key(pa, "util"), key(pb, "util"), key(pb, "only_b")])
        // A pinned workspace's module resolves its own imports in its own workspace, with the implicit `std`.
        XCTAssertEqual(t.modules[key(pa, "util")]?.imports.map(\.target), [key(nomu, "std/prelude"), key(pa, "util/inner")])
    }

    func testPinnedWorkspaceErrors() {
        var files = pinned
        files["/c/app/pkg.json"] = "{\"name\": \"app\", \"dependencies\": [\"absent\"]}"
        files["/c/app/main.nomu"] = "import wsa\nimport absent\nimport wsa/nothing\nimport wsa/util/inner\n"
        let t = plan(files, entry: ["/c/app/main.nomu"])
        XCTAssertEqual(errors(t), [
            "/c/app/main.nomu:1:1: error: 'wsa' names a pinned workspace — import one of its packages ('import wsa/<package>')",
            "/c/app/main.nomu:2:1: error: package 'absent' is external but no workspace pinned in nomu.yaml provides it",
            "/c/app/main.nomu:3:1: error: workspace 's.pa' has no package 'nothing'",
            "/c/app/main.nomu:4:1: error: module 'inner' is not a product of external package 'util' — list it under "
                + "'products' in that package's pkg.json",
        ])
    }

    // MARK: - On disk

    func testFixturesOnDisk() throws {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        let fixtures = srcdir + "/_main/tests/fixtures"
        func planFixture(_ dir: String) -> ModuleTable {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasSuffix(".nomu") }.sorted().map { dir + "/" + $0 } ?? []
            return ModuleTable(workspaces: WorkspaceSet(entry: files[0], includeLanguageWorkspace: true), entryFiles: files)
        }
        let alias = planFixture(fixtures + "/xworkspace_alias/consumer/app")
        XCTAssertEqual(errors(alias), [])
        XCTAssertEqual(Set(alias.modules.keys.map(\.workspace.description)), ["nomu.cons", "nomu.pa", "nomu.pb", "nomu.nomu"])

        let basic = planFixture(fixtures + "/multipackage_basic/app")
        XCTAssertEqual(errors(basic), [])
        XCTAssertNotNil(basic.modules[key(WorkspaceIdentity(scope: "nomu", name: "mpbasic"), "greet")])

        let undeclared = planFixture(fixtures + "/multipackage_undeclared/app")
        XCTAssertEqual(undeclared.diagnostics.map(\.message),
                       ["package 'greetlib' is not listed in this package's 'dependencies'"])
    }
}
