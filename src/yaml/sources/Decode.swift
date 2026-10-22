// Decoding a document into `Decodable` types (task 200, "API layers": Codable on top).
//
// The decoder reads the parsed document in place: containers are node handles, strings are decoded when a
// field reads them, and numbers are parsed from spellings the parser checked. Types are the Core types a YAML
// 1.2 parser resolves, so a decoded value means what the document means to any such parser: a quoted "42"
// given to an `Int` is a type mismatch, and so is `42` given to a `Double` (write `42.0`).
//
// Unknown keys are rejected by default. Each entry a container reads is marked; when decoding ends, every
// unmarked entry of a mapping that was decoded as a keyed container is an `unknownKey` error, with a
// suggestion drawn from the keys the container asked for and did not find. Errors carry source spans; the span
// of any decoded value is found afterwards from its coding path (`YAMLDocument.node(at:)`).

public struct YAMLDecoder {
    public enum UnknownKeys {
        case reject
        case ignore
    }

    public var unknownKeys: UnknownKeys
    public var userInfo: [CodingUserInfoKey: Any]

    public init(unknownKeys: UnknownKeys = .reject, userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.unknownKeys = unknownKeys
        self.userInfo = userInfo
    }

    // Decodes `type` from `document`. YAML problems are thrown as `YAMLErrors`; errors a type's own
    // `init(from:)` throws pass through.
    public func decode<T: Decodable>(_ type: T.Type, from document: YAMLDocument) throws -> T {
        let state = DecodingState(document, userInfo)
        let value = try state.decode(T.self, document.arena.root, [])
        if unknownKeys == .reject { try state.checkUnknownKeys() }
        return value
    }

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try decode(type, from: try YAMLDocument(parsing: bytes))
    }

    public func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decode(type, from: Array(text.utf8))
    }
}

extension YAMLDocument {
    // The value at `codingPath` (keys by string, sequence items by index), such as a decoding error's or a
    // decoded field's, for pointing at its source.
    public func node(at codingPath: [any CodingKey]) -> YAMLNode? {
        var n = root
        for key in codingPath {
            if n.kind == .sequence, let i = key.intValue {
                guard let item = n[i] else { return nil }
                n = item
            } else {
                guard let value = n[key.stringValue] else { return nil }
                n = value
            }
        }
        return n
    }
}

// MARK: State

// Shared by every container of one decode: the document, which entries were read, which mappings were decoded
// as keyed containers, and each mapping's lookup cursor. The per-node tables are raw memory, so marking an
// entry costs no reference counting or exclusivity check. Coding paths are built only for errors and nested
// decoders: a leaf takes its path as an autoclosure.
private final class DecodingState {
    let doc: YAMLDocument
    let userInfo: [CodingUserInfoKey: Any]
    private let words: Int
    private let read: UnsafeMutablePointer<UInt64>        // a bit per node: an entry some container read
    private let keyedBits: UnsafeMutablePointer<UInt64>   // a bit per node: a mapping opened as a keyed container
    private var keyed: [UInt32] = []
    // The entry each mapping's last lookup found; lookups start after it, since fields are usually decoded in
    // the order the file lists them.
    private let cursors: UnsafeMutablePointer<UInt32>
    // Keys a mapping's containers asked for and did not find, for suggesting a fix to an unknown key.
    private var missed: [UInt32: [String]] = [:]

    init(_ doc: YAMLDocument, _ userInfo: [CodingUserInfoKey: Any]) {
        self.doc = doc
        self.userInfo = userInfo
        let nodes = doc.arena.nodes.count
        words = (nodes + 63) / 64
        read = .allocate(capacity: words)
        read.initialize(repeating: 0, count: words)
        keyedBits = .allocate(capacity: words)
        keyedBits.initialize(repeating: 0, count: words)
        cursors = .allocate(capacity: max(nodes, 1))
        cursors.initialize(repeating: Node.none, count: max(nodes, 1))
    }

    deinit {
        read.deallocate()
        keyedBits.deallocate()
        cursors.deallocate()
    }

    @inline(__always) func markRead(_ e: UInt32) { read[Int(e >> 6)] |= 1 << UInt64(e & 63) }
    @inline(__always) private func isRead(_ e: UInt32) -> Bool { read[Int(e >> 6)] >> UInt64(e & 63) & 1 != 0 }

    func opened(_ m: UInt32) {
        let bit: UInt64 = 1 << UInt64(m & 63)
        if keyedBits[Int(m >> 6)] & bit == 0 {
            keyedBits[Int(m >> 6)] |= bit
            keyed.append(m)
        }
    }

