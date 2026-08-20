import ssair
import support

// Inlining (M7 · 7.5). Substitute a small direct-call body at the call site.
//
//   Phase A — single-block callees: a callee that is one block ending in `ret` splices its
//   instructions straight into the caller block (params → args, returned value → the call result).
//   No CFG surgery, no return φ.
//
//   Phase B — multi-block callees: a callee with real control flow is inlined by CFG surgery. The
//   caller block is split at the call; the callee's blocks are cloned with fresh block + value ids
//   and spliced in; each `ret v` becomes a branch into a fresh continuation block whose single
//   parameter is the return φ (the join of every return value), and the call result is replaced by
//   that parameter. Runs to a fixpoint per caller under an instruction-growth budget.
//
// Pipeline position devirt → inline → EA (§7.0.4): a devirtualized `.direct` call becomes an inline
// candidate, and inlining brings the callee's allocations into the caller so intra-procedural EA
// (7.3) can promote them — the interprocedural-reach dividend. Callee bodies are snapshotted before
// any inlining, so inlining always substitutes the original body (self-calls are skipped; recursion
// and deep chains unroll only up to the budget). Multi-block inlining preserves every back-edge and
// introduces no first-class aggregate, so loop-header safepoint coverage (I9) and the no-managed-
// value-in-an-FCA rule (I10) hold by construction; the post-pass verifier re-checks I1–I7.
public struct Inline: SSAPass {
    public init() {}
    public var name: String { "inlining" }

    private let maxSingleInsts = 12    // single-block callee size cap (splice)
    private let maxMultiInsts = 40     // multi-block callee size cap (surgery)
    private let multiBudget = 200      // per-caller cap on cloned instructions (bounds growth + recursion)

    public func run(_ module: inout SSAModule) {
        var singleBlock: [String: SSAFunction] = [:]
        var multiBlock: [String: SSAFunction] = [:]
        for f in module.functions where !f.blocks.isEmpty {
            let total = f.blocks.reduce(0) { $0 + $1.insts.count }
            if f.blocks.count == 1, case .ret = f.blocks[0].terminator.kind, total <= maxSingleInsts {
                singleBlock[f.name] = f
            } else if f.blocks.count > 1, total <= maxMultiInsts,
                      f.blocks[0].params.isEmpty, hasReturn(f) {
                multiBlock[f.name] = f
            }
        }
        if singleBlock.isEmpty && multiBlock.isEmpty { return }

        for ci in module.functions.indices where !module.functions[ci].blocks.isEmpty {
            if !singleBlock.isEmpty { spliceSingleBlock(&module.functions[ci], singleBlock) }
            if !multiBlock.isEmpty { inlineMultiBlock(&module.functions[ci], multiBlock) }
        }
    }

    private func hasReturn(_ f: SSAFunction) -> Bool {
        f.blocks.contains { if case .ret = $0.terminator.kind { return true }; return false }
    }

    // MARK: - Phase A: single-block splice (no CFG change)

    private func spliceSingleBlock(_ fn: inout SSAFunction, _ inlinable: [String: SSAFunction]) {
        let callerName = fn.name
        var nextId = freshBase(fn)
        var subst: [Int: SSAValue] = [:]      // caller call-result id → the callee's returned value
        var changed = false

        for bi in fn.blocks.indices {
            var out: [SSAInst] = []
            out.reserveCapacity(fn.blocks[bi].insts.count)
            for inst in fn.blocks[bi].insts {
                guard case .call(let c) = inst.kind, case .direct(let name) = c.kind,
                      name != callerName, let callee = inlinable[name],
                      callee.params.count == c.args.count else {
                    out.append(inst); continue
                }
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
                if case .ret(let rv) = body.terminator.kind, let rv, let res = inst.result {
                    subst[res.id] = vmap[rv.id] ?? rv
                }
                changed = true
            }
            fn.blocks[bi].insts = out
        }
        guard changed else { return }

        for bi in fn.blocks.indices {
            let insts = fn.blocks[bi].insts.map {
                SSAInst(result: $0.result, kind: remapOperands($0.kind) { subst[$0.id] ?? $0 }, span: $0.span)
            }
            let term = fn.blocks[bi].terminator
            let newTerm = SSATerm(kind: remapOperands(term.kind) { subst[$0.id] ?? $0 }, span: term.span)
            let b = fn.blocks[bi]
            fn.blocks[bi] = SSABlock(id: b.id, params: b.params, insts: insts, terminator: newTerm)
        }
    }

    // MARK: - Phase B: multi-block inline (CFG surgery)

    private func inlineMultiBlock(_ fn: inout SSAFunction, _ callees: [String: SSAFunction]) {
        var budget = multiBudget
        while true {
            var target: (bi: Int, k: Int, call: SSACall, result: SSAValue?, span: Span, callee: SSAFunction)?
            search: for bi in fn.blocks.indices {
                for (k, inst) in fn.blocks[bi].insts.enumerated() {
                    guard case .call(let c) = inst.kind, case .direct(let name) = c.kind,
                          name != fn.name, let callee = callees[name],
                          callee.params.count == c.args.count else { continue }
                    let size = callee.blocks.reduce(0) { $0 + $1.insts.count }
                    guard size <= budget else { continue }
                    target = (bi, k, c, inst.result, inst.span, callee)
                    budget -= size
                    break search
                }
            }
            guard let t = target else { return }
            performInline(&fn, blockIndex: t.bi, instIndex: t.k, call: t.call,
                          callResult: t.result, callSpan: t.span, callee: t.callee)
        }
    }

