import XCTest
import frontend
import codegen

final class CodegenTests: XCTestCase {

    private func gen(_ source: String) -> String {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        var codegen = Codegen(parser.parse())
        return codegen.emit()
    }

    func testStructEmit() {
        let c = gen("struct Point { var x: Int var y: Int }")
        XCTAssertTrue(c.contains("typedef struct {"))
        XCTAssertTrue(c.contains("int64_t x;"))
        XCTAssertTrue(c.contains("int64_t y;"))
        XCTAssertTrue(c.contains("} Point;"))
    }

    func testEnumEmit() {
        let c = gen("enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }")
        XCTAssertTrue(c.contains("Shape_circle, Shape_rect"))
        XCTAssertTrue(c.contains("Shape_tag tag;"))
        XCTAssertTrue(c.contains("int64_t radius;"))
        XCTAssertTrue(c.contains("} circle;"))
        XCTAssertTrue(c.contains("int64_t w;"))
        XCTAssertTrue(c.contains("} rect;"))
    }

    func testFuncEmit() {
        let c = gen("fun add(a: Int, b: Int) -> Int { return a }")
        XCTAssertTrue(c.contains("int64_t add(int64_t a, int64_t b)"))
        XCTAssertTrue(c.contains("return a;"))
    }

    func testMainRenamedToNomuMain() {
        let c = gen("fun main() { }")
        XCTAssertTrue(c.contains("void nomu_main(void)"))
        XCTAssertTrue(c.contains("int main(void)"))
        XCTAssertTrue(c.contains("nomu_main();"))
    }

    func testStructConstruction() {
        let c = gen("""
        struct Point { var x: Int var y: Int }
        fun main() { let p = Point(x: 1, y: 2) }
        """)
        XCTAssertTrue(c.contains("Point p = (Point){ .x = 1, .y = 2 };"))
    }

    func testMemberAccess() {
        let c = gen("""
        struct Point { var x: Int var y: Int }
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
        XCTAssertTrue(c.contains("case Shape_circle:"))
        XCTAssertTrue(c.contains("int64_t r = s.payload.circle.radius;"))
        XCTAssertTrue(c.contains("case Shape_rect:"))
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
        XCTAssertTrue(c.contains("typedef struct { void* fn; void* env; } Closure;"))
        XCTAssertTrue(c.contains("static int64_t nomu_clo0(void* __envv, int64_t x)"))
        XCTAssertTrue(c.contains("int64_t base = __env->base;"))          // capture read in impl
        XCTAssertTrue(c.contains("int64_t apply(Closure f, int64_t x)"))  // closure-typed param
        XCTAssertTrue(c.contains("__e->base = base;"))                    // capture by value at site
        XCTAssertTrue(c.contains(".fn = (void*)nomu_clo0"))
    }

    func testPreambleIncluded() {
        let c = gen("fun main() { }")
        XCTAssertTrue(c.contains("#include <stdio.h>"))
        XCTAssertTrue(c.contains("ObjectHeader"))
        XCTAssertTrue(c.contains("rt_retain"))
    }

    func testClassTypedef() {
        let c = gen("class Node { var val: Int }")
        XCTAssertTrue(c.contains("ObjectHeader header;"))
        XCTAssertTrue(c.contains("int64_t val;"))
        XCTAssertTrue(c.contains("} Node;"))
    }

    func testClassConstructor() {
        let c = gen("class Node { var val: Int }")
        XCTAssertTrue(c.contains("static Node* Node_new(int64_t val)"))
        XCTAssertTrue(c.contains("self->val = val;"))
        XCTAssertTrue(c.contains("rt_alloc(sizeof(Node))"))
    }

    func testClassBumpAndLeak() {
        // Classes allocate and leak under M2: no deinit, no release, no free.
        let c = gen("class Node { var val: Int }")
        XCTAssertTrue(c.contains("static Node* Node_new(int64_t val)"))
        XCTAssertFalse(c.contains("Node_deinit"))
        XCTAssertFalse(c.contains("Node_release"))
    }

    func testActorStructAndMailbox() {
        let c = gen("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
        }
        """)
        // Message union
        XCTAssertTrue(c.contains("Counter_bump"))
        XCTAssertTrue(c.contains("Counter_msg_tag tag;"))
        XCTAssertTrue(c.contains("int64_t by;"))
        // Mailbox
        XCTAssertTrue(c.contains("MsgQueue_Counter"))
        // Actor struct with queue
        XCTAssertTrue(c.contains("ObjectHeader header;"))
        XCTAssertTrue(c.contains("int64_t count;"))
        XCTAssertTrue(c.contains("MsgQueue_Counter queue;"))
        // Thread + sync primitives in struct
        XCTAssertTrue(c.contains("pthread_t      thread;"))
        XCTAssertTrue(c.contains("pthread_mutex_t mutex;"))
        XCTAssertTrue(c.contains("pthread_cond_t  cond;"))
        // Enqueue (locked) + run loop + join
        XCTAssertTrue(c.contains("static void Counter_enqueue(Counter* self"))
        XCTAssertTrue(c.contains("pthread_mutex_lock(&self->mutex)"))
        XCTAssertTrue(c.contains("static void* Counter_run(void* arg)"))
        XCTAssertTrue(c.contains("pthread_cond_wait(&self->cond, &self->mutex)"))
        XCTAssertTrue(c.contains("static void Counter_join(Counter* self)"))
        // Constructor starts thread
        XCTAssertTrue(c.contains("static Counter* Counter_new(void)"))
        XCTAssertTrue(c.contains("self->count = 0;"))
        XCTAssertTrue(c.contains("pthread_create(&self->thread, NULL, Counter_run, self)"))
        // Deinit joins + destroys
        XCTAssertTrue(c.contains("Counter_join(self);"))
        XCTAssertTrue(c.contains("pthread_mutex_destroy(&self->mutex)"))
        XCTAssertTrue(c.contains("static void Counter_release(Counter* self)"))
    }

    func testSpawnAndSendCodegen() {
        let c = gen("""
        actor Counter {
            var count: Int = 0
            on bump(by: Int) { count += by }
        }
        fun main() {
            let c = spawn Counter()
            send c.bump(by: 10)
            join c
            print(c.count)
        }
        """)
        // spawn → Counter_new()
        XCTAssertTrue(c.contains("Counter* c = Counter_new();"))
        // send → enqueue only (no drain; actor thread handles dispatch)
        XCTAssertTrue(c.contains("Counter_enqueue(c, (Counter_msg){ .tag = Counter_bump, .payload.bump.by = 10 });"))
        XCTAssertFalse(c.contains("Counter_drain"))
        // join → Counter_join
        XCTAssertTrue(c.contains("Counter_join(c);"))
        // member access via ->
        XCTAssertTrue(c.contains("c->count"))
        // ARC release at scope end
        XCTAssertTrue(c.contains("Counter_release(c);"))
    }

    func testClassNoReleaseAtScopeEnd() {
        let c = gen("""
        class Node { var val: Int }
        fun main() { let n = Node(val: 42) }
        """)
        XCTAssertTrue(c.contains("Node* n = Node_new(42);"))
        XCTAssertFalse(c.contains("Node_release(n);"))
    }
}
