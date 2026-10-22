// Stage 2: classify each line and record its tokens (spec §3–§10, §17–§21).
//
// The format is line-oriented: every scalar is one line except block scalars, indentation is two spaces per
// level, and separators are exact. So each line is lexed on its own; the only state carried from line to
// line is an open block scalar. A line records where its key, value and comment are; the spacing rules fix
// every other byte, so the records account for the whole line (see the rebuild test). Each line reports at
// most its first error and is then recorded as `.invalid`, so one mistake does not cascade. Scans within a
// line jump between bytes of interest through the block masks in `LexMasks.swift`.

public enum LineKind: UInt8 {
    case blank
    case comment
    case documentStart      // `---`
    case documentEnd        // `...`
    case node               // a dash, key, value and comment, any of which may be absent
    case blockContent       // a line inside a block scalar, kept verbatim
    case invalid            // a line that reported an error
}

public enum KeyKind: UInt8 {
    case none, plain, singleQuoted, doubleQuoted
}

public enum ValueKind: UInt8 {
    case none           // nothing on the line; a nested collection may follow
    case plain, singleQuoted, doubleQuoted
    case emptySequence  // `[]`
    case emptyMapping   // `{}`
    case literal        // `|` header
    case folded         // `>` header
}

public enum Chomping: UInt8 {
    case clip, strip, keep
}

// One record per line. Spans are byte offsets; a key or value span includes its quotes or indicators.
// `contentEnd` excludes the line break. A record is one 32-byte value written once per line: parallel arrays
// cost a uniqueness and bounds check per field written, and ran at an eighth of stage 1's speed.
public struct LineRecord: Equatable {
    public static let none = UInt32.max

    public internal(set) var kind = LineKind.blank
    public internal(set) var level: UInt8 = 0               // node lines: indentation / 2
    public internal(set) var shape: UInt8 = 0               // node lines: dash, key kind, value kind, chomping
    public internal(set) var keyStart: UInt32 = 0
    public internal(set) var keyEnd: UInt32 = 0
    public internal(set) var valueStart: UInt32 = 0
    public internal(set) var valueEnd: UInt32 = 0
    public internal(set) var commentStart = LineRecord.none // `none` when the line has no comment
    public internal(set) var contentStart: UInt32 = 0       // after the BOM, for the first line
    public internal(set) var contentEnd: UInt32 = 0

    public var hasDash: Bool { shape & Shape.dash != 0 }
    public var keyKind: KeyKind { KeyKind(rawValue: (shape >> Shape.keyShift) & 0b11)! }
    public var valueKind: ValueKind { ValueKind(rawValue: (shape >> Shape.valueShift) & 0b111)! }
    public var chomping: Chomping { Chomping(rawValue: (shape >> Shape.chompShift) & 0b11)! }
    public var hasComment: Bool { commentStart != LineRecord.none }
}

public struct LineRecords: Equatable {
    public let lines: [LineRecord]

    public var count: Int { lines.count }
    public subscript(line: Int) -> LineRecord { lines[line] }
    public var kinds: [LineKind] { lines.map(\.kind) }
}

// Bit layout of `LineRecord.shape`.
enum Shape {
    static let dash: UInt8 = 1
    static let keyShift: UInt8 = 1
    static let valueShift: UInt8 = 3
    static let chompShift: UInt8 = 6

    static func make(dash: Bool, key: KeyKind, value: ValueKind, chomping: Chomping) -> UInt8 {
        (dash ? Shape.dash : 0) | key.rawValue << keyShift | value.rawValue << valueShift
            | chomping.rawValue << chompShift
    }
}

public struct Lexing: Equatable {
    public let records: LineRecords
    public let errors: YAMLErrors
}

// Lexes the lines of a validated source. `errors` carries stage 1's errors forward.
public func lexLines(_ bytes: UnsafeBufferPointer<UInt8>, _ source: ValidatedSource, errors: YAMLErrors) -> Lexing {
    // One record per line, written in place: the line count is known, so the records need no copy.
    var errors = errors
    let lines = [LineRecord](unsafeUninitializedCapacity: source.lines.lineCount) { out, count in
        var lexer = Lexer(bytes, source, errors, out: out.baseAddress!)
        lexer.run()
        errors = lexer.errors
        count = source.lines.lineCount
    }
    return Lexing(records: LineRecords(lines: lines), errors: errors)
}