    private func performInline(_ fn: inout SSAFunction, blockIndex bi: Int, instIndex k: Int,
                               call c: SSACall, callResult: SSAValue?, callSpan: Span, callee: SSAFunction) {
        var nextVal = freshBase(fn)
        func freshVal(_ t: Type) -> SSAValue { defer { nextVal += 1 }; return SSAValue(id: nextVal, type: t) }
        var nextBlk = (fn.blocks.map(\.id).max() ?? 0) + 1
        func freshBlk() -> Int { defer { nextBlk += 1 }; return nextBlk }

        // Fresh block ids for every callee block, plus a continuation block for the returns to join.
        var blockMap: [Int: Int] = [:]
        for b in callee.blocks { blockMap[b.id] = freshBlk() }
        let contId = freshBlk()

        // Value map: callee params → the call args; callee block-params + results → fresh values.
        var vmap: [Int: SSAValue] = [:]
        for (p, a) in zip(callee.params, c.args) { vmap[p.id] = a }
        for b in callee.blocks {
            for p in b.params { vmap[p.id] = freshVal(p.type) }
            for ins in b.insts { if let r = ins.result { vmap[r.id] = freshVal(r.type) } }
        }
        func mapVal(_ v: SSAValue) -> SSAValue { vmap[v.id] ?? v }

        // The continuation parameter is the return φ — present iff the call produces a value.
        let retParam: SSAValue? = callResult.map { freshVal($0.type) }

        // Clone the callee blocks, rewriting `ret v` into a branch into the continuation block.
        var cloned: [SSABlock] = []
        for b in callee.blocks {
            let insts = b.insts.map {
                SSAInst(result: $0.result.map(mapVal), kind: remapOperands($0.kind, mapVal), span: $0.span)
            }
            let term: SSATermKind
            if case .ret(let rv) = b.terminator.kind {
                term = .br(target: contId, args: rv.map { [mapVal($0)] } ?? [])
            } else {
                term = remapTargets(remapOperands(b.terminator.kind, mapVal), blockMap)
            }
            cloned.append(SSABlock(id: blockMap[b.id]!, params: b.params.map(mapVal),
                                   insts: insts, terminator: SSATerm(kind: term, span: b.terminator.span)))
        }

        // Replace the call result with the continuation parameter everywhere it is used (the result
        // dominated only what the caller block's terminator reached, which the continuation now owns).
        func subResult(_ v: SSAValue) -> SSAValue {
            if let cr = callResult, v.id == cr.id, let rp = retParam { return rp }
            return v
        }

        let src = fn.blocks[bi]
        let head = Array(src.insts[..<k])                       // insts before the call (no use of its result)
        let tail = Array(src.insts[(k + 1)...])                 // insts after the call
        let contInsts = tail.map { SSAInst(result: $0.result, kind: remapOperands($0.kind, subResult), span: $0.span) }
        let contTerm = SSATerm(kind: remapOperands(src.terminator.kind, subResult), span: src.terminator.span)
        let contBlock = SSABlock(id: contId, params: retParam.map { [$0] } ?? [], insts: contInsts, terminator: contTerm)

        // The caller block keeps its id + params (edges into it are unchanged) and now branches into
        // the callee's cloned entry (which has no parameters — checked at eligibility).
        let entryClone = blockMap[callee.blocks[0].id]!
        let bPrime = SSABlock(id: src.id, params: src.params, insts: head,
                              terminator: SSATerm(kind: .br(target: entryClone, args: []), span: callSpan))

        var newBlocks: [SSABlock] = []
        newBlocks.reserveCapacity(fn.blocks.count + cloned.count + 1)
        for (idx, blk) in fn.blocks.enumerated() {
            if idx == bi {
                newBlocks.append(bPrime)
                newBlocks.append(contentsOf: cloned)
                newBlocks.append(contBlock)
            } else {
                let insts = blk.insts.map { SSAInst(result: $0.result, kind: remapOperands($0.kind, subResult), span: $0.span) }
                let term = SSATerm(kind: remapOperands(blk.terminator.kind, subResult), span: blk.terminator.span)
                newBlocks.append(SSABlock(id: blk.id, params: blk.params, insts: insts, terminator: term))
            }
        }
        fn.blocks = newBlocks
    }

    // Rename a terminator's edge targets under a block-id map (values are left to `remapOperands`).
    private func remapTargets(_ kind: SSATermKind, _ m: [Int: Int]) -> SSATermKind {
        func t(_ id: Int) -> Int { m[id] ?? id }
        switch kind {
        case .br(let target, let args):
            return .br(target: t(target), args: args)
        case .condBr(let cond, let th, let ta, let el, let ea):
            return .condBr(cond: cond, then: t(th), thenArgs: ta, else: t(el), elseArgs: ea)
        case .switchOn(let s, let cases, let d, let da):
            return .switchOn(scrutinee: s, cases: cases.map { SSASwitchCase(value: $0.value, target: t($0.target), args: $0.args) },
                             defaultTarget: t(d), defaultArgs: da)
        case .ret, .unreachable:
            return kind
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
