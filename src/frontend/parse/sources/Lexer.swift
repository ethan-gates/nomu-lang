import support
import ast

// The lexer scans over the source's UTF-8 bytes (`[UInt8]`), not `[Character]`. Tokens are ASCII, so
// classification and dispatch are integer byte compares. Identifiers are ASCII `[A-Za-z_][A-Za-z0-9_]*`;
// string literals and comments carry arbitrary UTF-8 through unchanged. Offsets, spans, and
// line/column are all in byte units — identical to character units for ASCII source.
public struct Lexer {
    private let src: [UInt8]
    // Owns the file name + line table; spans reference it and resolve line/column lazily. Tokens
    // carry only byte offsets, so no line/column is computed while lexing.
    public let map: SourceMap
    private var pos: Int = 0
    // Errors are collected, not fatal: an unexpected byte is reported and skipped so lexing
    // continues (the no-crash contract — frontend/README.md P0). A reference type, so the driver
    // can share one sink across the lexer and parser.
    private let diags: DiagnosticSink

    // `displayName` is the path reported for the file when it differs from its identity `file`, and
    // `debugName` the path debug info records (see `SourceMap`).
    public init(_ source: String, file: String = "<input>", displayName: String? = nil, debugName: String? = nil,
                diagnostics: DiagnosticSink = DiagnosticSink()) {
        let bytes = Array(source.utf8)
        src = bytes
        map = SourceMap(name: file, bytes: bytes, displayName: displayName, debugName: debugName)
        self.diags = diagnostics
    }

