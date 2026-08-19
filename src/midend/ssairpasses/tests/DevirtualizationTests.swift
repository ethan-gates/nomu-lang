import support
import XCTest
import ssair
@testable import ssairpasses

// Devirtualization (M7 · 7.4): a `.witness` call on a locally-constructed box rewrites to a `.direct`
// call on the concrete conformer. Devirt is sound only where the self ABI matches — a reference self
// is always a pointer, a non-mutating value self is the value, but a *mutating* value method needs an
// address, so it is skipped. An absent target or a non-local receiver is a safe no-op.
final class DevirtualizationTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }

    // A concrete method target present in the module (so the pass can find it + read `isMutating`).
    private func target(_ name: String, mutating: Bool, self selfTy: Type) -> SSAFunction {
        SSAFunction(name: name, params: [v(100, selfTy)], returnType: .int,
                    blocks: [SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))],
                    isMutating: mutating, span: sp)
    }

    // The call kind of the instruction defining value id `id`, after running the pass.
    private func callKind(_ m: SSAModule, _ id: Int) -> SSACallKind? {
        for f in m.functions { for b in f.blocks { for i in b.insts where i.result?.id == id {
            if case .call(let c) = i.kind { return c.kind }
        } } }
        return nil
    }

    // Build a caller `f` that boxes `payload` and dispatches `method` on it via `.witness`, returning
    // the module (caller + the given target functions). The witness-call result is id 2.
    private func boxAndDispatch(payload: SSAValue, interfaces: [String], method: String,
                                targets: [SSAFunction]) -> SSAModule {
        let box = v(1, .existential("X"))
        let res = v(2, .int)
        let caller = SSAFunction(name: "f", params: [], returnType: .void, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: payload, kind: .alloc(payload.type), span: sp),
                SSAInst(result: box, kind: .box(value: payload, interfaces: interfaces, onStack: false), span: sp),
                SSAInst(result: res, kind: .call(SSACall(kind: .witness(receiver: box, interface: interfaces[0], method: method), args: [])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ], isMutating: false, span: sp)
        return SSAModule(functions: [caller] + targets)
    }

    // A class conformer → devirt (self is always the object pointer).
    func testClassBoxDevirtualizes() {
        let c = Type.named("C", .class_)
        var m = boxAndDispatch(payload: v(0, c), interfaces: ["I"], method: "foo",
                               targets: [target("m:C:foo", mutating: false, self: c)])
        Devirtualize().run(&m)
        guard case .direct(let name) = callKind(m, 2) else { return XCTFail("\(String(describing: callKind(m, 2)))") }
        XCTAssertEqual(name, "m:C:foo")
    }

    // A non-mutating value conformer → devirt (self is the value).
    func testNonMutatingValueBoxDevirtualizes() {
        let s = Type.named("S", .struct_)
        var m = boxAndDispatch(payload: v(0, s), interfaces: ["I"], method: "bar",
                               targets: [target("m:S:bar", mutating: false, self: s)])
        Devirtualize().run(&m)
        guard case .direct(let name) = callKind(m, 2) else { return XCTFail() }
        XCTAssertEqual(name, "m:S:bar")
    }

    // A *mutating* value conformer → NOT devirt (a mutating value method needs the receiver's address).
    func testMutatingValueBoxStaysWitness() {
        let s = Type.named("S", .struct_)
        var m = boxAndDispatch(payload: v(0, s), interfaces: ["I"], method: "baz",
                               targets: [target("m:S:baz", mutating: true, self: s)])
        Devirtualize().run(&m)
        guard case .witness = callKind(m, 2) else { return XCTFail("mutating value method must stay witness") }
    }

    // The target method isn't in the module → safe no-op (stays witness).
    func testAbsentTargetStaysWitness() {
        let c = Type.named("C", .class_)
        var m = boxAndDispatch(payload: v(0, c), interfaces: ["I"], method: "missing", targets: [])
        Devirtualize().run(&m)
        guard case .witness = callKind(m, 2) else { return XCTFail("absent target must stay witness") }
    }

    // The witness receiver is a function parameter, not a local box → not devirtable.
    func testNonLocalReceiverStaysWitness() {
        let anyI = Type.existential("X"), recv = v(0, anyI), res = v(1, .int)
        let caller = SSAFunction(name: "f", params: [recv], returnType: .void, blocks: [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: res, kind: .call(SSACall(kind: .witness(receiver: recv, interface: "I", method: "foo"), args: [])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ], isMutating: false, span: sp)
        var m = SSAModule(functions: [caller, target("m:C:foo", mutating: false, self: Type.named("C", .class_))])
        Devirtualize().run(&m)
        guard case .witness = callKind(m, 1) else { return XCTFail("a param receiver is not a local box") }
    }
}
