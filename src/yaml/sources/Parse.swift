// The parser: stages 2–4 fused into one loop over the lines of a document that stage 1 accepted (task 200,
// "the shared core at ≥1 GB/s").
//
// Each line is lexed with stage 1's plain-stop masks, joined to the structure and its scalars typed while its
// bytes are in cache, and its record and nodes are written once. The loop accepts exactly the documents the
// diagnostic path accepts, with identical records, nodes, types and key tables. At the first error it stops,
// and the diagnostic path (`Lex.swift`, `Structure.swift`, `Resolve.swift`, run as separate stages) parses the
// document again and reports every error with recovery. This is simdjson's shape: a parser that stops at the
// first error, with the diagnostic path adding the full report.
//
// The two implement the same rules; a rule changed in one is changed in the other, and `ParseTests.swift`
// checks that they agree on every test document and on generated ones.

// The output of the parser, as the diagnostic path gives it for a valid document.
struct Parsed {
    let records: [LineRecord]
    let arena: NodeArena
    let types: [ScalarType]
    let keyTables: [UInt32: KeyTable]
}

// Parses a source stage 1 validated without errors; nil at the first error.
func parse(_ bytes: UnsafeBufferPointer<UInt8>, _ source: ValidatedSource) -> Parsed? {
    guard !source.plainStops.isEmpty, bytes.count > 0 else { return nil }
    let lines = source.lines.lineCount
    // A line adds at most four nodes: `- key: value` under a key owing a value opens a sequence, a mapping,
    // an entry and a scalar.
    let capacity = lines * 4 + 1
    var accepted = false
    var nodes: [Node] = []
    var types: [ScalarType] = []
    var root = Node.none
    var tables: [UInt32: KeyTable] = [:]
    let records = source.plainStops.withUnsafeBufferPointer { stops in
        source.lines.lineStarts.withUnsafeBufferPointer { starts in
            [LineRecord](unsafeUninitializedCapacity: lines) { recordOut, recordCount in
                nodes = [Node](unsafeUninitializedCapacity: capacity) { nodeOut, nodeCount in
                    types = [ScalarType](unsafeUninitializedCapacity: capacity) { typeOut, typeCount in
                        var parser = Parser(bytes, stops.baseAddress!, starts, source,
                                                records: recordOut.baseAddress!, nodes: nodeOut.baseAddress!,
                                                types: typeOut.baseAddress!)
                        accepted = parser.run()
                        typeCount = accepted ? parser.nodeCount : 0
                        nodeCount = typeCount
                        root = parser.root
                        tables = parser.finishedTables
                        parser.release()
                    }
                }
                recordCount = accepted ? lines : 0
            }
        }
    }
    guard accepted else { return nil }
    return Parsed(records: records, arena: NodeArena(nodes: nodes, root: root), types: types, keyTables: tables)
}

// The mask of bytes where a plain scalar may end, per 64-byte block: a tab, a colon before a separator, or `#`
// after a space. Stage 1 computes it while validating each block. A separator is any byte up to a space: the
// parser runs only on documents stage 1 accepted, which hold no control bytes but tabs and line breaks.
enum PlainStops {
    @inline(__always)
    static func mask(_ before: Block, _ v: Block, _ after: Block) -> UInt64 {
        Block.mask(before, v, after) { p, c, n in
            equal01(c, 0x09) | equal01(c, 0x3A) & below01(n, 0x21) | equal01(c, 0x23) & equal01(p, 0x20)
        }
    }

    // The mask of the block at `base`, from a copy padded with line feeds: the first and last blocks.
    @inline(never)
    static func mask(_ b: UnsafeBufferPointer<UInt8>, at base: Int) -> UInt64 {
        var m: UInt64 = 0
        LexMasks.withPadded(b, base) { p in m = mask(Block(p - 1), Block(p), Block(p + 1)) }
        return m
    }
}

private enum Char {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let space: UInt8 = 0x20
    static let dquote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let percent: UInt8 = 0x25
    static let squote: UInt8 = 0x27
    static let plus: UInt8 = 0x2B
    static let dash: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let colon: UInt8 = 0x3A
    static let gt: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let lbracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let lbrace: UInt8 = 0x7B
    static let pipe: UInt8 = 0x7C
}

private struct Parser {
    private static let maxKeyCharacters = 1024
    private static let maxIndent = 255 * 2

