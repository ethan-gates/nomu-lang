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
        "Color": [[], [], []],                                                // tag only
        "OptObj": [[.named("Obj", .class_)], []],                             // over null
        "Three": [[], [.named("Obj", .class_)], []],                          // two empty cases: addresses 0 and 1
        "OptBool": [[.bool], []],                                             // over Bool's 254
        "OptPair": [[.int, .named("String", .struct_)], []],                  // over the String field's
        "OptColor": [[.named("Color", .enum_)], []],                          // over Color's unused tags
        "OptOptObj": [[.named("OptObj", .enum_)], []],                        // OptObj's next address
        "OptMixed": [[.named("Mixed", .enum_)], []],                          // over Mixed's tag word
        "Option<Obj>": [[.named("Obj", .class_)], []],                        // a generic instance, by the same rules
        "Shape": [[.named("Obj", .class_)], [.named("Obj", .class_), .int], []], // a reference in every payload
        "Small": [[.bool], [.uint8, .bool], []],                              // byte payloads, a byte tag
        "Pet": [[.named("Obj", .class_)], [.array(.int)], [], []],           // one reference per payload case
        "Mixed2": [[.named("Obj", .class_), .named("Obj", .class_)], [.named("Obj", .class_), .int]],  // a reference only in one case at 8
    ]
    private func env() -> ShapeEnv {
        let s = structs, e = enums
        return ShapeEnv(structFields: { s[$0] }, enumCases: { e[$0] })
    }
    private let obj = Type.named("Obj", .class_)
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

    func testSizes() {
        let e = env()
        XCTAssertEqual(e.size(st("String")), 16)
        XCTAssertEqual(e.size(st("Pair")), 24)
        XCTAssertEqual(e.size(st("Trio")), 24, "the String first, then two one-byte Bools")
        XCTAssertEqual(e.size(en("Mixed")), 32, "the largest case (Pair, 24 bytes), then a tag word")
        XCTAssertEqual(e.size(en("Flags")), 16, "the Int, then a tag word")
        XCTAssertEqual(e.size(st("Empty")), 0)
        XCTAssertEqual(e.align(st("Pair")), 8)
        XCTAssertEqual(e.size(.bool), 1)
        XCTAssertEqual(e.fieldsLayout([.bool, .uint8], base: 0), FieldsLayout(offsets: [0, 1], end: 2, align: 1))
        XCTAssertEqual(e.fieldsLayout([.bool, st("String"), .int], base: 8),
                       FieldsLayout(offsets: [8, 16, 32], end: 40, align: 8))
        XCTAssertEqual(e.enumCaseLayout("Mixed", 1).offsets, [0])
        XCTAssertEqual(e.structLayout("Trio").offsets, [16, 17, 0], "by alignment, largest first, ties declared")
    }

    func testMemoryOrder() {
        let e = env()
        XCTAssertEqual(e.memoryOrder([.bool, .int, .uint8, st("String")], marks: nil), [1, 3, 0, 2])
        XCTAssertEqual(e.memoryOrder([.bool, .int, .int, .uint8], marks: [false, true, false, false]), [2, 0, 3, 1],
                       "a field from a type parameter comes last")
        XCTAssertEqual(e.memoryOrder([.int, .bool, .int], marks: [true, false, true]), [1, 0, 2],
                       "fields from type parameters keep declared order")
    }

    func testStructOffsets() {
        let e = env()
        XCTAssertEqual(e.shape(st("Trio")), Shape(conditional: [ShapeEntry(offset: 0, kind: stringLeaf)]))
        XCTAssertEqual(e.shape(st("Bag")),
                       Shape(managed: [0], conditional: [ShapeEntry(offset: 8, kind: stringLeaf)]))
        XCTAssertTrue(e.shape(st("Plain")).isEmpty)
        XCTAssertFalse(e.hasConditional(st("Plain")))
        XCTAssertTrue(e.hasConditional(st("Bag")))
    }

    func testEnumCases() {
        let e = env()
        XCTAssertEqual(e.shape(en("OptS")), Shape(conditional: [ShapeEntry(offset: 0, kind: stringLeaf)]),
                       "over the String's unused tags, an enum is its payload's shape")
        XCTAssertEqual(e.shape(en("Mixed")), Shape(conditional: [ShapeEntry(offset: 0, kind: .enumCases(
            name: "Mixed", tagOffset: 24, cases: [
                ShapeCase(tag: 1, shape: Shape(conditional: [ShapeEntry(offset: 0, kind: stringLeaf)])),
                ShapeCase(tag: 2, shape: Shape(managed: [0])),
            ]))]), "a word that is not a reference in every payload case is decoded by the tag")
        XCTAssertEqual(e.shape(en("Shape")), Shape(managed: [0]), "a reference in every payload case is a plain pointer")
        XCTAssertEqual(e.enumLayout("Mixed2"), .tagged(tagOffset: 16, width: 8),
                       "a word that is a reference in one payload case only needs the tag word to decode")
        XCTAssertTrue(e.shape(en("Flags")).isEmpty)
        XCTAssertEqual(e.shape(en("OptObj")), Shape(managed: [0]), "over null: a plain pointer")
        XCTAssertEqual(e.shape(en("Three")), Shape(managed: [0]), "two empty cases below the first page")
        XCTAssertEqual(e.shape(en("Option<Obj>")), Shape(managed: [0]), "a generic instance is laid out the same way")
    }

    func testEnumLayouts() {
        let e = env()
        XCTAssertEqual(e.enumLayout("Color"), .tagOnly(width: 1))
        XCTAssertEqual(e.size(en("Color")), 1)
        XCTAssertEqual(e.enumLayout("OptObj"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptObj")), 8)
        XCTAssertEqual(e.enumLayout("Three"), .overExtraInhabitants(payloadCase: 1))
        XCTAssertEqual(e.size(en("Three")), 8)
        XCTAssertEqual(e.enumLayout("OptBool"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptBool")), 1)
        XCTAssertEqual(e.enumLayout("OptPair"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptPair")), 24)
        XCTAssertEqual(e.enumLayout("OptColor"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptColor")), 1)
        XCTAssertEqual(e.enumLayout("OptOptObj"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptOptObj")), 8)
        XCTAssertEqual(e.enumLayout("OptMixed"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("OptMixed")), 32)
        XCTAssertEqual(e.enumLayout("Flags"), .tagged(tagOffset: 8, width: 8))
        XCTAssertEqual(e.enumLayout("Mixed"), .tagged(tagOffset: 24, width: 8))
        XCTAssertEqual(e.enumLayout("Shape"), .spareBits(payloadCases: [0, 1], tagOffset: 0),
                       "a reference at offset 0 in every payload case carries the case")
        XCTAssertEqual(e.size(en("Shape")), 16, "no tag word")
        XCTAssertEqual(e.enumLayout("Small"), .tagged(tagOffset: 2, width: 1))
        XCTAssertEqual(e.size(en("Small")), 3, "byte payloads and a byte tag")
        XCTAssertEqual(e.enumLayout("Pet"), .spareBits(payloadCases: [0, 1], tagOffset: 0))
        XCTAssertEqual(e.size(en("Pet")), 8, "the case in the reference's spare bits")
        XCTAssertEqual(e.shape(en("Pet")), Shape(managed: [0]), "the collector masks the tag off")
        XCTAssertEqual(e.extraInhabitants(en("Pet")), ExtraInhabitants(offset: 0, width: 8, shift: 3, first: 4, count: 508))
        XCTAssertEqual(e.extraInhabitants(en("Shape")), ExtraInhabitants(offset: 0, width: 8, shift: 3, first: 3, count: 509))
        let marked = ShapeEnv(structFields: { _ in nil }, enumCases: { $0 == "P" ? [[.named("Obj", .class_)], [.named("Obj", .class_)]] : nil },
                              enumCaseMarks: { _ in [[true], [false]] })
        XCTAssertEqual(marked.enumLayout("P"), .tagged(tagOffset: 8, width: 8), "a field from a type parameter keeps the tag")
        let off = env()
        off.spareBits = false
        XCTAssertEqual(off.enumLayout("Pet"), .tagged(tagOffset: 8, width: 8), "measure.no_spare_bits")
        XCTAssertEqual(off.enumLayout("Shape"), .tagged(tagOffset: 16, width: 8))
        XCTAssertEqual(e.enumLayout("Option<Obj>"), .overExtraInhabitants(payloadCase: 0))
        XCTAssertEqual(e.size(en("Option<Obj>")), 8)
        XCTAssertEqual(e.enumCaseLayout("Flags", 1).offsets, [0])
        XCTAssertEqual(e.enumCaseLayout("Mixed", 2).offsets, [0], "every payload from byte 0")
        XCTAssertEqual(e.enumExtraInhabitantIndex("Three", 2), 1)
    }

    func testExtraInhabitants() {
        let e = env()
        XCTAssertNil(e.extraInhabitants(.int))
        XCTAssertNil(e.extraInhabitants(.uint8))
        XCTAssertEqual(e.extraInhabitants(obj), ExtraInhabitants(offset: 0, width: 8, first: 0, count: 4096))
        XCTAssertEqual(e.extraInhabitants(.bool), ExtraInhabitants(offset: 0, width: 1, first: 2, count: 254))
        XCTAssertEqual(e.extraInhabitants(st("String")),
                       ExtraInhabitants(offset: 8, width: 8, shift: 60, first: 3, count: 13))
        XCTAssertEqual(e.extraInhabitants(st("Pair")),
                       ExtraInhabitants(offset: 8, width: 8, shift: 60, first: 3, count: 13), "the String field's")
        XCTAssertEqual(e.extraInhabitants(en("Color")), ExtraInhabitants(offset: 0, width: 1, first: 3, count: 253))
        XCTAssertEqual(e.extraInhabitants(en("OptColor")), ExtraInhabitants(offset: 0, width: 1, first: 4, count: 252),
                       "one of Color's unused tags is the enum's own empty case")
        XCTAssertEqual(e.extraInhabitants(en("OptObj")), ExtraInhabitants(offset: 0, width: 8, first: 1, count: 4095),
                       "null is taken")
        XCTAssertEqual(e.extraInhabitants(en("Three")), ExtraInhabitants(offset: 0, width: 8, first: 2, count: 4094))
        XCTAssertEqual(e.extraInhabitants(en("Flags")),
                       ExtraInhabitants(offset: 8, width: 8, first: 2, count: ExtraInhabitants.maxCount - 2),
                       "an appended tag word's unused values")
        XCTAssertEqual(e.extraInhabitants(en("OptPair")),
                       ExtraInhabitants(offset: 16, width: 8, shift: 60, first: 4, count: 12))
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
        XCTAssertEqual(e.size(some), 16)
        let unresolved = ShapeEnv(structFields: { s[$0] }, enumCases: { en[$0] })
        XCTAssertTrue(unresolved.shape(some).isEmpty)
    }
}
