// Stage 4: resolve each scalar's type under the YAML 1.2 Core schema and reject the spellings the format
// excludes (spec §11–§16), and check double-quoted escapes (§18).
//
// Typing and every rejection run eagerly, since any of them rejects the document. Values are not built here:
// strings are decoded when read (`ScalarText`), and numbers parsed again when read, from spellings this stage
// has checked.
//
// Rejections follow "simple rejection over ambiguity" (§26): every casing of `true`, `false`, `null`, `.inf`
// and `.nan` other than the lowercase one is rejected, as are numeric-looking spellings Core reads as strings
// (`0b1010`, `1_000`, `-0x2a`). Core reads those as strings, so rejecting them never changes the meaning of
// an accepted document.

public enum ScalarType: UInt8 {
    case string, integer, float, boolean, null
}

public struct Resolution: Equatable {
    // The type of each node's scalar, by node index; meaningful for scalar nodes only.
    public let types: [ScalarType]
    public let errors: YAMLErrors
}

// Resolves the scalars of a built structure. `structure.errors` carries the earlier stages' errors forward.
public func resolveScalars(_ bytes: UnsafeBufferPointer<UInt8>, _ lexing: Lexing, _ structure: Structuring)
    -> Resolution
{
    var errors = structure.errors
    let records = lexing.records.lines
    let nodes = structure.arena.nodes
    let types = [ScalarType](unsafeUninitializedCapacity: nodes.count) { out, count in
        for (k, node) in nodes.enumerated() {
            var type = ScalarType.string
            let r = records[Int(node.line)]
            switch node.kind {
            case .scalar:
                type = resolveValue(bytes, r, &errors)
            case .entry:
                resolveKey(bytes, r, &errors)
            case .mapping, .sequence:
                break
            }
            (out.baseAddress! + k).initialize(to: type)
        }
        count = nodes.count
    }
    return Resolution(types: types, errors: errors)
}

public func resolveScalars(_ bytes: [UInt8], _ lexing: Lexing, _ structure: Structuring) -> Resolution {
    bytes.withUnsafeBufferPointer { resolveScalars($0, lexing, structure) }
}

private func resolveValue(_ b: UnsafeBufferPointer<UInt8>, _ r: LineRecord, _ errors: inout YAMLErrors)
    -> ScalarType
{
    let start = Int(r.valueStart), end = Int(r.valueEnd)
    switch r.valueKind {
    case .plain:
        switch ScalarTyping.classify(b, start, end) {
        case .type(let t):
            return t
        case .rejected(let code, let message, let fix):
            errors.report(YAMLError(code, ByteSpan(start: r.valueStart, end: r.valueEnd), message, fix: fix))
        }
    case .doubleQuoted:
        checkEscapes(b, start, end, &errors)
    default:
        break
    }
    return .string
}

// A key is a string: a plain key that types as anything else is rejected (spec §6).
private func resolveKey(_ b: UnsafeBufferPointer<UInt8>, _ r: LineRecord, _ errors: inout YAMLErrors) {
    let start = Int(r.keyStart), end = Int(r.keyEnd)
    let span = ByteSpan(start: r.keyStart, end: r.keyEnd)
    switch r.keyKind {
    case .plain:
        switch ScalarTyping.classify(b, start, end) {
        case .type(.string):
            break
        case .type(let t):
            let text = String(decoding: b[start..<end], as: UTF8.self)
            errors.report(YAMLError(.nonStringKey, span, "the key `\(text)` is \(ScalarTyping.name(t)); keys are strings",
                                    fix: "quote it: \"\(text)\""))
        case .rejected(let code, let message, let fix):
            errors.report(YAMLError(code, span, message, fix: fix))
        }
    case .doubleQuoted:
        checkEscapes(b, start, end, &errors)
    default:
        break
    }
}

