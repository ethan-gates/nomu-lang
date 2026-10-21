import Foundation

// The GC frame index (task 195): a sorted table of every function with GC stackmap records, built after the
// link and written into the binary, so both stack walkers binary-search it with no setup at run time.
//
// Every object carries its own `__llvm_stackmaps` blob and the linker places them back to back; it relocates
// their function addresses but drops nothing, so a weak function emitted into several objects (a generic
// specialized in two consumers) leaves one blob entry per copy, all bound to the copy the linker kept. The
// link map names the object of every blob and of every kept definition, which tells the copies apart.
//
// The link reserves a zero-filled `__DATA_CONST,__nomu_frameidx` section (`-sectcreate`); afterwards the
// index is written into it and the linker's signature is redone over the patched pages (CodeSignature.swift).
//
// Layout, at the first 8-aligned address in the section (`-sectcreate` gives the section byte alignment):
//   header    { u32 magic 'NFIX', u32 version, u64 count }
//   entries   { i64 function address − stackmaps section start, u32 record offset into the stackmaps section,
//               u32 record count, u32 stack size (UINT32_MAX: dynamic), u32 blob ordinal }, sorted by
//               function address
//   directory { u64 blob count, then per blob i64 its object's `__nomu_shape_table` − stackmaps section
//               start (0: none) }
// A record's shape ordinals are numbered per object, so they resolve in the shape table of the object its
// blob came from (`{ count, then a descriptor type-id per ordinal }`); the step checks every ordinal against
// it. Positions are relative to the stackmaps section, so the index holds no pointers to relocate (the image
// slides as a whole). Reader: `rtFrameLookup` (runtime.nomu); `nomu_gc_frameidx_check` (runtime.c) aborts at
// startup when the index is missing.
enum FrameIndex {
    static let segment = "__DATA_CONST"
    static let section = "__nomu_frameidx"
    static let magic: UInt32 = 0x5849_464E   // "NFIX"
    static let version: UInt32 = 2
    static let headerSize = 16
    static let entrySize = 24

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // Bytes to reserve for the index over these objects: the alignment slack, the header, one entry per
    // stackmap function record in their blobs (an upper bound: folded copies leave slack), and the blob
    // directory.
    static func reserveSize(objects: [String]) throws -> Int {
        var functions = 0, blobs = 0
        for path in objects {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw Failure("cannot read '\(path)'")
            }
            let file = try MachO(data)
            if let s = file.section("__LLVM_STACKMAPS", "__llvm_stackmaps") ?? file.section("", "__llvm_stackmaps") {
                guard s.size >= 16 else { continue }
                let blob = Int(s.fileOffset)
                guard data[blob] == 3 else { throw Failure("'\(path)': unsupported stackmap version \(data[blob])") }
                functions += Int(data.u32(blob + 4))
                blobs += 1
            }
        }
        return 8 + headerSize + functions * entrySize + 8 + blobs * 8
    }

    // Build the index for a linked binary from its stackmaps and link map, and write it into the reserved
    // section in place. Returns the entry count and the number of folded copies dropped.
    @discardableResult
    static func write(binary: String, linkMap: String) throws -> (entries: Int, dropped: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: binary), options: .alwaysMapped) else {
            throw Failure("cannot read '\(binary)'")
        }
        let file = try MachO(data)
        guard let reserved = file.section(segment, section) else {
            throw Failure("'\(binary)' has no \(segment),\(section) section")
        }
        guard let sm = file.section("__LLVM_STACKMAPS", "__llvm_stackmaps") else {
            // A program with no statepoints: an empty index.
            try writeIndex(Data(), into: reserved, binary: binary)
            return (0, 0)
        }
        let fixups = try ChainedFixups(file: file, data: data)

        // Every blob's function entries, with the function each one's address field targets.
        struct Function { let blob: Int; let target: ChainedFixups.Target; let stack: UInt64; let nrec: UInt64; let recOff: Int }
        var functions: [Function] = []
        let start = Int(sm.fileOffset), end = start + Int(sm.size)
        var p = start, blobs = 0
        while p < end {
            guard data[p] == 3 else { throw Failure("stackmap blob \(blobs) at +\(p - start): version \(data[p]), expected 3") }
            let nfuncs = Int(data.u32(p + 4)), nconsts = Int(data.u32(p + 8))
            var r = p + 16 + nfuncs * 24 + nconsts * 8
            for fi in 0..<nfuncs {
                let fe = p + 16 + fi * 24
                let nrec = data.u64(fe + 16), recStart = r
                for _ in 0..<nrec { r += recordSize(data, at: r) }
                functions.append(Function(blob: blobs, target: try fixups.target(atFileOffset: fe), stack: data.u64(fe + 8),
                                          nrec: nrec, recOff: recStart - start))
            }
            p = r
            blobs += 1
        }
        guard p == end else { throw Failure("stackmap blobs end at +\(p - start), section size \(end - start)") }

        // Addresses: a rebase holds its target; a bind names a global, which `-x` keeps in the symbol table.
        var bound: Set<String> = []
        for f in functions { if case .bind(let n) = f.target { bound.insert(n) } }
        let globals = bound.isEmpty ? [:] : file.globals(named: bound)
        var addresses: [UInt64] = []
        addresses.reserveCapacity(functions.count)
        for f in functions {
            switch f.target {
            case .rebase(let a): addresses.append(a)
            case .bind(let n):
                guard let a = globals[n] else { throw Failure("stackmap function '\(n)' is not defined in the binary") }
                addresses.append(a)
            }
        }
        let map = try LinkMap(path: linkMap, addresses: Set(addresses))
        guard map.blobs.count == blobs else {
            throw Failure("\(blobs) stackmap blobs in the section, \(map.blobs.count) in the link map")
        }
        var blobStart = start
        for (i, b) in map.blobs.enumerated() {
            guard b.address == sm.address + UInt64(blobStart - start) else {
                throw Failure("stackmap blob \(i) at +\(blobStart - start) has no matching __LLVM_StackMaps in the link map")
            }
            blobStart += Int(b.size)
        }

        // Each blob's object's shape table, and its ordinal count.
        var tables: [Int64] = [], tableCounts: [UInt64?] = []
        for b in map.blobs {
            if let t = map.shapeTables[b.file], let off = file.fileOffset(ofAddress: t) {
                tables.append(Int64(bitPattern: t &- sm.address)); tableCounts.append(data.u64(off))
            } else {
                tables.append(0); tableCounts.append(nil)
            }
        }

        var entries: [(func: Int64, recOff: UInt32, nrec: UInt32, stack: UInt32, blob: UInt32)] = []
        entries.reserveCapacity(functions.count)
        var dropped = 0
        for (f, address) in zip(functions, addresses) {
            let owners = map.filesDefining(address: address)
            guard !owners.isEmpty else {
                throw Failure("stackmap function at 0x\(String(address, radix: 16)) is not a symbol in the link map")
            }
            // A weak copy the linker folded into another object's definition: its records describe code that
            // is not in the binary.
            guard owners.contains(map.blobs[f.blob].file) else { dropped += 1; continue }
            // LLVM records UINT64_MAX for a frame of dynamic size (a runtime-sized alloca, as an erased generic's
            // buffer); the index keeps it as UINT32_MAX.
            let stack = f.stack == UInt64.max ? UInt32.max : UInt32(exactly: f.stack)
            guard let stack, stack != UInt32.max || f.stack == UInt64.max, f.nrec <= UInt64(UInt32.max) else {
                throw Failure("stackmap function at 0x\(String(address, radix: 16)): stack size or record count out of range")
            }
            // Every shape ordinal in the records must name an entry of the blob's object's table.
            var r = start + f.recOff
            for _ in 0..<f.nrec {
                let nloc = Int(data.u16(r + 14))
                let numDeopt = nloc > 2 ? Int(data.u32(r + 16 + 2 * 12 + 8)) : 0
                var li = 3
                while li + 1 < 3 + numDeopt {
                    let c = r + 16 + li * 12
                    if data[c] == 4, data[c + 12] == 2 {   // (Constant ordinal, Direct slot)
                        let ordinal = UInt64(data.u32(c + 8))
                        guard let n = tableCounts[f.blob], ordinal < n else {
                            throw Failure("stackmap function at 0x\(String(address, radix: 16)): shape ordinal \(ordinal) has no entry in its object's shape table")
                        }
                    }
                    li += 2
                }
                r += recordSize(data, at: r)
            }
            entries.append((Int64(bitPattern: address &- sm.address), UInt32(f.recOff), UInt32(f.nrec), stack,
                            UInt32(f.blob)))
        }
        // Objects arrive in address order, so the entries are nearly sorted.
        entries.sort { $0.func < $1.func }
        for i in entries.indices.dropFirst() where entries[i].func == entries[i - 1].func {
            throw Failure("two kept stackmap entries for the function at 0x\(String(UInt64(bitPattern: entries[i].func) &+ sm.address, radix: 16))")
        }
        var bytes = Data(capacity: headerSize + entries.count * entrySize)
        bytes.appendLE(magic); bytes.appendLE(version); bytes.appendLE(UInt64(entries.count))
        for e in entries {
            bytes.appendLE(UInt64(bitPattern: e.func)); bytes.appendLE(e.recOff); bytes.appendLE(e.nrec)
            bytes.appendLE(e.stack); bytes.appendLE(e.blob)
        }
        bytes.appendLE(UInt64(tables.count))
        for t in tables { bytes.appendLE(UInt64(bitPattern: t)) }
        try writeIndex(bytes, into: reserved, binary: binary)
        return (entries.count, dropped)
    }

    // Write the index at the section's first 8-aligned address, in place in the file.
    private static func writeIndex(_ bytes: Data, into s: MachO.Section, binary: String) throws {
        let pad = Int((8 - s.address % 8) % 8)
        var index = bytes
        if index.isEmpty {   // no entries, no blobs
            index.appendLE(magic); index.appendLE(version); index.appendLE(UInt64(0)); index.appendLE(UInt64(0))
        }
        guard pad + index.count <= Int(s.size) else {
            throw Failure("frame index needs \(pad + index.count) bytes, \(s.size) reserved")
        }
        guard let h = FileHandle(forWritingAtPath: binary) else { throw Failure("cannot write '\(binary)'") }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(s.fileOffset) + UInt64(pad))
            try h.write(contentsOf: index)
        } catch {
            throw Failure("cannot write '\(binary)': \(error)")
        }
    }

    // A stackmap v3 record's byte length: header, locations, padding, live-outs, padding.
    static func recordSize(_ d: Data, at r: Int) -> Int {
        let nloc = Int(d.u16(r + 14))
        let locEnd = (16 + nloc * 12 + 7) & ~7
        let nlive = Int(d.u16(r + locEnd))
        return (locEnd + 2 + nlive * 4 + 7) & ~7
    }
}

