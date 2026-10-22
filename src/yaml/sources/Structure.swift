// Stage 3: build the document's structure from its line records (spec §3, §5–§9.1, §23).
//
// One walk over the lines with a stack of open collections, one per level: levels are exactly one apart, so
// a line at level L belongs to the collection at L, and a shallower line closes every deeper one. A key or
// dash with nothing after it on its line owes a value, which must be a collection starting on the next node
// line, exactly one level deeper. Blank lines, comments and block scalar content carry no structure.
//
// After an error, lines deeper than the failing line are skipped, so one mistake does not cascade. Lines that
// stage 2 marked invalid are skipped the same way, without a new report.

public enum NodeKind: UInt8 {
    case mapping    // children are entries
    case sequence   // children are the items
    case scalar     // a plain, quoted or block scalar
    case entry      // a mapping entry: its key is on its line, its one child is the value
}

// One node of the arena. `line` is the line record that holds the node: a scalar's value, an entry's key,
// or a collection's first entry or item. `[]` and `{}` are a childless sequence and mapping.
public struct Node: Equatable {
    public static let none = UInt32.max

    public internal(set) var kind: NodeKind
    public internal(set) var parent: UInt32
    public internal(set) var firstChild = Node.none
    public internal(set) var nextSibling = Node.none
    public internal(set) var line: UInt32
}

public struct NodeArena: Equatable {
    public let nodes: [Node]
    public let root: UInt32   // `Node.none` when the document has no value

    public subscript(node: UInt32) -> Node { nodes[Int(node)] }

    public func children(of node: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var c = nodes[Int(node)].firstChild
        while c != Node.none {
            out.append(c)
            c = nodes[Int(c)].nextSibling
        }
        return out
    }
}

public struct Structuring: Equatable {
    public let arena: NodeArena
    public let errors: YAMLErrors
    // The duplicate-key tables of mappings past `StructureBuilder.linearKeys` entries, by mapping node. Each
    // indexes the mapping's entry nodes by the hash of their case-folded keys; the document API keeps them
    // for key lookup.
    let keyTables: [UInt32: KeyTable]

    public static func == (x: Structuring, y: Structuring) -> Bool { x.arena == y.arena && x.errors == y.errors }
}

// Builds the structure of a lexed source. `lexing.errors` carries the earlier stages' errors forward.
public func buildStructure(_ bytes: UnsafeBufferPointer<UInt8>, _ lexing: Lexing) -> Structuring {
    lexing.records.lines.withUnsafeBufferPointer { records in
        var builder = StructureBuilder(bytes, records, lexing.errors)
        builder.run()
        return Structuring(arena: NodeArena(nodes: builder.nodes.array, root: builder.root), errors: builder.errors,
                           keyTables: builder.finishedTables)
    }
}

public func buildStructure(_ bytes: [UInt8], _ lexing: Lexing) -> Structuring {
    bytes.withUnsafeBufferPointer { buildStructure($0, lexing) }
}

struct StructureBuilder {
    // A mapping holding more entries than this indexes its keys by hash instead of scanning them.
    static let linearKeys = 32

    // An open collection.
    private struct Frame {
        let level: Int
        let node: UInt32
        var lastChild = Node.none
        let keysStart: Int      // the collection's first key in `keys`
        var keyIndex = -1       // its table in `keyTables`, once past `linearKeys` keys
    }

    // A value owed by a key or dash with nothing after it on its line.
    private struct Slot {
        let level: Int      // the level of the collection that must follow
        let owner: UInt32   // the entry, or the sequence of a bare dash
        let span: ByteSpan  // the key or dash, for reporting
        let keyLevel: Int   // the owning key's level, where an indentless sequence would sit; -1 for a dash
        var erred = false   // an error was reported at the slot's level; it is not reported missing as well
    }

