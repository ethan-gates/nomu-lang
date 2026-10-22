// Stage 1: validate the bytes and index the lines (spec §2, §4).
//
// One pass checks that the input is UTF-8 holding only permitted characters, that line endings are LF or
// CRLF in one style, and records where each line starts. ASCII, the common case for configuration files, is
// checked 64 bytes at a time with vector operations (`SIMD.swift`); a block holding any non-ASCII byte is
// decoded byte by byte. Invalid UTF-8 ends the pass, since line boundaries past bad bytes cannot be trusted;
// every other error here is independent and collected.

public enum LineEnding: Equatable {
    case lf
    case crlf
    case none   // the input has no line break
}

public struct ValidatedSource: Equatable {
    public let byteCount: UInt32
    public let lines: LineIndex
    public let lineEnding: LineEnding
    public let hasByteOrderMark: Bool
    // The parser's plain-stop mask for each 64-byte block from offset 0 (`PlainStops`); empty when the
    // validator did not classify.
    let plainStops: [UInt64]

    public static func == (x: ValidatedSource, y: ValidatedSource) -> Bool {
        x.byteCount == y.byteCount && x.lines == y.lines && x.lineEnding == y.lineEnding
            && x.hasByteOrderMark == y.hasByteOrderMark
    }
}

public struct Validation: Equatable {
    // Nil when the input could not be indexed: invalid UTF-8, or a file too large for 32-bit offsets.
    public let source: ValidatedSource?
    public let errors: YAMLErrors
}

// Validates `bytes` and indexes its lines; with `classifying`, also computes the parser's plain-stop masks
// in the same pass over each block.
public func validate(_ bytes: [UInt8], classifying: Bool = true) -> Validation {
    bytes.withUnsafeBufferPointer { validate($0, classifying: classifying) }
}

public func validate(_ bytes: UnsafeBufferPointer<UInt8>, classifying: Bool = true) -> Validation {
    var validator = Validator(bytes, vector: true, classifying: classifying)
    return validator.run()
}

private enum Byte {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
}

struct Validator {
    private let bytes: UnsafeBufferPointer<UInt8>
    private let count: Int
    // Off only in tests, which check the vector path against the byte-by-byte one.
    private let vector: Bool
    private let classifying: Bool

    private var errors = YAMLErrors()
    private let lineStarts: GrowableBuffer<UInt32>
    private var lineEnding = LineEnding.none
    private var reportedMixedEndings = false

    init(_ bytes: UnsafeBufferPointer<UInt8>, vector: Bool, classifying: Bool = false) {
        self.bytes = bytes
        self.count = bytes.count
        self.vector = vector
        self.classifying = classifying && vector
        lineStarts = GrowableBuffer(capacity: bytes.count / 16 + 1)
        lineStarts.append(0)
    }

    mutating func run() -> Validation {
        guard count <= Int(UInt32.max) else {
            errors.report(YAMLError(.fileTooLarge, ByteSpan(at: 0), "file is \(count) bytes; the limit is 4 GiB minus one byte"))
            return Validation(source: nil, errors: errors)
        }
        let hasBOM = count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        let blocks = classifying ? (count + Block.size - 1) / Block.size : 0
        let stops = UnsafeMutablePointer<UInt64>.allocate(capacity: blocks)
        defer { stops.deallocate() }
        guard scan(from: hasBOM ? 3 : 0, stops: classifying ? stops : nil) else {
            return Validation(source: nil, errors: errors)
        }
        let source = ValidatedSource(byteCount: UInt32(count), lines: LineIndex(lineStarts: lineStarts.array),
                                     lineEnding: lineEnding, hasByteOrderMark: hasBOM,
                                     plainStops: Array(UnsafeBufferPointer(start: stops, count: blocks)))
        return Validation(source: source, errors: errors)
    }

    // Validates from offset `i`, block by block from offset 0, and writes each block's plain-stop mask to
    // `stops` when classifying. Returns false at invalid UTF-8.
    private mutating func scan(from i: Int, stops: UnsafeMutablePointer<UInt64>?) -> Bool {
        var i = i
        var base = 0
        if vector {
            while base + Block.size <= count && !errors.truncated {
                let block = Block(UnsafeRawPointer(bytes.baseAddress! + base))
                if let stops { stops[base / Block.size] = classify(block, at: base) }
                guard let next = vectorBlock(block, at: base, from: i) else { return false }
                i = next
                base += Block.size
            }
            if base < count, let stops { stops[base / Block.size] = PlainStops.mask(bytes, at: base) }
        }
        while i < count && !errors.truncated {
            guard let next = scalarStep(at: i) else { return false }
            i = next
        }
        return true
    }

