import XCTest
@testable import config
import cfgresolver

final class FileTests: XCTestCase {
    private func read(_ text: String) throws(ConfigErrors) -> ConfigFile {
        try ConfigFile(Array(text.utf8), path: "cfg.yaml")
    }

    private func codes(_ text: String) -> [ConfigError.Code] {
        do {
            _ = try read(text)
            XCTFail("expected errors")
            return []
        } catch {
            return error.codes
        }
    }

    private func spelled(_ f: ConfigFile) -> [String] {
        f.declarations.map { d in ([d.setting] + d.configs).joined(separator: " ") }
    }

    func testSectionsJoinIntoNames() throws {
        let f = try read("""
            oven:
              temp: 200
              mode: broil
            dough:
              flours:
                - rye
                - spelt

            """)
        XCTAssertEqual(spelled(f), ["oven.temp", "oven.mode", "dough.flours"])
        XCTAssertEqual(f.declarations[0].value, .integer(200))
        XCTAssertEqual(f.declarations[2].value, .list([.string("rye"), .string("spelt")]))
        XCTAssertEqual(f.declarations[1].origin, .file(path: "cfg.yaml", line: 3, column: 3))
    }

    // A qualifier on a section applies to every key inside it; one on a key applies to that key.
    func testQualifierOnSectionOrKey() throws {
        let f = try read("""
            oven release:
              temp: 220
              mode: convect
            dough:
              proof test release: false

            """)
        XCTAssertEqual(spelled(f), ["oven.temp release", "oven.mode release", "dough.proof test release"])
    }

    func testQualifierOnSectionAndKeyIsAnError() {
        XCTAssertEqual(codes("oven release:\n  temp debug: 1\n"), [.qualifierTwice])
    }

    func testMalformedKeys() {
        XCTAssertEqual(codes("oven.temp: 1\n"), [.malformedKey])
        XCTAssertEqual(codes("oven  release:\n  temp: 1\n"), [.malformedKey])
        XCTAssertEqual(codes("Oven:\n  temp: 1\n"), [.malformedKey])
        XCTAssertEqual(codes("oven:\n  temp Release: 1\n"), [.malformedKey])
    }

    func testDotsGetANestingFix() {
        do {
            _ = try read("oven.temp: 1\n")
        } catch {
            XCTAssertEqual(error.errors.first?.fix, "nest it: `oven:` then `temp:`")
        }
    }

    func testConfigs() throws {
        let f = try read("configs:\n  production: release\n  gc_fast: null\n")
        XCTAssertEqual(f.configs.map(\.name), ["production", "gc_fast"])
        XCTAssertEqual(f.configs.map(\.parent), ["release", nil])
        XCTAssertNotNil(f.configsOrigin)
        XCTAssertEqual(codes("configs release:\n  x: null\n"), [.malformedSection])
        XCTAssertEqual(codes("configs:\n  x: 3\n"), [.malformedSection])
        XCTAssertEqual(codes("configs: 3\n"), [.malformedSection])
    }

    func testExternals() throws {
        let f = try read("""
            externals:
              all:
                oven:
                  mode: bake
              json:
                dough release:
                  proof: false

            """)
        XCTAssertEqual(f.externals.map(\.target), ["all", "json"])
        XCTAssertEqual(f.externals[1].declarations.map(\.setting), ["dough.proof"])
        XCTAssertEqual(f.externals[1].declarations.map(\.configs), [["release"]])
        XCTAssertEqual(codes("externals:\n  all:\n    configs:\n      x: null\n"), [.malformedSection])
        XCTAssertEqual(codes("externals:\n  all: 3\n"), [.malformedSection])
    }

    func testYAMLErrorsCarryTheirPlace() {
        do {
            _ = try read("oven:\n  temp: True\n")
            XCTFail("expected errors")
        } catch {
            XCTAssertEqual(error.codes, [.syntax])
            XCTAssertEqual(error.errors.first?.origin, .file(path: "cfg.yaml", line: 2, column: 9))
        }
    }

    func testAMappingInAListIsAnError() {
        XCTAssertEqual(codes("dough:\n  flours:\n    - a: 1\n"), [.invalidValue])
    }

    func testSelectionSplitsCommas() throws {
        XCTAssertEqual(try selection(["release,gc_fast", "rbe"]).map(\.name), ["release", "gc_fast", "rbe"])
        XCTAssertEqual(try selection(["release,gc_fast"]).map(\.origin), [.commandLine("-c release,gc_fast"), .commandLine("-c release,gc_fast")])
        XCTAssertThrowsError(try selection(["release,"]))
        XCTAssertThrowsError(try selection([""]))
    }

    // The builtin dump reads back as the builtin layer.
    func testBuiltinFileReadsBack() throws {
        let schema = Bakery.schema
        let f = try ConfigFile(Array(schema.builtinFile().utf8), path: "builtin.yaml")
        XCTAssertEqual(f.configs.map(\.name), schema.configs.map(\.name))
        XCTAssertEqual(f.configs.map(\.parent), schema.configs.map(\.parent))
        let read = f.declarations.map { d in ([d.setting] + d.configs, try? schema[d.setting]!.type.read(d.value).get()) }
        let builtin = schema.builtinLayer.declarations.map { d in ([d.setting] + d.configs, try? schema[d.setting]!.type.read(d.value).get()) }
        XCTAssertEqual(read.map(\.0), builtin.map(\.0))
        XCTAssertEqual(read.map(\.1), builtin.map(\.1))
    }
}