    func missing(_ key: String, in m: UInt32) { missed[m, default: []].append(key) }

    func checkUnknownKeys() throws {
        var errors = YAMLErrors()
        for m in keyed.sorted() {
            var e = doc.arena[m].firstChild
            while e != Node.none {
                if !isRead(e) {
                    let entry = YAMLEntry(document: doc, index: e)
                    let fix = DecodingState.closest(entry.key, missed[m] ?? []).map { "did you mean `\($0)`?" }
                    errors.report(YAMLError(.unknownKey, entry.keySpan, "unknown key `\(entry.key)`", fix: fix))
                }
                e = doc.arena[e].nextSibling
            }
        }
        if !errors.isEmpty { throw errors }
    }

    // The candidate nearest `key` by edit distance, when it is near enough to be a likely typo.
    private static func closest(_ key: String, _ candidates: [String]) -> String? {
        let a = Array(key.lowercased().unicodeScalars)
        var best: (String, Int)?
        for c in candidates {
            let b = Array(c.lowercased().unicodeScalars)
            guard !a.isEmpty && !b.isEmpty else { continue }
            var row = Array(0...b.count)
            for i in 1...a.count {
                var diagonal = row[0]
                row[0] = i
                for j in 1...b.count {
                    let above = row[j]
                    row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                    diagonal = above
                }
            }
            let distance = row[b.count]
            if distance <= max(2, a.count / 3) && distance < (best?.1 ?? .max) { best = (c, distance) }
        }
        return best?.0
    }

    // MARK: Values

    func decode<T: Decodable>(_ type: T.Type, _ n: UInt32, _ path: @autoclosure () -> [any CodingKey]) throws -> T {
        // The common leaf types skip building a decoder and a coding path.
        if T.self == String.self { return try string(n, path()) as! T }
        if T.self == Int.self { return try integer(Int.self, n, path()) as! T }
        if T.self == Bool.self { return try bool(n, path()) as! T }
        if T.self == Double.self { return try double(n, path()) as! T }
        return try T(from: NodeDecoder(self, n, path()))
    }

    private func kind(_ n: UInt32) -> String {
        switch doc.arena[n].kind {
        case .mapping: return "a mapping"
        case .sequence: return "a sequence"
        default: return ScalarTyping.name(doc.types[Int(n)])
        }
    }

