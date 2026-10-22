import Foundation
import yaml

// YAML throughput benchmark.
//
// Times each parse stage, reporting MB/s. With no files, it generates two large synthetic configuration
// documents: pure ASCII (the common case), and the same text with a non-ASCII character in every unit, which
// sends those words down the byte-by-byte path. Given files, it times each one, repeating it within a timed
// run until about `megabytes` are processed, since a single small file takes microseconds.
//
//   bazel run -c opt //src/yaml/bench:yamlbench -- [megabytes] [iters] [file ...]
//
// `megabytes` sizes each input (default 64); `iters` is the timed-run count (default 7, best reported to cut
// noise). A warm-up run precedes timing. Relative file paths resolve against the directory `bazel run` was
// invoked from.

let args = CommandLine.arguments
let megabytes = args.count > 1 ? Int(args[1]) ?? 64 : 64
let iters = args.count > 2 ? Int(args[2]) ?? 7 : 7
let files = Array(args.dropFirst(3))

// One unit is a representative slice of a configuration file: nested mappings, a sequence, comments, quoted
// and block scalars.
func unit(_ i: Int, accent: Bool) -> String {
    let name = accent ? "café_\(i)" : "cafe_\(i)"
    return """
    package_\(i):
      name: \(name)  # display name
      version: 1.2.\(i % 100)
      opt release:
        inline: true
        mono: all
      gc:
        nursery_reserve: 33554432
        collection_time debug: 60
      tags:
        - fast
        - "quoted value \(i)"
      notes: |
        first line of notes
        second line

    """
}

func document(bytes target: Int, accent: Bool) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(target + 512)
    var i = 0
    while out.count < target {
        out += unit(i, accent: accent).utf8
        i += 1
    }
    return out
}

func best(_ body: () -> Void) -> Duration {
    body()  // warm-up
    var fastest = Duration.seconds(1_000_000)
    let clock = ContinuousClock()
    for _ in 0..<iters {
        let elapsed = clock.measure(body)
        if elapsed < fastest { fastest = elapsed }
    }
    return fastest
}

// Decimal megabytes (10⁶ bytes), the unit simdjson's GB/s figures use. Input sizes stay in units of 2²⁰ bytes.
func megabytesPerSecond(_ byteCount: Int, _ d: Duration) -> Double {
    let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return Double(byteCount) / 1_000_000 / seconds
}

// Times each stage on `bytes`, `reps` times per timed run, and prints one line per stage. Each stage after
// the first is timed alone, on the previous stage's output.
func bench(_ label: String, _ bytes: [UInt8], reps: Int) {
    benchValidate(label, bytes, reps: reps, classifying: false)
    benchValidate(label, bytes, reps: reps, classifying: true)
    benchLex(label, bytes, reps: reps)
    benchStructure(label, bytes, reps: reps)
    benchResolve(label, bytes, reps: reps)
    benchParse(label, bytes, reps: reps)
}

// Times a whole parse into a `YAMLDocument`: stage 1 and the parser, or the diagnostic path after an error.
func benchParse(_ label: String, _ bytes: [UInt8], reps: Int) {
    var outcome = ""
    let elapsed = best {
        for _ in 0..<reps {
            do throws(YAMLErrors) {
                let doc = try YAMLDocument(parsing: bytes)
                outcome = "\(doc.root.count) root entries"
            } catch {
                outcome = "\(error.errors.count) errors"
            }
        }
    }
    let rate = megabytesPerSecond(bytes.count * reps, elapsed)
    print("parse     \(label.padding(14))  \(bytes.count) bytes  \(outcome)  \(rate.rounded(1)) MB/s")
}

func benchResolve(_ label: String, _ bytes: [UInt8], reps: Int) {
    let v = validate(bytes)
    guard let source = v.source else {
        print("resolve   \(label.padding(14))  skipped: input does not validate")
        return
    }
    let lexing = lexLines(bytes, source, errors: v.errors)
    let structure = buildStructure(bytes, lexing)
    var errorCount = 0
    let elapsed = bytes.withUnsafeBufferPointer { buffer in
        best {
            for _ in 0..<reps {
                errorCount = resolveScalars(buffer, lexing, structure).errors.errors.count
            }
        }
    }
    let rate = megabytesPerSecond(bytes.count * reps, elapsed)
    print("resolve   \(label.padding(14))  \(bytes.count) bytes  \(structure.arena.nodes.count) nodes  "
          + "\(errorCount) errors  \(rate.rounded(1)) MB/s")
}

