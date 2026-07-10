import XCTest

final class TypecheckerTests: XCTestCase {

    // Returns nil if the program passes; captures the error output if it fails.
    // We test the error cases by checking the process would exit — here we
    // call check() directly and expect it NOT to crash for valid programs.

    private func check(_ source: String) {
        var lexer = Lexer(source)
        var parser = Parser(lexer.tokenize())
        let program = parser.parse()
        var checker = Typechecker(program)
        checker.check()  // fatal on error
    }

    // MARK: - POD constraint (valid)

    func testPODStructAccepted() {
        check("""
        struct Point { var x: Int var y: Int }
        """)
    }

    func testPODEnumAccepted() {
        check("""
        enum Shape { case circle(radius: Int) case rect(w: Int, h: Int) }
        """)
    }

    func testClassAccepted() {
        check("""
        struct Point { var x: Int }
        class Buffer { var data: Point }
        """)
    }

    // MARK: - Let/var enforcement (valid)

    func testVarAssignmentAccepted() {
        check("""
        func main() { var x: Int = 1 x = 2 }
        """)
    }

    func testLetBindingReadAccepted() {
        check("""
        func main() { let x: Int = 1 let y: Int = x }
        """)
    }

    func testPatternBindingInSwitchReadAccepted() {
        check("""
        enum Shape { case circle(radius: Int) }
        func area(s: Shape) -> Int {
            switch s {
            case .circle(let r): return r
            }
        }
        """)
    }
}
