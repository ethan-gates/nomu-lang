import XCTest
import frontend

final class SemaTests: XCTestCase {

    private func sema(_ source: String) -> SemaResult {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        var s = Sema(parser.parse())
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
}
