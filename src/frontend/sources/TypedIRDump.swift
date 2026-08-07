// A human-readable dump of the typed IR — the `--dump-typed-ast` output and the
// minimum debug visibility into the typecheck phase (design: compiler.md §1).
//
// Indented tree, printed like a pretty-printer: a subtree collapses onto ONE
// line when its full flat rendering fits within `dumpWidth`; otherwise it breaks
// onto indented lines and each child re-tries the same test. So the break
// decision is about text width, not tree depth — a short deep subtree stays
// inline, a long shallow one breaks.
//
// Grammar (each token has exactly one job, so it stays unambiguous even inline):
//   • `:`      — "has type", always spaced: `c : Counter`, `x : Int`.
//   • `[slot]` — a named child position: `[callee]`, `[arg]`, `[lhs]`, `[then]`.
//   • `{ … }`  — groups an inline child, giving siblings a clear delimiter (`} [`)
//                and making nested inline children unambiguous.
//   • `( … )`  — appears only inside a function type.
//   • indentation — structure, when not inline.
// The kind word is dropped where the form implies it (bare name = var ref,
// `.x` = field, `+` = binary op).

private let dumpWidth = 80

public func dumpTypedIR(_ module: IRModule) -> String {
    var lines: [String] = ["Module"]
    for decl in module.decls { appendDecl(decl, ind: "  ", into: &lines) }
    return lines.joined(separator: "\n")
}

private func slot(_ name: String) -> String { name.isEmpty ? "" : "[\(name)] " }

// MARK: - Declarations

private func appendDecl(_ decl: IRDecl, ind: String, into lines: inout [String]) {
    switch decl {
    case .structDecl(let s):
        lines.append("\(ind)struct \(s.name)")
        for f in s.fields { lines.append("\(ind)  \(f.isMutable ? "var" : "let") \(f.name) : \(f.type)") }
        for m in s.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .enumDecl(let e):
        lines.append("\(ind)enum \(e.name)")
        for c in e.cases {
            let fs = c.fields.map { "\($0.name) : \($0.type)" }.joined(separator: ", ")
            lines.append("\(ind)  case \(c.name)(\(fs))")
        }
        for m in e.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .classDecl(let c):
        lines.append("\(ind)class \(c.name)")
        for f in c.fields { lines.append("\(ind)  \(f.isMutable ? "var" : "let") \(f.name) : \(f.type)") }
        for m in c.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .actorDecl(let a):
        lines.append("\(ind)actor \(a.name)")
        for f in a.fields {
            lines.append("\(ind)  \(f.name) : \(f.type)")
            if let initv = f.initializer { appendExpr(initv, slot: "init", ind: ind + "    ", into: &lines) }
        }
        for h in a.handlers {
            lines.append("\(ind)  on \(h.name)\(signature(h.params, h.returnType))")
            for s in h.body { appendStmt(s, ind: ind + "    ", into: &lines) }
        }
    case .funcDecl(let f):
        lines.append("\(ind)fun \(f.name)\(signature(f.params, f.returnType))")
        for s in f.body { appendStmt(s, ind: ind + "  ", into: &lines) }
    }
}

// An instance method — a `fun` member with an implicit `self` receiver (T3).
private func appendMethod(_ m: IRFunc, ind: String, into lines: inout [String]) {
    lines.append("\(ind)\(m.isMutating ? "mutating " : "")fun \(m.name)\(signature(m.params, m.returnType))")
    for s in m.body { appendStmt(s, ind: ind + "  ", into: &lines) }
}

private func signature(_ params: [IRParam], _ ret: Type) -> String {
    let ps = params.map { "\($0.name) : \($0.type)" }.joined(separator: ", ")
    return "(\(ps)) -> \(ret)"
}

// MARK: - Statements

private func appendStmt(_ stmt: IRStmt, ind: String, into lines: inout [String]) {
    let c = ind + "  "
    switch stmt.kind {
    case .letBinding(let name, let mut, let value):
        appendValued("\(mut ? "var" : "let") \(name) =", value, ind: ind, into: &lines)
    case .spawnLet(let name, let value, _):
        appendValued("spawn let \(name) =", value, ind: ind, into: &lines)
    case .ret(let e):
        if let e { appendValued("return", e, ind: ind, into: &lines) }
        else { lines.append("\(ind)return") }
    case .assign(let target, let value):
        lines.append("\(ind)assign")
        appendExpr(target, slot: "target", ind: c, into: &lines)
        appendExpr(value, slot: "value", ind: c, into: &lines)
    case .compoundAssign(let target, let value):
        lines.append("\(ind)assign +=")
        appendExpr(target, slot: "target", ind: c, into: &lines)
        appendExpr(value, slot: "value", ind: c, into: &lines)
    case .ifStmt(let cond, let then, let els):
        lines.append("\(ind)if")
        appendExpr(cond, slot: "cond", ind: c, into: &lines)
        lines.append("\(c)[then]")
        for s in then { appendStmt(s, ind: c + "  ", into: &lines) }
        if let els {
            lines.append("\(c)[else]")
            for s in els { appendStmt(s, ind: c + "  ", into: &lines) }
        }
    case .whileStmt(let cond, let body):
        lines.append("\(ind)while")
        appendExpr(cond, slot: "cond", ind: c, into: &lines)
        lines.append("\(c)[body]")
        for s in body { appendStmt(s, ind: c + "  ", into: &lines) }
    case .breakStmt:
        lines.append("\(ind)break")
    case .continueStmt:
        lines.append("\(ind)continue")
    case .switchStmt(let sw):
        lines.append("\(ind)switch")
        appendExpr(sw.subject, slot: "subject", ind: c, into: &lines)
        for arm in sw.arms {
            let binds = arm.bindings.map { "\($0.name) : \($0.type)" }.joined(separator: ", ")
            lines.append("\(c)case \(arm.caseName)(\(binds))")
            for s in arm.body { appendStmt(s, ind: c + "  ", into: &lines) }
        }
    case .exprStmt(let e):
        appendExpr(e, slot: "", ind: ind, into: &lines)
    }
}

