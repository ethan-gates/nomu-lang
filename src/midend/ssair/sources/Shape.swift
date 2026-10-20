import support   // Type

// One shape per type (task 176.5, `internals/shaped-roots.md`). `shape(T)` says where a value of type `T`
// holds managed words: plain managed pointers at fixed offsets, and *conditional* content whose managed
// words depend on a discriminant in the value — a shaped leaf (`StringBase`: `word0` managed only in the
// `heap` case) or an enum (each case's payload has its own shape). It is derived structurally from the leaf
// registry below, so a new shaped leaf, or shaped content in any aggregate, needs no change in a consumer.
// Every consumer (SSAIR liveness and homing, slot recording, the I11 verifier, shape ordinals, GC
// descriptors, the reload) reads it and decides nothing about shapedness on its own. Offsets are bytes in
// the 8-byte-slot layout (`slots`), the layout every component shares (the egress checks codegen's LLVM
// types against it).

// The shaped leaves: types whose value is a bit-stealing representation with a discriminant. This is the
// only place a leaf is named.
public enum ShapeLeaf: Equatable, Hashable, CaseIterable {
    case stringBase

    public static func of(_ t: Type) -> ShapeLeaf? {
        if case .stringBase = t { return .stringBase }
        return nil
    }

    public var type: Type {
        switch self {
        case .stringBase: return .stringBase
        }
    }

    // Name for the leaf's descriptor symbol.
    public var name: String {
        switch self {
        case .stringBase: return "string"
        }
    }

    // Size in 8-byte slots.
    public var slots: Int {
        switch self {
        case .stringBase: return 2
        }
    }

    // The discriminant: the byte offset of the word that holds it and the shift that extracts it.
    public var tagOffset: Int {
        switch self {
        case .stringBase: return 8      // word1's top bits: `immortal = 0`, `small = 1`, `heap = 2`
        }
    }
    public var tagShift: Int {
        switch self {
        case .stringBase: return 60
        }
    }

    // The discriminant values under which the leaf holds managed words, with their byte offsets. A value
    // under any other tag holds none (a `small` String's inline bytes, an `immortal` String's static data).
    public var managedCases: [(tag: Int, offsets: [Int])] {
        switch self {
        case .stringBase: return [(tag: 2, offsets: [0])]
        }
    }

    // The byte offsets of every word the leaf may hold managed, across its cases: the words a frame-slot
    // reload must read volatile.
    public var managedWords: [Int] {
        Array(Set(managedCases.flatMap(\.offsets))).sorted()
    }
}

// One conditional sub-value of a shape: a shaped leaf, or an enum whose per-case payload shapes are keyed by
// its tag (the case index, at offset 0 of the enum).
public indirect enum ShapeEntryKind: Equatable {
    case leaf(ShapeLeaf)
    case enumCases(name: String, cases: [ShapeCase])
}

// An enum case that holds managed content: its tag and its payload's shape, offsets relative to the enum's
// start (the payload begins at byte 8, past the tag word).
public struct ShapeCase: Equatable {
    public let tag: Int
    public let shape: Shape
    public init(tag: Int, shape: Shape) { self.tag = tag; self.shape = shape }
}

public struct ShapeEntry: Equatable {
    public let offset: Int
    public let kind: ShapeEntryKind
    public init(offset: Int, kind: ShapeEntryKind) { self.offset = offset; self.kind = kind }
}

public struct Shape: Equatable {
    // Byte offsets of plain managed pointers (class, actor, array, closure, `any`), managed in every value.
    public var managed: [Int] = []
    // Conditional sub-values, in offset order.
    public var conditional: [ShapeEntry] = []

    public init(managed: [Int] = [], conditional: [ShapeEntry] = []) {
        self.managed = managed
        self.conditional = conditional
    }

    public var isEmpty: Bool { managed.isEmpty && conditional.isEmpty }

    // This shape placed at byte `offset` inside an enclosing value.
    public func shifted(by offset: Int) -> Shape {
        Shape(managed: managed.map { $0 + offset },
              conditional: conditional.map { ShapeEntry(offset: $0.offset + offset, kind: $0.kind) })
    }

    // Byte offsets of the words a frame-slot load must read volatile: the conditional managed words, which
    // the collector rewrites in place and the statepoint rewrite cannot relocate (an `i64`). A leaf's managed
    // words, and every word of an enum payload that some case holds managed. Plain managed words need no
    // volatile load: a pointer loaded before a safepoint is an SSA value the statepoint rewrite relocates.
    public var conditionalWords: [Int] {
        var words = Set<Int>()
        for e in conditional {
            switch e.kind {
            case .leaf(let leaf):
                for w in leaf.managedWords { words.insert(e.offset + w) }
            case .enumCases(_, let cases):
                for c in cases {
                    for w in c.shape.managed { words.insert(e.offset + w) }
                    for w in c.shape.conditionalWords { words.insert(e.offset + w) }
                }
            }
        }
        return words.sorted()
    }

    mutating func append(_ other: Shape, at offset: Int) {
        let s = other.shifted(by: offset)
        managed += s.managed
        conditional += s.conditional
    }
}

