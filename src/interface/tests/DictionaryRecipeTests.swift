import XCTest
import noir
import support
@testable import interface

// Recipes (task 251.2.1): what a generic's dictionary must hold, read from a monomorphized module's decls.
final class DictionaryRecipeTests: XCTestCase {
    private let span = Span(startOffset: -1, endOffset: -1, map: nil)
    private let t = Type.typeParam("T")

    private func expr(_ type: Type, _ kind: ExprKind) -> NOIRExpr { NOIRExpr(type: type, span: span, kind: kind) }
    private func stmt(_ e: NOIRExpr) -> NOIRStmt { NOIRStmt(kind: .exprStmt(e), span: span) }
    private func field(_ name: String, _ type: Type) -> NOIRField {
        NOIRField(name: name, type: type, isMutable: true, span: span)
    }
    private func generic(_ name: String, _ body: [NOIRStmt]) -> NOIRDecl {
        .funcDecl(NOIRFunc(name: name, generics: [NOIRGenericParam(name: "T", bounds: [])], params: [],
                           returnType: .void, body: body, isMutating: false, span: span))
    }
    private func genericClass(_ name: String, _ fields: [NOIRField]) -> NOIRDecl {
        .classDecl(NOIRClass(name: name, generics: [NOIRGenericParam(name: "T", bounds: [])], fields: fields,
                             methods: [], span: span))
    }

    // Allocating `Node<T>` needs its descriptor, and the layouts it reaches come along, a private struct included.
    func testObjectNeedCarriesLayouts() {
        let node = Type.generic(base: "Node", args: [t])
        let inner = NOIRStruct(name: "Inner", generics: [], fields: [field("n", .int)], methods: [], span: span)
        let decls: [NOIRDecl] = [
            genericClass("Node", [field("value", t), field("inner", .named("Inner", .struct_))]),
            .structDecl(inner),
            generic("make", [stmt(expr(node, .construct(typeName: "Node", args: [])))]),
        ]
        let r = dictionaryRecipes(decls)
        XCTAssertEqual(r?.recipes, [DictionaryRecipe(symbol: "make", generics: ["T"], bounds: [[]], needs: [.object(node)])])
        XCTAssertEqual(r?.layouts.map(\.name), ["Inner", "Node"])
    }

    // A generic struct is laid out from witnesses, so it needs nothing, but the recipe still exists: a caller builds the
    // words every dictionary starts with from it. A generic class needs its descriptor even at concrete arguments,
    // since the compiled-once body allocates it.
    func testStructNeedsNothingConcreteClassDoes() {
        let box = Type.generic(base: "Box", args: [t])
        let concrete = Type.generic(base: "Node", args: [.int])
        let decls: [NOIRDecl] = [
            genericClass("Node", [field("value", t)]),
            .structDecl(NOIRStruct(name: "Box", generics: [NOIRGenericParam(name: "T", bounds: [])],
                                   fields: [field("v", t)], methods: [], span: span)),
            generic("f", [stmt(expr(box, .construct(typeName: "Box", args: [])))]),
            generic("g", [stmt(expr(concrete, .construct(typeName: "Node", args: [])))]),
        ]
        XCTAssertEqual(dictionaryRecipes(decls)?.recipes, [
            DictionaryRecipe(symbol: "f", generics: ["T"], bounds: [[]], needs: []),
            DictionaryRecipe(symbol: "g", generics: ["T"], bounds: [[]], needs: [.object(concrete)])])
    }

    // A generic callee is recorded at each distinct instantiation, concrete ones too, since the body passes on a word of
    // its own dictionary for every call, and a call of anything else is not. Arrays record their buffer.
    func testCalleesAndArraysDeduplicate() {
        let opt = Type.generic(base: "Option", args: [t])
        let callee = expr(.void, .varRef("keep"))
        let call = expr(.void, .call(callee: callee, args: [], typeArgs: [opt]))
        let concrete = expr(.void, .call(callee: callee, args: [], typeArgs: [.int]))
        let builtin = expr(.void, .call(callee: expr(.void, .varRef("__builtin")), args: [], typeArgs: [t]))
        let array = expr(.array(t), .arrayLit(elements: []))
        let r = dictionaryRecipes([generic("keep", []), generic("f", [stmt(call), stmt(call), stmt(concrete), stmt(builtin), stmt(array)])])
        XCTAssertEqual(r?.recipes.first { $0.symbol == "f" }?.needs,
                       [.callee(symbol: "keep", typeArgs: [opt]), .callee(symbol: "keep", typeArgs: [.int]),
                        .arrayBuffer(element: t)])
    }

