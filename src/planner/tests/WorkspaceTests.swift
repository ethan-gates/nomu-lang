import XCTest
import modules
@testable import planner

final class WorkspaceTests: XCTestCase {

    // MARK: - nomu.yaml

    private func parse(_ text: String) -> (WorkspaceConfig?, [String]) {
        let (c, d) = WorkspaceConfig.parse(Array(text.utf8), file: "nomu.yaml")
        return (c, d.map(\.description))
    }

    func testConfigIdentityAndPins() {
        let (c, d) = parse("""
            # a comment
            scope: ethan
            name: "http_kit"
            externals:
              util: ../util
              other: "/abs/other"
            """)
        XCTAssertEqual(d, [])
        XCTAssertEqual(c?.identity, WorkspaceIdentity(scope: "ethan", name: "http_kit"))
        XCTAssertEqual(c?.pins.map(\.alias), ["util", "other"])
        XCTAssertEqual(c?.pins.map(\.path), ["../util", "/abs/other"])
        XCTAssertEqual(c?.pins.first?.line, 5)
        XCTAssertEqual(c?.pins.first?.column, 9)
    }

    func testConfigErrors() {
        XCTAssertEqual(parse("name: app\n").1,
                       ["nomu.yaml: error: missing 'scope:' — every workspace declares its scope (e.g. 'scope: my_handle')"])
        XCTAssertEqual(parse("scope: me\nname: nomu-lang\n").1,
                       ["nomu.yaml:2:7: error: workspace name 'nomu-lang' must match [a-z][a-z0-9_]*"])
        XCTAssertEqual(parse("scope: Me\nname: a\n").1,
                       ["nomu.yaml:1:8: error: workspace scope 'Me' must match [a-z][a-z0-9_]*"])
        XCTAssertEqual(parse("scope: a\nscope: b\nname: c\n").1, ["nomu.yaml:2:1: error: 'scope' is set more than once"])
        XCTAssertEqual(parse("scope: a\nname: b\nexternals:\n  x: ../x\n  x: ../y\n  Bad: ../z\n").1,
                       ["nomu.yaml:5:3: error: pin alias 'x' is declared more than once",
                        "nomu.yaml:6:3: error: pin alias 'Bad' must match [a-z][a-z0-9_]*"])
    }

    func testPathComponentRule() {
        XCTAssertTrue(isPathComponent("a"))
        XCTAssertTrue(isPathComponent("std_v2"))
        XCTAssertFalse(isPathComponent(""))
        XCTAssertFalse(isPathComponent("_x"))
        XCTAssertFalse(isPathComponent("2x"))
        XCTAssertFalse(isPathComponent("a-b"))
        XCTAssertFalse(isPathComponent("aB"))
    }

    // MARK: - Loading workspaces

    // A tree that counts listings per directory.
    final class CountingTree: SourceTree {
        let inner: MemoryTree
        var lists: [String: Int] = [:]
        init(_ files: [String: String]) { inner = MemoryTree(files) }
        func list(_ path: String) -> [DirEntry]? { lists[path, default: 0] += 1; return inner.list(path) }
        func read(_ path: String) -> [UInt8]? { inner.read(path) }
        func kind(of path: String) -> DirEntry.Kind? { inner.kind(of: path) }
        func canonical(_ path: String) -> String? { inner.canonical(path) }
    }

    private func load(_ files: [String: String], entry: String, languageWorkspace: Bool = false) -> (WorkspaceSet, CountingTree) {
        let tree = CountingTree(files)
        return (WorkspaceSet(entry: entry, disk: tree, includeLanguageWorkspace: languageWorkspace), tree)
    }

    func testRootFoundAboveEntry() {
        let (ws, _) = load(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/cli/main.nomu": "fun main() {}\n"],
                           entry: "/w/app/cli/main.nomu")
        XCTAssertEqual(ws.diagnostics, [])
        XCTAssertEqual(ws.root.identity, WorkspaceIdentity(scope: "me", name: "app"))
        XCTAssertEqual(ws.root.root, "/w")
    }

