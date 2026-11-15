import support
import noir

// Recursive enums, boxed automatically (`design/plans/tasks/260-enum-layout.md`). The value types form
// a graph with an edge for each field or payload field held inline, through a generic's argument only where the
// generic holds that parameter inline; a reference type ends the path. A strongly connected component with a
// cycle is a recursive group, and each enum case with a payload field that reaches a member of its own group is
// boxed: its whole payload moves into a compiler-made immutable class, `Enum$case`, and the case holds one
// reference to it. A box is never null, so the enum keeps its payload-free cases in the reference's extra
// inhabitants: `enum Tree { case leaf; case node(left: Tree, right: Tree) }` is one word, null for `leaf`.
// The checker (`Typechecker.checkRecursiveValueTypes`) rejects a group whose cycles survive the boxing.
//
// It runs on NOIR before monomorphization, so a generic enum's box is a generic class over the enum's type
// parameters, specialized with it and allocated through the erased path like any generic class. Each module
// derives the same boxing from the declarations, its own and imported ones alike, so a producer and a consumer
// agree on an enum's layout. Construction becomes `Enum.case(box: Enum$case(fields…))`, and a `switch` arm on
// a boxed case binds the box and reads each payload field from it.
public func boxRecursiveCases(_ module: NOIRModule) -> NOIRModule {
    var boxer = CaseBoxer(module)
    guard !boxer.boxed.isEmpty else { return module }
    return boxer.rewrite()
}

struct CaseBoxer {
    let module: NOIRModule
    var structs: [String: NOIRStruct] = [:]
    var enums: [String: NOIREnum] = [:]
    // Boxed cases, by enum name: the case names.
    var boxed: [String: Set<String>] = [:]
    var nextBinding = 0

