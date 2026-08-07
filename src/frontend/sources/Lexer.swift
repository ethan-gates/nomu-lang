import Foundation

public enum TokenKind: Hashable {
    // Literals
    case intLit(Int)
    case doubleLit(Double)
    case boolLit(Bool)
    case stringLit(String)

    // Identifiers
    case ident(String)

    // Keywords
    case kwStruct, kwEnum, kwClass, kwActor
    case kwInterface
    case kwExtension
    case kwFunc, kwLet, kwVar
    case kwOn, kwSpawn
    case kwSwitch, kwCase, kwReturn
    case kwIf, kwElse
    case kwIn
    case kwWhile, kwBreak, kwContinue

    // Punctuation
    case lBrace, rBrace       // { }
    case lParen, rParen       // ( )
    case lBracket, rBracket   // [ ] — array literals and subscripts
    case colon                // :
    case arrow                // ->
    case dot                  // .
    case comma                // ,

    // Operators
    case eq                   // =
    case plusEq               // +=
    case plus, minus, star, slash, percent
    case eqEq, bangEq
    case lt, gt, ltEq, gtEq
    case amp                  // & — interface composition

    case eof
}

public struct Token {
    public let kind: TokenKind
    public let span: Span
    // Convenience for call sites that only need the start line.
    public var line: Int { span.begin.line }

    public init(kind: TokenKind, span: Span) {
        self.kind = kind
        self.span = span
    }
}

extension Token: CustomStringConvertible {
    public var description: String { "\(span.begin.line): \(kind)" }
}

public struct Lexer {
    private let src: [Character]
    private let file: String
    private let lineStarts: [Int]   // char offset of the start of each line
    private var pos: Int = 0
    // Errors are collected, not fatal: an unexpected character is reported and skipped so
    // lexing continues (the no-crash contract — frontend/README.md P0). A reference type,
    // so the driver can share one sink across the lexer and parser.
    private let diags: DiagnosticSink

