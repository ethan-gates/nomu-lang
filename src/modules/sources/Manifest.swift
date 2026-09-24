import Foundation

// The package manifest (task 100.3; modules.md §Manifest). JSON for now — dependency-free in the Swift
// host (YAML is task 163). Read from `pkg.json` at the package root; the root itself is still marked by
// `nomu.yaml`. Both file names are interim and subject to change. Minimal to start: just the package
// name (identity). Version, `sealed`, `bin`, tests, and dependencies fill in later.
public struct Manifest: Codable {
    public let name: String
}

public enum ManifestError: Error, CustomStringConvertible {
    case malformed(path: String, detail: String)
    public var description: String {
        switch self {
        case .malformed(let path, let detail): return "invalid manifest '\(path)': \(detail)"
        }
    }
}

// Load `<packageRoot>/pkg.json`. Returns nil when absent (an unmanifested tree still compiles under a
// default identity); throws on a present-but-invalid manifest.
public func loadManifest(packageRoot: String) throws -> Manifest? {
    let path = packageRoot + "/pkg.json"
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    do { return try JSONDecoder().decode(Manifest.self, from: data) }
    catch { throw ManifestError.malformed(path: path, detail: "\(error)") }
}

// The default package identity when no manifest is present. `main` matches the implied package the
// mangler assumes today; task 100.2.6 makes the encoding explicit.
public let defaultPackageName = "main"
