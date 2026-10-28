import Foundation

// Run `exe args` (in `dir` when given, with `environment` added to this process's), wait, and return its exit
// status (or 1 if it could not be launched).
func runProcess(_ exe: String, _ args: [String], in dir: String? = nil,
                        environment: [String: String] = [:]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
    if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fputs("error: failed to launch \(exe): \(error)\n", stderr)
        return 1
    }
    return p.terminationStatus
}

// Write a text artifact to `path` (or exit) and report its path to stderr — the "emit" style,
// consistent with --emit-c: outputs are build/ files, and the path report is a diagnostic (stderr), so
// stdout stays clean for a program's own output under `nomu run`.
func writeArtifact(_ contents: String, toFile path: String) {
    guard (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
        fputs("error: failed to write '\(path)'\n", stderr)
        exit(1)
    }
    fputs(path + "\n", stderr)
}
