import XCTest
import Foundation
@testable import modules

final class WorkspacePackagesTests: XCTestCase {
    // --- scaffolding: build a temp workspace tree on disk ---

    private var roots: [String] = []
    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
    }
    private func tempWorkspace() throws -> String {
        let dir = NSTemporaryDirectory() + "nomu-ws-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try write(dir + "/nomu.yaml", "")   // the workspace marker
        roots.append(dir)
        return dir
    }
    private func write(_ path: String, _ contents: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
    // A package at `dir` named `name`, with a single root module (a `main.nomu`).
    private func singleModulePackage(_ dir: String, name: String) throws {
        try write(dir + "/pkg.json", #"{ "name": "\#(name)" }"#)
        try write(dir + "/main.nomu", "fun main() {}\n")
    }

    // --- registry scan ---

    func testScanFindsPackagesByName() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/libs/foo", name: "libfoo")
        try singleModulePackage(ws + "/vendor/net", name: "netutil")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(registry["libfoo"], ws + "/libs/foo")
        XCTAssertEqual(registry["netutil"], ws + "/vendor/net")
        XCTAssertEqual(registry.count, 2)
    }

    func testDuplicatePackageNameThrows() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/a", name: "dup")
        try singleModulePackage(ws + "/b", name: "dup")
        XCTAssertThrowsError(try scanWorkspacePackages(workspaceRoot: ws)) { error in
            guard case WorkspaceError.duplicatePackageName(let name, _, _) = error else {
                return XCTFail("expected duplicatePackageName, got \(error)")
            }
            XCTAssertEqual(name, "dup")
        }
    }

    // A nested workspace (its own `nomu.yaml`) is a boundary: its packages belong to it, not the outer scan.
    func testNestedWorkspaceIsPruned() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/libs/foo", name: "libfoo")
        try write(ws + "/sub/nomu.yaml", "")
        try singleModulePackage(ws + "/sub/inner", name: "innerpkg")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(registry["libfoo"], ws + "/libs/foo")
        XCTAssertNil(registry["innerpkg"])
    }

    // --- resolution ---

    func testResolveSingleModulePackage() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/libs/foo", name: "libfoo")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        let r = resolvePackageImport(package: "libfoo", path: [], declaredDeps: ["libfoo"], registry: registry)
        XCTAssertEqual(r, .module(dir: ws + "/libs/foo"))
    }

    func testResolveDefaultModuleAndSubmodule() throws {
        let ws = try tempWorkspace()
        // A container package: root is a container (no root source); `core` is the default, `extra` a submodule.
        try write(ws + "/libs/foo/pkg.json", #"{ "name": "libfoo", "default-module": "core" }"#)
        try write(ws + "/libs/foo/core/main.nomu", "fun main() {}\n")
        try write(ws + "/libs/foo/extra/lib.nomu", "public fun x() -> Int { return 1 }\n")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(resolvePackageImport(package: "libfoo", path: [], declaredDeps: ["libfoo"], registry: registry),
                       .module(dir: ws + "/libs/foo/core"))
        XCTAssertEqual(resolvePackageImport(package: "libfoo", path: ["extra"], declaredDeps: ["libfoo"], registry: registry),
                       .module(dir: ws + "/libs/foo/extra"))
    }

    // Strict dependencies: a package not in the importer's allow-list is rejected before any lookup.
    func testUndeclaredDependencyRejected() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/libs/foo", name: "libfoo")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(resolvePackageImport(package: "libfoo", path: [], declaredDeps: [], registry: registry),
                       .notDeclared(package: "libfoo"))
    }

    // A declared dependency absent from the workspace is external — deferred to external resolution.
    func testDeclaredButNotInWorkspaceIsExternal() throws {
        let ws = try tempWorkspace()
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(resolvePackageImport(package: "redis", path: [], declaredDeps: ["redis"], registry: registry),
                       .external(package: "redis"))
    }

    // A declared, in-workspace package whose named module does not exist resolves to `.noModule`.
    func testMissingModuleIsNoModule() throws {
        let ws = try tempWorkspace()
        try singleModulePackage(ws + "/libs/foo", name: "libfoo")
        let registry = try scanWorkspacePackages(workspaceRoot: ws)
        XCTAssertEqual(resolvePackageImport(package: "libfoo", path: ["nope"], declaredDeps: ["libfoo"], registry: registry),
                       .noModule(package: "libfoo"))
    }
}