    // A key of an open mapping, for duplicate detection: the hash of its decoded, case-folded text. Keys are
    // compared in full only when hashes match, which is rare unless they are duplicates.
    private struct Key {
        let hash: UInt64
        let line: UInt32
        let entry: UInt32
    }

    private let b: UnsafeBufferPointer<UInt8>
    private let records: UnsafeBufferPointer<LineRecord>
    private(set) var errors: YAMLErrors
    let nodes: GrowableBuffer<Node>
    private(set) var root = Node.none

    private let frames = GrowableBuffer<Frame>(capacity: 64)
    private var slot: Slot?
    private let keys = GrowableBuffer<Key>(capacity: 256)
    // A hash table of entry nodes for each open mapping past `linearKeys` keys, and the tables of closed ones.
    private var keyTables: [KeyTable] = []
    private(set) var finishedTables: [UInt32: KeyTable] = [:]

    // Skips lines deeper than `skipLevel`, and with `skipDashes` also dash lines at it, after an error.
    private var skipLevel: Int?
    private var skipDashes = false

    // Whether the last value placed was a plain scalar, which a deeper line would continue.
    private var lastPlain = false
    private var rootScalar = false

    // Document state (spec §3).
    private var sawStart = false
    private var sawContent = false
    private var ended = false
    private var stopped = false     // a document-level error ended the walk

    init(_ bytes: UnsafeBufferPointer<UInt8>, _ records: UnsafeBufferPointer<LineRecord>, _ errors: YAMLErrors) {
        b = bytes
        self.records = records
        self.errors = errors
        nodes = GrowableBuffer(capacity: records.count * 2)
    }

    mutating func run() {
        for i in records.indices {
            switch records[i].kind {
            case .blank, .comment, .blockContent: continue
            case .documentStart: documentStart(i)
            case .documentEnd: documentEnd(i)
            case .invalid: invalidLine(i)
            case .node: nodeLine(i)
            }
        }
        closeSlot()
        while frames.count > 0 { popFrame() }
        if !sawContent && !stopped {
            errors.report(YAMLError(.emptyDocument, ByteSpan(at: 0), "the document has no value"))
        }
    }

    // MARK: Documents

    private mutating func documentStart(_ i: Int) {
        guard !stopped else { return }
        if sawContent || sawStart || ended {
            report(.multipleDocuments, markerSpan(i), "a file holds one document")
            stopped = true
            return
        }
        sawStart = true
    }

    private mutating func documentEnd(_ i: Int) {
        guard !stopped else { return }
        if ended {
            report(.contentAfterDocumentEnd, markerSpan(i), "only comments may follow `...`")
            stopped = true
            return
        }
        closeSlot()
        ended = true
    }

    // MARK: Lines

