// Edits to a document (task 200, "Document API"; spec §25.2).
//
// An edit is a byte range of the source and its replacement. `YAMLEdits` collects operations on values
// (set, insert, remove, append, sort), turns each into replacements of the bytes it touches, and `apply` copies
// the source once with every replacement in place and parses the result, which returns a new document; handles
// into the old one stay with the old one.
//
// Everything outside an operation's range is kept byte for byte. Comments on their own lines outside an
// edited value stay where they are; comments inside a value that is removed or replaced go with it; a trailing
// comment stays on its line, so it is removed with its line and moves with it when keys are sorted.
//
// New scalars are written plain when the plain spelling parses back as the same string, else single-quoted,
// else double-quoted. Multi-line text keeps the style it was parsed in; new multi-line text is double-quoted
// until it has two line breaks or its double-quoted spelling passes 40 bytes, then written as a `|` block.
// Every spelling but the double-quoted one is checked by parsing a small document holding it, so a spelling
// is used only when it reads back exactly.

// A value to write.
public enum YAMLValue {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case null
    case sequence([YAMLValue])
    case mapping([(key: String, value: YAMLValue)])
}

extension YAMLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: YAMLValue...) { self = .sequence(elements) }
    public init(dictionaryLiteral elements: (String, YAMLValue)...) {
        self = .mapping(elements.map { (key: $0.0, value: $0.1) })
    }
    public init(nilLiteral: ()) { self = .null }
}

// How new scalars are written.
public struct YAMLStyle {
    public enum Quoting {
        case plainWhenPossible  // plain, else single-quoted, else double-quoted
        case doubleQuoted       // every string double-quoted
    }

    public enum MultiLine {
        case automatic          // keep the parsed style; new text by its length (see the file comment)
        case block              // a `|` block whenever the text allows one
        case doubleQuoted       // always double-quoted, with `\n` escapes
    }

    public var quoting: Quoting
    public var multiLine: MultiLine

    public init(quoting: Quoting = .plainWhenPossible, multiLine: MultiLine = .automatic) {
        self.quoting = quoting
        self.multiLine = multiLine
    }
}

// A batch of edits to one document. Operations must not overlap: a value edited, removed or sorted is not
// edited again in the same batch (apply one batch, then edit the new document).
public struct YAMLEdits {
    public let document: YAMLDocument
    public var style: YAMLStyle
    private var ops: [Op] = []

    fileprivate enum Op {
        case set(node: UInt32, value: YAMLValue)
        case remove(child: UInt32)                      // an entry or a sequence item
        case append(collection: UInt32, key: String?, value: YAMLValue)
        case sort(mapping: UInt32, by: (String, String) -> Bool)
    }

    public init(_ document: YAMLDocument, style: YAMLStyle = YAMLStyle()) {
        self.document = document
        self.style = style
    }

    // Replaces the value `node`.
    public mutating func set(_ node: YAMLNode, to value: YAMLValue) {
        precondition(node.document === document, "the node belongs to another document")
        ops.append(.set(node: node.index, value: value))
    }

    // Sets `key` in `mapping` to `value`: replaces the value when the key is present, else appends an entry.
    public mutating func set(_ key: String, to value: YAMLValue, in mapping: YAMLNode) {
        precondition(mapping.document === document && mapping.kind == .mapping, "not a mapping of this document")
        if let e = document.entry(of: mapping.index, key: key) {
            ops.append(.set(node: document.arena[e].firstChild, value: value))
        } else {
            ops.append(.append(collection: mapping.index, key: key, value: value))
        }
    }

    // Removes the entry `key` from `mapping`; false when it has none.
    @discardableResult
    public mutating func remove(_ key: String, from mapping: YAMLNode) -> Bool {
        precondition(mapping.document === document && mapping.kind == .mapping, "not a mapping of this document")
        guard let e = document.entry(of: mapping.index, key: key) else { return false }
        ops.append(.remove(child: e))
        return true
    }

    // Removes the item at `index` from `sequence`.
    public mutating func remove(at index: Int, from sequence: YAMLNode) {
        precondition(sequence.document === document && sequence.kind == .sequence, "not a sequence of this document")
        let items = document.arena.children(of: sequence.index)
        precondition(items.indices.contains(index), "index \(index) is out of range")
        ops.append(.remove(child: items[index]))
    }

