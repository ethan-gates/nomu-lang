import Foundation

// The x19 facts the GC frame index carries (`design/internals/frames-contract.md`, the base pointer). LLVM
// addresses a frame's locals through a base pointer in x19 when the frame holds run-time-sized buffers and
// enough fixed locals; it is set from SP in the prologue and is a frame address held in a register across
// every stop. The collector reads root slots relative to it and the mover fixes it, both needing to know where
// each frame's x19 is kept. So, after the link, for every function that saves x19 or uses a base pointer:
//
//   - where it saves its caller's x19, as an offset from its frame pointer. From the binary's `__unwind_info`:
//     a frame-mode encoding saves the x19/x20 pair just below the frame record, x19 at fp − 8; a DWARF-mode
//     one points at an `__eh_frame` FDE, whose save rule for x19 is read relative to the CFA (fp + 16).
//   - whether it uses a base pointer: LLVM's prologue sets one with `mov x19, sp`.
//
// Function bounds come from `__unwind_info` too, which lists every function with unwind info in address order.
enum UnwindFacts {
    struct Fact {
        let start: UInt64        // function address
        let length: UInt32
        let x19: Int32           // offset of the x19 save from the frame pointer; 0 when it is not saved
        let basePointer: Bool
        let framelessSave: Bool  // saves x19 with no frame record: no offset from a frame pointer exists
    }

