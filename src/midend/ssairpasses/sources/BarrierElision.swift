import ssair

// Barrier elision: drops the write barrier on a store into an object allocated earlier in the same block with
// no safepoint between. A mutator allocation is young: under the generational plan a TLAB takes only clean
// blocks, tagged nursery, and a collection the allocation triggers runs before the object exists. Only a
// safepoint can collect, so the object is still young at the store, and the barrier, which remembers a mature
// object that may gain a young referent, has nothing to do. LXR skips logging new objects in the same way.
// A constructor's stores (`TreeNode(left: l, right: r)`: the arguments, then the allocation, then the stores)
// are the common case. Runs after inlining, which brings a constructor's stores into its caller. The verifier's
// I7 accepts exactly the stores this leaves unbarriered.
public struct BarrierElision: SSAPass {
    public init() {}
    public var name: String { "barrier-elision" }

    public func run(_ module: inout SSAModule) {
        for fi in module.functions.indices {
            for bi in module.functions[fi].blocks.indices {
                let old = module.functions[fi].blocks[bi].insts
                var young = Set<Int>()
                var insts: [SSAInst] = []
                insts.reserveCapacity(old.count)
                for inst in old {
                    if case .writeBarrier(let object, _) = inst.kind, young.contains(object.id) { continue }
                    if isSafepointInst(inst.kind) { young.removeAll() }
                    if case .alloc = inst.kind, let r = inst.result { young.insert(r.id) }
                    insts.append(inst)
                }
                if insts.count != old.count { module.functions[fi].blocks[bi].insts = insts }
            }
        }
    }
}