    // An open collection. A mapping past `StructureBuilder.linearKeys` keys indexes them in `table`, held
    // unmanaged so reading a frame costs no reference counting; the table is retained while the frame is open.
    private struct Frame {
        var level: Int
        var node: UInt32
        var last: UInt32
        var keysStart: Int
        var table: Unmanaged<KeyTable>?
    }

    // A key of an open mapping: the hash of its decoded, case-folded text, and its entry.
    private struct Key {
        let hash: UInt64
        let entry: UInt32
    }

    private let b: UnsafePointer<UInt8>
    private let buffer: UnsafeBufferPointer<UInt8>
    private let count: Int
    private let stops: UnsafePointer<UInt64>
    private let starts: UnsafeBufferPointer<UInt32>
    private let crlf: Int
    private let bom: Bool

    private let records: UnsafeMutablePointer<LineRecord>
    private let nodes: UnsafeMutablePointer<Node>
    private let types: UnsafeMutablePointer<ScalarType>
    private(set) var nodeCount = 0
    private(set) var root = Node.none
    private(set) var finishedTables: [UInt32: KeyTable] = [:]

    private let frames: UnsafeMutablePointer<Frame>
    private var frameCount = 0
    // A 256-bit filter per open mapping, four words per frame, with one bit set from each key's hash. A new
    // key whose bit is clear cannot equal an earlier key, so the scan for duplicates is skipped.
    private let filters: UnsafeMutablePointer<UInt64>
    private let keys: UnsafeMutablePointer<Key>
    private var keyCount = 0

    // A key or dash owing a value: the level its collection must start at, and the entry or sequence that
    // owns it; `slotLevel` is -1 when nothing is owed.
    private var slotLevel = -1
    private var slotOwner = Node.none
    // The open block scalar's content indentation (-1 when none), and whether a content line has fixed it.
    private var blockIndent = -1
    private var blockStarted = false

    // Document state (spec §3).
    private var sawStart = false
    private var sawContent = false
    private var ended = false
    private var rootScalar = false

    // The line being parsed.
    private var line = 0
    private var r = LineRecord()
    private var lineStart = 0
    private var end = 0
    private var dash = false
    private var keyKind = KeyKind.none
    private var valueKind = ValueKind.none
    private var chomping = Chomping.clip

    init(_ bytes: UnsafeBufferPointer<UInt8>, _ stops: UnsafePointer<UInt64>,
         _ starts: UnsafeBufferPointer<UInt32>, _ source: ValidatedSource, records: UnsafeMutablePointer<LineRecord>,
         nodes: UnsafeMutablePointer<Node>, types: UnsafeMutablePointer<ScalarType>) {
        b = bytes.baseAddress!
        buffer = bytes
        count = bytes.count
        self.stops = stops
        self.starts = starts
        crlf = source.lineEnding == .crlf ? 1 : 0
        bom = source.hasByteOrderMark
        self.records = records
        self.nodes = nodes
        self.types = types
        frames = .allocate(capacity: 260)
        filters = .allocate(capacity: 260 * 4)
        keys = .allocate(capacity: starts.count + 1)
    }

    // Frees the working storage; tables of frames still open are released.
    mutating func release() {
        for f in 0..<frameCount { frames[f].table?.release() }
        frames.deallocate()
        filters.deallocate()
        keys.deallocate()
    }

    // MARK: Masks

    // The first non-space byte at or after `from`, or `end`; read a word at a time, since indentation is short.
    @inline(__always)
    private func nextNonSpace(_ from: Int) -> Int {
        var i = from
        while i + 8 <= count {
            let x = UnsafeRawPointer(b + i).loadUnaligned(as: UInt64.self) ^ 0x2020_2020_2020_2020
            if x != 0 { return min(i + x.trailingZeroBitCount >> 3, end) }
            i += 8
            if i >= end { return end }
        }
        while i < end && b[i] == Char.space { i += 1 }
        return i
    }

    @inline(__always)
    private func nextPlainStop(_ from: Int) -> Int {
        var i = from
        while i < end {
            let rest = stops[i >> 6] >> UInt64(i & 63)
            if rest != 0 { return min(i + rest.trailingZeroBitCount, end) }
            i = (i | 63) + 1
        }
        return end
    }

