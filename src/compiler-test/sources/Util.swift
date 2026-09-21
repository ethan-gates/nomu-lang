import Foundation

// Shared free helpers used across the tool.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(2)
}

func fmt(_ s: Double) -> String { String(format: "%.1fs", s) }

func mtime(_ path: String) -> Date {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let d = attrs[.modificationDate] as? Date else { return .distantPast }
    return d
}
