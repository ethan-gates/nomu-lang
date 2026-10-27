import Foundation
import planner

// The paths debug info records (task 207.3): `/nomu-src/<workspace>/<path in the workspace>`, the same wherever
// the sources and the host cache live, so an object is the same bytes from any checkout and the cache can share
// it. The language workspace's files record `/nomu-src/nomu.nomu/…`. As with `-fdebug-prefix-map` and Rust's
// `--remap-path-prefix`, the debugger maps each prefix back to disk: a binary's link writes the mapping beside
// it as an lldb command file (`lldbInit`), loaded with `lldb -s <binary>.lldbinit`.
enum DebugPaths {
    static let root = "/nomu-src"

    // The prefix a workspace's files record.
    static func prefix(_ workspace: WorkspaceIdentity) -> String { root + "/\(workspace)" }

    // The recorded path of each of `files`, which lie under `workspaceRoot`.
    static func paths(_ files: [String], workspace: WorkspaceIdentity, workspaceRoot: String) -> [String: String] {
        var out: [String: String] = [:]
        for f in files where f.hasPrefix(workspaceRoot + "/") {
            out[f] = prefix(workspace) + f.dropFirst(workspaceRoot.count)
        }
        return out
    }

    // lldb commands that map each workspace's prefix to its directory on disk: its root, or for the language
    // workspace the source copy (`LanguageSourceCopy`).
    static func lldbInit(_ roots: [(WorkspaceIdentity, String)]) -> String {
        var out = "# Maps the paths Nomu debug info records to this machine's sources. Load with `lldb -s <this file>`.\n"
        for (workspace, dir) in roots.sorted(by: { "\($0.0)" < "\($1.0)" }) {
            out += "settings append target.source-map \(prefix(workspace)) \(quoted(dir))\n"
        }
        return out
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