// The type environment `shape(T)` derives from, and its per-type cache. The egress and the verifier each
// build one over their own view of the module's types; both views name the same structs and enums, so both
// compute the same shapes. The lookups are closures so a consumer whose type tables grow while it runs (the
// egress registers synthesized layouts) sees the additions; a type's entry never changes once present, so
// cached shapes stay valid.
public final class ShapeEnv {
    private let structFields: (String) -> [Type]?
    private let enumCases: (String) -> [[Type]]?
    private let resolveOpaque: (Type) -> Type
    private var shapes: [String: Shape] = [:]
    private var leaves: [String: ShapeLeaf?] = [:]
    private var inProgress = Set<String>()

    public init(structFields: @escaping (String) -> [Type]?,
                enumCases: @escaping (String) -> [[Type]]?,
                resolveOpaque: @escaping (Type) -> Type = { $0 }) {
        self.structFields = structFields
        self.enumCases = enumCases
        self.resolveOpaque = resolveOpaque
    }

    // The concrete type a `some I` stands for; an unresolvable one stays opaque.
    private func concrete(_ t: Type) -> Type {
        if case .opaque = t { return resolveOpaque(t) }
        return t
    }

    // Size of a value in 8-byte slots: the layout every component shares. A struct is the sum of its
    // fields; an enum is one tag word plus its largest case's payload; every other leaf is one word, except a
    // shaped leaf, which has its own size.
    public func slots(_ t: Type) -> Int {
        if let leaf = ShapeLeaf.of(t) { return leaf.slots }
        switch t {
        case .named(let n, .struct_):
            return structFields(n)?.reduce(0) { $0 + slots($1) } ?? 1
        case .named(let n, .enum_):
            return 1 + (enumCases(n)?.map { $0.reduce(0) { $0 + slots($1) } }.max() ?? 0)
        case .opaque:
            let c = concrete(t)
            if case .opaque = c { return 1 }
            return slots(c)
        default:
            return 1
        }
    }

    // The shaped leaf a value of type `t` *is*: the leaf itself, or a struct with exactly one field whose type
    // is such a value (a wrapper, like `struct String { let base: StringBase }`), which has the same words.
    // Nil for anything else, including a multi-field struct holding a leaf.
    public func leaf(_ t: Type) -> ShapeLeaf? {
        if let l = ShapeLeaf.of(t) { return l }
        switch t {
        case .named(let n, .struct_):
            if let known = leaves[n] { return known }
            guard !inProgress.contains(n) else { return nil }
            inProgress.insert(n)
            defer { inProgress.remove(n) }
            let fields = structFields(n) ?? []
            let l = fields.count == 1 ? leaf(fields[0]) : nil
            leaves[n] = .some(l)   // caches a nil result too
            return l
        case .opaque:
            let c = concrete(t)
            if case .opaque = c { return nil }
            return leaf(c)
        default:
            return nil
        }
    }

    // Whether a value of type `t` is a shaped leaf or a wrapper of one: it rides the shaped-value path (homed
    // in a two-word frame slot, recorded with the leaf's descriptor).
    public func isShapedValue(_ t: Type) -> Bool { leaf(t) != nil }

    // Whether `t` is a struct that wraps a shaped leaf (it lowers to the leaf's representation).
    public func isWrapper(_ t: Type) -> Bool {
        if case .named(_, .struct_) = t { return leaf(t) != nil }
        return false
    }

    // Whether a frame value of type `t` holds managed words the statepoint rewrite cannot see: conditional
    // content (a leaf's managed word is an `i64`; an enum's payload is `i64` words). Such a value is rooted by
    // a frame record — a shaped-value home, or a recorded slot for an aggregate.
    public func hasConditional(_ t: Type) -> Bool { !shape(t).conditional.isEmpty }

    public func shape(_ t: Type) -> Shape {
        if let leaf = ShapeLeaf.of(t) { return Shape(conditional: [ShapeEntry(offset: 0, kind: .leaf(leaf))]) }
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            return Shape(managed: [0])
        case .named(let n, .struct_):
            let key = "s:" + n
            if let s = shapes[key] { return s }
            guard !inProgress.contains(key) else { return Shape() }
            inProgress.insert(key)
            defer { inProgress.remove(key) }
            let s = fieldsShape(structFields(n) ?? [], base: 0)
            shapes[key] = s
            return s
        case .named(let n, .enum_):
            let key = "e:" + n
            if let s = shapes[key] { return s }
            guard !inProgress.contains(key) else { return Shape() }
            inProgress.insert(key)
            defer { inProgress.remove(key) }
            var cases: [ShapeCase] = []
            for (ci, fields) in (enumCases(n) ?? []).enumerated() {
                let cs = fieldsShape(fields, base: 8)   // the payload begins past the tag word
                if !cs.isEmpty { cases.append(ShapeCase(tag: ci, shape: cs)) }
            }
            let s = cases.isEmpty ? Shape()
                : Shape(conditional: [ShapeEntry(offset: 0, kind: .enumCases(name: n, cases: cases))])
            shapes[key] = s
            return s
        case .opaque:
            let c = concrete(t)
            if case .opaque = c { return Shape() }
            return shape(c)
        default:
            return Shape()   // scalars, raw pointers, and an erased `T` (rooted through its VWT buffer)
        }
    }

    // The shape of fields laid out in order from byte `base`, each at the slots of the fields before it. A
    // class or actor body, a closure or spawn environment, and an actor message's arguments are this, at
    // their object's first field offset.
    public func fieldsShape(_ fields: [Type], base: Int) -> Shape {
        var s = Shape()
        var off = base
        for f in fields {
            s.append(shape(f), at: off)
            off += slots(f) * 8
        }
        return s
    }
}
