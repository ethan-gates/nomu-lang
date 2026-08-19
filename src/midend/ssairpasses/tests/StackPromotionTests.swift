import support
import XCTest
import ssair
@testable import ssairpasses

// Closure-object stack promotion (M7 · 7.3). A non-escaping closure *object* (`makeClosure` result)
// is stack-allocated (`onStack = true`); its `env` object stays heap this slice. An escaping closure
// stays heap. Soundness is that *only* a non-escaping closure gets the flag.
final class StackPromotionTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private let envTy = Type.named("clo.0.env", .class_)
    private let cloTy = Type.function(params: [.int], ret: .int)

    private func module(_ blocks: [SSABlock]) -> SSAModule {
        SSAModule(functions: [SSAFunction(name: "f", params: [], returnType: .void,
                                          blocks: blocks, isMutating: false, span: sp)])
    }

    // Find the `onStack` flag of the single makeClosure in the module (nil if absent).
    private func closureOnStack(_ m: SSAModule) -> Bool? {
        for f in m.functions { for b in f.blocks { for i in b.insts {
            if case .makeClosure(_, _, let onStack) = i.kind { return onStack }
        } } }
        return nil
    }

    // Find the `onStack` flag of the single box in the module (nil if absent).
    private func boxOnStack(_ m: SSAModule) -> Bool? {
        for f in m.functions { for b in f.blocks { for i in b.insts {
            if case .box(_, _, let onStack) = i.kind { return onStack }
        } } }
        return nil
    }

    // Whether value id `id` is defined by a heap `alloc` (vs a promoted `stackAlloc`).
    private func isHeapAlloc(_ m: SSAModule, _ id: Int) -> Bool {
        for f in m.functions { for b in f.blocks { for i in b.insts where i.result?.id == id {
            if case .alloc = i.kind { return true }
        } } }
        return false
    }

    // A closure created and only *called* (indirect) is non-escaping → the object promotes; its env
    // stays a heap `alloc` (the env-promotion follow-up is separate).
    func testCalledClosurePromotesObjectKeepsEnvHeap() {
        let env = v(0, envTy), clo = v(1, cloTy), arg = v(2, .int), res = v(3, .int)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: env, kind: .alloc(envTy), span: sp),
            SSAInst(result: clo, kind: .makeClosure(funcName: "clo:0", env: env, onStack: false), span: sp),
            SSAInst(result: arg, kind: .constInt(5), span: sp),
            SSAInst(result: res, kind: .call(SSACall(kind: .indirect(clo), args: [arg])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        var m = module([bb])
        StackPromotion().run(&m)
        XCTAssertEqual(closureOnStack(m), true, "a locally-called closure object should promote")
        XCTAssertTrue(isHeapAlloc(m, env.id), "the env object stays heap this slice")
        XCTAssertEqual(verifySSAIR(m), [], "promoted module verifies clean")
    }

    // A closure that is *returned* escapes → the object stays heap (`onStack` unset).
    func testReturnedClosureStaysHeap() {
        let env = v(0, envTy), clo = v(1, cloTy)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: env, kind: .alloc(envTy), span: sp),
            SSAInst(result: clo, kind: .makeClosure(funcName: "clo:0", env: env, onStack: false), span: sp),
        ], terminator: SSATerm(kind: .ret(clo), span: sp))   // returned → escapes
        var m = SSAModule(functions: [SSAFunction(name: "f", params: [], returnType: cloTy,
                                                  blocks: [bb], isMutating: false, span: sp)])
        StackPromotion().run(&m)
        XCTAssertEqual(closureOnStack(m), false, "a returned closure must not promote")
    }

    // A closure passed *as a call argument* escapes (interprocedural) → stays heap.
    func testArgumentClosureStaysHeap() {
        let env = v(0, envTy), clo = v(1, cloTy), res = v(2, .int)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: env, kind: .alloc(envTy), span: sp),
            SSAInst(result: clo, kind: .makeClosure(funcName: "clo:0", env: env, onStack: false), span: sp),
            // `apply(clo)` — the closure rides in the args, which escape.
            SSAInst(result: res, kind: .call(SSACall(kind: .direct("apply"), args: [clo])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        var m = module([bb])
        StackPromotion().run(&m)
        XCTAssertEqual(closureOnStack(m), false, "a closure passed as an argument must not promote")
    }

    // An `any I` box used only for local witness dispatch is non-escaping → the box object promotes;
    // its payload object stays a heap `alloc`.
    func testDispatchedBoxPromotesObjectKeepsPayloadHeap() {
        let g = Type.named("G", .class_), anyG = Type.existential("G")
        let obj = v(0, g), box = v(1, anyG), res = v(2, .int)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: obj, kind: .alloc(g), span: sp),
            SSAInst(result: box, kind: .box(value: obj, interfaces: ["Greeter"], onStack: false), span: sp),
            SSAInst(result: res, kind: .call(SSACall(kind: .witness(receiver: box, interface: "Greeter", method: "greet"), args: [])), span: sp),
        ], terminator: SSATerm(kind: .ret(nil), span: sp))
        var m = module([bb])
        StackPromotion().run(&m)
        XCTAssertEqual(boxOnStack(m), true, "a locally-dispatched box object should promote")
        XCTAssertTrue(isHeapAlloc(m, obj.id), "the payload object stays heap this slice")
        XCTAssertEqual(verifySSAIR(m), [], "promoted module verifies clean")
    }

    // A box that is *returned* escapes → the box object stays heap.
    func testReturnedBoxStaysHeap() {
        let g = Type.named("G", .class_), anyG = Type.existential("G")
        let obj = v(0, g), box = v(1, anyG)
        let bb = SSABlock(id: 0, params: [], insts: [
            SSAInst(result: obj, kind: .alloc(g), span: sp),
            SSAInst(result: box, kind: .box(value: obj, interfaces: ["Greeter"], onStack: false), span: sp),
        ], terminator: SSATerm(kind: .ret(box), span: sp))   // returned → escapes
        var m = SSAModule(functions: [SSAFunction(name: "f", params: [], returnType: anyG,
                                                  blocks: [bb], isMutating: false, span: sp)])
        StackPromotion().run(&m)
        XCTAssertEqual(boxOnStack(m), false, "a returned box must not promote")
    }
}
