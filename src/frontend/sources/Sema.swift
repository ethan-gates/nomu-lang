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
    private var interfaces: [String: InterfaceDecl] = [:]   // M5 A1
    private var funcs:   [String: FnSig]      = [:]   // named functions + non-print builtins

    // Computed properties (M5 A1), by owning type then property name. Drives member
    // read → getter-call and assignment → setter-call routing during body lowering.
    private struct PropInfo { let type: Type; let hasSetter: Bool }
    private var computedProps: [String: [String: PropInfo]] = [:]

    // Lexical scope stack for locals/params (name → type + mutability).
    private var scopes: [[String: Local]] = []
    private struct Local { let type: Type; let isMutable: Bool }

    // Declared return type of the body being lowered — the contextual type for a
    // `return .case(...)` leading-dot construction (M4.10).
    private var currentReturnType: Type = .void

    // Value-type method calls, recorded during lowering with their receiver's
    // mutability; checked against inferred mutating-ness after the mutation pass (M4.11).
    private struct CallSite { let callee: String; let receiverMutable: Bool; let span: Span }
    private var methodCallSites: [CallSite] = []

    private struct FnSig { let params: [Type]; let ret: Type }

    public init(_ program: Program) { self.program = program }

    public mutating func check() -> SemaResult {
        collectGlobals()
        checkConformances()
        var decls: [IRDecl] = []
        for decl in program.decls {
            // Interfaces are abstract: validate them, but emit no IR (conformance in a
            // later slice generates the concrete witnesses that carry the defaults).
            if case .interfaceDecl(let i) = decl { checkInterface(i); continue }
            decls.append(lowerDecl(decl))
        }

        // M4.11: infer method mutating-ness, validate `let`-field / `self` writes,
        // annotate the IR, then check that mutating value-type calls have a mutable receiver.
        let mutation = analyzeMutation(IRModule(decls: decls), into: diags)
        for site in methodCallSites where mutation.mutating.contains(site.callee) && !site.receiverMutable {
            diags.error("cannot call mutating method on an immutable value — the receiver must be a 'var'", at: site.span)
        }
        return SemaResult(module: mutation.module, diagnostics: diags)
    }

    // MARK: - Global collection

    private mutating func collectGlobals() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e):   enums[e.name]   = e
            case .classDecl(let c):  classes[c.name] = c
            case .actorDecl(let a):  actors[a.name]  = a
            case .interfaceDecl(let i): interfaces[i.name] = i
            case .funcDecl(let f):
                funcs[f.name] = FnSig(params: f.params.map { resolve($0.type) },
                                      ret: resolve(f.returnType))
            case .extensionDecl:
                break   // merged into its target before Sema (M4.12)
            }
        }
        // Computed-property tables need the type dicts above populated first (a property
        // type may name any user type), so register them in a second pass.
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): registerProps(s.name, s.properties)
            case .enumDecl(let e):   registerProps(e.name, e.properties)
            case .classDecl(let c):  registerProps(c.name, c.properties)
            default: break
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
            if let k = kindOf(ref.name) {
                // A bare interface name isn't a usable type — `any I` / `some I` (later
                // slices) make the erasure explicit (interfaces.md §4.4).
                if k == .interface_ {
                    diags.error("interface type '\(ref.name)' must be written as 'any \(ref.name)' or 'some \(ref.name)'", at: ref.span)
                    return .error
                }
                return .named(ref.name, k)
            }
            diags.error("unknown type '\(ref.name)'", at: ref.span)
            return .error
        }
    }

    private func kindOf(_ name: String) -> NamedKind? {
        if structs[name] != nil { return .struct_ }
        if enums[name]   != nil { return .enum_ }
        if classes[name] != nil { return .class_ }
        if actors[name]  != nil { return .actor_ }
        if interfaces[name] != nil { return .interface_ }
        return nil
    }

    // The declared instance method `name` on a struct/enum/class, if any (T3).
    private func methodDecl(_ typeName: String, _ kind: NamedKind, _ name: String) -> FuncDecl? {
        switch kind {
        case .struct_: return structs[typeName]?.methods.first { $0.name == name }
        case .enum_:   return enums[typeName]?.methods.first { $0.name == name }
        case .class_:  return classes[typeName]?.methods.first { $0.name == name }
        case .actor_, .interface_:  return nil
        }
    }

    // MARK: - Declarations

    private mutating func lowerDecl(_ decl: TopDecl) -> IRDecl {
        switch decl {
        case .structDecl(let s):
            let fields = s.fields.map(lowerField)
            var methods = lowerMethods(s.methods, selfType: .named(s.name, .struct_), fields: fields)
            methods += lowerAccessors(s.properties, selfType: .named(s.name, .struct_), fields: fields)
            return .structDecl(IRStruct(name: s.name, fields: fields, methods: methods, span: s.span))
        case .enumDecl(let e):
            let cases = e.cases.map { IREnumCase(name: $0.name, fields: $0.fields.map(lowerField), span: $0.span) }
            var methods = lowerMethods(e.methods, selfType: .named(e.name, .enum_), fields: [])
            methods += lowerAccessors(e.properties, selfType: .named(e.name, .enum_), fields: [])
            return .enumDecl(IREnum(name: e.name, cases: cases, methods: methods, span: e.span))
        case .classDecl(let c):
            let fields = c.fields.map(lowerField)
            var methods = lowerMethods(c.methods, selfType: .named(c.name, .class_), fields: fields)
            methods += lowerAccessors(c.properties, selfType: .named(c.name, .class_), fields: fields)
            return .classDecl(IRClass(name: c.name, fields: fields, methods: methods, span: c.span))
        case .actorDecl(let a):
            return .actorDecl(lowerActor(a))
        case .funcDecl(let f):
            return .funcDecl(lowerFunc(f))
        case .interfaceDecl:
            preconditionFailure("interfaces are validated in check(), not lowered (M5 A1)")
        case .extensionDecl:
            preconditionFailure("extensions must be merged before Sema (M4.12)")
        }
    }

    // Validate an interface (M5 A1): its requirement signatures must resolve, and each
    // overridable default body must typecheck. In a default, `self` is the interface
    // type, its property requirements are visible by bare name, and `self.req(...)` /
    // `self.prop` resolve against the requirement set. No IR is retained — conformance
    // (a later slice) compiles the defaults into each conformer's witnesses.
    private mutating func checkInterface(_ i: InterfaceDecl) {
        for m in i.methods {
            for p in m.params { _ = resolve(p.type) }
            _ = resolve(m.returnType)
        }
        for p in i.properties { _ = resolve(p.type) }

        let selfType = Type.named(i.name, .interface_)
        for m in i.methods {
            guard let body = m.defaultBody else { continue }
            let params = m.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let ret = resolve(m.returnType)
            pushScope()
            declare("self", selfType)
            for p in i.properties { declare(p.name, resolve(p.type), isMutable: p.isSettable) }
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            _ = lowerBlock(body)
            currentReturnType = saved
            popScope()
        }
    }

    // A method requirement (or default) named `name` on an interface, if any.
    private func interfaceMethod(_ typeName: String, _ name: String) -> InterfaceMethod? {
        interfaces[typeName]?.methods.first { $0.name == name }
    }

    // MARK: - Conformance checking (M5 A1.3)

    // Verify each declared conformance: every requirement of the interface is satisfied
    // by a matching member (or an interface default). Struct/enum/class only — actor
    // conformance is parked post-M5 (interfaces.md §1). No witnesses yet (A1.4).
    private mutating func checkConformances() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s):
                checkConformance(s.name, s.conformances, methods: s.methods, fields: s.fields, properties: s.properties)
            case .enumDecl(let e):
                checkConformance(e.name, e.conformances, methods: e.methods, fields: [], properties: e.properties)
            case .classDecl(let c):
                checkConformance(c.name, c.conformances, methods: c.methods, fields: c.fields, properties: c.properties)
            case .actorDecl(let a):
                for conf in a.conformances {
                    diags.error("actors cannot conform to interfaces yet ('\(a.name): \(conf.name)') — parked post-M5", at: conf.span)
                }
            default:
                break
            }
        }
    }

    private mutating func checkConformance(_ typeName: String, _ conformances: [Conformance],
                                           methods: [FuncDecl], fields: [VarField], properties: [ComputedProperty]) {
        for conf in conformances {
            guard let iface = interfaces[conf.name] else {
                if kindOf(conf.name) != nil {
                    diags.error("'\(conf.name)' is not an interface; '\(typeName)' can only conform to interfaces", at: conf.span)
                } else {
                    diags.error("unknown interface '\(conf.name)'", at: conf.span)
                }
                continue
            }
            for req in iface.methods { checkMethodRequirement(req, typeName: typeName, interface: conf, methods: methods) }
            for req in iface.properties { checkPropertyRequirement(req, typeName: typeName, interface: conf, fields: fields, properties: properties) }
        }
    }

    // A method requirement is satisfied by a same-named method with matching parameter
    // types and return type, or (if none) by the interface's overridable default.
    private mutating func checkMethodRequirement(_ req: InterfaceMethod, typeName: String, interface conf: Conformance, methods: [FuncDecl]) {
        let named = methods.filter { $0.name == req.name }
        if named.contains(where: { methodMatches(req, $0) }) { return }
        if req.defaultBody != nil { return }
        if named.isEmpty {
            diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing method '\(req.name)'", at: conf.span)
        } else {
            diags.error("type '\(typeName)' does not conform to '\(conf.name)': method '\(req.name)' has the wrong signature", at: conf.span)
        }
    }

    private func methodMatches(_ req: InterfaceMethod, _ impl: FuncDecl) -> Bool {
        guard req.params.count == impl.params.count else { return false }
        for (rp, ip) in zip(req.params, impl.params) where resolve(rp.type) != resolve(ip.type) { return false }
        return resolve(req.returnType) == resolve(impl.returnType)
    }

    // A property requirement is satisfied by a stored field or computed property of the
    // same name and type; a `{ get set }` requirement needs a settable member.
    private mutating func checkPropertyRequirement(_ req: InterfacePropertyReq, typeName: String, interface conf: Conformance, fields: [VarField], properties: [ComputedProperty]) {
        let reqType = resolve(req.type)
        if let f = fields.first(where: { $0.name == req.name }) {
            if resolve(f.type) != reqType {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(resolve(f.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && !f.isMutable {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' must be a 'var' to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        if let p = properties.first(where: { $0.name == req.name }) {
            if resolve(p.type) != reqType {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': property '\(req.name)' has type '\(resolve(p.type))', expected '\(reqType)'", at: conf.span)
            } else if req.isSettable && p.setter == nil {
                diags.error("type '\(typeName)' does not conform to '\(conf.name)': computed property '\(req.name)' needs a setter to satisfy '{ get set }'", at: conf.span)
            }
            return
        }
        diags.error("type '\(typeName)' does not conform to '\(conf.name)': missing property '\(req.name)'", at: conf.span)
    }

    private func lowerField(_ f: VarField) -> IRField {
        IRField(name: f.name, type: resolve(f.type), isMutable: f.isMutable, span: f.span)
    }

    // Lower each `fun` member with `self` (immutable) and the receiver's fields
    // declared by bare name, mirroring how actor handlers see their fields (T3).
    private mutating func lowerMethods(_ methods: [FuncDecl], selfType: Type, fields: [IRField]) -> [IRFunc] {
        var out: [IRFunc] = []
        for m in methods {
            let params = m.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let ret = resolve(m.returnType)
            pushScope()
            declare("self", selfType)
            for f in fields { declare(f.name, f.type) }
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let body = lowerBlock(m.body)
            currentReturnType = saved
            popScope()
            out.append(IRFunc(name: m.name, params: params, returnType: ret, body: body, isMutating: false, span: m.span))
        }
        return out
    }

    private mutating func registerProps(_ typeName: String, _ props: [ComputedProperty]) {
        var table: [String: PropInfo] = [:]
        for p in props { table[p.name] = PropInfo(type: resolve(p.type), hasSetter: p.setter != nil) }
        computedProps[typeName] = table
    }

    // A computed property lowers to accessor methods on its type: a getter `prop.get`
    // (() -> T) and, if settable, a setter `prop.set` ((T) -> Void). The `.` keeps
    // their names out of any user method's namespace (Mangle z-encodes it), and being
    // ordinary methods they reuse method codegen, self-passing, and mutation inference
    // (the setter is inferred mutating because it writes a field).
    private mutating func lowerAccessors(_ props: [ComputedProperty], selfType: Type, fields: [IRField]) -> [IRFunc] {
        var out: [IRFunc] = []
        for p in props {
            let propType = resolve(p.type)
            let getBody = accessorBody(p.getter, returnType: propType, selfType: selfType,
                                       fields: fields, params: [], span: p.span)
            out.append(IRFunc(name: "\(p.name).get", params: [], returnType: propType,
                              body: getBody, isMutating: false, span: p.span))
            if let setter = p.setter {
                let param = IRParam(label: setter.paramName, name: setter.paramName, type: propType, span: p.span)
                let setBody = accessorBody(setter.body, returnType: .void, selfType: selfType,
                                           fields: fields, params: [param], span: p.span)
                out.append(IRFunc(name: "\(p.name).set", params: [param], returnType: .void,
                                  body: setBody, isMutating: false, span: p.span))
            }
        }
        return out
    }

    // Lowers an accessor body with `self`, the type's fields, and any accessor param in
    // scope (mirroring `lowerMethods`). A single-expression getter body is an implicit
    // `return` of that expression (the bare-body shorthand, and the common `get` form).
    private mutating func accessorBody(_ block: Block, returnType: Type, selfType: Type,
                                       fields: [IRField], params: [IRParam], span: Span) -> [IRStmt] {
        var block = block
        if returnType != .void, block.count == 1, case .expr(let e) = block[0] {
            block = [.ret(e, span: span)]
        }
        pushScope()
        declare("self", selfType)
        for f in fields { declare(f.name, f.type) }
        for p in params { declare(p.name, p.type) }
        let saved = currentReturnType; currentReturnType = returnType
        let body = lowerBlock(block)
        currentReturnType = saved
        popScope()
        return body
    }

    private mutating func lowerFunc(_ f: FuncDecl) -> IRFunc {
        let params = f.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
        let ret = resolve(f.returnType)
        pushScope()
        for p in params { declare(p.name, p.type) }
        let saved = currentReturnType; currentReturnType = ret
        let body = lowerBlock(f.body)
        currentReturnType = saved
        popScope()
        return IRFunc(name: f.name, params: params, returnType: ret, body: body, isMutating: false, span: f.span)
    }

    private mutating func lowerActor(_ a: ActorDecl) -> IRActor {
        let fields = a.fields.map { af in
            IRActorField(name: af.name, type: resolve(af.type),
                         initializer: af.initializer.map { checkExpr($0) }, span: af.span)
        }
        var handlers: [IRHandler] = []
        for h in a.handlers {
            let params = h.params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let ret = resolve(h.returnType)
            pushScope()
            for f in fields { declare(f.name, f.type) }   // handler body sees actor fields by name
            for p in params { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = ret
            let body = lowerBlock(h.body)
            currentReturnType = saved
            popScope()
            handlers.append(IRHandler(name: h.name, params: params, returnType: ret, body: body, span: h.span))
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
            let annotated = b.type.map { resolve($0) }
            let value = checkExpr(b.value, expected: annotated)
            let type = annotated ?? value.type
            declare(b.name, type, isMutable: b.isMutable)
            return IRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)

        case .spawnLet(let name, _, let value, let span):
            let v = checkExpr(value)
            declare(name, v.type)   // reading a spawn binding yields its result value
            return IRStmt(kind: .spawnLet(name: name, value: v, resultType: v.type), span: span)

        case .assign(let lhs, let rhs, let span):
            // A write to a computed property lowers to a setter accessor call (M5 A1).
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(base)
                if case .named(let tn, let kind) = b.type, let info = computedProps[tn]?[field] {
                    guard info.hasSetter else {
                        diags.error("cannot assign to read-only computed property '\(field)'", at: span)
                        return IRStmt(kind: .exprStmt(checkExpr(rhs, expected: info.type)), span: span)
                    }
                    let value = checkExpr(rhs, expected: info.type)
                    // The setter mutates the value; on a value type it needs a mutable receiver.
                    if kind != .class_ {
                        methodCallSites.append(CallSite(callee: "\(tn).\(field).set",
                                                        receiverMutable: isMutableReceiver(base), span: span))
                    }
                    let call = IRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return IRStmt(kind: .exprStmt(call), span: span)
                }
                let ftype = fieldType(of: b.type, field: field, at: mspan)
                let target = IRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(target)
                return IRStmt(kind: .assign(target: target, value: checkExpr(rhs)), span: span)
            }
            let target = checkExpr(lhs)
            rejectLetFieldTarget(target)
            return IRStmt(kind: .assign(target: target, value: checkExpr(rhs)), span: span)

        case .compoundAssign(let lhs, let rhs, let span):
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(base)
                if case .named(let tn, _) = b.type, computedProps[tn]?[field] != nil {
                    diags.error("compound assignment ('+=') to a computed property is not supported yet", at: span)
                    return IRStmt(kind: .exprStmt(checkExpr(rhs)), span: span)
                }
                let ftype = fieldType(of: b.type, field: field, at: mspan)
                let target = IRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(target)
                return IRStmt(kind: .compoundAssign(target: target, value: checkExpr(rhs)), span: span)
            }
            let target = checkExpr(lhs)
            rejectLetFieldTarget(target)
            return IRStmt(kind: .compoundAssign(target: target, value: checkExpr(rhs)), span: span)

        case .ret(let e, let span):
            return IRStmt(kind: .ret(e.map { checkExpr($0, expected: currentReturnType) }), span: span)

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

    // `expected` carries a contextual type inward (binding annotation, return
    // position, call-argument slot) so leading-dot `.case` construction can infer
    // its enum (M4.10). nil elsewhere; most expressions ignore it.
    private mutating func checkExpr(_ e: Expr, expected: Type? = nil) -> IRExpr {
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
            // Qualified no-payload enum construction: `EnumType.case`. (A payload case
            // used bare falls through buildEnumInit as a wrong-arity error.)
            if case .ident(let typeName, _) = base, lookup(typeName) == nil, enums[typeName] != nil {
                return buildEnumInit(typeName, field, [], at: span)
            }
            let b = checkExpr(base)
            // A property-requirement read inside an interface default (self: interface).
            if case .named(let tn, .interface_) = b.type,
               let prop = interfaces[tn]?.properties.first(where: { $0.name == field }) {
                return IRExpr(type: resolve(prop.type), span: span, kind: .fieldAccess(base: b, field: field))
            }
            // A computed-property read lowers to a getter accessor call (M5 A1).
            if case .named(let tn, _) = b.type, let info = computedProps[tn]?[field] {
                return IRExpr(type: info.type, span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            let type = fieldType(of: b.type, field: field, at: span)
            return IRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))

        case .implicitMember(let name, let span):
            return buildImplicitEnum(name, [], expected: expected, at: span)

        case .binary(let op, let l, let r, let span):
            let lhs = checkExpr(l), rhs = checkExpr(r)
            let type = binaryResult(op, lhs, rhs, at: span)
            return IRExpr(type: type, span: span, kind: .binary(op, lhs, rhs))

        case .call(let callee, let args, let span):
            return checkCall(callee: callee, args: args, span: span, expected: expected)

        case .closure(let params, let ret, let body, let span):
            let ps = params.map { IRParam(label: $0.label, name: $0.name, type: resolve($0.type), span: $0.span) }
            let retTy = resolve(ret)
            pushScope()
            for p in ps { declare(p.name, p.type) }
            let saved = currentReturnType; currentReturnType = retTy
            let irBody = lowerBlock(body)
            currentReturnType = saved
            popScope()
            let type = Type.function(params: ps.map(\.type), ret: retTy)
            return IRExpr(type: type, span: span, kind: .closure(params: ps, body: irBody))
        }
    }

    private mutating func checkCall(callee: Expr, args: [Arg], span: Span, expected: Type? = nil) -> IRExpr {
        // Qualified enum construction: `EnumType.case(args)`.
        if case .member(let base, let caseName, _) = callee,
           case .ident(let typeName, _) = base, lookup(typeName) == nil, enums[typeName] != nil {
            return buildEnumInit(typeName, caseName, args, at: span)
        }
        // Leading-dot enum construction: `.case(args)` — enum inferred from context.
        if case .implicitMember(let caseName, _) = callee {
            return buildImplicitEnum(caseName, args, expected: expected, at: span)
        }
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
                // Requirement call inside an interface default (self: interface).
                if kind == .interface_, let req = interfaceMethod(typeName, name) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: req.params.map { resolve($0.type) }, at: span)
                    return IRExpr(type: resolve(req.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // Instance method on a struct/enum/class value.
                if let method = methodDecl(typeName, kind, name) {
                    let irArgs = args.map { checkExpr($0.value) }
                    checkArgTypes(irArgs, against: method.params.map { resolve($0.type) }, at: span)
                    // Value types (struct/enum) get the mutating-receiver check; classes are
                    // reference types, so a mutating method is callable on any binding.
                    if kind != .class_ {
                        methodCallSites.append(CallSite(callee: "\(typeName).\(name)",
                                                        receiverMutable: isMutableReceiver(base), span: span))
                    }
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
                let irArgs = checkArgs(args, expectedParams: sig.params)
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

    // Assigning to a `let` field is rejected (M4.10 field-level immutability). Bare
    // field writes inside methods are already caught by the AST Typechecker (self is
    // read-only); this covers `value.field = …` targets on struct/class values.
    private func rejectLetFieldTarget(_ target: IRExpr) {
        guard case .fieldAccess(let base, let field) = target.kind,
              case .named(let typeName, let kind) = base.type else { return }
        let fields: [VarField]
        switch kind {
        case .struct_: fields = structs[typeName]?.fields ?? []
        case .class_:  fields = classes[typeName]?.fields ?? []
        default:       return
        }
        if let f = fields.first(where: { $0.name == field }), !f.isMutable {
            diags.error("cannot assign to 'let' field '\(field)'", at: target.span)
        }
    }

    private func fieldType(of type: Type, field: String, at span: Span) -> Type {
        guard case .named(let name, let kind) = type else {
            if type != .error { diags.error("value of type '\(type)' has no field '\(field)'", at: span) }
            return .error
        }
        let fields: [VarField]
        switch kind {
        case .struct_: fields = structs[name]?.fields ?? []
        case .class_:  fields = classes[name]?.fields ?? []
        case .actor_:  fields = actors[name]?.fields.map { VarField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) } ?? []
        case .enum_, .interface_:   fields = []
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

    // Check call args, threading a per-position expected type inward (for leading-dot
    // enum inference); `expectedParams` is nil where the slots aren't known.
    private mutating func checkArgs(_ args: [Arg], expectedParams: [Type]?) -> [IRArg] {
        var out: [IRArg] = []
        for (i, a) in args.enumerated() {
            let exp = expectedParams.flatMap { i < $0.count ? $0[i] : nil }
            out.append(IRArg(label: a.label, value: checkExpr(a.value, expected: exp)))
        }
        return out
    }

    // Leading-dot `.case(...)`: resolve the enum from the expected type, then build.
    private mutating func buildImplicitEnum(_ caseName: String, _ args: [Arg], expected: Type?, at span: Span) -> IRExpr {
        guard case .named(let enumName, .enum_)? = expected, enums[enumName] != nil else {
            diags.error("cannot infer enum type for '.\(caseName)' here", at: span)
            let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
            return IRExpr(type: .error, span: span, kind: .enumInit(typeName: "", caseName: caseName, args: irArgs))
        }
        return buildEnumInit(enumName, caseName, args, at: span)
    }

    // `EnumType.case(args)` → a typed enumInit, checking the payload against the case.
    private mutating func buildEnumInit(_ enumName: String, _ caseName: String, _ args: [Arg], at span: Span) -> IRExpr {
        let enumType = Type.named(enumName, .enum_)
        guard let caseDecl = enums[enumName]?.cases.first(where: { $0.name == caseName }) else {
            diags.error("enum '\(enumName)' has no case '\(caseName)'", at: span)
            let irArgs = args.map { IRArg(label: $0.label, value: checkExpr($0.value)) }
            return IRExpr(type: enumType, span: span, kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
        }
        let irArgs = matchEnumArgs(args, fields: caseDecl.fields, case: caseName, at: span)
        return IRExpr(type: enumType, span: span, kind: .enumInit(typeName: enumName, caseName: caseName, args: irArgs))
    }

    // Pair payload args to the case's declared fields (by label, else by position),
    // type-checking each against its field; arity/type mismatches are diagnostics.
    private mutating func matchEnumArgs(_ args: [Arg], fields: [VarField], case caseName: String, at span: Span) -> [IRArg] {
        if args.count != fields.count {
            diags.error("case '\(caseName)' expects \(fields.count) argument(s), got \(args.count)", at: span)
        }
        var out: [IRArg] = []
        for (i, field) in fields.enumerated() {
            let fieldTy = resolve(field.type)
            guard let arg = args.first(where: { $0.label == field.name }) ?? (i < args.count ? args[i] : nil) else { continue }
            let v = checkExpr(arg.value, expected: fieldTy)
            if v.type != fieldTy && v.type != .error && fieldTy != .error {
                diags.error("argument of type '\(v.type)' does not match expected '\(fieldTy)'", at: v.span)
            }
            out.append(IRArg(label: field.name, value: v))
        }
        return out
    }

    private func irVar(_ name: String, _ type: Type, _ span: Span) -> IRExpr {
        IRExpr(type: type, span: span, kind: .varRef(name))
    }

    // A mutable receiver for a mutating method call (M4.11, conservative first cut):
    // a `var` local, or `self` (mutation through self makes the enclosing method
    // mutating by inference, which keeps the check sound). Anything else — a `let`
    // local, a parameter, a field access, a temporary — is immutable.
    private func isMutableReceiver(_ base: Expr) -> Bool {
        if case .ident(let name, _) = base {
            return name == "self" || lookupMutable(name)
        }
        return false
    }

    // MARK: - Scopes

    private mutating func pushScope() { scopes.append([:]) }
    private mutating func popScope()  { scopes.removeLast() }
    private mutating func declare(_ name: String, _ type: Type, isMutable: Bool = false) {
        scopes[scopes.count - 1][name] = Local(type: type, isMutable: isMutable)
    }

    private func lookup(_ name: String) -> Type? {
        for scope in scopes.reversed() { if let l = scope[name] { return l.type } }
        return nil
    }

    // Whether `name` is a mutable (`var`) local — used by the M4.11 caller check.
    private func lookupMutable(_ name: String) -> Bool {
        for scope in scopes.reversed() { if let l = scope[name] { return l.isMutable } }
        return false
    }
}