// The parts of a 64-bit Mach-O file the frame index reads: sections and the chained-fixups payload.
struct MachO {
    struct Section { let segment: String; let name: String; let address: UInt64; let size: UInt64; let fileOffset: UInt32 }
    struct Segment { let name: String; let vmaddr: UInt64; let vmsize: UInt64; let fileOffset: UInt64; let fileSize: UInt64 }
    let sections: [Section]
    let segments: [Segment]
    let chainedFixups: (offset: Int, size: Int)?
    private let data: Data
    private let symtab: (symoff: Int, nsyms: Int, stroff: Int)?

    init(_ d: Data) throws {
        guard d.count >= 32, d.u32(0) == 0xFEED_FACF else { throw FrameIndex.Failure("not a 64-bit Mach-O file") }
        let ncmds = Int(d.u32(16))
        var off = 32
        var sections: [Section] = [], segments: [Segment] = []
        var fixups: (Int, Int)?
        var symtab: (Int, Int, Int)?
        for _ in 0..<ncmds {
            let cmd = d.u32(off), size = Int(d.u32(off + 4))
            if cmd == 0x19 {   // LC_SEGMENT_64
                let seg = d.cString(off + 8, 16)
                segments.append(Segment(name: seg, vmaddr: d.u64(off + 24), vmsize: d.u64(off + 32),
                                        fileOffset: d.u64(off + 40), fileSize: d.u64(off + 48)))
                var s = off + 72
                for _ in 0..<Int(d.u32(off + 64)) {
                    sections.append(Section(segment: d.cString(s + 16, 16), name: d.cString(s, 16),
                                            address: d.u64(s + 32), size: d.u64(s + 40), fileOffset: d.u32(s + 48)))
                    s += 80
                }
            } else if cmd == 0x8000_0034 {   // LC_DYLD_CHAINED_FIXUPS
                fixups = (Int(d.u32(off + 8)), Int(d.u32(off + 12)))
            } else if cmd == 0x2 {           // LC_SYMTAB
                symtab = (Int(d.u32(off + 8)), Int(d.u32(off + 12)), Int(d.u32(off + 16)))
            }
            off += size
        }
        self.sections = sections
        self.segments = segments
        self.chainedFixups = fixups
        self.data = d
        self.symtab = symtab
    }

