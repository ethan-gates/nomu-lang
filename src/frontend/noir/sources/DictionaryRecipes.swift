import ast
import support

// What a compiled-once body needs for each instantiation, which only a caller with concrete types can provide.
//
// A generic emitted once cannot name `Node<T>`'s descriptor: one exists per `T`, and the producer has not heard of
// the caller's types. So the producer records, per generic, a recipe of what its dictionary must hold, with the types
// written in its own type parameters, and the `.nmi` carries it. A caller substitutes its type arguments and emits
// the dictionary as a constant, without seeing a body. Layouts travel with the recipes, since a recipe may name a
// private type the `.nmi` does not otherwise describe. Design: `design/plans/tasks/251-erased-generic-objects.md`.

public enum DictionaryNeed: Codable, Equatable {
    case object(Type)                                 // allocates this generic class: its descriptor
    case arrayBuffer(element: Type)                   // grows an array of this: its buffer's descriptor
    case box(Type)                                    // boxes this as `any I`: its payload's descriptor
    case callee(symbol: String, typeArgs: [Type])     // calls this generic: its dictionary
}

// `symbol` is the generic's call symbol: its name, or `m:Type:method` for a method of a generic type.
public struct DictionaryRecipe: Codable, Equatable {
    public let symbol: String
    public let generics: [String]
    public let bounds: [[String]]                     // per type parameter, name-sorted
    public let needs: [DictionaryNeed]
    public init(symbol: String, generics: [String], bounds: [[String]], needs: [DictionaryNeed]) {
        self.symbol = symbol; self.generics = generics; self.bounds = bounds; self.needs = needs
    }
}

// A type a recipe names: enough to lay it out for any arguments. `fields` holds one list for a struct or class, and
// one per case for an enum.
public struct DictionaryLayout: Codable, Equatable {
    public let name: String
    public let generics: [String]
    public let kind: NamedKind
    public let fields: [[Type]]
    public let fieldNames: [[String]]                 // parallel to `fields`
    public let caseNames: [String]                    // an enum's
    // A struct's or class's fields that came from a type parameter (`NOIRField.fromTypeParameter`), parallel
    // to `fields`; nil when none did. The value layout reads it, so a specialized type imported by name is
    // laid out as its producer laid it out.
    public let fromTypeParameter: [[Bool]]?
    public init(name: String, generics: [String], kind: NamedKind, fields: [[Type]], fieldNames: [[String]],
                caseNames: [String] = [], fromTypeParameter: [[Bool]]? = nil) {
        self.name = name; self.generics = generics; self.kind = kind; self.fields = fields
        self.fieldNames = fieldNames; self.caseNames = caseNames; self.fromTypeParameter = fromTypeParameter
    }
}

public struct DictionaryRecipes: Codable, Equatable {
    public let recipes: [DictionaryRecipe]
    public let layouts: [DictionaryLayout]
    public init(recipes: [DictionaryRecipe], layouts: [DictionaryLayout]) {
        self.recipes = recipes; self.layouts = layouts
    }

    // These recipes as a consumer of the module `origin` names things: its own decls qualified, as imports are.
    public func qualified(origin: String) -> DictionaryRecipes {
        var own = Set(layouts.map(\.name)).filter { !ExternalName.isEncoded($0) }
        for r in recipes where !r.symbol.hasPrefix("m:") && !ExternalName.isEncoded(r.symbol) { own.insert(r.symbol) }
        func name(_ n: String) -> String { own.contains(n) ? ExternalName.encode(origin: origin, name: n) : n }
        func type(_ t: Type) -> Type {
            switch t {
            case .named(let n, let k): return .named(name(n), k)
            case .generic(let base, let args): return .generic(base: name(base), args: args.map(type))
            case .array(let e): return .array(type(e))
            case .ptr(let e): return .ptr(type(e))
            case .function(let ps, let r): return .function(params: ps.map(type), ret: type(r))
            default: return t
            }
        }
        func symbol(_ s: String) -> String {
            guard s.hasPrefix("m:") else { return name(s) }
            let rest = s.dropFirst(2)
            let base = String(rest.prefix { $0 != ":" })
            return "m:\(name(base))\(rest.dropFirst(base.count))"
        }
        func need(_ n: DictionaryNeed) -> DictionaryNeed {
            switch n {
            case .object(let t): return .object(type(t))
            case .arrayBuffer(let e): return .arrayBuffer(element: type(e))
            case .box(let t): return .box(type(t))
            case .callee(let s, let args): return .callee(symbol: symbol(s), typeArgs: args.map(type))
            }
        }
        return DictionaryRecipes(
            recipes: recipes.map { DictionaryRecipe(symbol: symbol($0.symbol), generics: $0.generics, bounds: $0.bounds,
                                                    needs: $0.needs.map(need)) },
            layouts: layouts.map { DictionaryLayout(name: name($0.name), generics: $0.generics, kind: $0.kind,
                                                    fields: $0.fields.map { $0.map(type) }, fieldNames: $0.fieldNames,
                                                    caseNames: $0.caseNames, fromTypeParameter: $0.fromTypeParameter) })
    }
}

