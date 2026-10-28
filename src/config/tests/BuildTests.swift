import XCTest
@testable import config
import cfgresolver

final class BuildTests: XCTestCase {
    private let schema = Bakery.schema

    private func file(_ text: String, _ path: String) -> ConfigFile {
        try! ConfigFile(Array(text.utf8), path: path)
    }

    // An entry workspace `acme.app` with a package `net` and a module `net/tls`; an external `acme.json`
    // pinned as `json`; a language workspace `nomu.std`.
    private func build(_ select: [String] = [], entry: String? = nil, json: String? = nil) throws(ConfigErrors) -> BuildConfiguration {
        let entryFile = file(entry ?? """
            configs:
              production: release
            oven:
              temp production: 230
              mode: convect
            dough:
              flours:
                - rye
            pantry:
              capacity production: 256M
            externals:
              all:
                oven:
                  mode: bake
              json:
                dough:
                  proof: false

            """, "app/cfg.yaml")
        let workspaces = [
            WorkspaceFiles("acme.app", role: .entry, workspace: entryFile,
                           packages: ["net": file("oven:\n  temp: 200\n  temp release: 210\n", "app/net/cfg.yaml")],
                           modules: ["net/tls": file("dough:\n  flours:\n    - spelt\n", "app/net/tls/cfg.yaml")]),
            WorkspaceFiles("acme.json", role: .external, workspace: file(json ?? "oven:\n  temp release: 190\n", "json/cfg.yaml")),
            WorkspaceFiles("nomu.std", role: .language),
        ]
        return try BuildConfiguration(schema, workspaces: workspaces, pins: ["json": "acme.json"],
                                      selection: try selection(select), defaultSelection: ["debug"], externalDefault: ["release"])
    }

    private func codes(_ select: [String] = [], entry: String? = nil, json: String? = nil) -> [ConfigError.Code] {
        do {
            _ = try build(select, entry: entry, json: json)
            XCTFail("expected errors")
            return []
        } catch {
            return error.codes
        }
    }

    private let cli = ModulePlace("acme.app", package: "cli", module: "cli")
    private let http = ModulePlace("acme.app", package: "net", module: "net/http")
    private let tls = ModulePlace("acme.app", package: "net", module: "net/tls")
    private let parse = ModulePlace("acme.json", package: "json", module: "json/parse")
    private let collections = ModulePlace("nomu.std", package: "std", module: "std/collections")

    func testActiveLists() throws {
        let b = try build(["production"])
        XCTAssertEqual(b.entryActive, ["release", "production"])
        XCTAssertEqual(b.externalActive, ["release"])
        let d = try build()
        XCTAssertEqual(d.entryActive, ["debug"])
        XCTAssertEqual(d.externalActive, ["release"])
        XCTAssertEqual(try build(["debug"]).externalActive, ["debug"])
    }

    func testEntryStacks() throws {
        let b = try build(["production"])
        XCTAssertEqual(b.configuration(for: cli)["oven.temp"], .int(230))
        // The package layer beats the workspace layer before qualifiers are compared.
        XCTAssertEqual(b.configuration(for: http)["oven.temp"], .int(210))
        XCTAssertEqual(b.configuration(for: tls)["dough.flours"], .list([.string("wheat"), .string("rye"), .string("spelt")]))
        XCTAssertEqual(b.configuration(for: http)["dough.flours"], .list([.string("wheat"), .string("rye")]))
    }

    func testExternalStacks() throws {
        let b = try build(["production"])
        let c = b.configuration(for: parse)
        XCTAssertEqual(c.active, ["release"])
        XCTAssertEqual(c["oven.temp"], .int(190))
        XCTAssertEqual(c["oven.mode"], .choice("bake"))
        XCTAssertEqual(c["dough.proof"], .bool(false))
        XCTAssertEqual(b.stack(for: parse).map(\.layer.kind), [.builtin, .workspace, .externals, .externals])
        XCTAssertEqual(b.stack(for: parse).map(\.layer.name), ["builtin", "acme.json", "all", "json"])
    }

    // The language workspace takes no `externals:` blocks.
    func testLanguageStack() throws {
        let b = try build(["production"])
        let c = b.configuration(for: collections)
        XCTAssertEqual(c["oven.temp"], .int(220))
        XCTAssertEqual(c["oven.mode"], .choice("bake"))
        XCTAssertEqual(b.stack(for: collections).map(\.layer.kind), [.builtin, .workspace])
    }

