import Foundation

public struct Parser {
    private let tokens: [Token]
    private var pos: Int = 0

    public init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    public mutating func parse() -> Program {
        var decls: [TopDecl] = []
        while !check(.eof) {
            decls.append(parseTopDecl())
        }
        return Program(decls: decls)
    }

    // MARK: - Top-level declarations

    private mutating func parseTopDecl() -> TopDecl {
        switch currentKind {
        case .kwStruct: return .structDecl(parseStructDecl())
        case .kwEnum:   return .enumDecl(parseEnumDecl())
        case .kwClass:  return .classDecl(parseClassDecl())
        case .kwActor:  return .actorDecl(parseActorDecl())
        case .kwFunc:   return .funcDecl(parseFuncDecl())
        default:
            error("expected top-level declaration, got \(currentKind)")
        }
    }

    private mutating func parseStructDecl() -> StructDecl {
        let start = currentSpan
        expect(.kwStruct)
        let name = expectIdent()
        expect(.lBrace)
        var fields: [VarField] = []
        while !check(.rBrace) && !check(.eof) {
            fields.append(parseVarField())
        }
        expect(.rBrace)
        return StructDecl(name: name, fields: fields, span: spanFrom(start))
    }

    private mutating func parseEnumDecl() -> EnumDecl {
        let start = currentSpan
        expect(.kwEnum)
        let name = expectIdent()
        expect(.lBrace)
        var cases: [EnumCaseDecl] = []
        while !check(.rBrace) && !check(.eof) {
            cases.append(parseEnumCaseDecl())
        }
        expect(.rBrace)
        return EnumDecl(name: name, cases: cases, span: spanFrom(start))
    }

    private mutating func parseEnumCaseDecl() -> EnumCaseDecl {
        let start = currentSpan
        expect(.kwCase)
        let name = expectIdent()
        var fields: [VarField] = []
        if eat(.lParen) {
            repeat {
                let fstart = currentSpan
                let fname = expectIdent()
                expect(.colon)
                let ftype = parseTypeRef()
                fields.append(VarField(name: fname, type: ftype, span: spanFrom(fstart)))
            } while eat(.comma)
            expect(.rParen)
        }
        return EnumCaseDecl(name: name, fields: fields, span: spanFrom(start))
    }

    private mutating func parseClassDecl() -> ClassDecl {
        let start = currentSpan
        expect(.kwClass)
        let name = expectIdent()
        expect(.lBrace)
        var fields: [VarField] = []
        while check(.kwVar) {
            fields.append(parseVarField())
        }
        expect(.rBrace)
        return ClassDecl(name: name, fields: fields, span: spanFrom(start))
    }

    private mutating func parseActorDecl() -> ActorDecl {
        let start = currentSpan
        expect(.kwActor)
        let name = expectIdent()
        expect(.lBrace)
        var fields: [ActorField] = []
        var handlers: [OnHandler] = []
        while !check(.rBrace) && !check(.eof) {
            if check(.kwVar) {
                fields.append(parseActorField())
            } else if check(.kwOn) {
                handlers.append(parseOnHandler())
            } else {
                error("expected 'var' or 'on' in actor body, got \(currentKind)")
            }
        }
        expect(.rBrace)
        return ActorDecl(name: name, fields: fields, handlers: handlers, span: spanFrom(start))
    }

    private mutating func parseFuncDecl() -> FuncDecl {
        let start = currentSpan
        expect(.kwFunc)
        let name = expectIdent()
        let params = parseParamList()
        var returnType: TypeRef? = nil
        if eat(.arrow) {
            returnType = parseTypeRef()
        }
        let body = parseBlock()
        return FuncDecl(name: name, params: params, returnType: returnType, body: body, span: spanFrom(start))
    }

    // MARK: - Fields and params

    private mutating func parseVarField() -> VarField {
        let start = currentSpan
        expect(.kwVar)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        return VarField(name: name, type: type, span: spanFrom(start))
    }

    private mutating func parseActorField() -> ActorField {
        let start = currentSpan
        expect(.kwVar)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        var initializer: Expr? = nil
        if eat(.eq) {
            initializer = parseExpr()
        }
        return ActorField(name: name, type: type, initializer: initializer, span: spanFrom(start))
    }

    private mutating func parseOnHandler() -> OnHandler {
        let start = currentSpan
        expect(.kwOn)
        let name = expectIdent()
        let params = parseParamList()
        var returnType: TypeRef? = nil
        if eat(.arrow) { returnType = parseTypeRef() }
        let body = parseBlock()
        return OnHandler(name: name, params: params, returnType: returnType, body: body, span: spanFrom(start))
    }

    private mutating func parseParamList() -> [Param] {
        expect(.lParen)
        var params: [Param] = []
        while !check(.rParen) && !check(.eof) {
            if !params.isEmpty { expect(.comma) }
            let start = currentSpan
            let label = expectIdent()
            // Support `label name: Type` or `label: Type` (label == name)
            let name: String
            if case .ident(_) = currentKind, peek() == .colon {
                name = expectIdent()
            } else {
                name = label
            }
            expect(.colon)
            let type = parseTypeRef()
            params.append(Param(label: label, name: name, type: type, span: spanFrom(start)))
        }
        expect(.rParen)
        return params
    }

