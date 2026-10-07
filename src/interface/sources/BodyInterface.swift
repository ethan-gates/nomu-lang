import noir
import Foundation

// The `.bir` body-IR artifact (task 100.5.1): a producer module's generic template **bodies**, shipped
// in pre-mono NOIR form so a consumer can inject them and let `Monomorphize` specialize the instances it
// uses (the specialization dial, 100.5). Distinct from the `.nmi`, which carries only the body-free
// surface: a consumer reads the `.nmi` to type-check against a dependency, and (under `--mono`) the `.bir`
// to specialize the dependency's generics into its own object.
//
// A `.bir` is a **self-contained closure unit**: the generic/nested-generic bodies plus the private
// non-generic callees those bodies reach (the latter exported but interface-invisible — the
// usableFromInline linkage effect, 100.5.1). Wire form is deterministic JSON (as with the `.nmi`; a
// bespoke binary with a local-index definition table and origin-keyed external references is the
// re-resolution phase, 100.5 "A"). A body that references nothing outside itself — `id<T>` — needs
// neither, so the first milestone ships the decls directly.

// The decls a `.bir` carries, with a format version. Regenerated per build, so a version mismatch
// invalidates a stale file rather than needing migration (as with the `.nmi`).
// NOIR is not `Equatable`, so neither is this; round-tripping is checked by byte-identity of a re-serialize.
public struct BIRFile: Codable {
    public var version: UInt64
    public var decls: [NOIRDecl]
    public init(version: UInt64 = birFormatVersion, decls: [NOIRDecl]) {
        self.version = version; self.decls = decls
    }
}

// The `.bir` schema version. Bump on a NOIR-serialization change; build-internal and regenerated.
public let birFormatVersion: UInt64 = 1

// Serialize a producer's shipped generic bodies to `.bir` text. Deterministic (sorted keys), so a byte
// diff tracks a real body change (the incremental-cache lever, task 172).
public func serializeBIR(_ decls: [NOIRDecl]) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(BIRFile(decls: decls)) else { return "" }
    return String(decoding: data, as: UTF8.self) + "\n"
}

// Parse a `.bir` back to its decls (the consumer side). Returns nil on malformed input or a version
// mismatch — the consumer then falls back to the erased witness path for that dependency.
public func parseBIR(_ text: String) -> [NOIRDecl]? {
    guard let data = text.data(using: .utf8),
          let file = try? JSONDecoder().decode(BIRFile.self, from: data),
          file.version == birFormatVersion else { return nil }
    return file.decls
}
