import Foundation
import planner

// The language workspace's sources (`core`, `runtime`, `std`), copied to disk so diagnostics and debug info
// name files that exist: lldb, profilers and editors open `<cache root>/source/std/prelude/prelude.nomu`
// where the compiler's own identity for the file is the virtual `<nomu>/std/prelude/prelude.nomu`.
//
// The copy is for reporting only; compiling always reads the sources carried in the compiler. There is one
// copy per host, at one place, replaced whenever a compiler with different embedded sources uses it (a
// `.digest` file names the sources it holds). A binary built by an older compiler may therefore point at
// newer sources. Writing it is best-effort: when it fails, reports keep the virtual paths.
enum LanguageSourceCopy {
    // Make the copy match this compiler's embedded sources. Returns its directory, or nil when it cannot be
    // written.
    static func ensure(cacheRoot: String) -> String? {
        let fm = FileManager.default
        let dir = cacheRoot + "/source"
        let digest = HostCache.languageSourcesDigest
        if (try? String(contentsOfFile: dir + "/.digest", encoding: .utf8)) == digest { return dir }

        // Write a complete copy beside it, then swap it into place.
        let tag = "\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ..< .max))"
        let staging = cacheRoot + "/.source-" + tag
        defer { try? fm.removeItem(atPath: staging) }
        do {
            for f in LanguageWorkspace.files() {
                let path = staging + "/" + f.path
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try f.text.write(toFile: path, atomically: false, encoding: .utf8)
            }
            try digest.write(toFile: staging + "/.digest", atomically: false, encoding: .utf8)
        } catch {
            return nil
        }
        let old = cacheRoot + "/.source-old-" + tag
        if fm.fileExists(atPath: dir) { _ = rename(dir, old) }
        _ = rename(staging, dir)
        try? fm.removeItem(atPath: old)
        // Another build may have swapped in its own copy meanwhile; either way, report into what is there.
        return fm.fileExists(atPath: dir) ? dir : nil
    }

    // The reported path of each language-workspace file among `files`, under the copy at `dir`.
    static func reportedPaths(_ files: [String], copy dir: String) -> [String: String] {
        let prefix = LanguageWorkspace.root + "/"
        var out: [String: String] = [:]
        for f in files where f.hasPrefix(prefix) { out[f] = dir + "/" + f.dropFirst(prefix.count) }
        return out
    }
}
