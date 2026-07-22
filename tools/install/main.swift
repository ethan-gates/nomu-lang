import Foundation

// Copies the freshly-built `nomuc` into `bin/nomuc`. The source binary's path is
// injected by bazel via `$(rootpath //compiler/nomu-cli:nomuc)` in `args` (see
// BUILD.bazel) and resolved from the runfiles tree — so it depends on the rule,
// not a hardcoded output path, and survives the target moving.

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment

guard let workspace = env["BUILD_WORKSPACE_DIRECTORY"] else {
    fputs("error: must be run via `bazel run //:install`\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count > 1 else {
    fputs("error: missing nomuc path argument (set via $(rootpath) in tools/install/BUILD.bazel)\n", stderr)
    exit(1)
}
let rel = CommandLine.arguments[1]

// Resolve the runfiles-relative path against the runfiles tree.
let cwd = fm.currentDirectoryPath
var candidates = [rel, "\(cwd)/\(rel)"]
if let rf = env["RUNFILES_DIR"] {
    candidates.append("\(rf)/\(rel)")
    candidates.append("\(rf)/_main/\(rel)")
}
guard let src = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
    fputs("error: could not locate the nomuc binary; tried:\n  \(candidates.joined(separator: "\n  "))\n", stderr)
    exit(1)
}

let dest = "\(workspace)/bin/nomuc"
try? fm.createDirectory(atPath: "\(workspace)/bin", withIntermediateDirectories: true)
try? fm.removeItem(atPath: dest)
// Read + write (rather than copyItem) to dereference the runfiles symlink and land a real file.
let data = try Data(contentsOf: URL(fileURLWithPath: src))
try data.write(to: URL(fileURLWithPath: dest))
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
print("installed: \(dest)")
