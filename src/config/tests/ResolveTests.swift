import XCTest
@testable import config
import cfgresolver

final class ResolveTests: XCTestCase {
    private let schema = Bakery.schema

    private func at(_ line: Int, _ path: String = "cfg.yaml") -> Origin { .file(path: path, line: line, column: 1) }

    private func table(_ workspace: [ConfigDeclaration] = []) throws(ConfigErrors) -> ConfigTable {
        try ConfigTable([schema.builtinLayer, Layer(.entryWorkspace, configs: workspace)])
    }

    private func resolveIn(_ layers: [Layer], active: [String] = ["debug"], workspace: [ConfigDeclaration] = []) throws(ConfigErrors) -> Configuration {
        try resolve(schema, layers: [schema.builtinLayer] + layers, configs: table(workspace), active: active)
    }

    private func errors(_ layers: [Layer], active: [String] = ["debug"], workspace: [ConfigDeclaration] = []) -> [ConfigError.Code] {
        do {
            _ = try resolveIn(layers, active: active, workspace: workspace)
            XCTFail("expected errors")
            return []
        } catch {
            return error.codes
        }
    }

    // MARK: Layers

    func testDefaultsWithNoFiles() throws {
        let c = try resolveIn([])
        XCTAssertEqual(c["oven.mode"], .choice("bake"))
        XCTAssertEqual(c["oven.temp"], .int(180))
        XCTAssertEqual(c["dough.proof"], .bool(true))
        XCTAssertEqual(c["dough.flours"], .list([.string("wheat")]))
        XCTAssertEqual(c["pantry.capacity"], .size(64 << 20))
        XCTAssertEqual(c.resolved("oven.temp")?.candidates.map(\.status), [.won, .unmatched])
    }

    func testStrongerLayerWins() throws {
        let c = try resolveIn([
            Layer(.entryWorkspace, declarations: [Declaration("oven.temp", .integer(150), origin: at(1))]),
            Layer(.package, declarations: [Declaration("oven.temp", .integer(160), origin: at(1, "pkg/cfg.yaml"))]),
            Layer(.module, declarations: [Declaration("oven.temp", .integer(170), origin: at(1, "pkg/m/cfg.yaml"))]),
            Layer(.module, declarations: [Declaration("oven.mode", .string("broil"), origin: at(2, "pkg/m/cfg.yaml"))]),
        ])
        XCTAssertEqual(c["oven.temp"], .int(170))
        XCTAssertEqual(c["oven.mode"], .choice("broil"))
        let temp = c.resolved("oven.temp")!.candidates
        XCTAssertEqual(temp.map(\.layer), [.builtin, .builtin, .entryWorkspace, .package, .module])
        XCTAssertEqual(temp.map(\.status), [.overridden, .unmatched, .overridden, .overridden, .won])
    }

    // A config's builtin value is a declaration in the builtin layer, so any stronger layer replaces it.
    func testConfigValueCarriedUntilAStrongerLayerDeclares() throws {
        XCTAssertEqual(try resolveIn([], active: ["release"])["oven.temp"], .int(220))
        let c = try resolveIn([Layer(.entryWorkspace, declarations: [Declaration("oven.temp", .integer(150), origin: at(1))])],
                              active: ["release"])
        XCTAssertEqual(c["oven.temp"], .int(150))
    }

    // MARK: Qualifiers

