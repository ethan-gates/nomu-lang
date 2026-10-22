// The document API: a parsed document and handles to its values (task 200, "API layers").
//
// A document keeps its source bytes, line records, node arena and scalar types; values are read from them on
// demand. Strings are decoded when read and numbers parsed again from spellings stage 4 checked. Comments live
// only in the bytes and line records, so the model exposes values, keys and spans, and the bytes render an
// unedited document exactly (spec §25.1).

public final class YAMLDocument {
    public let bytes: [UInt8]
    public let lines: LineIndex
    // The file's line-ending style; edits write new lines in it.
    let lineEnding: LineEnding
    let records: [LineRecord]
    let arena: NodeArena
    let types: [ScalarType]
    // The duplicate-key tables of mappings past `StructureBuilder.linearKeys` entries, kept for lookup; smaller
    // mappings are scanned.
    private let keyTables: [UInt32: KeyTable]

    // Parses `bytes`, throwing every error found (up to `YAMLErrors.limit`). A document stage 1 accepts takes
    // the parser (`Parse.swift`); at its first error, the diagnostic path runs and reports every error.
    public init(parsing bytes: [UInt8]) throws(YAMLErrors) {
        let v = validate(bytes)
        guard let source = v.source else { throw v.errors }
        self.bytes = bytes
        lines = source.lines
        lineEnding = source.lineEnding
        if v.errors.isEmpty, let parsed = bytes.withUnsafeBufferPointer({ parse($0, source) }) {
            records = parsed.records
            arena = parsed.arena
            types = parsed.types
            keyTables = parsed.keyTables
            return
        }
        let l = lexLines(bytes, source, errors: v.errors)
        let s = buildStructure(bytes, l)
        let r = resolveScalars(bytes, l, s)
        guard r.errors.isEmpty else { throw r.errors }
        records = l.records.lines
        arena = s.arena
        types = r.types
        keyTables = s.keyTables
    }

    public convenience init(parsing text: String) throws(YAMLErrors) {
        try self.init(parsing: Array(text.utf8))
    }

    // The document's value. A document without one fails to parse (`emptyDocument`).
    public var root: YAMLNode { YAMLNode(document: self, index: arena.root) }

    // 1-based line and byte column of a source offset.
    public func location(of offset: UInt32) -> (line: Int, column: Int) { lines.location(of: offset) }

    // MARK: Keys

    // Calls `body` with the decoded text of the key on line `r`. A plain key is its source bytes.
    private static func withKey<T>(_ b: UnsafeBufferPointer<UInt8>, _ r: LineRecord,
                                   _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        let start = Int(r.keyStart), end = Int(r.keyEnd)
        if r.keyKind == .plain { return body(UnsafeBufferPointer(rebasing: b[start..<end])) }
        var text: [UInt8] = []
        _ = ScalarText.appendDecoded(b, start, end, quote: r.keyKind == .singleQuoted ? 0x27 : 0x22, to: &text)
        return text.withUnsafeBufferPointer(body)
    }

    // The table hash of the key text `q`: the hash of its case-folded form, as stage 3 computes for each key.
    // Lookups compare exact text, and exactly equal keys fold alike.
    private static func tableHash(_ q: UnsafeBufferPointer<UInt8>) -> UInt64 {
        guard let p = q.baseAddress, !q.isEmpty else { return KeyHash.empty }
        let h = KeyHash.folded(p, q.count, readable: q.count)
        if h.ascii { return h.hash }
        var text = Array(q)
        ScalarText.fold(&text)
        return text.withUnsafeBufferPointer { KeyHash.folded($0.baseAddress!, $0.count, readable: $0.count).hash }
    }

    // The entry of mapping `m` whose decoded key is exactly `key`.
    func entry(of m: UInt32, key: String) -> UInt32? {
        var key = key
        return key.withUTF8 { q in
            bytes.withUnsafeBufferPointer { b in
                if let table = keyTables[m] {
                    let hash = YAMLDocument.tableHash(q)
                    var probe = table.first(hash)
                    while let e = table.key(at: probe) {
                        if table.hash(at: probe) == hash && keyMatches(b, UInt32(e), q) { return UInt32(e) }
                        probe = table.next(probe)
                    }
                    return nil
                }
                var e = arena[m].firstChild
                while e != Node.none {
                    if keyMatches(b, e, q) { return e }
                    e = arena[e].nextSibling
                }
                return nil
            }
        }
    }

