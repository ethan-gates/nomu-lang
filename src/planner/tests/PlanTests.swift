import XCTest
@testable import planner

final class PlanTests: XCTestCase {

    private let me = WorkspaceIdentity(scope: "me", name: "app")
    private let nomu = LanguageWorkspace.identity

    private func plan(_ files: [String: String], entry: [String], product: ModuleJob.Product = .binary,
                      outputOptions: [String] = []) -> Plan {
        var options = PlanOptions()
        options.product = product
        options.cacheRoot = "/cache"
        options.compilerIdentity = "abc123"
        options.outputOptions = outputOptions
        return Plan(entryFiles: entry, options: options, disk: MemoryTree(files))
    }

    private func key(_ ws: WorkspaceIdentity, _ path: String) -> ModuleKey {
        ModuleKey(ws, path.isEmpty ? [] : path.split(separator: "/").map(String.init))
    }

    private let app: [String: String] = [
        "/w/nomu.yaml": "scope: me\nname: app\nexternals:\n  prov: ../p\n",
        "/w/app/pkg.json": "{\"name\": \"app\", \"dependencies\": [\"greet\"]}",
        "/w/app/cli/main.nomu": "import pkg/util\nimport greet\nimport std/time\n",
        "/w/app/util/u.nomu": "",
        "/p/nomu.yaml": "scope: them\nname: prov\n",
        "/p/greet/pkg.json": "{\"name\": \"greet\", \"products\": [\"\"]}",
        "/p/greet/g.nomu": "import pkg/inner\n",
        "/p/greet/inner/i.nomu": "",
    ]

    func testJobOrderAndOutputs() {
        let p = plan(app, entry: ["/w/app/cli/main.nomu"])
        XCTAssertEqual(p.diagnostics, [])
        let them = WorkspaceIdentity(scope: "them", name: "prov")
        // Each module after everything it imports.
        XCTAssertEqual(p.jobs.map(\.module), [key(nomu, "runtime"), key(nomu, "std/prelude"), key(me, "app/util"), key(them, "greet/inner"),
                                              key(them, "greet"), key(nomu, "std/time"), key(me, "app/cli")])
        let byKey = Dictionary(uniqueKeysWithValues: p.jobs.map { ($0.module, $0) })

        // D2: the building workspace's modules under `build/`; another workspace's under `_external/`.
        let cli = byKey[key(me, "app/cli")]!
        XCTAssertEqual(cli.product, .binary)
        XCTAssertEqual(cli.binary, "/w/build/app/cli/cli")
        XCTAssertEqual(cli.object, "/w/build/app/cli/cli.o")
        XCTAssertEqual(cli.dependencies, [key(nomu, "std/prelude"), key(me, "app/util"), key(them, "greet"),
                                          key(nomu, "std/time")])
        XCTAssertEqual(byKey[key(me, "app/util")]?.interface, "/w/build/app/util/util.nmi")
        // Every transitive import, in job order: `greet/inner` comes through `greet`.
        XCTAssertEqual(cli.visibleDependencies, [key(nomu, "std/prelude"), key(me, "app/util"), key(them, "greet/inner"),
                                                 key(them, "greet"), key(nomu, "std/time")])
        XCTAssertEqual(byKey[key(them, "greet")]?.outputDir, "/w/build/_external/them.prov/greet")
        XCTAssertEqual(byKey[key(them, "greet")]?.product, .library)

        // D4: the language workspace's modules and the runtime archive are held in the per-host cache under their
        // keys, and materialized under `build/`.
        let prelude = byKey[key(nomu, "std/prelude")]!
        let workspaceKey = HostCache.languageWorkspaceKey(compilerIdentity: "abc123", outputOptions: [])
        let preludeKey = HostCache.languageModuleKey(workspaceKey: workspaceKey, path: ["std", "prelude"])
        XCTAssertEqual(prelude.hostCacheKey, preludeKey)
        XCTAssertEqual(prelude.outputDir, "/w/build/_external/nomu.nomu/std/prelude")
        XCTAssertEqual(prelude.object, "/w/build/_external/nomu.nomu/std/prelude/prelude.o")
        XCTAssertNil(cli.hostCacheKey)
        XCTAssertEqual(p.runtimeArchive?.key, HostCache.runtimeArchiveKey(recipe: []))
        XCTAssertEqual(p.runtimeArchive?.outputDir, "/w/build/_runtime")

        // The link takes every object the plan builds, plus the runtime archive.
        XCTAssertEqual(p.links.count, 1)
        XCTAssertEqual(p.links.first?.objects, [cli.object] + p.jobs.map(\.object).filter { $0 != cli.object })
        XCTAssertEqual(p.links.first?.runtimeArchive, p.runtimeArchive?.archive)
        XCTAssertEqual(p.links.first?.output, "/w/build/app/cli/cli")
    }