    // Quote masks are built when a quoted scalar is scanned, for the 64 bytes from `from`.
    @inline(__always)
    private func nextQuote(_ from: Int) -> Int {
        var i = from
        while i < end {
            let m: UInt64
            if i + Block.size <= count {
                m = Block(UnsafeRawPointer(b + i)).mask(LexMasks.quote01)
            } else {
                m = LexMasks.quotes(buffer, from: i)
            }
            if m != 0 { return min(i + m.trailingZeroBitCount, end) }
            i += Block.size
        }
        return end
    }

    // MARK: Lines

    mutating func run() -> Bool {
        let n = starts.count
        for l in 0..<n {
            line = l
            let start = Int(starts[l]) + (l == 0 && bom ? 3 : 0)
            var e: Int
            if l + 1 < n {
                e = Int(starts[l + 1]) - 1 - crlf
            } else {
                e = count
                if e > start && b[e - 1] == Char.lf { e -= 1 + crlf }
            }
            lineStart = start
            end = e
            r = LineRecord()
            r.contentStart = UInt32(start)
            r.contentEnd = UInt32(e)
            guard lexLine() else { return false }
            (records + l).initialize(to: r)
        }
        if blockIndent >= 0 && !blockStarted { return false }    // emptyBlockScalar
        if slotLevel >= 0 || !sawContent { return false }         // missingValue, emptyDocument
        while frameCount > 0 { popFrame() }
        return true
    }

    // Lexes the current line into `r` and joins it to the structure; false at an error.
    @inline(__always)
    private mutating func lexLine() -> Bool {
        let p = nextNonSpace(lineStart)
        let indent = p - lineStart
        if blockIndent >= 0 {
            if let continues = continuesBlock(at: p, indent: indent) { return continues }
        }
        if p == end { return indent == 0 }                        // whitespaceOnlyLine
        let last = b[end - 1]
        if last == Char.space || last == Char.tab { return false }  // trailingWhitespace
        let c = b[p]
        if c == Char.hash {
            r.kind = .comment
            r.commentStart = UInt32(p)
            return true
        }
        if c == Char.tab { return false }
        if indent == 0 && c <= Char.dot {
            if isMarker(Char.dash, at: p) { return marker(.documentStart, at: p) }
            if isMarker(Char.dot, at: p) { return marker(.documentEnd, at: p) }
            if c == Char.percent { return false }                 // directive
        }
        guard indent & 1 == 0 && indent <= Parser.maxIndent else { return false }
        guard !ended else { return false }                        // contentAfterDocumentEnd
        sawContent = true
        r.level = UInt8(indent / 2)
        dash = false
        keyKind = .none
        valueKind = .none
        chomping = .clip

        var q = p
        if c == Char.dash && (p + 1 == end || b[p + 1] == Char.space || b[p + 1] == Char.tab) {
            dash = true
            if p + 1 == end {
                finishNode()
                return structure(indent / 2)
            }
            if b[p + 1] == Char.tab { return false }
            q = p + 2
            let d = b[q]
            if d == Char.space || d == Char.hash {
                var k = q
                while b[k] == Char.space { k += 1 }
                guard b[k] == Char.hash else { return false }     // dashSpacing
                r.commentStart = UInt32(k)
                finishNode()
                return structure(indent / 2)
            }
            if d == Char.dash && (q + 1 == end || b[q + 1] == Char.space) { return false }  // sequenceOnItemLine
        }
        guard entry(at: q) else { return false }
        return structure(indent / 2)
    }

    // A line while a block scalar is open: true when it is content, false at an error, nil when it ends the
    // block and is lexed as an ordinary line.
    @inline(__always)
    private mutating func continuesBlock(at p: Int, indent: Int) -> Bool? {
        var q = p
        while q < end && (b[q] == Char.space || b[q] == Char.tab) { q += 1 }
        if q == end {
            r.kind = .blockContent
            return blockStarted || indent <= blockIndent
        }
        if indent >= blockIndent {
            r.kind = .blockContent
            if !blockStarted {
                guard indent == blockIndent else { return false }  // blockScalarIndentation
                blockStarted = true
            }
            return true
        }
        guard blockStarted else { return false }                  // emptyBlockScalar
        blockIndent = -1
        return nil
    }

    // `---` or `...` at `p`, followed by the end of the line or a space.
    @inline(__always)
    private func isMarker(_ c: UInt8, at p: Int) -> Bool {
        p + 3 <= end && b[p] == c && b[p + 1] == c && b[p + 2] == c && (p + 3 == end || b[p + 3] == Char.space)
    }

