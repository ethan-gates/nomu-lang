import XCTest
import frontend
import codegen

final class CodegenTests: XCTestCase {

    private func gen(_ source: String) -> String {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        var codegen = CodegenIR(sema.check().module)
        return codegen.emit()
    }

    // Returns the CodegenIR after emit(), so tests can inspect diagnostics.
    private func compiled(_ source: String) -> CodegenIR {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        var sema = Sema(parser.parse())
        var codegen = CodegenIR(sema.check().module)
        _ = codegen.emit()
        return codegen
    }

    func testStructEmit() {
        let c = gen("struct Point {\nvar x: Int\nvar y: Int\n}")
        XCTAssertTrue(c.contains("typedef struct {"))
        XCTAssertTrue(c.contains("int64_t x;"))
        XCTAssertTrue(c.contains("int64_t y;"))
        XCTAssertTrue(c.contains("} nomu_main_Point;"))
    }

    func testEnumEmit() {
        let c = gen("enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }")
        XCTAssertTrue(c.contains("nomu_main_Shape_circle, nomu_main_Shape_rect"))
        XCTAssertTrue(c.contains("nomu_main_Shape_tag tag;"))
        XCTAssertTrue(c.contains("int64_t radius;"))
        XCTAssertTrue(c.contains("} circle;"))
        XCTAssertTrue(c.contains("int64_t w;"))
        XCTAssertTrue(c.contains("} rect;"))
    }

    func testFuncEmit() {
        let c = gen("fun add(a: Int, b: Int) -> Int { return a }")
        XCTAssertTrue(c.contains("int64_t nomu_main_add(int64_t a, int64_t b)"))
        XCTAssertTrue(c.contains("return a;"))
    }

    func testMainRenamedToNomuMain() {
        // User `main` becomes `nomu_main`; the `int main` entry that calls it lives in
        // the runtime translation unit (nomu_main_runtime.c), not the generated code (M4.13).
        let c = gen("fun main() { }")
        XCTAssertTrue(c.contains("void nomu_main(void)"))
        XCTAssertFalse(c.contains("int main(void)"))
    }

    func testStructConstruction() {
        let c = gen("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun main() { let p = Point(x: 1, y: 2) }
        """)
        XCTAssertTrue(c.contains("nomu_main_Point p = (nomu_main_Point){ .x = 1, .y = 2 };"))
    }

    func testMemberAccess() {
        let c = gen("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun main() { let p = Point(x: 3, y: 4) print(p.x) }
        """)
        XCTAssertTrue(c.contains("p.x"))
        XCTAssertTrue(c.contains("printf(\"%lld\\n\""))
    }

    func testBinaryExpr() {
        let c = gen("fun double(x: Int) -> Int { return x + x }")
        XCTAssertTrue(c.contains("return (x + x);"))
    }

