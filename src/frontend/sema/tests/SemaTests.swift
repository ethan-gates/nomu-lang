import parse
import noir
import ast
import support
import XCTest
import sema

final class SemaTests: XCTestCase {

    private func sema(_ source: String) -> SemaResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        // Match the real pipeline: extensions are merged into their target before Sema (M4.12).
        let merged = mergeExtensions(parser.parse(), into: DiagnosticSink())
        var s = Sema(merged)
        return s.check()
    }

    func testInfersIntBinding() {
        let r = sema("fun f() -> Int { let x = 1 + 2 return x }")
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[0],
              case .letBinding(_, _, let value) = f.body[0].kind else { XCTFail(); return }
        XCTAssertEqual(value.type, .int)
        guard case .ret(let e?) = f.body[1].kind else { XCTFail(); return }
        XCTAssertEqual(e.type, .int)   // `x` resolves to Int
    }

    func testStructFieldAccess() {
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun f(p: Point) -> Int { return p.x }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .fieldAccess(let base, let field) = e.kind else { XCTFail(); return }
        XCTAssertEqual(field, "x")
        XCTAssertEqual(e.type, .int)
        XCTAssertEqual(base.type, .named("Point", .struct_))
    }

    func testLogicalOperatorsTypeAsBool() {
        let r = sema("fun f(a: Bool, b: Bool) -> Bool { return a && b || a }")
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[0],
              case .ret(let e?) = f.body[0].kind else { XCTFail(); return }
        XCTAssertEqual(e.type, .bool)
    }

    func testLogicalOperatorRejectsNonBool() {
        XCTAssertTrue(sema("fun f() -> Bool { return 3 && true }").diagnostics.hasErrors)
        XCTAssertTrue(sema("fun f() -> Bool { return true || 5 }").diagnostics.hasErrors)
    }

    func testStaticMethodResolvesToFreeFunc() {
        let r = sema("""
        struct Point {
            var x: Int
            static fun origin() -> Point { return Point(x: 0) }
        }
        fun main() -> Int {
            let p = Point.origin()
            return p.x
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        // The static method is emitted as a free function named `Point.origin`.
        let emitted = r.module.decls.contains { if case .funcDecl(let fn) = $0 { return fn.name == "Point.origin" }; return false }
        XCTAssertTrue(emitted)
        // The call site lowers to a direct call of that function, typed as the enclosing type.
        guard case .funcDecl(let main)? = r.module.decls.first(where: { if case .funcDecl(let fn) = $0 { return fn.name == "main" }; return false }),
              case .letBinding(_, _, let value) = main.body[0].kind,
              case .call(let callee, _, _) = value.kind,
              case .varRef(let n) = callee.kind else { XCTFail(); return }
        XCTAssertEqual(n, "Point.origin")
        XCTAssertEqual(value.type, .named("Point", .struct_))
    }

    func testStaticMethodBodyCannotUseSelf() {
        let r = sema("""
        struct P {
            var x: Int
            static fun bad() -> Int { return self.x }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testInstanceMethodNotCallableOnType() {
        let r = sema("""
        struct P {
            var x: Int
            fun get() -> Int { return x }
        }
        fun main() -> Int { return P.get() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testStaticMethodNotCallableOnValue() {
        let r = sema("""
        struct P {
            var x: Int
            static fun origin() -> P { return P(x: 0) }
        }
        fun main() -> Int {
            let p = P(x: 1)
            return p.origin().x
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testConstruction() {
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun f() -> Point { return Point(x: 1, y: 2) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .construct(let typeName, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(typeName, "Point")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(e.type, .named("Point", .struct_))
    }

    func testMethodCallTypes() {
        // `s.method()` resolves to a methodCall and takes the method's return type.
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
            fun sum() -> Int { return x + y }
        }
        fun f(p: Point) -> Int { return p.sum() }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .methodCall(let recv, let method, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "sum")
        XCTAssertEqual(args.count, 0)
        XCTAssertEqual(e.type, .int)
        XCTAssertEqual(recv.type, .named("Point", .struct_))
    }

    func testMethodBodySeesFieldsAndSelf() {
        // Inside a method, fields resolve by bare name and `self` is in scope.
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
            fun scaled(by: Int) -> Int { return self.x + y * by }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertEqual(s.methods.count, 1)
        XCTAssertEqual(s.methods[0].returnType, .int)
    }

    func testMissingMethodDiagnostic() {
        let r = sema("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun f(p: Point) -> Int { return p.nope() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testEnumConstructionQualified() {
        let r = sema("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun f() -> Shape { return Shape.circle(radius: 10) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .enumInit(let t, let c, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(t, "Shape")
        XCTAssertEqual(c, "circle")
        XCTAssertEqual(args.count, 1)
        XCTAssertEqual(e.type, .named("Shape", .enum_))
    }

    func testEnumConstructionLeadingDot() {
        // Enum inferred from the return type.
        let r = sema("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun f() -> Shape { return .rect(w: 2, h: 3) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .enumInit(_, let c, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(c, "rect")
        XCTAssertEqual(e.type, .named("Shape", .enum_))
    }

    func testLeadingDotNoContextDiagnostic() {
        let r = sema("""
        enum Color { case red case blue }
        fun f() { let c = .red }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testLetFieldMutabilityOnIR() {
        let r = sema("""
        struct P {
            let x: Int
            var y: Int
        }
        """)
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertFalse(s.fields[0].isMutable)
        XCTAssertTrue(s.fields[1].isMutable)
    }

    func testAssignToLetFieldDiagnostic() {
        let r = sema("""
        struct P {
            let x: Int
            var y: Int
        }
        fun f(p: P) { p.x = 5 }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testMutatingMethodInferred() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
            fun get() -> Int { return count }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertTrue(s.methods.first { $0.name == "bump" }!.isMutating)
        XCTAssertFalse(s.methods.first { $0.name == "get" }!.isMutating)
    }

    func testTransitiveMutatingInferred() {
        // A method that calls a mutating method on `self` is itself mutating.
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
            fun twice() { self.bump()  self.bump() }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .structDecl(let s) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertTrue(s.methods.first { $0.name == "twice" }!.isMutating)
    }

    func testMutatingCallOnLetRejected() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
        }
        fun f() { let c = C(count: 0)  c.bump() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testMutatingCallOnVarAccepted() {
        let r = sema("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
        }
        fun f() { var c = C(count: 0)  c.bump() }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testReassignSelfRejected() {
        let r = sema("""
        struct C {
            var count: Int
            fun replace(o: C) { self = o }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testUndefinedNameDiagnostic() {
        let r = sema("fun f() -> Int { return zzz }")
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testUnknownTypeDiagnostic() {
        let r = sema("fun f(x: Nope) -> Int { return 0 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    // MARK: - Computed properties (M5 A1)

    func testComputedPropertyReadIsGetterCall() {
        let r = sema("""
        struct Rect {
            var w: Int
            var area: Int { w * w }
        }
        fun f(r: Rect) -> Int { return r.area }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .methodCall(_, let method, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "area.get")
        XCTAssertEqual(args.count, 0)
        XCTAssertEqual(e.type, .int)
    }

    func testComputedPropertyWriteIsSetterCall() {
        let r = sema("""
        struct Rect {
            var w: Int
            var scale: Int {
                get { w }
                set(s) { w = s }
            }
        }
        fun f() {
            var r = Rect(w: 2)
            r.scale = 3
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .exprStmt(let e) = f.body[1].kind,
              case .methodCall(_, let method, let args) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "scale.set")
        XCTAssertEqual(args.count, 1)
    }

    func testAssignReadOnlyComputedPropertyErrors() {
        let r = sema("""
        struct Rect {
            var w: Int
            var area: Int { w * w }
        }
        fun f() {
            var r = Rect(w: 2)
            r.area = 9
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testSetComputedPropertyOnLetReceiverErrors() {
        let r = sema("""
        struct Rect {
            var w: Int
            var scale: Int {
                get { w }
                set(s) { w = s }
            }
        }
        fun f() {
            let r = Rect(w: 2)
            r.scale = 3
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testEnumComputedProperty() {
        let r = sema("""
        enum Shape {
            case dot
            case square(side: Int)
            var area: Int {
                get {
                    switch self {
                    case .dot: return 0
                    case .square(let s): return s * s
                    }
                }
            }
        }
        fun f(s: Shape) -> Int { return s.area }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let f) = r.module.decls[1],
              case .ret(let e?) = f.body[0].kind,
              case .methodCall(_, let method, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(method, "area.get")
        XCTAssertEqual(e.type, .int)
    }

    // MARK: - Interfaces (M5 A1.2)

    func testInterfaceDefaultTypechecksAndEmitsNoIR() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
            fun describe() -> String { return concat(self.name, self.draw()) }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertTrue(r.module.decls.isEmpty)   // interfaces are abstract — no codegen
    }

    func testBareInterfaceTypeRejected() {
        let r = sema("""
        interface Shape {
            fun area() -> Int
        }
        fun f(s: Shape) -> Int { return s.area() }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testInterfaceDefaultCallingUnknownRequirementRejected() {
        let r = sema("""
        interface I {
            fun a() -> Int
            fun b() -> Int { return self.nope() }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    // MARK: - Conformance checking (M5 A1.3)

    func testValidConformance() {
        // A default requirement may be omitted; a method + stored field satisfy the rest.
        let r = sema("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
            fun describe() -> String { return self.draw() }
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String { return name }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testMissingRequirementRejected() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
        }
        struct Bad: Drawable {
            var r: Int
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testWrongSignatureRejected() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Bad: Drawable {
            fun draw() -> Int { return 0 }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testGetSetRequirementNeedsSettableMember() {
        let r = sema("""
        interface Counter {
            var count: Int { get set }
        }
        struct Bad: Counter {
            let count: Int
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testConformingToNonInterfaceRejected() {
        let r = sema("""
        struct Helper {
            var x: Int
        }
        struct Bad: Helper {
            var x: Int
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testActorConformanceRejected() {
        let r = sema("""
        interface Pingable {
            fun ping() -> Int
        }
        actor Server: Pingable {
            var n: Int = 0
            on ping() -> Int { return n }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testComputedPropertySatisfiesRequirement() {
        let r = sema("""
        interface Sized {
            var area: Int { get }
            var scale: Int { get set }
        }
        struct Rect: Sized {
            var w: Int
            var area: Int { w * w }
            var scale: Int {
                get { w }
                set(s) { w = s }
            }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    // MARK: - Existentials `any I` (M5 A1.4)

    func testAnyBindingInsertsBox() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var r: Int
            fun draw() -> String { return "O" }
        }
        fun f() {
            let d: any Drawable = Circle(r: 1)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[1],
              case .letBinding(_, _, let value) = fn.body[0].kind,
              case .box(_, let ifaces) = value.kind else { XCTFail(); return }
        XCTAssertEqual(ifaces, ["Drawable"])
        XCTAssertEqual(value.type, .existential("Drawable"))
    }

    func testDispatchThroughAnyKeepsExistentialReceiver() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        fun f(d: any Drawable) -> String {
            return d.draw()
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[0],
              case .ret(let e?) = fn.body[0].kind,
              case .methodCall(let recv, let m, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(m, "draw")
        XCTAssertEqual(recv.type, .existential("Drawable"))
    }

    func testBoxingNonConformerRejected() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Plain {
            var x: Int
        }
        fun f() {
            let d: any Drawable = Plain(x: 1)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testUnknownInterfaceInAnyRejected() {
        let r = sema("fun f(d: any Nope) -> Int { return 0 }")
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    // MARK: - Refinement (M5 A1.5)

    func testRefinementRequiresInheritedRequirements() {
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        struct Bad: Drawable {
            fun draw() -> String { return "x" }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)   // missing inherited `name`
    }

    func testInheritedRequirementDispatchesThroughAny() {
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        fun f(d: any Drawable) -> String {
            return d.name
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[0],
              case .ret(let e?) = fn.body[0].kind,
              case .methodCall(let recv, let m, _) = e.kind else { XCTFail(); return }
        XCTAssertEqual(m, "name.get")
        XCTAssertEqual(recv.type, .existential("Drawable"))
    }

    func testConcreteRefinerBoxesAsBaseInterface() {
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String { return "O" }
        }
        fun f() {
            let n: any Named = Circle(name: "c")
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[1],
              case .letBinding(_, _, let value) = fn.body[0].kind,
              case .box(_, let ifaces) = value.kind else { XCTFail(); return }
        XCTAssertEqual(ifaces, ["Named"])
    }

    func testIncomparableSiblingDefaultsCancelToMandatory() {
        let r = sema("""
        interface A {
            fun tag() -> String { return "A" }
        }
        interface B {
            fun tag() -> String { return "B" }
        }
        interface C: A, B {
        }
        struct T: C {
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)   // tag cancels to mandatory; T omits it
    }

    func testRefinementCycleRejected() {
        let r = sema("""
        interface A: B {
        }
        interface B: A {
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    // MARK: - `&` composition (M5 A1.5b)

    func testCompositionIsCanonicalAndOrderIndependent() {
        // `any B & A` resolves to the same canonical composition as `any A & B`.
        let r = sema("""
        interface A {
            fun a() -> Int
        }
        interface B {
            fun b() -> Int
        }
        fun f(x: any B & A) -> Int { return x.a() }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertEqual(fn.params[0].type, .composition(["A", "B"]))
    }

    func testCompositionCollapsesToRefiner() {
        // `any Drawable & Named` where Drawable: Named collapses to `any Drawable`.
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        fun f(x: any Drawable & Named) -> String { return x.draw() }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertEqual(fn.params[0].type, .existential("Drawable"))
    }

    func testCompositionRequiresConformanceToAll() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        interface Named {
            var name: String { get }
        }
        struct OnlyDraw: Drawable {
            fun draw() -> String { return "x" }
        }
        fun f() {
            let x: any Drawable & Named = OnlyDraw()
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)   // OnlyDraw isn't Named
    }

    // MARK: - `Self`-type requirements → constraint-only (M5 A2)

    func testSelfRequirementConformanceTypechecks() {
        // `fun clone() -> Self` is satisfied by `fun clone() -> Point` on the conformer:
        // `Self` binds to the concrete type during conformance matching.
        let r = sema("""
        interface Cloneable {
            fun clone() -> Self
        }
        struct Point: Cloneable {
            var x: Int
            fun clone() -> Point { return Point(x: x) }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testSelfRequirementWrongReturnRejected() {
        // A `clone` that returns some other type does not satisfy `-> Self`.
        let r = sema("""
        interface Cloneable {
            fun clone() -> Self
        }
        struct Point: Cloneable {
            var x: Int
            fun clone() -> Int { return x }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testSelfParamRequirementConformanceTypechecks() {
        // Contravariant `Self` (parameter position) still substitutes to the conformer type.
        let r = sema("""
        interface Combinable {
            fun combined(with: Self) -> Self
        }
        struct Vec: Combinable {
            var x: Int
            fun combined(with: Vec) -> Vec { return Vec(x: x) }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testContravariantSelfRejectedAsAny() {
        // A *contravariant* `Self` (parameter position) stays constraint-only after 5.6 — the box
        // can't guarantee two `Self` values share a concrete type.
        let r = sema("""
        interface Combinable {
            fun combined(with: Self) -> Self
        }
        fun f(c: any Combinable) -> Int { return 0 }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("constraint-only"), r.diagnostics.render())
    }

    func testCovariantSelfAcceptedAsAny() {
        // A *covariant* `Self` (return position) is erasure-safe: `any Cloneable` is legal and a
        // witness table is emitted, with `clone()`'s slot erased to `any I` (M5 5.6).
        let r = sema("""
        interface Cloneable {
            fun clone() -> Self
        }
        struct Point: Cloneable {
            var x: Int
            fun clone() -> Point { return Point(x: x) }
        }
        fun f(c: any Cloneable) -> any Cloneable { return c.clone() }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
        XCTAssertTrue(r.module.interfaces.contains { $0.name == "Cloneable" })       // witness layout emitted
        XCTAssertTrue(r.module.conformances.contains { $0.interfaceName == "Cloneable" })
    }

    func testContravariantSelfPropagatesThroughRefinement() {
        // `Mergeable: Combinable` inherits the (contravariant) constraint-only property, so
        // `any Mergeable` is rejected even though Mergeable itself doesn't mention `Self`.
        let r = sema("""
        interface Combinable {
            fun combined(with: Self) -> Self
        }
        interface Mergeable: Combinable {
            fun tag() -> String
        }
        fun f(d: any Mergeable) -> Int { return 0 }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("constraint-only"), r.diagnostics.render())
    }

    func testContravariantSelfEmitsNoWitness() {
        // A contravariant-`Self` interface has no `any I` form, so no witness table / conformance
        // instance is emitted. Conformance is still checked for correctness.
        let r = sema("""
        interface Combinable {
            fun combined(with: Self) -> Self
        }
        struct Tally: Combinable {
            var n: Int
            fun combined(with: Tally) -> Tally { return Tally(n: n + with.n) }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertFalse(r.module.interfaces.contains { $0.name == "Combinable" })     // no witness-table layout
        XCTAssertFalse(r.module.conformances.contains { $0.interfaceName == "Combinable" })
    }

    func testSelfOutsideInterfaceRejected() {
        // `Self` is contextual to interface requirements; a concrete signature can't use it.
        let r = sema("""
        struct Point {
            var x: Int
            fun twin() -> Self { return Point(x: x) }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testContravariantRefinerKeepsAnyableBaseWitness() {
        // `Combinable: Named` is constraint-only (contravariant Self), but its base `Named` is not.
        // A conformer of Combinable still conforms to `any Named` — the base witness is emitted per
        // interface, so `any Named = tally` is legal (the mixed case).
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Combinable: Named {
            fun combined(with: Self) -> Self
        }
        struct Tally: Combinable {
            var name: String
            var n: Int
            fun combined(with: Tally) -> Tally { return Tally(name: name, n: n + with.n) }
        }
        fun f(n: any Named) -> String { return n.name }
        fun main() {
            let t = Tally(name: "t", n: 1)
            print(f(t))
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        // A Named witness exists; no Combinable witness (it's constraint-only).
        XCTAssertTrue(r.module.conformances.contains { $0.typeName == "Tally" && $0.interfaceName == "Named" })
        XCTAssertFalse(r.module.conformances.contains { $0.interfaceName == "Combinable" })
    }

    func testSelfFreeInterfaceStillAnyUsable() {
        // A `Self`-free interface keeps its `any I` form — the constraint-only gate is scoped
        // to interfaces that actually mention `Self`.
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        fun f(d: any Drawable) -> String { return d.draw() }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls[0] else { XCTFail(); return }
        XCTAssertEqual(fn.params[0].type, .existential("Drawable"))
    }

    // MARK: - `some I` opaque return types (M5 A3)

    func testOpaqueReturnTypechecksAndRecordsUnderlying() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var radius: Int
            fun draw() -> String { return "O" }
        }
        fun makeShape() -> some Drawable {
            return Circle(radius: 1)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        // The hidden underlying is recorded for the owner keyed by the function.
        XCTAssertEqual(r.module.opaqueUnderlyings["fn:makeShape"], .named("Circle", .struct_))
    }

    func testOpaqueTwoDifferentConcreteReturnsRejected() {
        let r = sema("""
        interface D {
            fun draw() -> String
        }
        struct A: D {
            fun draw() -> String { return "a" }
        }
        struct B: D {
            fun draw() -> String { return "b" }
        }
        fun pick(flag: Bool) -> some D {
            if flag {
                return A()
            }
            return B()
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("one concrete type"), r.diagnostics.render())
    }

    func testOpaqueNonConformerRejected() {
        let r = sema("""
        interface D {
            fun draw() -> String
        }
        struct Plain {
            var x: Int
        }
        fun f() -> some D {
            return Plain(x: 1)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("does not conform"), r.diagnostics.render())
    }

    func testSomeInParameterPositionRejected() {
        // Parameter-position `some` is deferred (it's the `<T: I>` sugar); only return types
        // and let/var bindings supply an opaque owner.
        let r = sema("""
        interface D {
            fun draw() -> String
        }
        fun f(x: some D) -> String {
            return x.draw()
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("only allowed as a return type"), r.diagnostics.render())
    }

    func testOpaqueRequirementCallDispatchesStatically() {
        // A requirement call on a `some I` value keeps the opaque receiver in the IR; codegen
        // devirtualizes it to a direct call on the underlying. Here we check the typed result.
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var radius: Int
            fun draw() -> String { return "O" }
        }
        fun makeShape() -> some Drawable {
            return Circle(radius: 1)
        }
        fun main() {
            let s = makeShape()
            print(s.draw())
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testOpaqueConstraintOnlyInterfaceUsableAsSome() {
        // A `Self`-mentioning interface is rejected as `any I` but allowed as `some I`; calling
        // its `-> Self` requirement yields the concrete underlying (the A3 decision).
        let r = sema("""
        interface Cloneable {
            fun clone() -> Self
            fun tag() -> String
        }
        struct Point: Cloneable {
            var x: Int
            fun clone() -> Point { return Point(x: x) }
            fun tag() -> String { return "p" }
        }
        fun makePoint() -> some Cloneable {
            return Point(x: 5)
        }
        fun main() {
            let p = makePoint()
            let q = p.clone()
            print(q.x)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertEqual(r.module.opaqueUnderlyings["fn:makePoint"], .named("Point", .struct_))
    }

    func testOpaqueComposition() {
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Named, Drawable {
            var name: String
            fun draw() -> String { return "O" }
        }
        fun make() -> some Drawable & Named {
            return Circle(name: "c")
        }
        fun main() {
            let s = make()
            print(s.draw())
            print(s.name)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testLocalOpaqueBindingAnnotation() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var radius: Int
            fun draw() -> String { return "O" }
        }
        fun main() {
            let d: some Drawable = Circle(radius: 2)
            print(d.draw())
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertEqual(r.module.opaqueUnderlyings["let:1"], .named("Circle", .struct_))
    }

    func testOpaquePerFunctionIdentityDistinct() {
        // Two functions returning `some D` produce distinct opaque types (per-function
        // identity) even with the same underlying — they carry different owners.
        let r = sema("""
        interface D {
            fun draw() -> String
        }
        struct Circle: D {
            var radius: Int
            fun draw() -> String { return "O" }
        }
        fun a() -> some D { return Circle(radius: 1) }
        fun b() -> some D { return Circle(radius: 2) }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        let ta = Type.opaque(interfaces: ["D"], owner: "fn:a")
        let tb = Type.opaque(interfaces: ["D"], owner: "fn:b")
        XCTAssertNotEqual(ta, tb)   // distinct identities despite the same underlying
    }

    // MARK: - Phase A completion follow-ups (5.0.8)

    func testPropertySetThroughAny() {
        // `d.count = v` on an existential dispatches to the witness set slot (5.1.1).
        let r = sema("""
        interface Counter {
            var count: Int { get set }
        }
        class Box: Counter {
            var count: Int
        }
        fun bump(c: any Counter) {
            c.count = 99
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testSetReadOnlyPropertyThroughAnyRejected() {
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        struct P: Named {
            var name: String
        }
        fun f(n: any Named) {
            n.name = "x"
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("read-only"), r.diagnostics.render())
    }

    func testExtensionComputedPropertySatisfiesRequirement() {
        // A computed property in a conformance extension satisfies a property requirement (5.1.1).
        let r = sema("""
        interface Named {
            var label: String { get }
        }
        struct Point {
            var x: Int
        }
        extension Point: Named {
            var label: String { "pt" }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testDefaultBarePropertyAndWrite() {
        // Default bodies may read a requirement by bare name and write a settable one (5.1.1).
        let r = sema("""
        interface Greeter {
            var name: String { get }
            var count: Int { get set }
            fun greet() -> String {
                return concat("hi ", name)
            }
            fun reset() {
                self.count = 0
            }
        }
        class Person: Greeter {
            var name: String
            var count: Int
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testOpaqueForwardReferencePropertyRead() {
        // A property read on a `some I` value whose producer is declared later type-checks (5.1.3).
        let r = sema("""
        fun main() {
            let s = makeShape()
            print(s.name)
        }
        interface Drawable {
            fun draw() -> String
            var name: String { get }
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String {
                return "O"
            }
        }
        fun makeShape() -> some Drawable {
            return Circle(name: "c")
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testOpaqueFromOpaqueLookThrough() {
        // A `some I` may be produced by returning another opaque of the same interface (5.1.3).
        let r = sema("""
        interface D {
            fun draw() -> String
        }
        struct Circle: D {
            var r: Int
            fun draw() -> String {
                return "O"
            }
        }
        fun makeShape() -> some D {
            return Circle(r: 1)
        }
        fun wrap() -> some D {
            return makeShape()
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertEqual(r.module.opaqueUnderlyings["fn:wrap"], .named("Circle", .struct_))
    }

    func testExistentialUpcastToBase() {
        // `any B` widens to `any A` when B refines A (5.1.1).
        let r = sema("""
        interface Named {
            var name: String { get }
        }
        interface Greeter: Named {
            fun greet() -> String
        }
        struct Person: Greeter {
            var name: String
            fun greet() -> String {
                return name
            }
        }
        fun f() {
            let g: any Greeter = Person(name: "Ada")
            let n: any Named = g
            print(n.name)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testExistentialWidenToNonBaseRejected() {
        let r = sema("""
        interface A {
            fun a() -> Int
        }
        interface B {
            fun b() -> Int
        }
        struct T: A, B {
            fun a() -> Int {
                return 1
            }
            fun b() -> Int {
                return 2
            }
        }
        fun f() {
            let x: any A = T()
            let y: any B = x
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)   // A does not refine B
    }

    // MARK: - Generics: parsing + type model (5.2.1)

    func testGenericTypeReferenceResolves() {
        // `Box<Int>` in a signature resolves to `.generic`; the generic decl now lowers to one
        // uniform shape carrying its type parameter, a `T` field held as `.typeParam` (5.2.3).
        let r = sema("""
        struct Box<T> {
            var value: T
        }
        fun unwrap(b: Box<Int>) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        XCTAssertEqual(r.module.decls.count, 2)   // generic `Box` is lowered (5.2.3), plus `unwrap`
        guard case .structDecl(let box) = r.module.decls[0] else { XCTFail("expected Box"); return }
        XCTAssertEqual(box.generics.map(\.name), ["T"])
        XCTAssertEqual(box.fields.first?.type, .typeParam("T"))
        guard case .funcDecl(let fn) = r.module.decls[1] else { XCTFail("expected unwrap"); return }
        XCTAssertEqual(fn.params[0].type, .generic(base: "Box", args: [.int]))
    }

    // MARK: - Generic types: construction, match, bounds (5.2.3)

    func testGenericStructConstructionInfersTypeArg() {
        // `Box(value: 42)` infers `T = Int` from the field, yielding `Box<Int>` (5.2.3).
        let r = sema("""
        struct Box<T> {
            let value: T
        }
        fun f() {
            let b = Box(value: 42)
            print(b.value)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn)? = r.module.decls.first(where: {
            if case .funcDecl(let f) = $0 { return f.name == "f" }; return false
        }) else { XCTFail("expected f"); return }
        guard case .letBinding(_, _, let value) = fn.body.first?.kind else { XCTFail("expected let"); return }
        XCTAssertEqual(value.type, .generic(base: "Box", args: [.int]))
    }

    func testGenericEnumConstructionInfersTypeArg() {
        // `.some(value: 7)` infers `T = Int`; the annotation fixes the enum (5.2.3).
        let r = sema("""
        enum Option<T> {
            case some(value: T)
            case none
        }
        fun f() {
            let o: Option<Int> = .some(value: 7)
            switch o {
            case .some(let v): print(v)
            case .none:        print(0)
            }
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn)? = r.module.decls.first(where: {
            if case .funcDecl(let f) = $0 { return f.name == "f" }; return false
        }) else { XCTFail("expected f"); return }
        guard case .letBinding(_, _, let value) = fn.body.first?.kind else { XCTFail("expected let"); return }
        XCTAssertEqual(value.type, .generic(base: "Option", args: [.int]))
    }

    func testGenericConstructionBoundViolationRejected() {
        // A non-conforming type argument is a clean local error (5.2.3 exit).
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Wrapper<T: Drawable> {
            let item: T
        }
        struct Plain {
            let n: Int
        }
        fun f() {
            let w = Wrapper(item: Plain(n: 1))
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("does not conform to 'Drawable'"), r.diagnostics.render())
    }

    func testGenericClosureParameterAccepted() {
        // A type parameter inside a closure parameter is bridged by a reabstraction thunk (5.2.3),
        // so a generic higher-order call type-checks clean and the result reads back concretely.
        let r = sema("""
        fun apply<T, U>(x: T, f: (T) -> U) -> U {
            return f(x)
        }
        fun caller() {
            let y = apply(5, {(n: Int) -> Int in return n * 2})
            print(y)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn)? = r.module.decls.first(where: {
            if case .funcDecl(let f) = $0 { return f.name == "caller" }; return false
        }) else { XCTFail("expected caller"); return }
        guard case .letBinding(_, _, let value) = fn.body.first?.kind else { XCTFail("expected let"); return }
        XCTAssertEqual(value.type, .int)   // apply<Int,Int> returns Int
    }

    func testGenericContainerReturnPositionAccepted() {
        // Building and returning a generic container over the type parameter is sound — the boxed
        // value moves out uniformly (no value witness). Only receiving one as a param is deferred.
        let r = sema("""
        struct Box<T> {
            let value: T
        }
        fun wrap<T>(x: T) -> Box<T> {
            return Box(value: x)
        }
        fun caller() {
            print(wrap(5).value)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testGenericTypeParameterUnderGenericAccepted() {
        // A type parameter nested in a generic-type parameter (`Option<T>`) is now accepted:
        // whole-program monomorphization (M5 5.4) specializes the function to a concrete copy,
        // so the abstract body never reaches codegen (the old value-witness miscompile is gone).
        let r = sema("""
        enum Option<T> {
            case some(value: T)
            case none
        }
        fun unwrap<T>(o: Option<T>, fallback: T) -> T {
            switch o {
            case .some(let v): return v
            case .none: return fallback
            }
        }
        fun f() {
            let a: Option<Int> = .some(value: 5)
            print(unwrap(a, 0))
        }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testGenericMethodsRejected() {
        // Instance methods on a generic type are deferred past 5.2.3.
        let r = sema("""
        struct Box<T> {
            let value: T
            fun get() -> T {
                return value
            }
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("aren't supported yet"), r.diagnostics.render())
    }

    func testGenericBindingTypeMismatchRejected() {
        // `Box<Int>` and `Box<String>` are distinct types — one C layout, but a binding
        // annotation mismatch is caught in Sema, not left to silently pass (5.2.3).
        let r = sema("""
        struct Box<T> {
            let value: T
        }
        fun f() {
            let b: Box<String> = Box(value: 5)
            print(b.value)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("Box<Int>") && r.diagnostics.render().contains("Box<String>"), r.diagnostics.render())
    }

    func testGenericReturnTypeMismatchRejected() {
        let r = sema("""
        struct Box<T> {
            let value: T
        }
        fun make() -> Box<String> {
            return Box(value: 5)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("cannot return"), r.diagnostics.render())
    }

    func testGenericMutableFieldWriteAccepted() {
        // A `var` `T` field can be written; the assignment re-boxes the slot (5.2.3).
        let r = sema("""
        struct Cell<T> {
            var value: T
        }
        fun f() {
            var c = Cell(value: 1)
            c.value = 99
            print(c.value)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testGenericLetFieldWriteRejected() {
        let r = sema("""
        struct Box<T> {
            let value: T
        }
        fun f() {
            var b = Box(value: 1)
            b.value = 2
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("'let' field"), r.diagnostics.render())
    }

    func testGenericArityMismatchRejected() {
        let r = sema("""
        struct Box<T> {
            var value: T
        }
        fun f(b: Box<Int, Bool>) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("expects 1 type argument"), r.diagnostics.render())
    }

    func testNonGenericTypeWithArgsRejected() {
        let r = sema("""
        struct Plain {
            var x: Int
        }
        fun f(p: Plain<Int>) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("is not generic"), r.diagnostics.render())
    }

    func testUnknownGenericRejected() {
        let r = sema("""
        fun f(x: Nope<Int>) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
    }

    func testGenericBoundMustBeInterface() {
        let r = sema("""
        struct Helper {
            var x: Int
        }
        fun f<T: Helper>(x: T) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("must name an interface"), r.diagnostics.render())
    }

    func testGenericFunctionSignatureResolves() {
        // A generic function's signature type-checks with its type params in scope, and it is
        // lowered (witness-passing, 5.2.2) carrying its generic parameters.
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        fun describe<T: Drawable>(x: T) -> String {
            return "x"
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
        guard case .funcDecl(let fn) = r.module.decls.first else { XCTFail(); return }
        XCTAssertEqual(fn.generics.map(\.name), ["T"])
        XCTAssertEqual(fn.generics.first?.bounds, ["Drawable"])
    }

    func testTypeParamOutsideGenericScopeRejected() {
        let r = sema("""
        fun f(x: T) -> Int {
            return 0
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)   // T isn't a declared type or a parameter here
    }

    // MARK: - Generic functions: witness-passing + inference (5.2.2)

    func testGenericFunctionCallTypechecks() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String {
                return "O"
            }
        }
        fun describe<T: Drawable>(x: T) -> String {
            return concat(x.name, x.draw())
        }
        fun main() {
            print(describe(Circle(name: "c")))
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testGenericBoundViolationRejected() {
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Plain {
            var x: Int
        }
        fun describe<T: Drawable>(x: T) -> String {
            return x.draw()
        }
        fun main() {
            print(describe(Plain(x: 1)))
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("does not conform to 'Drawable'"), r.diagnostics.render())
    }

    func testGenericConflictingInferenceRejected() {
        let r = sema("""
        struct A {
            var x: Int
        }
        struct B {
            var y: Int
        }
        fun pair<T>(a: T, b: T) -> Int {
            return 0
        }
        fun main() {
            print(pair(A(x: 1), B(y: 2)))
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("conflicting types"), r.diagnostics.render())
    }

    func testGenericReturnTypeParamSubstitutes() {
        // `echo<T>(x: T) -> T` — the call's result is the inferred concrete type, so `.radius`
        // (a Circle-only field) resolves.
        let r = sema("""
        interface Drawable {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var radius: Int
            fun draw() -> String {
                return "O"
            }
        }
        fun echo<T: Drawable>(x: T) -> T {
            return x
        }
        fun main() {
            let c = echo(Circle(radius: 5))
            print(c.radius)
        }
        """)
        XCTAssertTrue(r.diagnostics.isEmpty, r.diagnostics.render())
    }

    func testSelfBoundAccepted() {
        // A `Self`-mentioning interface is now usable as a generic bound (M5 5.6) — monomorphization
        // specializes the body to a concrete `T`, so `-> Self` is a direct call with no witness.
        // Both covariant (Cloneable) and contravariant (Combinable) bounds are allowed.
        let r = sema("""
        interface Cloneable {
            fun clone() -> Self
        }
        interface Combinable {
            fun combined(with: Self) -> Self
        }
        struct P: Cloneable {
            var x: Int
            fun clone() -> P { return P(x: x) }
        }
        struct Q: Combinable {
            var n: Int
            fun combined(with: Q) -> Q { return Q(n: n + with.n) }
        }
        fun dup<T: Cloneable>(v: T) -> T { return v.clone() }
        fun add<T: Combinable>(a: T, b: T) -> T { return a.combined(with: b) }
        fun main() {
            print(dup(P(x: 1)).x)
            print(add(Q(n: 2), Q(n: 3)).n)
        }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    // M5 5.3.2 — the `shared` bound.

    func testSharedBoundAcceptsShareableArg() {
        let r = sema("""
        struct Pair {
            let a: Int
            let b: Int
        }
        fun onTask<shared T>(x: T) -> T {
            return x
        }
        fun main() {
            let n = onTask(1)
            let p = onTask(Pair(a: 1, b: 2))
            print(n)
            print(p.a)
        }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testSharedBoundRejectsNonShareableArg() {
        let r = sema("""
        class Counter {
            var n: Int
        }
        fun onTask<shared T>(x: T) -> T {
            return x
        }
        fun main() {
            let c = Counter(n: 0)
            let x = onTask(c)
            print(x.n)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("is not shareable"), r.diagnostics.render())
    }

    func testSharedBoundAcceptsDeeplyImmutableClass() {
        let r = sema("""
        class Config {
            let host: String
            let port: Int
        }
        fun onTask<shared T>(x: T) -> T {
            return x
        }
        fun main() {
            let c = Config(host: "h", port: 1)
            let x = onTask(c)
            print(x.host)
        }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testSharedParamForwardsToSharedBound() {
        // A `shared T` in scope is itself shareable, so it satisfies another `shared` bound.
        let r = sema("""
        fun inner<shared U>(y: U) -> U {
            return y
        }
        fun outer<shared T>(x: T) -> T {
            return inner(x)
        }
        """)
        XCTAssertFalse(r.diagnostics.hasErrors, r.diagnostics.render())
    }

    func testNonSharedParamRejectedBySharedBound() {
        // A plain `<T>` is not known shareable, so it can't discharge a `shared` bound.
        let r = sema("""
        fun inner<shared U>(y: U) -> U {
            return y
        }
        fun outer<T>(x: T) -> T {
            return inner(x)
        }
        """)
        XCTAssertTrue(r.diagnostics.hasErrors)
        XCTAssertTrue(r.diagnostics.render().contains("is not shareable"), r.diagnostics.render())
    }
}
