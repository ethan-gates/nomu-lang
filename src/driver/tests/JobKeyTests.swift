import XCTest
import Foundation
@testable import driver

// Job keys: equal inputs give equal keys; changing any one input changes the key and is named by
// `changes(from:)`; output paths and dump-only options leave it; a dependency rewritten with identical bytes
// leaves it.
final class JobKeyTests: XCTestCase {
    private var dir = ""
    private let target = (triple: "arm64-apple-macosx", cpu: "apple-m1", features: "+neon")

    override func setUpWithError() throws {
        let tmp = ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory()
        dir = tmp + "/jobkey-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try write("main.nomu", "import pkg/dep\nfun main() {}\n")
        try write("dep.nmi", "interface")
        try write("dep.bir", "templates")
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: dir + "/" + name, atomically: false, encoding: .utf8)
    }

    // A job with one file, one dependency (shipping a `.bir`) and one setting.
    private func job() -> CompileJob {
        let file = dir + "/main.nomu"
        var j = CompileJob(
            origin: ["me", "app", "cli"], files: [file], packageName: "app", packageKey: "me|app",
            isProduct: false,
            imports: [file: [CompileJob.Import(root: .pkg, path: ["dep"], alias: nil, isPublic: false, isTest: false,
                                               isImplicit: false, target: ["me", "app", "dep"])]],
            dependencies: [CompileJob.Dependency(origin: ["me", "app", "dep"], interface: dir + "/dep.nmi",
                                                 bir: dir + "/dep.bir", packageKey: "me|app")],
            product: .binary, whiteBox: false, runtimeSubsetByMembership: false,
            outputs: CompileJob.Outputs(object: dir + "/out/cli.o", interface: dir + "/out/cli.nmi",
                                        bir: dir + "/out/cli.bir", debugStem: nil))
        j.settings = ["opt.inline": "true", "opt.level": "none"]
        return j
    }

    private func keyer(_ identity: String = "abc") -> JobKeyer { JobKeyer(compilerIdentity: identity, target: target) }

    func testEqualInputsGiveEqualKeys() {
        let a = keyer().key(job(), options: EmitOptions())
        let b = keyer().key(job(), options: EmitOptions())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.changes(from: b), [])
    }

    // Each change below alters exactly the named input, and so the key.
    func testEachInputChangesTheKey() throws {
        let base = keyer().key(job(), options: EmitOptions())
        func check(_ expected: [String], _ line: UInt = #line,
                   keyer k: JobKeyer? = nil, options: EmitOptions = EmitOptions(), _ edit: (inout CompileJob) -> Void = { _ in }) {
            var j = job()
            edit(&j)
            let changed = (k ?? keyer()).key(j, options: options)
            XCTAssertNotEqual(changed.key, base.key, line: line)
            XCTAssertEqual(changed.changes(from: base), expected, line: line)
        }
        let file = dir + "/main.nomu"
        check(["compiler"], keyer: keyer("abd"))
        check(["target.cpu"], keyer: JobKeyer(compilerIdentity: "abc", target: (target.triple, "apple-m2", target.features)))
        check(["target.features"], keyer: JobKeyer(compilerIdentity: "abc", target: (target.triple, target.cpu, "+sve")))
        check(["module"]) { $0.origin = ["me", "app", "tool"] }
        check(["package.key"]) { $0.packageKey = "me|other" }
        check(["product"]) { $0.product = .library }
        check(["product.public"]) { $0.isProduct = true }
        check(["white-box"]) { $0.whiteBox = true }
        check(["runtime-subset.membership"]) { $0.runtimeSubsetByMembership = true }
        check(["setting:opt.inline"]) { $0.settings["opt.inline"] = "false" }
        check(["setting:opt.scalar"]) { $0.settings["opt.scalar"] = "true" }
        check(["imports:" + file]) {
            $0.imports[file] = [CompileJob.Import(root: .pkg, path: ["dep"], alias: "d", isPublic: false, isTest: false,
                                                  isImplicit: false, target: ["me", "app", "dep"])]
        }
        check(["dep:me/app/dep.package"]) {
            $0.dependencies = [CompileJob.Dependency(origin: ["me", "app", "dep"], interface: self.dir + "/dep.nmi",
                                                     bir: self.dir + "/dep.bir", packageKey: "me|lib")]
        }
        check(["dep:me/app/dep.bir"]) {
            $0.dependencies = [CompileJob.Dependency(origin: ["me", "app", "dep"], interface: self.dir + "/dep.nmi",
                                                     bir: nil, packageKey: "me|app")]
        }
        var subset = EmitOptions()
        subset.subsetFuncs = ["rtAlloc"]
        check(["option.runtime-subset"], options: subset)
        var prelude = EmitOptions()
        prelude.compilingPrelude = true
        check(["option.compiling-prelude"], options: prelude)

        // A second file: the file list and the new file's source and imports.
        try write("more.nomu", "fun helper() {}\n")
        check(["files", "imports:" + dir + "/more.nomu", "source:" + dir + "/more.nomu"]) { $0.files.append(self.dir + "/more.nomu") }
    }

    // File contents: a source edit, and a dependency's `.nmi` or `.bir` edit, each change only their input.
    func testFileContentsChangeTheKey() throws {
        let k = keyer()
        let base = k.key(job(), options: EmitOptions())
        try write("main.nomu", "import pkg/dep\nfun main() { }\n")
        XCTAssertEqual(k.key(job(), options: EmitOptions()).changes(from: base), ["source:" + dir + "/main.nomu"])
        let afterSource = k.key(job(), options: EmitOptions())
        try write("dep.nmi", "interface, changed")
        XCTAssertEqual(k.key(job(), options: EmitOptions()).changes(from: afterSource), ["dep:me/app/dep.nmi"])
        let afterNMI = k.key(job(), options: EmitOptions())
        try write("dep.bir", "templateZ")
        XCTAssertEqual(k.key(job(), options: EmitOptions()).changes(from: afterNMI), ["dep:me/app/dep.bir"])
    }

    // A dependency recompiled to identical bytes (a new file at the same path) leaves the key unchanged.
    func testByteIdenticalDependencyKeepsTheKey() throws {
        let k = keyer()
        let base = k.key(job(), options: EmitOptions())
        try FileManager.default.removeItem(atPath: dir + "/dep.nmi")
        try FileManager.default.removeItem(atPath: dir + "/dep.bir")
        Thread.sleep(forTimeInterval: 0.01)
        try write("dep.nmi", "interface")
        try write("dep.bir", "templates")
        XCTAssertEqual(k.key(job(), options: EmitOptions()), base)
        XCTAssertEqual(keyer().key(job(), options: EmitOptions()), base)
    }

    // Dumps, stops, job files, the core-import gate and output paths change no object, so they leave the key.
    func testDumpOnlyOptionsAndOutputsLeaveTheKey() {
        let base = keyer().key(job(), options: EmitOptions())
        var dumps = EmitOptions()
        dumps.ast = true; dumps.noir = true; dumps.ssair = true; dumps.llvm = true; dumps.nmi = true
        dumps.stopAt = .ssair; dumps.emitJobs = true; dumps.allowCoreImport = true
        XCTAssertEqual(keyer().key(job(), options: dumps), base)
        var moved = job()
        moved.outputs = CompileJob.Outputs(object: "/x/cli.o", interface: "/x/cli.nmi", bir: "/x/cli.bir", debugStem: "/x/cli")
        XCTAssertEqual(keyer().key(moved, options: EmitOptions()), base)
    }

    // The same sources and dependency outputs at another checkout path, recorded under the same debug paths,
    // give the same key; a reported path (diagnostics only) changes nothing.
    func testKeyIsIndependentOfTheCheckoutPath() throws {
        func placed(_ root: String) throws -> CompileJob {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            for (name, text) in [("main.nomu", "import pkg/dep\nfun main() {}\n"), ("dep.nmi", "interface"),
                                 ("dep.bir", "templates")] {
                try text.write(toFile: root + "/" + name, atomically: false, encoding: .utf8)
            }
            let file = root + "/main.nomu"
            var j = job()
            j.files = [file]
            j.imports = [file: j.imports.values.first!]
            j.dependencies = [CompileJob.Dependency(origin: ["me", "app", "dep"], interface: root + "/dep.nmi",
                                                    bir: root + "/dep.bir", packageKey: "me|app")]
            j.debugPaths = [file: "/nomu-src/me.app/cli/main.nomu"]
            return j
        }
        let a = try placed(dir + "/one"), b = try placed(dir + "/elsewhere/two")
        XCTAssertEqual(keyer().key(a, options: EmitOptions()), keyer().key(b, options: EmitOptions()))
        var reported = a
        reported.reportedPaths = [a.files[0]: "/shown/main.nomu"]
        XCTAssertEqual(keyer().key(reported, options: EmitOptions()), keyer().key(a, options: EmitOptions()))
    }

    // A `.bir` path with no file behind it (which fails the compile) and no `.bir` offered key differently.
    func testMissingBIRFileIsAbsent() throws {
        try FileManager.default.removeItem(atPath: dir + "/dep.bir")
        let missing = keyer().key(job(), options: EmitOptions())
        XCTAssertEqual(missing.inputs["dep:me/app/dep.bir"], "absent")
        var none = job()
        none.dependencies = [CompileJob.Dependency(origin: ["me", "app", "dep"], interface: dir + "/dep.nmi", bir: nil,
                                                   packageKey: "me|app")]
        XCTAssertEqual(keyer().key(none, options: EmitOptions()).inputs["dep:me/app/dep.bir"], "none")
    }
}
