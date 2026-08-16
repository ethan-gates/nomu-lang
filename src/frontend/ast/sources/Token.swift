import support
// Tokens — the lexer's output, the interface between lex and parse. Kept in the `ast` module
// (the syntactic interface) so `parse` (Lexer, Parser) depends on the format, not vice versa.

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
