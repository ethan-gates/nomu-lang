import XCTest
@testable import yaml

final class LineIndexTests: XCTestCase {
    // "ab\ncd\n\nef": lines start at 0, 3, 6, 7.
    private let lines = LineIndex(lineStarts: [0, 3, 6, 7])

    func testLocationIsOneBased() {
        XCTAssertEqual(lines.location(of: 0).line, 1)
        XCTAssertEqual(lines.location(of: 0).column, 1)
    }

    func testLocationWithinAndAcrossLines() {
        XCTAssertEqual(lines.location(of: 1).line, 1)
        XCTAssertEqual(lines.location(of: 1).column, 2)
        XCTAssertEqual(lines.location(of: 3).line, 2)
        XCTAssertEqual(lines.location(of: 3).column, 1)
        XCTAssertEqual(lines.location(of: 4).column, 2)
    }

    func testLocationOnEmptyAndLastLine() {
        XCTAssertEqual(lines.location(of: 6).line, 3)
        XCTAssertEqual(lines.location(of: 7).line, 4)
        XCTAssertEqual(lines.location(of: 8).line, 4)
        XCTAssertEqual(lines.location(of: 8).column, 2)
    }

    // The line break itself belongs to the line it ends.
    func testLineBreakBelongsToItsLine() {
        XCTAssertEqual(lines.location(of: 2).line, 1)
        XCTAssertEqual(lines.location(of: 2).column, 3)
    }

    func testSingleLine() {
        let one = LineIndex(lineStarts: [0])
        XCTAssertEqual(one.location(of: 5).line, 1)
        XCTAssertEqual(one.location(of: 5).column, 6)
    }
}

final class ErrorTests: XCTestCase {
    private let lines = LineIndex(lineStarts: [0, 10, 20])

    func testRenderMatchesCompilerFormat() {
        let error = YAMLError(.unaryPlus, ByteSpan(start: 14, end: 17), "unary '+' is not allowed", fix: "write 42")
        XCTAssertEqual(error.render(file: "cfg.yaml", lines: lines),
                       "cfg.yaml:2:5: error: unary '+' is not allowed; write 42")
    }

    func testRenderWithoutFix() {
        let error = YAMLError(.trailingWhitespace, ByteSpan(at: 3), "trailing whitespace")
        XCTAssertEqual(error.render(file: "a.yaml", lines: lines), "a.yaml:1:4: error: trailing whitespace")
    }

    func testCollectionStopsAtLimit() {
        var errors = YAMLErrors()
        for i in 0..<(YAMLErrors.limit - 1) {
            XCTAssertTrue(errors.report(YAMLError(.duplicateKey, ByteSpan(at: UInt32(i)), "dup")))
        }
        // The report that fills the list says to stop.
        XCTAssertFalse(errors.report(YAMLError(.duplicateKey, ByteSpan(at: 0), "dup")))
        XCTAssertTrue(errors.isFull)
        XCTAssertFalse(errors.truncated)

        XCTAssertFalse(errors.report(YAMLError(.duplicateKey, ByteSpan(at: 0), "dup")))
        XCTAssertEqual(errors.errors.count, YAMLErrors.limit)
        XCTAssertTrue(errors.truncated)
    }

    func testTruncatedRenderAddsNote() {
        var errors = YAMLErrors()
        for _ in 0...YAMLErrors.limit {
            errors.report(YAMLError(.tag, ByteSpan(at: 0), "tags are not supported"))
        }
        let rendered = errors.render(file: "x.yaml", lines: lines).split(separator: "\n")
        XCTAssertEqual(rendered.count, YAMLErrors.limit + 1)
        XCTAssertEqual(rendered.last, "x.yaml: note: stopped after \(YAMLErrors.limit) errors")
    }

    func testCodesAreComparable() {
        let a = YAMLError(.duplicateKey, ByteSpan(start: 0, end: 4), "first wording")
        XCTAssertEqual(a.code, .duplicateKey)
        XCTAssertNotEqual(a.code, .unknownKey)
    }
}
