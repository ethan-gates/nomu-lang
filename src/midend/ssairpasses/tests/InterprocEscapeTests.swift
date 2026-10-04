import support
import XCTest
import ssair
import facts
@testable import ssairpasses

// Interprocedural escape summary (task 169). The oracle is at the summary/compose level: a leaf's summary
// agrees with the intraprocedural faithful escape, an unknown callee reproduces the "all arguments escape"
// floor, and a known no-escape callee lets a caller keep its argument local (the tightening win).
final class InterprocEscapeTests: XCTestCase {
    private let sp = Span(startOffset: 0, endOffset: 0, map: nil)
    private func v(_ id: Int, _ t: Type) -> SSAValue { SSAValue(id: id, type: t) }
    private let objTy = Type.named("Obj", .class_)

    private func fn(_ name: String, params: [SSAValue] = [], ret: Type = .void, _ blocks: [SSABlock]) -> SSAFunction {
        SSAFunction(name: name, params: params, returnType: ret, blocks: blocks, isMutating: false, span: sp)
    }
    private func summary(_ functions: [SSAFunction], _ name: String) -> EscapeSummary {
        computeEscapeSummaries(functions)[name]!
    }

    // A leaf that returns its parameter: faithful escapes the param (returned), so the summary does too.
    func testLeafReturnedParamEscapes() {
        let p = v(0, objTy)
        let f = fn("f", params: [p], ret: objTy, [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(p), span: sp))
        ])
        XCTAssertEqual(summary([f], "f").params, [.escapes])
        // Leaf agreement: the disposition matches the intraprocedural faithful escape restricted to params.
        XCTAssertEqual(escapingValues(f).contains(p.id), summary([f], "f").params[0] == .escapes)
    }

    // A leaf that never publishes its parameter: non-escaping in both the faithful query and the summary.
    func testLeafUnusedParamNoEscape() {
        let p = v(0, objTy)
        let f = fn("f", params: [p], [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(summary([f], "f").params, [.noEscape])
        XCTAssertEqual(escapingValues(f).contains(p.id), summary([f], "f").params[0] == .escapes)
    }

    // Conservative floor: calling a function outside the set (a dependency / builtin) escapes the argument,
    // reproducing the intraprocedural "all call arguments escape" assumption.
    func testUnknownCalleeEscapesArg() {
        let p = v(0, objTy)
        let f = fn("f", params: [p], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: nil, kind: .call(SSACall(kind: .direct("ext"), args: [p])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(summary([f], "f").params, [.escapes], "an unknown callee's argument escapes")
    }

    // A witness / indirect call is likewise conservative.
    func testIndirectCalleeEscapesArg() {
        let p = v(0, objTy), clo = v(1, .function(params: [objTy], ret: .void))
        let f = fn("f", params: [p], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: clo, kind: .makeClosure(funcName: "c", env: nil, onStack: false), span: sp),
                SSAInst(result: nil, kind: .call(SSACall(kind: .indirect(clo), args: [p])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(summary([f], "f").params, [.escapes])
    }

    // The tightening win: `f` passes its parameter only to `g`, which does not escape it, so `f`'s
    // parameter stays local — where the intraprocedural faithful query would escape it at the call.
    func testKnownNoEscapeCalleeKeepsArgLocal() {
        let gp = v(0, objTy)
        let g = fn("g", params: [gp], [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        let fp = v(0, objTy)
        let f = fn("f", params: [fp], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: nil, kind: .call(SSACall(kind: .direct("g"), args: [fp])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(summary([f, g], "g").params, [.noEscape])
        XCTAssertEqual(summary([f, g], "f").params, [.noEscape], "the call no longer forces the arg to escape")
        XCTAssertTrue(escapingValues(f).contains(fp.id), "faithful (intraprocedural) would escape it")
    }

    // A known callee that *does* escape its parameter propagates the escape to the caller's argument.
    func testKnownEscapingCalleePropagates() {
        let gp = v(0, objTy)
        let g = fn("g", params: [gp], ret: objTy, [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(gp), span: sp))  // returns param → escapes
        ])
        let fp = v(0, objTy)
        let f = fn("f", params: [fp], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: v(1, objTy), kind: .call(SSACall(kind: .direct("g"), args: [fp])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(summary([f, g], "g").params, [.escapes])
        XCTAssertEqual(summary([f, g], "f").params, [.escapes], "escape flows through the call")
    }

    // Mutual recursion (one SCC): neither function escapes its parameter, and the fixpoint converges to
    // noEscape rather than the conservative all-escape it would reach if started pessimistically.
    func testMutualRecursionConvergesNoEscape() {
        let ap = v(0, objTy)
        let a = fn("a", params: [ap], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: nil, kind: .call(SSACall(kind: .direct("b"), args: [ap])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        let bp = v(0, objTy)
        let b = fn("b", params: [bp], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: nil, kind: .call(SSACall(kind: .direct("a"), args: [bp])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        let s = computeEscapeSummaries([a, b])
        XCTAssertEqual(s["a"]!.params, [.noEscape])
        XCTAssertEqual(s["b"]!.params, [.noEscape], "the recursive cycle converges to the precise answer")
    }

    // Return provenance: a fresh local allocation returned is `fresh`; a returned parameter is `escaped`.
    func testReturnProvenance() {
        let r = v(0, objTy)
        let fresh = fn("fresh", ret: objTy, [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: r, kind: .alloc(objTy), span: sp),
            ], terminator: SSATerm(kind: .ret(r), span: sp))
        ])
        XCTAssertEqual(summary([fresh], "fresh").ret, .fresh)

        let p = v(0, objTy)
        let passthrough = fn("passthrough", params: [p], ret: objTy, [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(p), span: sp))
        ])
        XCTAssertEqual(summary([passthrough], "passthrough").ret, .escaped)
    }

    // The summaries land in the fact store's perf section, keyed by mangled name.
    func testWritesIntoFactStore() {
        let p = v(0, objTy)
        let f = fn("f", params: [p], ret: objTy, [
            SSABlock(id: 0, params: [], insts: [], terminator: SSATerm(kind: .ret(p), span: sp))
        ])
        var store = FactStore()
        writeEscapeSummaries(computeEscapeSummaries([f]), into: &store)
        XCTAssertEqual(store.facts(for: SymbolID("f"))?.perf.escape?.params, [.escapes])
    }

    // Cross-module seeding (task 164.6): a direct call to a callee outside the in-module set reads its
    // published summary from `external` instead of the conservative floor, so an imported non-escaping
    // callee lets the caller keep its argument local, and an imported escaping one propagates.
    func testExternalSummarySeedsImportedCall() {
        let p = v(0, objTy)
        let f = fn("f", params: [p], [
            SSABlock(id: 0, params: [], insts: [
                SSAInst(result: nil, kind: .call(SSACall(kind: .direct("util@ext"), args: [p])), span: sp),
            ], terminator: SSATerm(kind: .ret(nil), span: sp))
        ])
        XCTAssertEqual(computeEscapeSummaries([f])["f"]!.params, [.escapes],
                       "no summary ⇒ the imported call is conservative")
        let noEsc = ["util@ext": EscapeSummary(params: [.noEscape], ret: .fresh)]
        XCTAssertEqual(computeEscapeSummaries([f], external: noEsc)["f"]!.params, [.noEscape],
                       "a published no-escape summary keeps the arg local")
        let esc = ["util@ext": EscapeSummary(params: [.escapes], ret: .fresh)]
        XCTAssertEqual(computeEscapeSummaries([f], external: esc)["f"]!.params, [.escapes],
                       "a published escaping summary propagates")
    }

    // Re-keying to the per-definition `.nmi` convention (task 164.4.3): a method's `m:Type:method` SSA
    // name becomes `Type.method` (matching the ABI facts); a free function keeps its bare name.
    func testPerDefinitionReKeying() {
        let s = EscapeSummary(params: [.noEscape], ret: .fresh)
        let out = perDefinitionEscapeSummaries([
            "m:Point:bump": s,
            "makePoint": s,
        ])
        XCTAssertEqual(Set(out.keys), ["Point.bump", "makePoint"])
        XCTAssertEqual(out["Point.bump"], s)
        XCTAssertEqual(out["makePoint"], s)
    }
}
