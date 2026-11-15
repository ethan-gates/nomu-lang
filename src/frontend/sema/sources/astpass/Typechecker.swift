import ast
import support
public struct Typechecker {
    private let program: Program
    // Errors are collected, not fatal (the no-crash contract — frontend/README.md P0).
    private let diags: DiagnosticSink
    private var typeKinds: [String: DeclKind] = [
        "Int": .builtin,
        "UInt8": .builtin,
        "UInt64": .builtin,
        "Bool": .builtin,
        "String": .builtin,
    ]

    private enum DeclKind {
        case struct_, enum_, class_, actor_, interface_, builtin
    }

    // The imported struct and enum declarations, named by their per-origin identity (`origin@name`), and the
    // resolver from a type reference in a source file to the imported type it names (nil when it names none).
    private let externalDecls: [TopDecl]
    private let resolveImportedType: (TypeRef) -> String?

    public init(_ program: Program, diagnostics: DiagnosticSink = DiagnosticSink(),
                externalDecls: [TopDecl] = [], resolveImportedType: @escaping (TypeRef) -> String? = { _ in nil }) {
        self.program = program
        self.diags = diagnostics
        self.externalDecls = externalDecls
        self.resolveImportedType = resolveImportedType
    }

    @discardableResult
    public mutating func check() -> DiagnosticSink {
        collectTypeKinds()
        // A recursive value type would send every later walk over field types around its cycle forever.
        guard checkRecursiveValueTypes() else { return diags }
        checkLetVar()
        return diags
    }

    // MARK: - Phase 1: collect declared type names