// One recipe filled in with concrete types, which a caller emits as a constant. Needs are in the recipe's order.
public struct DictionaryInstance: Codable, Equatable {
    public enum Need: Codable, Equatable {
        case dictionary(key: String)
        case object(Type)
        case arrayBuffer(element: Type)
        case box(Type)
    }
    public let typeArgs: [Type]
    public let bounds: [[String]]
    public let needs: [Need]
    public init(typeArgs: [Type], bounds: [[String]], needs: [Need]) {
        self.typeArgs = typeArgs; self.bounds = bounds; self.needs = needs
    }
}

// The name an instantiation's dictionary goes by.
public func dictionaryKey(_ symbol: String, _ typeArgs: [Type]) -> String {
    symbol + "|" + typeArgs.map(\.description).joined(separator: ",")
}

private func mentions(_ t: Type, _ params: Set<String>) -> Bool {
    switch t {
    case .typeParam(let n): return params.contains(n)
    case .generic(_, let args): return args.contains { mentions($0, params) }
    case .array(let e), .ptr(let e): return mentions(e, params)
    case .function(let ps, let r): return ps.contains { mentions($0, params) } || mentions(r, params)
    default: return false
    }
}

// Every expression in `stmts`, outermost first.
private func forEachExpr(_ stmts: [NOIRStmt], _ visit: (NOIRExpr) -> Void) {
    func expr(_ e: NOIRExpr) {
        visit(e)
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef, .globalRef, .funcRef:
            break
        case .fieldAccess(let base, _):
            expr(base)
        case .construct(_, let args), .enumInit(_, _, let args):
            args.forEach { expr($0.value) }
        case .methodCall(let receiver, _, let args):
            expr(receiver); args.forEach(expr)
        case .call(let callee, let args, _):
            expr(callee); args.forEach { expr($0.value) }
        case .staticCall(_, _, let args):
            args.forEach(expr)
        case .binary(_, let l, let r):
            expr(l); expr(r)
        case .closure(_, let body):
            body.forEach(stmt)
        case .box(let value, _):
            expr(value)
        case .arrayLit(let elements):
            elements.forEach(expr)
        case .index(let base, let idx):
            expr(base); expr(idx)
        case .taskStart(_, let make, let call, let fulfill):
            expr(make); expr(call); expr(fulfill)
        }
    }
    func stmt(_ s: NOIRStmt) {
        switch s.kind {
        case .letBinding(_, _, let value):
            expr(value)
        case .fiberStart(let call):
            expr(call)
        case .assign(let t, let v), .compoundAssign(let t, let v):
            expr(t); expr(v)
        case .ret(let e):
            if let e { expr(e) }
        case .ifStmt(let cond, let then, let els):
            expr(cond); then.forEach(stmt); els?.forEach(stmt)
        case .whileStmt(let cond, let body):
            expr(cond); body.forEach(stmt)
        case .breakStmt, .continueStmt:
            break
        case .switchStmt(let sw):
            expr(sw.subject)
            sw.arms.forEach { $0.body.forEach(stmt) }
        case .exprStmt(let e):
            expr(e)
        }
    }
    stmts.forEach(stmt)
}

// The needs of a body with type parameters `params`, each once, in order of first use. `classes` names the generic
// classes: a generic struct or enum needs nothing, since witnesses lay it out.
private func needs(of body: [NOIRStmt], params: Set<String>, classes: Set<String>,
                   generics: Set<String>) -> [DictionaryNeed] {
    var out: [DictionaryNeed] = []
    func add(_ n: DictionaryNeed) { if !out.contains(n) { out.append(n) } }
    forEachExpr(body) { e in
        switch e.kind {
        case .construct:
            if case .generic(let base, _) = e.type, classes.contains(base) { add(.object(e.type)) }
        case .arrayLit:
            if case .array(let element) = e.type, mentions(element, params) { add(.arrayBuffer(element: element)) }
        case .box(let value, _):
            if mentions(value.type, params) { add(.box(value.type)) }
        case .call(let callee, _, let typeArgs):
            if case .varRef(let name) = callee.kind, !typeArgs.isEmpty, generics.contains(name) {
                add(.callee(symbol: name, typeArgs: typeArgs))
            }
            // A `ManagedBuffer` whose element mentions `T` (a channel's): the body allocates it with the descriptor
            // of the caller's instantiation, as it does a generic class.
            if case .varRef("__managedBufferCreate") = callee.kind, mentions(e.type, params) { add(.object(e.type)) }
        case .methodCall(let receiver, let method, _):
            if case .array(let element) = receiver.type, method == "append", mentions(element, params) {
                add(.arrayBuffer(element: element))
            } else if case .generic(let base, let args) = receiver.type, mentions(receiver.type, params) {
                add(.callee(symbol: "m:\(base):\(method)", typeArgs: args))
            }
        default:
            break
        }
    }
    return out
}