    // A coding path as written in messages: `gc.tags[2]`.
    static func describe(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "the document" }
        var text = ""
        for key in path {
            if key is IndexKey {
                text += "[\(key.intValue!)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return "`" + text + "`"
    }

    @inline(never)
    func mismatch(_ n: UInt32, _ path: [any CodingKey], expected: String, fix: String? = nil) -> YAMLErrors {
        var errors = YAMLErrors()
        errors.report(YAMLError(.typeMismatch, doc.span(n),
                                "expected \(expected) for \(DecodingState.describe(path)), found \(kind(n))", fix: fix))
        return errors
    }

    @inline(never)
    func error(_ code: YAMLError.Code, _ span: ByteSpan, _ message: String) -> YAMLErrors {
        var errors = YAMLErrors()
        errors.report(YAMLError(code, span, message))
        return errors
    }

    @inline(__always)
    private func type(_ n: UInt32) -> ScalarType? {
        doc.arena[n].kind == .scalar ? doc.types[Int(n)] : nil
    }

    func isNull(_ n: UInt32) -> Bool { type(n) == .null }

    // A plain scalar, or a quoted one without escapes, is its source bytes, so the string is built from them
    // directly; one of up to 15 bytes needs no allocation.
    func string(_ n: UInt32, _ path: @autoclosure () -> [any CodingKey]) throws -> String {
        guard type(n) == .string else {
            throw mismatch(n, path(), expected: "a string", fix: type(n) != nil ? "quote it for a string" : nil)
        }
        let r = doc.records[Int(doc.arena[n].line)]
        let start = Int(r.valueStart), end = Int(r.valueEnd)
        return doc.bytes.withUnsafeBufferPointer { b in
            switch r.valueKind {
            case .plain:
                return String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
            case .singleQuoted, .doubleQuoted:
                let special: UInt8 = r.valueKind == .singleQuoted ? 0x27 : 0x5C
                let body = UnsafeBufferPointer(rebasing: b[start + 1..<end - 1])
                if !body.contains(special) { return String(decoding: body, as: UTF8.self) }
                return String(decoding: ScalarText.value(b, doc.records, line: Int(doc.arena[n].line)), as: UTF8.self)
            default:
                return String(decoding: ScalarText.value(b, doc.records, line: Int(doc.arena[n].line)), as: UTF8.self)
            }
        }
    }

    func bool(_ n: UInt32, _ path: @autoclosure () -> [any CodingKey]) throws -> Bool {
        guard type(n) == .boolean else { throw mismatch(n, path(), expected: "a boolean (`true` or `false`)") }
        return doc.bytes[doc.valueSpan(n).start] == 0x74
    }

    func integer<I: FixedWidthInteger>(_ type: I.Type, _ n: UInt32, _ path: @autoclosure () -> [any CodingKey]) throws -> I {
        guard self.type(n) == .integer else { throw mismatch(n, path(), expected: "an integer") }
        let (start, end) = doc.valueSpan(n)
        let v = doc.bytes.withUnsafeBufferPointer { ScalarTyping.integerValue($0, start, end)! }
        guard let i = I(exactly: v) else {
            throw error(.typeMismatch, doc.span(n), "\(v) is out of range for \(DecodingState.describe(path())) (\(I.self))")
        }
        return i
    }

    func double(_ n: UInt32, _ path: @autoclosure () -> [any CodingKey]) throws -> Double {
        let (start, end) = doc.valueSpan(n)
        guard type(n) == .float else {
            let fix = type(n) == .integer
                ? "write it as a float: \(String(decoding: doc.bytes[start..<end], as: UTF8.self)).0" : nil
            throw mismatch(n, path(), expected: "a float", fix: fix)
        }
        return doc.bytes.withUnsafeBufferPointer { ScalarTyping.floatValue($0, start, end) }
    }

    // MARK: Keys

    // The entry of mapping `m` whose decoded key is `key`, searched from the entry after the mapping's cursor.
    func entry(_ m: UInt32, _ key: String) -> UInt32? {
        var key = key
        return key.withUTF8 { q in
            doc.bytes.withUnsafeBufferPointer { b in
                let cursor = cursors[Int(m)]
                let start = cursor == Node.none ? doc.arena[m].firstChild : doc.arena[cursor].nextSibling
                var e = start
                while e != Node.none {
                    if doc.keyMatches(b, e, q) { cursors[Int(m)] = e; return e }
                    e = doc.arena[e].nextSibling
                }
                e = doc.arena[m].firstChild
                while e != start {
                    if doc.keyMatches(b, e, q) { cursors[Int(m)] = e; return e }
                    e = doc.arena[e].nextSibling
                }
                return nil
            }
        }
    }
}

// MARK: Decoder

private struct NodeDecoder: Decoder {
    let state: DecodingState
    let node: UInt32
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { state.userInfo }

