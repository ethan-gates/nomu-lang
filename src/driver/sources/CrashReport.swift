import Foundation

// A program's crash report or fiber dump (task 219, `runtime/fault.nomu`), symbolized against its binary: by
// `nomu run`, from the file `NOMU_CRASH_REPORT` names, and by `nomu tool symbolize`, from a report saved anywhere.
// The report carries raw addresses only, so binaries need no symbol names; the names and lines come from the
// binary's debug info:
// its `.dSYM` when the build gathered one (`link.debug_info_storage: dsym`), else one `dsymutil` makes now
// from the objects the binary names, workspace-relative, so it runs in the workspace. `atos` maps the
// addresses and `c++filt` demangles the v0 names. Every step is best-effort: a missing tool or file leaves
// the raw report the program already printed.
enum CrashReport {
    // A fresh path for the program's report file.
    static func reportPath() -> String {
        NSTemporaryDirectory() + "nomu-crash-\(getpid())-\(UUID().uuidString).txt"
    }

    // The symbolized backtrace for the report at `reportPath`, written by the program at `binary`, or nil when
    // there is no report or nothing could be symbolized. Removes the report file and any dSYM it made.
    static func symbolize(reportPath: String, binary: String) -> String? {
        defer { try? FileManager.default.removeItem(atPath: reportPath) }
        guard let text = try? String(contentsOfFile: reportPath, encoding: .utf8) else { return nil }
        return symbolize(text: text, binary: binary)
    }

    // The build ID a report names (its `image:` line), canonical upper-case with dashes, or nil when it has none.
    static func reportBuildID(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("nomu-crash: image: ") {
            let fields = line.split(separator: " ")
            if fields.count >= 3 { return String(fields[2]) }
        }
        return nil
    }

    // A binary's build ID (its LC_UUID), in the form a report prints it, or nil when it has none.
    static func binaryBuildID(_ binary: String) -> String? {
        guard let d = FileManager.default.contents(atPath: binary), d.count >= 32 else { return nil }
        func u32(_ o: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        guard u32(0) == 0xFEED_FACF else { return nil }
        var off = 32
        for _ in 0..<Int(u32(16)) {
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == 0x1B {
                let hex = d[(off + 8)..<(off + 24)].map { String(format: "%02X", $0) }.joined()
                var out = ""
                for (i, c) in hex.enumerated() {
                    if [8, 12, 16, 20].contains(i) { out.append("-") }
                    out.append(c)
                }
                return out
            }
            off += size
        }
        return nil
    }

    // The symbolized text of a report from the program at `binary`, or nil when nothing could be symbolized.
    static func symbolize(text: String, binary: String) -> String? {
        // The faulting thread's frames, then each fiber's under its header (a fiber dump).
        var base: String? = nil
        var groups: [(header: String, frames: [UInt64])] = [("nomu: crash backtrace", [])]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if line.hasPrefix("nomu-crash: image: "), fields.count >= 4 { base = String(fields[3]) }
            if line.hasPrefix("nomu-crash: fiber ") { groups.append((String(line.dropFirst("nomu-crash: ".count)), [])) }
            if line.hasPrefix("nomu-crash: frame "), fields.count >= 4, let a = UInt64(fields[3].dropFirst(2), radix: 16) {
                groups[groups.count - 1].frames.append(a)
            }
        }
        let frames = groups.flatMap(\.frames)
        guard let base, !frames.isEmpty else { return nil }

        guard let (dwarf, made) = debugInfo(for: binary) else { return nil }
        defer { if let made { try? FileManager.default.removeItem(atPath: made) } }
        guard let atos = Toolchain.resolveTool("atos") else { return nil }
        // Every frame but the faulting thread's first is a return address, the instruction after the call: look
        // up each less one, so a call that ends its function names that function.
        var lookups: [String] = []
        for (g, group) in groups.enumerated() {
            for (i, a) in group.frames.enumerated() { lookups.append("0x" + String(g == 0 && i == 0 ? a : a - 1, radix: 16)) }
        }
        guard let out = Toolchain.output(atos, ["-o", dwarf, "-l", base] + lookups) else { return nil }
        let names = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard names.count >= frames.count else { return nil }
        let demangled = demangle(Array(names.prefix(frames.count)))

        var lines: [String] = []
        var k = 0
        for group in groups where !group.frames.isEmpty || group.header != groups[0].header {
            if !lines.isEmpty { lines.append("") }
            lines.append(group.header)
            for (i, a) in group.frames.enumerated() {
                lines.append("  " + pad(String(i), 3) + " " + "0x" + String(a, radix: 16) + "  " + describe(demangled[k], binary: binary))
                k += 1
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // The DWARF file inside the binary's dSYM, and the dSYM's path when this call made it (to remove after).
    private static func debugInfo(for binary: String) -> (String, String?)? {
        let name = (binary as NSString).lastPathComponent
        let kept = binary + ".dSYM"
        if FileManager.default.fileExists(atPath: kept) { return (kept + "/Contents/Resources/DWARF/" + name, nil) }
        guard let dsymutil = Toolchain.resolveTool("dsymutil") else { return nil }
        let made = NSTemporaryDirectory() + "nomu-crash-\(getpid())-\(UUID().uuidString).dSYM"
        let workspace = binary.range(of: "/build/", options: .backwards).map { String(binary[..<$0.lowerBound]) }
        guard runQuietly(dsymutil, [binary, "-o", made], in: workspace) == 0 else { return nil }
        return (made + "/Contents/Resources/DWARF/" + name, made)
    }

    // `atos` lines with each v0 name demangled; lines `c++filt` cannot read pass through.
    private static func demangle(_ lines: [String]) -> [String] {
        guard let filt = Toolchain.resolveTool("c++filt") else { return lines }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: filt)
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        do { try p.run() } catch { return lines }
        // `atos` prints a name, then ` (in <binary>)`; only the name goes through.
        let heads = lines.map { $0.components(separatedBy: " (in ").first ?? $0 }
        input.fileHandleForWriting.write(Data((heads.joined(separator: "\n") + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let names = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard names.count >= lines.count else { return lines }
        return lines.enumerated().map { i, line in
            let rest = line.components(separatedBy: " (in ").dropFirst().joined(separator: " (in ")
            return rest.isEmpty ? names[i] : names[i] + " (in " + rest
        }
    }

    // One frame's text: `name (file:line)` from an `atos` line, without the `(in <binary>)` part and the
    // `+ offset` a frame without line info has; another image's frames, which `atos` leaves as an address,
    // show as such.
    private static func describe(_ line: String, binary: String) -> String {
        if line.hasPrefix("0x") { return "(outside \((binary as NSString).lastPathComponent))" }
        var s = line
        if let r = s.range(of: " \\(in [^)]*\\)", options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - s.count)) + s
    }

    private static func runQuietly(_ exe: String, _ args: [String], in dir: String?) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
