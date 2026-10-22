// Scalar text: decoding quoted scalars (spec §17, §18) and the case-folded form of keys that duplicate-key
// detection compares (spec §6). Spans are whole scalars as the line records hold them, quotes included.

enum ScalarText {
    // Appends the decoded text of the scalar spanning `b[start..<end]` to `out`: plain when `quote` is nil,
    // else quoted with `quote`. Returns false at a malformed escape, which stage 4 reports; `out` is then
    // incomplete.
    static func appendDecoded(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, quote: UInt8?,
                              to out: inout [UInt8]) -> Bool {
        switch quote {
        case nil:
            out.append(contentsOf: b[start..<end])
            return true
        case 0x27?:  // single-quoted: `''` is one apostrophe
            var i = start + 1
            while i < end - 1 {
                out.append(b[i])
                i += b[i] == 0x27 ? 2 : 1
            }
            return true
        default:
            return appendDoubleQuoted(b, start + 1, end - 1, to: &out)
        }
    }

    // Decodes a double-quoted body `b[start..<end]`.
    private static func appendDoubleQuoted(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int,
                                           to out: inout [UInt8]) -> Bool {
        var i = start
        while i < end {
            guard b[i] == 0x5C else {
                out.append(b[i])
                i += 1
                continue
            }
            guard case .scalar(let v, let length) = escape(b, at: i, end: end) else { return false }
            appendUTF8(v, to: &out)
            i += length
        }
        return true
    }

    enum Escape: Equatable {
        case scalar(UInt32, length: Int)    // the escaped scalar and the escape's length in bytes
        case invalid(length: Int)           // an unknown escape, or too few hexadecimal digits
        case notAScalar(length: Int)        // a surrogate or a value past U+10FFFF
    }

    // The escape at `b[i]`, a backslash, in a double-quoted body ending before `end` (spec §18).
    static func escape(_ b: UnsafeBufferPointer<UInt8>, at i: Int, end: Int) -> Escape {
        guard i + 1 < end else { return .invalid(length: 1) }
        let e = b[i + 1]
        switch e {
        case 0x30: return .scalar(0x00, length: 2)                     // \0
        case 0x61: return .scalar(0x07, length: 2)                     // \a
        case 0x62: return .scalar(0x08, length: 2)                     // \b
        case 0x74, 0x09: return .scalar(0x09, length: 2)               // \t, or a backslash and a tab
        case 0x6E: return .scalar(0x0A, length: 2)                     // \n
        case 0x76: return .scalar(0x0B, length: 2)                     // \v
        case 0x66: return .scalar(0x0C, length: 2)                     // \f
        case 0x72: return .scalar(0x0D, length: 2)                     // \r
        case 0x65: return .scalar(0x1B, length: 2)                     // \e
        case 0x20, 0x22, 0x2F, 0x5C: return .scalar(UInt32(e), length: 2)  // space, \", \/, \\
        case 0x4E: return .scalar(0x85, length: 2)                     // \N
        case 0x5F: return .scalar(0xA0, length: 2)                     // \_
        case 0x4C: return .scalar(0x2028, length: 2)                   // \L
        case 0x50: return .scalar(0x2029, length: 2)                   // \P
        case 0x78, 0x75, 0x55:                                         // \xHH, \uHHHH, \UHHHHHHHH
            let digits = e == 0x78 ? 2 : e == 0x75 ? 4 : 8
            var v: UInt32 = 0
            var k = i + 2
            while k < i + 2 + digits {
                guard k < end, let d = hexValue(b[k]) else { return .invalid(length: k - i) }
                v = v << 4 | d
                k += 1
            }
            guard v <= 0x10FFFF && !(0xD800...0xDFFF).contains(v) else { return .notAScalar(length: 2 + digits) }
            return .scalar(v, length: 2 + digits)
        default:
            return .invalid(length: 2)
        }
    }

