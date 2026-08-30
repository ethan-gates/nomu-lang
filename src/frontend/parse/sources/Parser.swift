import ast
import support
import Foundation

public struct Parser {
    private let tokens: [Token]
    private var pos: Int = 0
    // Errors are collected, not fatal (the no-crash contract — frontend/README.md P0). A
    // shared reference type so the driver can thread one sink through the lexer and parser.
    private let diags: DiagnosticSink
    // Panic mode: once an error is reported, further errors are suppressed until a recovery
    // routine resynchronizes to a known boundary — this collapses one broken construct into
    // a single diagnostic instead of a cascade.
    private var panicking = false

    public init(_ tokens: [Token], diagnostics: DiagnosticSink = DiagnosticSink()) {
        self.tokens = tokens
        self.diags = diagnostics
    }

    public mutating func parse() -> Program {
        var decls: [TopDecl] = []
        while !check(.eof) {
            if let decl = parseTopDecl() { decls.append(decl) }
        }
        return Program(decls: decls)
    }

    // MARK: - Top-level declarations

    // Returns nil when the current token starts no declaration: the token is reported and
    // recovery skips to the next declaration boundary, so later decls still parse.
    private mutating func parseTopDecl() -> TopDecl? {
        switch currentKind {
        case .kwStruct: return .structDecl(parseStructDecl())
        case .kwEnum:   return .enumDecl(parseEnumDecl())
        case .kwClass:  return .classDecl(parseClassDecl())
        case .kwActor:  return .actorDecl(parseActorDecl())
        case .kwInterface: return .interfaceDecl(parseInterfaceDecl())
        case .kwExtension: return .extensionDecl(parseExtensionDecl())
        case .kwFunc:   return .funcDecl(parseFuncDecl())
        default:
            error("expected top-level declaration, got \(currentKind)")
            recover(to: Self.declStart)
            return nil
        }
    }

    // Tokens that begin a top-level declaration — the resync set for declaration recovery.
    private static let declStart: Set<TokenKind> =
        [.kwStruct, .kwEnum, .kwClass, .kwActor, .kwInterface, .kwExtension, .kwFunc]

    // Tokens that introduce a member inside any type body (plus the closing brace) — the
    // resync set when a type-body loop meets a token that starts no member.
    private static let memberBoundary: Set<TokenKind> =
        [.kwVar, .kwLet, .kwFunc, .kwCase, .kwOn, .rBrace]

    // An optional `: I1, I2` conformance clause following a type name (M5 A1.3).
    private mutating func parseConformanceClause() -> [Conformance] {
        guard eat(.colon) else { return [] }
        var out: [Conformance] = []
        repeat {
            let span = currentSpan
            out.append(Conformance(name: expectIdent(), span: span))
        } while eat(.comma)
        return out
    }

    // `<T>`, `<T: I>`, `<T: I & J>, U` — a generic parameter list (M5 5.2.1). Empty when no `<`.
    private mutating func parseGenericParams() -> [GenericParam] {
        guard eat(.lt) else { return [] }
        var params: [GenericParam] = []
        repeat {
            let pspan = currentSpan
            // `<shared T>` — an orthogonal capability prefix (contextual, like `any`/`some`),
            // requiring the type argument to be shareable (M5 5.3.2, generics.md §3a).
            var isShared = false
            if case .ident("shared") = currentKind, case .ident = peek() { advance(); isShared = true }
            let name = expectIdent()
            var bounds: [Conformance] = []
            if eat(.colon) {
                repeat {
                    let bspan = currentSpan
                    bounds.append(Conformance(name: expectIdent(), span: bspan))
                } while eat(.amp)
            }
            params.append(GenericParam(name: name, bounds: bounds, isShared: isShared, span: pspan))
        } while eat(.comma)
        expect(.gt)
        return params
    }

