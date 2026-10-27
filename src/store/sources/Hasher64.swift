import Foundation

// The build cache's one hash function (64-bit FNV-1a): host-cache keys, job keys and entry manifests all go
// through it, so replacing it (172 open question 1) is one change. Stable across runs and hosts.
public struct Hasher64 {
    private var h: UInt64 = 0xcbf29ce484222325

    public init() {}

    // Mix a string, length-prefixed, so ("ab", "c") and ("a", "bc") differ.
    public mutating func mix(_ s: String) {
        mixBytes(String(s.utf8.count).utf8); mixBytes(":".utf8); mixBytes(s.utf8)
    }

    // Mix raw bytes, unprefixed: for hashing one whole file.
    public mutating func mix(bytes data: Data) {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in mixBytes(bytes) }
    }

    private mutating func mixBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { h ^= UInt64(b); h = h &* 0x00000100000001B3 }
    }

    public var hex: String { String(h, radix: 16) }
}
