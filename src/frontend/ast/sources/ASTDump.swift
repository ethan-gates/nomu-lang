import support
// Produces a human-readable indented tree of a parsed Program.

public func dumpAST(_ program: Program) -> String {
    var lines: [String] = ["Program"]
    for decl in program.decls {
        appendTopDecl(decl, ind: "  ", into: &lines)
    }
    return lines.joined(separator: "\n")
}

// MARK: - Top-level declarations

private func appendTopDecl(_ decl: TopDecl, ind: String, into lines: inout [String]) {
    switch decl {
    case .structDecl(let s):
        lines.append("\(ind)StructDecl '\(s.name)'\(conformanceSuffix(s.conformances))")
        for f in s.fields { lines.append("\(ind)  \(f.isMutable ? "var" : "let") \(f.name): \(f.type.name)") }
        for p in s.properties { appendProperty(p, ind: ind + "  ", into: &lines) }
        for m in s.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .enumDecl(let e):
        lines.append("\(ind)EnumDecl '\(e.name)'\(conformanceSuffix(e.conformances))")
        for c in e.cases {
            let fields = c.fields.map { "\($0.name): \($0.type.name)" }.joined(separator: ", ")
            lines.append("\(ind)  Case '\(c.name)'(\(fields))")
        }
        for p in e.properties { appendProperty(p, ind: ind + "  ", into: &lines) }
        for m in e.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .classDecl(let c):
        lines.append("\(ind)ClassDecl '\(c.name)'\(conformanceSuffix(c.conformances))")
        for f in c.fields { lines.append("\(ind)  \(f.isMutable ? "var" : "let") \(f.name): \(f.type.name)") }
        for p in c.properties { appendProperty(p, ind: ind + "  ", into: &lines) }
        for m in c.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    case .actorDecl(let a):
        lines.append("\(ind)ActorDecl '\(a.name)'\(conformanceSuffix(a.conformances))")
        for f in a.fields {
            let init_ = f.initializer.map { " = \(describeExpr($0))" } ?? ""
            lines.append("\(ind)  Field \(f.name): \(f.type.name)\(init_)")
        }
        for h in a.handlers {
            let params = h.params.map { "\($0.label): \($0.type.name)" }.joined(separator: ", ")
            let ret = h.returnType.map { " -> \($0.name)" } ?? ""
            lines.append("\(ind)  OnHandler '\(h.name)'(\(params))\(ret)")
            appendBlock(h.body, ind: ind + "    ", into: &lines)
        }
    case .interfaceDecl(let i):
        lines.append("\(ind)InterfaceDecl '\(i.name)'\(conformanceSuffix(i.refines))")
        for m in i.methods {
            let params = m.params.map { "\($0.label): \($0.type.name)" }.joined(separator: ", ")
            let ret = m.returnType.map { " -> \($0.name)" } ?? ""
            let kind = m.defaultBody == nil ? "Requirement" : "Default"
            lines.append("\(ind)  \(kind) '\(m.name)'(\(params))\(ret)")
            if let body = m.defaultBody { appendBlock(body, ind: ind + "    ", into: &lines) }
        }
        for p in i.properties {
            lines.append("\(ind)  PropertyReq '\(p.name)': \(p.type.name) { get\(p.isSettable ? " set" : "") }")
        }
    case .funcDecl(let f):
        let params = f.params.map { "\($0.label): \($0.type.name)" }.joined(separator: ", ")
        let ret = f.returnType.map { " -> \($0.name)" } ?? ""
        lines.append("\(ind)FuncDecl '\(f.name)'(\(params))\(ret)")
        appendBlock(f.body, ind: ind + "  ", into: &lines)
    case .extensionDecl(let x):
        lines.append("\(ind)ExtensionDecl '\(x.typeName)'")
        for m in x.methods { appendMethod(m, ind: ind + "  ", into: &lines) }
    }
}

// A `fun` member (instance method) — same shape as a top-level FuncDecl (T3).
private func appendMethod(_ m: FuncDecl, ind: String, into lines: inout [String]) {
    let params = m.params.map { "\($0.label): \($0.type.name)" }.joined(separator: ", ")
    let ret = m.returnType.map { " -> \($0.name)" } ?? ""
    lines.append("\(ind)Method '\(m.name)'(\(params))\(ret)")
    appendBlock(m.body, ind: ind + "  ", into: &lines)
}

private func conformanceSuffix(_ cs: [Conformance]) -> String {
    cs.isEmpty ? "" : ": " + cs.map(\.name).joined(separator: ", ")
}

