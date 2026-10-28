import Foundation

// The last-build record (task 212.2): each module's job key from the workspace's last build that compiled or
// served it, and each binary's link key (214), in `build/.nomu-last-build.json`. Under `--explain` it also holds the key's named inputs and the
// details below them (`JobKeyer.details`), as Bazel writes its execution log only on request; a build that does
// not ask keeps a module's recorded inputs while its key is unchanged and drops them when it changes.
struct BuildRecord: Codable {
    struct Entry: Codable {
        var key: String
        var inputs: [String: String]?
        var details: [String: String]?
    }

    var modules: [String: Entry] = [:]
    // By binary, workspace-relative.
    var links: [String: Entry] = [:]

    init() {}

    // A record written before links were recorded reads with none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modules = try c.decode([String: Entry].self, forKey: .modules)
        links = try c.decodeIfPresent([String: Entry].self, forKey: .links) ?? [:]
    }

    static let fileName = ".nomu-last-build.json"

    // The record under `buildRoot`, or an empty one.
    static func load(buildRoot: String) -> BuildRecord {
        guard let data = FileManager.default.contents(atPath: buildRoot + "/" + fileName),
              let record = try? JSONDecoder().decode(BuildRecord.self, from: data) else { return BuildRecord() }
        return record
    }

    // Write the record under `buildRoot`, whole, by rename. Best-effort.
    func save(buildRoot: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        let path = buildRoot + "/" + Self.fileName
        let tmp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }

    // Record a module's key; its inputs and details when `explain`, else the previous ones while the key holds.
    mutating func update(_ module: String, key: JobKey, details: [String: String]?, explain: Bool) {
        modules[module] = Self.entry(modules[module], key, details, explain)
    }

    // Record a binary's link key, as `update` records a module's.
    mutating func updateLink(_ binary: String, key: JobKey, explain: Bool) {
        links[binary] = Self.entry(links[binary], key, nil, explain)
    }

    private static func entry(_ previous: Entry?, _ key: JobKey, _ details: [String: String]?, _ explain: Bool) -> Entry {
        let kept = previous?.key == key.key
        return Entry(key: key.key, inputs: explain ? key.inputs : (kept ? previous?.inputs : nil),
                     details: explain ? details : (kept ? previous?.details : nil))
    }
}

// Why a module compiled, or a binary linked, compared with its entry in the last-build record (task 212.3).
enum CompileReason {
    static func of(previous: BuildRecord.Entry?, key: JobKey, details: [String: String]?) -> String {
        guard let previous else { return "no previous build recorded" }
        if previous.key == key.key { return "unchanged; its cache entry was missing or damaged" }
        guard let before = previous.inputs else {
            return "key changed (the last build did not record its inputs; build with --explain to record them)"
        }
        let old = JobKey(inputs: before)
        // A tool present on one side only entered or left the link with a setting (`dsymutil` with
        // `link.debug_info_storage`), which names the change.
        let changed = key.changes(from: old).filter { !$0.hasPrefix("tool:") || (before[$0] != nil && key.inputs[$0] != nil) }
        return changed.map { describe($0, old: before, new: key.inputs, oldDetails: previous.details, newDetails: details) }
            .joined(separator: "; ")
    }

    private static func describe(_ name: String, old: [String: String], new: [String: String],
                                 oldDetails: [String: String]?, newDetails: [String: String]?) -> String {
        func shown(_ path: String) -> String {
            // `/nomu-src/<workspace>/<path>` reads as the workspace-relative path.
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            return parts.first == "nomu-src" && parts.count > 2 ? parts.dropFirst(2).joined(separator: "/") : path
        }
        if name.hasPrefix("source:") { return "source changed: \(shown(String(name.dropFirst(7))))" }
        if name.hasPrefix("imports:") { return "imports changed: \(shown(String(name.dropFirst(8))))" }
        if name.hasPrefix("setting:") {
            return "setting \(name.dropFirst(8)): \(old[name] ?? "unset") → \(new[name] ?? "unset")"
        }
        if name.hasPrefix("object:") { return "object changed: \(name.dropFirst(7))" }
        if name.hasPrefix("tool:") {
            return "toolchain changed: \(name.dropFirst(5)) (\(old[name] ?? "unset") → \(new[name] ?? "unset"))"
        }
        if name.hasPrefix("runtime-global:") {
            return "runtime setting \(name.dropFirst(15)): \(old[name] ?? "unset") → \(new[name] ?? "unset")"
        }
        // A dependency's origin (`scope/name/path…`) as a module reads elsewhere (`scope.name:path`).
        func module(_ origin: Substring) -> String {
            let parts = origin.split(separator: "/")
            guard parts.count >= 2 else { return String(origin) }
            return "\(parts[0]).\(parts[1]):" + parts.dropFirst(2).joined(separator: "/")
        }
        if name.hasPrefix("dep:") {
            let rest = name.dropFirst(4)
            if rest.hasSuffix(".nmi") {
                return "dependency \(module(rest.dropLast(4))): " + interfaceChange(name, oldDetails, newDetails)
            }
            if rest.hasSuffix(".bir") { return "dependency \(module(rest.dropLast(4))): templates (.bir) changed" }
            if rest.hasSuffix(".package") { return "dependency \(module(rest.dropLast(8))): package changed" }
        }
        switch name {
        case "compiler": return "compiler changed"
        case "target", "target.cpu", "target.features": return "target changed (\(name))"
        case "files": return "file list changed"
        case "dependencies": return "dependency list changed"
        case "objects": return "object list changed"
        case "runtime-archive": return "runtime archive changed"
        case "config-record": return "configuration record changed"
        case "link.recipe": return "link recipe changed"
        case "link.debug-info-storage":
            return "setting link.debug_info_storage: \(old[name] ?? "unset") → \(new[name] ?? "unset")"
        default: return "\(name) changed"
        }
    }

    // What changed in a dependency's `.nmi`: its ABI (naming the declarations) or its perf facts (naming the
    // definitions), from the recorded details.
    private static func interfaceChange(_ input: String, _ old: [String: String]?, _ new: [String: String]?) -> String {
        guard let old, let new else { return "interface file changed" }
        func changed(_ prefix: String) -> [String] {
            let names = Set(old.keys.filter { $0.hasPrefix(prefix) }).union(new.keys.filter { $0.hasPrefix(prefix) })
            return names.filter { old[$0] != new[$0] }.map { String($0.dropFirst(prefix.count)) }.sorted()
        }
        var parts: [String] = []
        if old[input + ".abi"] != new[input + ".abi"] {
            let decls = changed(input + ".abi:")
            parts.append("interface (ABI) changed" + (decls.isEmpty ? "" : " (\(decls.joined(separator: ", ")))"))
        }
        if old[input + ".perf"] != new[input + ".perf"] {
            let defs = changed(input + ".perf:")
            parts.append("perf facts changed" + (defs.isEmpty ? "" : " (escape summary of \(defs.joined(separator: ", ")))"))
        }
        return parts.isEmpty ? "interface file changed" : parts.joined(separator: ", ")
    }
}