    // The plain-stop mask of the full block at `base`, from three loads when its neighbors are in the source.
    @inline(__always)
    private func classify(_ block: Block, at base: Int) -> UInt64 {
        guard base > 0 && base + Block.size < count else { return PlainStops.mask(bytes, at: base) }
        let p = UnsafeRawPointer(bytes.baseAddress! + base)
        return PlainStops.mask(Block(p - 1), block, Block(p + 1))
    }

    // MARK: Vector path

    // Validates the 64-byte block at `i`, starting from offset `from` (past the block's start when a multibyte
    // character runs into it). Returns the offset after the last character handled, or nil at invalid UTF-8.
    //
    // Line endings are resolved with masks: a block whose only controls are tabs and well-formed line breaks
    // in the file's style records its line starts straight from the LF mask. A block holding anything else (a
    // forbidden control, a lone CR, a change of style) is checked byte by byte, which reports in source order.
    // Multibyte characters are decoded one by one, from the lead bytes in the mask of bytes from 0x80; the
    // ASCII masks leave those bytes out.
    @inline(__always)
    private mutating func vectorBlock(_ block: Block, at i: Int, from: Int) -> Int? {
        let ascii = block.isASCII

        // Masks cost a multiply per half-vector, so the rare classes (other controls, CRs) are first tested for
        // presence with a vector OR, and only the LF mask is always built.
        let otherControls = block.any(Validator.otherControl01)
        let lf = block.mask { equal01($0, Byte.lf) }
        let cr = block.any { equal01($0, Byte.cr) } ? block.mask { equal01($0, Byte.cr) } : 0
        // Bit k of `crBefore` says byte k - 1 is a CR; bit k of `lfAfter` says byte k + 1 is an LF. Each
        // reaches one byte past the block on its open side.
        let crBefore = cr << 1 | (i > 0 && bytes[i - 1] == Byte.cr ? 1 : 0)
        let lfAfter = lf >> 1 | (i + Block.size < count && bytes[i + Block.size] == Byte.lf ? 1 << 63 : 0)
        let crlf = lf & crBefore
        let bareLF = lf & ~crBefore
        let style: LineEnding = crlf != 0 ? .crlf : .lf
        let wellFormed = !otherControls
            && cr & ~lfAfter == 0                         // no lone CR
            && (crlf == 0 || bareLF == 0)                 // one style within the block
            && (lineEnding == .none || lineEnding == style || lf == 0)

        guard wellFormed else {
            if ascii {
                var interesting = block.mask(Validator.controlExceptTab01)
                while interesting != 0 {
                    let lane = interesting.trailingZeroBitCount
                    interesting &= interesting - 1
                    asciiControl(at: i + lane)
                }
                return i + Block.size
            }
            var j = from
            while j < i + Block.size {
                guard let next = scalarStep(at: j) else { return nil }
                j = next
            }
            return j
        }
        if lf != 0 && lineEnding == .none { lineEnding = style }
        lineStarts.reserve(Block.size)
        var breaks = lf
        while breaks != 0 {
            let start = i + breaks.trailingZeroBitCount + 1
            breaks &= breaks - 1
            if start < count { lineStarts.appendReserved(UInt32(start)) }
        }
        if ascii { return i + Block.size }

        var lead = block.mask { $0 &>> 7 } & ~UInt64(0) << UInt64(from - i)
        var j = i + Block.size
        while lead != 0 {
            guard let next = scalarStep(at: i + lead.trailingZeroBitCount) else { return nil }
            j = max(next, i + Block.size)
            lead = next - i >= Block.size ? 0 : lead & ~UInt64(0) << UInt64(next - i)
        }
        return j
    }

    // 0x01 in lanes holding an ASCII control byte other than a tab: below 0x20, or DEL. Tabs are placed by the
    // line stage, so here they are permitted.
    @inline(__always)
    private static func controlExceptTab01(_ v: Lanes) -> Lanes {
        (below01(v, 0x20) | equal01(v, 0x7F)) & (equal01(v, Byte.tab) ^ 1)
    }

    // 0x01 in lanes holding a control byte other than a tab, LF or CR.
    @inline(__always)
    private static func otherControl01(_ v: Lanes) -> Lanes {
        controlExceptTab01(v) & ~(equal01(v, Byte.lf) | equal01(v, Byte.cr))
    }

    // MARK: Byte-by-byte path