public func lexLines(_ bytes: [UInt8], _ source: ValidatedSource, errors: YAMLErrors) -> Lexing {
    bytes.withUnsafeBufferPointer { lexLines($0, source, errors: errors) }
}

private enum Char {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21       // !
    static let dquote: UInt8 = 0x22     // "
    static let hash: UInt8 = 0x23       // #
    static let percent: UInt8 = 0x25    // %
    static let amp: UInt8 = 0x26        // &
    static let squote: UInt8 = 0x27     // '
    static let star: UInt8 = 0x2A       // *
    static let plus: UInt8 = 0x2B       // +
    static let comma: UInt8 = 0x2C      // ,
    static let dash: UInt8 = 0x2D       // -
    static let dot: UInt8 = 0x2E        // .
    static let colon: UInt8 = 0x3A      // :
    static let gt: UInt8 = 0x3E         // >
    static let question: UInt8 = 0x3F   // ?
    static let at: UInt8 = 0x40         // @
    static let lbracket: UInt8 = 0x5B   // [
    static let backslash: UInt8 = 0x5C  // \
    static let rbracket: UInt8 = 0x5D   // ]
    static let backtick: UInt8 = 0x60   // `
    static let lbrace: UInt8 = 0x7B     // {
    static let pipe: UInt8 = 0x7C       // |
    static let rbrace: UInt8 = 0x7D     // }
}

struct Lexer {
    private static let maxKeyCharacters = 1024
    private static let maxLevel = 255

    private let b: UnsafeBufferPointer<UInt8>
    private let source: ValidatedSource
    private(set) var errors: YAMLErrors
    // Room for one record per line, and the record being built for the current line.
    private let out: UnsafeMutablePointer<LineRecord>
    private var r = LineRecord()
    private var masks: LexMasks

    // The content indentation of the open block scalar, if any, and whether a non-blank line has fixed it.
    private var blockIndent: Int?
    private var blockStarted = false
    // The open block scalar's header line and indicator span, for reporting a block with no content.
    private var blockHeaderLine = 0
    private var blockHeader = ByteSpan(at: 0)

    // The line being lexed and its bounds.
    private var line = 0
    private var lineStart = 0
    private var end = 0

    // The node line under construction.
    private var dash = false
    private var dashColumn = 0
    private var keyKind = KeyKind.none
    private var valueKind = ValueKind.none
    private var chomping = Chomping.clip

    init(_ bytes: UnsafeBufferPointer<UInt8>, _ source: ValidatedSource, _ errors: YAMLErrors,
         out: UnsafeMutablePointer<LineRecord>) {
        self.b = bytes
        self.source = source
        self.errors = errors
        masks = LexMasks(bytes)
        self.out = out
    }

    mutating func run() {
        source.lines.lineStarts.withUnsafeBufferPointer { run($0) }
    }

    private mutating func run(_ starts: UnsafeBufferPointer<UInt32>) {
        for l in 0..<starts.count {
            line = l
            lineStart = Int(starts[l]) + (l == 0 && source.hasByteOrderMark ? 3 : 0)
            var e = l + 1 < starts.count ? Int(starts[l + 1]) : b.count
            if e > lineStart && b[e - 1] == Char.lf {
                e -= 1
                if e > lineStart && b[e - 1] == Char.cr { e -= 1 }
            }
            end = e
            r = LineRecord()
            r.contentStart = UInt32(lineStart)
            r.contentEnd = UInt32(e)
            lexLine()
            (out + l).initialize(to: r)
        }
        if blockIndent != nil && !blockStarted { emptyBlockScalar() }
    }

    // MARK: Lines

