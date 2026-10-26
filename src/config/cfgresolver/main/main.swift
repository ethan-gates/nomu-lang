import Foundation
import cfgresolver

// Under `bazel run`, paths are the caller's, relative to the directory bazel was run from.
let cwd = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] ?? FileManager.default.currentDirectoryPath
let outcome = run(Array(CommandLine.arguments.dropFirst()), cwd: cwd)
FileHandle(fileDescriptor: outcome.status == 0 ? 1 : 2).write(Data(outcome.text.utf8))
exit(outcome.status)