    private mutating func parseTypeRef() -> TypeRef {
        let start = currentSpan
        if check(.lParen) {
            // Function type: (T1, T2) -> R
            expect(.lParen)
            var params: [TypeRef] = []
            while !check(.rParen) && !check(.eof) {
                if !params.isEmpty { expect(.comma) }
                params.append(parseTypeRef())
            }
            expect(.rParen)
            expect(.arrow)
            let ret = parseTypeRef()
            return TypeRef(name: renderFnType(params, ret), fn: FnType(params: params, ret: ret), span: spanFrom(start))
        }
        let name = expectIdent()
        return TypeRef(name: name, span: spanFrom(start))
    }

    private func renderFnType(_ params: [TypeRef], _ ret: TypeRef?) -> String {
        "(" + params.map(\.name).joined(separator: ", ") + ") -> " + (ret?.name ?? "Void")
    }

    // MARK: - Statements

    private mutating func parseBlock() -> Block {
        expect(.lBrace)
        var stmts: [Stmt] = []
        while !check(.rBrace) && !check(.eof) {
            stmts.append(parseStmt())
        }
        expect(.rBrace)
        return stmts
    }

    private mutating func parseCaseBody() -> Block {
        var stmts: [Stmt] = []
        while !check(.kwCase) && !check(.rBrace) && !check(.eof) {
            stmts.append(parseStmt())
        }
        return stmts
    }

    private mutating func parseStmt() -> Stmt {
        switch currentKind {
        case .kwLet:    return parseBinding(isMutable: false)
        case .kwVar:    return parseBinding(isMutable: true)
        case .kwReturn: return parseReturn()
        case .kwIf:     return parseIfStmt()
        case .kwSwitch: return parseSwitchStmt()
        case .kwSpawn where peek() == .kwLet: return parseSpawnLet()
        default:        return parseExprOrAssign()
        }
    }

    // spawn let x [: T] = expr  — runs expr concurrently; reading x joins.
    private mutating func parseSpawnLet() -> Stmt {
        let start = currentSpan
        expect(.kwSpawn)
        expect(.kwLet)
        let name = expectIdent()
        var type: TypeRef? = nil
        if eat(.colon) { type = parseTypeRef() }
        expect(.eq)
        let value = parseExpr()
        return .spawnLet(name: name, type: type, value: value, span: spanFrom(start))
    }

    private mutating func parseBinding(isMutable: Bool) -> Stmt {
        let start = currentSpan
        advance()  // consume let/var
        let name = expectIdent()
        var type: TypeRef? = nil
        if eat(.colon) {
            type = parseTypeRef()
        }
        expect(.eq)
        let value = parseExpr()
        return .binding(BindingStmt(isMutable: isMutable, name: name, type: type, value: value, span: spanFrom(start)))
    }

    private mutating func parseReturn() -> Stmt {
        let start = currentSpan
        expect(.kwReturn)
        // Return has an expression unless followed by a statement terminator
        let expr: Expr? = (check(.rBrace) || check(.kwCase) || check(.eof)) ? nil : parseExpr()
        return .ret(expr, span: spanFrom(start))
    }

    private mutating func parseIfStmt() -> Stmt {
        let start = currentSpan
        expect(.kwIf)
        let cond = parseExpr()
        let thenBody = parseBlock()
        var elseBody: Block? = nil
        if eat(.kwElse) {
            // `else if …` chains as a single nested if; `else { … }` is a plain block.
            elseBody = check(.kwIf) ? [parseIfStmt()] : parseBlock()
        }
        return .ifStmt(IfStmt(cond: cond, thenBody: thenBody, elseBody: elseBody, span: spanFrom(start)))
    }

    private mutating func parseSwitchStmt() -> Stmt {
        let start = currentSpan
        expect(.kwSwitch)
        let subject = parseExpr()
        expect(.lBrace)
        var cases: [CaseArm] = []
        while check(.kwCase) {
            let cstart = currentSpan
            expect(.kwCase)
            let pattern = parsePattern()
            expect(.colon)
            let body = parseCaseBody()
            cases.append(CaseArm(pattern: pattern, body: body, span: spanFrom(cstart)))
        }
        expect(.rBrace)
        return .switchStmt(SwitchStmt(subject: subject, cases: cases, span: spanFrom(start)))
    }

    private mutating func parsePattern() -> Pattern {
        let start = currentSpan
        expect(.dot)
        let name = expectIdent()
        var bindings: [String] = []
        if eat(.lParen) {
            repeat {
                expect(.kwLet)
                bindings.append(expectIdent())
            } while eat(.comma)
            expect(.rParen)
        }
        return .enumCase(name: name, bindings: bindings, span: spanFrom(start))
    }

    private mutating func parseExprOrAssign() -> Stmt {
        let start = currentSpan
        let lhs = parseExpr()
        if eat(.eq) {
            return .assign(lhs: lhs, rhs: parseExpr(), span: spanFrom(start))
        }
        if eat(.plusEq) {
            return .compoundAssign(lhs: lhs, rhs: parseExpr(), span: spanFrom(start))
        }
        return .expr(lhs)
    }

