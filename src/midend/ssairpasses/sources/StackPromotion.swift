import ssair
import support

// Stack promotion (M7 · 7.3) — a transform that consumes the escape fact (`EscapeAnalysis.swift`). It
// rewrites each non-escaping `alloc` of a promotable type to a `stackAlloc` and drops the now-unnecessary
// write barriers into those objects (I7 — a store into a stack slot, itself a root scanned every GC,
// needs no barrier). The egress allocates the object's storage in the entry block; SROA then
// scalar-replaces it, so a managed field becomes a statepoint-tracked SSA root (I5). Class instances are
// promoted; actors are never (their mailbox/drain semantics assume a shared heap object), and struct/enum
// values are already `stackAlloc`.
//
// The escape fact is injected (task 165.2): the transform calls a provider rather than computing escape
// itself. The default provider is the standalone `escapingValues` analysis; task 164 will pass a
// store-backed provider so the transform reads precomputed interprocedural facts.
public struct StackPromotion: SSAPass {
    private let escaping: (SSAFunction) -> Set<Int>
    public init(escaping: @escaping (SSAFunction) -> Set<Int> = escapingValues) { self.escaping = escaping }
    public var name: String { "stack-promotion" }

    public func run(_ module: inout SSAModule) {
        for fi in module.functions.indices {
            let escaping = self.escaping(module.functions[fi])
            var promoted = Set<Int>()        // `alloc` sites → `stackAlloc`
            var stackObjects = Set<Int>()    // `makeClosure`/`box` results → the object stack-allocated
            for blk in module.functions[fi].blocks {
                for inst in blk.insts {
                    guard let r = inst.result, !escaping.contains(r.id) else { continue }
                    switch inst.kind {
                    case .alloc(let t) where isPromotable(t): promoted.insert(r.id)
                    case .makeClosure, .box:                  stackObjects.insert(r.id)
                    default:                                  break
                    }
                }
            }
            if promoted.isEmpty && stackObjects.isEmpty { continue }
            for bi in module.functions[fi].blocks.indices {
                var insts: [SSAInst] = []
                insts.reserveCapacity(module.functions[fi].blocks[bi].insts.count)
                for inst in module.functions[fi].blocks[bi].insts {
                    let onStack = inst.result.map { stackObjects.contains($0.id) } ?? false
                    switch inst.kind {
                    case .alloc(let t) where inst.result.map({ promoted.contains($0.id) }) ?? false:
                        insts.append(SSAInst(result: inst.result, kind: .stackAlloc(t), span: inst.span))
                    case .makeClosure(let fn, let env, _) where onStack:
                        insts.append(SSAInst(result: inst.result, kind: .makeClosure(funcName: fn, env: env, onStack: true), span: inst.span))
                    case .box(let v, let ifaces, _) where onStack:
                        insts.append(SSAInst(result: inst.result, kind: .box(value: v, interfaces: ifaces, onStack: true), span: inst.span))
                    case .writeBarrier(let object, _) where promoted.contains(object.id):
                        continue   // barrier into a stack slot — drop (the following store remains)
                    default:
                        insts.append(inst)
                    }
                }
                module.functions[fi].blocks[bi].insts = insts
            }
        }
    }

    // Which `alloc` types promote to a `stackAlloc` slot. Only class instances. Actors keep their
    // shared-heap semantics; struct/enum values are already `stackAlloc`. A non-escaping closure
    // *object* promotes separately (the `makeClosure` `onStack` flag), but its `env` object still
    // allocates here as a heap class — env stack-promotion is a scoped follow-up (the `p1` env-param
    // addrspace wall); a spawn env is likewise never promoted (it crosses the fiber boundary).
    private func isPromotable(_ t: Type) -> Bool {
        if case .named(_, .class_) = t { return true }
        return false
    }
}