    public mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while true {
            let tok = next()
            tokens.append(tok)
            if tok.kind == .eof { break }
        }
        return tokens
    }

    // MARK: - Byte classification (ASCII)

    @inline(__always) private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }        // 0-9
    @inline(__always) private func isAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)                                      // A-Z a-z
    }
    @inline(__always) private func isIdentStartASCII(_ b: UInt8) -> Bool { isAlpha(b) || b == 0x5F }   // _ = 0x5F
    @inline(__always) private func isIdentContASCII(_ b: UInt8) -> Bool { isAlpha(b) || isDigit(b) || b == 0x5F }
    @inline(__always) private func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C   // space, tab, LF, CR, VT, FF
    }

    // Decode one UTF-8 scalar at `i`, returning it with its byte length (1–4); nil for a malformed or
    // truncated sequence. The source is valid UTF-8 (from `String.utf8`), so this succeeds for any
    // well-formed input; the guards keep a bad byte non-fatal rather than trapping.
    private func decodeScalar(at i: Int) -> (Unicode.Scalar, Int)? {
        let b0 = src[i]
        if b0 < 0x80 { return (Unicode.Scalar(b0), 1) }
        let len: Int
        var cp: UInt32
        if b0 & 0xE0 == 0xC0 { len = 2; cp = UInt32(b0 & 0x1F) }
        else if b0 & 0xF0 == 0xE0 { len = 3; cp = UInt32(b0 & 0x0F) }
        else if b0 & 0xF8 == 0xF0 { len = 4; cp = UInt32(b0 & 0x07) }
        else { return nil }
        guard i + len <= src.count else { return nil }
        for k in 1..<len {
            let bc = src[i + k]
            guard bc & 0xC0 == 0x80 else { return nil }
            cp = (cp << 6) | UInt32(bc & 0x3F)
        }
        guard let scalar = Unicode.Scalar(cp) else { return nil }
        return (scalar, len)
    }

    // MARK: - Scanning

    private mutating func next() -> Token {
        // Loop past any bytes that produced no token (reported + skipped), so a bad byte never
        // yields a spurious token and never stalls tokenization.
        while true {
            skipWhitespaceAndComments()
            let start = pos
            if let kind = scanKind() {
                return Token(kind: kind, span: Span(startOffset: start, endOffset: pos, map: map))
            }
        }
    }

    // Scans one token's kind, advancing `pos` past it. Returns nil when it reported an error and
    // skipped the offending byte — the caller retries for the next token.
    private mutating func scanKind() -> TokenKind? {
        guard pos < src.count else { return .eof }

        let c = src[pos]
        if isDigit(c) { return lexNumber() }
        if isIdentStartASCII(c) { return lexIdent() }
        if c == 0x22 {   // "
            if pos + 2 < src.count && src[pos + 1] == 0x22 && src[pos + 2] == 0x22 {
                return lexBlockString()   // """ … """
            }
            return lexString()
        }

        pos += 1
        switch c {
        case 0x7B: return .lBrace     // {
        case 0x7D: return .rBrace     // }
        case 0x28: return .lParen     // (
        case 0x29: return .rParen     // )
        case 0x5B: return .lBracket   // [
        case 0x5D: return .rBracket   // ]
        case 0x3A: return .colon      // :
        case 0x2E: return .dot        // .
        case 0x2C: return .comma      // ,
        case 0x2B:                    // +
            if peek() == 0x3D { pos += 1; return .plusEq }   // =
            return .plus
        case 0x2D:                    // -
            if peek() == 0x3E { pos += 1; return .arrow }    // >
            return .minus
        case 0x2A: return .star       // *
        case 0x2F: return .slash      // /
        case 0x25: return .percent    // %
        case 0x3D:                    // =
            if peek() == 0x3D { pos += 1; return .eqEq }
            return .eq
        case 0x21:                    // !
            if peek() == 0x3D { pos += 1; return .bangEq }
            return .bang
        case 0x3C:                    // <
            if peek() == 0x3D { pos += 1; return .ltEq }
            return .lt
        case 0x3E:                    // >
            if peek() == 0x3D { pos += 1; return .gtEq }
            return .gt
        case 0x26:                    // &
            if peek() == 0x26 { pos += 1; return .ampAmp }   // && logical-and
            return .amp
        case 0x7C:                    // |
            if peek() == 0x7C { pos += 1; return .pipePipe } // || logical-or
            return .pipe
        case 0x5E: return .caret      // ^
        case 0x7E: return .tilde      // ~
        default:
            // Unhandled. A non-ASCII byte begins a multibyte scalar, which appears only in comments and
            // string literals: consume the whole scalar and report it once, not per byte.
            if c >= 0x80 {
                pos -= 1
                let n = decodeScalar(at: pos)?.1 ?? 1
                error("unexpected character \(describeScalar(at: pos))", at: pos)
                pos += n
            } else {
                error("unexpected character \(describe(c))", at: pos - 1)
            }
            return nil
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while pos < src.count {
            let c = src[pos]
            if isSpace(c) {
                pos += 1
            } else if c == 0x2F && pos + 1 < src.count && src[pos + 1] == 0x2F {   // //
                while pos < src.count && src[pos] != 0x0A { pos += 1 }
            } else {
                break
            }
        }
    }

    // A run of digits is an `Int`. A following `.` is read by the byte after it:
    //   - a digit  → a `Double` literal (`3.14`, `0.5`);
    //   - a letter or `_` → member access, so the dot is left for the parser (`3.foo`, `5.double`);
    //   - anything else (EOF, space, operator, another `.`) → a bare `3.`, which is malformed: the
    //     author meant either a `Double` (`3.0`) or a member access (`3.name`). Report and skip the dot.
    private mutating func lexNumber() -> TokenKind {
        let start = pos
        while pos < src.count && isDigit(src[pos]) { pos += 1 }
        let digitsEnd = pos
        if pos < src.count && src[pos] == 0x2E {   // .
            let hasNext = pos + 1 < src.count
            if hasNext && isDigit(src[pos + 1]) {
                pos += 1                            // the '.'
                while pos < src.count && isDigit(src[pos]) { pos += 1 }
                return .doubleLit(Double(slice(start, pos))!)
            }
            // A member name after the dot leaves it for the parser (`3.foo`); anything else is a bare `3.`.
            if !(hasNext && isIdentStartASCII(src[pos + 1])) {
                let digits = slice(start, digitsEnd)
                error("a bare '\(digits).' is not a number: write '\(digits).0' for a Double, or '\(digits).<name>' for member access", at: pos)
                pos += 1                            // skip the stray '.' so it doesn't cascade
            }
        }
        return .intLit(Int(slice(start, digitsEnd))!)
    }

    private mutating func lexIdent() -> TokenKind {
        let start = pos
        // The first byte is an identifier start (checked by scanKind).
        while pos < src.count && isIdentContASCII(src[pos]) { pos += 1 }
        // Keywords are matched on the byte range with no allocation, so only real identifiers build a
        // String.
        if let kw = keyword(start, pos) { return kw }
        return .ident(slice(start, pos))
    }

    // Match the byte range [lo, hi) against the (all-ASCII) keyword set without allocating: switch on
    // length, then compare bytes. Returns nil for an identifier.
    private func keyword(_ lo: Int, _ hi: Int) -> TokenKind? {
        switch hi - lo {
        case 2:
            if eq(lo, "on") { return .kwOn }
            if eq(lo, "if") { return .kwIf }
            if eq(lo, "in") { return .kwIn }
        case 3:
            if eq(lo, "fun") { return .kwFunc }
            if eq(lo, "let") { return .kwLet }
            if eq(lo, "var") { return .kwVar }
        case 4:
            if eq(lo, "enum") { return .kwEnum }
            if eq(lo, "case") { return .kwCase }
            if eq(lo, "else") { return .kwElse }
            if eq(lo, "true") { return .boolLit(true) }
        case 5:
            if eq(lo, "class") { return .kwClass }
            if eq(lo, "actor") { return .kwActor }
            if eq(lo, "spawn") { return .kwSpawn }
            if eq(lo, "while") { return .kwWhile }
            if eq(lo, "break") { return .kwBreak }
            if eq(lo, "false") { return .boolLit(false) }
        case 6:
            if eq(lo, "struct") { return .kwStruct }
            if eq(lo, "switch") { return .kwSwitch }
            if eq(lo, "return") { return .kwReturn }
            if eq(lo, "static") { return .kwStatic }
        case 8:
            if eq(lo, "continue") { return .kwContinue }
        case 9:
            if eq(lo, "interface") { return .kwInterface }
            if eq(lo, "extension") { return .kwExtension }
        default:
            break
        }
        return nil
    }

    // Byte-compare the range starting at `lo` against a keyword literal (length already matched).
    private func eq(_ lo: Int, _ s: StaticString) -> Bool {
        s.withUTF8Buffer { buf in
            for k in 0..<buf.count where src[lo + k] != buf[k] { return false }
            return true
        }
    }

    private mutating func lexString() -> TokenKind {
        let startOffset = pos
        pos += 1  // consume opening "
        var buf: [UInt8] = []
        while pos < src.count && src[pos] != 0x22 {   // "
            if src[pos] == 0x5C && pos + 1 < src.count {   // backslash
                pos += 1
                switch src[pos] {
                case 0x6E: buf.append(0x0A)   // \n
                case 0x74: buf.append(0x09)   // \t
                case 0x5C: buf.append(0x5C)   // \\
                case 0x22: buf.append(0x22)   // \"
                default:   buf.append(src[pos])   // unknown escape: the byte, literally
                }
            } else {
                buf.append(src[pos])
            }
            pos += 1
        }
        guard pos < src.count else {
            // Ran off the end without a closing quote: report and take what we have, so the rest of
            // the token stream (up to EOF) is still usable.
            error("unterminated string literal", at: startOffset)
            return .stringLit(String(decoding: buf, as: UTF8.self))
        }
        pos += 1  // consume closing "
        return .stringLit(String(decoding: buf, as: UTF8.self))
    }

    // A triple-quoted block string literal, Swift-style. The opening `"""` is followed by a newline; the
    // closing `"""` sits on its own line, and the whitespace before it sets the indentation stripped from
    // every content line. The newlines adjacent to the delimiters are dropped, a bare `"` needs no escape,
    // and `\n`/`\t`/`\\`/`\"` escapes still apply. Emits the same `.stringLit` token as `"…"`, so nothing
    // downstream changes. (Line-continuation `\` at end of line is not special yet — a possible follow-on.)
    private mutating func lexBlockString() -> TokenKind {
        let startOffset = pos
        pos += 3   // consume opening """
        // The opening delimiter must be followed by (optional trailing spaces/tabs/CR, then) a newline.
        while pos < src.count && (src[pos] == 0x20 || src[pos] == 0x09 || src[pos] == 0x0D) { pos += 1 }
        if pos < src.count && src[pos] == 0x0A { pos += 1 }
        else { error("opening \"\"\" of a multiline string must be followed by a newline", at: startOffset) }

        // Collect raw bytes up to the first closing `"""`, tracking where the current line began so the
        // closing delimiter's indentation can be measured.
        var raw: [UInt8] = []
        var lineStart = 0
        var closed = false
        while pos < src.count {
            if src[pos] == 0x22 && pos + 2 < src.count && src[pos + 1] == 0x22 && src[pos + 2] == 0x22 {
                pos += 3
                closed = true
                break
            }
            raw.append(src[pos])
            if src[pos] == 0x0A { lineStart = raw.count }
            pos += 1
        }
        guard closed else {
            error("unterminated multiline string literal (missing closing \"\"\")", at: startOffset)
            return .stringLit(String(decoding: raw, as: UTF8.self))
        }

        // The closing line (raw[lineStart...]) must be whitespace only; its length is the strip width.
        var indent = 0
        var allWhitespace = true
        for k in lineStart..<raw.count {
            if raw[k] == 0x20 || raw[k] == 0x09 { indent += 1 } else { allWhitespace = false; break }
        }
        if !allWhitespace { error("closing \"\"\" of a multiline string must be on its own line", at: startOffset) }

        // Content is everything before the closing line, minus the newline that ends it (delimiter-adjacent).
        var content = Array(raw[0..<lineStart])
        if content.last == 0x0A { content.removeLast() }
        if content.last == 0x0D { content.removeLast() }

        // Strip `indent` leading whitespace per line, drop CR of CRLF, then apply escapes.
        var out: [UInt8] = []
        var i = 0
        var atLineStart = true
        var stripped = 0
        while i < content.count {
            let byte = content[i]
            if atLineStart && (byte == 0x20 || byte == 0x09) && stripped < indent {
                stripped += 1; i += 1; continue
            }
            atLineStart = false
            if byte == 0x0D && i + 1 < content.count && content[i + 1] == 0x0A { i += 1; continue }
            if byte == 0x0A {
                out.append(0x0A); atLineStart = true; stripped = 0; i += 1; continue
            }
            if byte == 0x5C && i + 1 < content.count {   // backslash escape
                i += 1
                switch content[i] {
                case 0x6E: out.append(0x0A)   // \n
                case 0x74: out.append(0x09)   // \t
                case 0x5C: out.append(0x5C)   // \\
                case 0x22: out.append(0x22)   // \"
                default:   out.append(content[i])
                }
                i += 1; continue
            }
            out.append(byte); i += 1
        }
        return .stringLit(String(decoding: out, as: UTF8.self))
    }

    // MARK: - Helpers

    // The next byte without consuming it; 0 past end (never a valid token byte).
    private func peek() -> UInt8 {
        pos < src.count ? src[pos] : 0
    }

    // Decode the byte range [lo, hi) as a UTF-8 string (identifiers, literals, error text).
    private func slice(_ lo: Int, _ hi: Int) -> String {
        String(decoding: src[lo..<hi], as: UTF8.self)
    }

    // A byte rendered for a diagnostic: printable ASCII as its character, else its hex value.
    private func describe(_ b: UInt8) -> String {
        (b >= 0x20 && b < 0x7F) ? "'\(Character(UnicodeScalar(b)))'" : "byte 0x\(String(b, radix: 16))"
    }

    // The (multibyte) scalar at `i` rendered for a diagnostic, or its lead byte if malformed.
    private func describeScalar(at i: Int) -> String {
        if let (s, _) = decodeScalar(at: i) { return "'\(Character(s))'" }
        return "byte 0x\(String(src[i], radix: 16))"
    }

    private func error(_ msg: String, at offset: Int) {
        diags.error(msg, at: Span(startOffset: offset, endOffset: offset, map: map))
    }
}
