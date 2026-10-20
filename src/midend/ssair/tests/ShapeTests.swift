import support
import XCTest
import ssair

// One shape per type (task 176.5): `shape(T)` is derived structurally from the leaf registry, so a wrapper,
// a struct, an enum and a nested aggregate each get their shaped content at the right offsets with no
// per-type rule.
final class ShapeTests: XCTestCase {
    private let structs: [String: [Type]] = [
        "String": [.stringBase],                                              // the wrapper
        "Wrap2": [.named("String", .struct_)],                                // a wrapper of a wrapper
        "Pair": [.named("String", .struct_), .int],
        "Trio": [.bool, .bool, .named("String", .struct_)],
        "Bag": [.array(.int), .named("Pair", .struct_)],
        "Plain": [.int, .bool],
        "Empty": [],
    ]
    private let enums: [String: [[Type]]] = [
        "OptS": [[.named("String", .struct_)], []],                           // some(String), none
        "Mixed": [[.int], [.named("Pair", .struct_)], [.array(.int)]],
        "Flags": [[], [.int]],
    ]
    private func env() -> ShapeEnv {
        let s = structs, e = enums
        return ShapeEnv(structFields: { s[$0] }, enumCases: { e[$0] })
    }
    private func st(_ n: String) -> Type { .named(n, .struct_) }
    private func en(_ n: String) -> Type { .named(n, .enum_) }
    private let stringLeaf = ShapeEntryKind.leaf(.stringBase)

    func testLeafAndWrappers() {
        let e = env()
        XCTAssertEqual(e.leaf(.stringBase), .stringBase)
        XCTAssertEqual(e.leaf(st("String")), .stringBase)
        XCTAssertEqual(e.leaf(st("Wrap2")), .stringBase)
        XCTAssertNil(e.leaf(st("Pair")), "a multi-field struct holding a leaf is an aggregate, not a leaf")
        XCTAssertTrue(e.isWrapper(st("String")))
        XCTAssertFalse(e.isWrapper(.stringBase))
        XCTAssertEqual(e.shape(st("String")), e.shape(.stringBase))
    }

    func testSlots() {
        let e = env()
        XCTAssertEqual(e.slots(st("String")), 2)
        XCTAssertEqual(e.slots(st("Pair")), 3)
        XCTAssertEqual(e.slots(st("Trio")), 4, "a Bool field is a whole slot")
        XCTAssertEqual(e.slots(en("Mixed")), 4, "tag word + the largest case (Pair, 3 slots)")
        XCTAssertEqual(e.slots(st("Empty")), 0)
    }

    func testStructOffsets() {
        let e = env()
        XCTAssertEqual(e.shape(st("Trio")), Shape(conditional: [ShapeEntry(offset: 16, kind: stringLeaf)]))
        XCTAssertEqual(e.shape(st("Bag")),
                       Shape(managed: [0], conditional: [ShapeEntry(offset: 8, kind: stringLeaf)]))
        XCTAssertTrue(e.shape(st("Plain")).isEmpty)
        XCTAssertFalse(e.hasConditional(st("Plain")))
        XCTAssertTrue(e.hasConditional(st("Bag")))
    }

    func testEnumCases() {
        let e = env()
        XCTAssertEqual(e.shape(en("OptS")), Shape(conditional: [ShapeEntry(offset: 0, kind: .enumCases(
            name: "OptS", cases: [ShapeCase(tag: 0, shape: Shape(conditional: [ShapeEntry(offset: 8, kind: stringLeaf)]))]))]))
        XCTAssertEqual(e.shape(en("Mixed")), Shape(conditional: [ShapeEntry(offset: 0, kind: .enumCases(
            name: "Mixed", cases: [
                ShapeCase(tag: 1, shape: Shape(conditional: [ShapeEntry(offset: 8, kind: stringLeaf)])),
                ShapeCase(tag: 2, shape: Shape(managed: [8])),
            ]))]), "a managed-pointer payload is conditional content too: the payload words are i64")
        XCTAssertTrue(e.shape(en("Flags")).isEmpty)
    }

    func testObjectFields() {
        let e = env()
        // A class body `{ header, a: Bool, s: String, r: Array }` lays its fields out from byte 8.
        let body = e.fieldsShape([.bool, st("String"), .array(.int)], base: 8)
        XCTAssertEqual(body, Shape(managed: [32], conditional: [ShapeEntry(offset: 16, kind: stringLeaf)]))
    }

    func testOpaqueResolvesToUnderlying() {
        let s = structs, en = enums
        let e = ShapeEnv(structFields: { s[$0] }, enumCases: { en[$0] }, resolveOpaque: { _ in .named("String", .struct_) })
        let some = Type.opaque(interfaces: ["P"], owner: "f")
        XCTAssertEqual(e.leaf(some), .stringBase)
        XCTAssertEqual(e.slots(some), 2)
        let unresolved = ShapeEnv(structFields: { s[$0] }, enumCases: { en[$0] })
        XCTAssertTrue(unresolved.shape(some).isEmpty)
    }
}
