import CommonCrypto
import Foundation

// Re-signing a binary after the driver patches it (the GC frame index). On arm64 macOS the linker ad-hoc
// signs every binary: an embedded code directory holding a SHA-256 hash of each 4 KB page up to the
// signature. A patch leaves the page count and the directory's size unchanged, so re-signing rehashes the
// pages and writes the hashes over the old ones in place, with no `codesign` process (as Go's linker signs).
//
// Only the linker's form is rewritten: a superblob holding one code directory, linker-signed and ad hoc,
// SHA-256 over 4 KB pages, no special slots. Anything else returns `.unsupported` and the caller signs
// with `codesign`. All signature fields are big-endian (mach-o/codesign.h, `cs_blobs.h`).
enum CodeSignature {
    enum Outcome { case signed, unsupported(String) }

    static func resign(binary: String) throws -> Outcome {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: binary), options: .alwaysMapped) else {
            throw FrameIndex.Failure("cannot read '\(binary)'")
        }
        guard data.count >= 32, data.le32(0) == 0xFEED_FACF else { return .unsupported("not a 64-bit Mach-O file") }
        // LC_CODE_SIGNATURE (linkedit_data_command { cmd, cmdsize, dataoff, datasize }).
        var off = 32, signature: (offset: Int, size: Int)?
        for _ in 0..<Int(data.le32(16)) {
            if data.le32(off) == 0x1D { signature = (Int(data.le32(off + 8)), Int(data.le32(off + 12))) }
            off += Int(data.le32(off + 4))
        }
        guard let (sigOff, sigSize) = signature else { return .unsupported("no LC_CODE_SIGNATURE") }
        guard sigOff + sigSize <= data.count, sigSize >= 12 else { return .unsupported("signature outside the file") }

        // SuperBlob { magic, length, count, then { type, offset } per blob }: one code directory.
        guard data.be32(sigOff) == 0xFADE_0CC0 else { return .unsupported("no embedded signature superblob") }
        guard data.be32(sigOff + 8) == 1, data.be32(sigOff + 12) == 0 else {
            return .unsupported("signature holds blobs other than one code directory")
        }
        let cd = sigOff + Int(data.be32(sigOff + 16))
        // CodeDirectory { magic, length, version, flags, hashOffset, identOffset, nSpecialSlots, nCodeSlots,
        //                 codeLimit, hashSize u8, hashType u8, platform u8, pageSize u8 (log2), ... }
        guard cd + 44 <= sigOff + sigSize, data.be32(cd) == 0xFADE_0C02 else { return .unsupported("no code directory") }
        let flags = data.be32(cd + 12)
        guard flags & 0x2_0002 == 0x2_0002 else { return .unsupported("signature is not linker-signed ad hoc") }
        let hashOffset = Int(data.be32(cd + 16)), nSpecial = data.be32(cd + 24)
        let nCode = Int(data.be32(cd + 28)), codeLimit = Int(data.be32(cd + 32))
        let hashSize = Int(data[cd + 36]), hashType = data[cd + 37], pageShift = data[cd + 39]
        guard hashType == 2, hashSize == Int(CC_SHA256_DIGEST_LENGTH), pageShift == 12, nSpecial == 0 else {
            return .unsupported("code directory is not SHA-256 over 4 KB pages without special slots")
        }
        let pageSize = 1 << Int(pageShift)
        guard codeLimit == sigOff, nCode == (codeLimit + pageSize - 1) / pageSize,
              cd + hashOffset + nCode * hashSize <= sigOff + sigSize else {
            return .unsupported("code directory does not cover the file up to the signature")
        }

        // One hash per page, then one write over the hash slots.
        var hashes = Data(count: nCode * hashSize)
        data.withUnsafeBytes { (file: UnsafeRawBufferPointer) in
            hashes.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for page in 0..<nCode {
                    let start = page * pageSize, length = min(pageSize, codeLimit - start)
                    _ = CC_SHA256(file.baseAddress! + start, CC_LONG(length),
                                  out.baseAddress!.assumingMemoryBound(to: UInt8.self) + page * hashSize)
                }
            }
        }
        guard let h = FileHandle(forWritingAtPath: binary) else { throw FrameIndex.Failure("cannot write '\(binary)'") }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(cd + hashOffset))
            try h.write(contentsOf: hashes)
        } catch {
            throw FrameIndex.Failure("cannot write '\(binary)': \(error)")
        }
        return .signed
    }
}

private extension Data {
    func le32(_ o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func be32(_ o: Int) -> UInt32 { le32(o).byteSwapped }
}
