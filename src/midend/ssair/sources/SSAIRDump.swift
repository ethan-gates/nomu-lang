import ast
import support

// A human-readable dump of SSAIR — the `--emit-ssair` output (wired at 7.2.4) and the debug
// visibility into lowering-in / the passes (design: noir.md, ssair.md).
//
// A flat, textual SSA form (LLVM/MLIR-flavored): values are `%<id>` with a trailing `: Type`, blocks
// are `bb<id>(params):` followed by their instructions and one terminator. Every def prints its type
// (the "typed values" invariant is visible on the page). Spans are not printed by default — they
// clutter the CFG; a span-annotated mode can be added if a pass needs it.

public func dumpSSAIR(_ module: SSAModule) -> String {
    var lines: [String] = ["ssair module"]

    for agg in module.aggregates {
        let fs = agg.fields.map { "\($0.isMutable ? "var" : "let") \($0.name) : \($0.type)" }.joined(separator: ", ")
        lines.append("")
        lines.append("\(kindWord(agg.kind)) \(agg.name) { \(fs) }")
    }
    for en in module.enums {
        let cs = en.cases.map { c in
            let fs = c.fields.map { "\($0.name) : \($0.type)" }.joined(separator: ", ")
            return "\(c.name)(\(fs))"
        }.joined(separator: " | ")
        lines.append("")
        lines.append("enum \(en.name) { \(cs) }")
    }
    for iface in module.interfaces {
        lines.append("")
        lines.append("interface \(iface.name)"
            + (iface.bases.isEmpty ? "" : " : " + iface.bases.joined(separator: ", ")))
    }
    for c in module.conformances {
        lines.append("conformance \(c.typeName) : \(c.interfaceName)")
    }
    for c in module.composites {
        lines.append("composite \(c.typeName) : any \(c.interfaces.joined(separator: " & "))")
    }

    for fn in module.functions {
        lines.append("")
        appendFunction(fn, into: &lines)
    }
    return lines.joined(separator: "\n")
}

// MARK: - Functions and blocks

private func appendFunction(_ fn: SSAFunction, into lines: inout [String]) {
    let ps = fn.params.map { "\(val($0)) : \($0.type)" }.joined(separator: ", ")
    let mut = fn.isMutating ? " mutating" : ""
    lines.append("fun \(fn.name)(\(ps)) -> \(fn.returnType)\(mut) {")
    for block in fn.blocks { appendBlock(block, into: &lines) }
    lines.append("}")
}

private func appendBlock(_ block: SSABlock, into lines: inout [String]) {
    let hdr = block.params.isEmpty
        ? "bb\(block.id):"
        : "bb\(block.id)(" + block.params.map { "\(val($0)) : \($0.type)" }.joined(separator: ", ") + "):"
    lines.append(hdr)
    for inst in block.insts { lines.append("  " + renderInst(inst)) }
    lines.append("  " + renderTerm(block.terminator.kind))
}

// MARK: - Instructions

private func renderInst(_ inst: SSAInst) -> String {
    let body = renderKind(inst.kind)
    guard let r = inst.result else { return body }   // void op: no `%id =` prefix
    return "\(val(r)) = \(body) : \(r.type)"
}

