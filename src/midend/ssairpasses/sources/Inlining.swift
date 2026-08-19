import ssair
import support

// Inlining (M7 · 7.5). Substitute a small direct-call body at the call site. **First slice: single-block
// callees** — a callee whose body is one block ending in `ret` splices its instructions straight into
// the caller block. Params map to the call args; the returned value replaces the call result. No CFG
// surgery, no return φ (that is the multi-block follow-up).
//
// Pipeline position devirt → inline → EA (§7.0.4): a devirtualized `.direct` call becomes an inline
// candidate, and inlining brings the callee's allocations into the caller so intra-procedural EA
// (7.3) can promote them — the interprocedural-reach dividend. Single-level per run (spliced bodies
// are not re-scanned this pass); deeper chains want a fixpoint, deferred.
public struct Inline: SSAPass {
    public init() {}
    public var name: String { "inlining" }

    // Inline a single-block callee only up to this many instructions (bound code growth).
    private let maxCalleeInsts = 12

    public func run(_ module: inout SSAModule) {
        // Eligible callees: exactly one block, `ret` terminator, small.
        var inlinable: [String: SSAFunction] = [:]
        for f in module.functions {
            guard f.blocks.count == 1, case .ret = f.blocks[0].terminator.kind,
                  f.blocks[0].insts.count <= maxCalleeInsts else { continue }
            inlinable[f.name] = f
        }
        if inlinable.isEmpty { return }

        for ci in module.functions.indices where !module.functions[ci].blocks.isEmpty {
            let callerName = module.functions[ci].name
            var nextId = freshBase(module.functions[ci])
            var subst: [Int: SSAValue] = [:]      // caller call-result id → the callee's returned value
            var changed = false

            // Splice pass: replace each eligible direct call with the callee body (fresh-id'd).
            for bi in module.functions[ci].blocks.indices {
                var out: [SSAInst] = []
                out.reserveCapacity(module.functions[ci].blocks[bi].insts.count)
                for inst in module.functions[ci].blocks[bi].insts {
                    guard case .call(let c) = inst.kind, case .direct(let name) = c.kind,
                          name != callerName, let callee = inlinable[name],
                          callee.params.count == c.args.count else {
                        out.append(inst); continue
                    }
                    // Map the callee's values: params → the call args; each result → a fresh caller value.
                    var vmap: [Int: SSAValue] = [:]
                    for (p, a) in zip(callee.params, c.args) { vmap[p.id] = a }
                    let body = callee.blocks[0]
                    for cinst in body.insts {
                        let kind = remapOperands(cinst.kind) { vmap[$0.id] ?? $0 }
                        if let r = cinst.result {
                            let nr = SSAValue(id: nextId, type: r.type); nextId += 1
                            vmap[r.id] = nr
                            out.append(SSAInst(result: nr, kind: kind, span: inst.span))
                        } else {
                            out.append(SSAInst(result: nil, kind: kind, span: inst.span))
                        }
                    }
                    // The call result becomes the returned value (an arg or a freshly-cloned value).
                    if case .ret(let rv) = body.terminator.kind, let rv, let res = inst.result {
                        subst[res.id] = vmap[rv.id] ?? rv
                    }
                    changed = true
                }
                module.functions[ci].blocks[bi].insts = out
            }
            guard changed else { continue }

            // Substitute call results everywhere (later insts, terminators, successor blocks). The
            // returned values are args / fresh clones — never themselves call results — so one pass
            // suffices. `nr` is spliced before the call site, so it dominates every use of the result.
            for bi in module.functions[ci].blocks.indices {
                let insts = module.functions[ci].blocks[bi].insts.map {
                    SSAInst(result: $0.result, kind: remapOperands($0.kind) { subst[$0.id] ?? $0 }, span: $0.span)
                }
                let term = module.functions[ci].blocks[bi].terminator
                let newTerm = SSATerm(kind: remapOperands(term.kind) { subst[$0.id] ?? $0 }, span: term.span)
                let b = module.functions[ci].blocks[bi]
                module.functions[ci].blocks[bi] = SSABlock(id: b.id, params: b.params, insts: insts, terminator: newTerm)
            }
        }
    }

    // A value id one past every value defined in `f` (params, block params, results) — the base for
    // fresh ids introduced by inlining, so a cloned callee value can never collide with a caller value.
    private func freshBase(_ f: SSAFunction) -> Int {
        var m = 0
        for p in f.params { m = max(m, p.id) }
        for b in f.blocks {
            for p in b.params { m = max(m, p.id) }
            for i in b.insts { if let r = i.result { m = max(m, r.id) } }
        }
        return m + 1
    }
}