    private mutating func marker(_ kind: LineKind, at p: Int) -> Bool {
        var q = p + 3
        while q < end && b[q] == Char.space { q += 1 }
        if q < end && b[q] != Char.hash { return false }          // contentOnMarkerLine
        r.kind = kind
        if q < end { r.commentStart = UInt32(q) }
        if kind == .documentStart {
            if sawContent || sawStart || ended { return false }   // multipleDocuments
            sawStart = true
        } else {
            if ended || slotLevel >= 0 { return false }           // contentAfterDocumentEnd, missingValue
            ended = true
        }
        return true
    }

    // Lexes a key and its value, or a lone value, at `p`.
    @inline(__always)
    private mutating func entry(at p: Int) -> Bool {
        let c = b[p]
        if c == Char.dquote || c == Char.squote {
            guard let close = quoted(at: p) else { return false }
            if close < end && b[close] == Char.colon
                && (close + 1 == end || b[close + 1] == Char.space || b[close + 1] == Char.tab) {
                guard setKey(c == Char.dquote ? .doubleQuoted : .singleQuoted, p, close) else { return false }
                return afterKey(colon: close)
            }
            setValue(c == Char.dquote ? .doubleQuoted : .singleQuoted, p, close)
            return trailer(close)
        }
        if Parser.isIndicator(c) {
            // `-`, `?` and `:` followed by a non-space start a plain scalar.
            let plain = (c == Char.dash || c == Char.question || c == Char.colon)
                && p + 1 < end && b[p + 1] != Char.space && b[p + 1] != Char.tab
            if !plain { return indicator(at: p) }
        }
        let j = nextPlainStop(p)
        if j == end {
            setValue(.plain, p, end)
            finishNode()
            return true
        }
        switch b[j] {
        case Char.colon:
            guard b[j - 1] != Char.space else { return false }   // spaceBeforeColon
            guard setKey(.plain, p, j) else { return false }
            return afterKey(colon: j)
        case Char.hash:
            var k = j
            while b[k - 1] == Char.space { k -= 1 }
            setValue(.plain, p, k)
            r.commentStart = UInt32(j)
            finishNode()
            return true
        default:
            return false                                          // a tab
        }
    }

    // After `key:` at `colon`: nothing, a comment, or one space and a value.
    @inline(__always)
    private mutating func afterKey(colon: Int) -> Bool {
        let q = colon + 1
        if q == end {
            finishNode()
            return true
        }
        guard b[q] == Char.space else { return false }            // a tab
        let v = q + 1
        let d = b[v]
        if d == Char.space || d == Char.hash {
            var k = v
            while b[k] == Char.space { k += 1 }
            guard b[k] == Char.hash else { return false }         // colonSpacing
            r.commentStart = UInt32(k)
            finishNode()
            return true
        }
        return value(at: v)
    }

    // Lexes a value at `p`, after its key: as `entry`, but a mapping colon is an error.
    @inline(__always)
    private mutating func value(at p: Int) -> Bool {
        let c = b[p]
        if c == Char.dquote || c == Char.squote {
            guard let close = quoted(at: p) else { return false }
            setValue(c == Char.dquote ? .doubleQuoted : .singleQuoted, p, close)
            return trailer(close)
        }
        if Parser.isIndicator(c) {
            let plain = (c == Char.dash || c == Char.question || c == Char.colon)
                && p + 1 < end && b[p + 1] != Char.space && b[p + 1] != Char.tab
            if !plain { return indicator(at: p) }
        }
        let j = nextPlainStop(p)
        if j == end {
            setValue(.plain, p, end)
            finishNode()
            return true
        }
        guard b[j] == Char.hash else { return false }             // mappingOnValueLine, a tab
        var k = j
        while b[k - 1] == Char.space { k -= 1 }
        setValue(.plain, p, k)
        r.commentStart = UInt32(j)
        finishNode()
        return true
    }

