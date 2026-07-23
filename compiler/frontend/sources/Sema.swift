// The semantic pass: resolves names, types every expression, and lowers the AST
// to the typed IR, collecting diagnostics (design: compiler.md §1). Concrete types
// only — interfaces/generics are M5; type methods are T3.

public struct SemaResult {
    public let module: IRModule
    public let diagnostics: DiagnosticSink
}

public struct Sema {
    private let program: Program
    private let diags = DiagnosticSink()

    // Global declarations, by name.
    private var structs: [String: StructDecl] = [:]
    private var enums:   [String: EnumDecl]   = [:]
    private var classes: [String: ClassDecl]  = [:]
    private var actors:  [String: ActorDecl]  = [:]
    private var funcs:   [String: FnSig]      = [:]   // named functions + non-print builtins

    // Lexical scope stack for locals/params (name → type).
    private var scopes: [[String: Type]] = []

    private struct FnSig { let params: [Type]; let ret: Type }

    public init(_ program: Program) { self.program = program }

    public mutating func check() -> SemaResult {
        collectGlobals()
        var decls: [IRDecl] = []
        for decl in program.decls { decls.append(lowerDecl(decl)) }
        return SemaResult(module: IRModule(decls: decls), diagnostics: diags)
    }

    // MARK: - Global collection