    private func plan(_ files: [String: String], roots: [[String]]) -> Plan {
        var options = PlanOptions()
        options.cacheRoot = "/cache"
        options.compilerIdentity = "abc123"
        return Plan(roots: roots, options: options, disk: MemoryTree(files))
    }

    // Two targets plan as one graph: a module they share is one job, and each target links its own binary from
    // the modules it reaches (task 211).
    func testSeveralRootsShareModules() {
        var files = app
        files["/w/app/tool/main.nomu"] = "import pkg/util\n"
        let p = plan(files, roots: [["/w/app/cli/main.nomu"], ["/w/app/tool/main.nomu"]])
        XCTAssertEqual(p.diagnostics, [])
        XCTAssertEqual(p.modules.roots, [key(me, "app/cli"), key(me, "app/tool")])
        XCTAssertEqual(p.jobs.filter { $0.module == key(me, "app/util") }.count, 1)
        XCTAssertEqual(p.jobs.filter { $0.product == .binary }.map(\.module), [key(me, "app/cli"), key(me, "app/tool")])
        XCTAssertEqual(p.links.map(\.output), ["/w/build/app/cli/cli", "/w/build/app/tool/tool"])
        let byKey = Dictionary(uniqueKeysWithValues: p.jobs.map { ($0.module, $0) })
        let tool = p.links[1].objects
        XCTAssertEqual(tool.first, byKey[key(me, "app/tool")]!.object)
        XCTAssertTrue(tool.contains(byKey[key(me, "app/util")]!.object))
        XCTAssertTrue(tool.contains(byKey[key(nomu, "runtime")]!.object))
        XCTAssertTrue(tool.contains(byKey[key(nomu, "std/prelude")]!.object))
        XCTAssertFalse(tool.contains(byKey[key(WorkspaceIdentity(scope: "them", name: "prov"), "greet")]!.object))
        XCTAssertFalse(tool.contains(byKey[key(me, "app/cli")]!.object))
        // The same target twice is one root.
        XCTAssertEqual(plan(files, roots: [["/w/app/tool/main.nomu"], ["/w/app/tool/main.nomu"]]).modules.roots,
                       [key(me, "app/tool")])
    }

    // A binary target that another module of the build imports, and a target outside the build's workspace,
    // are planning errors.
    func testRootErrors() {
        let imported = plan(app, roots: [["/w/app/cli/main.nomu"], ["/w/app/util/u.nomu"]])
        XCTAssertEqual(imported.jobs, [])
        XCTAssertTrue(imported.diagnostics.contains { $0.message == "target 'app/util' is imported by 'app/cli'; build them separately" },
                      "\(imported.diagnostics)")
        let outside = plan(app, roots: [["/w/app/cli/main.nomu"], ["/p/greet/g.nomu"]])
        XCTAssertEqual(outside.jobs, [])
        XCTAssertTrue(outside.diagnostics.contains { $0.message.hasPrefix("target '/p/greet' is outside workspace 'me.app'") },
                      "\(outside.diagnostics)")
    }