    // The addresses of these defined external symbols (nlist_64 { strx, type, sect, desc, value }).
    func globals(named names: Set<String>) -> [String: UInt64] {
        guard let (symoff, nsyms, stroff) = symtab else { return [:] }
        var out: [String: UInt64] = [:]
        for i in 0..<nsyms {
            let n = symoff + i * 16
            let type = data[data.startIndex + n + 4]
            guard type & 0x0E == 0x0E, type & 0x01 == 1 else { continue }   // N_SECT, N_EXT
            let name = data.cString(stroff + Int(data.u32(n)), .max)
            if names.contains(name) { out[name] = data.u64(n + 8) }
        }
        return out
    }

    // The file offset holding the byte at this address, when it lies in a segment's file contents.
    func fileOffset(ofAddress a: UInt64) -> Int? {
        for s in segments where a >= s.vmaddr && a < s.vmaddr + s.fileSize {
            return Int(s.fileOffset + (a - s.vmaddr))
        }
        return nil
    }

    func section(_ segment: String, _ name: String) -> Section? {
        sections.first { $0.name == name && (segment.isEmpty || $0.segment == segment) }
    }
}

// Decoding a pointer slot under `LC_DYLD_CHAINED_FIXUPS` (mach-o/fixup-chains.h): a slot holds either a
// rebase (its target) or a bind (an import's ordinal). Formats DYLD_CHAINED_PTR_64 (2) and _64_OFFSET (6).
struct ChainedFixups {
    enum Target { case rebase(UInt64); case bind(String) }
    private let data: Data
    private let imageBase: UInt64
    private let imports: [String]
    // Per segment: file range and pointer format.
    private let formats: [(fileStart: UInt64, fileEnd: UInt64, format: UInt16)]

