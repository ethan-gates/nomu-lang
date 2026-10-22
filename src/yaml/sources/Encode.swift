// Encoding `Encodable` values as new documents (task 200, "API layers": Codable on top).
//
// The encoder builds a `YAMLValue` tree and writes it with the edit renderer (`Edit.swift`), so new files follow
// the same spelling rules as edits and are parsed before they are returned. Updating an existing file, with its
// comments, goes through `YAMLEdits`; `encodeValue` gives a value to hand it.

public struct YAMLEncoder {
    public var style: YAMLStyle
    // Orders every mapping's keys; a Swift dictionary otherwise encodes in its own unstable order.
    public var sortedKeys: Bool
    public var userInfo: [CodingUserInfoKey: Any]

    public init(style: YAMLStyle = YAMLStyle(), sortedKeys: Bool = false, userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.style = style
        self.sortedKeys = sortedKeys
        self.userInfo = userInfo
    }

    // `value` as a document. Throws `EncodingError` for a value the format cannot hold (an unsigned integer past
    // the signed 64-bit range), `YAMLErrors` for NaN.
    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        var edits = YAMLEdits(try YAMLDocument(parsing: "x\n"), style: style)
        edits.set(edits.document.root, to: try encodeValue(value))
        return try edits.apply().bytes
    }

    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    // `value` as a `YAMLValue`, for writing into an existing document with `YAMLEdits`.
    public func encodeValue<T: Encodable>(_ value: T) throws -> YAMLValue {
        let box = Box()
        try box.encode(value, [], userInfo)
        return box.value(sorted: sortedKeys)
    }
}

// A value under construction: containers hand out boxes their children fill in later.
private final class Box {
    enum Content {
        case empty
        case scalar(YAMLValue)
        case mapping(keys: [String], boxes: [String: Box])
        case sequence([Box])
    }

    var content = Content.empty

    func value(sorted: Bool) -> YAMLValue {
        switch content {
        case .empty: return .null
        case .scalar(let v): return v
        case .mapping(let keys, let boxes):
            return .mapping((sorted ? keys.sorted() : keys).map { (key: $0, value: boxes[$0]!.value(sorted: sorted)) })
        case .sequence(let items): return .sequence(items.map { $0.value(sorted: sorted) })
        }
    }

    func encode<T: Encodable>(_ value: T, _ path: [any CodingKey], _ userInfo: [CodingUserInfoKey: Any]) throws {
        switch value {
        case let v as String: content = .scalar(.string(v))
        case let v as Bool: content = .scalar(.boolean(v))
        case let v as Double: content = .scalar(.float(v))
        case let v as Float: content = .scalar(.float(Double(v)))
        case let v as any BinaryInteger:
            // Every integer width lands here: their own `encode(to:)` would come back through this box.
            guard let i = Int64(exactly: v) else {
                throw EncodingError.invalidValue(v, .init(codingPath: path,
                                                          debugDescription: "past the signed 64-bit integer range"))
            }
            content = .scalar(.integer(i))
        default:
            try value.encode(to: NodeEncoder(self, path, userInfo))
        }
    }

    func key(_ key: String) -> Box {
        var keys: [String] = [], boxes: [String: Box] = [:]
        if case .mapping(let k, let b) = content { (keys, boxes) = (k, b) }
        if let existing = boxes[key] { return existing }
        let box = Box()
        keys.append(key)
        boxes[key] = box
        content = .mapping(keys: keys, boxes: boxes)
        return box
    }

    func item() -> Box {
        var items: [Box] = []
        if case .sequence(let i) = content { items = i }
        let box = Box()
        items.append(box)
        content = .sequence(items)
        return box
    }

    func startMapping() { if case .mapping = content {} else { content = .mapping(keys: [], boxes: [:]) } }
    func startSequence() { if case .sequence = content {} else { content = .sequence([]) } }
}

private struct NodeEncoder: Encoder {
    let box: Box
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(_ box: Box, _ path: [any CodingKey], _ userInfo: [CodingUserInfoKey: Any]) {
        self.box = box
        codingPath = path
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        box.startMapping()
        return KeyedEncodingContainer(KeyedContainer<Key>(box, codingPath, userInfo))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        box.startSequence()
        return UnkeyedContainer(box, codingPath, userInfo)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { SingleValueContainer(box, codingPath, userInfo) }
}

private struct EncodingIndex: CodingKey {
    let intValue: Int?
    var stringValue: String { "\(intValue!)" }
    init(_ i: Int) { intValue = i }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: Box
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(_ box: Box, _ path: [any CodingKey], _ userInfo: [CodingUserInfoKey: Any]) {
        self.box = box
        codingPath = path
        self.userInfo = userInfo
    }

    mutating func encodeNil(forKey key: Key) throws { box.key(key.stringValue).content = .scalar(.null) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try box.key(key.stringValue).encode(value, codingPath + [key], userInfo)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        NodeEncoder(box.key(key.stringValue), codingPath + [key], userInfo).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        NodeEncoder(box.key(key.stringValue), codingPath + [key], userInfo).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { NodeEncoder(box.key("super"), codingPath, userInfo) }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        NodeEncoder(box.key(key.stringValue), codingPath + [key], userInfo)
    }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let box: Box
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    private(set) var count = 0

    init(_ box: Box, _ path: [any CodingKey], _ userInfo: [CodingUserInfoKey: Any]) {
        self.box = box
        codingPath = path
        self.userInfo = userInfo
    }

    private mutating func next() -> (Box, [any CodingKey]) {
        defer { count += 1 }
        return (box.item(), codingPath + [EncodingIndex(count)])
    }

    mutating func encodeNil() throws { next().0.content = .scalar(.null) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let (item, path) = next()
        try item.encode(value, path, userInfo)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey>
    {
        let (item, path) = next()
        return NodeEncoder(item, path, userInfo).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let (item, path) = next()
        return NodeEncoder(item, path, userInfo).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let (item, path) = next()
        return NodeEncoder(item, path, userInfo)
    }
}

private struct SingleValueContainer: SingleValueEncodingContainer {
    let box: Box
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(_ box: Box, _ path: [any CodingKey], _ userInfo: [CodingUserInfoKey: Any]) {
        self.box = box
        codingPath = path
        self.userInfo = userInfo
    }

    mutating func encodeNil() throws { box.content = .scalar(.null) }
    mutating func encode<T: Encodable>(_ value: T) throws { try box.encode(value, codingPath, userInfo) }
}