    private mutating func nodeLine(_ i: Int) {
        guard !stopped else { return }
        let r = records[i]
        if ended {
            report(.contentAfterDocumentEnd, contentSpan(r), "only comments may follow `...`")
            stopped = true
            return
        }
        sawContent = true
        let level = Int(r.level)
        if skipping(level, dash: r.hasDash) { return }
        let bare = !r.hasDash && r.keyKind == .none

        if rootScalar {
            if bare && lastPlain {
                report(.multilinePlainScalar, contentSpan(r), "a plain scalar cannot continue onto the next line",
                       fix: "use a block scalar (`|` or `>`) for multi-line text")
            } else {
                report(.contentAfterRootScalar, contentSpan(r), "a scalar document holds only that scalar")
            }
            stopped = true
            return
        }

        if let s = slot {
            if level == s.level {
                if bare {
                    report(.valueOnNextLine, valueSpan(r), "a value starts on its key's or dash's line",
                           fix: "move it up after the colon or dash")
                    slot!.erred = true
                    skip(deeperThan: level)
                    return
                }
                slot = nil
                let c = newNode(r.hasDash ? .sequence : .mapping, parent: s.owner, line: i)
                appendChild(c, to: s.owner)
                frames.append(Frame(level: level, node: c, keysStart: keys.count))
                addLine(i)
                return
            }
            if level > s.level {
                report(.indentationJump, indentSpan(r), "this line is indented more than one level past its parent",
                       fix: "indent nested lines two spaces")
                slot!.erred = true
                skip(deeperThan: level)
                return
            }
            if r.hasDash && level == s.keyLevel {
                report(.indentlessSequence, dashSpan(r), "a sequence is indented under its key",
                       fix: "indent the sequence two spaces deeper than its key")
                slot = nil
                skip(deeperThan: level, dashes: true)
                return
            }
            closeSlot()
        }

        guard let top = frames.last else {
            if level != 0 {
                report(.indentationJump, indentSpan(r), "the document's top level is not indented")
                skip(deeperThan: level)
                return
            }
            if bare {
                root = valueNode(i, parent: Node.none)
                rootScalar = true
                lastPlain = r.valueKind == .plain
                return
            }
            root = newNode(r.hasDash ? .sequence : .mapping, parent: Node.none, line: i)
            frames.append(Frame(level: 0, node: root, keysStart: 0))
            addLine(i)
            return
        }
        if level > top.level {
            if lastPlain {
                report(.multilinePlainScalar, contentSpan(r), "a plain scalar cannot continue onto the next line",
                       fix: "use a block scalar (`|` or `>`) for multi-line text")
            } else {
                report(.indentationJump, indentSpan(r), "nothing can nest under a complete value")
            }
            skip(deeperThan: top.level)
            return
        }
        while frames[frames.count - 1].level > level { popFrame() }
        addLine(i)
    }

    // A line stage 2 rejected: it reported already, so this only keeps the walk in step.
    private mutating func invalidLine(_ i: Int) {
        guard !stopped && !ended else { return }
        sawContent = true
        let r = records[i]
        var indent = 0
        while Int(r.contentStart) + indent < Int(r.contentEnd) && b[Int(r.contentStart) + indent] == 0x20 {
            indent += 1
        }
        let level = (indent + 1) / 2
        if skipping(level, dash: false) { return }
        if let s = slot, level >= s.level { slot!.erred = true }
        lastPlain = false
        skip(deeperThan: level)
    }

    // Adds line `i`'s item or entry to the collection on top of the stack, which sits at the line's level.
    private mutating func addLine(_ i: Int) {
        let r = records[i]
        let top = frames.count - 1
        let level = frames[top].level
        let collection = frames[top].node
        if nodes[Int(collection)].kind == .sequence {
            guard r.hasDash else {
                if r.keyKind != .none {
                    report(.mixedCollection, keySpan(r), "a mapping entry among sequence items",
                           fix: "give every line at this level a dash, or none")
                } else {
                    report(.bareScalar, valueSpan(r), "a sequence item needs a dash", fix: "write `- \(text(valueSpan(r)))`")
                }
                skip(deeperThan: level)
                return
            }
            if r.keyKind != .none {
                let m = newNode(.mapping, parent: collection, line: i)
                appendChild(m, to: collection)
                frames.append(Frame(level: level + 1, node: m, keysStart: keys.count))
                addEntry(i, level: level + 1)
            } else if r.valueKind != .none {
                appendChild(valueNode(i, parent: collection), to: collection)
                lastPlain = r.valueKind == .plain
            } else {
                slot = Slot(level: level + 1, owner: collection, span: dashSpan(r), keyLevel: -1)
            }
            return
        }
        guard !r.hasDash && r.keyKind != .none else {
            if r.hasDash {
                report(.mixedCollection, dashSpan(r), "a sequence item among mapping entries",
                       fix: "give every line at this level a dash, or none")
            } else {
                report(.bareScalar, valueSpan(r), "a mapping entry needs a key",
                       fix: "write `key: \(text(valueSpan(r)))`")
            }
            skip(deeperThan: level)
            return
        }
        addEntry(i, level: level)
    }