    // A block's qualifier names the entry's configs and matches the entry's full list.
    func testExternalsBlockQualifiersAreTheEntrys() throws {
        let b = try build(["production"], entry: """
            configs:
              production: release
            externals:
              all:
                oven:
                  temp production: 150

            """)
        XCTAssertEqual(b.configuration(for: parse)["oven.temp"], .int(150))
        XCTAssertEqual(try build(["release"], entry: """
            configs:
              production: release
            externals:
              all:
                oven:
                  temp production: 150

            """).configuration(for: parse)["oven.temp"], .int(190))
    }

    func testAliasBeatsAll() throws {
        let b = try build([], entry: """
            externals:
              all:
                oven:
                  temp: 100
              json:
                oven:
                  temp: 120

            """)
        XCTAssertEqual(b.configuration(for: parse)["oven.temp"], .int(120))
    }

    // Program settings come from the entry workspace, for every module.
    func testProgramSettingsAreTheBuilds() throws {
        let b = try build(["production"])
        XCTAssertEqual(b.configuration(for: cli)["pantry.capacity"], .size(256 << 20))
        XCTAssertEqual(b.configuration(for: parse)["pantry.capacity"], .size(256 << 20))
        XCTAssertEqual(b.configuration(for: collections)["pantry.capacity"], .size(256 << 20))
    }

    // An external workspace's own program settings are for its own builds: accepted and ignored here. An
    // `externals:` block may not set one.
    func testProgramSettingInAnExternalIsIgnored() throws {
        let b = try build(["production"], json: "pantry:\n  capacity: 1G\n")
        XCTAssertEqual(b.configuration(for: parse)["pantry.capacity"], .size(256 << 20))
        XCTAssertEqual(b.buildWideSettings["pantry.capacity"], .size(256 << 20))
        XCTAssertEqual(codes(json: "pantry:\n  capacity: lots\n"), [.invalidValue], "its values are still checked")
        XCTAssertEqual(codes(entry: "externals:\n  all:\n    shop:\n      name: x\n"), [.settingInWrongLayer])
    }

    func testUnknownExternal() {
        XCTAssertEqual(codes(entry: "externals:\n  jsn:\n    oven:\n      temp: 1\n"), [.unknownExternal])
    }

    // An external's own configs are valid in its own qualifiers and match nothing; its `externals:` section is
    // ignored when it is consumed.
    func testExternalOwnConfigsAndSections() throws {
        let b = try build(["production"], json: """
            configs:
              fast: release
            oven:
              temp fast: 99
            externals:
              all:
                oven:
                  temp: 1

            """)
        XCTAssertEqual(b.configuration(for: parse)["oven.temp"], .int(220))
    }

    func testSelectingAnUndeclaredConfig() {
        XCTAssertEqual(codes(["prod"]), [.unknownConfig])
    }

    func testRecord() throws {
        let b = try build(["production"])
        XCTAssertEqual(b.record(command: "nomu build -c production", compiler: "3f9a2c1", source: "7a37071"), """
            command: nomu build -c production
            compiler: 3f9a2c1
            source: 7a37071
            active:
              acme.app:
                - release
                - production
              externals:
                - release
              language:
                - release
            builtin:
              oven.mode: bake
              oven.temp: 180
              oven.temp release: 220
              dough.proof: true
              dough.proof test: false
              dough.flours:
                - wheat
              pantry.capacity: 64M
              shop.name: corner
              shop.ledger: ledger
            workspaces:
              acme.app:
                oven.mode: convect
                oven.temp production: 230
                dough.flours:
                  - rye
                pantry.capacity production: 256M
              acme.json:
                oven.temp release: 190
            packages:
              acme.app/net:
                oven.temp: 200
                oven.temp release: 210
            modules:
              acme.app/net/tls:
                dough.flours:
                  - spelt
            externals:
              all:
                oven.mode: bake
              json:
                dough.proof: false

            """)
    }

    func testSummary() throws {
        XCTAssertEqual(try build(["production"]).summary(compiler: "3f9a2c1"), """
            compiler: 3f9a2c1
            active:
              acme.app:
                - release
                - production
              externals:
                - release
              language:
                - release

            """)
    }

    func testValues() throws {
        XCTAssertEqual(try build(["production"]).values(for: tls), """
            oven.mode: convect
            oven.temp: 210
            dough.proof: true
            dough.flours:
              - wheat
              - rye
              - spelt
            pantry.capacity: 256M
            shop.name: corner
            shop.ledger: ledger

            """)
    }
}
