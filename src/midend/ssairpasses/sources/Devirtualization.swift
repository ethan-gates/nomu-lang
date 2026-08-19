import ssair
import support

// Devirtualization (M7 · 7.4). Rewrite a `call .witness` to a `call .direct` where the concrete
// conformer is statically known. After whole-program monomorphization (M5) resolves generic dispatch
// and ssairgen devirtualizes `some I`/opaque at lowering, the residual target is the **locally
// constructed box**: a `.witness(receiver, I, m)` whose `receiver` is defined by a `box(value: v, …)`
// in the same function. The concrete conformer is then `v`'s type `T`, and the call becomes
// `.direct("m:T:m", self: v, …)` — the exact shape ssairgen emits for a concrete `v.m(…)` call.
//
// Besides removing the dynamic dispatch, this un-uses the box: its result stops being a witness
// receiver, so a locally-dispatched box then falls out through StackPromotion (7.3) / dead-alloca DCE.
// Devirt therefore runs *before* EA in the pipeline (§7.0.4: devirt → inline → EA/BCE).
public struct Devirtualize: SSAPass {
    public init() {}
    public var name: String { "devirtualization" }

    public func run(_ module: inout SSAModule) {
        // Concrete method targets present in the module + their mutating-ness (the self-ABI depends on
        // it). Keyed by the mangled `m:Type:method` name ssairgen emits (`ModuleContext.methodSymbol`).
        var mutatingByName: [String: Bool] = [:]
        for f in module.functions { mutatingByName[f.name] = f.isMutating }

        for fi in module.functions.indices {
            // A box result id → (payload value, concrete type name, payload is a reference type).
            var boxDef: [Int: (payload: SSAValue, type: String, isRef: Bool)] = [:]
            for blk in module.functions[fi].blocks {
                for inst in blk.insts {
                    guard case .box(let v, _, _) = inst.kind, let r = inst.result,
                          case .named(let t, let kind) = v.type else { continue }
                    boxDef[r.id] = (v, t, kind == .class_ || kind == .actor_)
                }
            }
            if boxDef.isEmpty { continue }

            for bi in module.functions[fi].blocks.indices {
                for ii in module.functions[fi].blocks[bi].insts.indices {
                    let inst = module.functions[fi].blocks[bi].insts[ii]
                    guard case .call(let c) = inst.kind,
                          case .witness(let recv, _, let method) = c.kind,
                          let box = boxDef[recv.id] else { continue }
                    // Mirrors `ModuleContext.methodSymbol` (ssairgen). Guarding on the target existing
                    // makes an absent/mismatched name a safe no-op rather than a bad call.
                    let target = "m:\(box.type):\(method)"
                    guard let mutating = mutatingByName[target] else { continue }
                    // Self ABI: a reference-type self is always the object pointer (`v`); a non-mutating
                    // value self is the value (`v`). A mutating value method wants the receiver's
                    // *address* and would mutate storage separate from the box's copy — skip it.
                    if !box.isRef && mutating { continue }
                    let direct = SSACall(kind: .direct(target), args: [box.payload] + c.args, typeArgs: c.typeArgs)
                    module.functions[fi].blocks[bi].insts[ii] =
                        SSAInst(result: inst.result, kind: .call(direct), span: inst.span)
                }
            }
        }
    }
}
