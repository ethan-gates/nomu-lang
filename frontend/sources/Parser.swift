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
        let line = currentLine
        expect(.kwStruct)
        let name = expectIdent()
        expect(.lBrace)
        var fields: [VarField] = []
        while !check(.rBrace) && !check(.eof) {
            fields.append(parseVarField())
        }
        expect(.rBrace)
        return StructDecl(name: name, fields: fields, line: line)
    }

    private mutating func parseEnumDecl() -> EnumDecl {
        let line = currentLine
        expect(.kwEnum)
        let name = expectIdent()
        expect(.lBrace)
        var cases: [EnumCaseDecl] = []
        while !check(.rBrace) && !check(.eof) {
            cases.append(parseEnumCaseDecl())
        }
        expect(.rBrace)
        return EnumDecl(name: name, cases: cases, line: line)
    }

    private mutating func parseEnumCaseDecl() -> EnumCaseDecl {
        let line = currentLine
        expect(.kwCase)
        let name = expectIdent()
        var fields: [VarField] = []
        if eat(.lParen) {
            repeat {
                let fline = currentLine
                let fname = expectIdent()
                expect(.colon)
                let ftype = parseTypeRef()
                fields.append(VarField(name: fname, type: ftype, line: fline))
            } while eat(.comma)
            expect(.rParen)
        }
        return EnumCaseDecl(name: name, fields: fields, line: line)
    }

    private mutating func parseClassDecl() -> ClassDecl {
        let line = currentLine
        expect(.kwClass)
        let name = expectIdent()
        expect(.lBrace)
        var fields: [VarField] = []
        while check(.kwVar) {
            fields.append(parseVarField())
        }
        expect(.rBrace)
        return ClassDecl(name: name, fields: fields, line: line)
    }

    private mutating func parseActorDecl() -> ActorDecl {
        let line = currentLine
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
        return ActorDecl(name: name, fields: fields, handlers: handlers, line: line)
    }

    private mutating func parseFuncDecl() -> FuncDecl {
        let line = currentLine
        expect(.kwFunc)
        let name = expectIdent()
        let params = parseParamList()
        var returnType: TypeRef? = nil
        if eat(.arrow) {
            returnType = parseTypeRef()
        }
        let body = parseBlock()
        return FuncDecl(name: name, params: params, returnType: returnType, body: body, line: line)
    }

    // MARK: - Fields and params

    private mutating func parseVarField() -> VarField {
        let line = currentLine
        expect(.kwVar)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        return VarField(name: name, type: type, line: line)
    }

    private mutating func parseActorField() -> ActorField {
        let line = currentLine
        expect(.kwVar)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        var initializer: Expr? = nil
        if eat(.eq) {
            initializer = parseExpr()
        }
        return ActorField(name: name, type: type, initializer: initializer, line: line)
    }

    private mutating func parseOnHandler() -> OnHandler {
        let line = currentLine
        expect(.kwOn)
        let name = expectIdent()
        let params = parseParamList()
        let body = parseBlock()
        return OnHandler(name: name, params: params, body: body, line: line)
    }

    private mutating func parseParamList() -> [Param] {
        expect(.lParen)
        var params: [Param] = []
        while !check(.rParen) && !check(.eof) {
            if !params.isEmpty { expect(.comma) }
            let line = currentLine
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
            params.append(Param(label: label, name: name, type: type, line: line))
        }
        expect(.rParen)
        return params
    }

    private mutating func parseTypeRef() -> TypeRef {
        let line = currentLine
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
            return TypeRef(name: renderFnType(params, ret), fn: FnType(params: params, ret: ret), line: line)
        }
        let name = expectIdent()
        return TypeRef(name: name, line: line)
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
        case .kwSend:   return parseSend()
        case .kwJoin:   return parseJoin()
        default:        return parseExprOrAssign()
        }
    }

    private mutating func parseBinding(isMutable: Bool) -> Stmt {
        let line = currentLine
        advance()  // consume let/var
        let name = expectIdent()
        var type: TypeRef? = nil
        if eat(.colon) {
            type = parseTypeRef()
        }
        expect(.eq)
        let value = parseExpr()
        return .binding(BindingStmt(isMutable: isMutable, name: name, type: type, value: value, line: line))
    }

    private mutating func parseReturn() -> Stmt {
        let line = currentLine
        expect(.kwReturn)
        // Return has an expression unless followed by a statement terminator
        let expr: Expr? = (check(.rBrace) || check(.kwCase) || check(.eof)) ? nil : parseExpr()
        return .ret(expr, line: line)
    }

    private mutating func parseIfStmt() -> Stmt {
        let line = currentLine
        expect(.kwIf)
        let cond = parseExpr()
        let thenBody = parseBlock()
        var elseBody: Block? = nil
        if eat(.kwElse) {
            // `else if …` chains as a single nested if; `else { … }` is a plain block.
            elseBody = check(.kwIf) ? [parseIfStmt()] : parseBlock()
        }
        return .ifStmt(IfStmt(cond: cond, thenBody: thenBody, elseBody: elseBody, line: line))
    }

    private mutating func parseSwitchStmt() -> Stmt {
        let line = currentLine
        expect(.kwSwitch)
        let subject = parseExpr()
        expect(.lBrace)
        var cases: [CaseArm] = []
        while check(.kwCase) {
            let cline = currentLine
            expect(.kwCase)
            let pattern = parsePattern()
            expect(.colon)
            let body = parseCaseBody()
            cases.append(CaseArm(pattern: pattern, body: body, line: cline))
        }
        expect(.rBrace)
        return .switchStmt(SwitchStmt(subject: subject, cases: cases, line: line))
    }

    private mutating func parsePattern() -> Pattern {
        let line = currentLine
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
        return .enumCase(name: name, bindings: bindings, line: line)
    }

    private mutating func parseSend() -> Stmt {
        let line = currentLine
        expect(.kwSend)
        let expr = parseExpr()
        return .send(expr, line: line)
    }

    private mutating func parseJoin() -> Stmt {
        let line = currentLine
        expect(.kwJoin)
        let expr = parseExpr()
        return .join(expr, line: line)
    }

    private mutating func parseExprOrAssign() -> Stmt {
        let line = currentLine
        let lhs = parseExpr()
        if eat(.eq) {
            return .assign(lhs: lhs, rhs: parseExpr(), line: line)
        }
        if eat(.plusEq) {
            return .compoundAssign(lhs: lhs, rhs: parseExpr(), line: line)
        }
        return .expr(lhs)
    }

    // MARK: - Expressions

    private mutating func parseExpr() -> Expr {
        parseComparison()
    }

    private mutating func parseComparison() -> Expr {
        var lhs = parseAdditive()
        while let op = comparisonOp() {
            let line = currentLine
            advance()
            lhs = .binary(op, lhs, parseAdditive(), line: line)
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
        var lhs = parseMultiplicative()
        while currentKind == .plus || currentKind == .minus {
            let op: BinOp = currentKind == .plus ? .add : .sub
            let line = currentLine
            advance()
            lhs = .binary(op, lhs, parseMultiplicative(), line: line)
        }
        return lhs
    }

    private mutating func parseMultiplicative() -> Expr {
        var lhs = parsePostfix()
        while currentKind == .star || currentKind == .slash {
            let op: BinOp = currentKind == .star ? .mul : .div
            let line = currentLine
            advance()
            lhs = .binary(op, lhs, parsePostfix(), line: line)
        }
        return lhs
    }

    private mutating func parsePostfix() -> Expr {
        var expr = parsePrimary()
        while true {
            let line = currentLine
            if eat(.dot) {
                expr = .member(expr, expectIdent(), line: line)
            } else if check(.lParen) {
                expr = .call(expr, parseArgList(), line: line)
            } else {
                break
            }
        }
        return expr
    }

    private mutating func parsePrimary() -> Expr {
        let line = currentLine
        switch currentKind {
        case .intLit(let v):
            advance(); return .intLit(v, line: line)
        case .boolLit(let v):
            advance(); return .boolLit(v, line: line)
        case .kwSpawn:
            advance()
            let name = expectIdent()
            return .spawn(name, parseArgList(), line: line)
        case .lBrace:
            return parseClosure()
        case .ident(let name):
            advance(); return .ident(name, line: line)
        default:
            error("expected expression, got \(currentKind)")
        }
    }

    // { (x: Int) -> Int in <stmts> }   — return type optional (void if omitted)
    private mutating func parseClosure() -> Expr {
        let line = currentLine
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
        return .closure(params: params, ret: ret, body: body, line: line)
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
    private var currentLine: Int { tokens[pos].line }

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
        fputs("error:\(currentLine): \(msg)\n", stderr)
        exit(1)
    }
}