    // The upper bound on facts for a link of these objects: one per compact-unwind entry, which LLVM emits for
    // every function it compiles (32 bytes each in `__LD,__compact_unwind`).
    static func entryCount(objects: [String]) throws -> Int {
        var n = 0
        for path in objects {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw FrameIndex.Failure("cannot read '\(path)'")
            }
            let file = try MachO(data)
            if let s = file.section("__LD", "__compact_unwind") { n += Int(s.size) / 32 }
        }
        return n
    }

    // The facts for a linked binary, sorted by address: only functions that save x19 or use a base pointer.
    static func facts(file: MachO, data: Data) throws -> [Fact] {
        guard let ui = file.section("__TEXT", "__unwind_info") else { return [] }
        guard let base = file.segments.first(where: { $0.name == "__TEXT" })?.vmaddr else {
            throw FrameIndex.Failure("binary has no __TEXT segment")
        }
        let eh = file.section("__TEXT", "__eh_frame")
        let functions = try listFunctions(data, at: Int(ui.fileOffset), size: Int(ui.size))
        var out: [Fact] = []
        for (i, f) in functions.enumerated() where f.start < f.end {
            let address = base + UInt64(f.start)
            let length = UInt32(f.end - f.start)
            var x19: Int32 = 0, frameless = false
            switch f.encoding & 0x0F00_0000 {
            case 0x0400_0000:                       // frame: the x19/x20 pair at fp − 8 and fp − 16
                if f.encoding & 0x1 != 0 { x19 = -8 }
            case 0x0200_0000:                       // frameless
                if f.encoding & 0x1 != 0 { frameless = true }
            case 0x0300_0000:                       // DWARF: the FDE's save rule
                guard let eh else { throw FrameIndex.Failure("function \(i) is described by DWARF, but the binary has no __eh_frame") }
                x19 = try dwarfX19(data, ehStart: Int(eh.fileOffset), ehSize: Int(eh.size),
                                   fde: Int(f.encoding & 0x00FF_FFFF), function: address)
            default:
                break
            }
            let bp = try usesBasePointer(file: file, data: data, address: address, length: Int(length))
            if x19 != 0 || bp || frameless {
                out.append(Fact(start: address, length: length, x19: x19, basePointer: bp, framelessSave: frameless))
            }
        }
        return out
    }

    // Every function `__unwind_info` covers, as (start, end, encoding) with offsets from the image base
    // (mach-o/compact_unwind_encoding.h): the first-level index pages to second-level pages, regular (kind 2)
    // or compressed (kind 3); the index's last entry is a sentinel marking the end of the last function.
    private static func listFunctions(_ d: Data, at s: Int, size: Int) throws -> [(start: UInt32, end: UInt32, encoding: UInt32)] {
        guard size >= 28, d.u32(s) == 1 else { throw FrameIndex.Failure("unsupported __unwind_info version") }
        let commonOff = Int(d.u32(s + 4)), commonCount = Int(d.u32(s + 8))
        let indexOff = Int(d.u32(s + 20)), indexCount = Int(d.u32(s + 24))
        var starts: [(UInt32, UInt32)] = []
        var sentinel: UInt32 = 0
        for k in 0..<indexCount {
            let e = s + indexOff + k * 12
            let fnBase = d.u32(e), pageOff = Int(d.u32(e + 4))
            if pageOff == 0 { sentinel = fnBase; continue }
            let page = s + pageOff
            let kind = d.u32(page)
            let entryOff = Int(d.u16(page + 4)), count = Int(d.u16(page + 6))
            switch kind {
            case 2:
                for j in 0..<count {
                    let e2 = page + entryOff + j * 8
                    starts.append((d.u32(e2), d.u32(e2 + 4)))
                }
            case 3:
                let encOff = Int(d.u16(page + 8))
                for j in 0..<count {
                    let w = d.u32(page + entryOff + j * 4)
                    let idx = Int(w >> 24)
                    let enc = idx < commonCount ? d.u32(s + commonOff + idx * 4)
                                                : d.u32(page + encOff + (idx - commonCount) * 4)
                    starts.append((fnBase + (w & 0x00FF_FFFF), enc))
                }
            default:
                throw FrameIndex.Failure("unsupported __unwind_info page kind \(kind)")
            }
        }
        starts.sort { $0.0 < $1.0 }
        var out: [(UInt32, UInt32, UInt32)] = []
        for (i, f) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].0 : sentinel
            out.append((f.0, end, f.1))
        }
        return out
    }

    // The x19 save of the function an FDE describes, as an offset from its frame pointer, or 0 when the FDE
    // saves no x19. The frame record must sit at CFA − 16 (x29 saved there), as in every frame LLVM builds on
    // arm64 Darwin, so the frame pointer is CFA − 16. The first save rule for each register is the prologue's;
    // later rules (epilogue CFI) restore and are ignored.
    private static func dwarfX19(_ d: Data, ehStart: Int, ehSize: Int, fde: Int, function: UInt64) throws -> Int32 {
        func fail(_ m: String) -> FrameIndex.Failure {
            FrameIndex.Failure("unwind info of the function at 0x\(String(function, radix: 16)): \(m)")
        }
        var r = Reader(d, ehStart + fde)
        let fdeLength = Int(r.u32())
        guard fdeLength != 0xFFFF_FFFF, fde + 4 + fdeLength <= ehSize else { throw fail("unsupported FDE") }
        let fdeEnd = r.at + fdeLength
        let ciePtrAt = r.at
        let cieRel = Int(r.u32())
        // The CIE: augmentation, alignment factors, and the pointer encoding its FDEs use.
        var c = Reader(d, ciePtrAt - cieRel)
        let cieLength = Int(c.u32())
        let cieEnd = c.at + cieLength
        guard c.u32() == 0 else { throw fail("FDE does not point at a CIE") }
        let version = c.u8()
        var aug = ""
        while true { let ch = c.u8(); if ch == 0 { break }; aug.append(Character(UnicodeScalar(ch))) }
        _ = c.uleb()                        // code alignment
        let dataAlign = c.sleb()
        if version == 1 { _ = c.u8() } else { _ = c.uleb() }   // return address register
        var ptrEnc: UInt8 = 0
        if aug.hasPrefix("z") {
            let augLen = Int(c.uleb())
            let augEnd = c.at + augLen
            for ch in aug.dropFirst() {
                switch ch {
                case "R": ptrEnc = c.u8()
                case "L": _ = c.u8()
                case "P": let e = c.u8(); c.at += pointerSize(e)
                default: break
                }
            }
            c.at = augEnd
        }
        var saves: [UInt64: Int64] = [:]
        try interpret(&c, until: cieEnd, dataAlign: dataAlign, saves: &saves, fail: fail)
        // The FDE: skip its address range and augmentation data, then its instructions.
        r.at += 2 * pointerSize(ptrEnc)
        if aug.hasPrefix("z") { let n = Int(r.uleb()); r.at += n }
        try interpret(&r, until: fdeEnd, dataAlign: dataAlign, saves: &saves, fail: fail)
        guard let x19 = saves[19] else { return 0 }
        guard saves[29] == -16 else { throw fail("saves x19 with no frame record at CFA - 16") }
        return Int32(x19 + 16)
    }

    // Read call-frame instructions, recording each register's first save rule (an offset from the CFA).
    private static func interpret(_ r: inout Reader, until end: Int, dataAlign: Int64, saves: inout [UInt64: Int64],
                                  fail: (String) -> FrameIndex.Failure) throws {
        func save(_ reg: UInt64, _ off: Int64) { if saves[reg] == nil { saves[reg] = off } }
        while r.at < end {
            let op = r.u8()
            switch op >> 6 {
            case 1: continue                                              // advance_loc
            case 2: save(UInt64(op & 0x3F), Int64(r.uleb()) * dataAlign); continue   // offset
            case 3: continue                                              // restore
            default: break
            }
            switch op {
            case 0x00, 0x0A, 0x0B: break                                  // nop, remember/restore state
            case 0x01: r.at += 8                                          // set_loc
            case 0x02: r.at += 1
            case 0x03: r.at += 2
            case 0x04: r.at += 4                                          // advance_loc1/2/4
            case 0x05: let reg = r.uleb(); save(reg, Int64(r.uleb()) * dataAlign)   // offset_extended
            case 0x06, 0x07, 0x08, 0x0D, 0x2E: _ = r.uleb()               // restore/undefined/same_value, def_cfa_register, args_size
            case 0x09, 0x0C: _ = r.uleb(); _ = r.uleb()                   // register, def_cfa
            case 0x0E: _ = r.uleb()                                       // def_cfa_offset
            case 0x11: let reg = r.uleb(); save(reg, r.sleb() * dataAlign)   // offset_extended_sf
            case 0x12: _ = r.uleb(); _ = r.sleb()                         // def_cfa_sf
            case 0x13: _ = r.sleb()                                       // def_cfa_offset_sf
            default: throw fail("unsupported call-frame instruction 0x\(String(op, radix: 16))")
            }
        }
    }

    private static func pointerSize(_ enc: UInt8) -> Int {
        switch enc & 0x0F {
        case 0x02, 0x0A: return 2
        case 0x03, 0x0B: return 4
        default: return 8
        }
    }

    // A base pointer: `mov x19, sp` (`add x19, sp, #0`) in the prologue, before the first branch or call.
    private static func usesBasePointer(file: MachO, data: Data, address: UInt64, length: Int) throws -> Bool {
        guard let off = file.fileOffset(ofAddress: address) else { return false }
        for k in 0..<min(length / 4, 64) {
            let w = data.u32(off + k * 4)
            if w == 0x9100_03F3 { return true }
            if w & 0xFC00_0000 == 0x9400_0000 || w & 0xFC00_0000 == 0x1400_0000 { return false }   // bl, b
            if w & 0xFFFF_FC1F == 0xD63F_0000 || w == 0xD65F_03C0 { return false }                  // blr, ret
        }
        return false
    }

    private struct Reader {
        let d: Data
        var at: Int
        init(_ d: Data, _ at: Int) { self.d = d; self.at = at }
        mutating func u8() -> UInt8 { let v = d[d.startIndex + at]; at += 1; return v }
        mutating func u32() -> UInt32 { var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(u8()) << (8 * i) }; return v }
        mutating func uleb() -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true { let b = u8(); v |= UInt64(b & 0x7F) << shift; shift += 7; if b & 0x80 == 0 { return v } }
        }
        mutating func sleb() -> Int64 {
            var v: Int64 = 0, shift: Int64 = 0, b: UInt8 = 0
            repeat { b = u8(); v |= Int64(b & 0x7F) << shift; shift += 7 } while b & 0x80 != 0
            if shift < 64 && b & 0x40 != 0 { v |= -(Int64(1) << shift) }
            return v
        }
    }
}
