import Foundation

// The workspace lock (task 210): one building `nomu` per workspace at a time, as Bazel keeps one command per
// output base. `build`, `run` and `test` hold it while they plan, compile and link; `nomu compile` never takes it,
// since a build system runs many compiles at once.
//
// The lock is an `flock` on `build/.nomu-lock`. The kernel releases it when its holder exits, however it exits,
// so a crashed or killed holder never leaves the workspace locked. The holder writes its pid into the file, and a
// second invocation prints that pid while it waits.
final class WorkspaceLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    static let fileName = ".nomu-lock"

    // Take the lock of the workspace at `root`, waiting while another invocation holds it. Nil (reported) when the
    // lock file cannot be opened.
    static func acquire(workspaceRoot root: String) -> WorkspaceLock? {
        let dir = root + "/build"
        Layout.clearFile(at: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + fileName
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            fputs("error: cannot open the workspace lock '\(path)': \(String(cString: strerror(errno)))\n", stderr)
            return nil
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fputs("nomu: waiting for another nomu (pid \(holder.map { $0.isEmpty ? "unknown" : $0 } ?? "unknown")) "
                  + "building in workspace '\(root)'\n", stderr)
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    fputs("error: cannot take the workspace lock '\(path)': \(String(cString: strerror(errno)))\n", stderr)
                    close(fd)
                    return nil
                }
            }
        }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
        return WorkspaceLock(fd: fd)
    }
}
