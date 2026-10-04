// The fact store (task 167) — the in-memory hub the inference stage writes into and the transforms +
// interface emit read from. Design home: `internals/inference.md` ("Fact store"). Plain infrastructure:
// a per-symbol record schema, deterministic independently-hashed sections, and a two-writer upsert API.
// It holds no analysis and depends on nothing — the SCC engine (168), the escape summary (169), and the
// real Sema/inference writers + `.nmi` emit (164) plug into it.

// A stable symbol key: a post-monomorphization mangled name. Per-definition (a public generic is one
// record over its erased body, not one per instantiation). A thin wrapper, not a bare `String`, so the
// key stays type-safe at every call site.
public struct SymbolID: Hashable, Comparable, CustomStringConvertible {
    public let mangled: String
    public init(_ mangled: String) { self.mangled = mangled }
    public var description: String { mangled }
    public static func < (a: SymbolID, b: SymbolID) -> Bool { a.mangled < b.mangled }
}

// The schema version. Adding a dimension is a field addition (additive); this bumps only when an existing
// field's meaning changes. Folded into each whole-store digest so the `.nmi` cache can reason across
// builds.
public let factSchemaVersion: UInt64 = 1

// MARK: - Canonical encoding + hash

// A deterministic byte encoder feeding FNV-1a. Swift's `Hasher` is per-process randomized and cannot
// produce a stable cache key, so sections serialize to a canonical byte form — fields in a fixed order,
// set/map keys sorted — and hash that. The digest is then insensitive to insertion order and reproducible
// across runs.
public struct CanonicalEncoder {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func put(_ n: UInt64) {   // little-endian, fixed width — self-delimiting
        var v = n
        for _ in 0..<8 { bytes.append(UInt8(v & 0xff)); v >>= 8 }
    }
    public mutating func put(_ n: Int) { put(UInt64(bitPattern: Int64(n))) }
    public mutating func put(_ b: Bool) { bytes.append(b ? 1 : 0) }
    public mutating func put(_ s: String) {   // length-prefixed, so concatenation is unambiguous
        put(UInt64(s.utf8.count)); bytes.append(contentsOf: s.utf8)
    }
    // A tagged optional: a presence bit, then the payload only when present. Distinguishes "absent" from
    // "present with a default value" in the hash.
    public mutating func putOptional(_ present: Bool, _ body: (inout CanonicalEncoder) -> Void) {
        put(present)
        if present { body(&self) }
    }

    public func fnv1a() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return h
    }
}

// MARK: - Sections

// ABI / soundness facts — what a consumer must see to compile correctly. A perf-only edit must leave this
// section's digest byte-identical, so a debug dependent that read only the ABI stays cached.
public struct ABIFacts: Equatable {
    public var mutating: Bool?                      // a method mutates `self`
    public var shareable: Bool?                     // a type is shareable across fibers
    public var conditionalConformance: [String]?    // shareable iff these type-parameter names are (canonicalized)
    public init() {}

    func encode(into e: inout CanonicalEncoder) {
        e.putOptional(mutating != nil) { $0.put(mutating ?? false) }
        e.putOptional(shareable != nil) { $0.put(shareable ?? false) }
        e.putOptional(conditionalConformance != nil) { enc in
            let names = (conditionalConformance ?? []).sorted()
            enc.put(UInt64(names.count))
            for n in names { enc.put(n) }
        }
    }
    public var digest: UInt64 { var e = CanonicalEncoder(); encode(into: &e); return e.fnv1a() }
}

// A parameter's escape disposition in a function's summary (task 169, the Level-1 floor). `escapes` folds
// in the conservative cases — the parameter reaches a terminal/cross-fiber sink, is returned, or is passed
// to a callee that escapes it. `noEscape` is the recoverable win: the parameter stays within the callee,
// so a caller can still promote the actual it passed. The intoReturn/intoParam refinements (threading a
// callee's return provenance back to the caller) are the k≥2 extension.
public enum ParamDisposition: String, Equatable, Codable { case noEscape, escapes }

// A function's return provenance. `fresh` — the return is a newly allocated object the caller may treat as
// local; `escaped` — be conservative (it aliases a parameter, comes from a call, or reaches a sink).
public enum ReturnProvenance: String, Equatable, Codable { case fresh, escaped }

// The interprocedural escape summary of one definition (task 169): per-parameter disposition + return
// provenance. Per-definition (a public generic is summarized once over its erased body).
public struct EscapeSummary: Equatable, Codable {
    public var params: [ParamDisposition]
    public var ret: ReturnProvenance
    public init(params: [ParamDisposition] = [], ret: ReturnProvenance = .escaped) {
        self.params = params; self.ret = ret
    }
    func encode(into e: inout CanonicalEncoder) {
        e.put(UInt64(params.count))
        for p in params { e.put(p == .escapes) }
        e.put(ret == .fresh)
    }
}

// Perf facts — optimization results. `escape` is the interprocedural escape summary (task 169).
public struct PerfFacts: Equatable {
    public var escape: EscapeSummary?       // the interprocedural escape summary
    public var stackDepthBound: UInt64?     // a fiber stack-depth bound, if computed
    public init() {}

    func encode(into e: inout CanonicalEncoder) {
        e.putOptional(escape != nil) { escape!.encode(into: &$0) }
        e.putOptional(stackDepthBound != nil) { $0.put(stackDepthBound ?? 0) }
    }
    public var digest: UInt64 { var e = CanonicalEncoder(); encode(into: &e); return e.fnv1a() }
}

// One symbol's record: the two independently-hashed sections. Writers touch disjoint fields (Sema the
// ABI facts, inference the perf facts), so the record is order-independent.
public struct SymbolFacts: Equatable {
    public var abi = ABIFacts()
    public var perf = PerfFacts()
    public init() {}
}

// MARK: - Store

public struct FactStore {
    public let schemaVersion: UInt64
    private var symbols: [SymbolID: SymbolFacts] = [:]

    public init(schemaVersion: UInt64 = factSchemaVersion) { self.schemaVersion = schemaVersion }

    // The two-writer API: upsert a symbol's record. Each writer mutates its own section's fields, so the
    // order the two writers run in does not affect the result.
    public mutating func update(_ id: SymbolID, _ body: (inout SymbolFacts) -> Void) {
        var f = symbols[id] ?? SymbolFacts()
        body(&f)
        symbols[id] = f
    }

    public func facts(for id: SymbolID) -> SymbolFacts? { symbols[id] }
    public var symbolIDs: [SymbolID] { symbols.keys.sorted() }

    // Per-symbol section digests — for a consumer that cached a single symbol.
    public func abiDigest(for id: SymbolID) -> UInt64? { symbols[id]?.abi.digest }
    public func perfDigest(for id: SymbolID) -> UInt64? { symbols[id]?.perf.digest }

    // Whole-store per-section digests, folded over symbols in sorted-key order (so insertion order never
    // perturbs the hash). The ABI digest is the incremental-cache lever: it stays fixed across any
    // perf-only edit.
    public func abiDigest() -> UInt64 {
        var e = CanonicalEncoder(); e.put(schemaVersion)
        for id in symbols.keys.sorted() { e.put(id.mangled); symbols[id]!.abi.encode(into: &e) }
        return e.fnv1a()
    }
    public func perfDigest() -> UInt64 {
        var e = CanonicalEncoder(); e.put(schemaVersion)
        for id in symbols.keys.sorted() { e.put(id.mangled); symbols[id]!.perf.encode(into: &e) }
        return e.fnv1a()
    }
}
