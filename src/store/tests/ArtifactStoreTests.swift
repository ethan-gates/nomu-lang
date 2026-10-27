import XCTest
import Foundation
@testable import store

// The store: publish, look up and materialize; one blob for identical outputs; concurrent publishes of one key;
// results naming a missing or altered blob discarded; leftovers of interrupted writes ignored and listed.
final class ArtifactStoreTests: XCTestCase {
    private var store = ArtifactStore(root: "")
    private var work = ""

    override func setUpWithError() throws {
        let tmp = ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory()
        work = tmp + "/store-" + UUID().uuidString
        store = ArtifactStore(root: work + "/cache")
    }

    private func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    // Build outputs `a.o` and `a.nmi` in a directory of their own and publish them under `key`.
    @discardableResult
    private func publish(_ key: String, _ text: String = "object", inputs: [String: String] = [:]) throws -> ActionResult {
        let dir = work + "/out-" + UUID().uuidString
        try write(text, dir + "/a.o")
        try write(text + " interface", dir + "/a.nmi")
        return try store.publish(key, outputsIn: dir, files: ["a.o", "a.nmi"], inputs: inputs)
    }

    private func blobOf(_ result: ActionResult, _ name: String) -> String {
        store.blob(result.files.first { $0.path == name }!.hash)
    }

    func testPublishLookUpAndMaterialize() throws {
        XCTAssertNil(store.lookup("k1"))
        let published = try publish("k1", inputs: ["key": "k1"])
        let result = try XCTUnwrap(store.lookup("k1"))
        XCTAssertEqual(result, published)
        XCTAssertEqual(result.files.map(\.path), ["a.nmi", "a.o"])
        XCTAssertEqual(result.inputs, ["key": "k1"])
        let target = work + "/build/m"
        try store.materialize(result, into: target)
        XCTAssertEqual(read(target + "/a.o"), "object")
        XCTAssertEqual(read(target + "/a.nmi"), "object interface")
        // Materializing again replaces what is there.
        try write("stale", target + "/a.o")
        try store.materialize(result, into: target)
        XCTAssertEqual(read(target + "/a.o"), "object")
        XCTAssertEqual(store.leftovers(), [])
        XCTAssertNil(store.lookup("k2"))
    }

    // A materialized output changed in place leaves its blob as it was.
    func testMaterializedOutputIsIndependentOfItsBlob() throws {
        let result = try publish("k")
        let target = work + "/build/m"
        try store.materialize(result, into: target)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: target + "/a.o"))
        handle.write(Data("OBJECT".utf8))
        try handle.close()
        XCTAssertEqual(read(blobOf(result, "a.o")), "object")
        XCTAssertNotNil(store.lookup("k"))
    }

    // Two results with an identical output name one blob.
    func testIdenticalOutputsShareABlob() throws {
        let a = try publish("k1", "same"), b = try publish("k2", "same")
        XCTAssertEqual(blobOf(a, "a.o"), blobOf(b, "a.o"))
        let blobs = try FileManager.default.contentsOfDirectory(atPath: store.root + "/cas")
        XCTAssertEqual(blobs.count, 2)
    }

    // Writers racing on one key all succeed, and the result they leave is whole.
    func testConcurrentPublishOfOneKey() throws {
        let failures = Atomic()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { try publish("shared") } catch { failures.add() }
        }
        XCTAssertEqual(failures.value, 0)
        let result = try XCTUnwrap(store.lookup("shared"))
        XCTAssertEqual(read(blobOf(result, "a.nmi")), "object interface")
        XCTAssertEqual(store.leftovers(), [])
    }

    func testMissingBlobDiscardsTheResult() throws {
        let result = try publish("k")
        try FileManager.default.removeItem(atPath: blobOf(result, "a.nmi"))
        XCTAssertNil(store.lookup("k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root + "/ac/k"))
        try publish("k")
        XCTAssertNotNil(store.lookup("k"))
    }

    // An altered blob of the same size fails its digest.
    func testAlteredBlobDiscardsTheResult() throws {
        let result = try publish("k")
        try write("objecT", blobOf(result, "a.o"))
        XCTAssertNil(store.lookup("k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root + "/ac/k"))
    }

    func testUnreadableResultIsDiscarded() throws {
        try publish("k")
        try write("{", store.root + "/ac/k")
        XCTAssertNil(store.lookup("k"))
    }

    // Temporary files an interrupted write left are never served and are listed as leftovers.
    func testInterruptedWritesAreIgnoredAndListed() throws {
        try publish("k")
        let partialBlob = store.root + "/cas/" + ArtifactStore.tmpPrefix + "1-2"
        let partialResult = store.root + "/ac/" + ArtifactStore.tmpPrefix + "3-4"
        try write("partial", partialBlob)
        try write("{", partialResult)
        XCTAssertNotNil(store.lookup("k"))
        XCTAssertEqual(store.leftovers(), [partialResult, partialBlob].sorted())
    }

    func testContentHash() {
        XCTAssertEqual(ContentHash.of(Data()), "cbf29ce484222325")
        XCTAssertNotEqual(ContentHash.of(Data("ab".utf8)), ContentHash.of(Data("ba".utf8)))
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