    // Appends `value` to `sequence`.
    public mutating func append(_ value: YAMLValue, to sequence: YAMLNode) {
        precondition(sequence.document === document && sequence.kind == .sequence, "not a sequence of this document")
        ops.append(.append(collection: sequence.index, key: nil, value: value))
    }

    // Orders the entries of `mapping` by their decoded keys. Each entry moves with its value, its nested
    // lines and its trailing comments; comment and blank lines between entries stay in place.
    public mutating func sortKeys(of mapping: YAMLNode, by areInIncreasingOrder: @escaping (String, String) -> Bool = (<)) {
        precondition(mapping.document === document && mapping.kind == .mapping, "not a mapping of this document")
        ops.append(.sort(mapping: mapping.index, by: areInIncreasingOrder))
    }

    // The edited document. Throws when a value cannot be written (NaN), or, which would be a bug, when the
    // result fails to parse.
    public func apply() throws(YAMLErrors) -> YAMLDocument {
        var plan = EditPlan(document, style)
        let arena = document.arena
        var sets: [(UInt32, YAMLValue)] = []
        var removed: [UInt32: [UInt32]] = [:]           // collection → removed children
        var appended: [UInt32: [(String?, YAMLValue)]] = [:]
        var sorts: [(UInt32, (String, String) -> Bool)] = []
        for op in ops {
            switch op {
            case .set(let n, let v): sets.append((n, v))
            case .remove(let c): removed[arena[c].parent, default: []].append(c)
            case .append(let c, let k, let v): appended[c, default: []].append((k, v))
            case .sort(let m, let by): sorts.append((m, by))
            }
        }
        // A collection left with no children, or `[]`/`{}` with new ones, is written whole.
        for (c, kids) in removed where Set(kids).count == arena.children(of: c).count {
            sets.append((c, EditPlan.collection(arena[c].kind, appended[c] ?? [])))
            removed[c] = nil
            appended[c] = nil
        }
        for (c, items) in appended where arena[c].firstChild == Node.none {
            sets.append((c, EditPlan.collection(arena[c].kind, items)))
            appended[c] = nil
        }

        for (n, v) in sets { plan.replaceValue(n, v) }
        for (c, kids) in removed { plan.remove(Set(kids), from: c) }
        for (c, items) in appended { plan.append(items, to: c) }
        for (m, by) in sorts { plan.sort(m, by: by) }
        guard plan.errors.isEmpty else { throw plan.errors }
        return try document.replacing(plan.replacements)
    }
}

extension YAMLDocument {
    // A replacement of the source bytes in `span` by `text`; an empty span inserts.
    public struct Replacement {
        public let span: ByteSpan
        public let text: [UInt8]

        public init(_ span: ByteSpan, _ text: [UInt8]) {
            self.span = span
            self.text = text
        }
    }

    // The document with every replacement applied to its source, parsed again. Replacements must not overlap;
    // insertions at one offset keep their order. An edit reaching the end of a file without a final line break
    // adds one, so a block scalar written there keeps its last line break.
    public func replacing(_ replacements: [Replacement]) throws(YAMLErrors) -> YAMLDocument {
        let sorted = replacements.enumerated().sorted {
            ($0.element.span.start, $0.element.span.end, $0.offset) < ($1.element.span.start, $1.element.span.end, $1.offset)
        }.map(\.element)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + sorted.reduce(0) { $0 + $1.text.count })
        var at = 0
        for r in sorted {
            let start = Int(r.span.start), end = Int(r.span.end)
            precondition(start >= at && end <= bytes.count, "edits overlap at byte \(start)")
            out.append(contentsOf: bytes[at..<start])
            out.append(contentsOf: r.text)
            at = end
        }
        out.append(contentsOf: bytes[at...])
        if let last = sorted.last, Int(last.span.end) == bytes.count, out.last != 0x0A {
            out.append(contentsOf: lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A])
        }
        return try YAMLDocument(parsing: out)
    }
}

// MARK: Planning

// Turns operations into byte replacements against one document.
private struct EditPlan {
    let d: YAMLDocument
    let style: YAMLStyle
    let newline: [UInt8]
    private(set) var replacements: [YAMLDocument.Replacement] = []
    private(set) var errors = YAMLErrors()

