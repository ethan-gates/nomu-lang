// Errors are values: the library never prints. Each error carries a stable code naming the spec rule it
// enforces, so tests assert codes and messages can be reworded freely.

public struct YAMLError: Error, Equatable {
    public enum Code: Equatable, Hashable {
        // Encoding and characters (spec §2).
        case invalidUTF8
        case forbiddenCharacter         // control characters, U+FFFE, U+FFFF
        case invisibleLineBreak         // literal NEL, U+2028, U+2029
        case misplacedByteOrderMark     // U+FEFF past offset 0
        case fileTooLarge               // 2³² bytes or more

        // Line endings and whitespace (spec §4).
        case loneCarriageReturn
        case mixedLineEndings
        case trailingWhitespace
        case whitespaceOnlyLine
        case tabOutsideScalar           // a tab outside quoted scalars, block scalar content and comments

        // Documents (spec §3).
        case emptyDocument
        case multipleDocuments
        case contentOnMarkerLine        // `--- value`
        case contentAfterDocumentEnd    // anything but comments after `...`
        case directive                  // `%YAML`, `%TAG`

        // Indentation and structure (spec §5, §7, §23).
        case oddIndentation             // structural indentation not a multiple of two spaces
        case indentationJump            // more than one level deeper than the parent
        case indentlessSequence
        case sequenceOnItemLine         // `- - a`
        case sequenceOnKeyLine          // `key: - a`
        case mappingOnValueLine         // `a: b: c`
        case mixedCollection            // mapping entries and sequence items at one level
        case nestingTooDeep             // more than 255 levels
        case missingValue               // `key:` or `-` with nothing on the line or below
        case valueOnNextLine            // a scalar value on the line after its key
        case multilinePlainScalar       // a plain scalar continued onto the next line
        case bareScalar                 // a scalar line with no key or dash inside a collection
        case contentAfterRootScalar     // a line after a document's root scalar

        // Mappings and keys (spec §6).
        case spaceBeforeColon
        case colonSpacing               // not exactly one space after the colon
        case dashSpacing                // not exactly one space after a sequence dash
        case duplicateKey
        case keyTooLong                 // more than 1024 characters
        case nonStringKey               // an unquoted key that resolves to a non-string
        case complexKey                 // `? key`
        case emptyKey                   // `: value`; an empty key must be quoted

        // Flow style (spec §8).
        case flowCollection             // non-empty, or spaced like `[ ]`

        // Unsupported YAML features (spec §24).
        case anchor
        case alias
        case tag
        case reservedIndicator          // `@`, a backtick, or `%` where no scalar may start

        // Quoted scalars (spec §17–§19).
        case unterminatedQuote
        case contentAfterQuote
        case invalidEscape
        case invalidUnicodeEscape       // surrogates and values past U+10FFFF

        // Block scalars (spec §20, §21).
        case blockIndentationIndicator  // `|2`
        case contentOnBlockHeader
        case blockScalarIndentation     // first content line not exactly two spaces deeper
        case emptyBlockScalar           // a header with no non-blank content line

        // Scalar typing (spec §11–§16).
        case booleanCase                // `True`, `FALSE`
        case nullSpelling               // `Null`, `NULL`, `~`
        case unaryPlus
        case nonDecimalInteger          // hexadecimal, octal, binary
        case numericUnderscore
        case notANumber
        case infinityCase               // `.Inf`, `.INF`
        case integerOutOfRange          // outside signed 64-bit
        case floatOutOfRange            // a finite spelling that rounds to infinity

        // Decoding into Codable types.
        case typeMismatch
        case missingKey
        case unknownKey
    }

    public let code: Code
    public let span: ByteSpan
    public let message: String
    // A suggested fix, shown after the message ("quote it: \"True\"", "did you mean `inline`?").
    public let fix: String?

    public init(_ code: Code, _ span: ByteSpan, _ message: String, fix: String? = nil) {
        self.code = code
        self.span = span
        self.message = message
        self.fix = fix
    }

    // `file:line:col: error: message; fix`, matching the compiler's diagnostic format.
    public func render(file: String, lines: LineIndex) -> String {
        let (line, column) = lines.location(of: span.start)
        let suffix = fix.map { "; \($0)" } ?? ""
        return "\(file):\(line):\(column): error: \(message)\(suffix)"
    }
}

// The errors from one parse, in source order. A parse stops collecting at `limit`; `truncated` says more
// were found.
public struct YAMLErrors: Error, Equatable {
    public static let limit = 100

    public private(set) var errors: [YAMLError] = []
    public private(set) var truncated = false

    public init() {}

    public var isEmpty: Bool { errors.isEmpty }
    public var isFull: Bool { errors.count >= YAMLErrors.limit }

    // Records an error; past the limit, notes the truncation instead. Returns false once full, so a stage
    // can stop early.
    @discardableResult
    public mutating func report(_ error: YAMLError) -> Bool {
        guard !isFull else {
            truncated = true
            return false
        }
        errors.append(error)
        return !isFull
    }

    // One rendered line per error, plus a closing note when the list was truncated.
    public func render(file: String, lines: LineIndex) -> String {
        var out = errors.map { $0.render(file: file, lines: lines) }
        if truncated {
            out.append("\(file): note: stopped after \(YAMLErrors.limit) errors")
        }
        return out.joined(separator: "\n")
    }
}