    // Adds line `i`'s key, and its value if on the line, to the mapping on top of the stack.
    private mutating func addEntry(_ i: Int, level: Int) {
        let r = records[i]
        let mapping = frames[frames.count - 1].node
        let entry = newNode(.entry, parent: mapping, line: i)
        appendChild(entry, to: mapping)
        checkDuplicate(i, entry: entry)
        if r.valueKind != .none {
            nodes[Int(entry)].firstChild = valueNode(i, parent: entry)
            lastPlain = r.valueKind == .plain
        } else {
            slot = Slot(level: level + 1, owner: entry, span: keySpan(r), keyLevel: level)
        }
    }

    // MARK: Duplicate keys

    // Reports line `i`'s key if the mapping on top of the stack already holds it, comparing decoded keys
    // under simple case folding (spec §6). A key with a malformed escape is skipped; stage 4 reports it.
    private mutating func checkDuplicate(_ i: Int, entry: UInt32) {
        guard let hash = keyHash(i) else { return }
        let top = frames.count - 1
        let start = frames[top].keysStart
        let table = frames[top].keyIndex >= 0 ? keyTables[frames[top].keyIndex] : nil
        if let table {
            var probe = table.first(hash)
            while let e = table.key(at: probe) {
                let line = Int(nodes[e].line)
                if table.hash(at: probe) == hash && sameKey(line, i) { return duplicate(i, line) }
                probe = table.next(probe)
            }
        } else {
            for k in start..<keys.count where keys[k].hash == hash && sameKey(Int(keys[k].line), i) {
                return duplicate(i, Int(keys[k].line))
            }
        }

        if let table {
            table.insert(Int(entry), hash: hash)
            return
        }
        keys.append(Key(hash: hash, line: UInt32(i), entry: entry))
        if keys.count - start > StructureBuilder.linearKeys {
            let table = KeyTable()
            for k in start..<keys.count { table.insert(Int(keys[k].entry), hash: keys[k].hash) }
            frames[top].keyIndex = keyTables.count
            keyTables.append(table)
        }
    }

    @inline(never)
    private mutating func duplicate(_ i: Int, _ first: Int) {
        let r = records[i]
        report(.duplicateKey, keySpan(r), "duplicate key `\(text(keySpan(r)))`; line \(first + 1) has the same key",
               fix: "keys are compared after decoding and ignoring case")
    }

    // The hash of line `i`'s decoded, case-folded key, or nil when the key has a malformed escape. A plain
    // ASCII key, the common case, is hashed straight from the source.
    private func keyHash(_ i: Int) -> UInt64? {
        let r = records[i]
        if r.keyKind == .plain {
            let start = Int(r.keyStart)
            let h = KeyHash.folded(b.baseAddress! + start, Int(r.keyEnd) - start, readable: b.count - start)
            if h.ascii { return h.hash }
        }
        guard let text = foldedKey(i) else { return nil }
        return text.withUnsafeBufferPointer { t in
            t.isEmpty ? KeyHash.empty
                : KeyHash.folded(t.baseAddress!, t.count, readable: t.count).hash
        }
    }

    // Line `i`'s key decoded and case-folded, or nil when it has a malformed escape.
    private func foldedKey(_ i: Int) -> [UInt8]? {
        let r = records[i]
        let quote: UInt8? = r.keyKind == .plain ? nil : r.keyKind == .singleQuoted ? 0x27 : 0x22
        var text: [UInt8] = []
        guard ScalarText.appendDecoded(b, Int(r.keyStart), Int(r.keyEnd), quote: quote, to: &text) else {
            return nil
        }
        ScalarText.fold(&text)
        return text
    }

    // Whether the keys on lines `x` and `y` are the same after decoding and folding.
    private func sameKey(_ x: Int, _ y: Int) -> Bool {
        foldedKey(x) == foldedKey(y)
    }

    // MARK: Helpers

