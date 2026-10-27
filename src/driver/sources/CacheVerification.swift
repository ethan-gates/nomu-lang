import Foundation
import store

// `nomu build --verify-cache` (task 207.5): every job compiles once, nothing is taken from the host cache, and a
// job whose key already has an entry is compared with it. An entry that differs from the fresh compile means its
// key leaves out an input that changed (or the compile is not reproducible), so the error lists the inputs the key
// covers: the place to start is outside that list. They are this compile's inputs, which are the entry's, since
// the two share a key. The entry is left as it is, for inspection.
final class CacheVerification {
    private(set) var failures: [String] = []

    // Compare the outputs `names` a fresh compile wrote in `fresh` with the cached result at their key, whose named
    // inputs are `inputs`.
    func compare(module: String, fresh: String, names: [String], cached: ActionResult, store: ArtifactStore,
                 inputs: [String: String]) {
        guard let difference = firstDifference(fresh, names, cached, store) else { return }
        var report = "\(module): differs from its cache entry (\(difference)); the key covers:"
        for (name, value) in inputs.sorted(by: { $0.key < $1.key }) { report += "\n    \(name) = \(value)" }
        failures.append(report)
        fputs("error: --verify-cache: \(report)\n", stderr)
    }

    // The first output that differs between a fresh compile and a cached result, or is in only one of them.
    private func firstDifference(_ fresh: String, _ names: [String], _ cached: ActionResult,
                                 _ store: ArtifactStore) -> String? {
        let fm = FileManager.default
        let blobs = Dictionary(uniqueKeysWithValues: cached.files.map { ($0.path, store.blob($0.hash)) })
        for name in Set(names).union(blobs.keys).sorted() {
            guard let a = fm.contents(atPath: fresh + "/" + name) else { return "\(name) only in the entry" }
            guard let blob = blobs[name], let b = fm.contents(atPath: blob) else {
                return "\(name) only in the fresh compile"
            }
            if a == b { continue }
            let ba = [UInt8](a), bb = [UInt8](b)
            var i = 0
            while i < min(ba.count, bb.count) && ba[i] == bb[i] { i += 1 }
            return "\(name) at byte \(i)"
        }
        return nil
    }
}
