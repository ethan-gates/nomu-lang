import support   // Type

// Value layout (`design/plans/tasks/196-dense-value-layout.md`): each type's size and alignment in bytes and
// its fields' offsets. Every component reads it: codegen's LLVM types (checked against it), the shapes and GC
// descriptors, the value witnesses, array and buffer strides, debug info and the erased path. A size is always
// a multiple of the alignment, so an element's stride is its size.
//
// The layout is dense: `Bool` and `UInt8` are one byte at alignment 1, every other scalar leaf and every
// reference 8 bytes at alignment 8, a shaped leaf its own whole words. Each field sits at the next multiple of
// its alignment; a run ends rounded up to its largest alignment. A struct's or object's fields are placed by
// alignment, largest first, ties in declared order, except that fields from a type parameter come last in
// declared order (`memoryOrder`); an enum case's payload and an actor message's arguments keep declared
// order. An enum is laid out by kind (`EnumLayout`).
//
// Extra inhabitants (`design/plans/tasks/260-enum-layout.md`) are the bit patterns a type's storage can hold
// but no valid value uses: null for a reference, 2 to 255 for a `Bool`, a tag's unused values. An enum with
// one payload case keeps its other cases in them and needs no tag.

// Where a type keeps its extra inhabitants: an integer of `width` bytes at byte `offset`, whose value shifted
// right by `shift` is unused from `first`, for `count` values. The k-th is written by zeroing the whole value
// and storing `(first + k) << shift` there; a value holds one when the field's shifted value is in range.
public struct ExtraInhabitants: Equatable {
    public let offset: Int
    public let width: Int
    public let shift: Int
    public let first: Int
    public let count: Int

    public init(offset: Int, width: Int, shift: Int = 0, first: Int, count: Int) {
        self.offset = offset; self.width = width; self.shift = shift; self.first = first; self.count = count
    }

    // Counts are capped, as Swift caps them: an enum never has more cases than this.
    public static let maxCount = Int(Int32.max)

    // An integer field of `width` bytes whose values from `used` are unused.
    public static func unusedValues(offset: Int, width: Int, used: Int) -> ExtraInhabitants {
        let values = width >= 8 ? maxCount : min(1 << (8 * width), maxCount)
        return ExtraInhabitants(offset: offset, width: width, first: used, count: max(values - used, 0))
    }
}

// How an enum is laid out:
// - `tagOnly`: no case has a payload; the case index in the smallest integer that fits, at byte 0.
// - `overExtraInhabitants`: one case has a payload, laid out from byte 0 in declared order; the other cases are
//   its payload's extra inhabitants, the k-th payload-free case (declared order) the k-th.
// - `tagged`: several cases have payloads, or one whose extra inhabitants are too few. Each payload is laid
//   out from byte 0 in declared order, and the case index follows the largest at `tagOffset`: a word when the
//   payloads are word-aligned (the tag fills the padding and the collector reads it whole), else the smallest
//   integer that fits. A payload-free case zeroes the payload region.
// - `spareBits`: at least two cases have payloads, all among the first eight cases, and every payload case
//   holds a reference field at `tagOffset` (the first such offset); no payload field comes from a type
//   parameter, so erased code decides the same without a witness. Each payload is laid out from byte 0 with
//   no tag word: the case index rides in that reference's low 3 bits, which objects leave clear. Payload case
//   `c` stores the object's address plus `c` there; payload-free case `c` zeroes the region and stores
//   `c << 3`, below the first page, where no object lives. So the case is `word >> 3` below the first page and
//   `word & 7` above it. Every other word holds a reference in every payload case or in none, since with no
//   tag word the collector cannot decode per-case content. The collector masks the tag off every managed word
//   it reads (`rtUntag`).
// A generic enum's instances follow the same rules; the erased path computes them at run time from each type
// argument's value witness table (its size, alignment and extra inhabitants), so both agree.
public enum EnumLayout: Equatable {
    case tagOnly(width: Int)
    case overExtraInhabitants(payloadCase: Int)
    case tagged(tagOffset: Int, width: Int)
    case spareBits(payloadCases: [Int], tagOffset: Int)