    // The offset after the closing quote of the quoted scalar at `p`, or nil when the line ends first. In single
    // quotes `''` is an escaped quote; in double quotes a backslash escapes the next byte.
    @inline(__always)
    private func quoted(at p: Int) -> Int? {
        let quote = b[p]
        var j = p + 1
        while true {
            j = nextQuote(j)
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

    // `[]`, `{}` and block headers; every other indicator is an error.
    private mutating func indicator(at p: Int) -> Bool {
        let c = b[p]
        if c == Char.lbracket || c == Char.lbrace {
            guard p + 1 < end && b[p + 1] == c + 2 else { return false }
            setValue(c == Char.lbracket ? .emptySequence : .emptyMapping, p, p + 2)
            return trailer(p + 2)
        }
        guard c == Char.pipe || c == Char.gt else { return false }
        var q = p + 1
        if q < end && (b[q] == Char.dash || b[q] == Char.plus) {
            chomping = b[q] == Char.dash ? .strip : .keep
            q += 1
        }
        if q < end && b[q] &- 0x30 < 10 { return false }          // blockIndentationIndicator
        setValue(c == Char.pipe ? .literal : .folded, p, q)
        guard trailer(q) else { return false }
        if keyKind == .none && !dash && r.level > 0 { return false }  // valueOnNextLine
        // Content sits two spaces deeper than the node owning the scalar: its key, its dash, or the line.
        let owner = keyKind != .none ? Int(r.keyStart) - lineStart : Int(r.level) * 2
        blockIndent = owner + 2
        blockStarted = false
        return true
    }

    // After a value ending at `q`: the end of the line, or spaces and a comment.
    @inline(__always)
    private mutating func trailer(_ q: Int) -> Bool {
        if q == end {
            finishNode()
            return true
        }
        guard b[q] == Char.space else { return false }
        var k = q
        while b[k] == Char.space { k += 1 }
        guard b[k] == Char.hash else { return false }
        r.commentStart = UInt32(k)
        finishNode()
        return true
    }

    @inline(__always)
    private mutating func setKey(_ kind: KeyKind, _ start: Int, _ stop: Int) -> Bool {
        if stop - start > Parser.maxKeyCharacters {
            var characters = 0
            for k in start..<stop where b[k] & 0xC0 != 0x80 { characters += 1 }
            if characters > Parser.maxKeyCharacters { return false }  // keyTooLong
        }
        keyKind = kind
        r.keyStart = UInt32(start)
        r.keyEnd = UInt32(stop)
        return true
    }

    @inline(__always)
    private mutating func setValue(_ kind: ValueKind, _ start: Int, _ stop: Int) {
        valueKind = kind
        r.valueStart = UInt32(start)
        r.valueEnd = UInt32(stop)
    }

    @inline(__always)
    private mutating func finishNode() {
        r.kind = .node
        r.shape = Shape.make(dash: dash, key: keyKind, value: valueKind, chomping: chomping)
    }

    // The indicators of `Lexer.isIndicator`, as a bitmap over ASCII.
    @inline(__always)
    private static func isIndicator(_ c: UInt8) -> Bool {
        let low: UInt64 = 0xC400_3462_0000_0000
        let high: UInt64 = 0x3800_0001_2800_0001
        return c < 64 ? low >> UInt64(c) & 1 != 0 : c < 128 && high >> UInt64(c & 63) & 1 != 0
    }

    // MARK: Structure

    @inline(__always)
    private mutating func newNode(_ kind: NodeKind, parent: UInt32) -> UInt32 {
        let k = nodeCount
        (nodes + k).initialize(to: Node(kind: kind, parent: parent, line: UInt32(line)))
        (types + k).initialize(to: .string)
        nodeCount += 1
        return UInt32(k)
    }

    @inline(__always)
    private mutating func appendChild(_ child: UInt32, toFrame f: Int) {
        let last = frames[f].last
        if last == Node.none {
            nodes[Int(frames[f].node)].firstChild = child
        } else {
            nodes[Int(last)].nextSibling = child
        }
        frames[f].last = child
    }

    @inline(__always)
    private mutating func pushFrame(_ level: Int, _ node: UInt32) {
        (frames + frameCount).initialize(to: Frame(level: level, node: node, last: Node.none, keysStart: keyCount,
                                                   table: nil))
        (filters + frameCount * 4).initialize(repeating: 0, count: 4)
        frameCount += 1
    }

    @inline(__always)
    private mutating func popFrame() {
        frameCount -= 1
        let f = frames[frameCount]
        keyCount = f.keysStart
        if let table = f.table { finishedTables[f.node] = table.takeRetainedValue() }
    }

    // Joins the current node line, at `level`, to the structure.
    @inline(__always)
    private mutating func structure(_ level: Int) -> Bool {
        let bare = !dash && keyKind == .none
        if slotLevel >= 0 {
            guard level == slotLevel && !bare else { return false }  // valueOnNextLine, indentation, missingValue
            let c = newNode(dash ? .sequence : .mapping, parent: slotOwner)
            if nodes[Int(slotOwner)].kind == .entry {
                nodes[Int(slotOwner)].firstChild = c
            } else {
                appendChild(c, toFrame: frameCount - 1)
            }
            pushFrame(level, c)
            slotLevel = -1
        } else if frameCount == 0 {
            guard level == 0 && !rootScalar else { return false }    // indentationJump, contentAfterRootScalar
            if bare {
                root = value(parent: Node.none)
                rootScalar = true
                return !typeFailed
            }
            root = newNode(dash ? .sequence : .mapping, parent: Node.none)
            pushFrame(0, root)
        } else {
            while frames[frameCount - 1].level > level { popFrame() }
            guard frames[frameCount - 1].level == level else { return false }  // indentationJump
        }

        var top = frameCount - 1
        let collection = frames[top].node
        if dash {
            guard nodes[Int(collection)].kind == .sequence else { return false }  // mixedCollection
            if keyKind == .none {
                if valueKind == .none {
                    slotLevel = level + 1
                    slotOwner = collection
                } else {
                    appendChild(value(parent: collection), toFrame: top)
                }
                return !typeFailed
            }
            let m = newNode(.mapping, parent: collection)
            appendChild(m, toFrame: top)
            pushFrame(level + 1, m)
            top += 1
        } else {
            guard !bare && nodes[Int(collection)].kind == .mapping else { return false }  // bareScalar, mixed
        }

        let e = newNode(.entry, parent: frames[top].node)
        appendChild(e, toFrame: top)
        guard key(entry: e, frame: top) else { return false }
        if valueKind == .none {
            slotLevel = frames[top].level + 1
            slotOwner = e
        } else {
            nodes[Int(e)].firstChild = value(parent: e)
        }
        return !typeFailed
    }

    // A node for the current line's value, typed; a rejected spelling or a bad escape sets `typeFailed`.
    @inline(__always)
    private mutating func value(parent: UInt32) -> UInt32 {
        switch valueKind {
        case .emptySequence: return newNode(.sequence, parent: parent)
        case .emptyMapping: return newNode(.mapping, parent: parent)
        case .plain:
            let v = newNode(.scalar, parent: parent)
            types[Int(v)] = type(Int(r.valueStart), Int(r.valueEnd))
            return v
        case .doubleQuoted:
            if !escapesValid(Int(r.valueStart), Int(r.valueEnd)) { typeFailed = true }
            return newNode(.scalar, parent: parent)
        default:
            return newNode(.scalar, parent: parent)
        }
    }

    private var typeFailed = false

    // The Core type of a plain scalar (spec §11–§16). Shortcuts: a first byte that cannot start a non-string,
    // the exact words, decimal integers of at most 18 digits, and floats without an exponent of at most 300
    // integer digits; neither can overflow. The rest goes to `ScalarTyping.classify`; a rejection sets
    // `typeFailed`.
    @inline(__always)
    private mutating func type(_ start: Int, _ stop: Int) -> ScalarType {
        let c = b[start]
        let length = stop - start
        switch c {
        case 0x30...0x39, Char.dash, Char.dot:
            var k = c == Char.dash ? start + 1 : start
            let digitsStart = k
            while k < stop && b[k] &- 0x30 < 10 { k += 1 }
            let digits = k - digitsStart
            if k == stop {
                if digits > 0 && digits <= 18 { return .integer }  // leading zeros are decimal (§12)
            } else if b[k] == Char.dot && digits <= 300 {
                k += 1
                let fractionStart = k
                while k < stop && b[k] &- 0x30 < 10 { k += 1 }
                if k == stop && (digits > 0 || k > fractionStart) { return .float }
            }
        case 0x74, 0x66, 0x6E:  // t f n
            guard length == 4 || length == 5 else { return .string }
            let w = UnsafeRawPointer(b + start).loadUnaligned(as: UInt32.self)
            if length == 4 && w == 0x6575_7274 { return .boolean }      // true
            if length == 4 && w == 0x6C6C_756E { return .null }         // null
            if length == 5 && w == 0x736C_6166 && b[start + 4] == 0x65 { return .boolean }  // false
            // Another casing of a word is rejected by the classifier; anything else is a string.
            let lower = w | 0x2020_2020
            let word = length == 4 ? lower == 0x6575_7274 || lower == 0x6C6C_756E
                : lower == 0x736C_6166 && b[start + 4] | 0x20 == 0x65
            if !word { return .string }
        case 0x54, 0x46, 0x4E:  // T F N
            guard length == 4 || length == 5 else { return .string }
        case Char.plus, 0x7E:  // + ~
            break
        default:
            return .string
        }
        switch ScalarTyping.classify(buffer, start, stop) {
        case .type(let t):
            return t
        case .rejected:
            typeFailed = true
            return .string
        }
    }

    // Whether every escape in the double-quoted scalar `b[start..<stop]`, quotes included, is well formed.
    @inline(__always)
    private func escapesValid(_ start: Int, _ stop: Int) -> Bool {
        var i = start + 1
        while true {
            i = nextQuote(i)
            if i >= stop - 1 { return true }
            if b[i] == Char.backslash {
                guard case .scalar(_, let length) = ScalarText.escape(buffer, at: i, end: stop - 1) else { return false }
                i += length
            } else {
                i += 1
            }
        }
    }

    // MARK: Keys

    // Types and checks the current line's key, and records it in its mapping (spec §6).
    @inline(__always)
    private mutating func key(entry: UInt32, frame f: Int) -> Bool {
        let start = Int(r.keyStart), stop = Int(r.keyEnd)
        var hash: UInt64
        switch keyKind {
        case .plain:
            if type(start, stop) != .string || typeFailed { return false }  // nonStringKey, rejections
            let h = KeyHash.folded(b + start, stop - start, readable: count - start)
            hash = h.ascii ? h.hash : foldedHash(r)
        case .doubleQuoted:
            guard escapesValid(start, stop) else { return false }
            hash = foldedHash(r)
        default:
            hash = foldedHash(r)
        }

        if let unmanaged = frames[f].table {
            let table = unmanaged.takeUnretainedValue()
            var probe = table.first(hash)
            while let e = table.key(at: probe) {
                if table.hash(at: probe) == hash && sameKey(UInt32(e)) { return false }  // duplicateKey
                probe = table.next(probe)
            }
            table.insert(Int(entry), hash: hash)
            return true
        }
        let first = frames[f].keysStart
        let bit = Int(truncatingIfNeeded: hash >> 56)
        let word = filters + f * 4 + (bit >> 6)
        let mask: UInt64 = 1 << UInt64(bit & 63)
        if word.pointee & mask != 0 {
            for k in first..<keyCount where keys[k].hash == hash && sameKey(keys[k].entry) { return false }
        }
        word.pointee |= mask
        (keys + keyCount).initialize(to: Key(hash: hash, entry: entry))
        keyCount += 1
        if keyCount - first > StructureBuilder.linearKeys {
            let table = KeyTable()
            for k in first..<keyCount { table.insert(Int(keys[k].entry), hash: keys[k].hash) }
            frames[f].table = Unmanaged.passRetained(table)
        }
        return true
    }

    // The key of `r` decoded and case-folded, as stage 3 compares keys.
    private func foldedKey(_ r: LineRecord) -> [UInt8] {
        let quote: UInt8? = r.keyKind == .plain ? nil : r.keyKind == .singleQuoted ? Char.squote : Char.dquote
        var text: [UInt8] = []
        _ = ScalarText.appendDecoded(buffer, Int(r.keyStart), Int(r.keyEnd), quote: quote, to: &text)
        ScalarText.fold(&text)
        return text
    }

    @inline(never)
    private func foldedHash(_ r: LineRecord) -> UInt64 {
        let text = foldedKey(r)
        return text.withUnsafeBufferPointer { t in
            t.isEmpty ? KeyHash.empty : KeyHash.folded(t.baseAddress!, t.count, readable: t.count).hash
        }
    }

    // Whether the key of entry `e`, on an earlier line, equals the current line's key; the hashes matched.
    @inline(never)
    private func sameKey(_ e: UInt32) -> Bool {
        foldedKey(records[Int(nodes[Int(e)].line)]) == foldedKey(r)
    }
}
