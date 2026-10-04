import XCTest
@testable import facts

// Fact store (task 167). No existing counterpart to differentially validate against, so the oracle is the
// store's defining properties: two-writer order independence, independent section hashing (the
// incremental-cache lever), and deterministic digests.
final class FactStoreTests: XCTestCase {
    private let f = SymbolID("m:Foo:bar")
    private let g = SymbolID("m:Foo:baz")

    // The two writers (Sema → ABI facts, inference → perf facts) touch disjoint fields, so either order
    // yields the identical record and identical digests.
    func testTwoWriterOrderIndependence() {
        var a = FactStore()
        a.update(f) { $0.abi.mutating = true }           // Sema first
        a.update(f) { $0.perf.stackDepthBound = 9 }      // then inference

        var b = FactStore()
        b.update(f) { $0.perf.stackDepthBound = 9 }      // inference first
        b.update(f) { $0.abi.mutating = true }           // then Sema

        XCTAssertEqual(a.facts(for: f), b.facts(for: f), "records equal regardless of writer order")
        XCTAssertEqual(a.abiDigest(), b.abiDigest(), "ABI digest independent of writer order")
        XCTAssertEqual(a.perfDigest(), b.perfDigest(), "perf digest independent of writer order")
    }

    // A perf-only edit leaves the ABI digest byte-identical and moves the perf digest; an ABI-only edit
    // the reverse. This is the property the incremental cache rests on.
    func testSectionIndependence() {
        var s = FactStore()
        s.update(f) { $0.abi.mutating = true; $0.perf.stackDepthBound = 1 }
        let abi0 = s.abiDigest(), perf0 = s.perfDigest()

        s.update(f) { $0.perf.stackDepthBound = 2 }   // perf-only change
        XCTAssertEqual(s.abiDigest(), abi0, "a perf edit must not disturb the ABI digest")
        XCTAssertNotEqual(s.perfDigest(), perf0, "a perf edit moves the perf digest")

        let perf1 = s.perfDigest()
        s.update(f) { $0.abi.mutating = false }           // ABI-only change
        XCTAssertNotEqual(s.abiDigest(), abi0, "an ABI edit moves the ABI digest")
        XCTAssertEqual(s.perfDigest(), perf1, "an ABI edit must not disturb the perf digest")
    }

    // Digests fold symbols in sorted-key order, so inserting them in different orders is identical.
    func testInsertionOrderDeterminism() {
        var a = FactStore()
        a.update(f) { $0.abi.shareable = true }
        a.update(g) { $0.perf.stackDepthBound = 3 }

        var b = FactStore()
        b.update(g) { $0.perf.stackDepthBound = 3 }   // reverse insertion order
        b.update(f) { $0.abi.shareable = true }

        XCTAssertEqual(a.abiDigest(), b.abiDigest())
        XCTAssertEqual(a.perfDigest(), b.perfDigest())
        XCTAssertEqual(a.symbolIDs, b.symbolIDs, "symbol ids enumerate in sorted order")
    }

    // "Absent" and "present with a default value" must hash differently (the tagged-optional encoding).
    func testAbsentDistinctFromDefault() {
        var absent = FactStore()
        absent.update(f) { _ in }                       // no facts set
        var present = FactStore()
        present.update(f) { $0.abi.mutating = false }   // present, value false

        XCTAssertNotEqual(absent.abiDigest(for: f), present.abiDigest(for: f),
                          "an unset field must not hash as a false field")
    }

    // The schema version participates in the whole-store digest.
    func testSchemaVersionInDigest() {
        var v1 = FactStore(schemaVersion: 1)
        var v2 = FactStore(schemaVersion: 2)
        v1.update(f) { $0.abi.mutating = true }
        v2.update(f) { $0.abi.mutating = true }
        XCTAssertNotEqual(v1.abiDigest(), v2.abiDigest(), "the schema version keys the digest")
    }

    // A set-valued field (conditional-conformance type-parameter names) hashes independent of order —
    // sorted canonically before hashing.
    func testSetFieldCanonicalized() {
        var a = FactStore(); a.update(f) { $0.abi.conditionalConformance = ["b", "a", "c"] }
        var b = FactStore(); b.update(f) { $0.abi.conditionalConformance = ["c", "a", "b"] }
        XCTAssertEqual(a.abiDigest(for: f), b.abiDigest(for: f))
    }
}
