import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The build cache's store (task 209), split as Bazel's is: an action cache and a content-addressed store under one
// root.
//   - `ac/<key>`: an action result, the job's outputs by name with each one's size and content digest
//     (`ActionResult`), written whole by one atomic rename.
//   - `cas/<digest>`: an output's bytes, under the digest of its content, stored once however many results name it.
// A writer publishes a job's outputs from where it built them: each output enters the CAS (cloned, then renamed into
// place), then the action result is written. A reader looks up a key, checks every blob it names against its
// digest, and materializes the outputs at the paths the build reads them from, by cloning each blob (APFS
// `clonefile`: no copy and no extra space until a file changes; elsewhere a copy). Never a hard link: the compiler
// rewrites an object in place, which would change the blob. A result naming a missing or altered blob is discarded
// and the lookup misses, so a damaged entry is rebuilt and never served. A blob is hashed only once per write: the
// store writes a blob whole, by rename, and never again, so a blob whose size and modification time are those it
// had when last hashed is the one hashed. That time is this host's bookkeeping (`checked/<digest>@<time>`, an empty
// file), kept out of the action results, which hold only what the outputs' contents determine.
//
// Clearing, eviction and size limits belong to cache management (199); `leftovers()` lists what an interrupted
// write left behind.
public struct ArtifactStore {
    public let root: String

    public init(root: String) { self.root = root }

    var ac: String { root + "/ac" }
    var cas: String { root + "/cas" }
    var checked: String { root + "/checked" }

    // The action result at `key` when every blob it names is present and matches its digest. A result that names a
    // missing or altered blob, or cannot be read, is discarded and the lookup misses.
    public func lookup(_ key: String) -> ActionResult? {
        let path = ac + "/" + key
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let data = FileManager.default.contents(atPath: path),
           let result = try? JSONDecoder().decode(ActionResult.self, from: data),
           result.files.allSatisfy(blobMatches) {
            return result
        }
        discard(key)
        return nil
    }

    // Place a result's outputs in `dir`, each at its name, replacing what is there. A name may hold directories
    // (a bundle's files, `X.dSYM/Contents/…`); they are made as needed.
    public func materialize(_ result: ActionResult, into dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in result.files {
            let target = dir + "/" + f.path
            if f.path.contains("/") {
                try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
            }
            let tmp = target + ".materialize-" + Self.tag()
            guard Self.clone(blob(f.hash), to: tmp) else { throw StoreError.write(target) }
            guard rename(tmp, target) == 0 else {
                try? FileManager.default.removeItem(atPath: tmp)
                throw StoreError.write(target)
            }
        }
    }

    // Publish the outputs `files` (names within `dir`) as `key`'s result, with `inputs` (named key inputs, when
    // recorded). Each output enters the CAS, then the result is written whole; a concurrent writer of the same key
    // writes the same result.
    @discardableResult
    public func publish(_ key: String, outputsIn dir: String, files: [String],
                        inputs: [String: String] = [:]) throws -> ActionResult {
        let fm = FileManager.default
        try fm.createDirectory(atPath: ac, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cas, withIntermediateDirectories: true)
        var described: [ActionResult.File] = []
        for name in files.sorted() {
            let path = dir + "/" + name
            guard let data = fm.contents(atPath: path) else { throw StoreError.read(path) }
            let digest = ContentHash.of(data)
            let file = ActionResult.File(path: name, size: data.count, hash: digest)
            if !blobMatches(file) {
                let tmp = cas + "/" + Self.tmpPrefix + Self.tag()
                guard Self.clone(path, to: tmp) else { throw StoreError.write(blob(digest)) }
                guard rename(tmp, blob(digest)) == 0 else {
                    try? fm.removeItem(atPath: tmp)
                    throw StoreError.write(blob(digest))
                }
            }
            described.append(file)
            markChecked(digest)
        }
        let result = ActionResult(files: described, inputs: inputs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let tmp = ac + "/" + Self.tmpPrefix + Self.tag()
        try encoder.encode(result).write(to: URL(fileURLWithPath: tmp))
        guard rename(tmp, ac + "/" + key) == 0 else {
            try? fm.removeItem(atPath: tmp)
            throw StoreError.write(ac + "/" + key)
        }
        return result
    }

    // Remove the action result at `key`. Its blobs stay; other results may name them.
    public func discard(_ key: String) {
        try? FileManager.default.removeItem(atPath: ac + "/" + key)
    }

    // The path of a blob.
    public func blob(_ digest: String) -> String { cas + "/" + digest }

    // What interrupted writes left in the store: temporary files in `ac/` and `cas/`. Lookups never see them (keys
    // and digests never start with a dot); clearing them is 199's.
    public func leftovers() -> [String] {
        var out: [String] = []
        for dir in [ac, cas] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            out += names.filter { $0.hasPrefix(Self.tmpPrefix) }.map { dir + "/" + $0 }
        }
        return out.sorted()
    }

    // The blob a file names is present with the file's size and digest: taken as checked when its modification
    // time is the one it had when last hashed, else read and hashed.
    private func blobMatches(_ f: ActionResult.File) -> Bool {
        let path = blob(f.hash)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.size] as? Int == f.size,
              let modified = attrs[.modificationDate] as? Date else { return false }
        if FileManager.default.fileExists(atPath: checkMark(f.hash, modified)) { return true }
        guard let data = FileManager.default.contents(atPath: path), ContentHash.of(data) == f.hash else { return false }
        markChecked(f.hash)
        return true
    }

    // The mark that the blob `digest` was hashed while its modification time was `modified`.
    private func checkMark(_ digest: String, _ modified: Date) -> String {
        checked + "/" + digest + "@" + String(modified.timeIntervalSinceReferenceDate)
    }

    // Record the blob `digest` as hashed at its current modification time. Best-effort: without the mark, the next
    // lookup hashes it again.
    private func markChecked(_ digest: String) {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: blob(digest)))?[.modificationDate] as? Date
        else { return }
        try? FileManager.default.createDirectory(atPath: checked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: checkMark(digest, modified), contents: nil)
    }

    static let tmpPrefix = ".tmp-"

    static func tag() -> String { "\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ..< .max))" }

    // Clone `from` to the new path `to`: `clonefile` where the filesystem has it, else a copy.
    static func clone(_ from: String, to: String) -> Bool {
        #if canImport(Darwin)
        if clonefile(from, to, 0) == 0 { return true }
        #endif
        return (try? FileManager.default.copyItem(atPath: from, toPath: to)) != nil
    }
}

// A job's action result: its outputs by name, each with its size and content digest, and the inputs its key covers
// when they were recorded.
public struct ActionResult: Codable, Equatable {
    public struct File: Codable, Equatable {
        public let path: String
        public let size: Int
        public let hash: String
    }

    public let files: [File]
    public let inputs: [String: String]
}

public enum StoreError: Error, CustomStringConvertible {
    case read(String)
    case write(String)

    public var description: String {
        switch self {
        case .read(let path): return "cannot read '\(path)'"
        case .write(let path): return "cannot write '\(path)'"
        }
    }
}