    private mutating func parseStructDecl() -> StructDecl {
        let start = currentSpan
        expect(.kwStruct)
        let name = expectIdent()
        let generics = parseGenericParams()
        let conformances = parseConformanceClause()
        expect(.lBrace)
        var fields: [VarField] = []
        var properties: [ComputedProperty] = []
        var methods: [FuncDecl] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwVar) || check(.kwLet) {
                switch parseFieldOrProperty() {
                case .field(let f):    fields.append(f)
                case .property(let p): properties.append(p)
                }
            } else if check(.kwFunc) || check(.kwStatic) {
                requireLineStart(check(.kwStatic) ? "static" : "fun")
                methods.append(parseFuncDecl())
            } else {
                error("expected 'let', 'var', 'fun', or 'static fun' in struct body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            // A member introducer for a *different* body kind (e.g. `case`/`on` here) is in the
            // recovery set, so recover() stops on it without consuming — force progress. (Same
            // guard as parseBlock/parseParamList; without it a stray boundary token spins.)
            if pos == before { advance() }
        }
        expect(.rBrace)
        return StructDecl(name: name, generics: generics, fields: fields, properties: properties, methods: methods,
                          conformances: conformances, span: spanFrom(start))
    }

    private mutating func parseEnumDecl() -> EnumDecl {
        let start = currentSpan
        expect(.kwEnum)
        let name = expectIdent()
        let generics = parseGenericParams()
        let conformances = parseConformanceClause()
        expect(.lBrace)
        var cases: [EnumCaseDecl] = []
        var properties: [ComputedProperty] = []
        var methods: [FuncDecl] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwCase) {
                cases.append(parseEnumCaseDecl())
            } else if check(.kwVar) {
                // Enums store nothing, so a `var` member must be a computed property.
                switch parseFieldOrProperty() {
                case .property(let p): properties.append(p)
                case .field:           error("enums cannot store fields; a 'var' member must be a computed property")
                }
            } else if check(.kwLet) {
                error("enums cannot store fields")
                advance()   // consume `let`, then skip the field's tokens to the next member
                recover(to: Self.memberBoundary)
            } else if check(.kwFunc) || check(.kwStatic) {
                requireLineStart(check(.kwStatic) ? "static" : "fun")
                methods.append(parseFuncDecl())
            } else {
                error("expected 'case', 'var', 'fun', or 'static fun' in enum body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            if pos == before { advance() }   // stray boundary token (e.g. `on`): force progress
        }
        expect(.rBrace)
        return EnumDecl(name: name, generics: generics, cases: cases, properties: properties, methods: methods,
                        conformances: conformances, span: spanFrom(start))
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
                fields.append(VarField(name: fname, type: ftype, isMutable: true, span: spanFrom(fstart)))
            } while eat(.comma)
            expect(.rParen)
        }
        return EnumCaseDecl(name: name, fields: fields, span: spanFrom(start))
    }

    private mutating func parseClassDecl() -> ClassDecl {
        let start = currentSpan
        expect(.kwClass)
        let name = expectIdent()
        let generics = parseGenericParams()
        let conformances = parseConformanceClause()
        expect(.lBrace)
        var fields: [VarField] = []
        var properties: [ComputedProperty] = []
        var methods: [FuncDecl] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwVar) || check(.kwLet) {
                switch parseFieldOrProperty() {
                case .field(let f):    fields.append(f)
                case .property(let p): properties.append(p)
                }
            } else if check(.kwFunc) || check(.kwStatic) {
                requireLineStart(check(.kwStatic) ? "static" : "fun")
                methods.append(parseFuncDecl())
            } else {
                error("expected 'let', 'var', 'fun', or 'static fun' in class body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            if pos == before { advance() }   // stray boundary token (e.g. `case`/`on`): force progress
        }
        expect(.rBrace)
        return ClassDecl(name: name, generics: generics, fields: fields, properties: properties, methods: methods,
                         conformances: conformances, span: spanFrom(start))
    }

    // A plain extension `extension T { … }` whose body holds only `fun` members.
    // The conformance form (`extension T: I`) and stored properties are rejected
    // with targeted diagnostics — both are M5 / never (M4.12; m4.12-spec.md §2).
    private mutating func parseExtensionDecl() -> ExtensionDecl {
        let start = currentSpan
        expect(.kwExtension)
        let nameSpan = currentSpan
        let name = expectIdent()
        // `extension T: I` is a conformance extension (M5 A1.3); bare `extension T` is plain.
        var conformance: Conformance? = nil
        if eat(.colon) {
            let ifaceSpan = currentSpan
            conformance = Conformance(name: expectIdent(), span: ifaceSpan)
        }
        expect(.lBrace)
        var methods: [FuncDecl] = []
        var properties: [ComputedProperty] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwFunc) {
                requireLineStart("fun")
                methods.append(parseFuncDecl())
            } else if check(.kwVar) || check(.kwLet) {
                // A computed property (`var x: T { … }`) is allowed in an extension; a stored
                // field is not (Swift's rule — extensions add no storage).
                switch parseFieldOrProperty() {
                case .field:           error("extensions cannot declare stored properties")
                case .property(let p): properties.append(p)
                }
            } else {
                error("expected 'fun' or a computed property in extension body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            if pos == before { advance() }   // stray boundary token (e.g. `case`/`on`): force progress
        }
        expect(.rBrace)
        return ExtensionDecl(typeName: name, typeNameSpan: nameSpan, conformance: conformance,
                             methods: methods, properties: properties, span: spanFrom(start))
    }

    // interface I {
    //     fun draw() -> String            // mandatory requirement (no body)
    //     fun describe() -> String { … }   // overridable default (has a body)
    //     var name: String { get }         // read-only property requirement
    //     var count: Int { get set }       // settable property requirement
    // }
    private mutating func parseInterfaceDecl() -> InterfaceDecl {
        let start = currentSpan
        expect(.kwInterface)
        let name = expectIdent()
        let refines = parseConformanceClause()   // `interface B: A, C` (M5 A1.5)
        expect(.lBrace)
        var methods: [InterfaceMethod] = []
        var properties: [InterfacePropertyReq] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwFunc) {
                requireLineStart("fun")
                methods.append(parseInterfaceMethod())
            } else if check(.kwVar) {
                requireLineStart("var")
                properties.append(parseInterfacePropertyReq())
            } else {
                error("expected 'fun' or 'var' requirement in interface body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            if pos == before { advance() }   // stray boundary token (e.g. `case`/`on`): force progress
        }
        expect(.rBrace)
        return InterfaceDecl(name: name, refines: refines, methods: methods, properties: properties, span: spanFrom(start))
    }

    // A method requirement: a signature, optionally followed by a `{ … }` default body.
    private mutating func parseInterfaceMethod() -> InterfaceMethod {
        let start = currentSpan
        expect(.kwFunc)
        let name = expectIdent()
        let params = parseParamList()
        var returnType: TypeRef? = nil
        if eat(.arrow) { returnType = parseTypeRef() }
        let defaultBody: Block? = check(.lBrace) ? parseBlock() : nil
        return InterfaceMethod(name: name, params: params, returnType: returnType,
                               defaultBody: defaultBody, span: spanFrom(start))
    }

    // A property requirement: `var name: T { get }` or `{ get set }` — accessor shapes
    // only, no bodies. `get`/`set` are contextual here, like in computed properties.
    private mutating func parseInterfacePropertyReq() -> InterfacePropertyReq {
        let start = currentSpan
        expect(.kwVar)
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        expect(.lBrace)
        // Recover by continuing as if `get` were present, so `{ get set }` shape still parses.
        if accessorReqKeyword("get") { advance() } else { error("property requirement needs 'get'") }
        var settable = false
        if accessorReqKeyword("set") { advance(); settable = true }
        expect(.rBrace)
        return InterfacePropertyReq(name: name, type: type, isSettable: settable, span: spanFrom(start))
    }

    // `get`/`set` as bare words inside a property-requirement brace group (no `{`/`(`
    // follows, unlike computed-property accessors).
    private func accessorReqKeyword(_ kw: String) -> Bool {
        if case .ident(let s) = currentKind, s == kw { return true }
        return false
    }

    private mutating func parseActorDecl() -> ActorDecl {
        let start = currentSpan
        expect(.kwActor)
        let name = expectIdent()
        let conformances = parseConformanceClause()
        expect(.lBrace)
        var fields: [ActorField] = []
        var handlers: [OnHandler] = []
        while !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            if check(.kwVar) {
                fields.append(parseActorField())
            } else if check(.kwOn) {
                handlers.append(parseOnHandler())
            } else {
                error("expected 'var' or 'on' in actor body, got \(currentKind)")
                recover(to: Self.memberBoundary)
            }
            if pos == before { advance() }   // stray boundary token (e.g. `case`): force progress
        }
        expect(.rBrace)
        return ActorDecl(name: name, fields: fields, handlers: handlers,
                         conformances: conformances, span: spanFrom(start))
    }

    private mutating func parseFuncDecl() -> FuncDecl {
        let start = currentSpan
        // `static fun …` — a type-associated function with no `self`. The modifier is only
        // meaningful inside a type body; a stray top-level `static` never reaches here (the
        // top-level dispatch keys on `fun`), so an accepted `static` here always precedes a member.
        let isStatic = eat(.kwStatic)
        expect(.kwFunc)
        let name = expectIdent()
        let generics = parseGenericParams()
        let params = parseParamList()
        var returnType: TypeRef? = nil
        if eat(.arrow) {
            returnType = parseTypeRef()
        }
        let body = parseBlock()
        return FuncDecl(name: name, generics: generics, params: params, returnType: returnType, body: body, isStatic: isStatic, span: spanFrom(start))
    }

    // MARK: - Fields and params

    // A `var`/`let` member is a stored field unless a `{` follows its type, in which
    // case it is a computed property (M5 A1). Computed properties must be `var`.
    private enum Member { case field(VarField); case property(ComputedProperty) }

    private mutating func parseFieldOrProperty() -> Member {
        let start = currentSpan
        let isMutable = check(.kwVar)
        requireLineStart(isMutable ? "var" : "let")
        advance()   // consume `var` / `let`
        let name = expectIdent()
        expect(.colon)
        let type = parseTypeRef()
        if check(.lBrace) {
            if !isMutable { error("computed properties must be declared with 'var'") }
            let (getter, setter) = parseAccessorBlock()
            return .property(ComputedProperty(name: name, type: type, getter: getter, setter: setter, span: spanFrom(start)))
        }
        return .field(VarField(name: name, type: type, isMutable: isMutable, span: spanFrom(start)))
    }

    // `{ get { … } set(v) { … } }` — or a bare body `{ <stmts> }` that is an implicit
    // read-only get. `get`/`set` are contextual (recognized only here by the `{`/`(`
    // that must follow), so they stay usable as ordinary identifiers elsewhere.
    private mutating func parseAccessorBlock() -> (Block, Setter?) {
        expect(.lBrace)
        if accessorKeyword("get") || accessorKeyword("set") {
            var getter: Block? = nil
            var setter: Setter? = nil
            while !check(.rBrace) && !check(.eof) {
                let before = pos
                if accessorKeyword("get") {
                    advance()   // `get`
                    getter = parseBlock()
                } else if accessorKeyword("set") {
                    advance()   // `set`
                    expect(.lParen)
                    let param = expectIdent()
                    expect(.rParen)
                    setter = Setter(paramName: param, body: parseBlock())
                } else {
                    error("expected 'get' or 'set' in accessor block, got \(currentKind)")
                }
                if pos == before { advance() }   // unexpected token: skip to guarantee progress
            }
            expect(.rBrace)
            // A missing getter is only an error when the recovery didn't already report one.
            guard let g = getter else {
                error("a computed property needs a 'get' accessor")
                return ([], setter)
            }
            return (g, setter)
        }
        // Bare body: the whole brace group is the getter (implicit read-only get).
        var stmts: [Stmt] = []
        while !check(.rBrace) && !check(.eof) {
            let before = pos
            stmts.append(parseStmt())
            if pos == before { advance() }   // unparseable token: skip to guarantee progress
        }
        expect(.rBrace)
        return (stmts, nil)
    }

    // `get` immediately followed by `{`, or `set` immediately followed by `(` — the
    // shapes that mark an accessor keyword rather than an ordinary identifier.
    private func accessorKeyword(_ kw: String) -> Bool {
        guard case .ident(let s) = currentKind, s == kw else { return false }
        return kw == "get" ? peek() == .lBrace : peek() == .lParen
    }

    private mutating func parseActorField() -> ActorField {
        let start = currentSpan
        requireLineStart("var")
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
            let before = pos
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
            if pos == before { advance() }   // no token consumed on a malformed param: force progress
        }
        expect(.rParen)
        return params
    }

    private mutating func parseTypeRef() -> TypeRef {
        let start = currentSpan
        // `any I` / `any A & B` — an existential over one or more interfaces (M5 A1.4/A1.5b).
        // `any` is contextual: it introduces an existential only when a type name follows.
        if case .ident("any") = currentKind, case .ident = peek() {
            advance()   // `any`
            var ifaces = [expectIdent()]
            while eat(.amp) { ifaces.append(expectIdent()) }
            return TypeRef(name: "any " + ifaces.joined(separator: " & "), existentialOf: ifaces, span: spanFrom(start))
        }
        // `some I` / `some A & B` — an opaque type over one or more interfaces (M5 A3).
        // Like `any`, `some` is contextual: it opens an opaque type only when a name follows.
        if case .ident("some") = currentKind, case .ident = peek() {
            advance()   // `some`
            var ifaces = [expectIdent()]
            while eat(.amp) { ifaces.append(expectIdent()) }
            return TypeRef(name: "some " + ifaces.joined(separator: " & "), opaqueOf: ifaces, span: spanFrom(start))
        }
        if check(.lParen) {
            // Function type: (T1, T2) -> R
            expect(.lParen)
            var params: [TypeRef] = []
            while !check(.rParen) && !check(.eof) {
                let before = pos
                if !params.isEmpty { expect(.comma) }
                params.append(parseTypeRef())
                // A non-type token here (e.g. a literal) makes parseTypeRef consume nothing;
                // without this guard the loop spins forever. Force progress.
                if pos == before { advance() }
            }
            expect(.rParen)
            expect(.arrow)
            let ret = parseTypeRef()
            return TypeRef(name: renderFnType(params, ret), fn: FnType(params: params, ret: ret), span: spanFrom(start))
        }
        let name = expectIdent()
        // Applied generic type `Box<Int>` / `Map<String, Int>` (M5 5.2.1). Angle brackets are
        // generic only in type position (decided, 5.0.6), so a `<` here is unambiguous.
        if check(.lt) {
            var args: [TypeRef] = []
            expect(.lt)
            repeat { args.append(parseTypeRef()) } while eat(.comma)
            expect(.gt)
            return TypeRef(name: name, genericArgs: args, span: spanFrom(start))   // `name` is the base; args carry the arguments
        }
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
            panicking = false
            let before = pos
            stmts.append(parseStmt())
            if pos == before { advance() }   // unparseable token: skip to guarantee progress
        }
        expect(.rBrace)
        return stmts
    }

    private mutating func parseCaseBody() -> Block {
        var stmts: [Stmt] = []
        while !check(.kwCase) && !check(.rBrace) && !check(.eof) {
            panicking = false
            let before = pos
            stmts.append(parseStmt())
            if pos == before { advance() }   // unparseable token: skip to guarantee progress
        }
        return stmts
    }

    private mutating func parseStmt() -> Stmt {
        switch currentKind {
        case .kwLet:    return parseBinding(isMutable: false)
        case .kwVar:    return parseBinding(isMutable: true)
        case .kwReturn: return parseReturn()
        case .kwIf:     return parseIfStmt()
        case .kwWhile:  return parseWhileStmt()
        case .kwBreak:  let s = currentSpan; advance(); return .breakStmt(span: s)
        case .kwContinue: let s = currentSpan; advance(); return .continueStmt(span: s)
        case .kwSwitch: return parseSwitchStmt()
        case .kwSpawn where peek() == .kwLet: return parseSpawnLet()
        default:        return parseExprOrAssign()
        }
    }

    // while <cond> { body }  — the one canonical loop (`loops.md`).
    private mutating func parseWhileStmt() -> Stmt {
        let start = currentSpan
        expect(.kwWhile)
        let cond = parseExpr()
        let body = parseBlock()
        return .whileStmt(WhileStmt(cond: cond, body: body, span: spanFrom(start)))
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
        parseLogicalOr()
    }

    // `||` — loosest binding of all, so `a && b || c` reads as `(a && b) || c`. Short-circuit:
    // codegen (SSAIRgen) lowers it to branches, evaluating the right side only when the left is false.
    private mutating func parseLogicalOr() -> Expr {
        let start = currentSpan
        var lhs = parseLogicalAnd()
        while currentKind == .pipePipe {
            advance()
            lhs = .binary(.or, lhs, parseLogicalAnd(), span: spanFrom(start))
        }
        return lhs
    }

    // `&&` — binds tighter than `||`, looser than comparison, so `a == b && c` reads as
    // `(a == b) && c`. Short-circuit, like `||`.
    private mutating func parseLogicalAnd() -> Expr {
        let start = currentSpan
        var lhs = parseComparison()
        while currentKind == .ampAmp {
            advance()
            lhs = .binary(.and, lhs, parseComparison(), span: spanFrom(start))
        }
        return lhs
    }

    // Precedence chain, loosest to tightest binding: `||` < `&&` < comparison < `|` < `^` < `&` <
    // shift < additive < multiplicative < unary prefix < postfix. Bitwise and shift bind tighter than
    // comparison (Go-style), so `x & mask == 0` reads as `(x & mask) == 0`, not the C footgun.
    private mutating func parseComparison() -> Expr {
        let start = currentSpan
        var lhs = parseBitOr()
        while let op = comparisonOp() {
            advance()
            lhs = .binary(op, lhs, parseBitOr(), span: spanFrom(start))
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

    private mutating func parseBitOr() -> Expr {
        let start = currentSpan
        var lhs = parseBitXor()
        while currentKind == .pipe {
            advance()
            lhs = .binary(.bitOr, lhs, parseBitXor(), span: spanFrom(start))
        }
        return lhs
    }

    private mutating func parseBitXor() -> Expr {
        let start = currentSpan
        var lhs = parseBitAnd()
        while currentKind == .caret {
            advance()
            lhs = .binary(.bitXor, lhs, parseBitAnd(), span: spanFrom(start))
        }
        return lhs
    }

    // `&` in expression position is bitwise-and (interface composition `any A & B` is parsed in
    // type position, a separate path).
    private mutating func parseBitAnd() -> Expr {
        let start = currentSpan
        var lhs = parseShift()
        while currentKind == .amp {
            advance()
            lhs = .binary(.bitAnd, lhs, parseShift(), span: spanFrom(start))
        }
        return lhs
    }

    private mutating func parseShift() -> Expr {
        let start = currentSpan
        var lhs = parseAdditive()
        while let op = shiftOp() {
            advance(); advance()   // consume both `<`/`>` tokens
            lhs = .binary(op, lhs, parseAdditive(), span: spanFrom(start))
        }
        return lhs
    }

    // `<<` / `>>` are two adjacent `<` / `>` tokens, recombined here rather than in the lexer so a
    // bare `>` still closes a generic argument list (`Box<Box<Int>>` lexes as two `>`). Adjacency
    // (no gap between the two tokens) is required, so `a > b` and `Foo<T>` are never misread.
    private func shiftOp() -> BinOp? {
        // The adjacency test reads the next token directly; guard the last-token case (the EOF
        // token is always last) so an expression that ends at EOF — e.g. from a missing closing
        // delimiter — does not index past the end. At EOF there is no two-token `<<`/`>>` anyway.
        guard pos + 1 < tokens.count,
              tokens[pos].span.endOffset == tokens[pos + 1].span.startOffset else { return nil }
        if currentKind == .lt, peek() == .lt { return .shl }
        if currentKind == .gt, peek() == .gt { return .shr }
        return nil
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
        var lhs = parseUnary()
        while currentKind == .star || currentKind == .slash || currentKind == .percent {
            let op: BinOp
            switch currentKind {
            case .star:  op = .mul
            case .slash: op = .div
            default:     op = .mod   // .percent
            }
            advance()
            lhs = .binary(op, lhs, parseUnary(), span: spanFrom(start))
        }
        return lhs
    }

    // Prefix operators: `-x` (negate), `!x` (logical not), `~x` (bitwise not). Right-associative
    // (a prefix op applies to the unary expression that follows), so `- -x` and `!!x` nest.
    private mutating func parseUnary() -> Expr {
        let start = currentSpan
        let op: UnaryOp?
        switch currentKind {
        case .minus: op = .neg
        case .bang:  op = .not
        case .tilde: op = .bitNot
        default:     op = nil
        }
        guard let op else { return parsePostfix() }
        advance()
        return .unary(op, parseUnary(), span: spanFrom(start))
    }

    private mutating func parsePostfix() -> Expr {
        let start = currentSpan
        var expr = parsePrimary()
        // Explicit type arguments on a name: `Name<T, U>` before a construction or member access
        // (`Box<Int>(...)`, `Option<Int>.some(...)`). Only a bare identifier can carry them, and
        // only when the brackets parse as a type list closing before `(` or `.` — otherwise `<` is
        // the comparison operator (resolved by parseComparison). See tryParseTypeArgs.
        if case .ident(let name, _) = expr, check(.lt), let targs = tryParseTypeArgs() {
            expr = .genericIdent(name, targs, span: spanFrom(start))
        }
        while true {
            if eat(.dot) {
                expr = .member(expr, expectIdent(), span: spanFrom(start))
            } else if check(.lParen) {
                expr = .call(expr, parseArgList(), span: spanFrom(start))
            } else if eat(.lBracket) {
                let idx = parseExpr()
                expect(.rBracket)
                expr = .index(expr, idx, span: spanFrom(start))
            } else {
                break
            }
        }
        return expr
    }

    // Speculatively read `< T, U >` as explicit type arguments. Swift-style backtracking: commit
    // only if the brackets form a well-formed type list whose closing `>` is immediately followed
    // by `(` or `.` (a construction or member access) and no diagnostics were emitted. Otherwise
    // the `<` is a comparison operator — restore the position, discard any speculative diagnostics,
    // and return nil so parseComparison handles it. `>>` closes two lists as two `>` tokens.
    private mutating func tryParseTypeArgs() -> [TypeRef]? {
        let savedPos = pos
        let savedDiagCount = diags.diagnostics.count
        let savedPanicking = panicking
        _ = eat(.lt)
        var args: [TypeRef] = []
        repeat { args.append(parseTypeRef()) } while eat(.comma)
        let committed = eat(.gt)
            && (check(.lParen) || check(.dot))
            && diags.diagnostics.count == savedDiagCount
        if committed { return args }
        pos = savedPos
        panicking = savedPanicking
        diags.truncate(to: savedDiagCount)
        return nil
    }

    private mutating func parsePrimary() -> Expr {
        let start = currentSpan
        switch currentKind {
        case .intLit(let v):
            advance(); return .intLit(v, span: spanFrom(start))
        case .doubleLit(let v):
            advance(); return .doubleLit(v, span: spanFrom(start))
        case .boolLit(let v):
            advance(); return .boolLit(v, span: spanFrom(start))
        case .stringLit(let v):
            advance(); return .stringLit(v, span: spanFrom(start))
        case .lParen:
            // Grouping parentheses: `(a + b) * c`. Transparent — the inner expression is
            // returned as-is, so precedence falls out of the recursive parseExpr. A trailing
            // call / member / subscript is attached by parsePostfix off the returned node.
            advance()
            let inner = parseExpr()
            expect(.rParen)
            return inner
        case .lBrace:
            return parseClosure()
        case .lBracket:
            return parseArrayLit()
        case .ident(let name):
            advance(); return .ident(name, span: spanFrom(start))
        case .dot:
            // Leading-dot enum-case shorthand: `.circle` / `.circle(...)`. A trailing
            // arg list, if any, is attached by parsePostfix as a call.
            advance()
            return .implicitMember(expectIdent(), span: spanFrom(start))
        default:
            // No expression here: report and yield an error placeholder. The token is left
            // for the enclosing statement/argument loop to resynchronize on.
            error("expected expression, got \(currentKind)")
            return .error(span: currentSpan)
        }
    }

    // [a, b, c]  — an array literal (empty `[]` allowed; element type inferred / annotated). A
    // trailing subscript like `[1, 2][0]` is handled by parsePostfix off the literal.
    private mutating func parseArrayLit() -> Expr {
        let start = currentSpan
        expect(.lBracket)
        var elems: [Expr] = []
        while !check(.rBracket) && !check(.eof) {
            let before = pos
            if !elems.isEmpty { expect(.comma) }
            elems.append(parseExpr())
            if pos == before { advance() }   // guarantee progress on unparseable input
        }
        expect(.rBracket)
        return .arrayLit(elems, span: spanFrom(start))
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
            panicking = false
            let before = pos
            body.append(parseStmt())
            if pos == before { advance() }   // unparseable token: skip to guarantee progress
        }
        expect(.rBrace)
        return .closure(params: params, ret: ret, body: body, span: spanFrom(start))
    }

    private mutating func parseArgList() -> [Arg] {
        expect(.lParen)
        var args: [Arg] = []
        while !check(.rParen) && !check(.eof) {
            let before = pos
            if !args.isEmpty { expect(.comma) }
            // IDENT ':' → labeled argument
            if case .ident(let label) = currentKind, peek() == .colon {
                advance()  // label
                advance()  // ':'
                args.append(Arg(label: label, value: parseExpr()))
            } else {
                args.append(Arg(value: parseExpr()))
            }
            if pos == before { advance() }   // no token consumed on a malformed arg: force progress
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

    // On a mismatch, report and return the current token as a placeholder *without*
    // consuming it — the missing token is synthesized, so the enclosing construct keeps
    // its shape and later real tokens are not swallowed.
    @discardableResult
    private mutating func expect(_ kind: TokenKind) -> Token {
        guard currentKind == kind else {
            error("expected \(kind), got \(currentKind)")
            return tokens[pos]
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

    // Like `expect`, but yields a placeholder name for a missing identifier so the AST
    // node can still be built; the diagnostic marks it as an error.
    private mutating func expectIdent() -> String {
        guard case .ident(let name) = currentKind else {
            error("expected identifier, got \(currentKind)")
            return "<error>"
        }
        advance()
        return name
    }

    private func check(_ kind: TokenKind) -> Bool { currentKind == kind }

    // Some declaration keywords must be the first token on their line (`var` fields
    // and `fun` members), so declarations never share a line inside a type body.
    // The lexer discards newlines, so this is checked against span line numbers:
    // the previous token must end on an earlier line than this one begins.
    private mutating func requireLineStart(_ keyword: String) {
        guard pos > 0 else { return }
        if tokens[pos - 1].span.end.line >= currentSpan.begin.line {
            error("'\(keyword)' must begin a new line")
        }
    }

    // Report an error at the current token and enter panic mode. While panicking, further
    // errors are suppressed (one diagnostic per broken construct); a loop-top reset or a
    // `recover(to:)` clears it at the next boundary.
    private mutating func error(_ msg: String) {
        guard !panicking else { return }
        diags.error(msg, at: currentSpan)
        panicking = true
    }

    // Skip tokens until the current one is in `sync` (or EOF), then leave panic mode. Used
    // to resynchronize after an error to a known boundary — a declaration keyword, a member
    // introducer, or a closing brace — so parsing can resume cleanly.
    private mutating func recover(to sync: Set<TokenKind>) {
        while !check(.eof) && !sync.contains(currentKind) { advance() }
        panicking = false
    }
}