    private static func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        default: return nil
        }
    }

    static func appendUTF8(_ v: UInt32, to out: inout [UInt8]) {
        switch v {
        case 0..<0x80:
            out.append(UInt8(v))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | v >> 6))
            out.append(UInt8(0x80 | v & 0x3F))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | v >> 12))
            out.append(UInt8(0x80 | v >> 6 & 0x3F))
            out.append(UInt8(0x80 | v & 0x3F))
        default:
            out.append(UInt8(0xF0 | v >> 18))
            out.append(UInt8(0x80 | v >> 12 & 0x3F))
            out.append(UInt8(0x80 | v >> 6 & 0x3F))
            out.append(UInt8(0x80 | v & 0x3F))
        }
    }

    // The decoded text of the value on line `i`: a plain or quoted scalar, or a block scalar with its header
    // on that line. Built when read; stage 4 has checked the escapes.
    static func value(_ b: UnsafeBufferPointer<UInt8>, _ records: [LineRecord], line i: Int) -> [UInt8] {
        let r = records[i]
        switch r.valueKind {
        case .literal, .folded:
            return blockScalar(b, records, header: i)
        default:
            let quote: UInt8? = r.valueKind == .singleQuoted ? 0x27 : r.valueKind == .doubleQuoted ? 0x22 : nil
            var out: [UInt8] = []
            _ = appendDecoded(b, Int(r.valueStart), Int(r.valueEnd), quote: quote, to: &out)
            return out
        }
    }

    // MARK: Block scalars

    // The text of the block scalar whose header is on line `header` (spec §20, §21): its content lines with
    // the content indentation removed, folded for `>`, and chomped.
    //
    // Folding follows YAML 1.2: a line break between two lines that start with a non-space character becomes
    // a space, or, when empty lines separate them, is dropped and each empty line gives a line break. Breaks
    // next to a more-indented line, one starting with a space or tab, are kept.
    static func blockScalar(_ b: UnsafeBufferPointer<UInt8>, _ records: [LineRecord], header: Int) -> [UInt8] {
        let h = records[header]
        let n = (h.keyKind != .none ? Int(h.keyStart - h.contentStart) : Int(h.level) * 2) + 2
        let folded = h.valueKind == .folded
        var out: [UInt8] = []
        var empties = 0             // empty lines since the last content line
        var emptyBreaks = 0         // how many of those end with a line break
        var previousFolds: Bool?    // whether the previous content line can fold; nil before the first
        var lastHasBreak = false

        var i = header + 1
        while i < records.count && records[i].kind == .blockContent {
            let r = records[i]
            i += 1
            let start = Int(r.contentStart), end = Int(r.contentEnd)
            var p = start
            while p < end && p - start < n && b[p] == 0x20 { p += 1 }
            let hasBreak = end < b.count
            if p == end {  // at most `n` spaces: an empty line
                empties += 1
                if hasBreak { emptyBreaks += 1 }
                continue
            }
            let folds = b[p] != 0x20 && b[p] != 0x09
            if let previous = previousFolds {
                if folded && previous && folds {
                    if empties == 0 { out.append(0x20) }
                } else {
                    out.append(0x0A)
                }
            }
            out.append(contentsOf: repeatElement(0x0A, count: empties))
            out.append(contentsOf: b[p..<end])
            previousFolds = folds
            empties = 0
            emptyBreaks = 0
            lastHasBreak = hasBreak
        }

        switch h.chomping {
        case .strip: break
        case .clip: if lastHasBreak { out.append(0x0A) }
        case .keep: if lastHasBreak { out.append(contentsOf: repeatElement(0x0A, count: 1 + emptyBreaks)) }
        }
        return out
    }

    // MARK: Case folding

    // Replaces `text` (UTF-8) with its simple case folding.
    static func fold(_ text: inout [UInt8]) {
        if text.allSatisfy({ $0 < 0x80 }) {
            for k in text.indices where text[k] &- 0x41 < 26 { text[k] |= 0x20 }
            return
        }
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        for scalar in String(decoding: text, as: UTF8.self).unicodeScalars {
            appendUTF8(fold(scalar.value), to: &out)
        }
        text = out
    }

    // The simple case folding of one scalar.
    static func fold(_ v: UInt32) -> UInt32 {
        if v < 0x80 { return v &- 0x41 < 26 ? v | 0x20 : v }
        var lo = 0, hi = caseFoldingPairs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let from = UInt32(truncatingIfNeeded: caseFoldingPairs[mid] >> 24)
            if from == v { return UInt32(truncatingIfNeeded: caseFoldingPairs[mid] & 0xFF_FFFF) }
            if from < v { lo = mid + 1 } else { hi = mid }
        }
        return v
    }
}
