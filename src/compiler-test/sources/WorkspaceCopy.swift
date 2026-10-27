import Foundation

// Copy the workspace marker, the configuration file and each fixture's top-level directory (`examples/`,
// `tests/`) from `projectRoot` into `dest`, leaving out every `build/`. A copy is a workspace of its own: its own
// `build/` and its own lock (task 210). Returns an error message, or nil.
func copyWorkspace(projectRoot: String, fixtures: [String], to dest: String) -> String? {
    let fm = FileManager.default
    var tops = Set(["nomu.yaml", "cfg.yaml"])
    for f in fixtures where !(f as NSString).isAbsolutePath { tops.insert(String(f.split(separator: "/").first!)) }
    for top in tops.sorted() {
        let from = projectRoot + "/" + top
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from, isDirectory: &isDir) else { continue }
        let files = isDir.boolValue
            ? (fm.enumerator(atPath: from)?.compactMap { $0 as? String } ?? [])
                .filter { !$0.split(separator: "/").contains("build") }.map { top + "/" + $0 }
            : [top]
        for rel in files {
            var fileIsDir: ObjCBool = false
            guard fm.fileExists(atPath: projectRoot + "/" + rel, isDirectory: &fileIsDir), !fileIsDir.boolValue
            else { continue }
            let to = dest + "/" + rel
            do {
                try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: projectRoot + "/" + rel, toPath: to)
            } catch {
                return "cannot copy '\(rel)' to '\(dest)': \(error)"
            }
        }
    }
    return nil
}

// Workspace copies for the compile phase's lanes. Every fixture lives in the one project workspace, and a
// workspace builds one invocation at a time (task 210), so each lane builds in a copy of its own; the copies share
// the host cache, and their outputs match the project's (207.3). A lane is made the first time it is needed and
// reused after; `removeAll` deletes them.
final class WorkspaceLanes {
    private let projectRoot: String
    private let fixtures: [String]
    private let base = NSTemporaryDirectory() + "nomu-suite-lanes-\(ProcessInfo.processInfo.processIdentifier)"
    private let cond = NSCondition()
    private var free: [String] = []
    private var made = 0

    init(projectRoot: String, fixtures: [String]) {
        self.projectRoot = projectRoot
        self.fixtures = fixtures
    }

    // A lane's workspace root, made if every existing lane is in use.
    func take() -> String {
        cond.lock()
        if let lane = free.popLast() { cond.unlock(); return lane }
        made += 1
        let lane = base + "/lane\(made)"
        cond.unlock()
        if let error = copyWorkspace(projectRoot: projectRoot, fixtures: fixtures, to: lane) { die("compile lanes: \(error)") }
        return lane
    }

    func give(_ lane: String) {
        cond.lock(); free.append(lane); cond.unlock()
    }

    func removeAll() { try? FileManager.default.removeItem(atPath: base) }
}
