#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The import scanner (task 190, D5): reads the import block at the top of a Nomu source file and returns its
// imports as plain data, so the planner can build the module graph before any module compiles. It is
// independent of the compiler's lexer and parser — the full parse belongs to the compiler, on the other side
// of the job boundary — and recognizes only what may precede a file's first declaration: whitespace, `//`
// comments (any UTF-8), ASCII identifiers and `/`. Imports precede every declaration (the parser enforces it), so the scan
// stops at the first token that starts no import and never reads past it.
//
// The grammar mirrors the parser's import block (`Parser.parseImports`; modules.md §Imports):
//
//     import := ("public" | "test")? "import" ident ("/" ident)* ("as" ident)?
//
// where `public`/`test` count as a prefix only when `import` follows, and an `ident` is never a keyword. The
// conformance test holds the two in step. The scanner reports the first malformed import and stops; the
// compiler's own parse reports anything after it.

// A position in a source file: a byte offset plus its 1-based line and byte column (the `SourceMap`
// convention, so the planner renders scanner diagnostics the way the compiler renders its own).
public struct SourceLocation: Equatable, Hashable {
    public let offset: Int
    public let line: Int
    public let column: Int
    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset; self.line = line; self.column = column
    }
}

// One import as written. `root` is `pkg` (this package) or the leading package / workspace-alias name;
// `path` the `/`-separated components after it. `start` is the first token (`public`/`test`/`import`) and
// `end` the end of the last token (exclusive), matching the parser's `ImportDecl.span`.
public struct ScannedImport: Equatable {
    public enum Root: Equatable { case pkg; case package(String) }
    public let root: Root
    public let path: [String]
    public let alias: String?
    public let isPublic: Bool
    public let isTest: Bool
    public let start: SourceLocation
    public let end: SourceLocation
}

public struct ScanError: Equatable, Error {
    public let location: SourceLocation
    public let message: String
}

// A file's scan result: the well-formed imports before the first error, and that error if any.
public struct FileImports: Equatable {
    public var imports: [ScannedImport] = []
    public var errors: [ScanError] = []
}

// A file that could not be read (`errno` from `open`/`pread`).
public struct ScanIOError: Error, Equatable {
    public let path: String
    public let code: Int32
    public var message: String { "cannot read '\(path)': \(String(cString: strerror(code)))" }
}

public enum ImportScanner {
    // The first read; the scan grows it (doubling) only when the import block runs past it.
    static let initialReadSize = 4096

    // Scan a whole file's bytes.
    public static func scan(_ bytes: [UInt8]) -> FileImports {
        bytes.withUnsafeBufferPointer { buf in
            var s = Scan(buf, isComplete: true)
            return s.run()
        }
    }

    // Scan the file at `path`, reading only its header: one `pread` of `initialReadSize` bytes, extended
    // only when the scan reaches the end of what was read before the import block ends.
    public static func scan(path: String) throws -> FileImports {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ScanIOError(path: path, code: errno) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: initialReadSize)
        var filled = 0
        while true {
            // Fill the buffer from where the last read stopped; a short read means end of file.
            var atEOF = false
            while filled < buffer.count {
                let n = buffer.withUnsafeMutableBytes { raw in
                    pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ScanIOError(path: path, code: errno)
                }
                if n == 0 { atEOF = true; break }
                filled += n
            }
            let result: FileImports? = buffer.withUnsafeBufferPointer { buf in
                var s = Scan(UnsafeBufferPointer(rebasing: buf[0 ..< filled]), isComplete: atEOF)
                let r = s.run()
                return s.truncated ? nil : r
            }
            if let result { return result }
            buffer.append(contentsOf: repeatElement(0, count: buffer.count))   // double and read on
        }
    }
}

// One pass over a byte buffer. When `isComplete` is false the buffer is a prefix of the file: reaching its
// end before the import block ends sets `truncated`, and the caller re-scans a longer prefix.
private struct Scan {
    let src: UnsafeBufferPointer<UInt8>
    let isComplete: Bool
    var pos = 0
    var line = 1
    var lineStart = 0
    var truncated = false
    var result = FileImports()
    var failed: Bool { !result.errors.isEmpty }

    init(_ src: UnsafeBufferPointer<UInt8>, isComplete: Bool) {
        self.src = src; self.isComplete = isComplete
    }

    var location: SourceLocation { SourceLocation(offset: pos, line: line, column: pos - lineStart + 1) }

    // True at the end of the buffer. On a prefix this is not the end of the file, so the scan can't decide
    // and marks itself truncated.
    mutating func atEnd() -> Bool {
        if pos < src.count { return false }
        if !isComplete { truncated = true }
        return true
    }

    mutating func run() -> FileImports {
        while !truncated, scanImport() {}
        return result
    }

    // MARK: - Tokens