    func testQualifiedBeatsUnqualifiedInOneLayer() throws {
        let layer = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", .integer(150), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(250), origin: at(2)),
        ])
        XCTAssertEqual(try resolveIn([layer], active: ["release"])["oven.temp"], .int(250))
        XCTAssertEqual(try resolveIn([layer], active: ["debug"])["oven.temp"], .int(150))
    }

    func testLatestConfigInTheListWins() throws {
        let layer = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["debug"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(200), origin: at(2)),
        ])
        XCTAssertEqual(try resolveIn([layer], active: ["debug", "release"])["oven.temp"], .int(200))
        XCTAssertEqual(try resolveIn([layer], active: ["release", "debug"])["oven.temp"], .int(100))
        let c = try resolveIn([layer], active: ["debug", "release"])
        XCTAssertEqual(c.resolved("oven.temp")!.candidates.filter { $0.layer == .entryWorkspace }.map(\.status), [.outranked, .won])
    }

    func testSeveralQualifierNamesMeanAnyOfThem() throws {
        let layer = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["test", "release"], .integer(120), origin: at(1)),
        ])
        XCTAssertEqual(try resolveIn([layer], active: ["release"])["oven.temp"], .int(120))
        XCTAssertEqual(try resolveIn([layer], active: ["debug", "test"])["oven.temp"], .int(120))
        XCTAssertEqual(try resolveIn([layer], active: ["debug"])["oven.temp"], .int(180))
    }

    // A weaker layer's qualified declaration loses to a stronger layer's unqualified one: layer order decides first.
    func testLayerOrderBeforeQualifiers() throws {
        let c = try resolveIn([
            Layer(.entryWorkspace, declarations: [Declaration("oven.temp", configs: ["release"], .integer(250), origin: at(1))]),
            Layer(.module, declarations: [Declaration("oven.temp", .integer(140), origin: at(1, "m/cfg.yaml"))]),
        ], active: ["release"])
        XCTAssertEqual(c["oven.temp"], .int(140))
    }

    func testConflictUnderOneWinningConfig() {
        let layer = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["debug", "release"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(200), origin: at(2)),
        ])
        XCTAssertEqual(errors([layer], active: ["release"]), [.conflict])
        XCTAssertEqual(errors([layer], active: ["debug", "release"]), [.conflict])
    }

    func testNoConflictWhenTheyWinUnderDifferentConfigsOrAgree() throws {
        let layer = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["debug", "release"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(200), origin: at(2)),
        ])
        XCTAssertEqual(try resolveIn([layer], active: ["debug"])["oven.temp"], .int(100))
        let agree = Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["debug", "release"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(100), origin: at(2)),
        ])
        XCTAssertEqual(try resolveIn([agree], active: ["release"])["oven.temp"], .int(100))
    }

    // `oven release:` holding `temp:` and `oven:` holding `temp release:` are one declaration spelled twice.
    func testTwoSpellingsOfOneDeclaration() {
        XCTAssertEqual(errors([Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["release"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(100), origin: at(4)),
        ])]), [.duplicateDeclaration])
        XCTAssertEqual(errors([Layer(.module, declarations: [
            Declaration("oven.temp", .integer(100), origin: at(1)),
            Declaration("oven.temp", .integer(110), origin: at(3)),
        ])]), [.duplicateDeclaration])
        XCTAssertEqual(errors([Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["debug", "release"], .integer(100), origin: at(1)),
            Declaration("oven.temp", configs: ["release", "debug"], .integer(100), origin: at(2)),
        ])]), [.duplicateDeclaration])
    }

    // Declarations resolve the same in any order.
    func testDeclarationOrderDoesNotMatter() throws {
        let declarations = [
            Declaration("oven.temp", .integer(150), origin: at(1)),
            Declaration("oven.temp", configs: ["release"], .integer(250), origin: at(2)),
            Declaration("oven.temp", configs: ["test"], .integer(90), origin: at(3)),
            Declaration("dough.flours", .list([.string("rye")]), origin: at(4)),
            Declaration("oven.mode", configs: ["debug"], .string("convect"), origin: at(5)),
        ]
        for active in [["debug"], ["release"], ["debug", "test"], ["debug", "test", "release"], ["release", "debug", "test"]] {
            let forward = try resolveIn([Layer(.entryWorkspace, declarations: declarations)], active: active)
            let backward = try resolveIn([Layer(.entryWorkspace, declarations: declarations.reversed())], active: active)
            XCTAssertEqual(forward.canonical(), backward.canonical(), "\(active)")
        }
    }

    // MARK: Checks

    func testUnknownSettingSuggestsTheNearest() {
        do {
            _ = try resolveIn([Layer(.entryWorkspace, declarations: [Declaration("oven.tmp", .integer(1), origin: at(3))])])
            XCTFail("expected errors")
        } catch {
            XCTAssertEqual(error.codes, [.unknownSetting])
            XCTAssertEqual(error.rendered, "cfg.yaml:3:1: error: unknown setting `oven.tmp`; did you mean `oven.temp`?")
        }
    }

    func testQualifierNamingAnUndeclaredConfig() {
        XCTAssertEqual(errors([Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["relase"], .integer(1), origin: at(1)),
        ])]), [.unknownConfig])
    }

    // A config the files' workspace declares may be absent from the list; its declarations match nothing.
    // An external workspace's files resolve this way under the builtin names of the entry's list.
    func testQualifierNamingADeclaredConfigOutsideTheList() throws {
        let c = try resolveIn([Layer(.entryWorkspace, declarations: [
            Declaration("oven.temp", configs: ["rbe"], .integer(1), origin: at(1)),
        ])], active: ["debug"], workspace: [ConfigDeclaration("rbe", parent: "debug", origin: at(9))])
        XCTAssertEqual(c["oven.temp"], .int(180))
    }

    func testProgramAndBuildSettingsOnlyInTheWorkspaceFile() throws {
        XCTAssertEqual(errors([Layer(.package, declarations: [Declaration("pantry.capacity", .string("1G"), origin: at(1))])]),
                       [.settingInWrongLayer])
        XCTAssertEqual(errors([Layer(.module, declarations: [Declaration("shop.ledger", .string("x"), origin: at(1))])]),
                       [.settingInWrongLayer])
        let c = try resolveIn([Layer(.entryWorkspace, declarations: [
            Declaration("pantry.capacity", .string("1G"), origin: at(1)),
            Declaration("shop.ledger", .string("x"), origin: at(2)),
        ])])
        XCTAssertEqual(c["pantry.capacity"], .size(1 << 30))
        XCTAssertEqual(c["shop.ledger"], .string("x"))
    }

    func testEveryErrorIsReported() {
        XCTAssertEqual(errors([
            Layer(.entryWorkspace, declarations: [
                Declaration("oven.tmp", .integer(1), origin: at(1)),
                Declaration("oven.temp", .integer(999), origin: at(2)),
            ]),
            Layer(.package, declarations: [Declaration("shop.name", .string("x"), origin: at(1, "p/cfg.yaml"))]),
        ]), [.unknownSetting, .invalidValue, .settingInWrongLayer])
    }

    // MARK: Merge

    func testAppendJoinsEachLayersWinnerWeakestFirst() throws {
        let c = try resolveIn([
            Layer(.entryWorkspace, declarations: [
                Declaration("dough.flours", .list([.string("rye")]), origin: at(1)),
                Declaration("dough.flours", configs: ["release"], .list([.string("spelt")]), origin: at(2)),
            ]),
            Layer(.module, declarations: [
                Declaration("dough.flours", .list([.string("oat")]), origin: at(1, "m/cfg.yaml")),
            ]),
        ], active: ["release"])
        XCTAssertEqual(c["dough.flours"], .list([.string("wheat"), .string("spelt"), .string("oat")]))
        XCTAssertEqual(c.resolved("dough.flours")!.candidates.map(\.status), [.won, .outranked, .won, .won])
    }

    func testEmptyListAppendsNothing() throws {
        let c = try resolveIn([Layer(.entryWorkspace, declarations: [Declaration("dough.flours", .list([]), origin: at(1))])])
        XCTAssertEqual(c["dough.flours"], .list([.string("wheat")]))
    }

    // MARK: Canonical form

    // Spellings that mean the same value give the same canonical form, so they key the cache alike (G2).
    func testCanonicalFormIgnoresSpelling() throws {
        let a = try resolveIn([Layer(.entryWorkspace, declarations: [
            Declaration("pantry.capacity", .string("64M"), origin: at(1))])])
        let b = try resolveIn([Layer(.entryWorkspace, declarations: [
            Declaration("pantry.capacity", .integer(64 << 20), origin: at(1))])])
        let c = try resolveIn([])
        XCTAssertEqual(a.canonical(), b.canonical())
        XCTAssertEqual(a.canonical(), c.canonical())
        XCTAssertEqual(a.canonical(), """
            dough.flours=["wheat"]
            dough.proof=true
            oven.mode=bake
            oven.temp=180
            pantry.capacity=67108864
            shop.ledger="ledger"
            shop.name="corner"

            """)
        XCTAssertEqual(a.canonical(["oven.temp", "shop.name"]), "oven.temp=180\nshop.name=\"corner\"\n")
    }

    // Configs that resolve every setting alike give one canonical form; it never names a config (G12).
    func testCanonicalFormHoldsValuesNotConfigNames() throws {
        let workspace = [ConfigDeclaration("production", parent: "release", origin: at(1))]
        let release = try resolveIn([], active: ["release"], workspace: workspace)
        let production = try resolveIn([], active: ["release", "production"], workspace: workspace)
        XCTAssertEqual(release.canonical(), production.canonical())
    }
}
