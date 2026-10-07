import XCTest
import noir
import support
@testable import interface

final class BodyInterfaceRoundTripTests: XCTestCase {
    private let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)

    // The generic template `id<T>(x: T) -> T { return x }` — the first-milestone body (task 100.5.1).
    private func idTemplate() -> NOIRFunc {
        NOIRFunc(name: "id",
                 generics: [NOIRGenericParam(name: "T", bounds: [])],
                 params: [NOIRParam(label: "x", name: "x", type: .typeParam("T"), span: zeroSpan)],
                 returnType: .typeParam("T"),
                 body: [NOIRStmt(kind: .ret(NOIRExpr(type: .typeParam("T"), span: zeroSpan, kind: .varRef("x"))),
                                 span: zeroSpan)],
                 isMutating: false, visibility: .public, span: zeroSpan)
    }

    // serialize → parse → serialize is the identity (byte-stable), and the decoded decl is the template.
    func testRoundTrip() {
        let text = serializeBIR([.funcDecl(idTemplate())])
        guard let decls = parseBIR(text) else { return XCTFail("parse failed") }
        XCTAssertEqual(decls.count, 1)
        guard case .funcDecl(let f) = decls[0] else { return XCTFail("expected a func decl") }
        XCTAssertEqual(f.name, "id")
        XCTAssertEqual(f.generics.map(\.name), ["T"])
        XCTAssertEqual(f.visibility, .public)
        XCTAssertEqual(serializeBIR(decls), text, "re-serialize is byte-identical")
    }

    // Serialization is deterministic: the same bodies yield identical bytes.
    func testDeterministic() {
        XCTAssertEqual(serializeBIR([.funcDecl(idTemplate())]), serializeBIR([.funcDecl(idTemplate())]))
    }

    // A version mismatch invalidates the file (the consumer falls back to the erased path).
    func testVersionMismatchRejected() {
        var text = serializeBIR([.funcDecl(idTemplate())])
        text = text.replacingOccurrences(of: "\"version\" : \(birFormatVersion)",
                                         with: "\"version\" : \(birFormatVersion + 1)")
        XCTAssertNil(parseBIR(text))
    }

    // `relay<T>(x: T) -> T { return echo(x) }` — a body referencing another of the module's own decls.
    private func relayTemplate() -> NOIRFunc {
        let xRef = NOIRExpr(type: .typeParam("T"), span: zeroSpan, kind: .varRef("x"))
        let callEcho = NOIRExpr(type: .typeParam("T"), span: zeroSpan,
            kind: .call(callee: NOIRExpr(type: .function(params: [.typeParam("T")], ret: .typeParam("T")),
                                         span: zeroSpan, kind: .varRef("echo")),
                        args: [NOIRArg(label: nil, value: xRef)], typeArgs: [.typeParam("T")]))
        return NOIRFunc(name: "relay",
                        generics: [NOIRGenericParam(name: "T", bounds: [])],
                        params: [NOIRParam(label: "x", name: "x", type: .typeParam("T"), span: zeroSpan)],
                        returnType: .typeParam("T"),
                        body: [NOIRStmt(kind: .ret(callEcho), span: zeroSpan)],
                        isMutating: false, visibility: .public, span: zeroSpan)
    }

    // Canonicalization (task 100.5.4): a reference to the module's own decl (`echo`) becomes origin-keyed;
    // the generic's own parameter (`x`) and type parameter (`T`) stay bare.
    func testCanonicalizeOriginKeysOwnReferences() {
        let out = canonicalizeForExport([.funcDecl(relayTemplate())], origin: "lib", ownNames: ["echo", "relay"])
        guard case .funcDecl(let f) = out[0],
              case .ret(let retExpr?) = f.body[0].kind,
              case .call(let callee, let args, _) = retExpr.kind,
              case .varRef(let calleeName) = callee.kind,
              case .varRef(let argName) = args[0].value.kind else { return XCTFail("unexpected shape") }
        XCTAssertEqual(calleeName, "lib@echo", "own-decl reference is origin-keyed")
        XCTAssertEqual(argName, "x", "the bound parameter stays bare")
    }

    // Reference collection (task 100.5.4): the body's callee is gathered (drives the shipped closure).
    func testCollectReferencedNames() {
        let refs = collectReferencedNames(.funcDecl(relayTemplate()))
        XCTAssertTrue(refs.contains("echo"), "the called function is collected")
        XCTAssertTrue(refs.contains("x"), "the argument reference is collected")
        XCTAssertTrue(collectReferencedNames(.funcDecl(idTemplate())).isSubset(of: ["x"]),
                      "a body that only returns its parameter references just that parameter")
    }

    // A reference not in the own-name set (a prelude/builtin call) stays bare.
    func testCanonicalizeLeavesForeignReferencesBare() {
        let out = canonicalizeForExport([.funcDecl(relayTemplate())], origin: "lib", ownNames: ["relay"])
        guard case .funcDecl(let f) = out[0],
              case .ret(let retExpr?) = f.body[0].kind,
              case .call(let callee, _, _) = retExpr.kind,
              case .varRef(let calleeName) = callee.kind else { return XCTFail("unexpected shape") }
        XCTAssertEqual(calleeName, "echo", "a reference outside the module's own names is left bare")
    }
}