    // The tag's byte offset and width; nil when the cases live in the payload's extra inhabitants or spare bits.
    public var tag: (offset: Int, width: Int)? {
        switch self {
        case .tagOnly(let w): return (0, w)
        case .overExtraInhabitants, .spareBits: return nil
        case .tagged(let off, let w): return (off, w)
        }
    }

    // A spare-bit enum's payload cases go in the low 3 bits of an 8-byte-aligned address; its payload-free
    // cases are `c << 3`, below the first page.
    public static let spareBitCases = 8
    public static let spareBitShift = 3
}

// The layout of a run of fields from a starting byte offset: a struct's or an enum case's fields from 0; a
// class's or actor's past the header word, an actor message's arguments past its prefix.
public struct FieldsLayout: Equatable {
    public let offsets: [Int]   // each field's byte offset, by declared position
    public let end: Int         // the byte past the last field, rounded up to `align`
    public let align: Int       // the largest field alignment; 1 for no fields

    public init(offsets: [Int], end: Int, align: Int) {
        self.offsets = offsets
        self.end = end
        self.align = align
    }
}

extension ShapeEnv {
    public func size(_ t: Type) -> Int { sizeAndAlign(t).size }
    public func align(_ t: Type) -> Int { sizeAndAlign(t).align }

    // Fields in declared order from byte `base`.
    public func fieldsLayout(_ fields: [Type], base: Int) -> FieldsLayout {
        orderedLayout(fields, order: Array(fields.indices), base: base)
    }

    // A struct's fields, from byte 0, in memory order.
    public func structLayout(_ name: String) -> FieldsLayout {
        let fields = structFields(name) ?? []
        return orderedLayout(fields, order: memoryOrder(fields, marks: fieldMarks(name)), base: 0)
    }

    // A class's or actor's fields, from byte `base` (past the header word, and an actor's mailbox), in memory
    // order.
    public func objectLayout(_ name: String, base: Int) -> FieldsLayout {
        let fields = classFields(name) ?? []
        return orderedLayout(fields, order: memoryOrder(fields, marks: fieldMarks(name)), base: base)
    }

    // The declared positions of a struct's or object's fields in memory order: unmarked fields by alignment,
    // largest first, ties in declared order, then fields from a type parameter (`marks`) in declared order.
    public func memoryOrder(_ fields: [Type], marks: [Bool]?) -> [Int] {
        let marked = { (i: Int) -> Bool in marks.map { i < $0.count && $0[i] } ?? false }
        let aligns = fields.map { sizeAndAlign($0).align }
        return fields.indices.sorted { a, b in
            if marked(a) != marked(b) { return !marked(a) }
            if !marked(a), aligns[a] != aligns[b] { return aligns[a] > aligns[b] }
            return a < b
        }
    }

    // Fields placed in `order` (declared positions) from byte `base`; offsets by declared position.
    func orderedLayout(_ fields: [Type], order: [Int], base: Int) -> FieldsLayout {
        var offsets = [Int](repeating: 0, count: fields.count)
        var off = base, maxAlign = 1
        for i in order {
            let (size, align) = sizeAndAlign(fields[i])
            off = ShapeEnv.alignUp(off, align)
            offsets[i] = off
            off += size
            maxAlign = max(maxAlign, align)
        }
        return FieldsLayout(offsets: offsets, end: ShapeEnv.alignUp(off, maxAlign), align: maxAlign)
    }

    // Case `caseIndex`'s payload fields, offsets from the enum's start: every payload begins at byte 0.
    public func enumCaseLayout(_ name: String, _ caseIndex: Int) -> FieldsLayout {
        let cases = enumCases(name) ?? []
        return fieldsLayout(caseIndex < cases.count ? cases[caseIndex] : [], base: 0)
    }

    // The payload region: the largest payload's end and the largest alignment.
    public func enumPayloadRegion(_ name: String) -> (end: Int, align: Int) {
        let layouts = (enumCases(name) ?? []).map { fieldsLayout($0, base: 0) }
        return (layouts.map(\.end).max() ?? 0, layouts.map(\.align).max() ?? 1)
    }