    // Validates the character starting at `i` and returns the offset after it, or nil after reporting
    // invalid UTF-8.
    private mutating func scalarStep(at i: Int) -> Int? {
        let b0 = bytes[i]
        if b0 < 0x80 {
            if b0 < 0x20 || b0 == 0x7F { asciiControl(at: i) }
            return i + 1
        }

        // Well-formed sequences, Unicode Table 3-7. The second byte's range depends on the first; it is what
        // rules out overlong forms, surrogates, and values past U+10FFFF.
        let length: Int
        var lo: UInt8 = 0x80, hi: UInt8 = 0xBF
        switch b0 {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; lo = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; hi = 0x9F
        case 0xF0: length = 4; lo = 0x90
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; hi = 0x8F
        default:
            return invalidUTF8(at: i, length: 1)
        }
        guard continuation(at: i + 1, lo, hi) else { return invalidUTF8(at: i, length: 1) }
        for k in 2..<length where !continuation(at: i + k, 0x80, 0xBF) {
            return invalidUTF8(at: i, length: k)
        }

        var scalar = UInt32(b0) & (0x7F >> length)
        for k in 1..<length { scalar = scalar << 6 | UInt32(bytes[i + k] & 0x3F) }
        checkNonASCII(scalar, span: ByteSpan(start: UInt32(i), end: UInt32(i + length)))
        return i + length
    }

    private func continuation(at j: Int, _ lo: UInt8, _ hi: UInt8) -> Bool {
        j < count && bytes[j] >= lo && bytes[j] <= hi
    }

    // `length` covers the bytes read before the sequence failed (its maximal well-formed prefix).
    private mutating func invalidUTF8(at i: Int, length: Int) -> Int? {
        errors.report(YAMLError(.invalidUTF8, ByteSpan(start: UInt32(i), end: UInt32(i + length)),
                                "invalid UTF-8 byte sequence"))
        return nil
    }

    // MARK: Characters and line endings

    // An ASCII control byte other than a tab.
    private mutating func asciiControl(at i: Int) {
        switch bytes[i] {
        case Byte.tab:
            break
        case Byte.lf:
            lineFeed(at: i)
        case Byte.cr:
            if i + 1 >= count || bytes[i + 1] != Byte.lf {
                errors.report(YAMLError(.loneCarriageReturn, ByteSpan(start: UInt32(i), end: UInt32(i + 1)),
                                        "a carriage return must be followed by a line feed"))
            }
        default:
            let span = ByteSpan(start: UInt32(i), end: UInt32(i + 1))
            errors.report(YAMLError(.forbiddenCharacter, span,
                                    "control character \(Validator.codePoint(UInt32(bytes[i]))) is not allowed"))
        }
    }

    private mutating func lineFeed(at i: Int) {
        let style: LineEnding = i > 0 && bytes[i - 1] == Byte.cr ? .crlf : .lf
        if lineEnding == .none {
            lineEnding = style
        } else if style != lineEnding && !reportedMixedEndings {
            reportedMixedEndings = true
            let start = style == .crlf ? i - 1 : i
            errors.report(YAMLError(.mixedLineEndings, ByteSpan(start: UInt32(start), end: UInt32(i + 1)),
                                    "this line ends with \(Validator.name(style)), but earlier lines end with \(Validator.name(lineEnding))",
                                    fix: "use one line-ending style throughout the file"))
        }
        // A final line break ends the last line without opening another.
        if i + 1 < count { lineStarts.append(UInt32(i + 1)) }
    }

    private mutating func checkNonASCII(_ scalar: UInt32, span: ByteSpan) {
        switch scalar {
        case 0x85, 0x2028, 0x2029:
            let (name, escape) = scalar == 0x85 ? ("NEXT LINE", "\\N")
                : scalar == 0x2028 ? ("LINE SEPARATOR", "\\L") : ("PARAGRAPH SEPARATOR", "\\P")
            errors.report(YAMLError(.invisibleLineBreak, span,
                                    "\(Validator.codePoint(scalar)) \(name) is not allowed literally; editors may show it as a line break",
                                    fix: "write it as \(escape) in a double-quoted string"))
        case 0x80...0x9F:
            errors.report(YAMLError(.forbiddenCharacter, span,
                                    "control character \(Validator.codePoint(scalar)) is not allowed"))
        case 0xFEFF:
            errors.report(YAMLError(.misplacedByteOrderMark, span,
                                    "a byte-order mark is allowed only at the start of the file",
                                    fix: "write it as \\uFEFF in a double-quoted string"))
        case 0xFFFE, 0xFFFF:
            errors.report(YAMLError(.forbiddenCharacter, span,
                                    "noncharacter \(Validator.codePoint(scalar)) is not allowed"))
        default:
            break
        }
    }

    // `U+XXXX`, at least four hex digits.
    static func codePoint(_ scalar: UInt32) -> String {
        let hex = String(scalar, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    private static func name(_ ending: LineEnding) -> String {
        switch ending {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .none: return "no line break"
        }
    }
}
