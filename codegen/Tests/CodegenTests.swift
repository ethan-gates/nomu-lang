import XCTest
import frontend

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
        let c = gen("func add(a: Int, b: Int) -> Int { return a }")
        XCTAssertTrue(c.contains("int64_t add(int64_t a, int64_t b)"))
        XCTAssertTrue(c.contains("return a;"))
    }

    func testMainRenamedToNomuMain() {
        let c = gen("func main() { }")
        XCTAssertTrue(c.contains("void nomu_main(void)"))
        XCTAssertTrue(c.contains("int main(void)"))
        XCTAssertTrue(c.contains("nomu_main();"))
    }

    func testStructConstruction() {
        let c = gen("""
        struct Point { var x: Int var y: Int }
        func main() { let p = Point(x: 1, y: 2) }
        """)
        XCTAssertTrue(c.contains("Point p = (Point){ .x = 1, .y = 2 };"))
    }

    func testMemberAccess() {
        let c = gen("""
        struct Point { var x: Int var y: Int }
        func main() { let p = Point(x: 3, y: 4) print(p.x) }
        """)
        XCTAssertTrue(c.contains("p.x"))
        XCTAssertTrue(c.contains("printf(\"%lld\\n\""))
    }

    func testBinaryExpr() {
        let c = gen("func double(x: Int) -> Int { return x + x }")
        XCTAssertTrue(c.contains("return (x + x);"))
    }

    func testSwitchEmit() {
        let c = gen("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        func area(s: Shape) -> Int {
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

    func testPreambleIncluded() {
        let c = gen("func main() { }")
        XCTAssertTrue(c.contains("#include <stdio.h>"))
        XCTAssertTrue(c.contains("ObjectHeader"))
        XCTAssertTrue(c.contains("rt_retain"))
    }
}