    public func enumLayout(_ name: String) -> EnumLayout {
        if let l = enumLayouts[name] { return l }
        let l = computeEnumLayout(name)
        enumLayouts[name] = l
        return l
    }

    private func computeEnumLayout(_ name: String) -> EnumLayout {
        let cases = enumCases(name) ?? []
        let payloadCases = cases.indices.filter { !cases[$0].isEmpty }
        if payloadCases.isEmpty { return .tagOnly(width: ShapeEnv.tagWidth(cases.count)) }
        if payloadCases.count == 1, let p = payloadCases.first,
           (payloadExtraInhabitants(cases[p])?.count ?? 0) >= cases.count - 1 {
            return .overExtraInhabitants(payloadCase: p)
        }
        if spareBits, let tagOffset = spareBitWord(name, payloadCases) {
            return .spareBits(payloadCases: payloadCases, tagOffset: tagOffset)
        }
        let region = enumPayloadRegion(name)
        let width = region.align >= 8 ? 8 : ShapeEnv.tagWidth(cases.count)
        return .tagged(tagOffset: ShapeEnv.alignUp(region.end, width), width: width)
    }

    // The word a spare-bit enum's case rides in, if the enum qualifies (`EnumLayout.spareBits`): the first offset
    // at which every payload case holds a reference field.
    private func spareBitWord(_ name: String, _ payloadCases: [Int]) -> Int? {
        let cases = enumCases(name) ?? []
        guard payloadCases.count >= 2, payloadCases.allSatisfy({ $0 < EnumLayout.spareBitCases }),
              cases.count < ShapeEnv.referenceExtraInhabitants >> EnumLayout.spareBitShift else { return nil }
        let marks = enumCaseMarks(name)
        if let marks, payloadCases.contains(where: { $0 < marks.count && marks[$0].contains(true) }) { return nil }
        // Each payload case's reference fields, by offset; and every case's managed words must be the same.
        var referenceOffsets: Set<Int>? = nil
        var managed: [Int]? = nil
        for c in payloadCases {
            let layout = enumCaseLayout(name, c)
            let refs = Set(cases[c].indices.filter { ShapeEnv.isReference(cases[c][$0]) }.map { layout.offsets[$0] })
            referenceOffsets = referenceOffsets.map { $0.intersection(refs) } ?? refs
            let shape = fieldsShape(cases[c], offsets: layout.offsets)
            guard shape.conditional.isEmpty, managed == nil || managed! == shape.managed.sorted() else { return nil }
            managed = shape.managed.sorted()
        }
        return referenceOffsets?.min()
    }

    // The smallest integer, in bytes, that holds `cases` distinct tags.
    public static func tagWidth(_ cases: Int) -> Int {
        cases <= 1 << 8 ? 1 : cases <= 1 << 16 ? 2 : 4
    }

    // Which extra inhabitant an `overExtraInhabitants` enum's payload-free case `caseIndex` is: its position
    // among the payload-free cases.
    public func enumExtraInhabitantIndex(_ name: String, _ caseIndex: Int) -> Int {
        let cases = enumCases(name) ?? []
        return cases.indices.filter { $0 < caseIndex && cases[$0].isEmpty }.count
    }

    // The extra inhabitants of fields laid out in declared order from byte 0: the field with the most, ties
    // to the first.
    public func payloadExtraInhabitants(_ fields: [Type]) -> ExtraInhabitants? {
        best(fields, offsets: fieldsLayout(fields, base: 0).offsets)
    }

    private func best(_ fields: [Type], offsets: [Int]) -> ExtraInhabitants? {
        var out: ExtraInhabitants? = nil
        for (f, off) in zip(fields, offsets) {
            guard let x = extraInhabitants(f), x.count > (out?.count ?? 0) else { continue }
            out = ExtraInhabitants(offset: off + x.offset, width: x.width, shift: x.shift, first: x.first, count: x.count)
        }
        return out
    }