    private mutating func popFrame() {
        let f = frames[frames.count - 1]
        frames.removeLast()
        keys.removeLast(keys.count - f.keysStart)
        if f.keyIndex >= 0 { finishedTables[f.node] = keyTables.removeLast() }
    }

    // Reports the owed value as missing, unless an error at its level was reported instead.
    private mutating func closeSlot() {
        if let s = slot, !s.erred {
            report(.missingValue, s.span, "a value is missing",
                   fix: "write \"\" for an empty string, [] or {} for an empty collection")
        }
        slot = nil
    }

    private mutating func skip(deeperThan level: Int, dashes: Bool = false) {
        skipLevel = level
        skipDashes = dashes
    }

    // Whether a line at `level` is skipped after an error; a line that is not ends the skipping.
    private mutating func skipping(_ level: Int, dash: Bool) -> Bool {
        guard let s = skipLevel else { return false }
        if level > s || (skipDashes && dash && level == s) { return true }
        skipLevel = nil
        return false
    }

    private mutating func newNode(_ kind: NodeKind, parent: UInt32, line: Int) -> UInt32 {
        nodes.append(Node(kind: kind, parent: parent, line: UInt32(line)))
        return UInt32(nodes.count - 1)
    }

    // The node for line `i`'s value: a scalar, or a childless collection for `[]` and `{}`.
    private mutating func valueNode(_ i: Int, parent: UInt32) -> UInt32 {
        switch records[i].valueKind {
        case .emptySequence: return newNode(.sequence, parent: parent, line: i)
        case .emptyMapping: return newNode(.mapping, parent: parent, line: i)
        default: return newNode(.scalar, parent: parent, line: i)
        }
    }

    // Appends `child` to `parent`: an entry takes one child; a collection is the one on top of the stack.
    private mutating func appendChild(_ child: UInt32, to parent: UInt32) {
        if nodes[Int(parent)].kind == .entry {
            nodes[Int(parent)].firstChild = child
            return
        }
        let top = frames.count - 1
        let last = frames[top].lastChild
        if last == Node.none { nodes[Int(parent)].firstChild = child } else { nodes[Int(last)].nextSibling = child }
        frames[top].lastChild = child
    }

    // MARK: Spans

    private func indentSpan(_ r: LineRecord) -> ByteSpan {
        ByteSpan(start: r.contentStart, end: r.contentStart + UInt32(r.level) * 2)
    }

    private func dashSpan(_ r: LineRecord) -> ByteSpan {
        let at = r.contentStart + UInt32(r.level) * 2
        return ByteSpan(start: at, end: at + 1)
    }

    private func keySpan(_ r: LineRecord) -> ByteSpan { ByteSpan(start: r.keyStart, end: r.keyEnd) }
    private func valueSpan(_ r: LineRecord) -> ByteSpan { ByteSpan(start: r.valueStart, end: r.valueEnd) }

    // From the line's first token to its end, comment excluded.
    private func contentSpan(_ r: LineRecord) -> ByteSpan {
        var start = Int(r.contentStart)
        while start < Int(r.contentEnd) && b[start] == 0x20 { start += 1 }
        var end = r.hasComment ? Int(r.commentStart) : Int(r.contentEnd)
        while end > start && b[end - 1] == 0x20 { end -= 1 }
        return ByteSpan(start: UInt32(start), end: UInt32(end))
    }

    private func markerSpan(_ i: Int) -> ByteSpan {
        ByteSpan(start: records[i].contentStart, end: records[i].contentStart + 3)
    }

    private func text(_ s: ByteSpan) -> String {
        String(decoding: b[Int(s.start)..<Int(s.end)], as: UTF8.self)
    }

    @inline(never)
    private mutating func report(_ code: YAMLError.Code, _ span: ByteSpan, _ message: String, fix: String? = nil) {
        errors.report(YAMLError(code, span, message, fix: fix))
    }
}

// Hashes keys a word at a time.
enum KeyHash {
    // The hash of no bytes.
    static let empty: UInt64 = 0x9E37_79B9_7F4A_7C15

