import Foundation

public enum TokenKind: Equatable {
    // Literals
    case intLit(Int)
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

    // Punctuation
    case lBrace, rBrace       // { }
    case lParen, rParen       // ( )
    case colon                // :
    case arrow                // ->
    case dot                  // .
    case comma                // ,

    // Operators
    case eq                   // =
    case plusEq               // +=
    case plus, minus, star, slash
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

    public init(_ source: String, file: String = "<input>") {
        src = Array(source)
        self.file = file
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
        skipWhitespaceAndComments()
        let start = pos
        let kind = scanKind()
        return Token(kind: kind, span: Span(file: file, begin: posAt(start), end: posAt(pos)))
    }

    // Scans one token's kind, advancing `pos` past it.
    private mutating func scanKind() -> TokenKind {
        guard pos < src.count else { return .eof }

        let c = src[pos]
        if c.isNumber { return lexInt() }
        if c.isLetter || c == "_" { return lexIdent() }
        if c == "\"" { return lexString() }

        pos += 1
        switch c {
        case "{": return .lBrace
        case "}": return .rBrace
        case "(": return .lParen
        case ")": return .rParen
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
        case "=":
            if peek() == "=" { pos += 1; return .eqEq }
            return .eq
        case "!":
            guard peek() == "=" else { error("unexpected character '!'", at: pos - 1) }
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

    private mutating func lexInt() -> TokenKind {
        var value = 0
        while pos < src.count && src[pos].isNumber {
            value = value * 10 + src[pos].wholeNumberValue!
            pos += 1
        }
        return .intLit(value)
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
        guard pos < src.count else { error("unterminated string literal", at: startOffset) }
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

    private func error(_ msg: String, at offset: Int) -> Never {
        let p = posAt(offset)
        fputs("error:\(p.line):\(p.col): \(msg)\n", stderr)
        exit(1)
    }
}
