import Foundation

// Stale `build/` layouts (task 210.3): a file where the current layout puts a directory, or a directory where it
// puts a file, was left by an earlier layout (or an earlier module tree). It is reported and removed, instead of
// failing the build with an opaque "File exists" or "Is a directory".
enum Layout {
    // Make the directory `dir`, clearing any file that stands where it or one of its ancestors goes, within
    // `buildRoot` (nothing outside it is touched).
    static func makeDirectory(_ dir: String, buildRoot: String) -> Bool {
        var ancestors: [String] = []
        var path = dir
        while path == buildRoot || path.hasPrefix(buildRoot + "/") {
            ancestors.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        for a in ancestors.reversed() { clearFile(at: a) }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); return true }
        catch { fputs("error: failed to create output dir '\(dir)': \(error)\n", stderr); return false }
    }

    // Remove a file (not a directory) at `path`, reporting it.
    static func clearFile(at path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
        fputs("nomu: removed '\(path)', a file left by an earlier build where a directory now goes\n", stderr)
        try? FileManager.default.removeItem(atPath: path)
    }

    // Remove a directory at `path`, where a file now goes, reporting it.
    static func clearDirectory(at path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        fputs("nomu: removed '\(path)', a directory left by an earlier build where a file now goes\n", stderr)
        try? FileManager.default.removeItem(atPath: path)
    }
}