    func keyMatches(_ b: UnsafeBufferPointer<UInt8>, _ e: UInt32, _ q: UnsafeBufferPointer<UInt8>) -> Bool {
        let r = records[Int(arena[e].line)]
        let length = Int(r.keyEnd - r.keyStart)
        // A plain key is its source bytes; a quoted one decodes to at most its body's length.
        if r.keyKind == .plain {
            return length == q.count && (length == 0 || YAMLDocument.equal(b.baseAddress! + Int(r.keyStart), q.baseAddress!, length))
        }
        if length - 2 < q.count { return false }
        return YAMLDocument.withKey(b, r) { k in
            k.count == q.count && (k.count == 0 || YAMLDocument.equal(k.baseAddress!, q.baseAddress!, k.count))
        }
    }

    // Whether `count` bytes at `x` and `y` are equal, compared a word at a time.
    @inline(__always)
    static func equal(_ x: UnsafePointer<UInt8>, _ y: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var i = 0
        while i + 8 <= count {
            if UnsafeRawPointer(x + i).loadUnaligned(as: UInt64.self) != UnsafeRawPointer(y + i).loadUnaligned(as: UInt64.self) {
                return false
            }
            i += 8
        }
        while i < count {
            if x[i] != y[i] { return false }
            i += 1
        }
        return true
    }

    func keyText(_ e: UInt32) -> String {
        bytes.withUnsafeBufferPointer { b in
            YAMLDocument.withKey(b, records[Int(arena[e].line)]) { String(decoding: $0, as: UTF8.self) }
        }
    }

    // MARK: Values

    func scalarBytes(_ n: UInt32) -> [UInt8] {
        bytes.withUnsafeBufferPointer { ScalarText.value($0, records, line: Int(arena[n].line)) }
    }

    func valueSpan(_ n: UInt32) -> (start: Int, end: Int) {
        let r = records[Int(arena[n].line)]
        return (Int(r.valueStart), Int(r.valueEnd))
    }

    // The span of node `n`. A scalar spans its spelling, quotes included; a block scalar runs from its header
    // to its last non-blank content line. A collection runs from its first key or dash to the end of its last
    // value; `[]` and `{}` span their brackets.
    func span(_ n: UInt32) -> ByteSpan {
        let node = arena[n]
        let r = records[Int(node.line)]
        switch node.kind {
        case .scalar:
            return ByteSpan(start: r.valueStart, end: scalarEnd(n))
        case .entry:
            return ByteSpan(start: r.keyStart, end: end(of: n))
        case .mapping, .sequence:
            if node.firstChild == Node.none { return ByteSpan(start: r.valueStart, end: r.valueEnd) }
            let start = node.kind == .mapping ? r.keyStart : r.contentStart + UInt32(r.level) * 2
            return ByteSpan(start: start, end: end(of: n))
        }
    }

    // Where the last value under node `n` ends.
    private func end(of n: UInt32) -> UInt32 {
        var n = n
        while true {
            let node = arena[n]
            guard node.firstChild != Node.none else {
                let r = records[Int(node.line)]
                return node.kind == .scalar ? scalarEnd(n) : r.valueEnd
            }
            var c = node.firstChild
            while arena[c].nextSibling != Node.none { c = arena[c].nextSibling }
            n = c
        }
    }

    private func scalarEnd(_ n: UInt32) -> UInt32 {
        let line = Int(arena[n].line)
        let r = records[line]
        guard r.valueKind == .literal || r.valueKind == .folded else { return r.valueEnd }
        var end = r.valueEnd
        var i = line + 1
        while i < records.count && records[i].kind == .blockContent {
            let c = records[i]
            if bytes[Int(c.contentStart)..<Int(c.contentEnd)].contains(where: { $0 != 0x20 }) { end = c.contentEnd }
            i += 1
        }
        return end
    }
}

// A value in a document: a mapping, a sequence or a scalar. A handle is the document plus a node index.
public struct YAMLNode {
    public enum Kind: Equatable {
        case mapping, sequence, string, integer, float, boolean, null
    }

    public let document: YAMLDocument
    let index: UInt32