    public init(_ source: String, file: String = "<input>", diagnostics: DiagnosticSink = DiagnosticSink()) {
        src = Array(source)
        self.file = file
        self.diags = diagnostics
        var starts = [0]
        for (i, c) in src.enumerated() where c == "\n" { starts.append(i + 1) }
        lineStarts = starts
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

    private mutating func next() -> Token {
        // Loop past any characters that produced no token (reported + skipped), so a bad
        // character never yields a spurious token and never stalls tokenization.
        while true {
            skipWhitespaceAndComments()
            let start = pos
            if let kind = scanKind() {
                return Token(kind: kind, span: Span(file: file, begin: posAt(start), end: posAt(pos)))
            }
        }
    }

    // Scans one token's kind, advancing `pos` past it. Returns nil when it reported an
    // error and skipped the offending character — the caller retries for the next token.
    private mutating func scanKind() -> TokenKind? {
        guard pos < src.count else { return .eof }

        let c = src[pos]
        if c.isNumber { return lexNumber() }
        if c.isLetter || c == "_" { return lexIdent() }
        if c == "\"" { return lexString() }

        pos += 1
        switch c {
        case "{": return .lBrace
        case "}": return .rBrace
        case "(": return .lParen
        case ")": return .rParen
        case "[": return .lBracket
        case "]": return .rBracket
        case ":": return .colon
        case ".": return .dot
        case ",": return .comma
        case "+":
            if peek() == "=" { pos += 1; return .plusEq }
            return .plus
        case "-":
            if peek() == ">" { pos += 1; return .arrow }
            return .minus
        case "*": return .star
        case "/": return .slash
        case "%": return .percent
        case "=":
            if peek() == "=" { pos += 1; return .eqEq }
            return .eq
        case "!":
            guard peek() == "=" else { error("unexpected character '!'", at: pos - 1); return nil }
            pos += 1; return .bangEq
        case "<":
            if peek() == "=" { pos += 1; return .ltEq }
            return .lt
        case ">":
            if peek() == "=" { pos += 1; return .gtEq }
            return .gt
        case "&": return .amp
        default:
            error("unexpected character '\(c)'", at: pos - 1)
            return nil
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while pos < src.count {
            let c = src[pos]
            if c.isWhitespace {
                pos += 1
            } else if c == "/" && pos + 1 < src.count && src[pos + 1] == "/" {
                while pos < src.count && src[pos] != "\n" { pos += 1 }
            } else {
                break
            }
        }
    }

    // A run of digits is an `Int`. A following `.` is read by the char after it:
    //   - a digit  → a `Double` literal (`3.14`, `0.5`);
    //   - a letter or `_` → member access, so the dot is left for the parser (`3.foo`, `5.double`);
    //   - anything else (EOF, space, operator, another `.`) → a bare `3.`, which is malformed: the
    //     author meant either a `Double` (`3.0`) or a member access (`3.name`). Report and skip the dot.
    private mutating func lexNumber() -> TokenKind {
        var text = ""
        while pos < src.count && src[pos].isNumber {
            text.append(src[pos])
            pos += 1
        }
        if pos < src.count && src[pos] == "." {
            let after = pos + 1 < src.count ? src[pos + 1] : nil
            if let a = after, a.isNumber {
                text.append("."); pos += 1                  // the '.'
                while pos < src.count && src[pos].isNumber {
                    text.append(src[pos])
                    pos += 1
                }
                return .doubleLit(Double(text)!)
            }
            if after == nil || !(after!.isLetter || after! == "_") {
                error("a bare '\(text).' is not a number: write '\(text).0' for a Double, or '\(text).<name>' for member access", at: pos)
                pos += 1                                     // skip the stray '.' so it doesn't cascade
            }
            // else: a member name follows — leave the '.' for the parser (`3.foo`).
        }
        return .intLit(Int(text)!)
    }

    private mutating func lexIdent() -> TokenKind {
        var text = ""
        while pos < src.count && (src[pos].isLetter || src[pos].isNumber || src[pos] == "_") {
            text.append(src[pos])
            pos += 1
        }
        switch text {
        case "struct":  return .kwStruct
        case "enum":    return .kwEnum
        case "class":   return .kwClass
        case "actor":   return .kwActor
        case "interface": return .kwInterface
        case "extension": return .kwExtension
        case "fun":     return .kwFunc
        case "let":     return .kwLet
        case "var":     return .kwVar
        case "on":      return .kwOn
        case "spawn":   return .kwSpawn
        case "switch":  return .kwSwitch
        case "case":    return .kwCase
        case "return":  return .kwReturn
        case "if":      return .kwIf
        case "else":    return .kwElse
        case "in":      return .kwIn
        case "while":   return .kwWhile
        case "break":   return .kwBreak
        case "continue": return .kwContinue
        case "true":    return .boolLit(true)
        case "false":   return .boolLit(false)
        default:        return .ident(text)
        }
    }

    private mutating func lexString() -> TokenKind {
        let startOffset = pos
        pos += 1  // consume opening "
        var value = ""
        while pos < src.count && src[pos] != "\"" {
            if src[pos] == "\\" && pos + 1 < src.count {
                pos += 1
                switch src[pos] {
                case "n":  value.append("\n")
                case "t":  value.append("\t")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                default:   value.append(src[pos])
                }
            } else {
                value.append(src[pos])
            }
            pos += 1
        }
        guard pos < src.count else {
            // Ran off the end without a closing quote: report and take what we have, so the
            // rest of the token stream (up to EOF) is still usable.
            error("unterminated string literal", at: startOffset)
            return .stringLit(value)
        }
        pos += 1  // consume closing "
        return .stringLit(value)
    }

    private func peek() -> Character? {
        guard pos < src.count else { return nil }
        return src[pos]
    }

    // Converts a character offset into a 1-based line/column via binary search
    // over the line-start table.
    private func posAt(_ offset: Int) -> Pos {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return Pos(line: lo + 1, col: offset - lineStarts[lo] + 1)
    }

    private func error(_ msg: String, at offset: Int) {
        let p = posAt(offset)
        diags.error(msg, at: Span(file: file, begin: p, end: p))
    }
}