    // A module's own names take its origin, and a name another module owns stays as it is.
    func testQualifiedNames() {
        let foreign = "other/place@Opt"
        let own = Type.generic(base: "Node", args: [.generic(base: foreign, args: [t])])
        let r = DictionaryRecipes(
            recipes: [DictionaryRecipe(symbol: "f", generics: ["T"], bounds: [[]],
                                       needs: [.object(own), .callee(symbol: "f", typeArgs: [t]),
                                               .callee(symbol: "m:Node:get", typeArgs: [t])])],
            layouts: [DictionaryLayout(name: "Node", generics: ["T"], kind: .class_, fields: [[t]], fieldNames: [["v"]])])
        let q = r.qualified(origin: "my/mod")
        XCTAssertEqual(q.recipes[0].symbol, "my/mod@f")
        XCTAssertEqual(q.layouts[0].name, "my/mod@Node")
        XCTAssertEqual(q.recipes[0].needs, [
            .object(.generic(base: "my/mod@Node", args: [.generic(base: foreign, args: [t])])),
            .callee(symbol: "my/mod@f", typeArgs: [t]),
            .callee(symbol: "m:my/mod@Node:get", typeArgs: [t])])
    }

    // A nested use inside a branch and a closure counts, and the recipes survive the `.nmi`.
    func testNestedBodiesAndRoundTrip() throws {
        let node = Type.generic(base: "Node", args: [t])
        let made = expr(node, .construct(typeName: "Node", args: []))
        let closure = expr(.function(params: [], ret: .void), .closure(params: [], body: [stmt(made)]))
        let cond = expr(.bool, .boolLit(true))
        let body = [NOIRStmt(kind: .ifStmt(cond: cond, then: [stmt(closure)], else: nil), span: span)]
        let r = try XCTUnwrap(dictionaryRecipes([genericClass("Node", [field("value", t)]), generic("f", body)]))
        XCTAssertEqual(r.recipes.first?.needs, [.object(node)])
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(DictionaryRecipes.self, from: data), r)
    }

    // Calling a function value whose type mentions `T` needs its call adapter; a call of a named function, whose type
    // never mentions `T` without type arguments, needs none.
    func testFunctionValueCallNeedsAdapter() {
        let fnType = Type.function(params: [t], ret: .int)
        let viaValue = expr(.int, .call(callee: expr(fnType, .varRef("f")), args: [], typeArgs: []))
        let concrete = expr(.int, .call(callee: expr(.function(params: [.int], ret: .int), .varRef("g")), args: [], typeArgs: []))
        let r = dictionaryRecipes([generic("h", [stmt(viaValue), stmt(viaValue), stmt(concrete)])])
        XCTAssertEqual(r?.recipes.first?.needs, [.callValue(fnType)])
    }

    // An append records its buffer, since it may grow the array: `append` reaches the scan as a call of
    // `__arrayAppend`, so a body with no array literal records it too.
    func testAppendNeedsBuffer() {
        let xs = expr(.array(t), .varRef("xs"))
        let append = expr(.void, .call(callee: expr(.void, .varRef("__arrayAppend")),
                                       args: [NOIRArg(label: nil, value: xs), NOIRArg(label: nil, value: expr(t, .varRef("x")))],
                                       typeArgs: []))
        let r = dictionaryRecipes([generic("f", [stmt(append), stmt(append)])])
        XCTAssertEqual(r?.recipes.first?.needs, [.arrayBuffer(element: t)])
    }

    // Closure conversion's needs append to a recipe, after those the body scan placed, each once, with its layouts.
    func testAddingAppendsAfterScannedNeeds() {
        let node = Type.generic(base: "Node", args: [t])
        let env = Type.generic(base: "clo.0.env", args: [t])
        let entry = Type.function(params: [], ret: t)
        let r = DictionaryRecipes(
            recipes: [DictionaryRecipe(symbol: "f", generics: ["T"], bounds: [[]], needs: [.object(node)]),
                      DictionaryRecipe(symbol: "g", generics: ["T"], bounds: [[]], needs: [])],
            layouts: [DictionaryLayout(name: "Node", generics: ["T"], kind: .class_, fields: [[t]], fieldNames: [["v"]])])
        let envLayout = DictionaryLayout(name: "clo.0.env", generics: ["T"], kind: .class_, fields: [[.rawPtr, t]],
                                         fieldNames: [["$dictionary", "x"]], fromTypeParameter: [[false, true]])
        let a = r.adding([("f", .object(env)), ("f", .closureEntry(entry)), ("f", .object(env)), ("f", .object(node))],
                         layouts: [envLayout])
        XCTAssertEqual(a.recipes[0].needs, [.object(node), .object(env), .closureEntry(entry)])
        XCTAssertEqual(a.recipes[1].needs, [])
        XCTAssertEqual(a.layouts.map(\.name), ["Node", "clo.0.env"])
    }
}