    public var kind: Kind {
        switch document.arena[index].kind {
        case .mapping: return .mapping
        case .sequence: return .sequence
        case .scalar, .entry:
            switch document.types[Int(index)] {
            case .string: return .string
            case .integer: return .integer
            case .float: return .float
            case .boolean: return .boolean
            case .null: return .null
            }
        }
    }

    public var span: ByteSpan { document.span(index) }

    // 1-based line and byte column where the value starts.
    public var location: (line: Int, column: Int) { document.location(of: span.start) }

    // MARK: Scalars

    // Each accessor is nil unless the value has that type; an integer does not read as a float.
    public var string: String? {
        kind == .string ? String(decoding: document.scalarBytes(index), as: UTF8.self) : nil
    }

    public var integer: Int64? {
        guard kind == .integer else { return nil }
        let (start, end) = document.valueSpan(index)
        return document.bytes.withUnsafeBufferPointer { ScalarTyping.integerValue($0, start, end) }
    }

    public var float: Double? {
        guard kind == .float else { return nil }
        let (start, end) = document.valueSpan(index)
        return document.bytes.withUnsafeBufferPointer { ScalarTyping.floatValue($0, start, end) }
    }

    public var boolean: Bool? {
        guard kind == .boolean else { return nil }
        return document.bytes[document.valueSpan(index).start] == 0x74  // `t`
    }

    public var isNull: Bool { kind == .null }

    // MARK: Collections

    // The number of entries or items; 0 for a scalar.
    public var count: Int {
        guard document.arena[index].kind != .scalar else { return 0 }
        var n = 0
        var c = document.arena[index].firstChild
        while c != Node.none {
            n += 1
            c = document.arena[c].nextSibling
        }
        return n
    }

    // A sequence's items; empty for a mapping or scalar.
    public var items: YAMLItems {
        YAMLItems(document: document, first: document.arena[index].kind == .sequence
                  ? document.arena[index].firstChild : Node.none)
    }

    // A mapping's entries, in source order; empty for a sequence or scalar.
    public var entries: YAMLEntries {
        YAMLEntries(document: document, first: document.arena[index].kind == .mapping
                    ? document.arena[index].firstChild : Node.none)
    }

    // The value under `key`, matched against decoded keys exactly; nil when absent or not a mapping.
    public subscript(key: String) -> YAMLNode? {
        guard document.arena[index].kind == .mapping, let e = document.entry(of: index, key: key) else { return nil }
        return YAMLNode(document: document, index: document.arena[e].firstChild)
    }

    // The item at `position`, found by walking the sequence; nil when out of range or not a sequence.
    public subscript(position: Int) -> YAMLNode? {
        guard position >= 0 else { return nil }
        var k = 0
        for item in items {
            if k == position { return item }
            k += 1
        }
        return nil
    }
}

// A mapping entry: its key and value.
public struct YAMLEntry {
    public let document: YAMLDocument
    let index: UInt32

    // The decoded key.
    public var key: String { document.keyText(index) }

    // The key's spelling in the source, quotes included.
    public var keySpan: ByteSpan {
        let r = document.records[Int(document.arena[index].line)]
        return ByteSpan(start: r.keyStart, end: r.keyEnd)
    }

    public var value: YAMLNode { YAMLNode(document: document, index: document.arena[index].firstChild) }
}

public struct YAMLItems: Sequence {
    let document: YAMLDocument
    let first: UInt32

    public struct Iterator: IteratorProtocol {
        let document: YAMLDocument
        var current: UInt32

        public mutating func next() -> YAMLNode? {
            guard current != Node.none else { return nil }
            defer { current = document.arena[current].nextSibling }
            return YAMLNode(document: document, index: current)
        }
    }

    public func makeIterator() -> Iterator { Iterator(document: document, current: first) }
}

public struct YAMLEntries: Sequence {
    let document: YAMLDocument
    let first: UInt32

    public struct Iterator: IteratorProtocol {
        let document: YAMLDocument
        var current: UInt32

        public mutating func next() -> YAMLEntry? {
            guard current != Node.none else { return nil }
            defer { current = document.arena[current].nextSibling }
            return YAMLEntry(document: document, index: current)
        }
    }

    public func makeIterator() -> Iterator { Iterator(document: document, current: first) }
}
