import noir
import support
// Monomorphization — the specialization pass (design: generics.md §6, compiler.md §1).
// An IR→IR pass, run after Sema/exhaustiveness and before codegen.
//
// Under a single compilation unit there is no ABI boundary to preserve, so this
// specializes **every** generic instantiation (Swift's whole-module optimization).
// It walks the module from its concrete roots (non-generic funcs, `main`), discovers
// generic instantiations — `.call` type arguments and `.generic` types — to a
// worklist/fixpoint, and **clones each generic decl with its type parameters replaced
// by concrete types**, dropping the `generics` list. The result is a fully-concrete
// `NOIRModule`: no `.typeParam`, no `.generic`, no witness parameters in the specialized
// decls. Codegen then emits direct calls / inline fields / no boxing through its
// existing concrete paths — a requirement call whose receiver is now concrete simply
// isn't taken by codegen's `.typeParam` witness-dispatch branch, so it devirtualizes.
//
// `any I` is left untouched (inherently dynamic — the explicit erasure opt-in), so the
// witness tables / conformances / interfaces ride through unchanged.
//
// Whole-program mono is a policy for the single-CU world; when multi-file/module builds
// land it is rescoped to within-module (cross-module specialization opt-in), preserving
// the stable-ABI default at module edges (generics.md §6).

public func monomorphize(_ module: NOIRModule, into diags: DiagnosticSink) -> NOIRModule {
    Monomorphizer(module: module, diags: diags).run()
}

private final class Monomorphizer {
    let module: NOIRModule
    let diags: DiagnosticSink

    // Generic templates (never emitted directly; only their specializations are).
    var genericFuncs:   [String: NOIRFunc]   = [:]
    var genericStructs: [String: NOIRStruct] = [:]
    var genericEnums:   [String: NOIREnum]   = [:]
    var genericClasses: [String: NOIRClass]  = [:]
    var baseKind:       [String: NamedKind] = [:]   // generic type base → its kind

    var out: [NOIRDecl] = []
    // Specialized names already emitted (guards recursion) + requested (dedupes the worklist).
    var doneFuncs = Set<String>(), doneTypes = Set<String>()
    var reqFuncs  = Set<String>(), reqTypes  = Set<String>()
    var funcWork: [(base: String, args: [Type])] = []
    var typeWork: [(base: String, args: [Type])] = []
    var recursionErrored = false

    // Cap on type-argument nesting depth (counted as `<` in a specialized name) — beyond
    // this we assume polymorphic recursion (`f<Box<T>>` → `f<Box<Box<T>>>` → …) and error.
    let depthCap = 64

    init(module: NOIRModule, diags: DiagnosticSink) { self.module = module; self.diags = diags }

    func run() -> NOIRModule {
        // Register every generic template first (a root may reference one declared later).
        var roots: [NOIRDecl] = []
        for decl in module.decls {
            switch decl {
            case .funcDecl(let f)   where !f.generics.isEmpty: genericFuncs[f.name]   = f
            case .structDecl(let s) where !s.generics.isEmpty: genericStructs[s.name] = s; baseKind[s.name] = .struct_
            case .enumDecl(let e)   where !e.generics.isEmpty: genericEnums[e.name]   = e; baseKind[e.name] = .enum_
            case .classDecl(let c)  where !c.generics.isEmpty: genericClasses[c.name] = c; baseKind[c.name] = .class_
            default: roots.append(decl)
            }
        }
        for r in roots { out.append(rewriteDecl(r, [:])) }
        while !funcWork.isEmpty || !typeWork.isEmpty {
            while let w = funcWork.popLast() { specializeFunc(w.base, w.args) }
            while let w = typeWork.popLast() { specializeType(w.base, w.args) }
        }
        return NOIRModule(decls: out, interfaces: module.interfaces, conformances: module.conformances,
                        composites: module.composites, opaqueUnderlyings: module.opaqueUnderlyings)
    }

    // MARK: - Specialization

    private func specializeFunc(_ base: String, _ args: [Type]) {
        let name = specName(base, args)
        guard doneFuncs.insert(name).inserted, let tmpl = genericFuncs[base] else { return }
        guard !overDepth(name, at: tmpl.span) else { return }
        let subst = Dictionary(uniqueKeysWithValues: zip(tmpl.generics.map(\.name), args))
        out.append(.funcDecl(rewriteFunc(tmpl, subst, name: name)))
    }

