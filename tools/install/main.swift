import Foundation

guard let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] else {
    fputs("error: must be run via `bazel run //:install`\n", stderr)
    exit(1)
}

let src  = "\(workspace)/bazel-bin/nomu-cli/nomuc"
let dest = "\(workspace)/bin/nomuc"

let fm = FileManager.default
guard fm.fileExists(atPath: src) else {
    fputs("error: binary not found at \(src)\n", stderr)
    exit(1)
}

try? fm.createDirectory(atPath: "\(workspace)/bin", withIntermediateDirectories: true)
try? fm.removeItem(atPath: dest)
try fm.copyItem(atPath: src, toPath: dest)
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
print("installed: \(dest)")
