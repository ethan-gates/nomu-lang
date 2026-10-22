// Byte spans and the line index. Every position in the library is a byte offset into the source; line and
// column are resolved only when something is shown to a person (spec §2.1 caps a file at 2³² − 1 bytes, so
// offsets are UInt32).

// A half-open byte range `[start, end)` in the source.
public struct ByteSpan: Equatable, Hashable {
    public let start: UInt32
    public let end: UInt32

    public init(start: UInt32, end: UInt32) {
        precondition(start <= end, "span start \(start) after end \(end)")
        self.start = start
        self.end = end
    }

    // An empty span at one offset, for errors that point at a position rather than a range.
    public init(at offset: UInt32) {
        self.init(start: offset, end: offset)
    }

    public var count: UInt32 { end - start }
}

// The byte offset at which each line starts. Line 1 starts at offset 0; a line break ends a line, so the
// offset after each LF starts the next one. Built by the validation stage.
public struct LineIndex: Equatable {
    public let lineStarts: [UInt32]

    public init(lineStarts: [UInt32]) {
        precondition(lineStarts.first == 0, "the first line starts at offset 0")
        self.lineStarts = lineStarts
    }

    public var lineCount: Int { lineStarts.count }

    // 1-based (line, column) for a byte offset. Columns count bytes, matching the compiler's diagnostics.
    public func location(of offset: UInt32) -> (line: Int, column: Int) {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return (lo + 1, Int(offset - lineStarts[lo]) + 1)
    }
}
