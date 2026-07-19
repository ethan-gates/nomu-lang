public enum EmitMode {
    case binary   // lex → parse → check → C → cc → native binary (default)
    case ast      // lex → parse → dump AST
    case c        // lex → parse → check → dump C
}
