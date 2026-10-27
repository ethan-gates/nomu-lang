import Foundation

// The store's content hash: a `Hasher64` over the bytes alone. Names blobs in the CAS.
public enum ContentHash {
    public static func of(_ data: Data) -> String {
        var h = Hasher64()
        h.mix(bytes: data)
        return h.hex
    }
}
