import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Live terminal output. On a TTY it keeps a single self-updating status line pinned at the bottom
// (the in-flight set + counts) while completed cases stream above it; off a TTY (pipe/CI) it stays
// silent so the caller's batch report drives output. All writes go through one FileHandle under a
// lock, so the status line and the streamed lines never corrupt each other.
final class StatusRenderer {
    let interactive: Bool
    private let lock = NSLock()
    private var status = ""

    init() { interactive = isatty(1) != 0 }

    private func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    private func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(1, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c), n > 0 { return n }
        return 100
    }

    private func fit(_ s: String) -> String {
        let w = terminalWidth()
        return s.count <= w ? s : String(s.prefix(max(0, w - 1))) + "…"
    }

    // A permanent line, printed above the live status.
    func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if interactive && !status.isEmpty { write("\r\u{1B}[2K") }   // clear the status line
        write(line + "\n")
        if interactive && !status.isEmpty { write("\r" + fit(status)) }
    }

    func setStatus(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        status = s
        if interactive { write("\r\u{1B}[2K" + fit(s)) }
    }

    func clearStatus() {
        lock.lock(); defer { lock.unlock() }
        if interactive && !status.isEmpty { write("\r\u{1B}[2K") }
        status = ""
    }
}

// Tracks pending → active → done across a phase and renders the status line. One instance drives
// both the compile phase and the run phase (beginPhase resets the counters and total).
final class Progress {
    private let renderer: StatusRenderer
    private let lock = NSLock()
    private var active: [String] = []
    private var label = ""
    private var total = 0
    private var done = 0, passed = 0, failed = 0, timedOut = 0

    var interactive: Bool { renderer.interactive }

    init(_ renderer: StatusRenderer) { self.renderer = renderer }

    func beginPhase(_ label: String, total: Int) {
        lock.lock()
        self.label = label; self.total = total
        active = []; done = 0; passed = 0; failed = 0; timedOut = 0
        lock.unlock()
        refresh()
    }

    func start(_ name: String) {
        lock.lock(); active.append(name); lock.unlock()
        refresh()
    }

    // Compile-phase completion (no pass/fail tally — failures surface per case in the run phase).
    func finishCompile(_ name: String) {
        lock.lock(); active.removeAll { $0 == name }; done += 1; lock.unlock()
        refresh()
    }

    func finishCase(_ name: String, _ status: Status) {
        lock.lock()
        active.removeAll { $0 == name }; done += 1
        switch status {
        case .pass:    passed += 1
        case .fail:    failed += 1
        case .timeout: timedOut += 1
        }
        lock.unlock()
        refresh()
    }

    func logLine(_ s: String) { renderer.log(s) }
    func endPhase() { renderer.clearStatus() }

    private func refresh() {
        guard renderer.interactive else { return }
        lock.lock()
        var s = "[\(done)/\(total)] \(label)"
        if !active.isEmpty { s += " · " + active.joined(separator: ", ") }
        if passed + failed + timedOut > 0 {
            s += "  ✓\(passed)"
            if failed > 0 { s += " ✗\(failed)" }
            if timedOut > 0 { s += " ⏱\(timedOut)" }
        }
        lock.unlock()
        renderer.setStatus(s)
    }
}
