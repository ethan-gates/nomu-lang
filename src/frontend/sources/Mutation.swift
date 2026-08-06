// Mutation analysis (M4.11) — an IR pass over the typed module.
//
// Infers which value/reference-type methods mutate `self`, validates writes to
// `let` fields and to `self` itself, and annotates each method's `isMutating`
// flag. A method is mutating iff it writes a field of `self`, or calls a mutating
// method on `self` (transitive — a fixpoint over each type's own methods). The
// caller-side check (a mutating value-type method needs a mutable receiver) lives
// in `Sema`, where local `var`/`let` mutability is known.

public struct MutationResult {
    public let module: IRModule
    public let mutating: Set<String>   // "TypeName.methodName" for each mutating method
}

public func analyzeMutation(_ module: IRModule, into diags: DiagnosticSink) -> MutationResult {
    let a = MutationAnalyzer(diags: diags)
    return a.run(module)
}

private func methodKey(_ type: String, _ method: String) -> String { "\(type).\(method)" }

private final class MutationAnalyzer {
    private let diags: DiagnosticSink
    private var fieldMut: [String: [String: Bool]] = [:]   // type → (field name → isMutable)

    init(diags: DiagnosticSink) { self.diags = diags }

    func run(_ module: IRModule) -> MutationResult {
        for decl in module.decls {
            switch decl {
            case .structDecl(let s): fieldMut[s.name] = fieldDict(s.fields)
            case .classDecl(let c):  fieldMut[c.name] = fieldDict(c.fields)
            case .enumDecl(let e):   fieldMut[e.name] = [:]      // no stored fields
            default: break
            }
        }

        // Per method: does it write a field directly, and what methods does it call on self?
        var direct: [String: Bool] = [:]
        var selfCalls: [String: Set<String>] = [:]
        for (typeName, m) in allMethods(module) {
            var d = false
            var calls: Set<String> = []
            scan(m.body, type: typeName, direct: &d, selfCalls: &calls)
            direct[methodKey(typeName, m.name)] = d
            selfCalls[methodKey(typeName, m.name)] = calls
        }

        // Fixpoint: mutating if it writes directly, or calls a mutating method (same type) on self.
        var mutating = Set(direct.filter { $0.value }.map { $0.key })
        var changed = true
        while changed {
            changed = false
            for (typeName, m) in allMethods(module) {
                let k = methodKey(typeName, m.name)
                if mutating.contains(k) { continue }
                if selfCalls[k]?.contains(where: { mutating.contains(methodKey(typeName, $0)) }) == true {
                    mutating.insert(k)
                    changed = true
                }
            }
        }

        return MutationResult(module: annotate(module, mutating: mutating), mutating: mutating)
    }

    private func fieldDict(_ fs: [IRField]) -> [String: Bool] {
        var d: [String: Bool] = [:]
        for f in fs { d[f.name] = f.isMutable }
        return d
    }

    private func allMethods(_ module: IRModule) -> [(String, IRFunc)] {
        var out: [(String, IRFunc)] = []
        for decl in module.decls {
            switch decl {
            case .structDecl(let s): for m in s.methods { out.append((s.name, m)) }
            case .classDecl(let c):  for m in c.methods { out.append((c.name, m)) }
            case .enumDecl(let e):   for m in e.methods { out.append((e.name, m)) }
            default: break
            }
        }
        return out
    }

    // MARK: - Scan a method body for field writes + self-method-calls

    private func scan(_ stmts: [IRStmt], type: String, direct: inout Bool, selfCalls: inout Set<String>) {
        for s in stmts { scanStmt(s, type: type, direct: &direct, selfCalls: &selfCalls) }
    }

    private func scanStmt(_ stmt: IRStmt, type: String, direct: inout Bool, selfCalls: inout Set<String>) {
        switch stmt.kind {
        case .letBinding(_, _, let v):   scanExpr(v, type: type, selfCalls: &selfCalls)
        case .spawnLet(_, let v, _):     scanExpr(v, type: type, selfCalls: &selfCalls)
        case .exprStmt(let v):           scanExpr(v, type: type, selfCalls: &selfCalls)
        case .ret(let v):                if let v { scanExpr(v, type: type, selfCalls: &selfCalls) }
        case .assign(let t, let v), .compoundAssign(let t, let v):
            checkWrite(t, type: type, direct: &direct)
            scanExpr(t, type: type, selfCalls: &selfCalls)
            scanExpr(v, type: type, selfCalls: &selfCalls)
        case .ifStmt(let cond, let then, let els):
            scanExpr(cond, type: type, selfCalls: &selfCalls)
            scan(then, type: type, direct: &direct, selfCalls: &selfCalls)
            if let els { scan(els, type: type, direct: &direct, selfCalls: &selfCalls) }
        case .whileStmt(let cond, let body):
            scanExpr(cond, type: type, selfCalls: &selfCalls)
            scan(body, type: type, direct: &direct, selfCalls: &selfCalls)
        case .breakStmt, .continueStmt:
            break
        case .switchStmt(let sw):
            scanExpr(sw.subject, type: type, selfCalls: &selfCalls)
            for arm in sw.arms { scan(arm.body, type: type, direct: &direct, selfCalls: &selfCalls) }
        }
    }

