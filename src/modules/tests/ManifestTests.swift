import XCTest
import Foundation
@testable import modules

final class ManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }

    // A name-only manifest is valid; every section past `name` defaults (empty lists, nil version).
    func testNameOnlyDefaults() throws {
        let m = try decode(#"{ "name": "foo" }"#)
        XCTAssertEqual(m.name, "foo")
        XCTAssertNil(m.version)
        XCTAssertEqual(m.sealed, [])
        XCTAssertTrue(m.bin.isEmpty)
        XCTAssertTrue(m.tests.isEmpty)
    }

    // Every section decodes: version, the sealed module list, bin declarations, and test modules.
    func testFullManifest() throws {
        let m = try decode(#"""
        {
          "name": "mypkg",
          "version": "0.1.0",
          "sealed": ["internal/secret", "net/raw"],
          "bin": [
            { "name": "app", "module": "" },
            { "name": "tool", "module": "cmd/tool" }
          ],
          "tests": [ { "module": "tests/core" } ]
        }
        """#)
        XCTAssertEqual(m.name, "mypkg")
        XCTAssertEqual(m.version, "0.1.0")
        XCTAssertEqual(m.sealed, ["internal/secret", "net/raw"])
        XCTAssertEqual(m.bin.map(\.name), ["app", "tool"])
        XCTAssertEqual(m.bin.map(\.module), ["", "cmd/tool"])
        XCTAssertEqual(m.tests.map(\.module), ["tests/core"])
    }

    // The empty string names the root module (the single-executable shorthand's explicit form).
    func testBinRootModuleIsEmptyString() throws {
        let m = try decode(#"{ "name": "p", "bin": [ { "name": "p", "module": "" } ] }"#)
        XCTAssertEqual(m.bin.first?.module, "")
    }

    // A missing required `name` is a decode failure.
    func testMissingNameFails() {
        XCTAssertThrowsError(try decode(#"{ "version": "1.0" }"#))
    }

    // On disk: an absent `pkg.json` is not an error — an unmanifested tree still compiles under the
    // default identity, so the loader returns nil.
    func testLoadAbsentReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNil(try loadManifest(packageRoot: dir))
    }

    // On disk: a present, valid manifest decodes.
    func testLoadValid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{ "name": "ondisk", "version": "2.0" }"#.write(
            toFile: dir + "/pkg.json", atomically: true, encoding: .utf8)
        let m = try loadManifest(packageRoot: dir)
        XCTAssertEqual(m?.name, "ondisk")
        XCTAssertEqual(m?.version, "2.0")
    }

    // On disk: a present-but-malformed manifest is fatal, wrapped as ManifestError.malformed.
    func testLoadMalformedThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{ not json".write(toFile: dir + "/pkg.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try loadManifest(packageRoot: dir)) { error in
            guard case ManifestError.malformed = error else {
                return XCTFail("expected ManifestError.malformed, got \(error)")
            }
        }
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "nomu-manifest-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