    init(_ module: NOIRModule) {
        self.module = module
        for d in module.decls {
            switch d {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e): enums[e.name] = e
            default: break
            }
        }
        boxed = findBoxedCases()
    }

    static func boxName(_ enumName: String, _ caseName: String) -> String { enumName + "$" + caseName }

    // MARK: Which cases

    private func fieldTypes(_ name: String) -> [(type: Type, caseName: String?)] {
        if let s = structs[name] { return s.fields.map { ($0.type, nil) } }
        if let e = enums[name] { return e.cases.flatMap { c in c.fields.map { ($0.type, c.name) } } }
        return []
    }

    private func params(_ name: String) -> [String] {
        structs[name]?.generics.map(\.name) ?? enums[name]?.generics.map(\.name) ?? []
    }

    // The value type a type names, if it is a struct or enum of this module's view.
    private func valueType(_ t: Type) -> (name: String, args: [Type])? {
        switch t {
        case .named(let n, .struct_), .named(let n, .enum_):
            return structs[n] != nil || enums[n] != nil ? (n, []) : nil
        case .generic(let base, let args):
            return structs[base] != nil || enums[base] != nil ? (base, args) : nil
        default:
            return nil
        }
    }

    private func findBoxedCases() -> [String: Set<String>] {
        let names = (Array(structs.keys) + Array(enums.keys)).sorted()
        // The parameters each generic value type holds inline, grown to a fixpoint.
        var inline: [String: Set<Int>] = [:]
        func holdsInline(_ t: Type, _ param: String) -> Bool {
            if case .typeParam(let p) = t { return p == param }
            guard let (g, args) = valueType(t) else { return false }
            return (inline[g] ?? []).contains { $0 < args.count && holdsInline(args[$0], param) }
        }
        var changed = true
        while changed {
            changed = false
            for name in names {
                for (i, p) in params(name).enumerated() where !(inline[name]?.contains(i) ?? false) {
                    if fieldTypes(name).contains(where: { holdsInline($0.type, p) }) {
                        inline[name, default: []].insert(i)
                        changed = true
                    }
                }
            }
        }
        func targets(_ t: Type, _ out: inout [String]) {
            guard let (v, args) = valueType(t) else { return }
            out.append(v)
            for i in inline[v] ?? [] where i < args.count { targets(args[i], &out) }
        }
        var edges: [String: [(to: String, caseName: String?)]] = [:]
        for name in names {
            for f in fieldTypes(name) {
                var to: [String] = []
                targets(f.type, &to)
                for t in to { edges[name, default: []].append((t, f.caseName)) }
            }
        }
        // Tarjan's strongly connected components.
        var index: [String: Int] = [:], low: [String: Int] = [:], onStack: Set<String> = []
        var stack: [String] = [], next = 0
        var out: [String: Set<String>] = [:]
        func connect(_ v: String) {
            index[v] = next; low[v] = next; next += 1
            stack.append(v); onStack.insert(v)
            for e in edges[v] ?? [] {
                if index[e.to] == nil {
                    connect(e.to); low[v] = min(low[v]!, low[e.to]!)
                } else if onStack.contains(e.to) {
                    low[v] = min(low[v]!, index[e.to]!)
                }
            }
            guard low[v] == index[v] else { return }
            var comp: Set<String> = []
            while let w = stack.popLast() { onStack.remove(w); comp.insert(w); if w == v { break } }
            for m in comp where enums[m] != nil {
                for e in edges[m] ?? [] where comp.contains(e.to) {
                    if let c = e.caseName { out[m, default: []].insert(c) }
                }
            }
        }
        for name in names where index[name] == nil { connect(name) }
        return out
    }

    // MARK: Rewriting

    // The box's type for a value of enum type `enumType`: the box class applied to the enum's arguments.
    private func boxType(_ enumType: Type, _ caseName: String) -> Type? {
        switch enumType {
        case .named(let n, .enum_):
            return .named(CaseBoxer.boxName(n, caseName), .class_)
        case .generic(let base, let args):
            return .generic(base: CaseBoxer.boxName(base, caseName), args: args)
        default:
            return nil
        }
    }

    private func enumName(_ t: Type) -> String? {
        switch t {
        case .named(let n, .enum_): return n
        case .generic(let base, _) where enums[base] != nil: return base
        default: return nil
        }
    }

    private func isBoxed(_ enumName: String?, _ caseName: String) -> Bool {
        guard let n = enumName else { return false }
        return boxed[n]?.contains(caseName) ?? false
    }

    mutating func rewrite() -> NOIRModule {
        var decls: [NOIRDecl] = []
        for d in module.decls {
            switch d {
            case .enumDecl(let e):
                var cases: [NOIREnumCase] = []
                for c in e.cases {
                    guard boxed[e.name]?.contains(c.name) ?? false else { cases.append(c); continue }
                    let name = CaseBoxer.boxName(e.name, c.name)
                    let selfType: Type = e.generics.isEmpty ? .named(e.name, .enum_)
                        : .generic(base: e.name, args: e.generics.map { .typeParam($0.name) })
                    decls.append(.classDecl(NOIRClass(name: name, generics: e.generics,
                        fields: c.fields.map { NOIRField(name: $0.name, type: $0.type, isMutable: false, span: $0.span) },
                        methods: [], span: c.span)))
                    cases.append(NOIREnumCase(name: c.name, fields: [NOIRField(name: "box", type: boxType(selfType, c.name)!,
                                                                               isMutable: false, span: c.span)], span: c.span))
                }
                decls.append(.enumDecl(NOIREnum(name: e.name, generics: e.generics, cases: cases,
                                                methods: e.methods.map { fn($0) }, span: e.span)))
            case .structDecl(let s):
                decls.append(.structDecl(NOIRStruct(name: s.name, generics: s.generics, fields: s.fields,
                                                    methods: s.methods.map { fn($0) }, span: s.span)))
            case .classDecl(let c):
                decls.append(.classDecl(NOIRClass(name: c.name, generics: c.generics, fields: c.fields,
                                                  methods: c.methods.map { fn($0) }, span: c.span)))
            case .actorDecl(let a):
                decls.append(.actorDecl(NOIRActor(name: a.name,
                    fields: a.fields.map { NOIRActorField(name: $0.name, type: $0.type, initializer: $0.initializer.map { expr($0) },
                                                          span: $0.span) },
                    handlers: a.handlers.map { NOIRHandler(name: $0.name, params: $0.params, returnType: $0.returnType,
                                                           body: block($0.body), span: $0.span) },
                    span: a.span)))
            case .funcDecl(let f):
                decls.append(.funcDecl(fn(f)))
            case .globalDecl(let g):
                decls.append(.globalDecl(NOIRGlobal(name: g.name, type: g.type, value: expr(g.value),
                                                    isConstant: g.isConstant, span: g.span)))
            }
        }
        return NOIRModule(decls: decls, interfaces: module.interfaces, conformances: module.conformances,
                          composites: module.composites, opaqueUnderlyings: module.opaqueUnderlyings,
                          externalMutatingMethods: module.externalMutatingMethods, monoTypeArgs: module.monoTypeArgs)
    }

    private mutating func fn(_ f: NOIRFunc) -> NOIRFunc {
        NOIRFunc(name: f.name, generics: f.generics, params: f.params, returnType: f.returnType, body: block(f.body),
                 isMutating: f.isMutating, visibility: f.visibility, span: f.span)
    }

    private mutating func block(_ stmts: [NOIRStmt]) -> [NOIRStmt] { stmts.map { stmt($0) } }

    private mutating func stmt(_ s: NOIRStmt) -> NOIRStmt {
        let k: StmtKind
        switch s.kind {
        case .letBinding(let name, let isMutable, let value):
            k = .letBinding(name: name, isMutable: isMutable, value: expr(value))
        case .fiberStart(let call):
            k = .fiberStart(call: expr(call))
        case .assign(let target, let value):
            k = .assign(target: expr(target), value: expr(value))
        case .compoundAssign(let target, let value):
            k = .compoundAssign(target: expr(target), value: expr(value))
        case .ret(let v):
            k = .ret(v.map { expr($0) })
        case .ifStmt(let cond, let then, let els):
            k = .ifStmt(cond: expr(cond), then: block(then), else: els.map { block($0) })
        case .whileStmt(let cond, let body):
            k = .whileStmt(cond: expr(cond), body: block(body))
        case .breakStmt, .continueStmt:
            k = s.kind
        case .switchStmt(let sw):
            k = .switchStmt(switchStmt(sw))
        case .exprStmt(let e):
            k = .exprStmt(expr(e))
        }
        return NOIRStmt(kind: k, span: s.span)
    }

    // An arm on a boxed case binds the box, then each payload field from it, in the bindings' order.
    private mutating func switchStmt(_ sw: NOIRSwitch) -> NOIRSwitch {
        let subject = expr(sw.subject)
        let en = enumName(sw.subject.type)
        var arms: [NOIRCaseArm] = []
        for arm in sw.arms {
            var body = block(arm.body)
            var bindings = arm.bindings
            if isBoxed(en, arm.caseName), let bt = boxType(sw.subject.type, arm.caseName),
               let fields = enums[en!]?.cases.first(where: { $0.name == arm.caseName })?.fields {
                let boxVar = "box$\(nextBinding)"
                nextBinding += 1
                let boxRef = NOIRExpr(type: bt, span: arm.span, kind: .varRef(boxVar))
                var reads: [NOIRStmt] = []
                for (i, b) in arm.bindings.enumerated() where i < fields.count && b.name != "_" {
                    let read = NOIRExpr(type: b.type, span: arm.span, kind: .fieldAccess(base: boxRef, field: fields[i].name))
                    reads.append(NOIRStmt(kind: .letBinding(name: b.name, isMutable: false, value: read), span: arm.span))
                }
                body = reads + body
                bindings = arm.bindings.isEmpty ? [] : [NOIRBinding(name: boxVar, type: bt)]
            }
            arms.append(NOIRCaseArm(caseName: arm.caseName, bindings: bindings, body: body, span: arm.span))
        }
        return NOIRSwitch(subject: subject, arms: arms)
    }

    private mutating func args(_ a: [NOIRArg]) -> [NOIRArg] { a.map { NOIRArg(label: $0.label, value: expr($0.value)) } }

    private mutating func expr(_ e: NOIRExpr) -> NOIRExpr {
        let k: ExprKind
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef, .globalRef, .funcRef:
            return e
        case .fieldAccess(let base, let field):
            k = .fieldAccess(base: expr(base), field: field)
        case .construct(let typeName, let a):
            k = .construct(typeName: typeName, args: args(a))
        case .enumInit(let typeName, let caseName, let a):
            let fields = args(a)
            if isBoxed(enumName(e.type), caseName), let bt = boxType(e.type, caseName) {
                let boxTypeName: String
                switch bt {
                case .named(let n, _): boxTypeName = n
                case .generic(let base, _): boxTypeName = base
                default: boxTypeName = ""
                }
                let box = NOIRExpr(type: bt, span: e.span, kind: .construct(typeName: boxTypeName, args: fields))
                k = .enumInit(typeName: typeName, caseName: caseName, args: [NOIRArg(label: "box", value: box)])
            } else {
                k = .enumInit(typeName: typeName, caseName: caseName, args: fields)
            }
        case .methodCall(let receiver, let method, let a):
            k = .methodCall(receiver: expr(receiver), method: method, args: a.map { expr($0) })
        case .call(let callee, let a, let typeArgs):
            k = .call(callee: expr(callee), args: args(a), typeArgs: typeArgs)
        case .staticCall(let onType, let method, let a):
            k = .staticCall(onType: onType, method: method, args: a.map { expr($0) })
        case .binary(let op, let l, let r):
            k = .binary(op, expr(l), expr(r))
        case .closure(let params, let body):
            k = .closure(params: params, body: block(body))
        case .box(let value, let interfaces):
            k = .box(value: expr(value), interfaces: interfaces)
        case .arrayLit(let elements):
            k = .arrayLit(elements: elements.map { expr($0) })
        case .index(let base, let idx):
            k = .index(base: expr(base), idx: expr(idx))
        case .taskStart(let binder, let make, let call, let fulfill):
            k = .taskStart(binder: binder, make: expr(make), call: expr(call), fulfill: expr(fulfill))
        }
        return NOIRExpr(type: e.type, span: e.span, kind: k)
    }
}
