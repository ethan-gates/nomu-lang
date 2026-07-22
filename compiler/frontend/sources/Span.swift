// Source positions and spans.
//
// A `Span` covers a half-open character range [begin, end) in a single source
// file, with 1-based line and column. Threaded from the lexer through tokens
// and the AST into the typed IR, so diagnostics and (later) debug info can point
// at precise ranges (design: `m4.9-spec.md` §6).

public struct Pos: Equatable {
    public let line: Int
    public let col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
}

public struct Span: Equatable {
    public let file: String
    public let begin: Pos
    public let end: Pos

    public init(file: String, begin: Pos, end: Pos) {
        self.file = file
        self.begin = begin
        self.end = end
    }

    // A span reaching from the start of `a` to the end of `b` (same file).
    // Used to give a parent node the range of its first..last child.
    public static func merge(_ a: Span, _ b: Span) -> Span {
        Span(file: a.file, begin: a.begin, end: b.end)
    }
}

extension Span: CustomStringConvertible {
    // `file:line:col` at the start — the usual diagnostic prefix.
    public var description: String { "\(file):\(begin.line):\(begin.col)" }
}
