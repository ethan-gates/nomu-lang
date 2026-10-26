import XCTest
@testable import config
import cfgresolver

final class ConfigsTests: XCTestCase {
    private let builtin = Bakery.schema.builtinLayer

    private func at(_ line: Int) -> Origin { .file(path: "cfg.yaml", line: line, column: 1) }

    private func codes(_ layers: [Layer]) -> [ConfigError.Code] {
        do {
            _ = try ConfigTable(layers)
            XCTFail("expected errors")
            return []
        } catch {
            return error.codes
        }
    }

    private func select(_ names: String...) -> [(name: String, origin: Origin)] {
        names.map { ($0, .commandLine("-c \($0)")) }
    }

    func testFlattenFollowsChainsInSelectionOrder() throws {
        let table = try ConfigTable([builtin, Layer(.entryWorkspace, configs: [
            ConfigDeclaration("rbe", parent: "debug", origin: at(2)),
            ConfigDeclaration("production", parent: "release", origin: at(3)),
            ConfigDeclaration("gc_fast", parent: nil, origin: at(4)),
        ])])
        XCTAssertEqual(try table.flatten(select("rbe", "debug")), ["debug", "rbe"])
        XCTAssertEqual(try table.flatten(select("test")), ["debug", "test"])
        XCTAssertEqual(try table.flatten(select("production")), ["release", "production"])
        XCTAssertEqual(try table.flatten(select("gc_fast", "release")), ["gc_fast", "release"])
        XCTAssertEqual(try table.flatten(select("release", "gc_fast")), ["release", "gc_fast"])
        XCTAssertEqual(try table.flatten(select("debug", "test", "debug")), ["debug", "test"])
    }

    func testSelectingAnUndeclaredConfig() throws {
        let table = try ConfigTable([builtin])
        do {
            _ = try table.flatten(select("relese"))
            XCTFail("expected errors")
        } catch {
            XCTAssertEqual(error.codes, [.unknownConfig])
            XCTAssertEqual(error.rendered, "error: -c relese: `relese` is not a declared config; did you mean `release`?")
        }
    }

    func testRedeclaringAName() {
        XCTAssertEqual(codes([builtin, Layer(.entryWorkspace, configs: [ConfigDeclaration("debug", parent: nil, origin: at(1))])]),
                       [.duplicateConfig])
    }

    func testUndeclaredParent() {
        XCTAssertEqual(codes([builtin, Layer(.entryWorkspace, configs: [ConfigDeclaration("rbe", parent: "dbug", origin: at(1))])]),
                       [.unknownConfig])
    }

    func testCycleReportedOnce() {
        let errors: ConfigErrors
        do {
            _ = try ConfigTable([builtin, Layer(.entryWorkspace, configs: [
                ConfigDeclaration("b", parent: "c", origin: at(1)),
                ConfigDeclaration("c", parent: "a", origin: at(2)),
                ConfigDeclaration("a", parent: "b", origin: at(3)),
                ConfigDeclaration("d", parent: "a", origin: at(4)),
            ])])
            XCTFail("expected errors")
            return
        } catch {
            errors = error
        }
        XCTAssertEqual(errors.codes, [.configCycle])
        XCTAssertEqual(errors.errors.first?.message, "config parents form a cycle: a -> b -> c -> a")
    }

    func testConfigsOnlyInBuiltinAndWorkspace() {
        XCTAssertEqual(codes([builtin, Layer(.package, configs: [ConfigDeclaration("x", parent: nil, origin: at(1))])]),
                       [.configInWrongLayer])
        XCTAssertEqual(codes([builtin, Layer(.module, configs: [ConfigDeclaration("x", parent: nil, origin: at(1))])]),
                       [.configInWrongLayer])
    }
}
