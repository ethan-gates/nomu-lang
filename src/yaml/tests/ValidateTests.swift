import XCTest
@testable import yaml

final class ValidateTests: XCTestCase {
    private func run(_ bytes: [UInt8]) -> Validation { validate(bytes) }
    private func run(_ text: String) -> Validation { validate(Array(text.utf8)) }

    private func codes(_ v: Validation) -> [YAMLError.Code] { v.errors.errors.map(\.code) }

    // MARK: Lines

    func testEmptyInput() {
        let v = run("")
        XCTAssertEqual(v.source?.lines.lineStarts, [0])
        XCTAssertEqual(v.source?.lineEnding, LineEnding.none)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testLineStartsWithFinalLineBreak() {
        let v = run("ab\ncd\n")
        XCTAssertEqual(v.source?.lines.lineStarts, [0, 3])
        XCTAssertEqual(v.source?.lineEnding, .lf)
        XCTAssertEqual(v.source?.byteCount, 6)
    }

    func testLineStartsWithoutFinalLineBreak() {
        XCTAssertEqual(run("ab\ncd").source?.lines.lineStarts, [0, 3])
    }

    func testBlankLinesStartLines() {
        XCTAssertEqual(run("a\n\n\nb\n").source?.lines.lineStarts, [0, 2, 3, 4])
    }

    func testCRLF() {
        let v = run("a: 1\r\nb: 2\r\n")
        XCTAssertEqual(v.source?.lines.lineStarts, [0, 6])
        XCTAssertEqual(v.source?.lineEnding, .crlf)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testMixedLineEndingsReportedOnce() {
        let v = run("a\nb\r\nc\r\nd\n")
        XCTAssertEqual(codes(v), [.mixedLineEndings])
        XCTAssertEqual(v.errors.errors.first?.span, ByteSpan(start: 3, end: 5))
        XCTAssertEqual(v.source?.lineEnding, .lf)
        XCTAssertEqual(v.source?.lines.lineStarts, [0, 2, 5, 8])
    }

    func testLoneCarriageReturn() {
        XCTAssertEqual(codes(run("a\rb\n")), [.loneCarriageReturn])
        XCTAssertEqual(codes(run("a\r")), [.loneCarriageReturn])
        XCTAssertEqual(run("a\rb\n").errors.errors.first?.span, ByteSpan(start: 1, end: 2))
    }

    // MARK: Byte-order mark

    func testLeadingByteOrderMark() {
        let v = run([0xEF, 0xBB, 0xBF] + Array("a: 1\n".utf8))
        XCTAssertEqual(v.source?.hasByteOrderMark, true)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testByteOrderMarkPastStart() {
        let v = run(Array("a".utf8) + [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(codes(v), [.misplacedByteOrderMark])
        XCTAssertEqual(v.errors.errors.first?.span, ByteSpan(start: 1, end: 4))
        XCTAssertEqual(v.source?.hasByteOrderMark, false)
    }

    // MARK: Characters

    func testTabIsPermittedHere() {
        XCTAssertTrue(run("a:\t\"x\"\n").errors.isEmpty)
    }

    func testForbiddenControlCharacters() {
        XCTAssertEqual(codes(run([0x61, 0x01, 0x0A])), [.forbiddenCharacter])
        XCTAssertEqual(codes(run([0x61, 0x7F])), [.forbiddenCharacter])
        XCTAssertEqual(codes(run([0x61, 0x00])), [.forbiddenCharacter])
        XCTAssertEqual(codes(run([0xC2, 0x81])), [.forbiddenCharacter])       // C1 control
        XCTAssertEqual(run([0x61, 0x01]).errors.errors.first?.message, "control character U+0001 is not allowed")
    }

    func testInvisibleLineBreaks() {
        XCTAssertEqual(codes(run([0xC2, 0x85])), [.invisibleLineBreak])        // NEL
        XCTAssertEqual(codes(run([0xE2, 0x80, 0xA8])), [.invisibleLineBreak])  // U+2028
        XCTAssertEqual(codes(run([0xE2, 0x80, 0xA9])), [.invisibleLineBreak])  // U+2029
        XCTAssertEqual(run([0xE2, 0x80, 0xA8]).errors.errors.first?.fix, "write it as \\L in a double-quoted string")
    }

    func testNoncharacters() {
        XCTAssertEqual(codes(run([0xEF, 0xBF, 0xBE])), [.forbiddenCharacter])  // U+FFFE
        XCTAssertEqual(codes(run([0xEF, 0xBF, 0xBF])), [.forbiddenCharacter])  // U+FFFF
        XCTAssertTrue(run([0xEF, 0xBF, 0xBD]).errors.isEmpty)                   // U+FFFD
    }

    func testValidMultibyte() {
        let v = run("name: café — 😀\n")
        XCTAssertTrue(v.errors.isEmpty)
        XCTAssertEqual(v.source?.lines.lineStarts, [0])
        XCTAssertTrue(run([0xC2, 0xA0]).errors.isEmpty)                         // U+00A0, first permitted above C1
        XCTAssertTrue(run([0xF4, 0x8F, 0xBF, 0xBF]).errors.isEmpty)             // U+10FFFF
    }

    func testIndependentErrorsAreAllCollected() {
        let v = run([0x01, 0x0A, 0x02, 0x0A, 0x0D, 0x61])
        XCTAssertEqual(codes(v), [.forbiddenCharacter, .forbiddenCharacter, .loneCarriageReturn])
        XCTAssertNotNil(v.source)
    }

    // MARK: Invalid UTF-8

    private func assertInvalid(_ bytes: [UInt8], span: ByteSpan, file: StaticString = #filePath, line: UInt = #line) {
        let v = run(bytes)
        XCTAssertNil(v.source, file: file, line: line)
        XCTAssertEqual(codes(v), [.invalidUTF8], file: file, line: line)
        XCTAssertEqual(v.errors.errors.first?.span, span, file: file, line: line)
    }

    func testInvalidUTF8() {
        assertInvalid([0x80], span: ByteSpan(start: 0, end: 1))                     // stray continuation
        assertInvalid([0xC0, 0xAF], span: ByteSpan(start: 0, end: 1))               // overlong lead
        assertInvalid([0xC1, 0xBF], span: ByteSpan(start: 0, end: 1))
        assertInvalid([0xE0, 0x80, 0x80], span: ByteSpan(start: 0, end: 1))         // overlong 3-byte
        assertInvalid([0xED, 0xA0, 0x80], span: ByteSpan(start: 0, end: 1))         // surrogate
        assertInvalid([0xF0, 0x80, 0x80, 0x80], span: ByteSpan(start: 0, end: 1))   // overlong 4-byte
        assertInvalid([0xF4, 0x90, 0x80, 0x80], span: ByteSpan(start: 0, end: 1))   // past U+10FFFF
        assertInvalid([0xF5, 0x80, 0x80, 0x80], span: ByteSpan(start: 0, end: 1))
        assertInvalid([0xFF], span: ByteSpan(start: 0, end: 1))
        assertInvalid([0xE2, 0x28, 0xA1], span: ByteSpan(start: 0, end: 1))         // bad second byte
        assertInvalid([0xE2, 0x82, 0x28], span: ByteSpan(start: 0, end: 2))         // bad third byte
        assertInvalid([0xF0, 0x9F, 0x98], span: ByteSpan(start: 0, end: 3))         // truncated at end
        assertInvalid([0x61, 0xE2, 0x82], span: ByteSpan(start: 1, end: 3))
    }

    func testInvalidUTF8StopsThePass() {
        let v = run([0x01, 0x80, 0x01])
        XCTAssertEqual(codes(v), [.forbiddenCharacter, .invalidUTF8])
        XCTAssertNil(v.source)
    }

    // MARK: Block boundaries
    //
    // The vector path reads 64-byte blocks of four 16-byte vectors, so edges fall at multiples of 16 and 64.

    private func ascii(_ n: Int) -> [UInt8] { Array(repeating: UInt8(ascii: "a"), count: n) }

    func testMultibyteCharactersStraddlingABlock() {
        let e = Array("é".utf8), euro = Array("€".utf8), smile = Array("😀".utf8)
        for prefix in Array(12...17) + Array(60...67) + Array(124...129) {
            for char in [e, euro, smile] {
                let v = run(ascii(prefix) + char + ascii(140))
                XCTAssertTrue(v.errors.isEmpty, "prefix \(prefix), \(char)")
                XCTAssertNotNil(v.source)
            }
        }
    }

    func testInvalidSequenceStraddlingABlock() {
        assertInvalid(ascii(63) + [0xE2, 0x28] + ascii(80), span: ByteSpan(start: 63, end: 64))
        assertInvalid(ascii(62) + [0xF0, 0x9F, 0x28] + ascii(80), span: ByteSpan(start: 62, end: 64))
    }

    func testControlCharactersAtEveryLane() {
        for lane in 0..<128 {
            var bytes = ascii(192)
            bytes[lane] = 0x01
            let v = run(bytes)
            XCTAssertEqual(codes(v), [.forbiddenCharacter], "lane \(lane)")
            XCTAssertEqual(v.errors.errors.first?.span.start, UInt32(lane))
        }
    }

    func testTabsAndPrintableBytesAtEveryLanePass() {
        for lane in 0..<64 {
            for byte: UInt8 in [0x09, 0x20, 0x7E] {
                var bytes = ascii(128)
                bytes[lane] = byte
                XCTAssertTrue(run(bytes).errors.isEmpty, "lane \(lane), byte \(byte)")
            }
        }
    }

    func testLineFeedsAtBlockEdges() {
        var bytes = ascii(160)
        for offset in [0, 15, 16, 63, 64, 127] { bytes[offset] = 0x0A }
        XCTAssertEqual(run(bytes).source?.lines.lineStarts, [0, 1, 16, 17, 64, 65, 128])
    }

    func testCRLFSplitAcrossBlocks() {
        var bytes = ascii(128)
        bytes[63] = 0x0D
        bytes[64] = 0x0A
        let v = run(bytes)
        XCTAssertTrue(v.errors.isEmpty)
        XCTAssertEqual(v.source?.lineEnding, .crlf)

        bytes[64] = UInt8(ascii: "a")
        XCTAssertEqual(codes(run(bytes)), [.loneCarriageReturn])
    }

    func testErrorCollectionIsCapped() {
        let v = run(Array(repeating: 0x01, count: YAMLErrors.limit + 50))
        XCTAssertEqual(v.errors.errors.count, YAMLErrors.limit)
        XCTAssertTrue(v.errors.truncated)
    }

    // MARK: Vector path against the byte-by-byte path

    // Random inputs drawn mostly from bytes the validator treats specially, so both paths meet line endings,
    // controls, multibyte characters and invalid sequences at every alignment.
    func testVectorPathMatchesByteByByte() {
        var rng = SplitMix64(seed: 0x5EED)
        let alphabet: [[UInt8]] = [
            [0x61], [0x20], [0x3A], [0x0A], [0x0D, 0x0A], [0x0D], [0x09], [0x01], [0x7F],
            Array("é".utf8), Array("€".utf8), Array("😀".utf8), [0xC2, 0x85], [0xE2, 0x80, 0xA8],
            [0xEF, 0xBB, 0xBF], [0xEF, 0xBF, 0xBE], [0x80], [0xE2, 0x82],
        ]
        for _ in 0..<2000 {
            var bytes: [UInt8] = []
            let pieces = Int(rng.next() % 120)
            for _ in 0..<pieces {
                // Weight plain ASCII heavily so many blocks take the vector path.
                let pick = rng.next() % 4 == 0 ? alphabet[Int(rng.next() % UInt64(alphabet.count))] : [0x61]
                bytes += pick
            }
            let vector = bytes.withUnsafeBufferPointer { buffer -> Validation in
                var v = Validator(buffer, vector: true)
                return v.run()
            }
            let scalar = bytes.withUnsafeBufferPointer { buffer -> Validation in
                var v = Validator(buffer, vector: false)
                return v.run()
            }
            XCTAssertEqual(vector, scalar, "input \(bytes)")
        }
    }
}

// A small deterministic generator, so the property test is reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
