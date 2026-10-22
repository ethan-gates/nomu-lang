import XCTest
import yaml

final class CodableTests: XCTestCase {
    struct Package: Codable, Equatable {
        enum Mode: String, Codable { case all, none }
        struct GC: Codable, Equatable {
            var nurseryReserve: Int
            var debug: Bool?
            enum CodingKeys: String, CodingKey {
                case nurseryReserve = "nursery_reserve"
                case debug
            }
        }
        var name: String
        var version: String
        var mode: Mode
        var ratio: Double
        var gc: GC
        var tags: [String]
        var notes: String?
        var limits: [String: Int]
    }

    private let source = """
        name: café  # display name
        version: 1.2.3
        mode: all
        ratio: 2.5
        gc:
          nursery_reserve: 33554432
        tags:
          - fast
          - "quoted"
        notes: |
          two
          lines
        limits:
          a: 1
          b: 2

        """

    private func codes(_ body: () throws -> Void) -> [YAMLError.Code] {
        do {
            try body()
            return []
        } catch let errors as YAMLErrors {
            return errors.errors.map(\.code)
        } catch {
            return []
        }
    }

    func testDecodesStructs() throws {
        let p = try YAMLDecoder().decode(Package.self, from: source)
        XCTAssertEqual(p, Package(name: "café", version: "1.2.3", mode: .all, ratio: 2.5,
                                  gc: .init(nurseryReserve: 33554432, debug: nil), tags: ["fast", "quoted"],
                                  notes: "two\nlines\n", limits: ["a": 1, "b": 2]))
    }