// `<keyword> <value>` on one line if the value's flat form fits, else break it out.
private func appendValued(_ keyword: String, _ value: IRExpr, ind: String, into lines: inout [String]) {
    if let f = flat(value), ind.count + keyword.count + 1 + f.count <= dumpWidth {
        lines.append("\(ind)\(keyword) \(f)")
    } else {
        lines.append("\(ind)\(keyword)")
        appendExpr(value, slot: "", ind: ind + "  ", into: &lines)
    }
}

// MARK: - Expressions

private func appendExpr(_ e: IRExpr, slot slotName: String, ind: String, into lines: inout [String]) {
    let prefix = slot(slotName)
    if let f = flat(e), ind.count + prefix.count + f.count <= dumpWidth {
        lines.append("\(ind)\(prefix)\(f)")
        return
    }
    // Closures always break — they carry a statement body.
    if case .closure(let params, let body) = e.kind {
        lines.append("\(ind)\(prefix)closure : \(e.type)")
        for p in params { lines.append("\(ind)  param \(p.name) : \(p.type)") }
        lines.append("\(ind)  [body]")
        for s in body { appendStmt(s, ind: ind + "    ", into: &lines) }
        return
    }
    lines.append("\(ind)\(prefix)\(head(e)) : \(e.type)")
    for k in children(e) { appendExpr(k.expr, slot: k.slot, ind: ind + "  ", into: &lines) }
}

// The whole subtree on one line, children wrapped in `[slot]{…}`; nil if it
// contains a closure (a statement body can't be flattened).
private func flat(_ e: IRExpr) -> String? {
    if case .closure = e.kind { return nil }
    let kids = children(e)
    if kids.isEmpty { return "\(head(e)) : \(e.type)" }
    var out = "\(head(e)) : \(e.type)"
    for k in kids {
        guard let cf = flat(k.expr) else { return nil }
        out += " [\(k.slot)]{\(cf)}"
    }
    return out
}

private func children(_ e: IRExpr) -> [(slot: String, expr: IRExpr)] {
    switch e.kind {
    case .intLit, .doubleLit, .boolLit, .stringLit, .varRef, .closure:
        return []
    case .fieldAccess(let base, _):
        return [("base", base)]
    case .construct(_, let args), .enumInit(_, _, let args):
        return args.map { (argSlot($0), $0.value) }
    case .methodCall(let recv, _, let args):
        return [("receiver", recv)] + args.map { ("arg", $0) }
    case .call(let callee, let args, _):
        return [("callee", callee)] + args.map { (argSlot($0), $0.value) }
    case .binary(_, let l, let r):
        return [("lhs", l), ("rhs", r)]
    case .box(let value, _):
        return [("value", value)]
    case .arrayLit(let elements):
        return elements.map { ("elem", $0) }
    case .index(let base, let idx):
        return [("base", base), ("index", idx)]
    }
}

// Every node names its kind, then any immediate detail. Explicit rather than
// terse: the kind is real information (and more kinds are coming), so we keep it.
private func head(_ e: IRExpr) -> String {
    switch e.kind {
    case .intLit(let v):           return "intLit \(v)"
    case .doubleLit(let v):        return "doubleLit \(v)"
    case .boolLit(let v):          return "boolLit \(v)"
    case .stringLit(let v):        return "stringLit \"\(v)\""
    case .varRef(let n):           return "varRef \(n)"
    case .fieldAccess(_, let f):   return "fieldAccess .\(f)"
    case .construct(let t, _):     return "construct \(t)"
    case .enumInit(let t, let c, _): return "enumInit \(t).\(c)"
    case .methodCall(_, let m, _): return "methodCall .\(m)"
    case .call:                    return "call"
    case .binary(let op, _, _):    return "binary \(opSym(op))"
    case .closure:                 return "closure"
    case .box(_, let ifaces):      return "box any \(ifaces.joined(separator: " & "))"
    case .arrayLit(let elements):  return "arrayLit [\(elements.count)]"
    case .index:                   return "index"
    }
}

private func argSlot(_ a: IRArg) -> String { a.label ?? "arg" }

private func opSym(_ op: BinOp) -> String {
    switch op {
    case .add: return "+";  case .sub: return "-";  case .mul: return "*";  case .div: return "/";  case .mod: return "%"
    case .eq:  return "=="; case .neq: return "!="; case .lt:  return "<"
    case .gt:  return ">";  case .lte: return "<="; case .gte: return ">="
    }
}