    // A build needs a workspace: with no `nomu.yaml` above the entry, planning stops at one error, whether or
    // not a `pkg.json` is present, and resolution adds nothing.
    func testNoWorkspaceIsAnError() {
        let files = ["/loose/pkg/pkg.json": "{\"name\": \"p\"}", "/loose/pkg/src/a.nomu": "import pkg/b\n"]
        let (ws, _) = load(files, entry: "/loose/pkg/src/a.nomu")
        XCTAssertTrue(ws.missingWorkspace)
        XCTAssertEqual(ws.diagnostics.map(\.description),
                       ["error: no nomu.yaml found at or above '/loose/pkg/src' — a build needs a workspace: a "
                        + "nomu.yaml declaring its 'scope' and 'name'"])
        let table = ModuleTable(workspaces: ws, entryFiles: ["/loose/pkg/src/a.nomu"])
        XCTAssertEqual(table.diagnostics, ws.diagnostics)
        XCTAssertTrue(table.modules.isEmpty)
    }

    func testPinsAtAnyDepth() {
        let (ws, _) = load([
            "/a/nomu.yaml": "scope: s\nname: a\nexternals:\n  bee: ../b\n  bee_again: ../b/.\n",
            "/b/nomu.yaml": "scope: s\nname: b\nexternals:\n  cee: ../c\n",
            "/c/nomu.yaml": "scope: s\nname: c\n",
        ], entry: "/a")
        XCTAssertEqual(ws.diagnostics, [])
        XCTAssertEqual(ws.byIdentity.keys.map(\.description).sorted(), ["s.a", "s.b", "s.c"])
        XCTAssertEqual(ws.root.pins, ["bee": WorkspaceIdentity(scope: "s", name: "b"),
                                      "bee_again": WorkspaceIdentity(scope: "s", name: "b")])
        XCTAssertEqual(ws.byIdentity[WorkspaceIdentity(scope: "s", name: "b")]?.pins["cee"],
                       WorkspaceIdentity(scope: "s", name: "c"))
    }

    func testPinErrors() {
        let (ws, _) = load([
            "/a/nomu.yaml": "scope: s\nname: a\nexternals:\n  dup: ../b\n  gone: ../nowhere\n  bare: ../d\n",
            "/b/nomu.yaml": "scope: s\nname: a\n",
            "/d/x.nomu": "",
        ], entry: "/a")
        XCTAssertEqual(ws.diagnostics.map(\.description), [
            "/a/nomu.yaml:4:8: error: two workspaces in this build are both 's.a': '/a' and '/b'",
            "/a/nomu.yaml:5:9: error: pinned workspace 'gone' at '../nowhere' does not exist",
            "/a/nomu.yaml:6:9: error: pinned workspace 'bare' at '../d' has no nomu.yaml",
        ])
    }

    func testLanguageWorkspace() {
        let (ws, _) = load(["/w/nomu.yaml": "scope: me\nname: app\n"], entry: "/w", languageWorkspace: true)
        XCTAssertEqual(ws.diagnostics, [])
        guard let nomu = ws.byIdentity[LanguageWorkspace.identity] else { return XCTFail("no language workspace") }
        XCTAssertTrue(nomu.isLanguageWorkspace)
        let pkgs = ws.packages(in: nomu)
        XCTAssertEqual(pkgs.keys.sorted(), ["core", "runtime", "std"])
        XCTAssertEqual(pkgs["std"]?.manifest.defaultModule, "prelude")
        XCTAssertFalse(nomu.moduleFiles(pkgs["std"]!.root + "/prelude").isEmpty)
        XCTAssertEqual(nomu.moduleFiles(pkgs["core"]!.root), [LanguageWorkspace.root + "/core/core.nomu"])

        // A user workspace may not claim the language workspace's identity.
        let (clash, _) = load(["/w/nomu.yaml": "scope: nomu\nname: nomu\n"], entry: "/w", languageWorkspace: true)
        XCTAssertEqual(clash.diagnostics.count, 1)
        XCTAssertTrue(clash.diagnostics[0].message.hasPrefix("two workspaces in this build are both 'nomu.nomu'"))
    }