private func renderKind(_ kind: SSAInstKind) -> String {
    switch kind {
    case .constInt(let n):    return "const \(n)"
    case .constDouble(let d): return "const \(d)"
    case .constBool(let b):   return "const \(b)"
    case .constString(let s): return "const \"\(s)\""
    case .binary(let op, let a, let b): return "\(val(a)) \(sym(op)) \(val(b))"

    case .alloc(let t):                        return "alloc \(t)"
    case .stackAlloc(let t):                   return "stackAlloc \(t)"
    case .load(let a):                         return "load \(val(a))"
    case .store(let addr, let v):              return "store \(val(addr)), \(val(v))"
    case .writeBarrier(let obj, let v):        return "writeBarrier \(val(obj)), \(val(v))"
    case .fieldAddr(let base, let i):          return "fieldAddr \(val(base)), #\(i)"
    case .elementAddr(let base, let idx):      return "elementAddr \(val(base)), \(val(idx))"
    case .arrayLen(let a):                     return "arrayLen \(val(a))"
    case .boundscheck(let idx, let len):       return "boundscheck \(val(idx)), \(val(len))"

    case .call(let c):                         return renderCall(c)
    case .mailboxInit(let a):                  return "mailboxInit \(val(a))"
    case .actorSend(let recv, let h, let args):
        return "send \(val(recv)).\(h)(\(list(args)))"
    case .spawn(let binding, let startFn, let env, _):
        return "spawn #\(binding) \(startFn)" + (env.map { " env \(val($0))" } ?? "")
    case .spawnJoin(let binding, _):           return "spawnJoin #\(binding)"

    case .makeStruct(let t, let fields):       return "makeStruct \(t)(\(list(fields)))"
    case .makeEnum(let t, let ci, let fields): return "makeEnum \(t)#\(ci)(\(list(fields)))"
    case .extractField(let base, let i):       return "extractField \(val(base)), #\(i)"
    case .enumTag(let a):                       return "enumTag \(val(a))"
    case .extractPayload(let base, let ci, let fi): return "extractPayload \(val(base)), #\(ci).\(fi)"

    case .box(let v, let ifaces, let onStack): return "\(onStack ? "stackbox" : "box") \(val(v)) as any \(ifaces.joined(separator: " & "))"
    case .arrayLit(let elems, _):              return "arrayLit [\(list(elems))]"   // element type shows in the result type
    case .makeClosure(let name, let env, let onStack):
        let kw = onStack ? "stackclosure" : "closure"
        return env.map { "\(kw) \(name) env \(val($0))" } ?? "\(kw) \(name)"
    }
}

private func renderCall(_ c: SSACall) -> String {
    let ta = c.typeArgs.isEmpty ? "" : "<" + c.typeArgs.map(\.description).joined(separator: ", ") + ">"
    switch c.kind {
    case .direct(let name):
        return "call \(name)\(ta)(\(list(c.args)))"
    case .witness(let recv, let iface, let method):
        return "call witness \(val(recv)).\(iface)::\(method)\(ta)(\(list(c.args)))"
    case .indirect(let callee):
        return "call \(val(callee))\(ta)(\(list(c.args)))"
    }
}

// MARK: - Terminators

private func renderTerm(_ kind: SSATermKind) -> String {
    switch kind {
    case .br(let target, let args):
        return "br \(blockRef(target, args))"
    case .condBr(let cond, let t, let ta, let e, let ea):
        return "condBr \(val(cond)), \(blockRef(t, ta)), \(blockRef(e, ea))"
    case .switchOn(let scrut, let cases, let def, let defArgs):
        let arms = cases.map { "\($0.value) -> \(blockRef($0.target, $0.args))" }.joined(separator: ", ")
        return "switch \(val(scrut)) [\(arms)] default \(blockRef(def, defArgs))"
    case .ret(let v):
        return v.map { "ret \(val($0))" } ?? "ret"
    case .unreachable:
        return "unreachable"
    }
}

private func blockRef(_ id: Int, _ args: [SSAValue]) -> String {
    args.isEmpty ? "bb\(id)" : "bb\(id)(\(list(args)))"
}

// MARK: - Leaves

private func val(_ v: SSAValue) -> String { "%\(v.id)" }
private func list(_ vs: [SSAValue]) -> String { vs.map(val).joined(separator: ", ") }

private func kindWord(_ k: NamedKind) -> String {
    switch k {
    case .struct_:    return "struct"
    case .class_:     return "class"
    case .actor_:     return "actor"
    case .enum_:      return "enum"
    case .interface_: return "interface"
    }
}

private func sym(_ op: BinOp) -> String {
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
    case .bitAnd: return "&"
    case .bitOr:  return "|"
    case .bitXor: return "^"
    case .shl:    return "<<"
    case .shr:    return ">>"
    case .and:    return "&&"
    case .or:     return "||"
    }
}
