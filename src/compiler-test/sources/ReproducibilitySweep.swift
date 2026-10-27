import Foundation

// The reproducibility sweep (`--check-reproducible`, task 207.4): builds every selected compile configuration twice from
// clean, and compares what the build cache stores, byte for byte. Each round builds from its own copy of the
// sources with its own host cache, the second at other, longer paths, so one comparison covers both
// non-determinism (unordered iteration, timestamps) and paths leaking into outputs. Compared: every file under
// each workspace's `build/` and the host cache's action results and blobs (`ac/`, `cas/`): objects, `.nmi`,
// `.bir`, the runtime archive. Left out: binaries and their `.lldbinit`, which hold this machine's paths
// by design (207.6). Runs only when asked; it replaces the compile and run phases. `nomu build
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
        print("reproducible: \(configs.count) compile configurations, two clean rounds under \(base)")

        var rounds: [[String: String]] = []
        for (i, place) in places.enumerated() {
            let start = Date()
            if let error = copyWorkspace(projectRoot: ctx.projectRoot, fixtures: configs.map(\.fixture), to: place.src) {
                die("reproducible: \(error)")
            }
            let failures = build(configs, src: place.src, cache: place.cache)
            if !failures.isEmpty {
                for f in failures { print("FAIL build \(f.name): \(f.detail)") }
                print("== reproducible: \(failures.count) builds failed in round \(i + 1); outputs kept under \(base) ==")
                return 1
            }
            rounds.append(outputs(src: place.src, cache: place.cache))
            print("round \(i + 1): \(rounds[i].count) outputs in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }

        let (a, b) = (rounds[0], rounds[1])
        var differences: [String] = []
        for rel in Set(a.keys).union(b.keys).sorted() {
            guard let pa = a[rel] else { differences.append("\(rel): only in round 2"); continue }
            guard let pb = b[rel] else { differences.append("\(rel): only in round 1"); continue }
            if let d = firstDifference(pa, pb) { differences.append("\(rel): \(d)") }
        }
        for d in differences.prefix(50) { print("DIFF " + d) }
        if differences.count > 50 { print("… and \(differences.count - 50) more") }
        if differences.isEmpty {
            try? fm.removeItem(atPath: base)
            print("== reproducible: \(a.count) outputs identical across both rounds ==")
            return 0
        }
        print("== reproducible: \(differences.count) of \(Set(a.keys).union(b.keys).count) outputs differ; rounds kept under \(base) ==")
        return 1
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
    // in the host cache's stores. Binaries and their `.lldbinit` are left out.
    private func outputs(src: String, cache: String) -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        var lldbInits: [String] = []
        for case let rel as String in fm.enumerator(atPath: src)! {
            let parts = rel.split(separator: "/")
            guard let b = parts.firstIndex(of: "build"), b < parts.count - 1 else { continue }
            let path = src + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if rel.hasSuffix(".lldbinit") { lldbInits.append(rel); continue }
            out["ws/" + rel] = path
        }
        for rel in lldbInits { out["ws/" + String(rel.dropLast(".lldbinit".count))] = nil }
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