    // Skip whitespace (space, tab, LF, CR, VT, FF — the lexer's set) and `//` comments. A comment's UTF-8
    // never contains a 0x0A byte, so it ends only at its newline. A non-ASCII byte outside a comment is an
    // error here, as in the lexer: it appears only in comments and string literals.
    mutating func skipTrivia() {
        while !atEnd() {
            let c = src[pos]
            if c == 0x0A {
                pos += 1; line += 1; lineStart = pos
            } else if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C {
                pos += 1
            } else if c == 0x2F {
                // A lone `/` ends trivia; `//` runs to the end of the line. Deciding needs the next byte.
                if pos + 1 >= src.count {
                    if !isComplete { truncated = true }
                    return
                }
                guard src[pos + 1] == 0x2F else { return }
                pos += 2
                while !atEnd(), src[pos] != 0x0A { pos += 1 }
            } else {
                if c >= 0x80 { reportNonASCII() }
                return
            }
        }
    }

    // Record the lexer's error for the scalar at `pos`, reading its whole UTF-8 sequence.
    mutating func reportNonASCII() {
        let b = src[pos]
        let len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
        if pos + len > src.count, !isComplete { truncated = true; return }
        let scalar = text(pos ..< min(pos + len, src.count))
        result.errors.append(ScanError(location: location, message: "unexpected character '\(scalar)'"))
    }

    // Identifiers are ASCII: letters, digits and `_`, starting with a letter or `_`.
    static func isIdentStart(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == 0x5F
    }
    static func isIdentContinue(_ b: UInt8) -> Bool { isIdentStart(b) || (b >= 0x30 && b <= 0x39) }

    // The identifier at `pos` as a byte range, consuming it; nil (consuming nothing) when none starts here.
    mutating func identRange() -> Range<Int>? {
        guard !failed, !atEnd(), Self.isIdentStart(src[pos]) else { return nil }
        let start = pos
        pos += 1
        while !atEnd(), Self.isIdentContinue(src[pos]) { pos += 1 }
        if truncated { return nil }
        return start ..< pos
    }

    func text(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: src[r]), as: UTF8.self) }

    func equals(_ r: Range<Int>, _ word: StaticString) -> Bool {
        guard r.count == word.utf8CodeUnitCount else { return false }
        let w = word.utf8Start
        for i in 0 ..< r.count where src[r.lowerBound + i] != w[i] { return false }
        return true
    }

    // The lexer's keywords. A keyword never lexes as an identifier, so it can't be a path component or alias.
    static let keywords: Set<String> = [
        "on", "if", "in", "fun", "let", "var", "enum", "case", "else", "true", "class", "actor", "spawn",
        "while", "break", "false", "struct", "switch", "return", "static", "continue", "interface", "extension",
    ]

    // MARK: - Grammar

    // Scan one import at the current position. Returns false when the import block has ended: the next token
    // starts no import, the input ended, or an import was malformed (the error is recorded).
    mutating func scanImport() -> Bool {
        skipTrivia()
        if truncated || failed { return false }
        let start = location
        let save = (pos, line, lineStart)
        guard let first = identRange() else { return false }

        var isPublic = false, isTest = false
        if equals(first, "public") || equals(first, "test") {
            // A prefix only when `import` follows; otherwise this is a declaration (e.g. `public fun`).
            skipTrivia()
            guard let next = identRange(), equals(next, "import") else {
                (pos, line, lineStart) = save
                return false
            }
            isPublic = equals(first, "public"); isTest = !isPublic
        } else if !equals(first, "import") {
            (pos, line, lineStart) = save
            return false
        }

        guard let rootText = expectComponent(after: "'import'") else { return false }
        var path: [String] = []
        var end = location
        while true {
            skipTrivia()
            if truncated || failed { return false }
            guard !atEnd(), src[pos] == 0x2F else { break }
            pos += 1
            guard let c = expectComponent(after: "'/'") else { return false }
            path.append(c)
            end = location
        }

        var alias: String? = nil
        let beforeAs = (pos, line, lineStart)
        if let r = identRange(), equals(r, "as") {
            guard let a = expectComponent(after: "'as'") else { return false }
            alias = a
            end = location
        } else {
            if truncated { return false }
            (pos, line, lineStart) = beforeAs
        }

        let root: ScannedImport.Root = rootText == "pkg" ? .pkg : .package(rootText)
        result.imports.append(ScannedImport(root: root, path: path, alias: alias, isPublic: isPublic,
                                            isTest: isTest, start: start, end: end))
        return true
    }

    // An identifier (never a keyword) after `what`, or nil with an error recorded. Called right after `what` is
    // consumed; an error is reported there, just past `what` on the import's own line (the parser's
    // `expectImportName` reports the same position and wording).
    mutating func expectComponent(after what: String) -> String? {
        let at = location
        skipTrivia()
        if truncated || failed { return nil }
        guard let r = identRange() else {
            if !truncated { result.errors.append(ScanError(location: at, message: "expected a name after \(what)")) }
            return nil
        }
        let name = text(r)
        guard !Self.keywords.contains(name) else {
            result.errors.append(ScanError(location: at, message: "expected a name after \(what), got keyword '\(name)'"))
            return nil
        }
        return name
    }
}