func benchStructure(_ label: String, _ bytes: [UInt8], reps: Int) {
    let v = validate(bytes)
    guard let source = v.source else {
        print("structure \(label.padding(14))  skipped: input does not validate")
        return
    }
    let lexing = lexLines(bytes, source, errors: v.errors)
    var nodes = 0
    var errorCount = 0
    let elapsed = bytes.withUnsafeBufferPointer { buffer in
        best {
            for _ in 0..<reps {
                let s = buildStructure(buffer, lexing)
                nodes = s.arena.nodes.count
                errorCount = s.errors.errors.count
            }
        }
    }
    let rate = megabytesPerSecond(bytes.count * reps, elapsed)
    print("structure \(label.padding(14))  \(bytes.count) bytes  \(nodes) nodes  \(errorCount) errors  "
          + "\(rate.rounded(1)) MB/s")
}

func benchLex(_ label: String, _ bytes: [UInt8], reps: Int) {
    let name = "lex       "
    let v = validate(bytes, classifying: false)
    guard let source = v.source else {
        print("\(name)\(label.padding(14))  skipped: input does not validate")
        return
    }
    var errorCount = 0
    let elapsed = bytes.withUnsafeBufferPointer { buffer in
        best {
            for _ in 0..<reps {
                errorCount = lexLines(buffer, source, errors: v.errors).errors.errors.count
            }
        }
    }
    let rate = megabytesPerSecond(bytes.count * reps, elapsed)
    print("\(name)\(label.padding(14))  \(bytes.count) bytes  \(source.lines.lineCount) lines  "
          + "\(errorCount) errors  \(rate.rounded(1)) MB/s")
}

// With `classifying`, stage 1 also computes the parser's plain-stop masks.
func benchValidate(_ label: String, _ bytes: [UInt8], reps: Int, classifying: Bool) {
    let name = classifying ? "validate  " : "validate -"
    var lines = 0
    var errorCount = 0
    let elapsed = bytes.withUnsafeBufferPointer { buffer in
        best {
            for _ in 0..<reps {
                let v = validate(buffer, classifying: classifying)
                lines = v.source?.lines.lineCount ?? 0
                errorCount = v.errors.errors.count
            }
        }
    }
    let rate = megabytesPerSecond(bytes.count * reps, elapsed)
    print("\(name)\(label.padding(14))  \(bytes.count) bytes  \(lines) lines  \(errorCount) errors  "
          + "\(rate.rounded(1)) MB/s")
}

// The synthetic unit as Swift types, for timing `YAMLDecoder` against parsing alone.
struct Package: Decodable {
    struct Options: Decodable {
        var inline: Bool
        var mono: String
    }
    struct GC: Decodable {
        var nurseryReserve: Int
        var collectionTime: Int
        enum CodingKeys: String, CodingKey {
            case nurseryReserve = "nursery_reserve"
            case collectionTime = "collection_time debug"
        }
    }
    var name: String
    var version: String
    var options: Options
    var gc: GC
    var tags: [String]
    var notes: String
    enum CodingKeys: String, CodingKey {
        case name, version, gc, tags, notes
        case options = "opt release"
    }
}

// Times parsing alone, then parsing and decoding the whole document into `[String: Package]`.
func benchDecode(_ label: String, _ bytes: [UInt8], reps: Int) {
    var count = 0
    let parse = best { for _ in 0..<reps { count = (try? YAMLDocument(parsing: bytes))?.root.count ?? -1 } }
    let decode = best {
        for _ in 0..<reps { count = (try? YAMLDecoder().decode([String: Package].self, from: bytes))?.count ?? -1 }
    }
    print("decode    \(label.padding(14))  \(count) packages  parse \(megabytesPerSecond(bytes.count * reps, parse).rounded(1)) MB/s, "
          + "parse and decode \(megabytesPerSecond(bytes.count * reps, decode).rounded(1)) MB/s")
}

if files.isEmpty {
    for (label, accent) in [("ascii", false), ("non-ascii", true)] {
        let bytes = document(bytes: megabytes * 1_048_576, accent: accent)
        bench(label, bytes, reps: 1)
        benchDecode(label, bytes, reps: 1)
    }
} else {
    let base = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"]
        ?? FileManager.default.currentDirectoryPath
    for path in files {
        let full = path.hasPrefix("/") ? path : base + "/" + path
        guard let data = FileManager.default.contents(atPath: full) else {
            print("cannot read \(full)")
            continue
        }
        let bytes = [UInt8](data)
        let reps = max(1, megabytes * 1_048_576 / max(1, bytes.count))
        bench(URL(fileURLWithPath: path).lastPathComponent, bytes, reps: reps)
    }
}

extension String {
    func padding(_ width: Int) -> String { self + String(repeating: " ", count: max(0, width - count)) }
}

extension Double {
    func rounded(_ places: Int) -> String {
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        let whole = (self * scale).rounded() / scale
        return "\(whole)"
    }
}
