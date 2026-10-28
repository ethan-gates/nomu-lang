import Foundation
import store
import planner
import embedded

// Compile the runtime C sources to objects and archive them into `libnomuruntime.a` (the
// `backend.md` "runtime library" item, real for the LLVM path). Replaces the C backend's
// per-file `cc` co-compile. Returns the archive path, or nil on failure (message on stderr).
// The runtime `.a` is identical across programs (the C floor is embedded in nomuc), so it lives in the
// per-host cache (D4), under a key over the embedded runtime sources, the host architecture and
// `runtimeArchiveRecipe` and the identities of the tools and SDK it runs (`HostCache.runtimeArchiveKey`): editing
// the runtime rebuilds the compiler, which changes the key, and so do editing a command and a toolchain update. A cached archive is materialized into the build's `_runtime/`.
func cachedRuntimeArchive(_ job: RuntimeArchiveJob, store: ArtifactStore) -> String? {
    let name = (job.archive as NSString).lastPathComponent
    guard Layout.makeDirectory(job.outputDir, buildRoot: (job.outputDir as NSString).deletingLastPathComponent)
    else { return nil }
    if let cached = store.lookup(job.key) {   // hit
        do { try store.materialize(cached, into: job.outputDir); return job.archive } catch {
            fputs("error: \(error)\n", stderr)
            return nil
        }
    }

    // Miss: build in a scratch directory, publish the archive, and materialize it.
    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "nomu-runtime-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    guard (try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)) != nil else {
        fputs("error: cannot create '\(scratch)'\n", stderr)
        return nil
    }
    defer { try? fm.removeItem(atPath: scratch) }
    writeRuntimeSources(toDir: scratch)
    guard let built = buildRuntimeArchive(inDir: scratch) else { return nil }
    guard rename(built, scratch + "/" + name) == 0 else {
        fputs("error: cannot name the runtime archive: \(String(cString: strerror(errno)))\n", stderr)
        return nil
    }
    do {
        let published = try store.publish(job.key, outputsIn: scratch, files: [name])
        try store.materialize(published, into: job.outputDir)
    } catch {
        fputs("error: \(error)\n", stderr)
        return nil
    }
    return job.archive
}

// The commands that build the runtime archive, run in order in a directory holding the runtime sources
// (`writeRuntimeSources`). The plan hashes them into the archive's key, so changing one rebuilds the archive.
let runtimeArchiveRecipe: [[String]] = {
    var commands = [["/usr/bin/cc", "-w", "-I", ".", "-c", "runtime.c", "-o", "runtime.o"],
                    ["/usr/bin/cc", "-w", "-I", ".", "-c", "core.c", "-o", "core.o"]]
    var members = ["runtime.o", "core.o"]
    // The asm floor (task 128.2): assemble the per-arch `.s` (clang assembles `.s` directly) and archive
    // it beside the C objects, so its symbols (rtSwitch, rtFiberInit) resolve in every emitted binary.
    if HostCache.hostArch == "arm64" {
        commands.append(["/usr/bin/cc", "-c", "rtasm.s", "-o", "rtasm.o"])
        members.append("rtasm.o")
    }
    // `rcs` creates + indexes the archive; the directory is fresh, so no stale members accumulate.
    // `ZERO_AR_DATE` records zero for each member's time, so the archive is the same bytes on every build.
    commands.append(["/usr/bin/env", "ZERO_AR_DATE=1", "/usr/bin/ar", "rcs", "libnomuruntime.a"] + members)
    return commands
}()

func buildRuntimeArchive(inDir dir: String) -> String? {
    for command in runtimeArchiveRecipe {
        if runProcess(command[0], Array(command.dropFirst()), in: dir) != 0 {
            fputs("error: failed to build the runtime archive: \(command.joined(separator: " "))\n", stderr)
            return nil
        }
    }
    return dir + "/libnomuruntime.a"
}

// Write the embedded runtime/core C sources + ABI header into `dir` (M4.13).
func writeRuntimeSources(toDir dir: String) {
    var files = [
        ("runtime.h", EmbeddedSources.runtimeHeader),
        ("runtime.c", EmbeddedSources.runtimeC),
        ("core.c",    EmbeddedSources.coreC),
    ]
    // The asm floor (task 128.2), per-arch. arm64 only for now; x86-64 is deferred, and core.c's
    // self-test degrades to a stub there, so no `.s` is needed to link.
    if HostCache.hostArch == "arm64" { files.append(("rtasm.s", EmbeddedSources.rtAsmArm64)) }
    for (name, contents) in files {
        guard (try? contents.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)) != nil else {
            fputs("error: failed to write runtime source '\(name)'\n", stderr)
            exit(1)
        }
    }
}