    func testSwitchEmit() {
        let c = gen("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun area(s: Shape) -> Int {
            switch s {
            case .circle(let r):      return 3 * r * r
            case .rect(let w, let h): return w * h
            }
        }
        """)
        XCTAssertTrue(c.contains("switch (s.tag)"))
        XCTAssertTrue(c.contains("case nomu_main_Shape_circle:"))
        XCTAssertTrue(c.contains("int64_t r = s.payload.circle.radius;"))
        XCTAssertTrue(c.contains("case nomu_main_Shape_rect:"))
        XCTAssertTrue(c.contains("int64_t w = s.payload.rect.w;"))
        XCTAssertTrue(c.contains("int64_t h = s.payload.rect.h;"))
    }

    func testIfEmit() {
        let c = gen("""
        fun classify(n: Int) -> Int {
            if n < 0 {
                return 0
            } else if n == 0 {
                return 1
            } else {
                return 2
            }
        }
        """)
        XCTAssertTrue(c.contains("if ((n < 0)) {"))
        XCTAssertTrue(c.contains("} else {"))
        XCTAssertTrue(c.contains("if ((n == 0)) {"))   // else-if nests
        XCTAssertTrue(c.contains("return 0;"))
        XCTAssertTrue(c.contains("return 2;"))
    }

    func testClosureEmit() {
        let c = gen("""
        fun apply(f: (Int) -> Int, x: Int) -> Int { return f(x) }
        fun main() {
            let base = 100
            let add = { (x: Int) -> Int in return x + base }
            print(add(5))
            print(apply(add, 10))
        }
        """)
        XCTAssertTrue(c.contains("static int64_t nomu_clo0(void* __envv, int64_t x)"))
        XCTAssertTrue(c.contains("int64_t base = __env->base;"))          // capture read in impl
        XCTAssertTrue(c.contains("int64_t nomu_main_apply(Closure f, int64_t x)"))  // closure-typed param
        XCTAssertTrue(c.contains("__e->base = base;"))                    // capture by value at site
        XCTAssertTrue(c.contains(".fn = (void*)nomu_clo0"))
    }

    func testSpawnEmit() {
        let c = gen("""
        fun sq(n: Int) -> Int { return n * n }
        fun main() {
            spawn let a = sq(3)
            spawn let b = sq(4)
            print(a + b)
        }
        """)
        // M4: a spawn is a fiber (not a pthread-per-spawn). `SpawnHandle`/`Fiber` are
        // declared in the runtime ABI header (M4.13); generated code just uses them.
        XCTAssertTrue(c.contains("static void* nomu_spawn0(void* __envv)"))     // thunk
        XCTAssertTrue(c.contains("SpawnHandle a__h; a__h.fiber = fiber_spawn(nomu_spawn0, a__e);"))
        XCTAssertTrue(c.contains("(*(int64_t*)spawn_join(&a__h))"))             // reading joins
        XCTAssertTrue(c.contains("int64_t nomu_main_sq(int64_t n);"))                     // forward prototype
    }

    func testEarlyReturnJoins() {
        // Spawns must be joined before any return, not just at block exit.
        let c = gen("""
        fun work(n: Int) -> Int { return n * 2 }
        fun compute(a: Int, b: Int) -> Int {
            spawn let x = work(a)
            spawn let y = work(b)
            return x + y
        }
        fun main() { print(compute(3, 4)) }
        """)
        // Standalone spawn_join (followed by semicolon+newline) proves the pre-join statement
        // was emitted. It cannot appear that way inside the return expression itself.
        XCTAssertTrue(c.contains("spawn_join(&x__h);\n"), "x must be joined before return")
        XCTAssertTrue(c.contains("spawn_join(&y__h);\n"), "y must be joined before return")
    }

    func testSwitchArmSpawnJoin() {
        // A spawn defined inside a switch arm and never read must be joined at arm exit.
        let c = gen("""
        enum Box { case val(n: Int) }
        fun work(n: Int) -> Int { return n * 2 }
        fun process(b: Box) {
            switch b {
            case .val(let n):
                spawn let x = work(n)
            }
        }
        fun main() { }
        """)
        // x is never read in the arm body, so emitBlock must emit the join before break.
        XCTAssertTrue(c.contains("spawn_join(&x__h);\n"), "unread spawn in switch arm must be joined at arm exit")
    }

    func testShareableClosureAllowed() {
        // A closure whose captures are all shareable is itself shareable.
        let cg = compiled("""
        fun apply(f: (Int) -> Int, x: Int) -> Int { return f(x) }
        fun main() {
            let base = 10
            let add = { (x: Int) -> Int in return x + base }
            spawn let r = apply(add, 5)
            print(r)
        }
        """)
        XCTAssertTrue(cg.diagnostics.isEmpty, "closure with shareable captures must be allowed: \(cg.diagnostics)")
    }

    func testNonShareableClosureRejected() {
        // A closure that captures a class is not shareable.
        let cg = compiled("""
        class Box {
            var val: Int
        }
        fun apply(f: (Int) -> Int, x: Int) -> Int { return f(x) }
        fun main() {
            let b = Box(val: 10)
            let get = { (x: Int) -> Int in return b.val + x }
            spawn let r = apply(get, 5)
            print(r)
        }
        """)
        XCTAssertFalse(cg.diagnostics.isEmpty, "closure capturing a class must be rejected at a task boundary")
    }

    func testShareableValueTypeCaptureAllowed() {
        let cg = compiled("""
        struct Point {
            var x: Int
            var y: Int
        }
        fun dist(p: Point) -> Int { return p.x + p.y }
        fun main() {
            let p = Point(x: 3, y: 4)
            spawn let d = dist(p)
            print(d)
        }
        """)
        XCTAssertTrue(cg.diagnostics.isEmpty, "struct capture must be allowed: \(cg.diagnostics)")
    }

    func testNonShareableClassCaptureRejected() {
        let cg = compiled("""
        class Node {
            var val: Int
        }
        fun getVal(n: Node) -> Int { return n.val }
        fun main() {
            let n = Node(val: 42)
            spawn let v = getVal(n)
            print(v)
        }
        """)
        XCTAssertFalse(cg.diagnostics.isEmpty, "class capture across task boundary must be rejected")
        XCTAssertTrue(cg.diagnostics[0].contains("'n'"), "diagnostic must name the offending variable")
        XCTAssertTrue(cg.diagnostics[0].contains("Node"), "diagnostic must name the offending type")
    }

    func testStructMethodEmit() {
        // Value-type method: `self` by value, fields copied to locals, call passes the value.
        let c = gen("""
        struct Point {
            var x: Int
            var y: Int
            fun sum() -> Int { return x + y }
        }
        fun main() {
            let p = Point(x: 3, y: 4)
            print(p.sum())
        }
        """)
        XCTAssertTrue(c.contains("static int64_t nomu_main_Point_sum(nomu_main_Point self);"))   // prototype
        XCTAssertTrue(c.contains("static int64_t nomu_main_Point_sum(nomu_main_Point self) {"))  // definition
        XCTAssertTrue(c.contains("int64_t x = self.x;"))                     // field copied by value
        XCTAssertTrue(c.contains("return (x + y);"))
        XCTAssertTrue(c.contains("nomu_main_Point_sum(p)"))                           // call site
    }

    func testClassMethodEmit() {
        // Reference-type method: `self` is a pointer, fields read via `->`.
        let c = gen("""
        class Counter {
            var n: Int
            fun get() -> Int { return n }
        }
        fun main() {
            let c = Counter(n: 7)
            print(c.get())
        }
        """)
        XCTAssertTrue(c.contains("static int64_t nomu_main_Counter_get(nomu_main_Counter* self)"))
        XCTAssertTrue(c.contains("int64_t n = self->n;"))
        XCTAssertTrue(c.contains("nomu_main_Counter_get(c)"))
    }

    func testEnumMethodEmit() {
        // Value-type (enum) method: `self` by value; body may switch on it.
        let c = gen("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int)
            fun area() -> Int {
                switch self {
                case .circle(let r):      return 3 * r * r
                case .rect(let w, let h): return w * h
                }
            }
        }
        """)
        XCTAssertTrue(c.contains("static int64_t nomu_main_Shape_area(nomu_main_Shape self)"))
        XCTAssertTrue(c.contains("switch (self.tag)"))
    }

    func testEnumConstructionEmit() {
        let c = gen("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        fun f() -> Shape { return Shape.circle(radius: 10) }
        """)
        XCTAssertTrue(c.contains("(nomu_main_Shape){ .tag = nomu_main_Shape_circle, .payload.circle = { .radius = 10 } }"))
    }

    func testEnumConstructionNoPayloadEmit() {
        let c = gen("""
        enum Color { case red case blue }
        fun f() -> Color { return Color.blue }
        """)
        XCTAssertTrue(c.contains("(nomu_main_Color){ .tag = nomu_main_Color_blue }"))
    }

    func testMutatingStructMethodEmit() {
        // A mutating value-type method takes `self` by pointer, writes fields directly
        // through it (no copy/write-back), and the call site passes the address.
        let c = gen("""
        struct Counter {
            var count: Int
            fun bump() { count = count + 1 }
            fun get() -> Int { return count }
        }
        fun main() { var c = Counter(count: 0)  c.bump()  print(c.get()) }
        """)
        XCTAssertTrue(c.contains("static void nomu_main_Counter_bump(nomu_main_Counter* self)"))   // pointer self
        XCTAssertTrue(c.contains("self->count = (self->count + 1)"))           // direct write
        XCTAssertTrue(c.contains("static int64_t nomu_main_Counter_get(nomu_main_Counter self)"))  // read-only stays by value
        XCTAssertTrue(c.contains("nomu_main_Counter_bump(&c)"))                          // address at the call site
    }

    func testSleepBuiltin() {
        let c = gen("fun main() { let a = sleep(100) print(a) }")
        XCTAssertTrue(c.contains("rt_sleep_ms(100)"))   // M4: sleep lowers to the fiber-aware timer heap
    }

    func testIncludesRuntimeHeader() {
        // Generated code reaches the runtime through the ABI header, not an inline
        // preamble (M4.13). The old refcount hook (rt_retain) never existed here.
        let c = gen("fun main() { }")
        XCTAssertTrue(c.contains("#include \"runtime.h\""))
        XCTAssertFalse(c.contains("rt_retain"))
    }

    func testClassTypedef() {
        let c = gen("class Node {\nvar val: Int\n}")
        XCTAssertTrue(c.contains("ObjectHeader header;"))
        XCTAssertTrue(c.contains("int64_t val;"))
        XCTAssertTrue(c.contains("} nomu_main_Node;"))
    }

    func testClassConstructor() {
        let c = gen("class Node {\nvar val: Int\n}")
        XCTAssertTrue(c.contains("static nomu_main_Node* nomu_main_Node_new(int64_t val)"))
        XCTAssertTrue(c.contains("self->val = val;"))
        XCTAssertTrue(c.contains("rt_alloc(sizeof(nomu_main_Node))"))
    }

    func testClassBumpAndLeak() {
        // Classes allocate and leak under M2: no deinit, no release, no free.
        let c = gen("class Node {\nvar val: Int\n}")
        XCTAssertTrue(c.contains("static nomu_main_Node* nomu_main_Node_new(int64_t val)"))
        XCTAssertFalse(c.contains("nomu_main_Node_deinit"))
        XCTAssertFalse(c.contains("nomu_main_Node_release"))
    }

    func testActorStructAndMailbox() {
        let c = gen("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
            on getCount() -> Int { return count }
        }
        """)
        // The runtime preamble (with its condvars/threads) is now a separate
        // translation unit (M4.13), so the emitted code is the actor's own; the
        // "actor is mutex-only" checks can read the whole output directly.
        // Actor struct: fields + mutex only (no thread, no queue, no condvars)
        XCTAssertTrue(c.contains("ObjectHeader header;"))
        XCTAssertTrue(c.contains("int64_t count;"))
        XCTAssertTrue(c.contains("pthread_mutex_t mu;"))
        XCTAssertFalse(c.contains("nomu_main_Counter_run"), "no dedicated run loop in M3 actor")
        XCTAssertFalse(c.contains("pthread_cond_t"), "no condvar in the actor itself")
        // Per-handler blocking functions
        XCTAssertTrue(c.contains("static void nomu_main_Counter_bump(nomu_main_Counter* self, int64_t by)"))
        XCTAssertTrue(c.contains("static int64_t nomu_main_Counter_getCount(nomu_main_Counter* self)"))
        // Each function locks, runs body, writes back, unlocks
        XCTAssertTrue(c.contains("pthread_mutex_lock(&self->mu)"))
        XCTAssertTrue(c.contains("count += by"))
        XCTAssertTrue(c.contains("self->count = count;"))
        XCTAssertTrue(c.contains("pthread_mutex_unlock(&self->mu)"))
        // Constructor initializes mutex, no thread spawn
        XCTAssertTrue(c.contains("static nomu_main_Counter* nomu_main_Counter_new(void)"))
        XCTAssertTrue(c.contains("self->count = 0;"))
        XCTAssertTrue(c.contains("pthread_mutex_init(&self->mu, NULL)"))
        XCTAssertFalse(c.contains("pthread_create"), "actor constructor spawns no thread")
        // Deinit destroys mutex + release for refcount
        XCTAssertTrue(c.contains("pthread_mutex_destroy(&self->mu)"))
        XCTAssertTrue(c.contains("static void nomu_main_Counter_release(nomu_main_Counter* self)"))
    }

    func testActorMethodCallCodegen() {
        let c = gen("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
            on getCount() -> Int { return count }
        }
        fun main() {
            let c = Counter()
            c.bump(by: 10)
            print(c.getCount())
        }
        """)
        // Actor construction via plain call
        XCTAssertTrue(c.contains("nomu_main_Counter* c = nomu_main_Counter_new();"))
        // Void handler call
        XCTAssertTrue(c.contains("nomu_main_Counter_bump(c, 10);"))
        // Returning handler call (used inside print)
        XCTAssertTrue(c.contains("nomu_main_Counter_getCount(c)"))
        // ARC release at scope end
        XCTAssertTrue(c.contains("nomu_main_Counter_release(c);"))
    }

    func testActorHandleIsShareable() {
        // Actor handles are shareable — passing one across a spawn boundary must not produce a diagnostic.
        let cg = compiled("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
        }
        fun doWork(c: Counter, amount: Int) -> Int {
            c.bump(by: amount)
            return amount
        }
        fun main() {
            let c = Counter()
            spawn let a = doWork(c, 1)
            spawn let b = doWork(c, 2)
            print(a + b)
        }
        """)
        XCTAssertTrue(cg.diagnostics.isEmpty, "actor handle must be shareable across task boundary: \(cg.diagnostics)")
    }

    func testClassNoReleaseAtScopeEnd() {
        let c = gen("""
        class Node {
            var val: Int
        }
        fun main() { let n = Node(val: 42) }
        """)
        XCTAssertTrue(c.contains("nomu_main_Node* n = nomu_main_Node_new(42);"))
        XCTAssertFalse(c.contains("nomu_main_Node_release(n);"))
    }

    // A computed property emits accessor functions (the `.` in `area.get` z-encodes to
    // `zd`), and a read of it calls the getter rather than loading a field (M5 A1).
    func testComputedPropertyEmit() {
        let c = gen("""
        struct Rect {
            var w: Int
            var area: Int { w * w }
        }
        fun f(r: Rect) -> Int { return r.area }
        """)
        XCTAssertTrue(c.contains("nomu_main_Rect_areazdget("))       // getter defined + called
        XCTAssertFalse(c.contains("r.area"))                          // not a struct field load
    }

    // `any I`: a per-interface witness struct, a per-conformance instance, boxing that
    // wraps a value with the witness, and dispatch through the witness pointer (M5 A1.4).
    func testWitnessTableAndAnyDispatchEmit() {
        let c = gen("""
        interface Drawable {
            fun draw() -> String
            var name: String { get }
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String { return name }
        }
        fun render(d: any Drawable) -> String {
            return d.draw()
        }
        fun main() {
            let x: any Drawable = Circle(name: "c")
            print(render(x))
        }
        """)
        XCTAssertTrue(c.contains("} nomu_main_Drawable_witness;"))              // witness struct type
        XCTAssertTrue(c.contains("nomu_main_Circle_Drawable_witness = {"))      // instance for Circle
        XCTAssertTrue(c.contains(".witness = &nomu_main_Circle_Drawable_witness"))  // boxing
        XCTAssertTrue(c.contains("->draw("))                                    // dispatch via witness pointer
    }

    // A refining interface's witness table carries inherited slots, and a witness
    // instance is generated for the interface and every base it refines (M5 A1.5).
    func testRefinedWitnessIncludesInheritedSlots() {
        let c = gen("""
        interface Named {
            var name: String { get }
        }
        interface Drawable: Named {
            fun draw() -> String
        }
        struct Circle: Drawable {
            var name: String
            fun draw() -> String { return name }
        }
        fun f(d: any Drawable) -> String {
            return d.name
        }
        fun main() {
            let x: any Drawable = Circle(name: "c")
            print(f(x))
        }
        """)
        XCTAssertTrue(c.contains("(*name_get)(void*)"))                     // inherited slot in Drawable's table
        XCTAssertTrue(c.contains("nomu_main_Circle_Drawable_witness = {"))  // witness for the refiner
        XCTAssertTrue(c.contains("nomu_main_Circle_Named_witness = {"))     // and for the base
    }

    func testComputedPropertySetterMutates() {
        // The setter writes a field, so it is inferred mutating and takes `Rect* self`.
        let c = gen("""
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
        XCTAssertTrue(c.contains("nomu_main_Rect_scalezdset(nomu_main_Rect* self"))
        XCTAssertTrue(c.contains("nomu_main_Rect_scalezdset(&r, 3)"))
    }
}
