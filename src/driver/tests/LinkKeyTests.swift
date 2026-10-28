import XCTest
import Foundation
import LLVMBridge
@testable import driver

// Link keys (task 214): changing any one input changes the key and is named by `changes(from:)`; the same
// objects and archive at another checkout path give the same key.
final class LinkKeyTests: XCTestCase {
    private var dir = ""
    private let target = (triple: "arm64-apple-macosx", cpu: "apple-m1", features: "+neon")

    override func setUpWithError() throws {
        let tmp = ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory()
        dir = tmp + "/linkkey-" + UUID().uuidString
        try place(dir)
    }

    // A workspace at `root` holding two objects and a runtime archive under `build/`.
    private func place(_ root: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/build/_runtime", withIntermediateDirectories: true)
        for (name, text) in [("build/app.o", "app"), ("build/lib.o", "lib"), ("build/_runtime/nomu-runtime.a", "rt")] {
            try text.write(toFile: root + "/" + name, atomically: false, encoding: .utf8)
        }
    }

    private func link(_ root: String? = nil) -> LinkInputs {
        let root = root ?? dir
        return LinkInputs(objects: [root + "/build/app.o", root + "/build/lib.o"],
                          runtimeArchive: root + "/build/_runtime/nomu-runtime.a",
                          runtimeGlobals: [("nomu_setting_gc_stress", .int(0))], record: "compiler: abc\n",
                          debugInfoStorage: "objects", output: root + "/build/app", workspaceRoot: root,
                          toolchain: ["cc": "clang-2100", "ld": "ld-1267", "codesign": "c1", "sdk": "s1",
                                      "dsymutil": "llvm-21", "strip": "s2", "ar": "a1"])
    }

    private func keyer(_ identity: String = "abc") -> JobKeyer { JobKeyer(compilerIdentity: identity, target: target) }

    private func edited(_ edit: (inout LinkInputs) -> Void) -> LinkInputs {
        var l = link()
        edit(&l)
        return l
    }

    // Each change below alters exactly the named input, and so the key.
    func testEachInputChangesTheKey() throws {
        let base = keyer().key(link())
        func check(_ expected: [String], _ inputs: LinkInputs? = nil, keyer k: JobKeyer? = nil, line: UInt = #line) {
            let changed = (k ?? keyer()).key(inputs ?? link())
            XCTAssertNotEqual(changed.key, base.key, line: line)
            XCTAssertEqual(changed.changes(from: base), expected, line: line)
        }
        check(["compiler"], keyer: keyer("abd"))
        check(["target.cpu"], keyer: JobKeyer(compilerIdentity: "abc", target: (target.triple, "apple-m2", target.features)))
        check(["link.debug-info-storage", "tool:dsymutil", "tool:strip"], edited { $0.debugInfoStorage = "dsym" })
        check(["tool:ld"], edited { $0.toolchain["ld"] = "ld-1300" })
        check(["tool:sdk"], edited { $0.toolchain["sdk"] = "s3" })
        check(["binary.name"], edited { $0.output = self.dir + "/build/tool" })
        check(["config-record"], edited { $0.record = "compiler: abc\nactive: release\n" })
        check(["runtime-global:nomu_setting_gc_stress"], edited { $0.runtimeGlobals = [("nomu_setting_gc_stress", .int(1))] })
        check(["objects"], edited { $0.objects.reverse() })
        check(["object:build/lib.o", "objects"], edited { $0.objects.removeLast() })
        // A tool the link does not run leaves the key.
        XCTAssertEqual(keyer().key(edited { $0.toolchain["ar"] = "a2" }), base)

        try "app, changed".write(toFile: dir + "/build/app.o", atomically: false, encoding: .utf8)
        check(["object:build/app.o"])
        try "app".write(toFile: dir + "/build/app.o", atomically: false, encoding: .utf8)
        try "runtime, changed".write(toFile: dir + "/build/_runtime/nomu-runtime.a", atomically: false, encoding: .utf8)
        check(["runtime-archive"])
    }

    // The same objects and archive in a workspace at another path give the same key: each object enters by its
    // workspace-relative path, as the binary's debug map records it.
    func testKeyIsIndependentOfTheCheckoutPath() throws {
        let other = dir + "/elsewhere/two"
        try place(other)
        XCTAssertEqual(keyer().key(link(other)), keyer().key(link()))
        XCTAssertEqual(keyer().key(link()).inputs["objects"], "build/app.o\nbuild/lib.o")
    }

    // An object outside the workspace is recorded by its full path, in the binary and in the key.
    func testObjectOutsideTheWorkspaceKeepsItsPath() throws {
        let outside = NSTemporaryDirectory() + "outside-" + UUID().uuidString + ".o"
        try "o".write(toFile: outside, atomically: false, encoding: .utf8)
        let key = keyer().key(edited { $0.objects.append(outside) })
        XCTAssertNotNil(key.inputs["object:" + outside])
    }
}
