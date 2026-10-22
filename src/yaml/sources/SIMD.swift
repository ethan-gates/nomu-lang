// Vector helpers over 64-byte blocks, in the style of simdjson: classify every byte of a block at once and
// collapse each class to a 64-bit mask, one bit per byte, byte 0 in the low bit.
//
// Swift's SIMD types lower to NEON only for some operations, so these helpers use a narrow subset, checked
// against the disassembly of a `-c opt` build on arm64 (Swift 6.3):
// - Lowers to vector code: unaligned loads, lane arithmetic (`&+`, `&-`), bitwise operations, lane shifts,
//   reinterpreting a vector as `SIMD2<UInt64>`, and lane comparisons (`.==`, `.<`) whose mask is
//   reinterpreted as a vector at once (one `cmeq` or `cmhi`, 0xFF in true lanes).
// - Avoided: reductions over a `SIMDMask` such as `any` (a call), the swizzle subscript (sixteen separate
//   byte loads; there is no table lookup), `max()`, `min()`, `pointwiseMin` and `pointwiseMax` (correct
//   single instructions, but emitted as calls), and lane-weighted `wrappedSum` (rewritten into per-lane
//   scalar code).
// Masks are gathered with a multiply.

typealias Lanes = SIMD16<UInt8>

// 64 bytes as four 16-byte vectors.
struct Block {
    static let size = 64

    let v0, v1, v2, v3: Lanes

    @inline(__always)
    init(_ p: UnsafeRawPointer) {
        v0 = p.loadUnaligned(fromByteOffset: 0, as: Lanes.self)
        v1 = p.loadUnaligned(fromByteOffset: 16, as: Lanes.self)
        v2 = p.loadUnaligned(fromByteOffset: 32, as: Lanes.self)
        v3 = p.loadUnaligned(fromByteOffset: 48, as: Lanes.self)
    }

    // Whether every byte is below 0x80.
    @inline(__always)
    var isASCII: Bool {
        let halves = unsafeBitCast(v0 | v1 | v2 | v3, to: SIMD2<UInt64>.self)
        return (halves[0] | halves[1]) & 0x8080_8080_8080_8080 == 0
    }

    // Whether `classify` returns 0x01 in any lane (it must return 0x00 or 0x01 in every lane). Cheaper than
    // `mask`: one vector OR and a test of two words, with no multiplies.
    @inline(__always)
    func any(_ classify: (Lanes) -> Lanes) -> Bool {
        let halves = unsafeBitCast(classify(v0) | classify(v1) | classify(v2) | classify(v3), to: SIMD2<UInt64>.self)
        return halves[0] | halves[1] != 0
    }

    // The mask of bytes for which `classify` returns 0x01 (it must return 0x00 or 0x01 in every lane).
    @inline(__always)
    func mask(_ classify: (Lanes) -> Lanes) -> UInt64 {
        UInt64(movemask(classify(v0)))
            | UInt64(movemask(classify(v1))) << 16
            | UInt64(movemask(classify(v2))) << 32
            | UInt64(movemask(classify(v3))) << 48
    }

    // The mask of bytes for which `classify` returns 0x01, given each lane of three blocks at consecutive
    // offsets: the byte before, the byte itself, and the byte after.
    @inline(__always)
    static func mask(_ before: Block, _ v: Block, _ after: Block, _ classify: (Lanes, Lanes, Lanes) -> Lanes)
        -> UInt64
    {
        UInt64(movemask(classify(before.v0, v.v0, after.v0)))
            | UInt64(movemask(classify(before.v1, v.v1, after.v1))) << 16
            | UInt64(movemask(classify(before.v2, v.v2, after.v2))) << 32
            | UInt64(movemask(classify(before.v3, v.v3, after.v3))) << 48
    }
}

// 0x01 in lanes equal to `c`, 0x00 elsewhere.
@inline(__always)
func equal01(_ v: Lanes, _ c: UInt8) -> Lanes {
    unsafeBitCast(v .== Lanes(repeating: c), to: Lanes.self) & 1
}

// 0x01 in lanes below `c`, 0x00 elsewhere.
@inline(__always)
func below01(_ v: Lanes, _ c: UInt8) -> Lanes {
    unsafeBitCast(v .< Lanes(repeating: c), to: Lanes.self) & 1
}

// One bit per lane from lanes holding 0x00 or 0x01. Multiplying a 64-bit half by 0x0102040810204080 moves
// lane k's bit to bit 56 + k with no carries between the partial products, so the top byte is the half's
// mask.
@inline(__always)
func movemask(_ v01: Lanes) -> UInt16 {
    let halves = unsafeBitCast(v01, to: SIMD2<UInt64>.self)
    let lo = (halves[0] &* 0x0102_0408_1020_4080) >> 56
    let hi = (halves[1] &* 0x0102_0408_1020_4080) >> 56
    return UInt16(truncatingIfNeeded: lo | hi << 8)
}