    // The hash of `count` bytes at `p` with ASCII letters folded to lower case, and whether every byte is
    // ASCII. Bytes from 0x80 hash unchanged, so a key already folded by `ScalarText.fold` hashes the same as
    // an ASCII key folded here. `readable` bytes are safe to read from `p`, so whole words load while they fit.
    @inline(__always)
    static func folded(_ p: UnsafePointer<UInt8>, _ count: Int, readable: Int) -> (hash: UInt64, ascii: Bool) {
        var h = empty ^ UInt64(count)
        var high: UInt64 = 0
        var k = 0
        while k < count {
            let n = min(8, count - k)
            var w: UInt64
            if k + 8 <= readable {
                w = UnsafeRawPointer(p + k).loadUnaligned(as: UInt64.self)
                if n < 8 { w &= (1 << UInt64(n * 8)) - 1 }
            } else {
                w = 0
                for j in 0..<n { w |= UInt64(p[k + j]) << UInt64(j * 8) }
            }
            high |= w
            h = (h ^ lower(w)) &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 31
            k += 8
        }
        return (h, high & 0x8080_8080_8080_8080 == 0)
    }

    // ASCII A–Z to a–z in each byte; bytes from 0x80 are unchanged.
    @inline(__always)
    static func lower(_ w: UInt64) -> UInt64 {
        let low = w & 0x7F7F_7F7F_7F7F_7F7F
        let fromA = low &+ 0x3F3F_3F3F_3F3F_3F3F   // high bit set from 0x41
        let fromBracket = low &+ 0x2525_2525_2525_2525   // high bit set from 0x5B
        let upper = fromA & ~fromBracket & ~w & 0x8080_8080_8080_8080
        return w | upper >> 2
    }
}

// An open-addressing table of entry nodes by key hash (linear probing, at most half full), for mappings with many
// keys. Keys with equal hashes sit in one probe run, so a lookup walks the run from `first`.
final class KeyTable {
    private var hashes: UnsafeMutablePointer<UInt64>
    private var indexes: UnsafeMutablePointer<UInt32>  // `empty` for an empty slot
    private static let empty = UInt32.max
    private var capacity = 64
    private var count = 0

    init() {
        hashes = .allocate(capacity: capacity)
        indexes = .allocate(capacity: capacity)
        indexes.initialize(repeating: KeyTable.empty, count: capacity)
    }

    deinit {
        hashes.deallocate()
        indexes.deallocate()
    }

    @inline(__always) func first(_ hash: UInt64) -> Int { Int(truncatingIfNeeded: hash) & (capacity - 1) }
    @inline(__always) func next(_ probe: Int) -> Int { (probe + 1) & (capacity - 1) }
    @inline(__always) func key(at probe: Int) -> Int? { indexes[probe] == KeyTable.empty ? nil : Int(indexes[probe]) }
    @inline(__always) func hash(at probe: Int) -> UInt64 { hashes[probe] }

    func insert(_ k: Int, hash: UInt64) {
        if (count + 1) * 2 > capacity { grow() }
        place(UInt32(k), hash)
        count += 1
    }

    private func place(_ k: UInt32, _ hash: UInt64) {
        var probe = first(hash)
        while indexes[probe] != KeyTable.empty { probe = next(probe) }
        hashes[probe] = hash
        indexes[probe] = k
    }

    private func grow() {
        let (oldHashes, oldIndexes, oldCapacity) = (hashes, indexes, capacity)
        capacity *= 2
        hashes = .allocate(capacity: capacity)
        indexes = .allocate(capacity: capacity)
        indexes.initialize(repeating: KeyTable.empty, count: capacity)
        for s in 0..<oldCapacity where oldIndexes[s] != KeyTable.empty { place(oldIndexes[s], oldHashes[s]) }
        oldHashes.deallocate()
        oldIndexes.deallocate()
    }
}
