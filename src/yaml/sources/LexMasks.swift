// Byte-class masks for the line lexer, in the style of simdjson's structural index: each 64-byte block of the
// source is classified at once (`SIMD.swift`) into 64-bit masks, one bit per byte, so a scan jumps to the next
// byte of interest with a count of trailing zeros instead of testing each byte.
//
// Blocks are aligned to offset 0 of the source and computed when a scan first reaches them; lines are lexed in
// order, so each block is classified about once. The last, partial block is classified from a copy padded with
// line feeds, which end a line just as the end of the file does. These masks serve the diagnostic path's lexer;
// the parser reads stage 1's plain-stop masks (`PlainStops`).

struct LexMasks {
    // The classes a scan can ask for.
    enum Class {
        case nonSpace   // any byte but a space
        case plainStop  // where a plain scalar may end: a tab, a mapping colon, or `#` after a space
        case quote      // `"`, `'` or `\`
    }

    private static let lf: UInt8 = 0x0A

    private let b: UnsafeBufferPointer<UInt8>
    private var block = -1
    private var nonSpace: UInt64 = 0
    private var plainStop: UInt64 = 0
    // Quoted scalars are rare, so the quote mask is built only when a scan asks for it.
    private var quoteBlock = -1
    private var quote: UInt64 = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        b = bytes
    }

    // The first offset in `[from, end)` whose byte is in `cls`, or `end` when there is none.
    @inline(__always)
    mutating func next(_ cls: Class, from: Int, end: Int) -> Int {
        var i = from
        while i < end {
            let k = i >> 6
            let m: UInt64
            switch cls {
            case .nonSpace:
                if k != block { classify(k) }
                m = nonSpace
            case .plainStop:
                if k != block { classify(k) }
                m = plainStop
            case .quote:
                if k != quoteBlock { classifyQuotes(k) }
                m = quote
            }
            let rest = m >> UInt64(i & 63)
            if rest != 0 { return min(i + rest.trailingZeroBitCount, end) }
            i = (k + 1) << 6
        }
        return end
    }

    // Classifies block `k` from three loads: the block, and the block shifted one byte back and one forward,
    // which give each byte its neighbors without moving bits across lanes. A block at either end of the source
    // is classified from a copy with a line feed before and after it, which classify as the start or end of a
    // line does.
    @inline(never)
    private mutating func classify(_ k: Int) {
        block = k
        let base = k << 6
        if base > 0 && base + Block.size < b.count {
            let p = UnsafeRawPointer(b.baseAddress! + base)
            classify(Block(p - 1), Block(p), Block(p + 1))
            return
        }
        LexMasks.withPadded(b, base) { p in classify(Block(p - 1), Block(p), Block(p + 1)) }
    }

    @inline(never)
    private mutating func classifyQuotes(_ k: Int) {
        quoteBlock = k
        quote = LexMasks.quotes(b, block: k)
    }

    // The quote mask of the 64 bytes from `base`.
    @inline(__always)
    static func quotes(_ b: UnsafeBufferPointer<UInt8>, block k: Int) -> UInt64 { quotes(b, from: k << 6) }

    @inline(__always)
    static func quotes(_ b: UnsafeBufferPointer<UInt8>, from base: Int) -> UInt64 {
        if base + Block.size <= b.count { return Block(UnsafeRawPointer(b.baseAddress! + base)).mask(quote01) }
        return paddedQuotes(b, from: base)
    }

    @inline(never)
    private static func paddedQuotes(_ b: UnsafeBufferPointer<UInt8>, from base: Int) -> UInt64 {
        var m: UInt64 = 0
        withPadded(b, base) { p in m = Block(p).mask(quote01) }
        return m
    }

    // Calls `body` with a pointer to a copy of the block at `base`, with one byte before it and one after, and
    // line feeds where the source has no bytes.
    static func withPadded(_ b: UnsafeBufferPointer<UInt8>, _ base: Int, _ body: (UnsafeRawPointer) -> Void) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Block.size + 2) { tmp in
            tmp.initialize(repeating: LexMasks.lf)
            for j in max(base - 1, 0)..<min(base + Block.size + 1, b.count) { tmp[j - base + 1] = b[j] }
            body(UnsafeRawPointer(tmp.baseAddress! + 1))
        }
    }

    @inline(__always)
    private mutating func classify(_ before: Block, _ v: Block, _ after: Block) {
        nonSpace = ~v.mask(LexMasks.space01)
        plainStop = LexMasks.plainStop(before, v, after)
    }

    @inline(__always)
    private static func plainStop(_ before: Block, _ v: Block, _ after: Block) -> UInt64 {
        Block.mask(before, v, after) { p, c, n in
            equal01(c, 0x09)
                | equal01(c, 0x3A) & LexMasks.separator01(n)
                | equal01(c, 0x23) & equal01(p, 0x20)
        }
    }

    @inline(__always)
    private static func space01(_ v: Lanes) -> Lanes { equal01(v, 0x20) }

    // A separator after a mapping colon: a space, a tab, or the end of the line (a CR is always followed by an
    // LF).
    @inline(__always)
    private static func separator01(_ v: Lanes) -> Lanes {
        equal01(v, 0x20) | equal01(v, 0x09) | equal01(v, 0x0A) | equal01(v, 0x0D)
    }

    @inline(__always)
    static func quote01(_ v: Lanes) -> Lanes {
        equal01(v, 0x22) | equal01(v, 0x27) | equal01(v, 0x5C)
    }
}
