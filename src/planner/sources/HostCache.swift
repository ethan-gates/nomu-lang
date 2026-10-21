import embedded

// The per-host cache (task 190, D4): language-level artifacts shared by every build on the host and kept
// across `git clean -dfx`, namely the runtime archive and the language workspace's modules. Entries are
// content-keyed, so a present entry is always the right one for its key.
public enum HostCache {
    // The cache root: `NOMU_CACHE_DIR` when set, else the platform user cache directory
    // (`~/Library/Caches/nomu` on macOS; `$XDG_CACHE_HOME/nomu`, falling back to `~/.cache/nomu`, elsewhere).
    public static func root(environment env: [String: String]) -> String {
        if let dir = env["NOMU_CACHE_DIR"], !dir.isEmpty { return dir }
        let home = env["HOME"] ?? "/tmp"
        #if os(macOS)
        return home + "/Library/Caches/nomu"
        #else
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty { return xdg + "/nomu" }
        return home + "/.cache/nomu"
        #endif
    }

    // The host the build targets, as it enters cache keys.
    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
    public static var hostTarget: String {
        #if os(macOS)
        return hostArch + "-macos"
        #else
        return hostArch + "-linux"
        #endif
    }

    // The runtime archive's key: the embedded runtime sources, the host architecture and the recipe (the
    // driver's commands that build the archive, `PlanOptions.runtimeRecipe`). Editing the runtime rebuilds the
    // compiler, which changes the embedded content and so the key; editing a command changes the recipe. (The
    // local `cc` version is deliberately left out: an archive built by an older `cc` still links and runs.)
    public static func runtimeArchiveKey(recipe: [[String]]) -> String {
        var h = Hasher64()
        h.mix(runtimeSourcesDigest)
        h.mix(hostArch)
        for command in recipe { h.mix(String(command.count)); for arg in command { h.mix(arg) } }
        return h.hex
    }

    // The language workspace's key: its sources, the compiler's identity (the git commit it was built from;
    // `.nmi` / `.bir` formats change with the compiler), the host target, and every option that changes the
    // compiled output.
    public static func languageWorkspaceKey(compilerIdentity: String, outputOptions: [String]) -> String {
        var h = Hasher64()
        h.mix(languageSourcesDigest)
        h.mix(compilerIdentity)
        h.mix(hostTarget)
        for o in outputOptions { h.mix(o) }
        return h.hex
    }

    // A digest of the language workspace's files (their paths and text).
    public static var languageSourcesDigest: String { planner.languageSourcesDigest }
}

// The runtime's C and asm sources, hashed once per process.
private let runtimeSourcesDigest: String = {
    var h = Hasher64()
    h.mix(EmbeddedSources.runtimeHeader)
    h.mix(EmbeddedSources.runtimeC)
    h.mix(EmbeddedSources.coreC)
    h.mix(EmbeddedSources.rtAsmArm64)   // the asm floor is archived in
    return h.hex
}()

// The language workspace's files, hashed once per process.
private let languageSourcesDigest: String = {
    var h = Hasher64()
    for f in LanguageWorkspace.files() { h.mix(f.path); h.mix(f.text) }
    return h.hex
}()

// FNV-1a, 64-bit: stable across runs and hosts. Each mixed string is length-prefixed, so ("ab", "c") and
// ("a", "bc") differ.
struct Hasher64 {
    private var h: UInt64 = 0xcbf29ce484222325
    mutating func mix(_ s: String) {
        mixBytes(String(s.utf8.count).utf8); mixBytes(":".utf8); mixBytes(s.utf8)
    }
    private mutating func mixBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { h ^= UInt64(b); h = h &* 0x00000100000001B3 }
    }
    var hex: String { String(h, radix: 16) }
}