// A computed property: its getter body, and a setter body if settable (M5 A1).
private func appendProperty(_ p: ComputedProperty, ind: String, into lines: inout [String]) {
    lines.append("\(ind)Property '\(p.name)': \(p.type.name)")
    lines.append("\(ind)  get")
    appendBlock(p.getter, ind: ind + "    ", into: &lines)
    if let setter = p.setter {
        lines.append("\(ind)  set(\(setter.paramName))")
        appendBlock(setter.body, ind: ind + "    ", into: &lines)
    }
}

// MARK: - Statements

private func appendBlock(_ block: Block, ind: String, into lines: inout [String]) {
    for stmt in block { appendStmt(stmt, ind: ind, into: &lines) }
}

private func appendStmt(_ stmt: Stmt, ind: String, into lines: inout [String]) {
    switch stmt {
    case .binding(let b):
        let kw    = b.isMutable ? "var" : "let"
        let annot = b.type.map { ": \($0.name)" } ?? ""
        lines.append("\(ind)\(kw) \(b.name)\(annot) = \(describeExpr(b.value))")
    case .spawnLet(let name, let type, let value, _):
        let annot = type.map { ": \($0.name)" } ?? ""
        lines.append("\(ind)spawn let \(name)\(annot) = \(describeExpr(value))")
    case .assign(let lhs, let rhs, _):
        lines.append("\(ind)\(describeExpr(lhs)) = \(describeExpr(rhs))")
    case .compoundAssign(let lhs, let rhs, _):
        lines.append("\(ind)\(describeExpr(lhs)) += \(describeExpr(rhs))")
    case .ret(let e, _):
        lines.append("\(ind)return\(e.map { " \(describeExpr($0))" } ?? "")")
    case .ifStmt(let s):
        lines.append("\(ind)if \(describeExpr(s.cond))")
        appendBlock(s.thenBody, ind: ind + "  ", into: &lines)
        if let elseBody = s.elseBody {
            lines.append("\(ind)else")
            appendBlock(elseBody, ind: ind + "  ", into: &lines)
        }
    case .whileStmt(let s):
        lines.append("\(ind)while \(describeExpr(s.cond))")
        appendBlock(s.body, ind: ind + "  ", into: &lines)
    case .breakStmt:
        lines.append("\(ind)break")
    case .continueStmt:
        lines.append("\(ind)continue")
    case .switchStmt(let sw):
        lines.append("\(ind)switch \(describeExpr(sw.subject))")
        for arm in sw.cases {
            lines.append("\(ind)  \(describePattern(arm.pattern))")
            appendBlock(arm.body, ind: ind + "    ", into: &lines)
        }
    case .expr(let e):
        lines.append("\(ind)\(describeExpr(e))")
    }
}

// MARK: - Expressions and patterns (single-line descriptions)

private func describeExpr(_ e: Expr) -> String {
    switch e {
    case .intLit(let v, _):    return "\(v)"
    case .doubleLit(let v, _): return "\(v)"
    case .boolLit(let v, _):   return v ? "true" : "false"
    case .stringLit(let v, _): return "\"\(v)\""
    case .ident(let n, _):     return n
    case .genericIdent(let n, let targs, _): return "\(n)<\(targs.map(\.name).joined(separator: ", "))>"
    case .member(let b, let f, _): return "\(describeExpr(b)).\(f)"
    case .implicitMember(let name, _): return ".\(name)"
    case .binary(let op, let l, let r, _):
        return "\(describeExpr(l)) \(describeOp(op)) \(describeExpr(r))"
    case .call(let callee, let args, _):
        return "\(describeExpr(callee))(\(describeArgs(args)))"
    case .closure(let params, let ret, _, _):
        let ps = params.map { "\($0.name): \($0.type.name)" }.joined(separator: ", ")
        let r = ret.map { " -> \($0.name)" } ?? ""
        return "{ (\(ps))\(r) in … }"
    case .arrayLit(let elems, _):
        return "[\(elems.map(describeExpr).joined(separator: ", "))]"
    case .index(let base, let idx, _):
        return "\(describeExpr(base))[\(describeExpr(idx))]"
    case .error:
        return "<error>"
    }
}

private func describeArgs(_ args: [Arg]) -> String {
    args.map { a in
        let label = a.label.map { "\($0): " } ?? ""
        return "\(label)\(describeExpr(a.value))"
    }.joined(separator: ", ")
}

private func describePattern(_ p: Pattern) -> String {
    switch p {
    case .enumCase(let name, let bindings, _):
        let b = bindings.isEmpty ? "" : "(\(bindings.joined(separator: ", ")))"
        return "case .\(name)\(b)"
    }
}

private func describeOp(_ op: BinOp) -> String {
    switch op {
    case .add: return "+"
    case .sub: return "-"
    case .mul: return "*"
    case .div: return "/"
    case .mod: return "%"
    case .eq:  return "=="
    case .neq: return "!="
    case .lt:  return "<"
    case .gt:  return ">"
    case .lte: return "<="
    case .gte: return ">="
    }
}
