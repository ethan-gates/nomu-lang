import parse
import noir
import facts
import support
import XCTest
import sema

// Fact collection into the shared store (task 164.1). The store mirrors Sema's inferred mutating-ness,
// keyed by the per-definition `Type.method` convention. These assert the writer populates the right keys
// with the right values; the store is behavior-preserving (nothing reads it yet), so the end-to-end suite
// is the behavior-preserving check.
final class FactCollectionTests: XCTestCase {
    private func noirModule(_ source: String) -> NOIRModule {
        var lexer = Lexer(source, file: "t.nomu")
        var parser = Parser(lexer.tokenize())
        let merged = mergeExtensions(parser.parse(), into: DiagnosticSink())
        var s = Sema(merged)
        return s.check().module
    }

    func testMutatingFactsCollectedByMethodKey() {
        let store = collectFacts(noirModule("""
        struct C {
            var count: Int
            fun bump() { count = count + 1 }
            fun get() -> Int { return count }
            fun twice() { self.bump()  self.bump() }
        }
        """))
        XCTAssertEqual(store.facts(for: SymbolID("C.bump"))?.abi.mutating, true)
        XCTAssertEqual(store.facts(for: SymbolID("C.get"))?.abi.mutating, false)
        XCTAssertEqual(store.facts(for: SymbolID("C.twice"))?.abi.mutating, true, "transitive mutation recorded")
    }

    func testMethodsOfDistinctTypesKeyedSeparately() {
        let store = collectFacts(noirModule("""
        struct A { var n: Int  fun set() { n = 1 } }
        struct B { var n: Int  fun read() -> Int { return n } }
        """))
        XCTAssertEqual(store.facts(for: SymbolID("A.set"))?.abi.mutating, true)
        XCTAssertEqual(store.facts(for: SymbolID("B.read"))?.abi.mutating, false)
        XCTAssertNil(store.facts(for: SymbolID("A.read")), "keys do not collide across types")
    }
}