    // MARK: - Expressions

    private mutating func parseExpr() -> Expr {
        parseComparison()
    }

    private mutating func parseComparison() -> Expr {
        let start = currentSpan
        var lhs = parseAdditive()
        while let op = comparisonOp() {
            advance()
            lhs = .binary(op, lhs, parseAdditive(), span: spanFrom(start))
        }
        return lhs
    }

    private func comparisonOp() -> BinOp? {
        switch currentKind {
        case .eqEq:  return .eq
        case .bangEq: return .neq
        case .lt:    return .lt
        case .gt:    return .gt
        case .ltEq:  return .lte
        case .gtEq:  return .gte
        default:     return nil
        }
    }

    private mutating func parseAdditive() -> Expr {
        let start = currentSpan
        var lhs = parseMultiplicative()
        while currentKind == .plus || currentKind == .minus {
            let op: BinOp = currentKind == .plus ? .add : .sub
            advance()
            lhs = .binary(op, lhs, parseMultiplicative(), span: spanFrom(start))
        }
        return lhs
    }

    private mutating func parseMultiplicative() -> Expr {
        let start = currentSpan
        var lhs = parsePostfix()
        while currentKind == .star || currentKind == .slash {
            let op: BinOp = currentKind == .star ? .mul : .div
            advance()
            lhs = .binary(op, lhs, parsePostfix(), span: spanFrom(start))
        }
        return lhs
    }

    private mutating func parsePostfix() -> Expr {
        let start = currentSpan
        var expr = parsePrimary()
        while true {
            if eat(.dot) {
                expr = .member(expr, expectIdent(), span: spanFrom(start))
            } else if check(.lParen) {
                expr = .call(expr, parseArgList(), span: spanFrom(start))
            } else {
                break
            }
        }
        return expr
    }

    private mutating func parsePrimary() -> Expr {
        let start = currentSpan
        switch currentKind {
        case .intLit(let v):
            advance(); return .intLit(v, span: spanFrom(start))
        case .boolLit(let v):
            advance(); return .boolLit(v, span: spanFrom(start))
        case .stringLit(let v):
            advance(); return .stringLit(v, span: spanFrom(start))
        case .lBrace:
            return parseClosure()
        case .ident(let name):
            advance(); return .ident(name, span: spanFrom(start))
        default:
            error("expected expression, got \(currentKind)")
        }
    }

    // { (x: Int) -> Int in <stmts> }   — return type optional (void if omitted)
    private mutating func parseClosure() -> Expr {
        let start = currentSpan
        expect(.lBrace)
        let params = parseParamList()
        var ret: TypeRef? = nil
        if eat(.arrow) { ret = parseTypeRef() }
        expect(.kwIn)
        var body: [Stmt] = []
        while !check(.rBrace) && !check(.eof) {
            body.append(parseStmt())
        }
        expect(.rBrace)
        return .closure(params: params, ret: ret, body: body, span: spanFrom(start))
    }

    private mutating func parseArgList() -> [Arg] {
        expect(.lParen)
        var args: [Arg] = []
        while !check(.rParen) && !check(.eof) {
            if !args.isEmpty { expect(.comma) }
            // IDENT ':' → labeled argument
            if case .ident(let label) = currentKind, peek() == .colon {
                advance()  // label
                advance()  // ':'
                args.append(Arg(label: label, value: parseExpr()))
            } else {
                args.append(Arg(value: parseExpr()))
            }
        }
        expect(.rParen)
        return args
    }

    // MARK: - Helpers

    private var currentKind: TokenKind { tokens[pos].kind }
    private var currentSpan: Span { tokens[pos].span }
    // Span of the most recently consumed token — a node reaches from its start to here.
    private var prevSpan: Span { tokens[pos > 0 ? pos - 1 : 0].span }
    private func spanFrom(_ start: Span) -> Span { Span.merge(start, prevSpan) }

    private func peek(_ offset: Int = 1) -> TokenKind {
        let i = pos + offset
        return i < tokens.count ? tokens[i].kind : .eof
    }

    private mutating func advance() {
        if pos + 1 < tokens.count { pos += 1 }
    }

    @discardableResult
    private mutating func expect(_ kind: TokenKind) -> Token {
        guard currentKind == kind else {
            error("expected \(kind), got \(currentKind)")
        }
        let tok = tokens[pos]
        advance()
        return tok
    }

    private mutating func eat(_ kind: TokenKind) -> Bool {
        guard currentKind == kind else { return false }
        advance()
        return true
    }

    private mutating func expectIdent() -> String {
        guard case .ident(let name) = currentKind else {
            error("expected identifier, got \(currentKind)")
        }
        advance()
        return name
    }

    private func check(_ kind: TokenKind) -> Bool { currentKind == kind }

    private func error(_ msg: String) -> Never {
        let s = currentSpan
        fputs("error:\(s.begin.line):\(s.begin.col): \(msg)\n", stderr)
        exit(1)
    }
}