    private func specializeType(_ base: String, _ args: [Type]) {
        let name = specName(base, args)
        guard doneTypes.insert(name).inserted else { return }
        if let s = genericStructs[base] {
            guard !overDepth(name, at: s.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            out.append(.structDecl(NOIRStruct(name: name, generics: [],
                fields: s.fields.map { rewriteField($0, subst) },
                methods: s.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: s.span)))
        } else if let e = genericEnums[base] {
            guard !overDepth(name, at: e.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(e.generics.map(\.name), args))
            out.append(.enumDecl(NOIREnum(name: name, generics: [],
                cases: e.cases.map { c in NOIREnumCase(name: c.name, fields: c.fields.map { rewriteField($0, subst) }, span: c.span) },
                methods: e.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: e.span)))
        } else if let c = genericClasses[base] {
            guard !overDepth(name, at: c.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(c.generics.map(\.name), args))
            out.append(.classDecl(NOIRClass(name: name, generics: [],
                fields: c.fields.map { rewriteField($0, subst) },
                methods: c.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: c.span)))
        }
    }

    private func overDepth(_ name: String, at span: Span) -> Bool {
        guard name.lazy.filter({ $0 == "<" }).count > depthCap else { return false }
        if !recursionErrored {
            recursionErrored = true
            diags.error("possible infinite specialization (polymorphic recursion) while monomorphizing '\(name.prefix(40))…'", at: span)
        }
        return true
    }

    // MARK: - Decl rewriting (roots use an empty subst; templates their instantiation's)

    private func rewriteDecl(_ d: NOIRDecl, _ s: [String: Type]) -> NOIRDecl {
        switch d {
        case .funcDecl(let f):   return .funcDecl(rewriteFunc(f, s, name: f.name))
        case .structDecl(let t): return .structDecl(NOIRStruct(name: t.name, generics: [],
            fields: t.fields.map { rewriteField($0, s) }, methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .enumDecl(let t):   return .enumDecl(NOIREnum(name: t.name, generics: [],
            cases: t.cases.map { c in NOIREnumCase(name: c.name, fields: c.fields.map { rewriteField($0, s) }, span: c.span) },
            methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .classDecl(let t):  return .classDecl(NOIRClass(name: t.name, generics: [],
            fields: t.fields.map { rewriteField($0, s) }, methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .actorDecl(let a):  return .actorDecl(rewriteActor(a, s))
        }
    }

    private func rewriteFunc(_ f: NOIRFunc, _ s: [String: Type], name: String) -> NOIRFunc {
        NOIRFunc(name: name, generics: [],
               params: f.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
               returnType: resolveType(f.returnType, s),
               body: f.body.map { rewriteStmt($0, s) }, isMutating: f.isMutating, span: f.span)
    }

    private func rewriteField(_ f: NOIRField, _ s: [String: Type]) -> NOIRField {
        NOIRField(name: f.name, type: resolveType(f.type, s), isMutable: f.isMutable, span: f.span)
    }

    private func rewriteActor(_ a: NOIRActor, _ s: [String: Type]) -> NOIRActor {
        NOIRActor(name: a.name,
                fields: a.fields.map { NOIRActorField(name: $0.name, type: resolveType($0.type, s),
                                                    initializer: $0.initializer.map { rewriteExpr($0, s) }, span: $0.span) },
                handlers: a.handlers.map { h in NOIRHandler(name: h.name,
                    params: h.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
                    returnType: resolveType(h.returnType, s), body: h.body.map { rewriteStmt($0, s) }, span: h.span) },
                span: a.span)
    }

    // MARK: - Statement / expression rewriting

    private func rewriteStmt(_ st: NOIRStmt, _ s: [String: Type]) -> NOIRStmt {
        let kind: StmtKind
        switch st.kind {
        case .letBinding(let n, let m, let v):    kind = .letBinding(name: n, isMutable: m, value: rewriteExpr(v, s))
        case .spawnLet(let n, let v, let rt):     kind = .spawnLet(name: n, value: rewriteExpr(v, s), resultType: resolveType(rt, s))
        case .assign(let t, let v):               kind = .assign(target: rewriteExpr(t, s), value: rewriteExpr(v, s))
        case .compoundAssign(let t, let v):       kind = .compoundAssign(target: rewriteExpr(t, s), value: rewriteExpr(v, s))
        case .ret(let e):                         kind = .ret(e.map { rewriteExpr($0, s) })
        case .ifStmt(let c, let t, let e):        kind = .ifStmt(cond: rewriteExpr(c, s), then: t.map { rewriteStmt($0, s) }, else: e.map { $0.map { rewriteStmt($0, s) } })
        case .whileStmt(let c, let body):         kind = .whileStmt(cond: rewriteExpr(c, s), body: body.map { rewriteStmt($0, s) })
        case .breakStmt:                          kind = .breakStmt
        case .continueStmt:                       kind = .continueStmt
        case .switchStmt(let sw):
            kind = .switchStmt(NOIRSwitch(subject: rewriteExpr(sw.subject, s),
                arms: sw.arms.map { arm in NOIRCaseArm(caseName: arm.caseName,
                    bindings: arm.bindings.map { NOIRBinding(name: $0.name, type: resolveType($0.type, s)) },
                    body: arm.body.map { rewriteStmt($0, s) }, span: arm.span) }))
        case .exprStmt(let e):                    kind = .exprStmt(rewriteExpr(e, s))
        }
        return NOIRStmt(kind: kind, span: st.span)
    }

    private func rewriteExpr(_ e: NOIRExpr, _ s: [String: Type]) -> NOIRExpr {
        let newType = resolveType(e.type, s)
        let kind: ExprKind
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef:
            kind = e.kind
        case .fieldAccess(let base, let field):
            kind = .fieldAccess(base: rewriteExpr(base, s), field: field)
        case .construct(let typeName, let args):
            kind = .construct(typeName: namedName(newType) ?? typeName, args: rewriteArgs(args, s))
        case .enumInit(let typeName, let caseName, let args):
            kind = .enumInit(typeName: namedName(newType) ?? typeName, caseName: caseName, args: rewriteArgs(args, s))
        case .methodCall(let recv, let method, let args):
            kind = .methodCall(receiver: rewriteExpr(recv, s), method: method, args: args.map { rewriteExpr($0, s) })
        case .call(let callee, let args, let typeArgs):
            let rArgs = typeArgs.map { resolveType($0, s) }
            if case .varRef(let fname) = callee.kind, genericFuncs[fname] != nil, !rArgs.isEmpty {
                enqueueFunc(fname, rArgs)
                let sn = specName(fname, rArgs)
                // Codegen resolves a global call by name (`funcs[sn]`), never the callee's
                // type, so leave it a placeholder — resolving the generic function type here
                // would recurse into its unbound `T`s and enqueue stray `Box<T>` specializations.
                let newCallee = NOIRExpr(type: .void, span: callee.span, kind: .varRef(sn))
                kind = .call(callee: newCallee, args: rewriteArgs(args, s), typeArgs: [])
            } else {
                kind = .call(callee: rewriteExpr(callee, s), args: rewriteArgs(args, s), typeArgs: rArgs)
            }
        case .binary(let op, let l, let r):
            kind = .binary(op, rewriteExpr(l, s), rewriteExpr(r, s))
        case .closure(let params, let body):
            kind = .closure(params: params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
                            body: body.map { rewriteStmt($0, s) })
        case .box(let value, let interfaces):
            kind = .box(value: rewriteExpr(value, s), interfaces: interfaces)
        case .arrayLit(let elements):
            kind = .arrayLit(elements: elements.map { rewriteExpr($0, s) })
        case .index(let base, let idx):
            kind = .index(base: rewriteExpr(base, s), idx: rewriteExpr(idx, s))
        }
        return NOIRExpr(type: newType, span: e.span, kind: kind)
    }

    private func rewriteArgs(_ args: [NOIRArg], _ s: [String: Type]) -> [NOIRArg] {
        args.map { NOIRArg(label: $0.label, value: rewriteExpr($0.value, s)) }
    }

    // MARK: - Types

    // Substitute type parameters, then rename any applied generic `Box<Int>` to a fresh
    // concrete `.named("Box<Int>")` and enqueue its specialization.
    private func resolveType(_ t: Type, _ s: [String: Type]) -> Type {
        switch t {
        case .typeParam(let p):
            if let bound = s[p] { return resolveType(bound, [:]) }
            return t
        case .generic(let base, let args):
            let rargs = args.map { resolveType($0, s) }
            enqueueType(base, rargs)
            return .named(specName(base, rargs), baseKind[base] ?? .struct_)
        case .function(let ps, let r):
            return .function(params: ps.map { resolveType($0, s) }, ret: resolveType(r, s))
        case .array(let e):
            return .array(resolveType(e, s))
        default:
            return t
        }
    }

    private func enqueueFunc(_ base: String, _ args: [Type]) {
        let n = specName(base, args)
        guard !doneFuncs.contains(n), reqFuncs.insert(n).inserted else { return }
        funcWork.append((base, args))
    }

    private func enqueueType(_ base: String, _ args: [Type]) {
        guard genericStructs[base] != nil || genericEnums[base] != nil || genericClasses[base] != nil else { return }
        let n = specName(base, args)
        guard !doneTypes.contains(n), reqTypes.insert(n).inserted else { return }
        typeWork.append((base, args))
    }

    // The specialized decl name: `base<argKey,argKey>` — carried as a nominal name; Mangle
    // 9-encodes the `<`, `>`, `,` (compiler.md §2a) into a valid C identifier.
    private func specName(_ base: String, _ args: [Type]) -> String {
        args.isEmpty ? base : base + "<" + args.map(typeKey).joined(separator: ",") + ">"
    }

    // A mangling-safe key for a type argument. Named types may already carry `<…>` from a
    // prior specialization (nesting composes); function/existential/opaque types get an
    // identifier-ish rendering rather than their spaced `description`.
    private func typeKey(_ t: Type) -> String {
        switch t {
        case .int: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        case .string: return "String"
        case .void: return "Void"
        case .named(let n, _): return n
        case .generic(let b, let a): return b + "<" + a.map(typeKey).joined(separator: ",") + ">"
        case .array(let e): return "Array<" + typeKey(e) + ">"
        case .function(let p, let r): return "fn<" + (p.map(typeKey) + [typeKey(r)]).joined(separator: ",") + ">"
        case .existential(let i): return "any_" + i
        case .composition(let is_): return "any_" + is_.joined(separator: "_")
        case .opaque(let ifs, _): return "some_" + ifs.joined(separator: "_")
        case .typeParam(let p): return p
        case .selfType: return "Self"
        case .error: return "error"
        }
    }

    private func namedName(_ t: Type) -> String? {
        if case .named(let n, _) = t { return n }
        return nil
    }
}