    init(_ d: YAMLDocument, _ style: YAMLStyle) {
        self.d = d
        self.style = style
        newline = d.lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A]
    }

    static func collection(_ kind: NodeKind, _ items: [(String?, YAMLValue)]) -> YAMLValue {
        kind == .mapping ? .mapping(items.map { (key: $0.0!, value: $0.1) }) : .sequence(items.map(\.1))
    }

    private mutating func replace(_ start: Int, _ end: Int, _ text: [UInt8]) {
        replacements.append(YAMLDocument.Replacement(ByteSpan(start: UInt32(start), end: UInt32(end)), text))
    }

    // MARK: Source geometry

    private func node(_ n: UInt32) -> Node { d.arena[n] }
    private func record(_ line: Int) -> LineRecord { d.records[line] }
    private func lineEnd(_ line: Int) -> Int { Int(record(line).contentEnd) }
    private func lineStart(_ line: Int) -> Int { Int(record(line).contentStart) }
    private func nextLineStart(_ line: Int) -> Int {
        line + 1 < d.records.count ? Int(d.lines.lineStarts[line + 1]) : d.bytes.count
    }

    // The last line holding part of node `n`: its last value's line, or a block scalar's last non-blank line;
    // with keep chomping (`|+`) the empty lines after it are content too.
    private func lastLine(of n: UInt32) -> Int {
        var n = n
        while node(n).firstChild != Node.none {
            var c = node(n).firstChild
            while node(c).nextSibling != Node.none { c = node(c).nextSibling }
            n = c
        }
        var line = Int(node(n).line)
        let r = record(line)
        if node(n).kind == .scalar && (r.valueKind == .literal || r.valueKind == .folded) {
            var i = line + 1
            while i < d.records.count && record(i).kind == .blockContent {
                if r.chomping == .keep || d.bytes[lineStart(i)..<lineEnd(i)].contains(where: { $0 != 0x20 && $0 != 0x09 }) {
                    line = i
                }
                i += 1
            }
        }
        return line
    }

    private func keyColumn(_ mapping: UInt32) -> Int {
        let r = record(Int(node(mapping).line))
        return Int(r.keyStart - r.contentStart)
    }

    private func dashColumn(_ sequence: UInt32) -> Int { Int(record(Int(node(sequence).line)).level) * 2 }

    // The line holding the key or dash that owns value `v`; nil for the root.
    private func ownerLine(_ v: UInt32) -> Int? {
        let parent = node(v).parent
        guard parent != Node.none else { return nil }
        if node(parent).kind == .entry { return Int(node(parent).line) }
        let line = Int(node(v).line)
        let r = record(line)
        if r.hasDash && Int(r.level) * 2 == dashColumn(parent) { return line }
        var i = line - 1                                  // a collection under a bare dash: the dash's line
        while record(i).kind != .node { i -= 1 }
        return i
    }

    // The column of the key or dash owning `v`.
    private func ownerColumn(_ v: UInt32) -> Int {
        let parent = node(v).parent
        if node(parent).kind == .entry {
            let r = record(Int(node(parent).line))
            return Int(r.keyStart - r.contentStart)
        }
        return dashColumn(parent)
    }

    private func isNested(_ v: UInt32) -> Bool { node(v).kind != .scalar && node(v).firstChild != Node.none }

    // `- key: value`: a mapping item whose first entry shares its dash's line.
    private func startsOnDashLine(_ v: UInt32) -> Bool {
        node(v).kind == .mapping && isNested(v) && Int(node(v).line) == ownerLine(v)
    }

    // MARK: Operations

    // Replaces value `v` with `value`.
    mutating func replaceValue(_ v: UInt32, _ value: YAMLValue) {
        let n = node(v)
        let r = record(Int(n.line))
        let previous: ValueKind? = n.kind == .scalar ? r.valueKind : nil
        guard let owner = ownerLine(v) else { return replaceRoot(v, value, previous) }
        let column = ownerColumn(v)
        let item = node(n.parent).kind == .sequence
        let (inline, following) = attach(value, column, item: item, previous: previous)
        let tail = following.isEmpty ? [] : newline + join(following)
        let ownerRecord = record(owner)

        if isNested(v) && startsOnDashLine(v) {
            // `- k: v ...` becomes `- <value>`; a nested sequence goes on the following lines.
            let first = Int(record(Int(node(n.firstChild).line)).keyStart)
            let end = lineEnd(lastLine(of: v))
            if let inline {
                replace(first, end, inline + tail)
            } else {
                replace(first - 1, end, tail)                    // drop the space after the dash
            }
            return
        }
        if isNested(v) {
            // The value is on the lines after its key or dash; it goes back onto that line when it fits there.
            let region = (lineEnd(owner), lineEnd(lastLine(of: v)))
            if let inline {
                if ownerRecord.hasComment {
                    replace(markerEnd(owner) + 2, markerEnd(owner) + 2, inline + [0x20])
                    replace(region.0, region.1, tail)
                } else {
                    replace(region.0, region.1, [0x20] + inline + tail)
                }
            } else {
                replace(region.0, region.1, tail)
            }
            return
        }
        // The value is on its owner's line: a scalar, `[]`, `{}`, or a block scalar's header.
        let span = (Int(r.valueStart), Int(r.valueEnd))
        let content: (Int, Int)? = lastLine(of: v) > owner ? (lineEnd(owner), lineEnd(lastLine(of: v))) : nil
        if let inline {
            replace(span.0, span.1, inline)
        } else if ownerRecord.hasComment {
            replace(span.0, Int(ownerRecord.commentStart), [])
        } else {
            replace(span.0 - 1, span.1, [])                     // with the space before it
        }
        if let content {
            replace(content.0, content.1, tail)
        } else if !tail.isEmpty {
            replace(lineEnd(owner), lineEnd(owner), tail)
        }
    }

    // The offset of the owner line's colon or dash; a value goes after it and one space.
    private func markerEnd(_ owner: Int) -> Int {
        let r = record(owner)
        return r.keyKind != .none ? Int(r.keyEnd) : lineStart(owner) + Int(r.level) * 2
    }

    private mutating func replaceRoot(_ v: UInt32, _ value: YAMLValue, _ previous: ValueKind?) {
        let n = node(v)
        let r = record(Int(n.line))
        var lines: [[UInt8]]
        switch value {
        case .mapping(let entries) where !entries.isEmpty: lines = renderEntries(entries, 0)
        case .sequence(let items) where !items.isEmpty: lines = renderItems(items, 0)
        default:
            let (inline, following) = attach(value, 0, item: false, previous: previous)
            lines = [inline!] + following
        }
        if isNested(v) {
            let start = n.kind == .mapping ? Int(r.keyStart) : lineStart(Int(n.line)) + Int(r.level) * 2
            replace(start, lineEnd(lastLine(of: v)), join(lines))
            return
        }
        replace(Int(r.valueStart), Int(r.valueEnd), join(lines))
        let last = lastLine(of: v)
        if last > Int(n.line) { replace(lineEnd(Int(n.line)), lineEnd(last), []) }
    }

    // Removes `kids`, entries or items of `collection`, with their lines; some children remain.
    mutating func remove(_ kids: Set<UInt32>, from collection: UInt32) {
        let children = d.arena.children(of: collection)
        var first = 0
        if node(collection).kind == .mapping && startsOnDashLine(collection) {
            // Removed entries at the start of `- k: v` give the dash line to the first one kept.
            while kids.contains(children[first]) { first += 1 }
            if first > 0 {
                let start = Int(record(Int(node(children[0]).line)).keyStart)
                replace(start, Int(record(Int(node(children[first]).line)).keyStart), [])
            }
        }
        for child in children[first...] where kids.contains(child) {
            let line = node(child).kind == .entry ? Int(node(child).line) : ownerLine(child)!
            replace(lineStart(line), nextLineStart(lastLine(of: child)), [])
        }
    }

    // Appends entries or items after the last line of `collection`, which has children.
    mutating func append(_ items: [(String?, YAMLValue)], to collection: UInt32) {
        let lines = node(collection).kind == .mapping
            ? renderEntries(items.map { (key: $0.0!, value: $0.1) }, keyColumn(collection))
            : renderItems(items.map(\.1), dashColumn(collection))
        let last = lastLine(of: collection)
        let at = nextLineStart(last)
        if lineEnd(last) == d.bytes.count {
            replace(at, at, newline + join(lines))              // the last line has no line break
        } else {
            replace(at, at, join(lines) + newline)
        }
    }

    // Orders the entries of `mapping` by decoded key, moving each entry's lines; the lines between entries stay.
    mutating func sort(_ mapping: UInt32, by areInIncreasingOrder: (String, String) -> Bool) {
        let entries = d.arena.children(of: mapping)
        let keys = entries.map { d.keyText($0) }
        let order = entries.indices.sorted { a, b in
            areInIncreasingOrder(keys[a], keys[b]) || !areInIncreasingOrder(keys[b], keys[a]) && a < b
        }
        guard order != Array(entries.indices) else { return }
        let starts = entries.map { Int(record(Int(node($0).line)).keyStart) }
        let ends = entries.map { lineEnd(lastLine(of: $0)) }
        var text: [UInt8] = []
        for (slot, k) in order.enumerated() {
            text += d.bytes[starts[k]..<ends[k]]
            if slot + 1 < entries.count { text += d.bytes[ends[slot]..<starts[slot + 1]] }
        }
        replace(starts[0], ends[entries.count - 1], text)
    }

    // MARK: Rendering

    private func join(_ lines: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for (k, line) in lines.enumerated() {
            if k > 0 { out += newline }
            out += line
        }
        return out
    }

    private func spaces(_ n: Int) -> [UInt8] { [UInt8](repeating: 0x20, count: n) }

    // How `value` attaches to a key or dash at `column`: the text on the owner's line, if any, and the lines
    // that follow it (indented, without line breaks). An item's mapping puts its first entry on the dash line.
    private mutating func attach(_ value: YAMLValue, _ column: Int, item: Bool, previous: ValueKind?)
        -> (inline: [UInt8]?, following: [[UInt8]])
    {
        switch value {
        case .mapping(let entries):
            if entries.isEmpty { return (Array("{}".utf8), []) }
            guard item else { return (nil, renderEntries(entries, column + 2)) }
            let rest = renderEntries(entries, column + 2)
            return (Array(rest[0].dropFirst(column + 2)), Array(rest.dropFirst()))
        case .sequence(let items):
            if items.isEmpty { return (Array("[]".utf8), []) }
            return (nil, renderItems(items, column + 2))
        case .string(let text):
            switch spellString(text, previous: previous) {
            case .inline(let t): return (t, [])
            case .block(let header, let content):
                return (header, content.map { $0.isEmpty ? [] : spaces(column + 2) + $0 })
            }
        default:
            return (scalar(value), [])
        }
    }

    private mutating func renderEntries(_ entries: [(key: String, value: YAMLValue)], _ column: Int) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        for (key, value) in entries {
            let (inline, following) = attach(value, column, item: false, previous: nil)
            lines.append(spaces(column) + spellKey(key) + [0x3A] + (inline.map { [0x20] + $0 } ?? []))
            lines += following
        }
        return lines
    }

    private mutating func renderItems(_ items: [YAMLValue], _ column: Int) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        for value in items {
            let (inline, following) = attach(value, column, item: true, previous: nil)
            lines.append(spaces(column) + [0x2D] + (inline.map { [0x20] + $0 } ?? []))
            lines += following
        }
        return lines
    }

    // MARK: Scalars

    private mutating func scalar(_ value: YAMLValue) -> [UInt8] {
        switch value {
        case .integer(let i): return Array(String(i).utf8)
        case .boolean(let b): return Array((b ? "true" : "false").utf8)
        case .null: return Array("null".utf8)
        case .float(let x):
            if x.isNaN {
                errors.report(YAMLError(.notANumber, ByteSpan(at: 0), "NaN cannot be written; the format has none"))
                return Array(".nan".utf8)
            }
            if x.isInfinite { return Array((x < 0 ? "-.inf" : ".inf").utf8) }
            return Array("\(x)".utf8)
        default:
            preconditionFailure("not a scalar")
        }
    }

    private enum Spelling {
        case inline([UInt8])
        case block(header: [UInt8], content: [[UInt8]])  // content lines without indentation
    }

    private func spellString(_ text: String, previous: ValueKind?) -> Spelling {
        let breaks = text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if breaks == 0 {
            if style.quoting == .plainWhenPossible {
                if let plain = EditPlan.plain(text) { return .inline(plain) }
                if let single = EditPlan.singleQuoted(text) { return .inline(single) }
            }
            return .inline(EditPlan.doubleQuoted(text))
        }
        let double = EditPlan.doubleQuoted(text)
        let block: Bool
        switch style.multiLine {
        case .block: block = true
        case .doubleQuoted: block = false
        case .automatic:
            switch previous {
            case .literal?, .folded?: block = true
            case .doubleQuoted?: block = false
            default: block = breaks >= 2 || double.count > 40
            }
        }
        if block, let b = EditPlan.blockSpelling(text) { return b }
        return .inline(double)
    }

    private func spellKey(_ key: String) -> [UInt8] {
        if style.quoting == .plainWhenPossible && !key.contains("\n") {
            for candidate in [Array(key.utf8), EditPlan.singleQuoted(key)].compactMap({ $0 }) {
                if let doc = try? YAMLDocument(parsing: candidate + Array(": x\n".utf8)),
                   doc.root.count == 1, Array(doc.root.entries)[0].key == key {
                    return candidate
                }
            }
        }
        return EditPlan.doubleQuoted(key)
    }

    // `text` as a plain scalar, when it parses back as that string.
    private static func plain(_ text: String) -> [UInt8]? {
        let spelling = Array(text.utf8)
        return reads(spelling, as: text) ? spelling : nil
    }

    private static func singleQuoted(_ text: String) -> [UInt8]? {
        guard !text.contains("\n") else { return nil }
        var spelling: [UInt8] = [0x27]
        for c in text.utf8 { spelling += c == 0x27 ? [0x27, 0x27] : [c] }
        spelling.append(0x27)
        return reads(spelling, as: text) ? spelling : nil
    }

    // A `|` block for `text`, with the chomping indicator its final line breaks need, when it reads back.
    private static func blockSpelling(_ text: String) -> Spelling? {
        var body = Array(text.utf8)
        var trailing = 0
        while body.last == 0x0A {
            body.removeLast()
            trailing += 1
        }
        guard !body.isEmpty, !body.contains(0x0D) else { return nil }
        let header = Array((trailing == 0 ? "|-" : trailing == 1 ? "|" : "|+").utf8)
        var content = body.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        content += [[UInt8]](repeating: [], count: max(0, trailing - 1))
        var probe = Array("k: ".utf8) + header
        for line in content { probe += [0x0A] + (line.isEmpty ? [] : [0x20, 0x20] + line) }
        probe.append(0x0A)
        guard let doc = try? YAMLDocument(parsing: probe), doc.root["k"]?.string == text else { return nil }
        return .block(header: header, content: content)
    }

    // Whether `spelling`, written as the value of a one-entry mapping, reads back as the string `text`.
    private static func reads(_ spelling: [UInt8], as text: String) -> Bool {
        guard let doc = try? YAMLDocument(parsing: Array("k: ".utf8) + spelling + [0x0A]) else { return false }
        return doc.root.count == 1 && doc.root["k"]?.string == text
    }

    // `text` double-quoted, escaping what cannot appear literally (spec §18).
    static func doubleQuoted(_ text: String) -> [UInt8] {
        var out: [UInt8] = [0x22]
        for s in text.unicodeScalars {
            let v = s.value
            switch v {
            case 0x22: out += Array("\\\"".utf8)
            case 0x5C: out += Array("\\\\".utf8)
            case 0x0A: out += Array("\\n".utf8)
            case 0x09: out += Array("\\t".utf8)
            case 0x0D: out += Array("\\r".utf8)
            case 0x85: out += Array("\\N".utf8)
            case 0x2028: out += Array("\\L".utf8)
            case 0x2029: out += Array("\\P".utf8)
            case 0..<0x20, 0x7F, 0x80...0x9F: out += Array("\\x".utf8) + hex(v, digits: 2)
            case 0xFEFF, 0xFFFE, 0xFFFF: out += Array("\\u".utf8) + hex(v, digits: 4)
            default: ScalarText.appendUTF8(v, to: &out)
            }
        }
        out.append(0x22)
        return out
    }

    private static func hex(_ v: UInt32, digits: Int) -> [UInt8] {
        let digitsText = String(v, radix: 16, uppercase: true)
        return Array((String(repeating: "0", count: max(0, digits - digitsText.count)) + digitsText).utf8)
    }
}