    private mutating func lexLine() {
        let p = masks.next(.nonSpace, from: lineStart, end: end)
        let indent = p - lineStart

        if let content = blockIndent {
            if continuesBlock(at: p, indent: indent, content: content) { return }
            blockIndent = nil
            if !blockStarted { emptyBlockScalar() }
        }

        if p == end {
            if indent > 0 {
                fail(.whitespaceOnlyLine, lineStart, end, "a line holding only spaces is not allowed")
            }
            return  // `.blank` is the default
        }
        let last = b[end - 1]
        if last == Char.space || last == Char.tab {
            var t = end
            while t > p && (b[t - 1] == Char.space || b[t - 1] == Char.tab) { t -= 1 }
            fail(.trailingWhitespace, t, end, "trailing whitespace")
            return
        }
        if b[p] == Char.tab {
            fail(.tabOutsideScalar, p, p + 1, "a tab cannot indent a line", fix: "indent with spaces")
            return
        }
        if b[p] == Char.hash {
            r.kind = .comment
            r.commentStart = UInt32(p)
            return
        }
        if indent == 0 && b[p] <= Char.dot {  // `-`, `.` and `%` sort below every letter and digit
            if marker(Char.dash, at: p) { lexMarker(.documentStart, at: p); return }
            if marker(Char.dot, at: p) { lexMarker(.documentEnd, at: p); return }
            if b[p] == Char.percent {
                fail(.directive, p, end, "YAML directives are not supported")
                return
            }
        }
        lexNode(at: p, indent: indent)
    }

    // Handles a line while a block scalar is open; returns false when the line ends the block.
    private mutating func continuesBlock(at p: Int, indent: Int, content: Int) -> Bool {
        var q = p
        while q < end && (b[q] == Char.space || b[q] == Char.tab) { q += 1 }
        if q == end {
            // Blank lines belong to the block. Before its first content line, none may be deeper than it.
            r.kind = .blockContent
            if !blockStarted && indent > content {
                fail(.blockScalarIndentation, lineStart, end,
                     "a leading blank line of a block scalar is indented past its content")
            }
            return true
        }
        guard indent >= content else { return false }
        r.kind = .blockContent
        if !blockStarted {
            blockStarted = true
            if indent != content {
                fail(.blockScalarIndentation, lineStart, p,
                     "block scalar content is indented \(indent) spaces; it starts at \(content)",
                     fix: "indent the first line two spaces deeper than its key or dash")
            }
        }
        return true
    }

    // `---` or `...` at `p`, followed by the end of the line or a space.
    private func marker(_ c: UInt8, at p: Int) -> Bool {
        p + 3 <= end && b[p] == c && b[p + 1] == c && b[p + 2] == c && (p + 3 == end || b[p + 3] == Char.space)
    }

    private mutating func lexMarker(_ kind: LineKind, at p: Int) {
        var q = p + 3
        while q < end && b[q] == Char.space { q += 1 }
        if q < end && b[q] != Char.hash {
            fail(.contentOnMarkerLine, q, end, "a document marker stands alone on its line")
            return
        }
        r.kind = kind
        if q < end { r.commentStart = UInt32(q) }
    }

    // MARK: Nodes

    private mutating func lexNode(at p0: Int, indent: Int) {
        if indent & 1 != 0 {
            fail(.oddIndentation, lineStart, p0, "indentation is \(indent) spaces; it is two spaces per level")
            return
        }
        if indent / 2 > Lexer.maxLevel {
            fail(.nestingTooDeep, lineStart, p0, "nesting is deeper than \(Lexer.maxLevel) levels")
            return
        }
        r.level = UInt8(indent / 2)
        dash = false
        keyKind = .none
        valueKind = .none
        chomping = .clip

        var p = p0
        if b[p] == Char.dash && (p + 1 == end || b[p + 1] == Char.space || b[p + 1] == Char.tab) {
            dash = true
            dashColumn = p - lineStart
            p += 1
            if p == end { finishNode(); return }
            if b[p] == Char.tab {
                fail(.tabOutsideScalar, p, p + 1, "a tab cannot follow a sequence dash", fix: "use one space")
                return
            }
            p += 1
            if b[p] == Char.space {
                var q = p
                while b[q] == Char.space { q += 1 }   // the line has no trailing spaces, so q < end
                if b[q] == Char.hash { comment(at: q); return }
                fail(.dashSpacing, p0 + 1, q, "a sequence dash is followed by exactly one space")
                return
            }
            if b[p] == Char.hash { comment(at: p); return }
            if b[p] == Char.dash && (p + 1 == end || b[p + 1] == Char.space) {
                fail(.sequenceOnItemLine, p, p + 1, "a nested sequence cannot start on its parent item's line",
                     fix: "put the nested sequence on the next line, indented")
                return
            }
        }
        lexEntry(at: p, keyAllowed: true)
    }