    // Whether a value of type `t` is one reference.
    public static func isReference(_ t: Type) -> Bool {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array: return true
        default: return false
        }
    }

    // A reference's extra inhabitants: the addresses below the first page, where no object lives. The
    // collector and every root walk treat a managed word below it as holding no object (the runtime's
    // `rtNotObjectBound`).
    public static let referenceExtraInhabitants = 4096

    // A type's extra inhabitants; nil when it has none (`Int`, `Double`, `UInt8`, a raw pointer, an erased `T`).
    public func extraInhabitants(_ t: Type) -> ExtraInhabitants? {
        switch t {
        case .stringBase:
            // `word1`'s top nibble is the tag: `immortal`, `small` and `heap` use 0 to 2.
            let leaf = ShapeLeaf.stringBase
            return ExtraInhabitants(offset: leaf.tagOffset, width: 8, shift: leaf.tagShift, first: 3, count: 13)
        case .bool:
            return ExtraInhabitants(offset: 0, width: 1, first: 2, count: 254)
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            return ExtraInhabitants(offset: 0, width: 8, first: 0, count: ShapeEnv.referenceExtraInhabitants)
        case .named(let n, .struct_):
            guard let fields = structFields(n) else { return nil }
            let key = "xs:" + n
            if let x = extras[key] { return x }
            guard !inProgress.contains(key) else { return nil }
            inProgress.insert(key)
            defer { inProgress.remove(key) }
            let x = best(fields, offsets: structLayout(n).offsets)
            extras[key] = .some(x)
            return x
        case .named(let n, .enum_):
            guard let cases = enumCases(n) else { return nil }
            switch enumLayout(n) {
            case .tagOnly(let w):
                return .unusedValues(offset: 0, width: w, used: cases.count)
            case .tagged(let off, let w):
                return .unusedValues(offset: off, width: w, used: cases.count)
            case .spareBits(_, let off):
                // The values below the first page past the case indices.
                return ExtraInhabitants(offset: off, width: 8, shift: EnumLayout.spareBitShift, first: cases.count,
                                        count: (ShapeEnv.referenceExtraInhabitants >> EnumLayout.spareBitShift) - cases.count)
            case .overExtraInhabitants(let p):
                guard let x = payloadExtraInhabitants(cases[p]) else { return nil }
                let used = cases.count - 1
                guard x.count > used else { return nil }
                return ExtraInhabitants(offset: x.offset, width: x.width, shift: x.shift, first: x.first + used,
                                        count: x.count - used)
            }
        case .opaque:
            let c = concrete(t)
            if case .opaque = c { return nil }
            return extraInhabitants(c)
        default:
            return nil
        }
    }

    public static func alignUp(_ v: Int, _ align: Int) -> Int { (v + align - 1) / align * align }

    func sizeAndAlign(_ t: Type) -> (size: Int, align: Int) {
        if let leaf = ShapeLeaf.of(t) { return (leaf.size, leaf.align) }
        switch t {
        case .named(let n, .struct_):
            return cachedLayout("ls:" + n) {
                guard structFields(n) != nil else { return (8, 8) }
                let l = structLayout(n)
                return (l.end, l.align)
            }
        case .named(let n, .enum_):
            return cachedLayout("le:" + n) {
                switch enumLayout(n) {
                case .tagOnly(let w):
                    return (w, w)
                case .overExtraInhabitants(let p):
                    let l = fieldsLayout((enumCases(n) ?? [])[p], base: 0)
                    return (l.end, l.align)
                case .tagged(let off, let w):
                    let a = max(enumPayloadRegion(n).align, w)
                    return (ShapeEnv.alignUp(off + w, a), a)
                case .spareBits:
                    let region = enumPayloadRegion(n)
                    return (ShapeEnv.alignUp(region.end, region.align), region.align)
                }
            }
        case .bool, .uint8:
            return (1, 1)
        case .opaque:
            let c = concrete(t)
            if case .opaque = c { return (8, 8) }
            return sizeAndAlign(c)
        default:
            return (8, 8)
        }
    }

    private func cachedLayout(_ key: String, _ compute: () -> (size: Int, align: Int)) -> (size: Int, align: Int) {
        if let l = layouts[key] { return l }
        guard !inProgress.contains(key) else { return (8, 8) }   // a recursive value type, rejected by the checker
        inProgress.insert(key)
        defer { inProgress.remove(key) }
        let l = compute()
        layouts[key] = l
        return l
    }
}
