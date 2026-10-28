import Foundation
import store
import buildinfo
import LLVMBridge
import planner
import interface

// A compile job's cache key (task 208): a hash over everything the compile reads, so equal keys mean equal
// outputs. Each input is kept by name beside the key, so two keys can be compared input by input to say why a
// job rebuilt (`changes(from:)`).
//
// The inputs: the compiler's identity; the target triple, CPU and CPU features; the job's identity, package,
// product and flags; its files in order, named by the paths debug info records (`DebugPaths`), and their
// contents; each file's imports; its dependencies in order, with each one's package and the bytes of the `.nmi`
// and `.bir` the compile reads; its settings; and the options that change an object (`subsetFuncs`,
// `compilingPrelude`). Where the sources and outputs live stays out (no input is an absolute path), as do the
// reported paths (diagnostics only) and the options that change no object (the dumps, `stopAt`, `emitJobs`), so
// a moved checkout or a switched dump does not rebuild. A job that stops before its object (`stopAt`, a
// terminal `--emit-nmi`) produces no entry to key.
public struct JobKey: Equatable {
    public let key: String
    public let inputs: [String: String]

    init(inputs: [String: String]) {
        var h = Hasher64()
        for name in inputs.keys.sorted() { h.mix(name); h.mix(inputs[name]!) }
        self.key = h.hex
        self.inputs = inputs
    }

    // The inputs whose values differ from `other`'s, by name, an input present in only one of them included.
    public func changes(from other: JobKey) -> [String] {
        Set(inputs.keys).union(other.inputs.keys).filter { inputs[$0] != other.inputs[$0] }.sorted()
    }
}

// Computes job keys for one process. It holds what every key shares (the compiler's identity and the target),
// and hashes each file once: a dependency's `.nmi` is hashed once however many dependents read it, and again
// only if its size or modification time changes.
public final class JobKeyer {
    let compilerIdentity: String
    let target: (triple: String, cpu: String, features: String)
    let featuresHash: String
    private var fileHashes: [String: (stamp: FileStamp, hash: String)] = [:]

    public init(compilerIdentity: String = BuildInfo.compilerIdentity,
                target: (triple: String, cpu: String, features: String) = objectTarget()) {
        self.compilerIdentity = compilerIdentity
        self.target = target
        self.featuresHash = ContentHash.of(Data(target.features.utf8))
    }

    public func key(_ job: CompileJob, options: EmitOptions) -> JobKey {
        // A file as debug info records it; its reported path, or itself, when the job gives no debug path.
        func recorded(_ path: String) -> String { job.debugPaths?[path] ?? job.reportedPaths?[path] ?? path }
        var inputs: [String: String] = [
            "compiler": compilerIdentity,
            "target": target.triple,
            "target.cpu": target.cpu,
            "target.features": featuresHash,
            "module": job.origin.joined(separator: "/"),
            "package": job.packageName,
            "package.key": job.packageKey,
            "product": job.product.rawValue,
            "product.public": String(job.isProduct),
            "white-box": String(job.whiteBox),
            "runtime-subset.membership": String(job.runtimeSubsetByMembership),
            "files": job.files.map(recorded).joined(separator: "\n"),
            "dependencies": job.dependencies.map { $0.origin.joined(separator: "/") }.joined(separator: "\n"),
            "option.runtime-subset": options.subsetFuncs.sorted().joined(separator: ","),
            "option.compiling-prelude": String(options.compilingPrelude),
        ]
        for path in job.files {
            inputs["source:" + recorded(path)] = sourceHash(path)
            inputs["imports:" + recorded(path)] = hash(canonical(job.imports[path] ?? []))
        }
        for d in job.dependencies {
            let origin = "dep:" + d.origin.joined(separator: "/")
            inputs[origin + ".package"] = d.packageKey
            inputs[origin + ".nmi"] = fileHash(d.interface)
            inputs[origin + ".bir"] = d.bir.map(fileHash) ?? "none"
        }
        for (name, value) in job.settings { inputs["setting:" + name] = value }
        return JobKey(inputs: inputs)
    }

    // What a job's dependency inputs hold, below the whole-file hashes the key uses (task 212.1): for each
    // dependency, its `.nmi`'s ABI and perf section hashes, a hash per ABI declaration (`dep:<o>.nmi.abi:<kind>
    // <name>`) and per perf definition (`dep:<o>.nmi.perf:<name>`). Explanation only: the key covers the bytes.
    public func details(_ job: CompileJob) -> [String: String] {
        var out: [String: String] = [:]
        for d in job.dependencies {
            let origin = "dep:" + d.origin.joined(separator: "/") + ".nmi"
            guard let text = try? String(contentsOfFile: d.interface, encoding: .utf8), let nmi = parseNMI(text) else {
                continue
            }
            out[origin + ".abi"] = String(nmi.abiHash, radix: 16)
            out[origin + ".perf"] = String(nmi.perfHash, radix: 16)
            for f in nmi.abi.functions { out[origin + ".abi:func \(f.name)"] = hash(canonicalJSON(f)) }
            for t in nmi.abi.types { out[origin + ".abi:type \(t.name)"] = hash(canonicalJSON(t)) }
            for e in nmi.abi.enums { out[origin + ".abi:enum \(e.name)"] = hash(canonicalJSON(e)) }
            for i in nmi.abi.interfaces { out[origin + ".abi:interface \(i.name)"] = hash(canonicalJSON(i)) }
            for (name, summary) in nmi.perf.escape { out[origin + ".perf:\(name)"] = hash(canonicalJSON(summary)) }
        }
        return out
    }

    private func canonicalJSON<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // A file's content hash, or `absent` when it cannot be read.
    func fileHash(_ path: String) -> String {
        guard let stamp = FileStamp(path) else { return "absent" }
        if let known = fileHashes[path], known.stamp == stamp { return known.hash }
        guard let data = FileManager.default.contents(atPath: path) else { return "absent" }
        let h = ContentHash.of(data)
        fileHashes[path] = (stamp, h)
        return h
    }

    // A source file's content hash; a language-workspace file is read from the sources the compiler carries.
    private func sourceHash(_ path: String) -> String {
        guard path.hasPrefix(LanguageWorkspace.root + "/") else { return fileHash(path) }
        if let known = fileHashes[path] { return known.hash }
        let h = readSource(path).map { ContentHash.of(Data($0.utf8)) } ?? "absent"
        fileHashes[path] = (FileStamp(size: 0, modified: 0), h)
        return h
    }

    private func hash(_ s: String) -> String { ContentHash.of(Data(s.utf8)) }

    private func canonical(_ imports: [CompileJob.Import]) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(imports)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// A file's size and modification time: a remembered hash stays valid while both are unchanged.
struct FileStamp: Equatable {
    let size: Int
    let modified: Double

    init(size: Int, modified: Double) { self.size = size; self.modified = modified }

    init?(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, let date = attrs[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = date.timeIntervalSinceReferenceDate
    }
}
