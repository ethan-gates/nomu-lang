import Foundation

// The reproducibility sweep (`--check-reproducible`, tasks 207.4 and 172.3): builds every selected compile
// configuration in two rounds and compares what the build cache stores, byte for byte. Each round builds from its
// own copy of the sources with its own host cache, the second at other, longer paths, so one comparison covers
// non-determinism (unordered iteration, timestamps), paths leaking into outputs, and incremental builds:
//   - round 1 builds the edited sources from clean;
//   - round 2 builds the sources as they are, then the edited ones, so its second build serves what the edit left
//     unchanged from the cache and compiles the rest, and must produce round 1's outputs.
// The edit appends an unused private function to one file of each of a fixture's library modules (each directory
// below the target holding sources): their objects change and their `.nmi` and `.bir` do not, so the modules
// above them come from the cache. Round 2's cache also holds the unedited build's entries; every entry of round 1
// must be in it, the same. Compared: every file under
// each workspace's `build/` and the host cache's action results and blobs (`ac/`, `cas/`): objects, `.nmi`,
// `.bir`, the runtime archive, binaries and their dSYMs, the last-build record. Left out: the workspace lock (its
// holder's pid) and each binary's `.lldbinit`, which maps to this machine's paths by design. Runs only when asked; it replaces the compile and run phases. `nomu build
// --verify-cache` checks a build against the cache; this sweep covers every fixture and varies the paths.
struct ReproducibilitySweep {
    let ctx: Ctx

