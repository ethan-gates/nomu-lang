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

// Bytes fed to a child's stdin through a pipe, written `delayMs` after the launch and then closed (so the
// child sees end of input). A delay lets a case observe a program waiting on input that has not arrived.
struct StdinFeed {
    var data: Data
    var delayMs: Int
}

// The host variables every child gets: the tool search path (`cc`, `nm`), the home directory (the host
// cache lives under it) and the temporary directory.
let hermeticBase: [String: String] = {
    let host = ProcessInfo.processInfo.environment
    var base: [String: String] = [:]
    for k in ["PATH", "HOME", "TMPDIR"] { if let v = host[k] { base[k] = v } }
    return base
}()

// Launch `path args…` with `env` overlaid on the hermetic base environment, capturing stdout and
// stderr, bounded by `timeout` seconds. stdin is /dev/null unless `stdin` supplies a feed.
//
// The child is made its own process-group leader (POSIX_SPAWN_SETPGROUP, pgroup 0). On timeout
// the whole group is SIGKILLed, so a wedged binary and every thread/child it spawned (carriers,
// the GC-sync thread) is reaped rather than orphaned — a bare per-process kill can leak the
// runtime's helper threads.
func runProcess(path: String, args: [String], env: [String: String], timeout: Double,
                stdin: StdinFeed? = nil) -> RunOutcome {
    let start = Date()

    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    _ = pipe(&outPipe)
    _ = pipe(&errPipe)
    var inPipe: [Int32] = [-1, -1]
    if stdin != nil {
        _ = pipe(&inPipe)
        #if canImport(Darwin)
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)   // a child that exits early must not SIGPIPE the harness
        #endif
    }

    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    if stdin != nil {
        posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, inPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, inPipe[1])
    } else {
        // stdin from /dev/null — avoids a stray inherited terminal.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    // Close every inherited fd except the three set up above: without this a child also inherits the pipe
    // ends of cases spawned concurrently, so their readers (and a fed stdin's end of input) wait for it.
    #if canImport(Darwin)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    #else
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    #endif
    posix_spawnattr_setpgroup(&attr, 0)   // 0 → new group, gid == child pid

    // A hermetic environment: the few variables a compile or run needs from the host, plus the case's
    // declared settings. Nothing else in the caller's environment (a stray `NOMU_*` in a developer's shell)
    // reaches the child. Build a NULL-terminated char**.
    var merged = hermeticBase
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
    if stdin != nil { close(inPipe[0]) }

    if rc != 0 {
        close(outPipe[0]); close(errPipe[0])
        if stdin != nil { close(inPipe[1]) }
        return RunOutcome(timedOut: false, exitCode: nil, signal: nil,
                          stdout: "", stderr: "spawn failed: \(String(cString: strerror(rc)))",
                          duration: Date().timeIntervalSince(start))
    }

    // Feed stdin on a background queue: wait the delay, write everything, close (end of input).
    if let feed = stdin {
        let fd = inPipe[1]
        DispatchQueue.global().async {
            if feed.delayMs > 0 { usleep(useconds_t(feed.delayMs) * 1000) }
            feed.data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(fd)
        }
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