    // A write whose target is a field of `self` (bare name or `self.field`) marks the
    // method mutating; writing a `let` field or reassigning `self` is a diagnostic.
    private func checkWrite(_ target: IRExpr, type: String, direct: inout Bool) {
        switch target.kind {
        case .varRef(let name):
            if name == "self" {
                diags.error("cannot reassign 'self'", at: target.span)
            } else if let mutable = fieldMut[type]?[name] {
                if !mutable { diags.error("cannot assign to 'let' field '\(name)'", at: target.span) }
                direct = true
            }
        case .fieldAccess(let base, let field):
            if case .varRef("self") = base.kind, let mutable = fieldMut[type]?[field] {
                if !mutable { diags.error("cannot assign to 'let' field '\(field)'", at: target.span) }
                direct = true
            }
        default:
            break
        }
    }

    // Collect method names called on `self`; closures are treated as opaque.
    private func scanExpr(_ e: IRExpr, type: String, selfCalls: inout Set<String>) {
        switch e.kind {
        case .methodCall(let recv, let method, let args):
            if case .varRef("self") = recv.kind { selfCalls.insert(method) }
            scanExpr(recv, type: type, selfCalls: &selfCalls)
            for a in args { scanExpr(a, type: type, selfCalls: &selfCalls) }
        case .fieldAccess(let base, _):
            scanExpr(base, type: type, selfCalls: &selfCalls)
        case .construct(_, let args), .enumInit(_, _, let args):
            for a in args { scanExpr(a.value, type: type, selfCalls: &selfCalls) }
        case .call(let callee, let args, _):
            scanExpr(callee, type: type, selfCalls: &selfCalls)
            for a in args { scanExpr(a.value, type: type, selfCalls: &selfCalls) }
        case .binary(_, let l, let r):
            scanExpr(l, type: type, selfCalls: &selfCalls)
            scanExpr(r, type: type, selfCalls: &selfCalls)
        case .box(let v, _):
            scanExpr(v, type: type, selfCalls: &selfCalls)
        case .arrayLit(let elements):
            for el in elements { scanExpr(el, type: type, selfCalls: &selfCalls) }
        case .index(let base, let idx):
            scanExpr(base, type: type, selfCalls: &selfCalls)
            scanExpr(idx, type: type, selfCalls: &selfCalls)
        case .intLit, .boolLit, .stringLit, .varRef, .closure:
            break
        }
    }

    // MARK: - Rebuild the module with each method's isMutating set

    private func annotate(_ module: IRModule, mutating: Set<String>) -> IRModule {
        func ann(_ typeName: String, _ ms: [IRFunc]) -> [IRFunc] {
            ms.map { m in
                IRFunc(name: m.name, generics: m.generics, params: m.params, returnType: m.returnType, body: m.body,
                       isMutating: mutating.contains(methodKey(typeName, m.name)), span: m.span)
            }
        }
        let decls: [IRDecl] = module.decls.map { decl in
            switch decl {
            case .structDecl(let s):
                return .structDecl(IRStruct(name: s.name, generics: s.generics, fields: s.fields, methods: ann(s.name, s.methods), span: s.span))
            case .classDecl(let c):
                return .classDecl(IRClass(name: c.name, generics: c.generics, fields: c.fields, methods: ann(c.name, c.methods), span: c.span))
            case .enumDecl(let e):
                return .enumDecl(IREnum(name: e.name, generics: e.generics, cases: e.cases, methods: ann(e.name, e.methods), span: e.span))
            default:
                return decl
            }
        }
        return IRModule(decls: decls, interfaces: module.interfaces,
                        conformances: module.conformances, composites: module.composites,
                        opaqueUnderlyings: module.opaqueUnderlyings)
    }
}