    // Lexes a key and its value, or a lone value, starting at `p`.
    private mutating func lexEntry(at p: Int, keyAllowed: Bool) {
        let c = b[p]
        if c == Char.dquote || c == Char.squote {
            guard let close = scanQuoted(at: p) else {
                fail(.unterminatedQuote, p, end, "unterminated quoted scalar",
                     fix: "close it on the same line; quoted scalars are one line")
                return
            }
            if keyAllowed && isMappingColon(at: close) {
                setKey(c == Char.dquote ? .doubleQuoted : .singleQuoted, p, close)
                afterKey(colon: close)
                return
            }
            if keyAllowed && close < end && b[close] == Char.space {
                var q = close
                while q < end && b[q] == Char.space { q += 1 }
                if isMappingColon(at: q) {
                    fail(.spaceBeforeColon, close, q, "no space is allowed before a mapping colon")
                    return
                }
            }
            setValue(c == Char.dquote ? .doubleQuoted : .singleQuoted, p, close)
            trailer(at: close, code: .contentAfterQuote, "only a comment may follow a quoted scalar")
            return
        }
        guard !Lexer.isIndicator(c) || checkPlainStart(at: p, keyAllowed: keyAllowed) else { return }

        // A plain scalar: it ends at a mapping colon, at ` #`, or at the end of the line. The plain-stop mask
        // holds exactly those bytes, plus tabs, which are reported.
        let j = masks.next(.plainStop, from: p, end: end)
        if j == end {
            setValue(.plain, p, end)
            finishNode()
            return
        }
        switch b[j] {
        case Char.tab:
            fail(.tabOutsideScalar, j, j + 1, "a tab is allowed only in quoted and block scalars",
                 fix: "quote the scalar")
        case Char.colon:
            guard keyAllowed else {
                fail(.mappingOnValueLine, j, j + 1, "a mapping cannot start on its key's value line",
                     fix: "quote the value if the colon is part of it")
                return
            }
            if b[j - 1] == Char.space {
                var k = j
                while b[k - 1] == Char.space { k -= 1 }
                fail(.spaceBeforeColon, k, j, "no space is allowed before a mapping colon")
                return
            }
            setKey(.plain, p, j)
            afterKey(colon: j)
        default:  // `#` after a space
            var k = j
            while b[k - 1] == Char.space { k -= 1 }
            setValue(.plain, p, k)
            comment(at: j)
        }
    }

    // After `key:` at `colon`: nothing, a comment, or one space and a value.
    private mutating func afterKey(colon: Int) {
        var q = colon + 1
        if q == end { finishNode(); return }
        if b[q] == Char.tab {
            fail(.tabOutsideScalar, q, q + 1, "a tab cannot follow a mapping colon", fix: "use one space")
            return
        }
        q += 1  // the space
        if b[q] == Char.space {
            var r = q
            while b[r] == Char.space { r += 1 }   // no trailing spaces, so r < end
            if b[r] == Char.hash { comment(at: r); return }
            fail(.colonSpacing, colon + 1, r, "a mapping colon is followed by exactly one space")
            return
        }
        if b[q] == Char.hash { comment(at: q); return }
        lexEntry(at: q, keyAllowed: false)
    }

