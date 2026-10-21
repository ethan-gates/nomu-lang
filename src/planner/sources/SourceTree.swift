#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import scanner

// Where a workspace's files come from (task 190, D5). The planner reads only through this interface, so an
// on-disk workspace and the compiler's language workspace are planned the same way and nothing is
// written to disk to plan a build. Paths are absolute `/`-separated strings within the tree.
public protocol SourceTree: AnyObject {
    // A directory's entries, sorted by name; nil when `path` is not a readable directory.
    func list(_ path: String) -> [DirEntry]?
    // A file's bytes; nil when it cannot be read.
    func read(_ path: String) -> [UInt8]?
    // What is at `path`, following symlinks; nil when nothing is.
    func kind(of path: String) -> DirEntry.Kind?
    // The canonical form of a directory path (`.`/`..` and symlinks resolved), so two routes to one
    // directory compare equal; nil when it is not a directory.
    func canonical(_ path: String) -> String?
    // A source file's import block; nil when the file cannot be read.
    func scanImports(_ path: String) -> FileImports?
}

extension SourceTree {
    public func scanImports(_ path: String) -> FileImports? { read(path).map(ImportScanner.scan) }
}

public struct DirEntry: Equatable {
    public enum Kind: Equatable { case file, directory, symlink, other }
    public let name: String
    public let kind: Kind
    public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
}

// The real filesystem, through POSIX `opendir`/`readdir` (the entry kind comes with the listing, so no
// per-entry `stat`) and `open`/`read`.
public final class DiskTree: SourceTree {
    public init() {}

    public func list(_ path: String) -> [DirEntry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var entries: [DirEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let kind: DirEntry.Kind
            switch Int32(ent.pointee.d_type) {
            case Int32(DT_REG): kind = .file
            case Int32(DT_DIR): kind = .directory
            case Int32(DT_LNK): kind = Self.linkKind(path + "/" + name)
            case Int32(DT_UNKNOWN): kind = Self.statKind(path + "/" + name)
            default: kind = .other
            }
            entries.append(DirEntry(name: name, kind: kind))
        }
        return entries.sorted { $0.name < $1.name }
    }

    public func kind(of path: String) -> DirEntry.Kind? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Self.kind(st.st_mode)
    }

    // A symlink to a file counts as the file; any other symlink stays a symlink, so walks never follow one
    // into a directory (no cycles, no escaping the tree).
    private static func linkKind(_ path: String) -> DirEntry.Kind {
        var st = stat()
        guard stat(path, &st) == 0, kind(st.st_mode) == .file else { return .symlink }
        return .file
    }

    // For filesystems that report no entry kind.
    private static func statKind(_ path: String) -> DirEntry.Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .other }
        return kind(st.st_mode)
    }

    private static func kind(_ mode: mode_t) -> DirEntry.Kind {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    // Reads only the file's header (`ImportScanner.scan(path:)`).
    public func scanImports(_ path: String) -> FileImports? { try? ImportScanner.scan(path: path) }

    public func read(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return bytes }
            bytes.append(contentsOf: chunk[0 ..< n])
        }
    }

    public func canonical(_ path: String) -> String? {
        guard kind(of: path) == .directory, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buf, count)
    #else
    return Glibc.read(fd, buf, count)
    #endif
}

// A tree held in memory: a map from file path to contents, with directories implied by the paths. Backs the
// language workspace, and tests.
public final class MemoryTree: SourceTree {
    private var files: [String: [UInt8]] = [:]
    private var dirs: [String: Set<String>] = [:]          // directory → child names
    private var childDirs: Set<String> = []                // every directory path

    public init(_ files: [String: String] = [:]) {
        for (path, text) in files { add(path, text) }
    }

    public func add(_ path: String, _ text: String) {
        files[path] = Array(text.utf8)
        var child = path
        while let slash = child.lastIndex(of: "/"), slash != child.startIndex {
            let parent = String(child[..<slash])
            dirs[parent, default: []].insert(String(child[child.index(after: slash)...]))
            if child != path { childDirs.insert(child) }
            child = parent
        }
        if child != path { childDirs.insert(child) }
    }

    public func list(_ path: String) -> [DirEntry]? {
        guard let names = dirs[path] else { return nil }
        return names.sorted().map { name in
            let full = path + "/" + name
            return DirEntry(name: name, kind: childDirs.contains(full) ? .directory : .file)
        }
    }

    public func read(_ path: String) -> [UInt8]? { files[path] }

    public func kind(of path: String) -> DirEntry.Kind? {
        files[path] != nil ? .file : dirs[path] != nil ? .directory : nil
    }

    public func canonical(_ path: String) -> String? {
        var parts: [Substring] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        let p = (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
        return kind(of: p) == .directory ? p : nil
    }
}
