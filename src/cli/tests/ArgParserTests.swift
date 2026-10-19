import XCTest
@testable import cli

final class ArgParserTests: XCTestCase {
    // A root mirroring the `nomu` surface closely enough to exercise every feature.
    private func root() -> Command {
        Command("nomu", summary: "The Nomu compiler driver.",
            // Global (inherited) flags/options — shared across subcommands.
            flags: [Flag("release", short: "O", help: "optimize")],
            options: [Opt("mono", help: "specialization depth", defaultValue: "none",
                          choices: ["none", "edge", "all"])],
            subcommands: [
                Command("compile", summary: "compile source files",
                    flags: [Flag("emit-ast"), Flag("verbose", short: "v"), Flag("internal-switch", hidden: true)],
                    options: [
                        Opt("output", short: "o", valueName: "path", help: "output binary"),
                        Opt("runtime-subset", valueName: "names", isList: true, commaSplit: true),
                    ],
                    positionals: [Positional("files", variadic: true)]),
                Command("run", summary: "build and run a bin",
                    options: [Opt("bin", help: "which bin")],
                    positionals: [Positional("dir", required: false)],
                    passthrough: true),
            ])
    }

    private func parsed(_ args: [String]) -> Parsed {
        guard case .run(let p) = parse(root(), args, version: "nomu 0.1") else {
            XCTFail("expected .run for \(args)"); return Parsed(commandPath: [], flags: [], options: [:], positionals: [:], passthrough: [])
        }
        return p
    }

    private func errorMessage(_ args: [String]) -> String {
        guard case .error(let m) = parse(root(), args, version: "nomu 0.1") else {
            XCTFail("expected .error for \(args)"); return ""
        }
        return m
    }

    func testSubcommandDispatchAndPositionals() {
        let p = parsed(["compile", "a.nomu", "b.nomu"])
        XCTAssertEqual(p.commandPath, ["nomu", "compile"])
        XCTAssertEqual(p.positionals("files"), ["a.nomu", "b.nomu"])
    }

    func testLongAndShortOptionValueForms() {
        XCTAssertEqual(parsed(["compile", "-o", "x", "f.nomu"]).value("output"), "x")
        XCTAssertEqual(parsed(["compile", "-o=x", "f.nomu"]).value("output"), "x")
        XCTAssertEqual(parsed(["compile", "--output", "x", "f.nomu"]).value("output"), "x")
        XCTAssertEqual(parsed(["compile", "--output=x", "f.nomu"]).value("output"), "x")
    }

    func testCompactedShortFlags() {
        // -Ov ≡ -O -v (both value-less flags; `release` is a global flag, `verbose` local).
        let p = parsed(["compile", "-Ov", "f.nomu"])
        XCTAssertTrue(p.has("release"))
        XCTAssertTrue(p.has("verbose"))
    }

    func testValueOptionInClusterIsError() {
        let m = errorMessage(["compile", "-ov", "f.nomu"])
        XCTAssertTrue(m.contains("-o takes a value and cannot be combined"), m)
    }

    func testSharedGlobalFlagAndOption() {
        let p = parsed(["compile", "-O", "--mono=all", "f.nomu"])
        XCTAssertTrue(p.has("release"))
        XCTAssertEqual(p.value("mono"), "all")
    }

    func testOptionDefaultApplies() {
        XCTAssertEqual(parsed(["compile", "f.nomu"]).value("mono"), "none")
    }

    func testChoiceValidation() {
        let m = errorMessage(["compile", "--mono=wild", "f.nomu"])
        XCTAssertTrue(m.contains("invalid value 'wild'"), m)
        XCTAssertTrue(m.contains("none, edge, all"), m)
    }

    func testListOptionRepeatedAndCommaSplit() {
        XCTAssertEqual(parsed(["compile", "--runtime-subset=a,b", "--runtime-subset", "c", "f.nomu"])
                        .values("runtime-subset"), ["a", "b", "c"])
    }

    func testPassthroughForwardsAfterDashDash() {
        let p = parsed(["run", "mydir", "--", "--flag", "arg"])
        XCTAssertEqual(p.positional("dir"), "mydir")
        XCTAssertEqual(p.passthrough, ["--flag", "arg"])
    }

    func testUnknownOptionAndSubcommand() {
        XCTAssertTrue(errorMessage(["compile", "--nope", "f.nomu"]).contains("unknown option '--nope'"))
        XCTAssertTrue(errorMessage(["bogus"]).contains("unknown subcommand 'bogus'"))
    }

    func testMissingOptionValueAndRequiredPositional() {
        XCTAssertTrue(errorMessage(["compile", "-o"]).contains("option -o requires a value"))
        // `compile` needs at least one file (variadic + required by default).
        XCTAssertTrue(errorMessage(["compile"]).contains("missing required argument <files>"))
    }

    func testHelpAndVersion() {
        guard case .help(let top) = parse(root(), ["--help"], version: "nomu 0.1") else {
            return XCTFail("expected top-level help")
        }
        XCTAssertTrue(top.contains("commands:"))
        XCTAssertTrue(top.contains("compile"))

        guard case .help(let sub) = parse(root(), ["compile", "-h"], version: "nomu 0.1") else {
            return XCTFail("expected subcommand help")
        }
        XCTAssertTrue(sub.contains("--output"))
        XCTAssertTrue(sub.contains("(none | edge | all)"))   // choices surfaced in help

        guard case .version(let v) = parse(root(), ["--version"], version: "nomu 0.1") else {
            return XCTFail("expected version")
        }
        XCTAssertEqual(v, "nomu 0.1")
    }

    func testHiddenFlagParsesButStaysOutOfHelp() {
        XCTAssertTrue(parsed(["compile", "--internal-switch", "a.nomu"]).has("internal-switch"))
        guard case .help(let sub) = parse(root(), ["compile", "-h"], version: "nomu 0.1") else {
            return XCTFail("expected subcommand help")
        }
        XCTAssertFalse(sub.contains("internal-switch"))
        XCTAssertTrue(sub.contains("--emit-ast"))
    }

    func testBareGroupingCommandShowsHelp() {
        guard case .help = parse(root(), [], version: "nomu 0.1") else {
            return XCTFail("bare root with subcommands should show help")
        }
    }
}
