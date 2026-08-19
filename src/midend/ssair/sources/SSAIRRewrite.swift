import ast

// Operand remapping over SSAIR — replace value uses under a mapping `f`, leaving instruction results
// and block/edge structure intact. Used by ssairgen's trivial-block-argument cleanup and, later, by
// the transform passes (a rewrite that substitutes one value for another is the common shape). `f`
// must preserve type: a replacement value has the same `Type` as the value it replaces.

public func remapOperands(_ kind: SSAInstKind, _ f: (SSAValue) -> SSAValue) -> SSAInstKind {
    switch kind {
    case .constInt, .constDouble, .constBool, .constString, .alloc, .stackAlloc:
        return kind
    case .binary(let op, let a, let b):
        return .binary(op, f(a), f(b))
    case .load(let a):
        return .load(f(a))
    case .store(let addr, let v):
        return .store(addr: f(addr), value: f(v))
    case .writeBarrier(let obj, let v):
        return .writeBarrier(object: f(obj), value: f(v))
    case .fieldAddr(let base, let i):
        return .fieldAddr(base: f(base), fieldIndex: i)
    case .elementAddr(let base, let idx):
        return .elementAddr(base: f(base), index: f(idx))
    case .arrayLen(let a):
        return .arrayLen(f(a))
    case .boundscheck(let idx, let len):
        return .boundscheck(index: f(idx), length: f(len))
    case .call(let c):
        return .call(SSACall(kind: remapCallKind(c.kind, f), args: c.args.map(f), typeArgs: c.typeArgs))
    case .mailboxInit(let a):
        return .mailboxInit(f(a))
    case .actorSend(let recv, let h, let args):
        return .actorSend(receiver: f(recv), handler: h, args: args.map(f))
    case .spawn(let binding, let startFn, let env, let t):
        return .spawn(binding: binding, startFn: startFn, env: env.map(f), resultType: t)
    case .spawnJoin:
        return kind
    case .makeStruct(let t, let fields):
        return .makeStruct(t, fields: fields.map(f))
    case .makeEnum(let t, let ci, let fields):
        return .makeEnum(t, caseIndex: ci, fields: fields.map(f))
    case .extractField(let base, let i):
        return .extractField(base: f(base), fieldIndex: i)
    case .enumTag(let a):
        return .enumTag(f(a))
    case .extractPayload(let base, let ci, let fi):
        return .extractPayload(base: f(base), caseIndex: ci, fieldIndex: fi)
    case .box(let v, let ifaces, let onStack):
        return .box(value: f(v), interfaces: ifaces, onStack: onStack)
    case .arrayLit(let elems, let elem):
        return .arrayLit(elements: elems.map(f), elem: elem)
    case .makeClosure(let name, let env, let onStack):
        return .makeClosure(funcName: name, env: env.map(f), onStack: onStack)
    }
}

public func remapCallKind(_ kind: SSACallKind, _ f: (SSAValue) -> SSAValue) -> SSACallKind {
    switch kind {
    case .direct:
        return kind
    case .witness(let recv, let iface, let method):
        return .witness(receiver: f(recv), interface: iface, method: method)
    case .indirect(let callee):
        return .indirect(f(callee))
    }
}

public func remapOperands(_ kind: SSATermKind, _ f: (SSAValue) -> SSAValue) -> SSATermKind {
    switch kind {
    case .br(let target, let args):
        return .br(target: target, args: args.map(f))
    case .condBr(let cond, let t, let ta, let e, let ea):
        return .condBr(cond: f(cond), then: t, thenArgs: ta.map(f), else: e, elseArgs: ea.map(f))
    case .switchOn(let scrut, let cases, let def, let defArgs):
        let mapped = cases.map { SSASwitchCase(value: $0.value, target: $0.target, args: $0.args.map(f)) }
        return .switchOn(scrutinee: f(scrut), cases: mapped, defaultTarget: def, defaultArgs: defArgs.map(f))
    case .ret(let v):
        return .ret(v.map(f))
    case .unreachable:
        return .unreachable
    }
}

// The successor block ids of a terminator (edge targets), in edge order.
public func successors(_ kind: SSATermKind) -> [Int] {
    switch kind {
    case .br(let t, _):                       return [t]
    case .condBr(_, let t, _, let e, _):      return [t, e]
    case .switchOn(_, let cases, let d, _):   return cases.map(\.target) + [d]
    case .ret, .unreachable:                  return []
    }
}