    func testTypesAreStrict() {
        struct I: Decodable { var v: Int }
        struct S: Decodable { var v: String }
        struct B: Decodable { var v: Bool }
        struct Small: Decodable { var v: Int8 }
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(I.self, from: "v: \"42\"\n") }, [.typeMismatch])
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(I.self, from: "v: 1.5\n") }, [.typeMismatch])
        // An integer is not a float: the Core schema resolves `42` as an integer.
        struct D: Decodable { var v: Double }
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(D.self, from: "v: 42\n") }, [.typeMismatch])
        XCTAssertEqual(try? YAMLDecoder().decode(D.self, from: "v: 42.0\n").v, 42)
        XCTAssertEqual(try? YAMLDecoder().decode(D.self, from: "v: 1e3\n").v, 1000)
        do {
            _ = try YAMLDecoder().decode(D.self, from: "v: 42\n")
        } catch let errors as YAMLErrors {
            XCTAssertEqual(errors.errors[0].fix, "write it as a float: 42.0")
        } catch {}
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(S.self, from: "v: 42\n") }, [.typeMismatch])
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(S.self, from: "v: []\n") }, [.typeMismatch])
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(B.self, from: "v: yes\n") }, [.typeMismatch])
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(Small.self, from: "v: 300\n") }, [.typeMismatch])
        XCTAssertEqual(try? YAMLDecoder().decode(Small.self, from: "v: -128\n").v, -128)
    }

    func testMissingAndNullKeys() {
        struct R: Decodable { var a: Int; var b: Int? }
        XCTAssertEqual(codes { _ = try YAMLDecoder().decode(R.self, from: "b: 1\n") }, [.missingKey])
        XCTAssertNil(try? YAMLDecoder().decode(R.self, from: "a: 1\nb: null\n").b)
        XCTAssertEqual(try? YAMLDecoder().decode(R.self, from: "a: 1\n").a, 1)
    }

    func testUnknownKeysAreRejectedWithSuggestions() throws {
        struct R: Decodable { var inline: Bool?; var mono: String? }
        do {
            _ = try YAMLDecoder().decode(R.self, from: "inlne: true\nmono: all\nextra: 1\n")
            XCTFail("unknown keys accepted")
        } catch let errors as YAMLErrors {
            XCTAssertEqual(errors.errors.map(\.code), [.unknownKey, .unknownKey])
            XCTAssertEqual(errors.errors[0].span, ByteSpan(start: 0, end: 5))
            XCTAssertEqual(errors.errors[0].fix, "did you mean `inline`?")
            XCTAssertNil(errors.errors[1].fix)
        }
        XCTAssertNotNil(try YAMLDecoder(unknownKeys: .ignore).decode(R.self, from: "inlne: true\n"))
        // Keys of a dictionary are all read.
        XCTAssertEqual(try YAMLDecoder().decode([String: Int].self, from: "x: 1\ny: 2\n"), ["x": 1, "y": 2])
    }

    func testErrorsPointAtTheSource() throws {
        do {
            _ = try YAMLDecoder().decode(Package.self, from: source.replacingOccurrences(of: "33554432", with: "big"))
            XCTFail("decoded")
        } catch let errors as YAMLErrors {
            let e = errors.errors[0]
            XCTAssertEqual(e.code, .typeMismatch)
            XCTAssertEqual(e.message, "expected an integer for `gc.nursery_reserve`, found a string")
            let doc = try YAMLDocument(parsing: source)
            XCTAssertEqual(doc.location(of: e.span.start).line, 6)
        }
        do {
            _ = try YAMLDecoder().decode(Package.self, from: source.replacingOccurrences(of: "\"quoted\"", with: "[]"))
            XCTFail("decoded")
        } catch let errors as YAMLErrors {
            XCTAssertEqual(errors.errors[0].message, "expected a string for `tags[1]`, found a sequence")
        }
    }

    func testSpansByCodingPath() throws {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int?
            init(_ s: String) { stringValue = s }
            init(_ i: Int) { stringValue = "\(i)"; intValue = i }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { self.init(intValue) }
        }
        let doc = try YAMLDocument(parsing: source)
        XCTAssertEqual(doc.node(at: [Key("gc"), Key("nursery_reserve")])?.location.line, 6)
        XCTAssertEqual(doc.node(at: [Key("tags"), Key(1)])?.string, "quoted")
        XCTAssertNil(doc.node(at: [Key("tags"), Key(5)]))
        XCTAssertNil(doc.node(at: [Key("nope")]))
    }

    // MARK: Encoding

    func testEncodes() throws {
        struct Small: Codable { var name: String; var count: Int8; var tags: [String]; var maybe: Int? }
        XCTAssertEqual(try YAMLEncoder().encodeToString(Small(name: "true", count: 3, tags: [], maybe: nil)),
                       "name: 'true'\ncount: 3\ntags: []\n")
        XCTAssertEqual(try YAMLEncoder(sortedKeys: true).encodeToString(["b": 1, "a": 2]), "a: 2\nb: 1\n")
        XCTAssertEqual(try YAMLEncoder().encodeToString([1, 2]), "- 1\n- 2\n")
        XCTAssertEqual(try YAMLEncoder().encodeToString("multi\nline\ntext\n"), "|\n  multi\n  line\n  text\n")
        XCTAssertThrowsError(try YAMLEncoder().encode(UInt64.max))
        XCTAssertThrowsError(try YAMLEncoder().encode(Double.nan))
    }

    func testRoundTrips() throws {
        let p = try YAMLDecoder().decode(Package.self, from: source)
        let text = try YAMLEncoder(sortedKeys: true).encodeToString(p)
        XCTAssertEqual(try YAMLDecoder().decode(Package.self, from: text), p)
    }

    func testEncodeValueFeedsEdits() throws {
        let doc = try YAMLDocument(parsing: "# keep\npkg: old  # comment\n")
        var edits = YAMLEdits(doc)
        edits.set(doc.root["pkg"]!, to: try YAMLEncoder().encodeValue(["n": 1]))
        XCTAssertEqual(String(decoding: try edits.apply().bytes, as: UTF8.self), "# keep\npkg: # comment\n  n: 1\n")
    }
}