    init(_ state: DecodingState, _ node: UInt32, _ path: [any CodingKey]) {
        self.state = state
        self.node = node
        codingPath = path
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard state.doc.arena[node].kind == .mapping else { throw state.mismatch(node, codingPath, expected: "a mapping") }
        state.opened(node)
        return KeyedDecodingContainer(KeyedContainer<Key>(state, node, codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard state.doc.arena[node].kind == .sequence else { throw state.mismatch(node, codingPath, expected: "a sequence") }
        return UnkeyedContainer(state, node, codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueContainer(state, node, codingPath)
    }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "\(intValue!)" }
    init(_ i: Int) { intValue = i }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: DecodingState
    let mapping: UInt32
    let codingPath: [any CodingKey]

    init(_ state: DecodingState, _ mapping: UInt32, _ path: [any CodingKey]) {
        self.state = state
        self.mapping = mapping
        codingPath = path
    }

    var allKeys: [Key] {
        state.doc.arena.children(of: mapping).compactMap { Key(stringValue: state.doc.keyText($0)) }
    }

    // The value under `key`, marking its entry read; throws `missingKey` when absent.
    private func value(_ key: Key) throws -> UInt32 {
        guard let e = state.entry(mapping, key.stringValue) else {
            state.missing(key.stringValue, in: mapping)
            let owner = state.doc.span(mapping)
            throw state.error(.missingKey, ByteSpan(start: owner.start, end: owner.start),
                              "missing key `\(key.stringValue)` in \(DecodingState.describe(codingPath))")
        }
        state.markRead(e)
        return state.doc.arena[e].firstChild
    }

    // The value under `key`, marking its entry read; nil when absent or null.
    private func optionalValue(_ key: Key) -> UInt32? {
        guard let e = state.entry(mapping, key.stringValue) else {
            state.missing(key.stringValue, in: mapping)
            return nil
        }
        state.markRead(e)
        let v = state.doc.arena[e].firstChild
        return state.isNull(v) ? nil : v
    }

    func contains(_ key: Key) -> Bool { state.entry(mapping, key.stringValue) != nil }

    func decodeNil(forKey key: Key) throws -> Bool { state.isNull(try value(key)) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try state.decode(T.self, try value(key), codingPath + [key])
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let v = optionalValue(key) else { return nil }
        return try state.decode(T.self, v, codingPath + [key])
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try state.string(try value(key), codingPath + [key])
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try state.bool(try value(key), codingPath + [key]) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try state.double(try value(key), codingPath + [key])
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        Float(try state.double(try value(key), codingPath + [key]))
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try int(key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try int(key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try int(key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try int(key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try int(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try int(key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try int(key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try int(key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try int(key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try int(key) }

    private func int<I: FixedWidthInteger>(_ key: Key) throws -> I {
        try state.integer(I.self, try value(key), codingPath + [key])
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        try optionalValue(key).map { try state.string($0, codingPath + [key]) }
    }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        try optionalValue(key).map { try state.bool($0, codingPath + [key]) }
    }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        try optionalValue(key).map { try state.double($0, codingPath + [key]) }
    }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        try optionalValue(key).map { try state.integer(Int.self, $0, codingPath + [key]) }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try NodeDecoder(state, try value(key), codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try NodeDecoder(state, try value(key), codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        try superDecoder(forKey: Key(stringValue: "super")!)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        NodeDecoder(state, try value(key), codingPath + [key])
    }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let state: DecodingState
    let sequence: UInt32
    let codingPath: [any CodingKey]
    private var next: UInt32
    private(set) var currentIndex = 0
    let count: Int?

    init(_ state: DecodingState, _ sequence: UInt32, _ path: [any CodingKey]) {
        self.state = state
        self.sequence = sequence
        codingPath = path
        next = state.doc.arena[sequence].firstChild
        var n = 0
        var c = next
        while c != Node.none {
            n += 1
            c = state.doc.arena[c].nextSibling
        }
        count = n
    }

    var isAtEnd: Bool { next == Node.none }

    private mutating func advance() throws -> (UInt32, [any CodingKey]) {
        guard next != Node.none else {
            let span = state.doc.span(sequence)
            throw state.error(.typeMismatch, ByteSpan(start: span.end, end: span.end),
                              "\(DecodingState.describe(codingPath)) has only \(currentIndex) items")
        }
        let item = next
        let path = codingPath + [IndexKey(currentIndex)]
        next = state.doc.arena[item].nextSibling
        currentIndex += 1
        return (item, path)
    }

    mutating func decodeNil() throws -> Bool {
        guard next != Node.none, state.isNull(next) else { return false }
        _ = try advance()
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (item, path) = try advance()
        return try state.decode(T.self, item, path)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let (item, path) = try advance()
        return try state.string(item, path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        let (item, path) = try advance()
        return try NodeDecoder(state, item, path).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let (item, path) = try advance()
        return try NodeDecoder(state, item, path).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let (item, path) = try advance()
        return NodeDecoder(state, item, path)
    }
}

private struct SingleValueContainer: SingleValueDecodingContainer {
    let state: DecodingState
    let node: UInt32
    let codingPath: [any CodingKey]

    init(_ state: DecodingState, _ node: UInt32, _ path: [any CodingKey]) {
        self.state = state
        self.node = node
        codingPath = path
    }

    func decodeNil() -> Bool { state.isNull(node) }
    func decode(_ type: Bool.Type) throws -> Bool { try state.bool(node, codingPath) }
    func decode(_ type: String.Type) throws -> String { try state.string(node, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try state.double(node, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { Float(try state.double(node, codingPath)) }
    func decode(_ type: Int.Type) throws -> Int { try state.integer(Int.self, node, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try state.integer(Int8.self, node, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try state.integer(Int16.self, node, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try state.integer(Int32.self, node, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try state.integer(Int64.self, node, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try state.integer(UInt.self, node, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try state.integer(UInt8.self, node, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try state.integer(UInt16.self, node, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try state.integer(UInt32.self, node, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try state.integer(UInt64.self, node, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try state.decode(T.self, node, codingPath) }
}