    init(file: MachO, data: Data) throws {
        guard let (off, _) = file.chainedFixups else {
            throw FrameIndex.Failure("binary has no LC_DYLD_CHAINED_FIXUPS (link with chained fixups)")
        }
        self.data = data
        imageBase = file.segments.first { $0.name == "__TEXT" }?.vmaddr ?? 0
        let startsOff = off + Int(data.u32(off + 4)), importsOff = off + Int(data.u32(off + 8))
        let symbolsOff = off + Int(data.u32(off + 12)), count = Int(data.u32(off + 16))
        let importsFormat = data.u32(off + 20)
        var names: [String] = []
        for i in 0..<count {
            let nameOffset: Int
            switch importsFormat {
            case 1: nameOffset = Int(data.u32(importsOff + i * 4) >> 9)          // DYLD_CHAINED_IMPORT
            case 2: nameOffset = Int(data.u32(importsOff + i * 8) >> 9)          // _ADDEND
            case 3: nameOffset = Int(data.u64(importsOff + i * 16) >> 32)        // _ADDEND64
            default: throw FrameIndex.Failure("unsupported chained imports format \(importsFormat)")
            }
            names.append(data.cString(symbolsOff + nameOffset, .max))
        }
        imports = names
        var formats: [(UInt64, UInt64, UInt16)] = []
        let segCount = Int(data.u32(startsOff))
        for i in 0..<segCount {
            let infoOff = Int(data.u32(startsOff + 4 + i * 4))
            guard infoOff != 0, i < file.segments.count else { continue }
            let seg = startsOff + infoOff
            let segFile = file.segments[i].fileOffset
            let pageSize = UInt64(data.u16(seg + 4)), pageCount = UInt64(data.u16(seg + 20))
            formats.append((segFile, segFile + pageSize * pageCount, data.u16(seg + 6)))
        }
        self.formats = formats
    }