    // MARK: - Packages

    func testPackageWalk() {
        let (ws, tree) = load([
            "/w/nomu.yaml": "scope: me\nname: app\n",
            "/w/libs/greet/pkg.json": "{\"name\": \"greet\"}",
            "/w/libs/greet/hello/a.nomu": "",
            "/w/app/pkg.json": "{\"name\": \"app\"}",
            "/w/app/main.nomu": "",
            "/w/build/x/pkg.json": "{\"name\": \"stale\"}",
            "/w/.hidden/pkg.json": "{\"name\": \"hidden\"}",
            "/w/nested/nomu.yaml": "scope: me\nname: nested\n",
            "/w/nested/inner/pkg.json": "{\"name\": \"inner\"}",
        ], entry: "/w/app/main.nomu")
        let pkgs = ws.packages(in: ws.root)
        XCTAssertEqual(ws.diagnostics, [])
        XCTAssertEqual(pkgs.keys.sorted(), ["app", "greet"])
        XCTAssertEqual(pkgs["greet"]?.root, "/w/libs/greet")

        // Each directory is listed once: the walk's listing of a package root serves its module files, and a
        // second registry request reuses the first walk.
        XCTAssertEqual(ws.root.moduleFiles("/w/app"), ["/w/app/main.nomu"])
        _ = ws.packages(in: ws.root)
        XCTAssertEqual(ws.root.moduleFiles("/w/libs/greet/hello"), ["/w/libs/greet/hello/a.nomu"])
        XCTAssertEqual(ws.root.moduleFiles("/w/libs/greet/hello"), ["/w/libs/greet/hello/a.nomu"])
        XCTAssertEqual(tree.lists.values.max(), 1)
        XCTAssertNil(tree.lists["/w/build"])
        XCTAssertNil(tree.lists["/w/.hidden"])
        XCTAssertNil(tree.lists["/w/nested/inner"])
    }

    func testPackageErrors() {
        let (ws, _) = load([
            "/w/nomu.yaml": "scope: me\nname: app\n",
            "/w/a/pkg.json": "{\"name\": \"dup\"}",
            "/w/b/pkg.json": "{\"name\": \"dup\"}",
            "/w/c/pkg.json": "{\"name\": \"std\"}",
            "/w/d/pkg.json": "{ not json",
        ], entry: "/w")
        let pkgs = ws.packages(in: ws.root)
        XCTAssertEqual(pkgs.keys.sorted(), ["dup"])
        let messages = ws.diagnostics.map(\.description)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], "/w/b/pkg.json: error: two packages in workspace 'me.app' are both named 'dup': "
                                    + "'/w/a' and '/w/b'")
        XCTAssertTrue(messages[1].hasPrefix("/w/c/pkg.json: error: package name 'std' is reserved"))
        XCTAssertTrue(messages[2].hasPrefix("/w/d/pkg.json: error: invalid manifest '/w/d/pkg.json'"))
    }

    // MARK: - On disk

    // The cross-workspace fixtures load from disk with their pins.
    func testFixtureWorkspacesOnDisk() throws {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        let consumer = srcdir + "/_main/tests/fixtures/xworkspace_alias/consumer"
        let ws = WorkspaceSet(entry: consumer, includeLanguageWorkspace: true)
        XCTAssertEqual(ws.diagnostics, [])
        XCTAssertEqual(ws.byIdentity.keys.map(\.description).sorted(), ["nomu.cons", "nomu.nomu", "nomu.pa", "nomu.pb"])
        XCTAssertEqual(ws.root.pins.keys.sorted(), ["wsa", "wsb"])
    }
}
