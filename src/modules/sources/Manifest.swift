import Foundation

// The package manifest (modules.md §Manifest). One per package. JSON for now — dependency-free in the
// Swift host (Foundation; YAML is task 163). Read from `pkg.json` at the package root; the root itself is
// still marked by `nomu.yaml`. Both file names are interim and subject to change.
//
// Contents are the settled contract: package name + version (identity), the `products` module list (the
// opt-in external surface), `bin` executable declarations, and test-module declarations. Dependencies (the
// cross-package allow-list) are a name list; the repo-root workspace section fills in with external pins.
// Module metadata stays zero — the manifest references modules only as policy lists (products / bin /
// tests), never as an addressing inventory (the filesystem is the module list, modules.md §Modules).
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
    private let productsField: [String]?
    private let binField: [Bin]?
    private let testsField: [TestModule]?
    private let dependenciesField: [String]?

    public var version: String? { versionField }
    // The leaf module a bare package name forwards to, for `import`/`build`/`run` (modules.md
    // §First-party addressing). A package-root-relative path (`/`-separated); nil when the package
    // designates none — a single-module package's root module is its implicit default, so it needs no entry.
    public var defaultModule: String? { defaultModuleField }
    // The package's **products** (modules.md §Visibility): the opt-in list of modules importable from
    // outside the package, each a package-root-relative path. Module publicness is opt-in — the default is
    // package-internal, and `public` is allowed only inside a product module. Replaces the earlier `sealed`
    // opt-out (a module was public unless sealed); products invert that so encapsulation is the default and
    // one mechanism covers it. Empty when the package exposes no module. Enforcement rides 187.4.2/187.4.3.
    public var products: [String] { productsField ?? [] }
    public var bin: [Bin] { binField ?? [] }
    public var tests: [TestModule] { testsField ?? [] }
    // The allow-list of packages this package's modules may import from (task 187.1): each entry is a
    // dependency's **own package name** — the root token an import uses (`import libfoo/bar` names the
    // package `libfoo`), no per-importer aliasing since identity is workspace-unique. Imports are strict —
    // a module may import only packages listed here; a dependency's own dependencies are not transitively
    // importable. No paths or versions live here: an in-workspace package is found by its `pkg.json` marker
    // within the workspace tree, and an external package's workspace is pinned (version/source) in
    // `nomu.yaml`. Empty when the package has none.
    public var dependencies: [String] { dependenciesField ?? [] }

    private enum CodingKeys: String, CodingKey {
        case name
        case versionField = "version"
        case defaultModuleField = "default-module"
        case productsField = "products"
        case binField = "bin"
        case testsField = "tests"
        case dependenciesField = "dependencies"
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
    return try decodeManifest(data, path: path)
}

// Decode a manifest's bytes; `path` names it in the error. For callers that read files themselves.
public func decodeManifest(_ data: Data, path: String) throws -> Manifest {
    do { return try JSONDecoder().decode(Manifest.self, from: data) }
    catch { throw ManifestError.malformed(path: path, detail: "\(error)") }
}

// Package names a user package may not take: `std` is the compiler-embedded standard library (the import root
// `std` always resolves to it), and `pkg` is the same-package import root keyword. The embedded `nomu`
// workspace's own `std` package is the one legitimate holder; the driver exempts it.
public let reservedPackageNames: Set<String> = ["std", "pkg"]

public func reservedPackageNameError(_ name: String, at path: String) -> String {
    let what = name == "std" ? "the standard library" : "the same-package import root"
    return "package name '\(name)' is reserved for \(what) — rename the package in '\(path)/pkg.json'"
}

// The default package identity when no manifest is present. `main` matches the implied package the
// mangler assumes today; task 100.2.6 makes the encoding explicit.
public let defaultPackageName = "main"