    func target(atFileOffset o: Int) throws -> Target {
        guard let f = formats.first(where: { UInt64(o) >= $0.fileStart && UInt64(o) < $0.fileEnd })?.format else {
            throw FrameIndex.Failure("no chained-fixup segment covers file offset 0x\(String(o, radix: 16))")
        }
        guard f == 2 || f == 6 else { throw FrameIndex.Failure("unsupported chained pointer format \(f)") }
        let v = data.u64(o)
        if v >> 63 == 1 {
            let ordinal = Int(v & 0xFF_FFFF)
            guard ordinal < imports.count else { throw FrameIndex.Failure("bind ordinal \(ordinal) out of range") }
            return .bind(imports[ordinal])
        }
        let target = v & 0xF_FFFF_FFFF, high8 = (v >> 36) & 0xFF
        return .rebase((high8 << 56) | (f == 6 ? imageBase &+ target : target))
    }
}

// The ld64 link map (`-map`): each object's stackmap blob and shape table, and the objects defining the given addresses
// (local symbols included, which `-x` strips from the binary). Scanned as bytes: the map lists every symbol
// in the link (megabytes for a program with the collector), and only a few lines matter.
struct LinkMap {
    struct Blob { let address: UInt64; let size: UInt64; let file: Int }
    private(set) var blobs: [Blob] = []
    // Each object's shape-ordinal table (`__nomu_shape_table`, local to its object), by object.
    private(set) var shapeTables: [Int: UInt64] = [:]
    private var byAddress: [UInt64: Set<Int>] = [:]

    init(path: String, addresses: Set<UInt64>) throws {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            throw FrameIndex.Failure("cannot read link map '\(path)'")
        }
        let marker = Array("__LLVM_StackMaps".utf8), shapeTable = Array("___nomu_shape_table".utf8)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            var inSymbols = false
            func hex(_ j: inout Int) -> UInt64? {
                guard j + 1 < n, b[j] == 0x30, b[j + 1] == 0x78 else { return nil }   // "0x"
                j += 2
                var v: UInt64 = 0, any = false
                while j < n {
                    let c = b[j]
                    let d: UInt8
                    if c >= 0x30 && c <= 0x39 { d = c - 0x30 } else if c >= 0x41 && c <= 0x46 { d = c - 0x37 }
                    else if c >= 0x61 && c <= 0x66 { d = c - 0x57 } else { break }
                    v = v << 4 | UInt64(d); any = true; j += 1
                }
                return any ? v : nil
            }
            while i < n {
                var eol = i
                while eol < n && b[eol] != 0x0A { eol += 1 }
                defer { i = eol + 1 }
                if b[i] == 0x23 {   // "#": a section heading
                    if eol - i >= 10 && b[i + 2] == 0x53 && b[i + 3] == 0x79 { inSymbols = true }        // "# Symbols:"
                    else if inSymbols && eol - i >= 6 && b[i + 2] == 0x44 && b[i + 3] == 0x65 { break }  // "# Dead"
                    continue
                }
                guard inSymbols else { continue }
                // "0x<address>\t0x<size>\t[ <file>] <name>"
                var j = i
                guard let address = hex(&j) else { continue }
                while j < eol && (b[j] == 0x09 || b[j] == 0x20) { j += 1 }
                guard let size = hex(&j) else { continue }
                while j < eol && b[j] != 0x5B { j += 1 }    // "["
                j += 1
                while j < eol && b[j] == 0x20 { j += 1 }
                var file = 0
                while j < eol && b[j] >= 0x30 && b[j] <= 0x39 { file = file * 10 + Int(b[j] - 0x30); j += 1 }
                j += 2                                      // "] "
                if eol - j == marker.count && marker.indices.allSatisfy({ b[j + $0] == marker[$0] }) {
                    blobs.append(Blob(address: address, size: size, file: file))
                } else if eol - j == shapeTable.count && shapeTable.indices.allSatisfy({ b[j + $0] == shapeTable[$0] }) {
                    shapeTables[file] = address
                } else if addresses.contains(address) {
                    byAddress[address, default: []].insert(file)
                }
            }
        }
        blobs.sort { $0.address < $1.address }
    }

    func filesDefining(address: UInt64) -> Set<Int> { byAddress[address] ?? [] }
}

private extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
    func cString(_ o: Int, _ max: Int) -> String {
        var e = startIndex + o
        let limit = max == .max ? endIndex : Swift.min(endIndex, startIndex + o + max)
        while e < limit && self[e] != 0 { e += 1 }
        return String(decoding: self[(startIndex + o)..<e], as: UTF8.self)
    }
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
