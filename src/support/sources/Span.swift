// Source positions and spans.
//
// A `Span` is a half-open **byte** range [start, end) in one source file, plus a reference to that
// file's `SourceMap`. Line/column are resolved lazily from the map when a diagnostic or debug-info
// entry actually needs them — never computed eagerly per token. So a `Span` is small (two offsets +
// a shared reference) and cheap to construct, while `span.begin.line` / `span.file` still work for
// every consumer via the computed accessors below (design: `compiler.md` §1).

// Resolves byte offsets in one source file to 1-based line/column, and names the file. One per
// lexed source; a `Span` holds a reference so any consumer can resolve on demand.
public final class SourceMap {
    public let name: String
    private let lineStarts: [Int]   // byte offset of the start of each line

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        var starts = [0]
        for i in 0..<bytes.count where bytes[i] == 0x0A { starts.append(i + 1) }   // '\n'
        lineStarts = starts
    }

    // 1-based (line, column) for a byte offset; (0, 0) for a synthetic offset (< 0), which callers
    // use as a "no source location" sentinel (e.g. the debug-info guard `line > 0`).
    public func location(_ offset: Int) -> (line: Int, col: Int) {
        guard offset >= 0 else { return (0, 0) }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return (lo + 1, offset - lineStarts[lo] + 1)
    }
}

// A 1-based line/column, resolved on demand from a byte offset. Equality is by offset only (the map
// is identity-irrelevant), matching the old value-type behavior.
public struct Pos: Equatable {
    public let offset: Int
    public let map: SourceMap?

    public init(offset: Int, map: SourceMap?) {
        self.offset = offset
        self.map = map
    }

    public var line: Int { map?.location(offset).line ?? 0 }
    public var col: Int { map?.location(offset).col ?? 0 }

    public static func == (a: Pos, b: Pos) -> Bool { a.offset == b.offset }
}

public struct Span: Equatable {
    public let startOffset: Int
    public let endOffset: Int
    public let map: SourceMap?

    public init(startOffset: Int, endOffset: Int, map: SourceMap?) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.map = map
    }

    // Computed accessors so existing call sites (`span.begin.line`, `span.end.line`, `span.file`)
    // keep working — line/column resolve lazily through the map.
    public var begin: Pos { Pos(offset: startOffset, map: map) }
    public var end: Pos { Pos(offset: endOffset, map: map) }
    public var file: String { map?.name ?? "" }

    // A span reaching from the start of `a` to the end of `b` (same file). Used to give a parent
    // node the range of its first..last child.
    public static func merge(_ a: Span, _ b: Span) -> Span {
        Span(startOffset: a.startOffset, endOffset: b.endOffset, map: a.map)
    }

    public static func == (a: Span, b: Span) -> Bool {
        a.startOffset == b.startOffset && a.endOffset == b.endOffset
    }
}

extension Span: CustomStringConvertible {
    // `file:line:col` at the start — the usual diagnostic prefix.
    public var description: String { "\(file):\(begin.line):\(begin.col)" }
}