// The recipes of the generics in `decls`, a monomorphized module's: what remains generic there is what is emitted
// compiled-once. The recipes of `imported` generics these reach are copied in, so each `.nmi` is complete: a caller
// never needs a module beyond the one it imports.
public func dictionaryRecipes(_ decls: [NOIRDecl], imported: DictionaryRecipes? = nil) -> DictionaryRecipes? {
    var classes = Set<String>()
    var known: [String: DictionaryLayout] = [:]
    func marks(_ fields: [NOIRField]) -> [[Bool]]? {
        fields.contains { $0.fromTypeParameter } ? [fields.map(\.fromTypeParameter)] : nil
    }
    for l in imported?.layouts ?? [] { known[l.name] = l }
    for decl in decls {
        switch decl {
        case .structDecl(let s):
            known[s.name] = DictionaryLayout(name: s.name, generics: s.generics.map(\.name), kind: .struct_,
                                             fields: [s.fields.map(\.type)], fieldNames: [s.fields.map(\.name)],
                                             fromTypeParameter: marks(s.fields))
        case .classDecl(let c):
            known[c.name] = DictionaryLayout(name: c.name, generics: c.generics.map(\.name), kind: .class_,
                                             fields: [c.fields.map(\.type)], fieldNames: [c.fields.map(\.name)],
                                             fromTypeParameter: marks(c.fields))
            if !c.generics.isEmpty { classes.insert(c.name) }
        case .enumDecl(let e):
            known[e.name] = DictionaryLayout(name: e.name, generics: e.generics.map(\.name), kind: .enum_,
                                             fields: e.cases.map { $0.fields.map(\.type) },
                                             fieldNames: e.cases.map { $0.fields.map(\.name) },
                                             caseNames: e.cases.map(\.name))
        default:
            break
        }
    }
    for l in known.values where l.kind == .class_ && !l.generics.isEmpty { classes.insert(l.name) }

    var generics = Set(imported?.recipes.map(\.symbol) ?? [])
    for case .funcDecl(let f) in decls where !f.generics.isEmpty { generics.insert(f.name) }

    var recipes: [DictionaryRecipe] = []
    func record(_ symbol: String, _ params: [NOIRGenericParam], _ body: [NOIRStmt]) {
        let names = params.map(\.name)
        recipes.append(DictionaryRecipe(symbol: symbol, generics: names, bounds: params.map { $0.bounds.sorted() },
                                        needs: needs(of: body, params: Set(names), classes: classes, generics: generics)))
    }
    for decl in decls {
        switch decl {
        case .funcDecl(let f) where !f.generics.isEmpty:
            record(f.name, f.generics, f.body)
        case .structDecl(let s) where !s.generics.isEmpty:
            for m in s.methods { record("m:\(s.name):\(m.name)", s.generics + m.generics, m.body) }
        case .enumDecl(let e) where !e.generics.isEmpty:
            for m in e.methods { record("m:\(e.name):\(m.name)", e.generics + m.generics, m.body) }
        case .classDecl(let c) where !c.generics.isEmpty:
            for m in c.methods { record("m:\(c.name):\(m.name)", c.generics + m.generics, m.body) }
        default:
            break
        }
    }

    // The imported recipes these reach.
    let foreign = Dictionary((imported?.recipes ?? []).map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
    var present = Set(recipes.map(\.symbol))
    var i = 0
    while i < recipes.count {
        for case .callee(let symbol, _) in recipes[i].needs {
            if let r = foreign[symbol], present.insert(symbol).inserted { recipes.append(r) }
        }
        i += 1
    }
    if recipes.isEmpty { return nil }

    // The layouts the recipes reach, through field types.
    var reached: [String: DictionaryLayout] = [:]
    func reach(_ t: Type) {
        switch t {
        case .named(let name, _):
            visit(name)
        case .generic(let base, let args):
            visit(base); args.forEach(reach)
        case .array(let e), .ptr(let e):
            reach(e)
        default:
            break
        }
    }
    func visit(_ name: String) {
        guard reached[name] == nil, let layout = known[name] else { return }
        reached[name] = layout
        layout.fields.forEach { $0.forEach(reach) }
    }
    for r in recipes {
        for n in r.needs {
            switch n {
            case .object(let t), .box(let t), .arrayBuffer(let t): reach(t)
            case .callee(_, let args): args.forEach(reach)
            }
        }
    }
    for r in recipes where r.symbol.hasPrefix("m:") {   // a method's own type, whose methods a caller may reach
        visit(String(r.symbol.dropFirst(2).prefix { $0 != ":" }))
    }
    return DictionaryRecipes(recipes: recipes.sorted { $0.symbol < $1.symbol },
                             layouts: reached.values.sorted { $0.name < $1.name })
}