    private mutating func collectGlobals() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e):   enums[e.name]   = e
            case .classDecl(let c):  classes[c.name] = c
            case .actorDecl(let a):  actors[a.name]  = a
            case .funcDecl(let f):
                funcs[f.name] = FnSig(params: f.params.map { resolve($0.type) },
                                      ret: resolve(f.returnType))
            }
        }
        // Prototype builtins (print is special-cased in checkCall — it is variadic-ish).
        funcs["concat"]   = FnSig(params: [.string, .string], ret: .string)
        funcs["readLine"] = FnSig(params: [], ret: .string)
        funcs["sleep"]    = FnSig(params: [.int], ret: .int)
    }

    // MARK: - Type resolution (syntax → semantics)

    private func resolve(_ ref: TypeRef?) -> Type {
        guard let ref else { return .void }
        if let fn = ref.fn {
            return .function(params: fn.params.map { resolve($0) }, ret: resolve(fn.ret))
        }
        switch ref.name {
        case "Int":    return .int
        case "Bool":   return .bool
        case "String": return .string
        case "Void":   return .void
        default:
            if let k = kindOf(ref.name) { return .named(ref.name, k) }
            diags.error("unknown type '\(ref.name)'", at: ref.span)
            return .error
        }
    }

    private func kindOf(_ name: String) -> NamedKind? {
        if structs[name] != nil { return .struct_ }
        if enums[name]   != nil { return .enum_ }
        if classes[name] != nil { return .class_ }
        if actors[name]  != nil { return .actor_ }
        return nil
    }

    // The declared instance method `name` on a struct/enum/class, if any (T3).
    private func methodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
        switch kind {
        case .struct_: return structs[typeName]?.methods.first { $0.name == name }
        case .enum_:   return enums[typeName]?.methods.first { $0.name == name }
        case .class_:  return classes[typeName]?.methods.first { $0.name == name }
        case .actor_:  return nil
        }
    }

    // MARK: - Declarations

    private mutating func lowerDecl(_ decl: TopDecl) -> IRDecl {
        switch decl {
        case .structDecl(let s):
            let fields = s.fields.map(lowerField)
            let methods = lowerMethods(s.methods, selfType: .named(s.name, .struct_), fields: fields)
            return .structDecl(IRStruct(name: s.name, fields: fields, methods: methods, span: s.span))
        case .enumDecl(let e):
            let cases = e.cases.map { IREnumCase(name: $0.name, fields: $0.fields.map(lowerField), span: $0.span) }
            let methods = lowerMethods(e.methods, selfType: .named(e.name, .enum_), fields: [])
            return .enumDecl(IREnum(name: e.name, cases: cases, methods: methods, span: e.span))
        case .classDecl(let c):
            let fields = c.fields.map(lowerField)
            let methods = lowerMethods(c.methods, selfType: .named(c.name, .class_), fields: fields)
            return .classDecl(IRClass(name: c.name, fields: fields, methods: methods, span: c.span))
        case .actorDecl(let a):
            return .actorDecl(lowerActor(a))
        case .funcDecl(let f):
            return .funcDecl(lowerFunc(f))
        }
    }

    private func lowerField(_ f: VarField) -> IRField {
        IRField(name: f.name, type: resolve(f.type), span: f.span)
    }

    // Lower each `fun` member with `self` (immutable) and the receiver's fields
    // declared by bare name, mirroring how actor handlers see their fields (T3).
    private mutating func lowerMethods(_ methods: [FuncDecl], selfType: Type, fields: [IRField]) -> [IRFunc] {
        var out: [IRFunc] = []
        for m in methods {
            let params = m.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            pushScope()
            declare("self", selfType)
            for f in fields { declare(f.name, f.type) }
            for p in params { declare(p.name, p.type) }
            let body = lowerBlock(m.body)
            popScope()
            out.append(IRFunc(name: m.name, params: params, returnType: resolve(m.returnType), body: body, span: m.span))
        }
        return out
    }

    private mutating func lowerFunc(_ f: FuncDecl) -> IRFunc {
        let params = f.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
        pushScope()
        for p in params { declare(p.name, p.type) }
        let body = lowerBlock(f.body)
        popScope()
        return IRFunc(name: f.name, params: params, returnType: resolve(f.returnType), body: body, span: f.span)
    }

    private mutating func lowerActor(_ a: ActorDecl) -> IRActor {
        let fields = a.fields.map { af in
            IRActorField(name: af.name, type: resolve(af.type),
                         initializer: af.initializer.map { checkExpr($0) }, span: af.span)
        }
        var handlers: [IRHandler] = []
        for h in a.handlers {
            let params = h.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            pushScope()
            for f in fields { declare(f.name, f.type) }   // handler body sees actor fields by name
            for p in params { declare(p.name, p.type) }
            let body = lowerBlock(h.body)
            popScope()
            handlers.append(IRHandler(name: h.name, params: params, returnType: resolve(h.returnType),
                                      body: body, span: h.span))
        }
        return IRActor(name: a.name, fields: fields, handlers: handlers, span: a.span)
    }

    // MARK: - Statements

    private mutating func lowerBlock(_ block: Block) -> [IRStmt] {
        pushScope()
        let stmts = block.map { lowerStmt($0) }
        popScope()
        return stmts
    }

    private mutating func lowerStmt(_ stmt: Stmt) -> IRStmt {
        switch stmt {
        case .binding(let b):
            let value = checkExpr(b.value)
            let type = b.type.map { resolve($0) } ?? value.type
            declare(b.name, type)
            return IRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)

        case .spawnLet(let name, _, let value, let span):
            let v = checkExpr(value)
            declare(name, v.type)   // reading a spawn binding yields its result value
            return IRStmt(kind: .spawnLet(name: name, value: v, resultType: v.type), span: span)

        case .assign(let lhs, let rhs, let span):
            return IRStmt(kind: .assign(target: checkExpr(lhs), value: checkExpr(rhs)), span: span)

        case .compoundAssign(let lhs, let rhs, let span):
            return IRStmt(kind: .compoundAssign(target: checkExpr(lhs), value: checkExpr(rhs)), span: span)

        case .ret(let e, let span):
            return IRStmt(kind: .ret(e.map { checkExpr($0) }), span: span)

        case .ifStmt(let s):
            let cond = checkExpr(s.cond)
            let then = lowerBlock(s.thenBody)
            let els = s.elseBody.map { lowerBlock($0) }
            return IRStmt(kind: .ifStmt(cond: cond, then: then, else: els), span: s.span)

        case .switchStmt(let sw):
            return IRStmt(kind: .switchStmt(lowerSwitch(sw)), span: sw.span)

        case .expr(let e):
            let ir = checkExpr(e)
            return IRStmt(kind: .exprStmt(ir), span: ir.span)
        }
    }

    private mutating func lowerSwitch(_ sw: SwitchStmt) -> IRSwitch {
        let subject = checkExpr(sw.subject)
        // The subject's enum, if any, gives payload binding types.
        let enumDecl: EnumDecl? = { if case .named(let n, .enum_) = subject.type { return enums[n] }; return nil }()
        var arms: [IRCaseArm] = []
        for arm in sw.cases {
            guard case .enumCase(let name, let names, _) = arm.pattern else { continue }
            let caseDecl = enumDecl?.cases.first { $0.name == name }
            let bindings: [IRBinding] = zip(names, caseDecl?.fields ?? []).map {
                IRBinding(name: $0.0, type: resolve($0.1.type))
            }
            pushScope()
            for b in bindings { declare(b.name, b.type) }
            let body = lowerBlock(arm.body)
            popScope()
            arms.append(IRCaseArm(caseName: name, bindings: bindings, body: body, span: arm.span))
        }
        return IRSwitch(subject: subject, arms: arms)
    }

    // MARK: - Expressions

    private mutating func checkExpr(_ e: Expr) -> IRExpr {
        switch e {
        case .intLit(let v, let span):    return IRExpr(type: .int,    span: span, kind: .intLit(v))
        case .boolLit(let v, let span):   return IRExpr(type: .bool,   span: span, kind: .boolLit(v))
        case .stringLit(let v, let span): return IRExpr(type: .string, span: span, kind: .stringLit(v))

        case .ident(let name, let span):
            if let t = lookup(name) {
                return IRExpr(type: t, span: span, kind: .varRef(name))
            }
            if let sig = funcs[name] {
                return IRExpr(type: .function(params: sig.params, ret: sig.ret), span: span, kind: .varRef(name))
            }
            diags.error("undefined name '\(name)'", at: span)
            return IRExpr(type: .error, span: span, kind: .varRef(name))

        case .member(let base, let field, let span):
            let b = checkExpr(base)
            let type = fieldType(of: b.type, field: field, at: span)
            return IRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))

        case .binary(let op, let l, let r, let span):
            let lhs = checkExpr(l), rhs = checkExpr(r)
            let type = binaryResult(op, lhs, rhs, at: span)
            return IRExpr(type: type, span: span, kind: .binary(op, lhs, rhs))

        case .call(let callee, let args, let span):
            return checkCall(callee: callee, args: args, span: span)

        case .closure(let params, let ret, let body, let span):
            let ps = params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            pushScope()
            for p in ps { declare(p.name, p.type) }
            let irBody = lowerBlock(body)
            popScope()
            let type = Type.function(params: ps.map(\.type), ret: resolve(ret))
            return IRExpr(type: type, span: span, kind: .closure(params: ps, body: irBody))
        }
    }

    private mutating func checkCall(callee: Expr, args: [Arg], span: Span) -> IRExpr {
        // Member call: base.member(args) — an actor send or an instance method.
        if case .member(let base, let name, _) = callee {
            let recv = checkExpr(base)
            if case .named(let typeName, let kind) = recv.type {
                // Actor send: base.handler(args).
                if kind == .actor_, let handler = actors[typeName]?.handlers.first(where: { $0.name == name }) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: handler.params.map { resolve($0.type) }, at: span)
                    return IRExpr(type: resolve(handler.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // Instance method on a struct/enum/class value.
                if let method = methodDecl(typeName, kind, name) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: method.params.map { resolve($0.type) }, at: span)
                    return IRExpr(type: resolve(method.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
            }
            if recv.type != .error {
                diags.error("value of type '\(recv.type)' has no method '\(name)'", at: span)
            }
            return IRExpr(type: .error, span: span, kind: .methodCall(receiver: recv, method: name,
                                                                       args: args.map { checkExpr($0.value) }))
        }

        if case .ident(let name, _) = callee {
            // print — accepts zero or one arg of any printable type.
            if name == "print" {
                let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
                return IRExpr(type: .void, span: span, kind: .call(callee: irVar(name, .void, span), args: irArgs))
            }
            // Construction: TypeName(...) for struct/class/actor.
            if let k = kindOf(name), k != .enum_ {
                let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
                return IRExpr(type: .named(name, k), span: span, kind: .construct(typeName: name, args: irArgs))
            }
            // Named function / non-print builtin.
            if let sig = funcs[name] {
                let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
                checkArgTypes(irArgs.map(\.value), against: sig.params, at: span)
                let calleeType = Type.function(params: sig.params, ret: sig.ret)
                return IRExpr(type: sig.ret, span: span, kind: .call(callee: irVar(name, calleeType, span), args: irArgs))
            }
        }

        // Fallback: type the callee; call it if it is a function value.
        let c = checkExpr(callee)
        let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
        if case .function(_, let ret) = c.type {
            return IRExpr(type: ret, span: span, kind: .call(callee: c, args: irArgs))
        }
        if c.type != .error {
            diags.error("value of type '\(c.type)' is not callable", at: span)
        }
        return IRExpr(type: .error, span: span, kind: .call(callee: c, args: irArgs))
    }

    // MARK: - Type checks

    private func fieldType(of type: Type, field: String, at span: Span) -> Type {
        guard case .named(let name, let kind) = type else {
            if type != .error { diags.error("value of type '\(type)' has no field '\(field)'", at: span) }
            return .error
        }
        let fields: [VarField]
        switch kind {
        case .struct_: fields = structs[name]?.fields ?? []
        case .class_:  fields = classes[name]?.fields ?? []
        case .actor_:  fields = actors[name]?.fields.map { VarField(name: $0.name, type: $0.type, span: $0.span) } ?? []
        case .enum_:   fields = []
        }
        if let f = fields.first(where: { $0.name == field }) { return resolve(f.type) }
        diags.error("type '\(name)' has no field '\(field)'", at: span)
        return .error
    }

    private func binaryResult(_ op: BinOp, _ lhs: IRExpr, _ rhs: IRExpr, at span: Span) -> Type {
        switch op {
        case .add, .sub, .mul, .div:
            if lhs.type != .int && lhs.type != .error {
                diags.error("arithmetic requires Int, got '\(lhs.type)'", at: lhs.span)
            }
            if rhs.type != .int && rhs.type != .error {
                diags.error("arithmetic requires Int, got '\(rhs.type)'", at: rhs.span)
            }
            return .int
        case .eq, .neq, .lt, .gt, .lte, .gte:
            return .bool
        }
    }

    private func checkArgTypes(_ args: [IRExpr], against params: [Type], at span: Span) {
        if args.count != params.count {
            diags.error("expected \(params.count) argument(s), got \(args.count)", at: span)
            return
        }
        for (a, p) in zip(args, params) where a.type != p && a.type != .error && p != .error {
            diags.error("argument of type '\(a.type)' does not match expected '\(p)'", at: a.span)
        }
    }

    private func irVar(_ name: String, _ type: Type, _ span: Span) -> IRExpr {
        IRExpr(type: type, span: span, kind: .varRef(name))
    }

    // MARK: - Scopes

    private mutating func pushScope() { scopes.append([:]) }
    private mutating func popScope()  { scopes.removeLast() }
    private mutating func declare(_ name: String, _ type: Type) { scopes[scopes.count - 1][name] = type }

    private func lookup(_ name: String) -> Type? {
        for scope in scopes.reversed() { if let t = scope[name] { return t } }
        return nil
    }
}