    func run() -> Int32 {
        let fm = FileManager.default
        var seen = Set<String>()
        let configs = ctx.selectedCases().filter { $0.compile?.expectError == nil && seen.insert($0.compileKey).inserted }
        let base = NSTemporaryDirectory() + "nomu-reproducible-sweep-\(ProcessInfo.processInfo.processIdentifier)"
        let places = [(src: base + "/a/src", cache: base + "/a/cache"),
                      (src: base + "/elsewhere/round-b/src", cache: base + "/elsewhere/round-b/host-cache")]
        print("reproducible: \(configs.count) compile configurations, a clean and an incremental round under \(base)")

        var rounds: [[String: String]] = []
        for (i, place) in places.enumerated() {
            let start = Date()
            if let error = copyWorkspace(projectRoot: ctx.projectRoot, fixtures: configs.map(\.fixture), to: place.src) {
                die("reproducible: \(error)")
            }
            // Round 2 first builds the sources as they are, warming its cache.
            var steps = ["edited"]
            if i == 1 { steps.insert("unedited", at: 0) }
            var edited = 0
            for step in steps {
                if step == "edited" { edited = edit(fixtures: Set(configs.map(\.fixture)), src: place.src) }
                let failures = build(configs, src: place.src, cache: place.cache)
                if !failures.isEmpty {
                    for f in failures { print("FAIL build \(f.name): \(f.detail)") }
                    print("== reproducible: \(failures.count) builds of the \(step) sources failed in round \(i + 1); outputs kept under \(base) ==")
                    return 1
                }
            }
            rounds.append(outputs(src: place.src, cache: place.cache))
            print("round \(i + 1) (\(steps.joined(separator: ", then "))): \(rounds[i].count) outputs, \(edited) modules edited, in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }

        let (a, b) = (rounds[0], rounds[1])
        var differences: [String] = []
        for rel in Set(a.keys).union(b.keys).sorted() {
            // Round 2's cache also holds the unedited build's entries.
            guard let pa = a[rel] else { if !rel.hasPrefix("cache/") { differences.append("\(rel): only in round 2") }; continue }
            guard let pb = b[rel] else { differences.append("\(rel): only in round 1"); continue }
            if let d = firstDifference(pa, pb) { differences.append("\(rel): \(d)") }
        }
        for d in differences.prefix(50) { print("DIFF " + d) }
        if differences.count > 50 { print("… and \(differences.count - 50) more") }
        if differences.isEmpty {
            try? fm.removeItem(atPath: base)
            print("== reproducible: \(a.count) outputs identical across both rounds, the second incremental ==")
            return 0
        }
        print("== reproducible: \(differences.count) of \(Set(a.keys).union(b.keys).count) outputs differ; rounds kept under \(base) ==")
        return 1
    }

    // Append an unused private function to the first source file of each directory below each fixture's target
    // (its library modules). Returns how many were edited.
    private func edit(fixtures: Set<String>, src: String) -> Int {
        let fm = FileManager.default
        var edited = 0
        // A directory is edited once, though it may lie below more than one fixture's target.
        var done = Set<String>()
        for fixture in fixtures.sorted() where !(fixture as NSString).isAbsolutePath {
            let target = src + "/" + fixture
            var byDir: [String: [String]] = [:]
            for rel in (fm.enumerator(atPath: target)?.allObjects as? [String]) ?? []
                where rel.hasSuffix(".nomu") && rel.contains("/") && !rel.split(separator: "/").contains("build") {
                byDir[target + "/" + (rel as NSString).deletingLastPathComponent, default: []].append(target + "/" + rel)
            }
            for (dir, files) in byDir.sorted(by: { $0.key < $1.key }) where done.insert(dir).inserted {
                guard let first = files.sorted().first, let handle = FileHandle(forWritingAtPath: first) else { continue }
                handle.seekToEndOfFile()
                handle.write(Data("\nprivate fun incrementalProbe() -> Int {\n    return 1\n}\n".utf8))
                try? handle.close()
                edited += 1
            }
        }
        return edited
    }

    // Build each configuration under `src` with the host cache at `cache`: one fixture's configurations one
    // after another, fixtures in parallel. Returns the builds that failed.
    private func build(_ configs: [ResolvedCase], src: String, cache: String) -> [(name: String, detail: String)] {
        var byFixture: [String: [ResolvedCase]] = [:]
        var order: [String] = []
        for c in configs {
            if byFixture[c.fixture] == nil { order.append(c.fixture) }
            byFixture[c.fixture, default: []].append(c)
        }
        let lock = NSLock()
        var failures: [(name: String, detail: String)] = []
        WeightedGate(capacity: ctx.poolCapacity).dispatch(order) { fixture in
            for c in byFixture[fixture]! {
                let target = (fixture as NSString).isAbsolutePath ? fixture : src + "/" + fixture
                let r = runProcess(path: ctx.nomu, args: ["build"] + c.compileArgs + [target],
                                   env: c.compileEnv.merging(["NOMU_CACHE_DIR": cache]) { $1 }, timeout: c.compileTimeout)
                if !r.succeeded {
                    let line = r.stderr.split(separator: "\n").first { $0.contains("error") } ?? "exit \(r.exitCode ?? -1)"
                    lock.lock(); failures.append((c.name, String(line))); lock.unlock()
                }
            }
        }
        return failures
    }

    // The files a round produced, by path relative to the round's root: `ws/…` under each `build/`, `cache/…`
    // in the host cache's stores. The workspace lock and `.lldbinit` files are left out.
    private func outputs(src: String, cache: String) -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for case let rel as String in fm.enumerator(atPath: src)! {
            let parts = rel.split(separator: "/")
            guard let b = parts.firstIndex(of: "build"), b < parts.count - 1 else { continue }
            let path = src + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if rel.hasSuffix(".lldbinit") { continue }   // maps recorded paths to this machine's
            if rel.hasSuffix("/.nomu-lock") { continue }   // the workspace lock holds its holder's pid
            out["ws/" + rel] = path
        }
        for store in ["ac", "cas"] {
            guard let entries = fm.enumerator(atPath: cache + "/" + store) else { continue }
            for case let rel as String in entries {
                let path = cache + "/" + store + "/" + rel
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
                out["cache/" + store + "/" + rel] = path
            }
        }
        return out
    }

    // Where two files first differ, and their sizes; nil when they are identical.
    private func firstDifference(_ a: String, _ b: String) -> String? {
        guard let da = FileManager.default.contents(atPath: a), let db = FileManager.default.contents(atPath: b) else {
            return "unreadable"
        }
        if da == db { return nil }
        let ba = [UInt8](da), bb = [UInt8](db)
        let n = min(ba.count, bb.count)
        var i = 0
        while i < n && ba[i] == bb[i] { i += 1 }
        return "first difference at byte \(i), sizes \(da.count) and \(db.count)"
    }
}