    private mutating func collectTypeKinds() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): typeKinds[s.name] = .struct_
            case .enumDecl(let e):   typeKinds[e.name] = .enum_
            case .classDecl(let c):  typeKinds[c.name] = .class_
            case .actorDecl(let a):  typeKinds[a.name] = .actor_
            case .interfaceDecl(let i): typeKinds[i.name] = .interface_
            case .funcDecl, .globalDecl: break
            case .extensionDecl:     break   // merged into its target before this pass (M4.12)
            }
        }
    }

    // MARK: - Phase 1b: recursive value types

    // A struct or enum that holds itself inline, directly or through other value types, has no finite size,
    // unless an enum case on the way is boxed. The value types form a graph with an edge for each field or
    // payload field held inline; a reference type
    // (class, actor, array, closure, existential) ends the path. An imported value type cannot name a local
    // one back (imports are acyclic), but an imported generic can hold a local type argument inline, so the
    // imported structs and enums join the graph for their inline parameters. A generic's type argument is
    // held inline only at the parameters the generic itself holds inline (`inlineParams`), so `Array<Node>`
    // adds no edge and `Pair<Node>` or `Option<Node>` does. A strongly connected component with a cycle is a
    // recursive group, and each enum case holding a member of its own group is boxed (`BoxRecursiveCases`),
    // which removes its edges. A cycle left without them runs through struct fields only, or
    // through a generic's type parameter (`struct Node { let next: Option<Node> }`, where boxing `Option`'s
    // case for one instance would change `Option`'s layout), and is reported once, at its first declaration,
    // with one path around it. Returns false when any is reported.
    private func checkRecursiveValueTypes() -> Bool {
        var order: [String] = []                       // this module's value types in declaration order
        var fieldsOf: [String: [(label: String, type: TypeRef, isCase: Bool)]] = [:]
        var genericsOf: [String: [String]] = [:]
        var spanOf: [String: Span] = [:]
        func add(_ decl: TopDecl, local: Bool) {
            switch decl {
            case .structDecl(let d):
                if local { order.append(d.name); spanOf[d.name] = d.span }
                genericsOf[d.name] = d.generics.map(\.name)
                fieldsOf[d.name] = d.fields.map { (label: $0.name, type: $0.type, isCase: false) }
            case .enumDecl(let d):
                if local { order.append(d.name); spanOf[d.name] = d.span }
                genericsOf[d.name] = d.generics.map(\.name)
                fieldsOf[d.name] = d.cases.flatMap { c in c.fields.map { (label: "\(c.name).\($0.name)", type: $0.type, isCase: true) } }
            default:
                break
            }
        }
        for decl in externalDecls { add(decl, local: false) }
        for decl in program.decls { add(decl, local: true) }
        // The value type a reference names: a local one or an imported one already named by its identity,
        // else the imported type the reference resolves to in its file.
        func valueType(_ t: TypeRef) -> String? {
            guard t.fn == nil else { return nil }
            if t.qualifier == nil, fieldsOf[t.name] != nil { return t.name }
            guard let k = resolveImportedType(t), fieldsOf[k] != nil else { return nil }
            return k
        }
        // Whether a field of type `t` holds the type parameter `param` inline.
        func holdsInline(_ t: TypeRef, _ param: String, _ inlineParams: [String: Set<Int>]) -> Bool {
            if t.qualifier == nil, t.fn == nil, t.genericArgs == nil, t.name == param { return true }
            guard let args = t.genericArgs, let g = valueType(t) else { return false }
            for i in inlineParams[g] ?? [] where i < args.count {
                if holdsInline(args[i], param, inlineParams) { return true }
            }
            return false
        }
        // The parameters each generic value type holds inline: a field of the parameter's own type, or of a
        // value-type generic holding that argument position inline. Grown to a fixpoint.
        var inlineParams: [String: Set<Int>] = [:]
        var changed = true
        while changed {
            changed = false
            for name in fieldsOf.keys.sorted() {
                let params = genericsOf[name] ?? []
                if params.isEmpty { continue }
                for f in fieldsOf[name] ?? [] {
                    for (i, p) in params.enumerated() where !(inlineParams[name]?.contains(i) ?? false) {
                        if holdsInline(f.type, p, inlineParams) {
                            inlineParams[name, default: []].insert(i)
                            changed = true
                        }
                    }
                }
            }
        }
        // Edges: the value types a field's type holds inline, each with the field that leads there.
        func targets(_ t: TypeRef, _ out: inout [String]) {
            guard let v = valueType(t) else { return }
            out.append(v)
            if let args = t.genericArgs {
                for i in inlineParams[v] ?? [] where i < args.count { targets(args[i], &out) }
            }
        }
        typealias Edge = (to: String, label: String, isCase: Bool)
        var edges: [String: [Edge]] = [:]
        for name in order {
            for f in fieldsOf[name] ?? [] {
                var to: [String] = []
                targets(f.type, &to)
                for t in to { edges[name, default: []].append((to: t, label: "\(name).\(f.label)", isCase: f.isCase)) }
            }
        }
        // Tarjan's strongly connected components of `nodes` over `edgesOf`, each with a cycle.
        func cycles(_ nodes: [String], _ edgesOf: (String) -> [Edge]) -> [[String]] {
            var index: [String: Int] = [:], low: [String: Int] = [:], onStack: Set<String> = []
            var stack: [String] = [], next = 0
            var components: [[String]] = []
            func connect(_ v: String) {
                index[v] = next; low[v] = next; next += 1
                stack.append(v); onStack.insert(v)
                for e in edgesOf(v) {
                    if index[e.to] == nil {
                        connect(e.to); low[v] = min(low[v]!, low[e.to]!)
                    } else if onStack.contains(e.to) {
                        low[v] = min(low[v]!, index[e.to]!)
                    }
                }
                if low[v] == index[v] {
                    var comp: [String] = []
                    while let w = stack.popLast() { onStack.remove(w); comp.append(w); if w == v { break } }
                    if comp.count > 1 || edgesOf(comp[0]).contains(where: { $0.to == comp[0] }) { components.append(comp) }
                }
            }
            for name in nodes where index[name] == nil { connect(name) }
            return components
        }
        var ok = true
        for group in cycles(order, { edges[$0] ?? [] }) {
            // Boxing each enum case that holds a member of the group removes its edges within the group.
            let members = Set(group)
            let unboxed = { (v: String) -> [Edge] in (edges[v] ?? []).filter { members.contains($0.to) && !$0.isCase } }
            for comp in cycles(order.filter { members.contains($0) }, unboxed) {
                let inComp = Set(comp)
                let first = order.first { inComp.contains($0) }!
                // One path around the cycle from `first`, staying inside the component.
                var path: [String] = []
                var seen: Set<String> = []
                func walk(_ v: String) -> Bool {
                    for e in unboxed(v) where inComp.contains(e.to) {
                        if e.to == first { path.append(e.label); return true }
                        if seen.insert(e.to).inserted {
                            path.append(e.label)
                            if walk(e.to) { return true }
                            path.removeLast()
                        }
                    }
                    return false
                }
                _ = walk(first)
                let route = path.joined(separator: " → ") + " → " + first
                fail("value type '\(first)' contains itself: \(route); a value type cannot hold itself except through an enum case; hold the value through a class",
                     span: spanOf[first]!)
                ok = false
            }
        }
        return ok
    }

    // MARK: - Phase 3: let/var enforcement

    private func checkLetVar() {
        for decl in program.decls {
            switch decl {
            case .funcDecl(let f):
                checkBlock(f.body, lets: [])
            case .actorDecl(let a):
                for h in a.handlers { checkBlock(h.body, lets: []) }
            case .structDecl(let s):
                checkMethods(s.methods)
                checkProperties(s.properties)
            case .classDecl(let c):
                checkMethods(c.methods)
                checkProperties(c.properties)
            case .enumDecl(let e):
                checkMethods(e.methods)
                checkProperties(e.properties)
            case .interfaceDecl(let i):
                for m in i.methods { if let body = m.defaultBody { checkBlock(body, lets: []) } }
            case .extensionDecl:
                break   // merged into its target before this pass (M4.12)
            case .globalDecl:
                break   // a global is a `let`; sema reports a top-level `var` and any assignment to a global
            }
        }
    }

    // Method bodies get the ordinary local let/var check. Field-write validity
    // (`let` fields, reassigning `self`) is enforced in Sema (M4.11), which has the
    // resolved receiver types the AST pass lacks; mutating-ness is inferred there.
    private func checkMethods(_ methods: [FuncDecl]) {
        for m in methods { checkBlock(m.body, lets: []) }
    }

    // Accessor bodies get the same local let/var check as method bodies.
    private func checkProperties(_ properties: [ComputedProperty]) {
        for p in properties {
            checkBlock(p.getter, lets: [])
            if let setter = p.setter { checkBlock(setter.body, lets: []) }
        }
    }

    private func checkBlock(_ block: Block, lets: Set<String>) {
        var lets = lets
        for stmt in block { checkStmt(stmt, lets: &lets) }
    }

    private func checkStmt(_ stmt: Stmt, lets: inout Set<String>) {
        switch stmt {
        case .binding(let b):
            if !b.isMutable { lets.insert(b.name) }
        case .fiberStart:
            break
        case .assign(let lhs, _, let span):
            rejectLetTarget(lhs, lets: lets, span: span)
        case .compoundAssign(let lhs, _, let span):
            rejectLetTarget(lhs, lets: lets, span: span)
        case .ifStmt(let s):
            checkBlock(s.thenBody, lets: lets)
            if let elseBody = s.elseBody { checkBlock(elseBody, lets: lets) }
        case .whileStmt(let s):
            checkBlock(s.body, lets: lets)
        case .switchStmt(let sw):
            for arm in sw.cases {
                var innerLets = lets
                if case .enumCase(_, let bindings, _) = arm.pattern {
                    innerLets.formUnion(bindings)  // pattern bindings are always immutable
                }
                checkBlock(arm.body, lets: innerLets)
            }
        case .selectStmt(let sel):
            for arm in sel.arms {
                var innerLets = lets
                if let b = arm.binding { innerLets.insert(b) }   // a case's value binding is immutable
                checkBlock(arm.body, lets: innerLets)
            }
            if let d = sel.defaultBody { checkBlock(d, lets: lets) }
        case .ret, .expr, .breakStmt, .continueStmt:
            break
        }
    }

    private func rejectLetTarget(_ lhs: Expr, lets: Set<String>, span: Span) {
        if case .ident(let name, _) = lhs, lets.contains(name) {
            fail("cannot assign to '\(name)' ('let' constant)", span: span)
        }
    }

    // MARK: - Lookup helpers

    // MARK: - Error reporting

    private func fail(_ msg: String, span: Span) {
        diags.error(msg, at: span)
    }
}
