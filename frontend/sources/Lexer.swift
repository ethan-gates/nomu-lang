import Foundation

public enum TokenKind: Equatable {
    // Literals
    case intLit(Int)
    case boolLit(Bool)

    // Identifiers
    case ident(String)

    // Keywords
    case kwStruct, kwEnum, kwClass, kwActor
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

    case eof
}

public struct Token {
    public let kind: TokenKind
    public let line: Int
}

extension Token: CustomStringConvertible {
    public var description: String { "\(line): \(kind)" }
}

public struct Lexer {
    private let src: [Character]
    private var pos: Int = 0
    private var line: Int = 1

    public init(_ source: String) {
        src = Array(source)
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
        guard pos < src.count else { return Token(kind: .eof, line: line) }

        let startLine = line
        let c = src[pos]

        if c.isNumber { return lexInt(startLine) }
        if c.isLetter || c == "_" { return lexIdent(startLine) }

        pos += 1
        switch c {
        case "{": return Token(kind: .lBrace, line: startLine)
        case "}": return Token(kind: .rBrace, line: startLine)
        case "(": return Token(kind: .lParen, line: startLine)
        case ")": return Token(kind: .rParen, line: startLine)
        case ":": return Token(kind: .colon, line: startLine)
        case ".": return Token(kind: .dot, line: startLine)
        case ",": return Token(kind: .comma, line: startLine)
        case "+":
            if peek() == "=" { pos += 1; return Token(kind: .plusEq, line: startLine) }
            return Token(kind: .plus, line: startLine)
        case "-":
            if peek() == ">" { pos += 1; return Token(kind: .arrow, line: startLine) }
            return Token(kind: .minus, line: startLine)
        case "*": return Token(kind: .star, line: startLine)
        case "/": return Token(kind: .slash, line: startLine)
        case "=":
            if peek() == "=" { pos += 1; return Token(kind: .eqEq, line: startLine) }
            return Token(kind: .eq, line: startLine)
        case "!":
            guard peek() == "=" else { error("unexpected character '!'", line: startLine) }
            pos += 1; return Token(kind: .bangEq, line: startLine)
        case "<":
            if peek() == "=" { pos += 1; return Token(kind: .ltEq, line: startLine) }
            return Token(kind: .lt, line: startLine)
        case ">":
            if peek() == "=" { pos += 1; return Token(kind: .gtEq, line: startLine) }
            return Token(kind: .gt, line: startLine)
        default:
            error("unexpected character '\(c)'", line: startLine)
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while pos < src.count {
            let c = src[pos]
            if c == "\n" {
                line += 1; pos += 1
            } else if c.isWhitespace {
                pos += 1
            } else if c == "/" && pos + 1 < src.count && src[pos + 1] == "/" {
                while pos < src.count && src[pos] != "\n" { pos += 1 }
            } else {
                break
            }
        }
    }

    private mutating func lexInt(_ startLine: Int) -> Token {
        var value = 0
        while pos < src.count && src[pos].isNumber {
            value = value * 10 + src[pos].wholeNumberValue!
            pos += 1
        }
        return Token(kind: .intLit(value), line: startLine)
    }

    private mutating func lexIdent(_ startLine: Int) -> Token {
        var text = ""
        while pos < src.count && (src[pos].isLetter || src[pos].isNumber || src[pos] == "_") {
            text.append(src[pos])
            pos += 1
        }
        let kind: TokenKind = switch text {
        case "struct":  .kwStruct
        case "enum":    .kwEnum
        case "class":   .kwClass
        case "actor":   .kwActor
        case "fun":     .kwFunc
        case "let":     .kwLet
        case "var":     .kwVar
        case "on":      .kwOn
        case "spawn":   .kwSpawn
        case "switch":  .kwSwitch
        case "case":    .kwCase
        case "return":  .kwReturn
        case "if":      .kwIf
        case "else":    .kwElse
        case "in":      .kwIn
        case "true":    .boolLit(true)
        case "false":   .boolLit(false)
        default:        .ident(text)
        }
        return Token(kind: kind, line: startLine)
    }

    private func peek() -> Character? {
        guard pos < src.count else { return nil }
        return src[pos]
    }

    private func error(_ msg: String, line: Int) -> Never {
        fputs("error:\(line): \(msg)\n", stderr)
        exit(1)
    }
}
