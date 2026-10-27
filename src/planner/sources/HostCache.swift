import embedded
import store

// The per-host cache (task 190, D4): language-level artifacts shared by every build on the host and kept
// across `git clean -dfx`, namely the runtime archive and the language workspace's modules. They live in one
// store under the root (task 209): an action cache (`ac/<key>`) and a content-addressed store (`cas/<digest>`);
// a build materializes each one's outputs under its `build/`.
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

    // The store under the cache root.
    public static func store(cacheRoot: String) -> ArtifactStore { ArtifactStore(root: cacheRoot) }

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

    // The language workspace's key: its sources, the compiler's identity (`BuildInfo.compilerIdentity`: its
    // commit plus any uncommitted changes; output and the `.nmi` / `.bir` formats change with the compiler), the host target,
    // and every option that changes the compiled output.
    public static func languageWorkspaceKey(compilerIdentity: String, outputOptions: [String]) -> String {
        var h = Hasher64()
        h.mix(languageSourcesDigest)
        h.mix(compilerIdentity)
        h.mix(hostTarget)
        for o in outputOptions { h.mix(o) }
        return h.hex
    }

    // One language-workspace module's key: the workspace's key and the module's path within it.
    public static func languageModuleKey(workspaceKey: String, path: [String]) -> String {
        var h = Hasher64()
        h.mix(workspaceKey)
        h.mix(String(path.count))
        for p in path { h.mix(p) }
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