    func testLibraryBuildHasNoLinkAndNoLanguageWorkspace() {
        let p = plan(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/lib/pkg.json": "{\"name\": \"lib\"}",
                      "/w/lib/l.nomu": ""], entry: ["/w/lib/l.nomu"], product: .library)
        XCTAssertEqual(p.diagnostics, [])
        XCTAssertEqual(p.jobs.map(\.module), [key(me, "lib")])
        XCTAssertEqual(p.jobs.first?.product, .library)
        XCTAssertEqual(p.links, [])
        XCTAssertNil(p.runtimeArchive)
    }

    func testPackageRootModuleAndFlags() {
        let p = plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                      "/w/app/pkg.json": "{\"name\": \"tool\"}",
                      "/w/app/main.nomu": "test import pkg/lib\n",
                      "/w/app/lib/l.nomu": ""],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(p.diagnostics, [])
        let root = p.jobs.last!
        XCTAssertEqual(root.module, key(me, "app"))
        XCTAssertEqual(root.binary, "/w/build/app/app")          // named after its last path component
        XCTAssertEqual(p.jobs.first { $0.module == key(me, "app/lib") }?.whiteBox, true)
        XCTAssertEqual(root.whiteBox, false)
    }

    // Each language-workspace module has its own key, which follows the workspace's key.
    func testLanguageModuleKeys() {
        let a = HostCache.languageModuleKey(workspaceKey: "w1", path: ["std", "prelude"])
        XCTAssertEqual(a, HostCache.languageModuleKey(workspaceKey: "w1", path: ["std", "prelude"]))
        XCTAssertNotEqual(a, HostCache.languageModuleKey(workspaceKey: "w2", path: ["std", "prelude"]))
        XCTAssertNotEqual(a, HostCache.languageModuleKey(workspaceKey: "w1", path: ["std", "time"]))
        XCTAssertNotEqual(a, HostCache.languageModuleKey(workspaceKey: "w1", path: ["std/prelude"]))
    }

    func testRuntimeArchiveKeyFollowsRecipe() {
        let a = HostCache.runtimeArchiveKey(recipe: [["cc", "-c", "runtime.c"]])
        XCTAssertEqual(a, HostCache.runtimeArchiveKey(recipe: [["cc", "-c", "runtime.c"]]))
        XCTAssertNotEqual(a, HostCache.runtimeArchiveKey(recipe: [["cc", "-O2", "-c", "runtime.c"]]))
        XCTAssertNotEqual(a, HostCache.runtimeArchiveKey(recipe: [["cc", "-c"], ["runtime.c"]]))
    }

    func testLanguageWorkspaceKeyFollowsCompilerAndOptions() {
        let a = HostCache.languageWorkspaceKey(compilerIdentity: "abc", outputOptions: [])
        XCTAssertEqual(a, HostCache.languageWorkspaceKey(compilerIdentity: "abc", outputOptions: []))
        XCTAssertNotEqual(a, HostCache.languageWorkspaceKey(compilerIdentity: "abd", outputOptions: []))
        XCTAssertNotEqual(a, HostCache.languageWorkspaceKey(compilerIdentity: "abc", outputOptions: ["-O"]))
        let plain = plan(app, entry: ["/w/app/cli/main.nomu"])
        let optimized = plan(app, entry: ["/w/app/cli/main.nomu"], outputOptions: ["-O"])
        XCTAssertNotEqual(plain.jobs.first?.hostCacheKey, optimized.jobs.first?.hostCacheKey)
    }

    func testRuntimePackageJob() {
        var options = PlanOptions()
        options.allowCoreImport = true
        options.cacheRoot = "/cache"
        let p = Plan(entryFiles: ["/w/app/main.nomu"], options: options,
                     disk: MemoryTree(["/w/nomu.yaml": "scope: me\nname: app\n", "/w/app/pkg.json": "{\"name\": \"app\"}", "/w/app/main.nomu": "import core\n"]))
        XCTAssertEqual(p.diagnostics, [])
        XCTAssertTrue(p.jobs.contains { $0.module == key(nomu, "core") })
        // The language workspace's `runtime` package is in every binary build, first, though nothing
        // imports it.
        XCTAssertEqual(p.jobs.first?.module, key(nomu, "runtime"))
        XCTAssertEqual(p.jobs.filter(\.runtimeSubsetByMembership).map(\.module), [key(nomu, "runtime")])
        XCTAssertEqual(p.modules.implicitRoots, [key(nomu, "runtime")])
    }

    func testHostCacheRoot() {
        XCTAssertEqual(HostCache.root(environment: ["NOMU_CACHE_DIR": "/x", "HOME": "/h"]), "/x")
        #if os(macOS)
        XCTAssertEqual(HostCache.root(environment: ["HOME": "/h"]), "/h/Library/Caches/nomu")
        #else
        XCTAssertEqual(HostCache.root(environment: ["HOME": "/h"]), "/h/.cache/nomu")
        XCTAssertEqual(HostCache.root(environment: ["HOME": "/h", "XDG_CACHE_HOME": "/xdg"]), "/xdg/nomu")
        #endif
    }

    func testTimings() {
        let p = plan(app, entry: ["/w/app/cli/main.nomu"])
        let t = p.timings
        XCTAssertEqual(t.modules, p.jobs.count)
        XCTAssertEqual(t.filesScanned, p.jobs.reduce(0) { $0 + $1.files.count })
        XCTAssertGreaterThan(t.directoriesListed, 0)
        // Every step ran and was timed; the total is their sum.
        XCTAssertEqual(Set(t.seconds.keys), Set(PlanTimings.Step.allCases))
        XCTAssertEqual(t.total, t.seconds.values.reduce(0, +))
    }

    // MARK: - Cycles

    func testModuleCycle() {
        let p = plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                      "/w/app/pkg.json": "{\"name\": \"app\"}",
                      "/w/app/main.nomu": "import pkg/a\n",
                      "/w/app/a/a.nomu": "import pkg/b\n",
                      "/w/app/b/b.nomu": "// b\nimport pkg/a\n"],
                     entry: ["/w/app/main.nomu"])
        XCTAssertEqual(p.diagnostics.map(\.description), ["/w/app/b/b.nomu:2:1: error: module import cycle: app/a → app/b → app/a"])
        XCTAssertEqual(p.jobs, [])
        XCTAssertEqual(p.links, [])
    }

    func testPackageCycle() {
        // No module cycle (p/main → q → p/extra), but the packages form one.
        let p = plan(["/w/nomu.yaml": "scope: me\nname: app\n",
                      "/w/p/pkg.json": "{\"name\": \"p\", \"dependencies\": [\"q\"], \"products\": [\"extra\"]}",
                      "/w/p/main/m.nomu": "import q\n",
                      "/w/p/extra/e.nomu": "",
                      "/w/q/pkg.json": "{\"name\": \"q\", \"dependencies\": [\"p\"], \"products\": [\"\"]}",
                      "/w/q/q.nomu": "import p/extra\n"],
                     entry: ["/w/p/main/m.nomu"])
        XCTAssertEqual(p.diagnostics.map(\.description), ["/w/q/q.nomu:1:1: error: package dependency cycle: p → q → p"])
    }

    // MARK: - On disk

    func testFixturePlanOnDisk() throws {
        guard let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { throw XCTSkip("not under bazel test") }
        let app = srcdir + "/_main/tests/fixtures/xworkspace_basic/consumer/app"
        let files = try FileManager.default.contentsOfDirectory(atPath: app).filter { $0.hasSuffix(".nomu") }
            .sorted().map { app + "/" + $0 }
        var options = PlanOptions()
        options.cacheRoot = "/cache"
        let p = Plan(entryFiles: files, options: options)
        XCTAssertEqual(p.diagnostics, [])
        XCTAssertTrue(p.jobs.contains { $0.outputDir.contains("/build/_external/nomu.prov/") })
        XCTAssertEqual(p.jobs.last?.product, .binary)
        XCTAssertEqual(p.links.first?.output.hasSuffix("/consumer/build/app/app"), true)
    }
}