    // Checks a scalar at `p` that starts with an indicator character (`isIndicator`). Indicators cannot start
    // a plain scalar, except a few followed by a non-space; the ones that form values here (`[]`, `{}`, block
    // headers) are lexed, the rest reported. Returns false after lexing or reporting.
    @inline(never)
    private mutating func checkPlainStart(at p: Int, keyAllowed: Bool) -> Bool {
        let c = b[p]
        let next: UInt8? = p + 1 < end ? b[p + 1] : nil
        let spaceOrEnd = next == nil || next == Char.space || next == Char.tab
        switch c {
        case Char.dash where spaceOrEnd:
            fail(.sequenceOnKeyLine, p, p + 1, "a sequence cannot start on its key's line",
                 fix: "put the sequence on the next line, indented")
            return false
        case Char.question where spaceOrEnd:
            fail(.complexKey, p, p + 1, "complex keys (`? key`) are not supported")
            return false
        case Char.colon where spaceOrEnd:
            fail(.emptyKey, p, p + 1, "a mapping entry needs a key", fix: "write an empty key as \"\"")
            return false
        case Char.lbracket, Char.lbrace:
            let close = c == Char.lbracket ? Char.rbracket : Char.rbrace
            guard next == close else {
                fail(.flowCollection, p, end, "flow collections are not supported; only [] and {} are allowed",
                     fix: "write the collection in block style")
                return false
            }
            setValue(c == Char.lbracket ? .emptySequence : .emptyMapping, p, p + 2)
            trailer(at: p + 2, code: .flowCollection, "only a comment may follow [] or {}")
            return false
        case Char.rbracket, Char.rbrace, Char.comma:
            fail(.flowCollection, p, p + 1, "a scalar cannot start with `\(Character(Unicode.Scalar(c)))`",
                 fix: "quote it")
            return false
        case Char.amp:
            fail(.anchor, p, p + 1, "anchors are not supported")
            return false
        case Char.star:
            fail(.alias, p, p + 1, "aliases are not supported")
            return false
        case Char.bang:
            fail(.tag, p, p + 1, "tags are not supported")
            return false
        case Char.pipe, Char.gt:
            lexBlockHeader(at: p)
            return false
        case Char.percent, Char.at, Char.backtick:
            fail(.reservedIndicator, p, p + 1, "a scalar cannot start with `\(Character(Unicode.Scalar(c)))`",
                 fix: "quote it")
            return false
        default:
            return true
        }
    }

    // Whether `c` is one of the indicators `checkPlainStart` handles, ``-?:[]{},&*!|>%@` ``, as a bitmap over
    // ASCII: most scalars start with a letter or digit, which one bit test passes without the switch.
    @inline(__always)
    private static func isIndicator(_ c: UInt8) -> Bool {
        let low: UInt64 = 0xC400_3462_0000_0000    // bytes 0x00–0x3F
        let high: UInt64 = 0x3800_0001_2800_0001   // bytes 0x40–0x7F
        return c < 64 ? low >> UInt64(c) & 1 != 0 : c < 128 && high >> UInt64(c & 63) & 1 != 0
    }

    // `|` or `>`, an optional chomping indicator, then a comment or the end of the line.
    private mutating func lexBlockHeader(at p: Int) {
        var q = p + 1
        if q < end && (b[q] == Char.dash || b[q] == Char.plus) {
            chomping = b[q] == Char.dash ? .strip : .keep
            q += 1
        }
        if q < end && b[q] >= 0x30 && b[q] <= 0x39 {
            fail(.blockIndentationIndicator, q, q + 1, "block scalar indentation indicators are not supported",
                 fix: "indent the content two spaces deeper than its key or dash")
            return
        }
        setValue(b[p] == Char.pipe ? .literal : .folded, p, q)
        guard trailer(at: q, code: .contentOnBlockHeader, "block scalar content starts on the next line") else {
            return
        }
        blockHeaderLine = line
        blockHeader = ByteSpan(start: UInt32(p), end: UInt32(q))
        if keyKind == .none && !dash && r.level > 0 {
            // A header alone on an indented line is a value on the line after its key, which stage 3 rejects.
            // Every following line indented at least as far is taken as its content, so that one error covers
            // the whole scalar.
            blockIndent = Int(r.level) * 2
            blockStarted = true
            return
        }
        // Content sits two spaces deeper than the node that owns the scalar: its key, its dash, or the line.
        let owner = keyKind != .none ? Int(r.keyStart) - lineStart
            : dash ? dashColumn : Int(r.level) * 2
        blockIndent = owner + 2
        blockStarted = false
    }

