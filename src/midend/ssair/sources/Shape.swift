import support   // Type

// One shape per type (task 176.5, `internals/shaped-roots.md`). `shape(T)` says where a value of type `T`
// holds managed words: plain managed pointers at fixed offsets, and *conditional* content whose managed
// words depend on a discriminant in the value — a shaped leaf (`StringBase`: `word0` managed only in the
// `heap` case) or an enum (each case's payload has its own shape). It is derived structurally from the leaf
// registry below, so a new shaped leaf, or shaped content in any aggregate, needs no change in a consumer.
// Every consumer (SSAIR liveness and homing, slot recording, the I11 verifier, shape ordinals, GC
// descriptors, the reload) reads it and decides nothing about shapedness on its own. Offsets are bytes in
// the value layout (`Layout.swift`), the layout every component shares (the egress checks codegen's LLVM
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

    // Size in 8-byte words.
    public var slots: Int {
        switch self {
        case .stringBase: return 2
        }
    }

    // Size and alignment in bytes: whole words, word-aligned.
    public var size: Int { slots * 8 }
    public var align: Int { 8 }

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
// its tag (the case index, a word at `tagOffset` from the enum's start).
public indirect enum ShapeEntryKind: Equatable {
    case leaf(ShapeLeaf)
    case enumCases(name: String, tagOffset: Int, cases: [ShapeCase])
}

// An enum case that holds managed content: its tag and its payload's shape, offsets relative to the enum's
// start.
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
            case .enumCases(_, _, let cases):
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
    let structFields: (String) -> [Type]?
    let enumCases: (String) -> [[Type]]?
    let classFields: (String) -> [Type]?
    let fieldMarks: (String) -> [Bool]?   // a struct's or class's `fromTypeParameter` marks, by declared position
    let enumCaseMarks: (String) -> [[Bool]]?   // an enum's, by case and declared position
    // Whether enums whose payloads are all references keep their case in the references' spare bits
    // (`EnumLayout.spareBits`); off under `measure.no_spare_bits`, which keeps the moved tag.
    public var spareBits = true
    private let resolveOpaque: (Type) -> Type
    private var shapes: [String: Shape] = [:]
    private var leaves: [String: ShapeLeaf?] = [:]
    var layouts: [String: (size: Int, align: Int)] = [:]   // `Layout.swift`'s per-type cache
    var enumLayouts: [String: EnumLayout] = [:]
    var extras: [String: ExtraInhabitants?] = [:]
    var inProgress = Set<String>()

    public init(structFields: @escaping (String) -> [Type]?,
                enumCases: @escaping (String) -> [[Type]]?,
                classFields: @escaping (String) -> [Type]? = { _ in nil },
                fieldMarks: @escaping (String) -> [Bool]? = { _ in nil },
                enumCaseMarks: @escaping (String) -> [[Bool]]? = { _ in nil },
                resolveOpaque: @escaping (Type) -> Type = { $0 }) {
        self.structFields = structFields
        self.enumCases = enumCases
        self.classFields = classFields
        self.fieldMarks = fieldMarks
        self.enumCaseMarks = enumCaseMarks
        self.resolveOpaque = resolveOpaque
    }

    // The shape of a class object's body, offsets from the object's start (the header word is offset 0, the
    // fields follow): what a stack-promoted instance's slot holds. Nil for any other type, whose slot holds a
    // value of the type itself (`shape`). The heap object's descriptor is built from the same fields.
    public func objectShape(_ t: Type) -> Shape? {
        guard case .named(let n, .class_) = t, let fields = classFields(n) else { return nil }
        return fieldsShape(fields, offsets: objectLayout(n, base: 8).offsets)
    }

    // The concrete type a `some I` stands for; an unresolvable one stays opaque.
    func concrete(_ t: Type) -> Type {
        if case .opaque = t { return resolveOpaque(t) }
        return t
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
            let s = fieldsShape(structFields(n) ?? [], offsets: structLayout(n).offsets)
            shapes[key] = s
            return s
        case .named(let n, .enum_):
            let key = "e:" + n
            if let s = shapes[key] { return s }
            guard !inProgress.contains(key) else { return Shape() }
            inProgress.insert(key)
            defer { inProgress.remove(key) }
            let s = enumShape(n)
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

    // An enum's shape, by its layout. Over its payload's extra inhabitants it is the payload's shape: a
    // payload-free case zeroes the payload and writes an extra inhabitant, which holds no object (null) and
    // which the payload's own decoding (a leaf's tag, a nested enum's tag) reads as holding none. With a tag,
    // a word that holds a reference in every payload case is a plain pointer (a payload-free case zeroes it),
    // and the rest of each case's payload shape is keyed by the tag; a tag-only enum holds nothing.
    private func enumShape(_ n: String) -> Shape {
        let all = enumCases(n) ?? []
        let layout = enumLayout(n)
        if case .overExtraInhabitants(let p) = layout { return fieldsShape(all[p], base: 0) }
        if case .spareBits = layout {
            // Every payload case's managed words are the same plain pointers (one carries the tag, which the
            // collector masks off), and a payload-free case zeroes them.
            let p = all.indices.first { !all[$0].isEmpty }!
            return fieldsShape(all[p], offsets: enumCaseLayout(n, p).offsets)
        }
        guard let tag = layout.tag else { return Shape() }
        let shapes = all.indices.map { fieldsShape(all[$0], offsets: enumCaseLayout(n, $0).offsets) }
        let payloads = all.indices.filter { !all[$0].isEmpty }
        var common: Set<Int> = payloads.first.map { Set(shapes[$0].managed) } ?? []
        for ci in payloads { common.formIntersection(shapes[ci].managed) }
        var cases: [ShapeCase] = []
        for ci in all.indices {
            let cs = Shape(managed: shapes[ci].managed.filter { !common.contains($0) }, conditional: shapes[ci].conditional)
            if !cs.isEmpty { cases.append(ShapeCase(tag: ci, shape: cs)) }
        }
        let conditional = cases.isEmpty ? []
            : [ShapeEntry(offset: 0, kind: .enumCases(name: n, tagOffset: tag.offset, cases: cases))]
        return Shape(managed: common.sorted(), conditional: conditional)
    }

    // The shape of fields laid out from byte `base` (`fieldsLayout`). A class or actor body, a closure or
    // fiber environment, and an actor message's arguments are this, at their object's first field offset.
    public func fieldsShape(_ fields: [Type], base: Int) -> Shape {
        fieldsShape(fields, offsets: fieldsLayout(fields, base: base).offsets)
    }

    // The shape of fields at the given offsets (a struct's or object's, from `structLayout`/`objectLayout`).
    public func fieldsShape(_ fields: [Type], offsets: [Int]) -> Shape {
        var s = Shape()
        for (f, off) in zip(fields, offsets) {
            s.append(shape(f), at: off)
        }
        return s
    }
}