// Reports each malformed escape in the double-quoted scalar spanning `b[start..<end]`, quotes included.
private func checkEscapes(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ errors: inout YAMLErrors) {
    var i = start + 1
    while i < end - 1 {
        guard b[i] == 0x5C else {
            i += 1
            continue
        }
        let escape = ScalarText.escape(b, at: i, end: end - 1)
        switch escape {
        case .scalar(_, let length):
            i += length
        case .invalid(let length):
            let text = String(decoding: b[i..<i + max(length, 2)], as: UTF8.self)
            errors.report(YAMLError(.invalidEscape, ByteSpan(start: UInt32(i), end: UInt32(i + max(length, 2))),
                                    "`\(text)` is not an escape", fix: "write a backslash as \\\\"))
            i += max(length, 2)
        case .notAScalar(let length):
            errors.report(YAMLError(.invalidUnicodeEscape, ByteSpan(start: UInt32(i), end: UInt32(i + length)),
                                    "the escape is not a Unicode scalar value (a surrogate, or past U+10FFFF)"))
            i += length
        }
    }
}

enum ScalarTyping {
    enum Typing: Equatable {
        case type(ScalarType)
        case rejected(YAMLError.Code, String, fix: String?)
    }

    // The type of the plain scalar `b[start..<end]`, or why it is rejected.
    static func classify(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Typing {
        switch b[start] {
        case 0x2B, 0x2D, 0x2E, 0x30...0x39:  // + - . digits
            return number(b, start, end)
        case 0x74, 0x54, 0x66, 0x46, 0x6E, 0x4E:  // t f n, either case
            return words(b, start, end)
        case 0x7E where end - start == 1:  // ~
            return .rejected(.nullSpelling, "`~` is not a null spelling; null is `null`",
                             fix: "write null, or quote it for a string: \"~\"")
        default:
            return .type(.string)
        }
    }

    // `true`, `false` and `null` in any casing.
    private static func words(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Typing {
        let word: StaticString, type: ScalarType
        switch (end - start, b[start] | 0x20) {
        case (4, 0x74): (word, type) = ("true", .boolean)
        case (5, 0x66): (word, type) = ("false", .boolean)
        case (4, 0x6E): (word, type) = ("null", .null)
        default: return .type(.string)
        }
        switch match(b, start, end, word) {
        case .exact:
            return .type(type)
        case .otherCase:
            let text = String(decoding: b[start..<end], as: UTF8.self)
            let fix = "write \(word), or quote it for a string: \"\(text)\""
            return type == .null
                ? .rejected(.nullSpelling, "`\(text)` is not a null spelling; null is `null`", fix: fix)
                : .rejected(.booleanCase, "`\(text)` is not a boolean spelling; booleans are `true` and `false`",
                            fix: fix)
        case .different:
            return .type(.string)
        }
    }

    // A scalar starting with a sign, a dot or a digit.
    private static func number(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Typing {
        let sign: UInt8? = b[start] == 0x2B || b[start] == 0x2D ? b[start] : nil
        let body = sign == nil ? start : start + 1
        guard body < end else { return .type(.string) }
        let plus = sign == 0x2B
        func text() -> String { String(decoding: b[start..<end], as: UTF8.self) }
        func quote() -> String { "quote it for a string: \"\(text())\"" }
        func unaryPlus() -> Typing {
            .rejected(.unaryPlus, "a unary `+` is not allowed", fix: "write \(text().dropFirst()), or \(quote())")
        }

        if match(b, body, end, ".nan") != .different {
            return .rejected(.notANumber, "NaN is not allowed", fix: quote())
        }
        switch match(b, body, end, ".inf") {
        case .exact:
            return plus ? unaryPlus() : .type(.float)
        case .otherCase:
            if plus { return unaryPlus() }
            return .rejected(.infinityCase, "infinity is spelled `.inf`",
                             fix: "write \(sign == nil ? "" : "-").inf, or \(quote())")
        case .different:
            break
        }
        if nonDecimal(b, body, end) {
            if plus { return unaryPlus() }
            return .rejected(.nonDecimalInteger, "only decimal integers are allowed",
                             fix: "write it in decimal, or \(quote())")
        }
        switch decimal(b, body, end, underscores: false) {
        case .integer:
            if plus { return unaryPlus() }
            guard integerValue(b, start, end) != nil else {
                return .rejected(.integerOutOfRange, "the integer is outside the signed 64-bit range", fix: quote())
            }
            return .type(.integer)
        case .float:
            if plus { return unaryPlus() }
            guard floatValue(b, start, end).isFinite else {
                return .rejected(.floatOutOfRange, "the float is too large; it rounds to infinity", fix: quote())
            }
            return .type(.float)
        case nil:
            break
        }
        if decimal(b, body, end, underscores: true) != nil {
            if plus { return unaryPlus() }
            return .rejected(.numericUnderscore, "underscores are not allowed in numbers",
                             fix: "remove them, or \(quote())")
        }
        return .type(.string)
    }

    private enum Match { case exact, otherCase, different }

    // Whether `b[start..<end]` is `word` (lowercase ASCII), exactly or in another casing.
    private static func match(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ word: StaticString)
        -> Match
    {
        guard end - start == word.utf8CodeUnitCount else { return .different }
        var exact = true
        for k in 0..<word.utf8CodeUnitCount {
            let c = b[start + k], w = word.utf8Start[k]
            if c == w { continue }
            guard c &- 0x41 < 26 && c | 0x20 == w else { return .different }
            exact = false
        }
        return exact ? .exact : .otherCase
    }

    private enum Decimal { case integer, float }

    // Whether `b[start..<end]` is a Core decimal integer `[0-9]+` or float
    // `(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`. With `underscores`, it must hold an underscore, may hold
    // more after its first character, and is matched with them removed.
    private static func decimal(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, underscores: Bool)
        -> Decimal?
    {
        var i = start
        var sawUnderscore = false
        func digits() -> Int {
            var n = 0
            while i < end {
                if b[i] &- 0x30 < 10 { n += 1 } else if !(underscores && b[i] == 0x5F && i > start) { break }
                if b[i] == 0x5F { sawUnderscore = true }
                i += 1
            }
            return n
        }
        let whole = digits()
        var isFloat = false
        if i < end && b[i] == 0x2E {
            i += 1
            let fraction = digits()
            guard whole > 0 || fraction > 0 else { return nil }
            isFloat = true
        } else if whole == 0 {
            return nil
        }
        if i < end && (b[i] == 0x65 || b[i] == 0x45) {
            i += 1
            if i < end && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
            guard digits() > 0 else { return nil }
            isFloat = true
        }
        guard i == end && sawUnderscore == underscores else { return nil }
        return isFloat ? .float : .integer
    }

    // `0x`, `0o` or `0b` in either case, followed by digits of that base or underscores (Core reads `0x2a` and
    // `0o52` as integers and the rest as strings; all of them read as numbers).
    private static func nonDecimal(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        guard end - start > 2 && b[start] == 0x30 else { return false }
        let radix = b[start + 1] | 0x20
        for k in start + 2..<end {
            let c = b[k]
            if c == 0x5F { continue }
            let ok: Bool
            switch radix {
            case 0x78: ok = c &- 0x30 < 10 || (c | 0x20) &- 0x61 < 6   // x
            case 0x6F: ok = c &- 0x30 < 8                              // o
            case 0x62: ok = c &- 0x30 < 2                              // b
            default: return false
            }
            if !ok { return false }
        }
        return true
    }

    // The value of the Core float `b[start..<end]` (a checked spelling, with an optional `-`), rounded to
    // nearest; infinite past the double range, and for `.inf`.
    static func floatValue(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Double {
        let negative = b[start] == 0x2D
        if match(b, negative ? start + 1 : start, end, ".inf") == .exact { return negative ? -.infinity : .infinity }
        return Double(String(decoding: b[start..<end], as: UTF8.self))!
    }

    // The value of the decimal integer `b[start..<end]`, with an optional `-`, or nil past 64 bits.
    static func integerValue(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Int64? {
        let negative = b[start] == 0x2D
        var magnitude: UInt64 = 0
        for k in (negative ? start + 1 : start)..<end {
            let (m, o1) = magnitude.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(UInt64(b[k] - 0x30))
            if o1 || o2 { return nil }
            magnitude = s
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }

    static func name(_ t: ScalarType) -> String {
        switch t {
        case .string: return "a string"
        case .integer: return "an integer"
        case .float: return "a float"
        case .boolean: return "a boolean"
        case .null: return "null"
        }
    }
}