    // Reports a block scalar that ended before any non-blank content line, on its header line (spec §20).
    @inline(never)
    private mutating func emptyBlockScalar() {
        errors.report(YAMLError(.emptyBlockScalar, blockHeader, "a block scalar needs at least one content line",
                                fix: "write an empty string as \"\""))
        out[blockHeaderLine].kind = .invalid
    }

    // After a complete value ending at `q`: the end of the line, or spaces and a comment. Returns false after
    // reporting.
    @discardableResult
    private mutating func trailer(at q: Int, code: YAMLError.Code, _ message: String) -> Bool {
        if q == end { finishNode(); return true }
        if b[q] == Char.space {
            var r = q
            while b[r] == Char.space { r += 1 }   // no trailing spaces, so r < end
            if b[r] == Char.hash { comment(at: r); return true }
            fail(code, r, end, message)
            return false
        }
        if b[q] == Char.tab {
            fail(.tabOutsideScalar, q, q + 1, "a tab cannot separate a value from a comment", fix: "use spaces")
            return false
        }
        fail(code, q, end, message)
        return false
    }

    // MARK: Scanning helpers

    // The offset just past the closing quote of the quoted scalar at `p`, or nil when the line ends first.
    // In single quotes `''` is an escaped quote; in double quotes a backslash escapes the next byte (escapes
    // are checked when the scalar is decoded).
    private mutating func scanQuoted(at p: Int) -> Int? {
        let quote = b[p]
        var j = p + 1
        while true {
            j = masks.next(.quote, from: j, end: end)
            if j >= end { return nil }
            let d = b[j]
            if quote == Char.squote && d == Char.squote {
                if j + 1 < end && b[j + 1] == Char.squote { j += 2; continue }
                return j + 1
            }
            if quote == Char.dquote {
                if d == Char.backslash { j += 2; continue }
                if d == Char.dquote { return j + 1 }
            }
            j += 1
        }
    }

    // A colon at `j` followed by the end of the line, a space, or a tab (which is then reported).
    private func isMappingColon(at j: Int) -> Bool {
        j < end && b[j] == Char.colon && (j + 1 == end || b[j + 1] == Char.space || b[j + 1] == Char.tab)
    }

    // MARK: Recording

    private mutating func setKey(_ kind: KeyKind, _ start: Int, _ stop: Int) {
        // A character is at least one byte, so only a key longer in bytes than the limit needs counting.
        if stop - start > Lexer.maxKeyCharacters { checkKeyLength(start, stop) }
        keyKind = kind
        r.keyStart = UInt32(start)
        r.keyEnd = UInt32(stop)
    }

    @inline(never)
    private mutating func checkKeyLength(_ start: Int, _ stop: Int) {
        var characters = 0
        for k in start..<stop where b[k] & 0xC0 != 0x80 { characters += 1 }
        if characters > Lexer.maxKeyCharacters {
            fail(.keyTooLong, start, stop, "a key is at most \(Lexer.maxKeyCharacters) characters")
        }
    }

    private mutating func setValue(_ kind: ValueKind, _ start: Int, _ stop: Int) {
        valueKind = kind
        r.valueStart = UInt32(start)
        r.valueEnd = UInt32(stop)
    }

    private mutating func comment(at p: Int) {
        r.commentStart = UInt32(p)
        finishNode()
    }

    private mutating func finishNode() {
        guard r.kind != .invalid else { return }
        r.kind = .node
        r.shape = Shape.make(dash: dash, key: keyKind, value: valueKind, chomping: chomping)
    }

    // Reports the line's first error; later ones on the same line are follow-ons and dropped. Kept out of line
    // so the hot paths that call it stay small.
    @inline(never)
    private mutating func fail(_ code: YAMLError.Code, _ start: Int, _ stop: Int, _ message: String,
                               fix: String? = nil) {
        guard r.kind != .invalid else { return }
        errors.report(YAMLError(code, ByteSpan(start: UInt32(start), end: UInt32(stop)), message, fix: fix))
        r.kind = .invalid
    }
}
