import Foundation

// The package manifest (modules.md §Manifest). One per package. JSON for now — dependency-free in the
// Swift host (Foundation; YAML is task 163). Read from `pkg.json` at the package root; the root itself is
// still marked by `nomu.yaml`. Both file names are interim and subject to change.
//
// Contents are the settled contract: package name + version (identity), the `sealed` module list, `bin`
// executable declarations, and test-module declarations. Dependencies (external-package aliases) and the
// repo-root workspace section fill in when cross-package linkage lands. Module metadata stays zero — the
// manifest references modules only as policy lists (sealed / bin / tests), never as an addressing
// inventory (the filesystem is the module list, modules.md §Modules).
//
// Every section beyond `name` is optional: a name-only manifest is valid, and an absent section defaults
// to empty. Module paths are package-root-relative with `/` separators; the empty string "" names the
// root module.
public struct Manifest: Codable {
    public let name: String

    // An executable: the `name` it builds to and the `module` whose `main` is its entry (modules.md
    // §Initialization & entry point). A package with no `bin` and a `main` at its root module is the
    // single-executable shorthand, so `bin` may be empty.
    public struct Bin: Codable {
        public let name: String
        public let module: String
    }

    // A test module (modules.md §Tests). Test identity is module-level — a module is real XOR test. The
    // runner + case designation live in the test-framework work (modules.md §Tests); this records the
    // module identity only.
    public struct TestModule: Codable {
        public let module: String
    }

    // Backing storage is optional so the name-only manifest stays valid; the accessors default to empty
    // (or nil for `version` / `defaultModule`). The synthesized Codable decodes a missing optional key as nil.
    private let versionField: String?
    private let defaultModuleField: String?
    private let sealedField: [String]?
    private let binField: [Bin]?
    private let testsField: [TestModule]?

    public var version: String? { versionField }
    // The leaf module a bare package name forwards to, for `import`/`build`/`run` (modules.md
    // §First-party addressing). A package-root-relative path (`/`-separated); nil when the package
    // designates none — a single-module package's root module is its implicit default, so it needs no entry.
    public var defaultModule: String? { defaultModuleField }
    public var sealed: [String] { sealedField ?? [] }
    public var bin: [Bin] { binField ?? [] }
    public var tests: [TestModule] { testsField ?? [] }

    private enum CodingKeys: String, CodingKey {
        case name
        case versionField = "version"
        case defaultModuleField = "default-module"
        case sealedField = "sealed"
        case binField = "bin"
        case testsField = "tests"
    }
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
