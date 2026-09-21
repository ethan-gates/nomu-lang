import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Result of one bounded subprocess run. `timedOut` is a first-class outcome: the
// timeout & hang handling in the harness design treats a wedged binary distinctly from
// a crash, so the runner can report TIMEOUT with the partial output captured up to the kill.
struct RunOutcome {
    var timedOut: Bool
    var exitCode: Int32?   // set when the process exited normally
    var signal: Int32?     // set when the process died from a signal
    var stdout: String
    var stderr: String
    var duration: Double   // wall-clock seconds

    var succeeded: Bool { !timedOut && exitCode == 0 }
}

// A mutable box so background reader/waiter closures can hand a value back without a
// data race on captured `var` storage.
private final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}

// Drain a pipe fd to EOF. Blocking; run on a background queue.
private func drain(_ fd: Int32) -> Data {
    var data = Data()
    let cap = 1 << 16
    let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 1)
    defer { buf.deallocate() }
    while true {
        let n = read(fd, buf, cap)
        if n > 0 {
            data.append(buf.assumingMemoryBound(to: UInt8.self), count: n)
        } else if n == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            break
        }
    }
    return data
}

// Launch `path args…` with `env` overlaid on the current environment, capturing stdout and
// stderr, bounded by `timeout` seconds.
//
// The child is made its own process-group leader (POSIX_SPAWN_SETPGROUP, pgroup 0). On timeout
// the whole group is SIGKILLed, so a wedged binary and every thread/child it spawned (carriers,
// the GC-sync thread) is reaped rather than orphaned — a bare per-process kill can leak the
// runtime's helper threads.
func runProcess(path: String, args: [String], env: [String: String], timeout: Double) -> RunOutcome {
    let start = Date()

    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    _ = pipe(&outPipe)
    _ = pipe(&errPipe)

    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    // stdin from /dev/null — fixtures never read it; avoids a stray inherited terminal.
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)   // 0 → new group, gid == child pid

    // Merge overrides onto the current environment; build a NULL-terminated char**.
    var merged = ProcessInfo.processInfo.environment
    for (k, v) in env { merged[k] = v }
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]

    var pid: pid_t = 0
    let rc = argv.withUnsafeBufferPointer { argvBuf in
        envp.withUnsafeBufferPointer { envpBuf in
            posix_spawn(&pid, path,
                        &fileActions, &attr,
                        argvBuf.baseAddress, envpBuf.baseAddress)
        }
    }

    for p in argv where p != nil { free(p) }
    for p in envp where p != nil { free(p) }
    posix_spawn_file_actions_destroy(&fileActions)
    posix_spawnattr_destroy(&attr)

    // Parent keeps only the read ends; closing the write ends lets the readers see EOF.
    close(outPipe[1])
    close(errPipe[1])

    if rc != 0 {
        close(outPipe[0]); close(errPipe[0])
        return RunOutcome(timedOut: false, exitCode: nil, signal: nil,
                          stdout: "", stderr: "spawn failed: \(String(cString: strerror(rc)))",
                          duration: Date().timeIntervalSince(start))
    }

    let outBox = Box(Data())
    let errBox = Box(Data())
    let readers = DispatchGroup()
    DispatchQueue.global().async(group: readers) { outBox.value = drain(outPipe[0]) }
    DispatchQueue.global().async(group: readers) { errBox.value = drain(errPipe[0]) }

    let statusBox = Box<Int32>(0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
        statusBox.value = st
        done.signal()
    }

    let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
    var timedOut = false
    if done.wait(timeout: deadline) == .timedOut {
        timedOut = true
        kill(-pid, SIGKILL)   // whole group
        done.wait()           // reap
    }
    readers.wait()            // readers hit EOF once the process (group) is gone
    close(outPipe[0]); close(errPipe[0])

    let status = statusBox.value
    var exitCode: Int32? = nil
    var signal: Int32? = nil
    // Decode wait status without the WIF* macros (unavailable in Swift).
    if status & 0x7f == 0 {
        exitCode = (status >> 8) & 0xff
    } else {
        signal = status & 0x7f
    }

    return RunOutcome(timedOut: timedOut,
                      exitCode: timedOut ? nil : exitCode,
                      signal: timedOut ? nil : signal,
                      stdout: String(decoding: outBox.value, as: UTF8.self),
                      stderr: String(decoding: errBox.value, as: UTF8.self),
                      duration: Date().timeIntervalSince(start))
}
