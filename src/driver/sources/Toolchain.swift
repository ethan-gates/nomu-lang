import Foundation
import store

// The identity of each system tool a build runs (the link and the runtime archive's recipe), and of the SDK they
// read (`libSystem`'s stubs, the C headers), as it enters their cache keys: a toolchain update rebuilds what the
// tools made. A tool that reports a version is named by that report (`cc --version`'s first line, `ld -v`'s
// project and build lines, `dsymutil --version`); one that does not (`strip`, `ar`, `codesign`) by its file's
// content hash, and the SDK by its `SDKSettings.json`'s. Interim: the tools and the stubs move into the compiler
// (216), whose identity then covers them.
//
// Asking costs a process per tool, so the answers are kept in the host cache (`toolchain.json`) with what they
// depend on: the selected developer directory, the environment that redirects `xcrun`, and each resolved tool's
// size and modification time. While those hold, a build reads the record and runs nothing; when one changes (an
// Xcode switch or update), or a tool was missing, every tool is asked again.
struct Toolchain: Codable, Equatable {
    // A tool's command (the `/usr/bin` shim the build runs), and the arguments that print its version with the
    // number of lines of the report that name it; nil for one named by its file's content.
    struct Tool {
        let name: String
        let version: (args: [String], lines: Int)?
    }

    static let tools = [
        Tool(name: "cc", version: (["--version"], 1)),
        Tool(name: "ld", version: (["-v"], 2)),
        Tool(name: "dsymutil", version: (["--version"], 1)),
        Tool(name: "strip", version: nil),
        Tool(name: "ar", version: nil),
        Tool(name: "codesign", version: nil),
        Tool(name: "sdk", version: nil),
    ]

    // What the identities depend on.
    struct Selection: Codable, Equatable {
        var developerDir: String?
        var environment: [String: String]
    }

    struct Resolved: Codable, Equatable {
        var path: String
        var size: Int
        var modified: Double
    }

    var selection: Selection
    var resolved: [String: Resolved]
    // By tool name; `absent` for a tool that cannot be found or run.
    var identities: [String: String]

    static let fileName = "toolchain.json"

    // The current toolchain's identities: the record under `cacheRoot` while it holds, else asked again and
    // recorded. `resolve` finds a tool's file and `run` runs a command for its output; tests replace both.
    static func identities(cacheRoot: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                           selectLink: String = "/var/db/xcode_select_link",
                           resolve: (String) -> String? = resolveTool, run: (String, [String]) -> String? = output)
        -> [String: String]
    {
        let path = cacheRoot + "/" + fileName
        let selection = Selection(
            developerDir: try? FileManager.default.destinationOfSymbolicLink(atPath: selectLink),
            environment: environment.filter { ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"].contains($0.key) })
        if let data = FileManager.default.contents(atPath: path),
           let record = try? JSONDecoder().decode(Toolchain.self, from: data),
           record.selection == selection,
           record.resolved.allSatisfy({ name, r in stamp(r.path) == r }),
           Set(record.identities.keys) == Set(tools.map(\.name)), !record.identities.values.contains("absent") {
            return record.identities
        }
        var record = Toolchain(selection: selection, resolved: [:], identities: [:])
        for tool in tools {
            guard let file = resolve(tool.name), let stamped = stamp(file) else {
                record.identities[tool.name] = "absent"
                continue
            }
            record.resolved[tool.name] = stamped
            if let (args, lines) = tool.version {
                record.identities[tool.name] = run("/usr/bin/" + tool.name, args).map { summary($0, lines: lines) } ?? "absent"
            } else {
                record.identities[tool.name] = FileManager.default.contents(atPath: file).map(ContentHash.of) ?? "absent"
            }
        }
        save(record, to: path)
        return record.identities
    }

    // A version report's first `lines` lines, joined.
    static func summary(_ report: String, lines: Int) -> String {
        report.split(separator: "\n").prefix(lines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    static func stamp(_ path: String) -> Resolved? {
        guard let s = FileStamp(path) else { return nil }
        return Resolved(path: path, size: s.size, modified: s.modified)
    }

    // A tool's file: `xcrun -f` for a toolchain tool, the `/usr/bin` file itself for a system one (`codesign`); for
    // the SDK, its `SDKSettings.json`.
    static func resolveTool(_ name: String) -> String? {
        if name == "sdk" {
            guard let sdk = output("/usr/bin/xcrun", ["--show-sdk-path"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  FileManager.default.fileExists(atPath: sdk + "/SDKSettings.json") else { return nil }
            return sdk + "/SDKSettings.json"
        }
        if let found = output("/usr/bin/xcrun", ["-f", name])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !found.isEmpty, FileManager.default.fileExists(atPath: found) {
            return found
        }
        return FileManager.default.fileExists(atPath: "/usr/bin/" + name) ? "/usr/bin/" + name : nil
    }

    // A command's standard output and error together (`ld -v` prints to error), or nil if it did not run.
    static func output(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // Write the record whole, by rename. Best-effort: without it the next build asks again.
    private static func save(_ record: Toolchain, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let tmp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }
}
