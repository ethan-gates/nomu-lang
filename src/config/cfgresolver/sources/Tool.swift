import Foundation
import cli
import config

// What one run prints, and its exit status.
public struct Outcome: Equatable {
    public let text: String
    public let status: Int32
}

let command = Command(
    "cfgresolver",
    summary: "Resolve a fixture tree of cfg.yaml files under the bakery schema and print the configuration record.",
    flags: [Flag("builtin", help: "print the builtin layer as a cfg.yaml instead")],
    options: [
        Opt("config", short: "c", valueName: "names", help: "select configs; repeat or separate with commas", isList: true),
        Opt("values", valueName: "module", help: "print one module's final values instead (e.g. acme.app/net/tls)"),
        Opt("language", valueName: "dir", help: "a language workspace to include"),
    ],
    positionals: [Positional("workspace", help: "the entry workspace's directory", required: false)])

// Runs the tool on `args`, with relative paths read from `cwd` and shown relative to it.
public func run(_ args: [String], cwd: String) -> Outcome {
    let parsed: Parsed
    switch parse(command, args) {
    case .run(let p): parsed = p
    case .help(let text), .version(let text): return Outcome(text: text, status: 0)
    case .error(let message): return Outcome(text: message + "\n", status: 2)
    }
    let schema = Bakery.schema
    if parsed.has("builtin") { return Outcome(text: schema.builtinFile(), status: 0) }
    guard let workspace = parsed.positional("workspace") else {
        return Outcome(text: "error: name the entry workspace's directory\n", status: 2)
    }

    let base = standardized(cwd)
    func absolute(_ path: String) -> String { standardized(path.hasPrefix("/") ? path : base + "/" + path) }
    func display(_ path: String) -> String {
        path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
    func failed(_ lines: [String]) -> Outcome { Outcome(text: lines.joined(separator: "\n") + "\n", status: 1) }

    let fixture: Fixture
    do {
        fixture = try Fixture.load(entry: absolute(workspace), language: parsed.value("language").map(absolute), display: display)
    } catch {
        return failed(error.lines)
    }
    do {
        let build = try BuildConfiguration(schema, workspaces: fixture.workspaces, pins: fixture.pins,
                                           selection: try selection(parsed.values("config")),
                                           defaultSelection: ["debug"], externalDefault: ["release"])
        if let name = parsed.value("values") {
            guard let place = fixture.places.first(where: { $0.name == name }) else {
                return failed(["error: no module `\(name)`; modules: " + fixture.places.map(\.name).sorted().joined(separator: ", ")])
            }
            return Outcome(text: build.values(for: place), status: 0)
        }
        return Outcome(text: build.record(command: (["cfgresolver"] + args).joined(separator: " "),
                                          compiler: "cfgresolver", source: "fixture"), status: 0)
    } catch {
        return failed(error.errors.map(\.rendered))
    }
}
