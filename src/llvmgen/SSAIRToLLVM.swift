import sema
import mangle

import ssair
import noir
import ast
import support
import Foundation
import LLVM_C

// M7 · 7.2.3 — the SSAIR → LLVM egress, the sole backend path since M7.7. A CFG-walk that holds one
// `LLVMGen` and lowers through its GC-ABI primitives (object layout / alloc / barrier / witness / actor
// ABI emitted from one place, §7.0.4). SSAIR supplies a CFG with block arguments and SSA values, so
// this egress maps blocks 1:1 (block args → LLVM φ) and keeps SSA values in a per-function id→value
// table with no per-scalar spill. (`LLVMGen` was factored out as a shared emitter while the retired
// NOIR tree-walk still co-existed; it now serves this egress alone.)
//
// Type-layout + witness + actor metadata come from the original NOIR module (populated into `LLVMGen`),
// plus the closure/fiber environment aggregates the SSA module synthesized. Function *declaration* is
// done here (the `m:Type:method` → `Mangle.method` symbol); the
// shared witness/actor thunks find the resulting callables already declared, so their internal
// `declareMethod`/`declareActorHandler` calls early-return without needing NOIR method bodies.
final class SSAIRToLLVM {
    let e: LLVMGen

    // Globals (task 224) by NOIR name: the LLVM global, and for a constant one its folded value, which a
    // read in this module uses directly. A global read from another module (a shipped generic body naming
    // it origin-keyed) is declared on first use.
    var globalVars: [String: (global: LLVMValueRef, constant: LLVMValueRef?)] = [:]
    // The constant global being folded, which names a `Runtime.staticStorage` block.
    private var foldingGlobal: SSAGlobal?

    // Per-function state, reset in `defineFunction`.
    var values: [Int: LLVMValueRef] = [:]          // SSAValue.id → LLVM value
    var blockMap: [Int: LLVMBasicBlockRef] = [:]   // SSABlock.id → LLVM basic block
    var blocksById: [Int: SSABlock] = [:]          // SSABlock.id → the block (for edge φ wiring)
    // Shaped-value frame homes (task 176 Stage 3, Model 1): a value with conditional content (a `String`, or
    // a struct or enum holding one or a managed enum payload) live across a safepoint lives in an
    // address-taken alloca — its home. Reads load it with its conditional managed words volatile
    // (`loadReloading`), so the collector's in-place rewrite is observed; writes store to it. The home's
    // address and the type's shape ordinal go into each spanning safepoint's `"deopt"` bundle, keeping it
    // memory-resident and recording it as a shaped root. A value that never spans a safepoint stays a pure
    // SSA value (absent here). Populated per function from `computeShapedLiveness`.
    // SSAValue.id → its home alloca and the value's type.
    var shapedHome: [Int: (slot: LLVMValueRef, type: Type)] = [:]
    var shapedLive: ShapedLiveness?                // current function's shaped-value liveness
    // Recorded frame slots (task 176.3a, 176.5): a `stackAlloc` with conditional content, or with managed
    // content and an escaped address (`recordedSlots`). Live across or used by a safepoint, its base + the
    // type's shape ordinal are recorded so the collector updates its managed words in place. `shapedSlots`
    // maps the slot's SSA id → its type; `slotRoot` maps a slot or slot-derived address → the slot.
    var shapedSlots: [Int: Type] = [:]
    var slotRoot = RecordedSlots()
    var shapedSlotLive: ShapedLiveness?            // liveness of the recorded slots and their derived addresses
    // φ incomings, deferred until every block's instructions are lowered: a branch argument may be
    // defined in a block that lowers after the branch's block (e.g. a loop latch whose block id
    // precedes the case block that computes the carried value), so resolving `val(arg)` eagerly would
    // miss it. Captured at terminator time (the predecessor is the current block), wired at the end.
    var pendingIncomings: [(phi: LLVMValueRef, pred: LLVMBasicBlockRef, arg: SSAValue)] = []

    // Erased generic ABI (backend.md §4), set in `defineFunction` for an erased generic (non-empty
    // `generics`) and read when lowering its body. `curVWTParams` maps a type-parameter name to its VWT
    // pointer parameter; `curPWTParams` maps "T::iface" to the PWT pointer parameter for that bound
    // (used to dispatch a requirement call on a `.typeParam` receiver); `curSretParam` is the
    // caller-allocated result buffer; `curReturnVWT` is the VWT for the returned type parameter (sizing
    // the move memcpy). All empty/nil for a normal (fully-concrete) function.
    var curVWTParams: [String: LLVMValueRef] = [:]
    var curDictionary: LLVMValueRef? = nil            // this erased function's dictionary pointer, and its words
    var curDictionaryWords: [LLVMValueRef] = []
    var curSizes: [String: LLVMValueRef] = [:]        // each type parameter's size, read at entry
    var curAligns: [String: LLVMValueRef] = [:]       // its alignment, read from its VWT at entry
    // This module's erased functions, by callable key: an erased body calls them through the witness ABI.
    var erasedSigs: [String: ExternalGenericSig] = [:]
    var curPWTParams: [String: LLVMValueRef] = [:]
    var curSretParam: LLVMValueRef?
    var curReturnType: Type?   // an erased function's return type (mentions a type parameter); sizes the `ret` move

    // Producer-internal typed GC roots (task 100.4.3.6). When an erased body *constructs* a composed
    // value with a `T` field (`makeStruct`/`makeEnum` → `erased.box`/`erased.enum`), that `T` lives in an
    // opaque byte buffer the stackmap can't see into, so the buffer's `T`-component must be registered on
    // the fiber's shadow stack for as long as the composed value is live — else a collection while it is
    // live across an allocation would strand or dangle the managed pointers inside it. `curProducerSave`
    // is the shadow-top captured in the erased prologue (nil when the frame constructs no such value); the
    // epilogue `rtShadowPopTo`s it before every `ret`, so the frame's pushes unwind on any exit. A POD `T`
    // is registered too — its VWT descriptor reports no managed pointers, so the walk expands it to
    // nothing (correct, a little redundant).
    //
    // Loop constructions (hazard (b) in the milestone doc) use a loop-scoped save: each loop header saves
    // the shadow-top into `headerSaveSlot[header]`, and every back-edge `rtShadowPopTo`s that save before
    // branching, so an iteration's pushes are cleared before the next iteration re-pushes the same
    // entry-hoisted nodes — without the pop the re-push would make a node's `prev` point at itself.
    // `curBackEdges` maps a block to the header it back-branches to.
    var curProducerSave: LLVMValueRef?
    var curBackEdges: [Int: Int] = [:]
    var headerSaveSlot: [Int: LLVMValueRef] = [:]
    var curBlockId: Int = -1
    var curChecksStack = false                      // the function being lowered checks its stack (`checksStack`)
    private var selectOptions: [String: LLVMValueRef] = [:]   // a select receive's `Option`, by area value id and case
    private var selectSlots: [String: LLVMValueRef] = [:]     // a select case's destination or value slot, likewise

    // The erased ABI's PWT parameters (backend.md §4), in fixed order: one per (type parameter, bound),
    // type parameters in declaration order and bounds name-sorted — the identical order the producer
    // declares and the consumer threads, so they line up across the boundary.
    private func erasedPWTs(_ f: SSAFunction) -> [(param: String, iface: String)] {
        f.generics.flatMap { gp in gp.bounds.sorted().map { (gp.name, $0) } }
    }

    // Derived-VWT layout (task 100.4.3.3.4; backend.md §4): the value layout (`ShapeEnv.fieldsLayout`) computed
    // at run time, since a type parameter's size and alignment come from its VWT. Each field sits at the next
    // multiple of its alignment, a run ends rounded up to its largest alignment, and an enum is a tag word and
    // a word-rounded payload, exactly as the static layout, so erased and specialized code agree. A concrete
    // type's size and alignment are constants, which fold.
    private func erasedTypeSize(_ t: Type, _ span: Span) -> LLVMValueRef? {
        switch t {
        case .typeParam(let name):
            guard let size = curSizes[name] else {
                e.fail("100.4.3.3.4: no size for type parameter '\(name)'", span); return nil
            }
            return size
        case .generic(let base, let args):
            if e.classMap[base] != nil { return LLVMConstInt(e.i64, 8, 0) }   // a reference
            if let s = e.structMap[base] {
                let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
                return erasedFieldsLayout(s.fields.map { substType($0.type, subst) }, order: erasedMemoryOrder(s.fields),
                                          base: 0, span)?.end
            }
            if let en = e.enumMap[base] {
                guard let l = erasedEnumLayout(en, args, span) else { return nil }
                switch l.kind {
                case .tagOnly(let w):
                    return const64(w)
                case .single, .multi:
                    return l.size
                case .spareBits:
                    return const64(e.shapes.size(.named(base, .enum_)))
                }
            }
            e.fail("100.4.3.3.4: no layout for generic '\(base)'", span); return nil
        default:
            return LLVMConstInt(e.i64, UInt64(e.sizeOf(t)), 0)
        }
    }

    // A type's alignment: a type parameter's from its VWT, a composed generic's the largest of its fields'
    // (an enum's and a class reference's a word), a concrete type's from the value layout.
    private func erasedAlign(_ t: Type, _ span: Span) -> LLVMValueRef? {
        switch t {
        case .typeParam(let name):
            guard let a = curAligns[name] else { e.fail("no alignment for type parameter '\(name)'", span); return nil }
            return a
        case .generic(let base, let args):
            if let s = e.structMap[base] {
                let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
                return erasedFieldsLayout(s.fields.map { substType($0.type, subst) }, base: 0, span)?.align
            }
            if let en = e.enumMap[base] {
                guard let l = erasedEnumLayout(en, args, span) else { return nil }
                switch l.kind {
                case .tagOnly(let w): return const64(w)
                case .single, .multi: return l.align
                case .spareBits: return const64(e.shapes.align(.named(base, .enum_)))
                }
            }
            return LLVMConstInt(e.i64, 8, 0)
        default:
            return LLVMConstInt(e.i64, UInt64(e.shapes.align(t)), 0)
        }
    }

    // The run-time layout of fields placed in `order` (declared positions; declared order when nil) from byte
    // `base`: the end rounded up to the largest alignment, that alignment, and the offset of field `offsetOf`.
    private func erasedFieldsLayout(_ types: [Type], order: [Int]? = nil, base: Int, _ span: Span, offsetOf: Int? = nil)
        -> (end: LLVMValueRef, align: LLVMValueRef, offset: LLVMValueRef?)? {
        var off = LLVMConstInt(e.i64, UInt64(base), 0)!
        var maxAlign = LLVMConstInt(e.i64, 1, 0)!
        var offset: LLVMValueRef? = nil
        for k in order ?? Array(types.indices) {
            let t = types[k]
            guard let size = erasedTypeSize(t, span), let a = erasedAlign(t, span) else { return nil }
            off = alignUp(off, a)
            if k == offsetOf { offset = off }
            off = LLVMBuildAdd(b, off, size, "end")!
            maxAlign = umax(maxAlign, a)
        }
        return (alignUp(off, maxAlign), maxAlign, offset)
    }

    // A struct's or class's template fields in memory order (`ShapeEnv.memoryOrder`): the fields whose type
    // mentions no type parameter by alignment, largest first, then the rest in declared order, as the
    // specialized type's fields are placed. The first group's alignments are compile-time constants.
    private func erasedMemoryOrder(_ fields: [NOIRField]) -> [Int] {
        let marks = fields.map { $0.type.mentionsTypeParameter }
        let aligns = fields.map { $0.type.mentionsTypeParameter ? 0 : staticAlign($0.type) }
        return fields.indices.sorted { a, b in
            if marks[a] != marks[b] { return !marks[a] }
            if !marks[a], aligns[a] != aligns[b] { return aligns[a] > aligns[b] }
            return a < b
        }
    }

    // The alignment of a type that mentions no type parameter: a generic struct application's from its
    // template's fields, since the shape environment knows only its specialized name.
    private func staticAlign(_ t: Type) -> Int {
        if case .generic(let base, let args) = t, let s = e.structMap[base] {
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            return s.fields.reduce(1) { max($0, staticAlign(substType($1.type, subst))) }
        }
        // A generic enum application's from its run-time layout, which folds to a constant when no argument is a
        // type parameter.
        if case .generic(let base, _) = t, e.enumMap[base] != nil, let a = erasedAlign(t, e.zeroSpan),
           LLVMIsAConstantInt(a) != nil {
            return Int(LLVMConstIntGetZExtValue(a))
        }
        if case .generic = t { return 8 }
        return e.shapes.align(t)
    }

    // The run-time byte offset of field `fieldIndex` in a struct-composed generic. A struct value buffer
    // starts at offset 0; a **class** object (reference receiver, task 100.4.3.9) starts its user fields past
    // the 8-byte object header. Past the last field it is the value's size, or the object's (rounded up to a
    // word, as `objectSize`), which `lowerErasedAlloc` allocates.
    private func erasedFieldOffset(_ composed: Type, _ fieldIndex: Int, _ span: Span) -> LLVMValueRef? {
        guard case .generic(let base, let args) = composed else { return LLVMConstInt(e.i64, 0, 0) }
        let generics: [NOIRGenericParam], fields: [NOIRField], header: Int
        if let s = e.structMap[base] { generics = s.generics; fields = s.fields; header = 0 }
        else if let c = e.classMap[base] { generics = c.generics; fields = c.fields; header = 8 }
        else { return LLVMConstInt(e.i64, 0, 0) }
        let subst = Dictionary(uniqueKeysWithValues: zip(generics.map(\.name), args))
        guard let l = erasedFieldsLayout(fields.map { substType($0.type, subst) }, order: erasedMemoryOrder(fields),
                                         base: header, span, offsetOf: fieldIndex) else { return nil }
        if let offset = l.offset { return offset }
        return header == 0 ? l.end : alignUp(l.end, LLVMConstInt(e.i64, 8, 0))
    }

    // The run-time byte offset of payload field `fieldIndex` of case `caseIndex` in an erased generic enum:
    // every payload begins at byte 0.
    private func erasedEnumPayloadOffset(_ base: String, _ args: [Type], _ caseIndex: Int, _ fieldIndex: Int, _ span: Span) -> LLVMValueRef? {
        guard let en = e.enumMap[base], caseIndex < en.cases.count else { return const64(0) }
        let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
        let fields = en.cases[caseIndex].fields
        guard fieldIndex < fields.count else { return const64(0) }
        return erasedFieldsLayout(fields.map { substType($0.type, subst) }, base: 0, span, offsetOf: fieldIndex)?.offset
    }

    private func payloadCaseCount(_ en: NOIREnum) -> Int { en.cases.filter { !$0.fields.isEmpty }.count }

    private func const64(_ v: Int) -> LLVMValueRef { LLVMConstInt(e.i64, UInt64(bitPattern: Int64(v)), 0) }

    // MARK: Erased enum layout

    // A type's extra inhabitants at run time (`ExtraInhabitants`), each an `i64`; a count of 0 means none.
    struct DynExtraInhabitants {
        var count, offset, first, width, shift: LLVMValueRef
    }

    // An enum's layout at run time: `ShapeEnv.enumLayout`'s rules, over the type arguments' value witnesses in an
    // erased body, or the static layout as constants. Which cases have payloads fixes the kind; over one payload
    // case, whether the other cases live in the payload's extra inhabitants (`overXI`) is decided at run time,
    // and the payload's extra inhabitants, the appended tag's place, the size and the alignment with it. With
    // several (`multi`), the tag follows the largest payload.
    struct DynEnumLayout {
        enum Kind { case tagOnly(width: Int), single(payloadCase: Int), multi, spareBits(payloadCases: [Int], tagOffset: Int) }
        let kind: Kind
        let cases: Int
        var overXI: LLVMValueRef? = nil
        var payloadXI: DynExtraInhabitants? = nil
        var tagOffset: LLVMValueRef? = nil
        var tagWidth: LLVMValueRef? = nil
        var size: LLVMValueRef? = nil
        var align: LLVMValueRef? = nil
    }

    private func constXI(_ x: ExtraInhabitants?) -> DynExtraInhabitants? {
        guard let x else { return nil }
        return DynExtraInhabitants(count: const64(x.count), offset: const64(x.offset), first: const64(x.first),
                                   width: const64(x.width), shift: const64(x.shift))
    }

    private func shiftedXI(_ x: DynExtraInhabitants, by off: LLVMValueRef) -> DynExtraInhabitants {
        var y = x
        y.offset = LLVMBuildAdd(b, x.offset, off, "xi.off")!
        return y
    }

    // The one with more extra inhabitants, ties to `a` (the earlier field), as `ShapeEnv` picks.
    private func moreXI(_ a: DynExtraInhabitants?, _ x: DynExtraInhabitants) -> DynExtraInhabitants {
        guard let a else { return x }
        let more = LLVMBuildICmp(b, LLVMIntUGT, x.count, a.count, "xi.more")!
        func pick(_ p: LLVMValueRef, _ q: LLVMValueRef) -> LLVMValueRef { LLVMBuildSelect(b, more, p, q, "xi.pick")! }
        return DynExtraInhabitants(count: pick(x.count, a.count), offset: pick(x.offset, a.offset),
                                   first: pick(x.first, a.first), width: pick(x.width, a.width), shift: pick(x.shift, a.shift))
    }

    // An integer field of `width` bytes whose values from `used` are unused (`ExtraInhabitants.unusedValues`).
    private func unusedValues(offset: LLVMValueRef, width: Int, used: Int) -> DynExtraInhabitants {
        let x = ExtraInhabitants.unusedValues(offset: 0, width: width, used: used)
        return DynExtraInhabitants(count: const64(x.count), offset: offset, first: const64(used), width: const64(width),
                                   shift: const64(0))
    }

    // A type's extra inhabitants in an erased body: a type parameter's from its value witness, a composed
    // generic's from its parts, a concrete type's from the static layout.
    private func erasedExtraInhabitants(_ t: Type, _ span: Span) -> DynExtraInhabitants? {
        switch t {
        case .typeParam(let name):
            guard let vwt = curVWTParams[name] else { return nil }
            let x = e.loadVWTExtraInhabitants(vwt)
            return DynExtraInhabitants(count: x.count, offset: x.offset, first: x.first, width: x.width, shift: x.shift)
        case .generic(let base, let args):
            if e.classMap[base] != nil {
                return constXI(ExtraInhabitants(offset: 0, width: 8, first: 0, count: ShapeEnv.referenceExtraInhabitants))
            }
            if let s = e.structMap[base] {
                let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
                var best: DynExtraInhabitants? = nil
                for (i, f) in s.fields.enumerated() {
                    guard let x = erasedExtraInhabitants(substType(f.type, subst), span),
                          let off = erasedFieldOffset(t, i, span) else { continue }
                    best = moreXI(best, shiftedXI(x, by: off))
                }
                return best
            }
            if let en = e.enumMap[base], let l = erasedEnumLayout(en, args, span) { return enumXI(l) }
            return nil
        case .array, .function, .existential, .composition:
            return constXI(ExtraInhabitants(offset: 0, width: 8, first: 0, count: ShapeEnv.referenceExtraInhabitants))
        default:
            return constXI(e.shapes.extraInhabitants(t))
        }
    }

    // An enum's own extra inhabitants, from its layout (`ShapeEnv.extraInhabitants`).
    private func enumXI(_ l: DynEnumLayout) -> DynExtraInhabitants? {
        switch l.kind {
        case .tagOnly(let w):
            return unusedValues(offset: const64(0), width: w, used: l.cases)
        case .spareBits(_, let tagOffset):
            return constXI(ExtraInhabitants(offset: tagOffset, width: 8, shift: EnumLayout.spareBitShift, first: l.cases,
                                            count: (ShapeEnv.referenceExtraInhabitants >> EnumLayout.spareBitShift) - l.cases))
        case .single, .multi:
            let used = l.cases - 1
            let narrow = ShapeEnv.tagWidth(l.cases)
            let wordTag = LLVMBuildICmp(b, LLVMIntEQ, l.tagWidth!, const64(8), "tag.word")!
            let tagCount = LLVMBuildSelect(b, wordTag, unusedValues(offset: const64(0), width: 8, used: l.cases).count,
                                           unusedValues(offset: const64(0), width: narrow, used: l.cases).count, "tag.count")!
            let tagged = DynExtraInhabitants(count: tagCount, offset: l.tagOffset!, first: const64(l.cases),
                                             width: l.tagWidth!, shift: const64(0))
            if case .multi = l.kind { return tagged }
            guard let x = l.payloadXI else {
                // With no payload extra inhabitants the cases sit over the payload only when there is one case.
                let none = DynExtraInhabitants(count: const64(0), offset: const64(0), first: const64(0),
                                               width: const64(8), shift: const64(0))
                return l.cases == 1 ? none : tagged
            }
            let over = DynExtraInhabitants(count: LLVMBuildSub(b, x.count, const64(used), "xi.left")!, offset: x.offset,
                                           first: LLVMBuildAdd(b, x.first, const64(used), "xi.first")!,
                                           width: x.width, shift: x.shift)
            let o = l.overXI!
            func pick(_ p: LLVMValueRef, _ q: LLVMValueRef) -> LLVMValueRef { LLVMBuildSelect(b, o, p, q, "xi.enum")! }
            return DynExtraInhabitants(count: pick(over.count, tagged.count), offset: pick(over.offset, tagged.offset),
                                       first: pick(over.first, tagged.first), width: pick(over.width, tagged.width),
                                       shift: pick(over.shift, tagged.shift))
        }
    }

    // An erased generic enum's layout from its template and arguments.
    private func erasedEnumLayout(_ en: NOIREnum, _ args: [Type], _ span: Span) -> DynEnumLayout? {
        let n = en.cases.count
        let payloadCases = en.cases.indices.filter { !en.cases[$0].fields.isEmpty }
        if payloadCases.isEmpty { return DynEnumLayout(kind: .tagOnly(width: ShapeEnv.tagWidth(n)), cases: n) }
        let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
        // The spare-bit rule reads the template's field types, which are what a specialized instance's marks
        // record: a field mentioning a type parameter never qualifies, so a qualifying template's layout is the
        // static one.
        if payloadCases.allSatisfy({ c in !en.cases[c].fields.contains { $0.type.mentionsTypeParameter } }),
           case .spareBits(let payloads, let tagOffset) = e.shapes.enumLayout(en.name) {
            return DynEnumLayout(kind: .spareBits(payloadCases: payloads, tagOffset: tagOffset), cases: n)
        }
        guard payloadCases.count == 1, let p = payloadCases.first else {
            // The payload region: the largest payload's end and the largest alignment; the tag follows it.
            var end = const64(0), align = const64(1)
            for c in payloadCases {
                guard let l = erasedFieldsLayout(en.cases[c].fields.map { substType($0.type, subst) }, base: 0, span) else { return nil }
                end = umax(end, l.end)
                align = umax(align, l.align)
            }
            let wide = LLVMBuildICmp(b, LLVMIntUGE, align, const64(8), "pl.wide")!
            let tagWidth = LLVMBuildSelect(b, wide, const64(8), const64(ShapeEnv.tagWidth(n)), "tag.w")!
            let tagOffset = alignUp(end, tagWidth)
            let taggedAlign = umax(align, tagWidth)
            return DynEnumLayout(kind: .multi, cases: n, tagOffset: tagOffset, tagWidth: tagWidth,
                                 size: alignUp(LLVMBuildAdd(b, tagOffset, tagWidth, "tag.end")!, taggedAlign), align: taggedAlign)
        }
        let fields = en.cases[p].fields.map { substType($0.type, subst) }
        guard let payload = erasedFieldsLayout(fields, base: 0, span) else { return nil }
        var xi: DynExtraInhabitants? = nil
        for (i, f) in fields.enumerated() {
            guard let x = erasedExtraInhabitants(f, span),
                  let off = erasedFieldsLayout(fields, base: 0, span, offsetOf: i)?.offset else { continue }
            xi = moreXI(xi, shiftedXI(x, by: off))
        }
        let overXI = xi.map { LLVMBuildICmp(b, LLVMIntUGE, $0.count, const64(n - 1), "xi.fits")! }
            ?? LLVMConstInt(e.i1, n == 1 ? 1 : 0, 0)!
        let wide = LLVMBuildICmp(b, LLVMIntUGE, payload.align, const64(8), "pl.wide")!
        let tagWidth = LLVMBuildSelect(b, wide, const64(8), const64(ShapeEnv.tagWidth(n)), "tag.w")!
        let tagOffset = alignUp(payload.end, tagWidth)
        let taggedAlign = umax(payload.align, tagWidth)
        let taggedSize = alignUp(LLVMBuildAdd(b, tagOffset, tagWidth, "tag.end")!, taggedAlign)
        return DynEnumLayout(kind: .single(payloadCase: p), cases: n, overXI: overXI, payloadXI: xi,
                             tagOffset: tagOffset, tagWidth: tagWidth,
                             size: LLVMBuildSelect(b, overXI, payload.end, taggedSize, "enum.size")!,
                             align: LLVMBuildSelect(b, overXI, payload.align, taggedAlign, "enum.align")!)
    }

    // A named enum's static layout in the same form, so the code that reads and writes a case serves both.
    private func namedEnumLayout(_ name: String) -> DynEnumLayout? {
        guard let en = e.enumMap[name] else { return nil }
        let n = en.cases.count
        let payloadXI = { (p: Int) in self.constXI(self.e.shapes.payloadExtraInhabitants(en.cases[p].fields.map(\.type))) }
        switch e.shapes.enumLayout(name) {
        case .tagOnly(let w):
            return DynEnumLayout(kind: .tagOnly(width: w), cases: n)
        case .overExtraInhabitants(let p):
            return DynEnumLayout(kind: .single(payloadCase: p), cases: n, overXI: LLVMConstInt(e.i1, 1, 0),
                                 payloadXI: payloadXI(p), tagOffset: const64(0), tagWidth: const64(8))
        case .tagged(let off, let w):
            let payloads = en.cases.indices.filter { !en.cases[$0].fields.isEmpty }
            if payloads.count == 1, let p = payloads.first {
                return DynEnumLayout(kind: .single(payloadCase: p), cases: n, overXI: LLVMConstInt(e.i1, 0, 0),
                                     payloadXI: payloadXI(p), tagOffset: const64(off), tagWidth: const64(w))
            }
            return DynEnumLayout(kind: .multi, cases: n, tagOffset: const64(off), tagWidth: const64(w))
        case .spareBits(let payloads, let tagOffset):
            return DynEnumLayout(kind: .spareBits(payloadCases: payloads, tagOffset: tagOffset), cases: n)
        }
    }

    // The case index of the enum at `buf`, as an `i64`. Over the payload's extra inhabitants, the k-th past its
    // first unused value is the k-th payload-free case (declared order, skipping the payload case), and any
    // other value is the payload case.
    private func loadEnumCase(_ buf: LLVMValueRef, _ l: DynEnumLayout) -> LLVMValueRef {
        switch l.kind {
        case .tagOnly(let w):
            return e.loadUInt(buf, width: const64(w))
        case .multi:
            return e.loadUInt(e.gepByte(buf, l.tagOffset!), width: l.tagWidth!)
        case .spareBits(let payloads, let tagOffset):
            let word = LLVMBuildLoad2(b, e.i64, e.gepByte(buf, const64(tagOffset)), "sb.word")!
            return spareBitCase(word, allPayloads: payloads.count == l.cases)
        case .single(let p):
            guard let x = l.payloadXI else {
                return l.cases == 1 ? const64(p) : e.loadUInt(e.gepByte(buf, l.tagOffset!), width: l.tagWidth!)
            }
            let o = l.overXI!
            let addr = e.gepByte(buf, LLVMBuildSelect(b, o, x.offset, l.tagOffset!, "tag.off")!)
            let v = e.loadUInt(addr, width: LLVMBuildSelect(b, o, x.width, l.tagWidth!, "tag.width")!)
            let k = LLVMBuildSub(b, LLVMBuildLShr(b, v, x.shift, "xi.v")!, x.first, "xi.k")!
            let isEmpty = LLVMBuildICmp(b, LLVMIntULT, k, const64(l.cases - 1), "xi.empty")!
            let past = LLVMBuildICmp(b, LLVMIntUGE, k, const64(p), "xi.past")!
            let emptyCase = LLVMBuildAdd(b, k, LLVMBuildZExt(b, past, e.i64, "xi.skip")!, "xi.case")!
            let fromXI = LLVMBuildSelect(b, isEmpty, emptyCase, const64(p), "xi.tag")!
            return LLVMBuildSelect(b, o, fromXI, v, "etag")!
        }
    }

    // A spare-bit enum's case index from its word (an `i64`): `word >> 3` below the first page, `word & 7` above;
    // with no payload-free case, `word & 7` alone.
    private func spareBitCase(_ word: LLVMValueRef, allPayloads: Bool) -> LLVMValueRef {
        if allPayloads { return LLVMBuildAnd(b, word, const64(7), "sb.c")! }
        let isEmpty = LLVMBuildICmp(b, LLVMIntULT, word, const64(ShapeEnv.referenceExtraInhabitants), "sb.empty")!
        return LLVMBuildSelect(b, isEmpty, LLVMBuildLShr(b, word, const64(EnumLayout.spareBitShift), "sb.k")!,
                               LLVMBuildAnd(b, word, const64(7), "sb.c")!, "sb.tag")!
    }

    // A spare-bit enum's reference: the word less its own low bits, the same address computation in every case,
    // so arms that read the same field merge. A pointer derived from the word, which the statepoint rewrite
    // relocates.
    private func spareBitUntag(_ word: LLVMValueRef) -> LLVMValueRef {
        let low = LLVMBuildAnd(b, LLVMBuildPtrToInt(b, word, e.i64, "sb.int")!, const64(7), "sb.low")!
        return e.gepByte(word, LLVMBuildNeg(b, low, "sb.back")!)
    }

    // Write case `caseIndex` (an `i64`) into the enum at `buf`, whose payload is already in place: the payload
    // case's, or zero for a payload-free case.
    private func storeEnumCase(_ buf: LLVMValueRef, _ l: DynEnumLayout, _ caseIndex: LLVMValueRef) {
        switch l.kind {
        case .tagOnly(let w):
            e.storeUInt(buf, width: const64(w), caseIndex)
        case .multi:
            e.storeUInt(e.gepByte(buf, l.tagOffset!), width: l.tagWidth!, caseIndex)
        case .spareBits(let payloads, let tagOffset):
            // A payload case adds its index to the reference already stored; a payload-free case is `c << 3`.
            let buf = e.gepByte(buf, const64(tagOffset))
            var isPayload = LLVMConstInt(e.i1, 0, 0)!
            for c in payloads {
                isPayload = LLVMBuildOr(b, isPayload, LLVMBuildICmp(b, LLVMIntEQ, caseIndex, const64(c), "sb.isc")!, "sb.pl")!
            }
            let stored = LLVMBuildLoad2(b, e.i64, buf, "sb.ref")!
            let tagged = LLVMBuildAdd(b, stored, caseIndex, "sb.tagged")!
            let empty = LLVMBuildShl(b, caseIndex, const64(EnumLayout.spareBitShift), "sb.k")!
            LLVMBuildStore(b, LLVMBuildSelect(b, isPayload, tagged, empty, "sb.word")!, buf)
        case .single(let p):
            let tagAddr = e.gepByte(buf, l.tagOffset!)
            guard let x = l.payloadXI else {
                if l.cases > 1 { e.storeUInt(tagAddr, width: l.tagWidth!, caseIndex) }
                return
            }
            // Over the payload's extra inhabitants the payload case leaves the field as it is: it stores back the
            // value already there. The address is one offset from `buf`, so it stays a pointer derived from it.
            let o = l.overXI!
            let isPayload = LLVMBuildICmp(b, LLVMIntEQ, caseIndex, const64(p), "is.payload")!
            let past = LLVMBuildZExt(b, LLVMBuildICmp(b, LLVMIntUGT, caseIndex, const64(p), "past")!, e.i64, "skip")!
            let k = LLVMBuildSub(b, caseIndex, past, "xi.k")!
            let xiValue = LLVMBuildShl(b, LLVMBuildAdd(b, x.first, k, "xi.n")!, x.shift, "xi.value")!
            let addr = e.gepByte(buf, LLVMBuildSelect(b, o, x.offset, l.tagOffset!, "case.off")!)
            let width = LLVMBuildSelect(b, o, x.width, l.tagWidth!, "case.width")!
            let kept = LLVMBuildSelect(b, isPayload, e.loadUInt(addr, width: width), xiValue, "xi.kept")!
            e.storeUInt(addr, width: width, LLVMBuildSelect(b, o, kept, caseIndex, "case.value")!)
        }
    }

    private func umax(_ x: LLVMValueRef, _ y: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildSelect(b, LLVMBuildICmp(b, LLVMIntUGT, x, y, "gt")!, x, y, "max")!
    }

    // `v` rounded up to a multiple of the power of two `a`.
    private func alignUp(_ v: LLVMValueRef, _ a: LLVMValueRef) -> LLVMValueRef {
        let one = LLVMConstInt(e.i64, 1, 0)!
        let bumped = LLVMBuildAdd(b, v, LLVMBuildSub(b, a, one, "am1")!, "bump")!
        return LLVMBuildAnd(b, bumped, LLVMBuildNeg(b, a, "amask")!, "aligned")!
    }

    // Substitute a composed type's template type-parameter names with its actual arguments.
    private func substType(_ t: Type, _ s: [String: Type]) -> Type {
        switch t {
        case .typeParam(let p): return s[p] ?? t
        case .generic(let b, let a): return .generic(base: b, args: a.map { substType($0, s) })
        case .array(let e): return .array(substType(e, s))
        case .ptr(let e): return .ptr(substType(e, s))
        case .function(let ps, let r): return .function(params: ps.map { substType($0, s) }, ret: substType(r, s))
        default: return t
        }
    }

    var loweredMain = false
    var error: String? { e.error }

    init(ctx: LLVMContextRef, mod: LLVMModuleRef) {
        self.e = LLVMGen(ctx: ctx, mod: mod)
    }

    // MARK: - Convenience accessors over the shared emitter

    var b: LLVMBuilderRef { e.b }
    var ctx: LLVMContextRef { e.ctx }
    func ty(_ t: Type, _ span: Span) -> LLVMTypeRef? { e.llvmType(t, span) }

    // The LLVM storage type for a `stackAlloc` slot. For a value aggregate `llvmType` is already the
    // storage (the struct/enum value); for a **stack-promoted** class/actor the slot must hold the
    // object struct `{ header, fields… }`, not the `p1` `llvmType` gives a reference — the slot is an
    // addrspace(0) pointer to that struct, and `fieldAddr` GEPs past the header like a heap object.
    func storageType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        if case .named(let n, let k) = t {
            switch k {
            case .class_: return e.classType(n)
            case .actor_: return e.actorType(n)
            default: break
            }
        }
        return ty(t, span)
    }

    var curFnName = ""
    // Every SSA value is defined before use (SSA dominance) and every def maps here, so a miss is an
    // egress bug, not user error — report it as a compile error (a null placeholder keeps lowering from
    // trapping; the error aborts the emit before the module is used).
    func val(_ v: SSAValue) -> LLVMValueRef {
        // A homed shaped value reads from its frame alloca (task 176 Stage 3, Model 1), its conditional managed
        // words volatile, so the collector's post-relocation writeback is observed rather than a stale
        // pre-safepoint value being forwarded.
        if let home = shapedHome[v.id], let lt = e.llvmType(home.type, e.zeroSpan) {
            return loadReloading(home.slot, home.type, lt)
        }
        if let x = values[v.id] { return x }
        e.fail("7.2.3: internal — unmapped SSA value id=\(v.id) (\(v.type)) in '\(curFnName)'", e.zeroSpan)
        return LLVMConstNull(e.i8ptr)
    }

    // Store a produced shaped value into `id`'s home alloca, if it has one.
    private func storeHomeIfShaped(_ id: Int, _ value: LLVMValueRef) {
        if let home = shapedHome[id] { LLVMBuildStore(b, value, home.slot) }
    }

    // A load from frame memory (`addrspace(0)`: a recorded slot, a GEP into one, a `self` pointer into a
    // caller's slot, an erased buffer) of a type with conditional content reads that content's managed words
    // volatile (`Shape.conditionalWords`), so the collector's in-place rewrite at a safepoint is observed
    // rather than a pre-safepoint value forwarded (I11a). Other words load ordinarily: a plain managed pointer
    // loaded early is an SSA value the statepoint rewrite relocates. A heap (`addrspace(1)`) load needs none,
    // since its base is relocated.
    func loadReloading(_ p: LLVMValueRef, _ t: Type, _ lt: LLVMTypeRef) -> LLVMValueRef {
        let frame = LLVMGetPointerAddressSpace(LLVMTypeOf(p)) == 0 && !e.measureNoShapedHomes
        let words = frame ? e.shapes.shape(t).conditionalWords : []
        if words.isEmpty { return LLVMBuildLoad2(b, lt, p, "ld") }
        if let leaf = e.shapes.leaf(t) { return loadLeafWords(p, leaf) }
        var agg = LLVMBuildLoad2(b, lt, p, "ld")!
        for off in words {
            guard let (path, wt) = wordPath(lt, off) else {
                e.fail("internal: no 8-byte word at byte \(off) of \(t)'s LLVM type", e.zeroSpan)
                continue
            }
            let w = LLVMBuildLoad2(b, wt, e.gepByte(p, LLVMConstInt(e.i64, UInt64(off), 0)), "ld.w")!
            LLVMSetVolatile(w, 1)
            agg = insertWord(agg, path, w)
        }
        return agg
    }

    // The index path to the word at byte `off` of an aggregate's LLVM type, and the word's type (an `i64`, or
    // a pointer: an enum's payload reference ahead of an appended tag), under LLVM's natural layout (the layout
    // `checkLayout` holds codegen to): struct elements each at the next multiple of their alignment, array
    // elements by size.
    private func wordPath(_ t: LLVMTypeRef, _ off: Int) -> ([UInt32], LLVMTypeRef)? {
        switch LLVMGetTypeKind(t) {
        case LLVMStructTypeKind:
            var at = 0
            for i in 0..<LLVMCountStructElementTypes(t) {
                let et = LLVMStructGetTypeAtIndex(t, i)!
                at = ShapeEnv.alignUp(at, naturalAlign(et))
                let size = naturalSize(et)
                if off < at + size { return off >= at ? wordPath(et, off - at).map { ([i] + $0.0, $0.1) } : nil }
                at += size
            }
            return nil
        case LLVMArrayTypeKind:
            let et = LLVMGetElementType(t)!
            let size = naturalSize(et)
            guard size > 0, off / size < Int(LLVMGetArrayLength2(t)) else { return nil }
            return wordPath(et, off % size).map { ([UInt32(off / size)] + $0.0, $0.1) }
        case LLVMIntegerTypeKind where LLVMGetIntTypeWidth(t) == 64, LLVMPointerTypeKind:
            return off == 0 ? ([], t) : nil
        default:
            return nil
        }
    }

    // An LLVM type's size and alignment under its natural layout, for the types codegen builds aggregates
    // from: `i1` and `i8` one byte, `i64`, `double` and pointers eight, structs and arrays from their parts.
    private func naturalAlign(_ t: LLVMTypeRef) -> Int {
        switch LLVMGetTypeKind(t) {
        case LLVMStructTypeKind:
            return (0..<LLVMCountStructElementTypes(t)).reduce(1) { max($0, naturalAlign(LLVMStructGetTypeAtIndex(t, $1)!)) }
        case LLVMArrayTypeKind:
            return naturalAlign(LLVMGetElementType(t)!)
        case LLVMIntegerTypeKind:
            return max(Int(LLVMGetIntTypeWidth(t)) / 8, 1)
        default:
            return 8
        }
    }

    private func naturalSize(_ t: LLVMTypeRef) -> Int {
        switch LLVMGetTypeKind(t) {
        case LLVMStructTypeKind:
            var at = 0
            for i in 0..<LLVMCountStructElementTypes(t) {
                let et = LLVMStructGetTypeAtIndex(t, i)!
                at = ShapeEnv.alignUp(at, naturalAlign(et)) + naturalSize(et)
            }
            return ShapeEnv.alignUp(at, naturalAlign(t))
        case LLVMArrayTypeKind:
            return Int(LLVMGetArrayLength2(t)) * naturalSize(LLVMGetElementType(t)!)
        case LLVMIntegerTypeKind:
            return max(Int(LLVMGetIntTypeWidth(t)) / 8, 1)
        default:
            return 8
        }
    }

    // `agg` with the word at index `path` replaced by `w`.
    private func insertWord(_ agg: LLVMValueRef, _ path: [UInt32], _ w: LLVMValueRef) -> LLVMValueRef {
        guard let first = path.first else { return w }
        if path.count == 1 { return LLVMBuildInsertValue(b, agg, w, first, "ld.v")! }
        let inner = LLVMBuildExtractValue(b, agg, first, "ld.sub")!
        return LLVMBuildInsertValue(b, agg, insertWord(inner, Array(path.dropFirst()), w), first, "ld.v")!
    }

    // Read a shaped leaf's value from `p` one 8-byte word at a time (a leaf lowers to a struct of `i64`
    // words), the words it may hold managed (`ShapeLeaf.managedWords`) volatile.
    func loadLeafWords(_ p: LLVMValueRef, _ leaf: ShapeLeaf) -> LLVMValueRef {
        let lt = e.llvmType(leaf.type, e.zeroSpan)!
        let managed = Set(leaf.managedWords)
        var agg = LLVMGetUndef(lt)!
        for w in 0..<leaf.slots {
            let word = LLVMBuildLoad2(b, e.i64, e.structGEP(lt, p, w), "shp.w\(w)")!
            if managed.contains(w * 8) { LLVMSetVolatile(word, 1) }
            agg = LLVMBuildInsertValue(b, agg, word, UInt32(w), "shp.v\(w)")!
        }
        return agg
    }

    // The `"deopt"` shaped-root operands for the homed values in `ids` (task 176 Stage 4): per root an i32
    // shape ordinal (its type's) and its home-slot pointer. The walker maps the ordinal to the type's
    // descriptor and scans the slot conditionally.
    private func shapedDeoptOps(homed: Set<Int>, slots: Set<Int>) -> [LLVMValueRef?] {
        var ops: [LLVMValueRef?] = []
        for id in homed.sorted() {
            guard let home = shapedHome[id] else { continue }
            ops.append(LLVMConstInt(e.i32, UInt64(bitPattern: Int64(e.shapeOrdinal(home.type))), 0))
            ops.append(home.slot)
        }
        // A shaped-containing value-aggregate slot (task 176.3a): record its base + the aggregate's shape
        // ordinal. The base is the bare `stackAlloc` alloca, which records as a `Direct` stackmap location
        // (a non-zero sub-field GEP records as `Indirect` and is dropped — see shaped-roots.md Stage 3b).
        for id in slots.sorted() {
            guard let t = shapedSlots[id], let base = values[id] else { continue }
            let ord = e.shapeOrdinal(t)
            ops.append(LLVMConstInt(e.i32, UInt64(bitPattern: Int64(ord)), 0))
            ops.append(base)
        }
        return ops
    }

    // The loop-header safepoint poll, recording the shaped values live at the header as shaped roots on the
    // poll's statepoint (task 176). A header with no live homed shaped value emits the plain poll.
    // The function-entry stack check, recording the shaped values live into the entry block (their homes
    // are set up for it in `setUpShapedHomes`).
    private func emitEntryStackCheck(_ blockId: Int) {
        let ops = shapedDeoptOps(homed: shapedLive?.liveInBlock[blockId] ?? [],
                                 slots: slotRoot.roots(shapedSlotLive?.liveInBlock[blockId] ?? []))
        e.emitStackCheck(ops)
    }

    private func emitHeaderPoll(_ blockId: Int) {
        if e.measureNoLoopPolls { return }
        let ops = shapedDeoptOps(homed: shapedLive?.liveInBlock[blockId] ?? [],
                                 slots: slotRoot.roots(shapedSlotLive?.liveInBlock[blockId] ?? []))
        if ops.isEmpty { e.emitSafepointPoll(); return }
        e.emitSafepointPollWithDeopt(ops)
    }

    // MARK: - Entry

    // Lower a whole SSA module. `noirModule` supplies the NOIR-shaped type/witness metadata the shared
    // layout/witness/actor primitives read (the SSA module keeps only logical field indices); the SSA
    // module supplies every function body plus the synthesized closure/fiber env aggregates.
    func lower(_ module: SSAModule, from noirModule: NOIRModule) {
        // Type + witness registries — mirror `NOIRToLLVM.lower`.
        for i in noirModule.interfaces { e.interfaceDefs[i.name] = i }
        e.opaqueUnderlyings = noirModule.opaqueUnderlyings
        e.monoTypeArgs = noirModule.monoTypeArgs
        e.dictionaries = noirModule.dictionaries
        for r in noirModule.recipes?.recipes ?? [] { e.recipes[r.symbol] = r }
        for decl in noirModule.decls {
            switch decl {
            case .funcDecl(let f):   e.funcMap[f.name] = f
            case .structDecl(let s): e.structMap[s.name] = s
            case .enumDecl(let en):  e.enumMap[en.name] = en
            case .classDecl(let c):  e.classMap[c.name] = c
            case .actorDecl(let a):  e.actorMap[a.name] = a
            case .globalDecl:        break   // globals are emitted from the SSA module (task 224.2–224.3)
            }
        }
        // `EmptyHeader` is compiler GC substrate (task 174.5.1): the zero-field `ManagedBuffer` header codegen
        // names for a heap `String`'s byte buffer (`managedBufferTypeId(EmptyHeader, UInt8)`). It carries no
        // symbols and is never written in source, so it is a compiler builtin — seed its zero-field layout so
        // the value layout and the descriptors read headerSize 0, with no prepended decl.
        if e.structMap["EmptyHeader"] == nil {
            e.structMap["EmptyHeader"] = NOIRStruct(name: "EmptyHeader", fields: [], methods: [],
                                                    span: Span(startOffset: -1, endOffset: -1, map: nil))
        }
        // Synthesized closure/fiber environment layouts live only in the SSA module — register them as
        // classes so `classType`/`aggInfo`/`typeId` can lay them out and scan their captured fields.
        for agg in module.aggregates where e.classMap[agg.name] == nil && agg.kind == .class_ {
            e.classMap[agg.name] = NOIRClass(
                name: agg.name,
                fields: agg.fields.map { NOIRField(name: $0.name, type: $0.type, isMutable: $0.isMutable, span: agg.span,
                                                   fromTypeParameter: $0.fromTypeParameter) },
                methods: [], span: agg.span)
        }

        // A library module has no `main`; debug info still needs a source file, so fall back to the first
        // function's. Only the entry object requires `main` (checked by the driver via `loweredMain`).
        if let anyFn = module.functions.first(where: { $0.name == "main" }) ?? module.functions.first {
            e.setupDebugInfo(sourceFile: anyFn.span.debugFile)
        }

        // Constant globals fold before any body is lowered, so a read uses the value directly. Their init
        // functions are only folded, never declared or emitted. A startup global gets zero-filled storage its
        // init function's result is stored into once, from the module's init function.
        let constantInits = Set(module.globals.filter(\.isConstant).map(\.initFunction))
        for f in module.functions where !constantInits.contains(f.name) { declareFunction(f) }
        foldConstantGlobals(module)
        declareStartupGlobals(module)
        for f in module.functions where !constantInits.contains(f.name) {
            if error != nil { break }
            defineFunction(f)
        }
        if error == nil { defineModuleInits(module) }
        if error == nil, e.emitsProcessEntry, let entry = e.callables["f:main"] {
            e.emitProcessEntry(main: entry.fn, entry.ty)
        }

        // Value-witness tables for monomorphized generic value-type instantiations (task 100.4.3.2;
        // instantiation names carry `<…>`). The erased path (100.4.3.3+) additionally emits VWTs on
        // demand for the concrete type arguments at call sites; emitting the module's generic value types
        // here exercises the VWT capability (unreferenced ones dead-strip).
        for name in e.structMap.keys.sorted() where name.contains("<") { e.valueWitness(.named(name, .struct_)) }
        for name in e.enumMap.keys.sorted() where name.contains("<") { e.valueWitness(.named(name, .enum_)) }

        // The shared kind-2 shaped descriptor for every `String` value (task 121/176): register it so the
        // discriminant-keyed map is serialized and emitted (weak-folded across modules). The collector
        // consumes it once String flows as a root/field (176.1); emitting it here exercises the kind-2
        // serialization path and lands the descriptor in the binary.
        // The ordinal→descriptor table the frame-root walk reads (task 176.3a): ordinal 0 = String, 1+ = the
        // shaped-containing value aggregates recorded during this compilation. Emitted after all functions are
        // lowered, so every recorded ordinal is known. Its String entry also pins the String kind-2
        // descriptor, which a String value (no object header) never stamps.
        e.emitShapeOrdinalTable()

        // Register the heap `String` byte-buffer descriptor — a `ManagedBuffer<EmptyHeader, UInt8>` (task
        // 176.2 / 180.4) — at module start, so a module that only *relocates* a received heap String (never
        // allocating one itself, so it has no `__stringAllocHeap` site) still emits the weak-ODR descriptor
        // into its own section. `allocHeap` sites register the same id; this is the belt for the alloc-free
        // consumer. No String-specific symbol: the id folds onto the shared `ManagedBuffer` descriptor.
        _ = e.managedBufferTypeId(header: .named("EmptyHeader", .struct_), element: .uint8)

        // The link-time offset-as-id descriptor section (task 100.4.7): every module emits its own
        // types' descriptors, weak duplicates folding at link — so a dependency's heap types are all
        // present at the section the runtime reads via `getsectiondata`.
        e.emitDescriptors()
        if let dib = e.di {
            LLVMDIBuilderFinalize(dib)
            LLVMDisposeDIBuilder(dib)
            e.di = nil
        }
        if error == nil { loweredMain = e.callables["f:main"] != nil }
    }

    // MARK: - Globals (task 224)

    // Emit each constant global as read-only static data. Its init function is a single block of constant
    // instructions (sema admits only literals, arithmetic, struct and payload-free enum values, and
    // `RawPtr.null`); lowering them in a scratch block yields LLVM constants and inserts nothing.
    private func foldConstantGlobals(_ module: SSAModule) {
        guard !module.globals.isEmpty else { return }
        let scratchFn = LLVMAddFunction(e.mod, "__nomu_fold_scratch", LLVMFunctionType(e.voidTy, nil, 0, 0))!
        defer { LLVMDeleteFunction(scratchFn) }
        // A static-storage global folds first: it reads nothing, and another constant global may read it.
        let constants = module.globals.filter(\.isConstant)
        let storageFirst = constants.filter { isStaticStorageInit($0, module) } + constants.filter { !isStaticStorageInit($0, module) }
        for g in storageFirst {
            foldingGlobal = g
            defer { foldingGlobal = nil }
            guard let f = module.functions.first(where: { $0.name == g.initFunction }) else { continue }
            guard let gty = ty(g.type, g.span) else { continue }
            let symbol = Mangle.global(g.name, home: e.definitionModule(for: g.span.file))
            guard f.blocks.count == 1, let blk = f.blocks.first, case .ret(let rv?) = blk.terminator.kind else {
                e.fail("global '\(g.name)': a constant initializer must be straight-line", g.span); continue
            }
            values = [:]; shapedHome = [:]; shapedLive = nil
            let scratch = LLVMAppendBasicBlockInContext(ctx, scratchFn, "fold")!
            LLVMPositionBuilderAtEnd(b, scratch)
            for inst in blk.insts { lowerInst(inst) }
            let value = values[rv.id]
            let inserted = LLVMGetFirstInstruction(scratch) != nil
            LLVMDeleteBasicBlock(scratch)
            guard let c = value, !inserted, LLVMIsConstant(c) != 0, LLVMIsPoison(c) == 0, LLVMIsUndef(c) == 0 else {
                e.fail("global '\(g.name)': its initializer does not fold to a constant (a division by zero or an out-of-range shift?)", g.span)
                continue
            }
            let gv = LLVMAddGlobal(e.mod, gty, symbol)!
            LLVMSetInitializer(gv, c)
            LLVMSetGlobalConstant(gv, 1)
            if e.weakOriginFiles.contains(g.span.file) { LLVMSetLinkage(gv, LLVMWeakODRLinkage) }
            globalVars[g.name] = (gv, c)
        }
        values = [:]
    }

    private func isStaticStorageInit(_ g: SSAGlobal, _ module: SSAModule) -> Bool {
        guard let f = module.functions.first(where: { $0.name == g.initFunction }) else { return false }
        return f.blocks.contains { $0.insts.contains { inst in
            if case .call(let c) = inst.kind, case .direct("__staticStorage") = c.kind { return true }
            return false
        } }
    }

    // A `Runtime.staticStorage(bytes:align:)` block: zeroed, writable data under its own symbol, whose address
    // is the folding global's value. Sema admits it only as a global's whole initializer.
    private func staticStorageBlock(_ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard let g = foldingGlobal, args.count == 2 else {
            e.fail("internal: 'Runtime.staticStorage' outside a global's initializer", span); return nil
        }
        let bytes = LLVMConstIntGetZExtValue(val(args[0]))
        let align = LLVMConstIntGetZExtValue(val(args[1]))
        let symbol = Mangle.staticStorage(g.name, home: e.definitionModule(for: g.span.file))
        guard LLVMGetNamedGlobal(e.mod, symbol) == nil else {
            e.fail("internal: static storage '\(symbol)' declared before its global folds", span); return nil
        }
        let blockTy = LLVMArrayType2(e.i8, bytes)!
        let block = LLVMAddGlobal(e.mod, blockTy, symbol)!
        LLVMSetInitializer(block, LLVMConstNull(blockTy))
        LLVMSetAlignment(block, UInt32(align))
        if e.weakOriginFiles.contains(g.span.file) { LLVMSetLinkage(block, LLVMWeakODRLinkage) }
        return block
    }

    // A startup global's storage: zero-filled and writable, holding its value once the module's init function
    // has run. Its init function is never inlined, so no function that stores the value also reads it.
    private func declareStartupGlobals(_ module: SSAModule) {
        for g in module.globals where !g.isConstant {
            guard let gty = ty(g.type, g.span) else { continue }
            let gv = LLVMAddGlobal(e.mod, gty, Mangle.global(g.name, home: e.definitionModule(for: g.span.file)))!
            LLVMSetInitializer(gv, LLVMConstNull(gty))
            if e.weakOriginFiles.contains(g.span.file) { LLVMSetLinkage(gv, LLVMWeakODRLinkage) }
            globalVars[g.name] = (gv, nil)
            if let c = e.callables["f:\(g.initFunction)"] { e.addNoInline(c.fn) }
        }
    }

    // The module's init function: run once, guarded by a done-flag, it calls its imports' init functions,
    // then stores its startup globals in their proven order. The `runtime` package defines the runtime's
    // instead, which the process entry `main` calls before the scheduler boots and which calls nothing else.
    // A runtime-tier global in any other module (a `test.runtime_prelude` prepend) is the runtime's own,
    // shared through its weak-ODR symbol, so the runtime's init stores it. Neither is inlined, so the stores never share a
    // function with the globals' invariant loads.
    private func defineModuleInits(_ module: SSAModule) {
        let startup = module.globals.filter { !$0.isConstant }
        if e.isRuntimePackage {
            let (fn, _) = e.preludeFn(Mangle.moduleInit(home: []), ret: e.voidTy, params: [])
            defineInit(fn, calling: [], storing: startup)
            return
        }
        let own = startup.filter { !e.weakOriginFiles.contains($0.span.file) }
        let dependencies = e.dependencyModules.map { e.preludeFn(Mangle.moduleInit(home: $0), ret: e.voidTy, params: []) }
        defineInit(moduleInit, calling: dependencies, storing: own)
    }

    private func defineInit(_ fn: LLVMValueRef, calling inits: [(LLVMValueRef, LLVMTypeRef)], storing globals: [SSAGlobal]) {
        LLVMSetGC(fn, "statepoint-example")
        e.addNoInline(fn)
        let done = LLVMAddGlobal(e.mod, e.i1, "__nomu_init_done")!
        LLVMSetInitializer(done, LLVMConstInt(e.i1, 0, 0))
        LLVMSetLinkage(done, LLVMInternalLinkage)
        e.withStubBody(fn) {
            let run = LLVMAppendBasicBlockInContext(ctx, fn, "run")!
            let finished = LLVMAppendBasicBlockInContext(ctx, fn, "done")!
            LLVMBuildCondBr(b, LLVMBuildLoad2(b, e.i1, done, "done"), finished, run)
            LLVMPositionBuilderAtEnd(b, run)
            LLVMBuildStore(b, LLVMConstInt(e.i1, 1, 0), done)
            if e.isRuntimePackage { e.emitCarrierKeySetup() }
            for (f, t) in inits { _ = e.buildCall(f, t, []) }
            for g in globals {
                guard let c = e.callables["f:\(g.initFunction)"], let gv = globalVars[g.name]?.global else { continue }
                LLVMBuildStore(b, e.buildCall(c.fn, c.ty, []), gv)
            }
            LLVMBuildBr(b, finished)
            LLVMPositionBuilderAtEnd(b, finished)
            LLVMBuildRetVoid(b)
        }
    }

    // This module's init function, declared on first use: `main` calls it on entry, and the module defines it
    // after every body.
    private var moduleInit: LLVMValueRef {
        e.preludeFn(Mangle.moduleInit(home: e.homeModule), ret: e.voidTy, params: []).0
    }

    // A global read: a constant global of this module is its folded value; any other global is a load from
    // its symbol (declared here when another module defines it). The load is invariant: a startup global is
    // read only after the init functions have run, and never changes after.
    private func readGlobal(_ name: String, _ type: Type, _ span: Span) -> LLVMValueRef? {
        guard let gty = ty(type, span) else { return nil }
        let gv: LLVMValueRef
        if let g = globalVars[name] {
            if let c = g.constant { return c }
            gv = g.global
        } else {
            let symbol = Mangle.global(name, home: e.homeModule)
            gv = LLVMGetNamedGlobal(e.mod, symbol) ?? LLVMAddGlobal(e.mod, gty, symbol)!
            globalVars[name] = (gv, nil)
        }
        let load = LLVMBuildLoad2(b, gty, gv, "global")!
        e.markInvariantLoad(load)
        return load
    }

    // MARK: - Declaration (the callable-key / symbol mangling)

    // The callable key + method receiver info for an SSA function. Free functions key `f:<name>`
    // (closures/fiber routines are `f:clo:N` / `f:fiber:N`); methods and actor handlers key
    // `m:<type>:<method>` — matching the `.direct`/`.witness` call names ssairgen emits.
    private func keyAndSelf(_ f: SSAFunction) -> (key: String, selfType: String?, byPointer: Bool, symbol: String) {
        // The origin qualifier is the module this function is *defined* in (task 100.4); it must match
        // the on-demand declaration in `LLVMGenCallables`, which derives it the same way (name + file).
        // A cross-module specialization carries an origin-keyed name, so it is producer-qualified, not
        // home-qualified — the weak-ODR fold then collapses identical copies across objects (100.5.5).
        let home = e.definitionModule(for: f.span.file)
        guard f.name.hasPrefix("m:") else {
            return ("f:\(f.name)", nil, false, Mangle.function(f.name, home: home))
        }
        let rest = f.name.dropFirst(2)
        let colon = rest.firstIndex(of: ":")!
        let type = String(rest[rest.startIndex..<colon])
        let method = String(rest[rest.index(after: colon)...])
        let isActor = e.actorMap[type] != nil
        let isReference = e.classMap[type] != nil || isActor
        let byPointer = isReference || f.isMutating
        let symbol = Mangle.method(type, method, home: home)
        return ("m:\(f.name.dropFirst(2))", type, byPointer, symbol)
    }

    // Distinct residual type-parameter names in a function's signature, in first-appearance order
    // (params then return). Non-empty ⇒ the function is an **erased** generic (backend.md §4): mono
    // substitutes every type parameter away in a monomorphized decl, so a residual `.typeParam` only
    // survives in a public generic's erased copy (100.4.3.3).
    private func signatureTypeParams(_ f: SSAFunction) -> [String] {
        var out: [String] = []
        for p in f.params { collectTypeParams(p.type, into: &out) }
        collectTypeParams(f.returnType, into: &out)
        return out
    }

    private func collectTypeParams(_ t: Type, into out: inout [String]) {
        switch t {
        case .typeParam(let p): if !out.contains(p) { out.append(p) }
        case .generic(_, let args): for a in args { collectTypeParams(a, into: &out) }
        case .array(let e): collectTypeParams(e, into: &out)
        case .ptr(let e): collectTypeParams(e, into: &out)
        case .function(let ps, let r): for p in ps { collectTypeParams(p, into: &out) }; collectTypeParams(r, into: &out)
        default: break
        }
    }

    private func mentionsTypeParam(_ t: Type) -> Bool {
        var tmp: [String] = []; collectTypeParams(t, into: &tmp); return !tmp.isEmpty
    }

    // A value an erased body holds as a pointer to its bytes. A generic class mentions a type parameter but
    // is a reference: one managed pointer, stored and returned directly.
    private func heldByBuffer(_ t: Type) -> Bool {
        if case .generic(let base, _) = t, e.classMap[base] != nil { return false }
        return mentionsTypeParam(t)
    }

    // Create the LLVM function for `f` and register it in `callables` with the ABI-correct signature —
    // the self ABI (by-pointer for a class/actor/mutating receiver, else by value) mirrors
    // `declareCallable`, so a witness/actor thunk built later dispatches through a matching signature.
    private func declareFunction(_ f: SSAFunction) {
        let (key, selfType, byPointer, symbol) = keyAndSelf(f)
        if e.callables[key] != nil { return }
        if !f.generics.isEmpty { declareErasedFunction(f, key: key, symbol: symbol); return }
        guard let retTy = ty(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        var rest = f.params
        if let selfType = selfType {
            guard let st = e.selfLLVMType(selfType) else { return }
            let isReference = e.classMap[selfType] != nil || e.actorMap[selfType] != nil
            if byPointer {
                paramTys.append(isReference ? e.p1 : LLVMPointerType(st, 0)!)
            } else {
                paramTys.append(st)
            }
            rest = Array(f.params.dropFirst())
        }
        for p in rest {
            guard let t = ty(p.type, f.span) else { return }
            paramTys.append(t)
        }
        // A lifted `fiber:N` routine's env crosses the fiber (C) boundary as a runtime-held `void*`, so
        // its env parameter is addrspace(0) — like the NOIR fiber routine — not the managed `p1` its
        // class type would give. Keeping it addr0 avoids a 0→1 addrspacecast the GC statepoint rewriter
        // rejects; the captured-field loads GEP off the addr0 pointer and reload each managed capture as
        // its own root. (Closures never cross the boundary, so their env stays `p1`.)
        if f.name.hasPrefix("fiber:"), !paramTys.isEmpty { paramTys[0] = e.i8ptr }
        let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys,
                                        debug: (f.name, f.span.begin.line, f.span.debugFile))
        // Prelude functions are compiled into every module's object (interim, task 100.3.7); weak
        // linkage lets the linker fold the duplicate definitions to one.
        // Weak-ODR so duplicate definitions fold at link: a prelude function (compiled into every object,
        // task 100.3.7) or a cross-module generic specialized under its producer-keyed name in more than
        // one consumer (task 100.5.5 — the name is identical across consumers, so the copies coalesce).
        if e.weakOriginFiles.contains(f.span.file) || ExternalName.isEncoded(f.name) {
            LLVMSetLinkage(fn, LLVMWeakODRLinkage)
        }
        let dummy = NOIRFunc(name: f.name, params: [], returnType: f.returnType,
                             body: [], isMutating: f.isMutating, span: f.span)
        e.callables[key] = Callable(fn: fn, ty: fnTy, ir: dummy,
                                    selfType: selfType, selfByPointer: byPointer)
    }

    // Declare a public generic's **erased** copy under the witness-passing ABI (backend.md §4). Hidden
    // leading parameters, in the fixed order: (1) a dictionary pointer, whose words are a VWT and a size per
    // type parameter in declaration order, then one PWT per (type parameter, bound), bounds name-sorted;
    // (2) a result buffer (sret-style) when the return type mentions a type parameter. Then the value parameters, each
    // `.typeParam`-typed one passed indirectly as a `ptr` to a caller-allocated buffer. A method
    // (`m:` prefix) with residual type parameters would also need self handling — not reached, since
    // only free generic functions are emitted erased today.
    private func declareErasedFunction(_ f: SSAFunction, key: String, symbol: String) {
        let returnsTP = heldByBuffer(f.returnType)
        var paramTys: [LLVMTypeRef] = []
        paramTys.append(e.i8ptr)                                // (1) the dictionary
        if returnsTP { paramTys.append(e.i8ptr) }               // (2) result buffer (sret)
        for p in f.params {                                     // value parameters (a `T` value is a ptr)
            guard let t = ty(p.type, f.span) else { return }
            paramTys.append(t)
        }
        let retTy: LLVMTypeRef
        if returnsTP {
            retTy = e.voidTy
        } else {
            guard let r = ty(f.returnType, f.span) else { return }
            retTy = r
        }
        let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys,
                                        debug: (f.name, f.span.begin.line, f.span.debugFile))
        erasedSigs[key] = ExternalGenericSig(generics: f.generics.map(\.name), bounds: f.generics.map { $0.bounds.sorted() },
                                             params: f.params.map(\.type), ret: f.returnType)
        // Weak-ODR so duplicate definitions fold at link: a prelude function (compiled into every object,
        // task 100.3.7) or a cross-module generic specialized under its producer-keyed name in more than
        // one consumer (task 100.5.5 — the name is identical across consumers, so the copies coalesce).
        if e.weakOriginFiles.contains(f.span.file) || ExternalName.isEncoded(f.name) {
            LLVMSetLinkage(fn, LLVMWeakODRLinkage)
        }
        let dummy = NOIRFunc(name: f.name, params: [], returnType: f.returnType,
                             body: [], isMutating: f.isMutating, span: f.span)
        e.callables[key] = Callable(fn: fn, ty: fnTy, ir: dummy, selfType: nil, selfByPointer: false)
    }

    // MARK: - Body

    private func defineFunction(_ f: SSAFunction) {
        let (key, _, _, _) = keyAndSelf(f)
        guard let c = e.callables[key] else { return }
        curChecksStack = checksStack(f)
        values = [:]; blockMap = [:]; blocksById = [:]; selectOptions = [:]; selectSlots = [:]; pendingIncomings.removeAll(keepingCapacity: true)
        shapedHome = [:]; shapedLive = nil; shapedSlots = [:]; slotRoot = RecordedSlots(); shapedSlotLive = nil
        curVWTParams = [:]; curPWTParams = [:]; curSretParam = nil; curReturnType = nil
        curDictionary = nil; curDictionaryWords = []; curSizes = [:]; curAligns = [:]
        curProducerSave = nil; curBackEdges = [:]; headerSaveSlot = [:]; curBlockId = -1
        curFnName = f.name
        e.currentFn = c.fn

        // An erased generic's value parameters sit past the hidden leading parameters — the dictionary,
        // then an sret result buffer if the return mentions a type parameter (backend.md §4). The witnesses
        // are read from the dictionary at entry; the sret + returned type parameter's VWT let `ret` lower the
        // move as a VWT-sized memcpy.
        if !f.generics.isEmpty {
            let returnsTP = heldByBuffer(f.returnType)
            let leading = 1 + (returnsTP ? 1 : 0)
            for (i, p) in f.params.enumerated() { values[p.id] = LLVMGetParam(c.fn, UInt32(leading + i)) }
            if returnsTP {
                curSretParam = LLVMGetParam(c.fn, 1)
                curReturnType = f.returnType   // the `ret` move sizes it via the derived VWT
            }
        } else {
            // Function parameters map to the LLVM parameters by position (the SSA param order — self first
            // for a method — matches the declared signature).
            for (i, p) in f.params.enumerated() { values[p.id] = LLVMGetParam(c.fn, UInt32(i)) }
        }

        e.enterDebugScope(c.fn, line: f.span.begin.line)

        // Pass A — materialize every block, and a φ for each block parameter (block args → φ).
        for blk in f.blocks {
            let bb = LLVMAppendBasicBlockInContext(ctx, c.fn, "bb\(blk.id)")!
            blockMap[blk.id] = bb
            blocksById[blk.id] = blk
        }
        for blk in f.blocks {
            LLVMPositionBuilderAtEnd(b, blockMap[blk.id])
            for p in blk.params {
                guard let pty = ty(p.type, f.span) else { return }
                values[p.id] = LLVMBuildPhi(b, pty, "arg")
            }
        }

        // Pointers that may point into a caller's frame, marked where they enter (`markFrameAddress`): a
        // `mutating` value receiver, and an erased generic's result buffer and `T`-typed argument buffers.
        if let entry = f.blocks.first {
            LLVMPositionBuilderAtEnd(b, blockMap[entry.id])
            let (_, selfType, byPointer, _) = keyAndSelf(f)
            if let st = selfType, byPointer, e.classMap[st] == nil, e.actorMap[st] == nil,
               let p = f.params.first, let v = values[p.id] {
                values[p.id] = e.markFrameAddress(v)
            }
            if !f.generics.isEmpty {
                for p in f.params where mentionsTypeParam(p.type) {
                    if let v = values[p.id], LLVMTypeOf(v) == e.i8ptr { values[p.id] = e.markFrameAddress(v) }
                }
                if let sret = curSretParam { curSretParam = e.markFrameAddress(sret) }
                let dict = LLVMGetParam(c.fn, 0)!
                curDictionary = dict
                curDictionaryWords = []
                func word() -> LLVMValueRef {
                    let w = e.loadDictionaryWord(dict, curDictionaryWords.count)
                    curDictionaryWords.append(w)
                    return w
                }
                for gp in f.generics {
                    curVWTParams[gp.name] = word()
                    curSizes[gp.name] = LLVMBuildPtrToInt(b, word(), e.i64, "size")
                    if let vwt = curVWTParams[gp.name] { curAligns[gp.name] = e.loadVWTAlign(vwt) }
                }
                for pw in erasedPWTs(f) { curPWTParams["\(pw.param)::\(pw.iface)"] = word() }
            }
        }

        // Shaped-value frame homes (task 176 Stage 3): a shaped value live across a safepoint gets an alloca
        // home, zero-initialized so a not-yet-stored home scans as holding no managed word (Stage 5 zero-scan
        // safety). Reads/writes route through the home (`val`/`define`).
        setUpShapedHomes(f)

        // Producer-internal typed-root prologue (task 100.4.3.6): if this erased frame constructs a
        // composed `T`-carrying value, capture the shadow-top at entry so the epilogue can unwind exactly
        // the frame's own pushes. Emitted once, at the end of the entry block (after its φs, before its
        // body), so the saved value dominates every `ret`. A per-header save slot (entry alloca) is set up
        // for the loop-scoped unwind; the stores land when the header block is lowered.
        if !f.generics.isEmpty, let entry = f.blocks.first, frameBuildsRegistrableComposite(f) {
            for be in backEdges(f) { curBackEdges[be.from] = be.to }
            LLVMPositionBuilderAtEnd(b, blockMap[entry.id])
            let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i64, params: [])
            curProducerSave = e.buildCall(save.0, save.1, [])
            for h in Set(curBackEdges.values) { headerSaveSlot[h] = e.entryAlloca(e.i64, "loopshadow.save") }
        }

        // Pass B — lower each block's instructions and terminator. A GC safepoint poll goes at the top
        // of every loop header (a back-edge target): a poll-free loop can't be paused by a
        // stop-the-world collector, so the mutator must reach a safepoint on every back-edge (D3). The
        // NOIR walker does the same at each `while` header; placed after the header's φs and before its
        // body, so every iteration passes through it. (Eliding it when the loop already hits a safepoint
        // each iteration — NOIR's `loopBodyHasSafepoint` — is a later refinement / the safepoint pass.)
        // A runtime-subset (`noSafepoint`) function elides the poll (task 149, runtime-subset.md §4): its
        // code may run during a stop-the-world, so a poll here would recursively try to stop the world.
        // The closure check (Sema) already keeps subset code from reaching a non-subset callee, so no poll
        // hides behind a call either. This is the codegen-site guard the scheduler loop needs (128.1.1).
        let headers = f.noSafepoint ? Set<Int>() : loopHeaders(f)
        for blk in f.blocks {
            LLVMPositionBuilderAtEnd(b, blockMap[blk.id])
            // A loop-carried shaped value arrives as a homed block param (a φ); write it into its slot at block
            // entry so the slot holds the current value before the header poll records it (task 176).
            for p in blk.params {
                if let home = shapedHome[p.id], let phi = values[p.id] { LLVMBuildStore(b, phi, home.slot) }
            }
            // The stack check, first in the body: the prologue has reserved the frame, which the reserve holds.
            if checksStack(f), blk.id == f.blocks.first?.id {
                e.setDebugLoc(f.span)
                emitEntryStackCheck(blk.id)
            }
            // The entry runs every module's init function first, on the main fiber (globals design).
            if f.name == "main", blk.id == f.blocks.first?.id {
                e.setDebugLoc(f.span)
                _ = e.buildCall(moduleInit, e.fnType(e.voidTy, []), [])
            }
            if headers.contains(blk.id) {
                e.setDebugLoc(blk.insts.first?.span ?? blk.terminator.span)
                emitHeaderPoll(blk.id)
            }
            // Loop-scoped typed-root save (task 100.4.3.6): record the shadow-top on entry to this loop
            // header, so the back-edge can restore it and clear the iteration's producer pushes.
            if let slot = headerSaveSlot[blk.id] {
                let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i64, params: [])
                LLVMBuildStore(b, e.buildCall(save.0, save.1, []), slot)
            }
            lowerBlock(blk)
            if error != nil { return }
        }

        // Every value is now defined; wire the deferred φ incomings (block-argument edges).
        flushIncomings()
    }

    // Compute the shaped-value liveness and allocate a home for every shaped value that crosses a safepoint
    // — any `isSafepointInst` (a non-leaf call, conservatively every call, plus the allocation-forming kinds
    // that can trigger a collection), including the operands such an instruction stores after allocating,
    // or a loop-header poll. The homing set must match the recording set (`lowerBlock` records
    // `crossingInst` at exactly the same sites), or a value crossing an allocation but no call would be
    // recorded with no home and silently dropped. Each home is zero-initialized at entry.
    private func setUpShapedHomes(_ f: SSAFunction) {
        if e.measureNoShapedHomes { return }
        let live = computeShapedLiveness(f, e.shapes)
        shapedLive = live
        // Recorded slots (`recordedSlots`): their liveness tracks the slot and every address derived from it,
        // so a slot reached only through a `fieldAddr` (a field passed to a call) still counts as live.
        slotRoot = recordedSlots(f, e.shapes)
        if let p = slotRoot.ambiguous.first {
            e.fail("internal: block parameter %\(p) in '\(f.name)' receives addresses of two recorded slots", e.zeroSpan)
        }
        shapedSlots = slotRoot.types
        shapedSlotLive = computeSlotLiveness(f, tracked: Set(slotRoot.root.keys))
        var homed = Set<Int>()
        for blk in f.blocks {
            for c in (live.crossingInst[blk.id] ?? [:]).values { homed.formUnion(c) }
        }
        for h in loopHeaders(f) { homed.formUnion(live.liveInBlock[h] ?? []) }
        if checksStack(f), let entry = f.blocks.first { homed.formUnion(live.liveInBlock[entry.id] ?? []) }
        guard !homed.isEmpty, let entry = f.blocks.first else { return }

        // Allocas land at the entry block (via `entryAlloca`); zero-init stores go at the entry block end,
        // before its poll/body, so a home dominates every use and starts all-zero (a leaf's tag 0, an enum's
        // case 0 with a null payload: no managed word).
        var types: [Int: Type] = [:]
        for p in f.params { types[p.id] = p.type }
        for blk in f.blocks {
            for p in blk.params { types[p.id] = p.type }
            for inst in blk.insts { if let r = inst.result { types[r.id] = r.type } }
        }
        LLVMPositionBuilderAtEnd(b, blockMap[entry.id])
        for id in homed.sorted() {
            guard let t = types[id], let lt = e.llvmType(t, e.zeroSpan) else { continue }
            let home = e.entryAlloca(lt, "shp.home")
            shapedHome[id] = (home, t)
            LLVMBuildStore(b, LLVMConstNull(lt), home)
        }
        // A homed shaped function parameter is not produced by a `define`, so seed its home from the incoming
        // parameter value (after the zero-init so it wins).
        for p in f.params {
            if let home = shapedHome[p.id], let v = values[p.id] { LLVMBuildStore(b, v, home.slot) }
        }
    }

    // Whether `f` checks its stack on entry: every function but the runtime's own (the `runtime` package and
    // `noSafepoint` code), which runs where a stack cannot grow (104, "The runtime's own code").
    private func checksStack(_ f: SSAFunction) -> Bool {
        !f.noSafepoint && !e.isRuntimePackage && !e.measureNoStackChecks
    }

    // The loop headers of a function: back-edge targets, found by a DFS that marks a node "on the
    // recursion stack" — an edge to such a node is a back-edge, and its target is a loop header. Order
    // matches ssairgen's `blocks` (entry first). Iterative to avoid deep recursion on large CFGs.
    private func loopHeaders(_ f: SSAFunction) -> Set<Int> {
        var succ: [Int: [Int]] = [:]
        for blk in f.blocks { succ[blk.id] = successorIds(blk.terminator) }
        var headers = Set<Int>()
        var state: [Int: Int] = [:]   // 0/absent = unvisited, 1 = on stack, 2 = done
        guard let entry = f.blocks.first?.id else { return headers }
        var stack: [(node: Int, next: Int)] = [(entry, 0)]
        state[entry] = 1
        while let top = stack.last {
            let succs = succ[top.node] ?? []
            if top.next < succs.count {
                stack[stack.count - 1].next += 1
                let s = succs[top.next]
                switch state[s] ?? 0 {
                case 0: state[s] = 1; stack.append((s, 0))
                case 1: headers.insert(s)   // edge to a node on the stack → back-edge
                default: break
                }
            } else {
                state[top.node] = 2
                stack.removeLast()
            }
        }
        return headers
    }

    private func successorIds(_ term: SSATerm) -> [Int] {
        switch term.kind {
        case .br(let t, _): return [t]
        case .condBr(_, let t, _, let e, _): return [t, e]
        case .switchOn(_, let cases, let def, _): return cases.map { $0.target } + [def]
        case .ret, .unreachable: return []
        }
    }

    // The back-edges of a function (task 100.4.3.6): edges `from → to` where `to` is on the DFS recursion
    // stack, i.e. a loop header. The producer typed-root unwind restores the shadow-top at each of these.
    private func backEdges(_ f: SSAFunction) -> [(from: Int, to: Int)] {
        var succ: [Int: [Int]] = [:]
        for blk in f.blocks { succ[blk.id] = successorIds(blk.terminator) }
        guard let entry = f.blocks.first?.id else { return [] }
        var edges: [(from: Int, to: Int)] = []
        var state: [Int: Int] = [:]   // 0/absent = unvisited, 1 = on stack, 2 = done
        var stack: [(node: Int, next: Int)] = [(entry, 0)]
        state[entry] = 1
        while let top = stack.last {
            let succs = succ[top.node] ?? []
            if top.next < succs.count {
                stack[stack.count - 1].next += 1
                let s = succs[top.next]
                switch state[s] ?? 0 {
                case 0: state[s] = 1; stack.append((s, 0))
                case 1: edges.append((top.node, s))
                default: break
                }
            } else {
                state[top.node] = 2
                stack.removeLast()
            }
        }
        return edges
    }

    // Whether an erased frame constructs a composed value with a `T`-carrying field — the trigger for
    // emitting the producer typed-root prologue/epilogue (task 100.4.3.6). Mirrors the registration
    // predicate in `makeStruct`/`makeEnum` so the prologue save exists exactly when a `ret` (or back-edge)
    // will need to unwind a push.
    private func frameBuildsRegistrableComposite(_ f: SSAFunction) -> Bool {
        for blk in f.blocks {
            for inst in blk.insts {
                switch inst.kind {
                case .makeStruct(let t, _), .makeEnum(let t, _, _):
                    if composedHasTypeParamField(t) { return true }
                case .load, .call:
                    if let r = inst.result, heldByBuffer(r.type) { return true }
                default: break
                }
            }
        }
        return false
    }

    // Whether a composed generic type (as it appears in an erased body — type parameters retained) has a
    // field / payload whose type mentions a type parameter, i.e. a `T`-component held inline in its buffer.
    private func composedHasTypeParamField(_ t: Type) -> Bool {
        guard case .generic(let base, let args) = t else { return false }
        if let s = e.structMap[base] {
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            return s.fields.contains { mentionsTypeParam(substType($0.type, subst)) }
        }
        if let en = e.enumMap[base] {
            let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
            return en.cases.contains { $0.fields.contains { mentionsTypeParam(substType($0.type, subst)) } }
        }
        return false
    }

    // Register the managed components of a composed buffer as typed GC roots (task 100.4.3.6). `baseOff` is
    // the component's byte offset within `buf`. A bare type parameter pushes one shadow node pairing its slot
    // with the runtime VWT passed for that parameter; a nested composed struct recurses into its fields. An
    // enum's active case is a runtime property, so each case's components are pushed with `when`, the condition
    // that the case is active: while false they pair with a POD witness, which the walk expands to nothing.
    // The tag is read here, so the buffer must not change case while registered. A construction in a loop is
    // cleared each iteration by the back-edge unwind. No-op when the prologue took no save.
    private func registerErasedComponents(_ buf: LLVMValueRef, _ t: Type, _ baseOff: LLVMValueRef, _ span: Span,
                                          when: LLVMValueRef? = nil) {
        guard curProducerSave != nil else { return }
        func push(_ vwt: LLVMValueRef) {
            let chosen = when.map { LLVMBuildSelect(b, $0, vwt, e.valueWitness(.int), "root.vwt")! } ?? vwt
            producerShadowPush(e.gepByte(buf, baseOff), chosen)
        }
        switch t {
        case .typeParam(let name):
            guard let vwt = curVWTParams[name] else { return }
            push(vwt)
        case .generic(let base, let args):
            if e.classMap[base] != nil {          // a reference: one managed word, whatever its arguments
                push(e.valueWitness(t))
                return
            }
            if let en = e.enumMap[base], payloadCaseCount(en) <= 1 {
                // One payload case: its components are registered whatever the case. A payload-free case holds
                // the zeroed payload with an extra inhabitant written in, which holds no object.
                let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
                for (c, kase) in en.cases.enumerated() {
                    for (i, f) in kase.fields.enumerated() {
                        let ft = substType(f.type, subst)
                        guard mentionsTypeParam(ft),
                              let foff = erasedEnumPayloadOffset(base, args, c, i, span) else { continue }
                        registerErasedComponents(buf, ft, LLVMBuildAdd(b, baseOff, foff, "coff")!, span, when: when)
                    }
                }
                return
            }
            if let en = e.enumMap[base], let l = erasedEnumLayout(en, args, span) {
                let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
                let tag = loadEnumCase(e.gepByte(buf, baseOff), l)
                for (c, kase) in en.cases.enumerated() {
                    var active = LLVMBuildICmp(b, LLVMIntEQ, tag, LLVMConstInt(e.i64, UInt64(c), 0), "root.case")!
                    if let when { active = LLVMBuildAnd(b, when, active, "root.when")! }
                    for (i, f) in kase.fields.enumerated() {
                        let ft = substType(f.type, subst)
                        guard mentionsTypeParam(ft),
                              let foff = erasedEnumPayloadOffset(base, args, c, i, span) else { continue }
                        registerErasedComponents(buf, ft, LLVMBuildAdd(b, baseOff, foff, "coff")!, span, when: active)
                    }
                }
                return
            }
            guard let s = e.structMap[base] else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            for (i, f) in s.fields.enumerated() {
                let ft = substType(f.type, subst)
                guard mentionsTypeParam(ft), let foff = erasedFieldOffset(t, i, span) else { continue }
                registerErasedComponents(buf, ft, LLVMBuildAdd(b, baseOff, foff, "coff")!, span, when: when)
            }
        default:
            break
        }
    }

    // Push one typed-root node for `comp` (a slot address) paired with its value-layout VWT, on the
    // current fiber's shadow stack. The node storage is an entry-hoisted alloca; `rtShadowPush` is a
    // no-op when no fiber is bound (non-scheduler runs), so this is safe in any run config.
    private func producerShadowPush(_ comp: LLVMValueRef, _ vwt: LLVMValueRef) {
        let push = e.preludeFn("nomu_fn_rtShadowPush", ret: e.voidTy, params: [e.i8ptr, e.i8ptr, e.i8ptr])
        let node = e.entryAlloca(e.structTy([e.i8ptr, e.i8ptr, e.i8ptr]), "pshadow.node")
        _ = e.buildCall(push.0, push.1, [node, comp, vwt])
    }

    private func lowerBlock(_ blk: SSABlock) {
        curBlockId = blk.id
        var i = 0
        while i < blk.insts.count {
            let inst = blk.insts[i]
            e.setDebugLoc(inst.span)
            // ssairgen emits `writeBarrier(obj, v)` immediately before `store(addr, v)` for a managed
            // field write; fuse the pair into one barriered store (the combined ABI the shared
            // `storeField` emits). A standalone `store` is a plain store.
            // An erased store (writing a `T`-typed value, held by buffer) is a VWT-sized copy, not a
            // first-class pointer store, so it does not fold into `storeField` (task 100.4.3.10): the copy
            // runs, then the barrier's object-remembering half logs the heap object, which is the same barrier.
            if case .writeBarrier(let object, let bv) = inst.kind,
               i + 1 < blk.insts.count, case .store(let addr, let sv) = blk.insts[i + 1].kind, sv.id == bv.id {
                if heldByBuffer(sv.type) {
                    lowerInst(blk.insts[i + 1])
                    let target = val(object)
                    if LLVMGetPointerAddressSpace(LLVMTypeOf(target)) == 1 {
                        let (remember, rty) = e.nomuRememberBarrier()
                        _ = e.buildCall(remember, rty, [target])
                    }
                } else {
                    e.storeField(val(object), val(addr), val(sv), type: sv.type)
                }
                i += 2
                continue
            }
            // Record the shaped roots crossing a safepoint instruction, so a per-site statepoint call in its
            // lowering carries them (task 176). `liveOutInst` is live-after; the inst's own result is new, so
            // it does not cross. A direct user call / `concat` takes the bundle directly; an allocation routes
            // through the `noinline` rooted-alloc variant (`rtAllocManaged`) so the bundle reaches its
            // statepoint. The loop-header poll records roots on its own path (`emitHeaderPoll`).
            // A recorded slot the instruction itself uses (a slot passed to a call that runs on it) is live at
            // its safepoint too, so its operands join the slot set; slot-derived addresses record their slot.
            if isSafepointInst(inst.kind) {
                let crossing = shapedLive?.crossingInst[blk.id]?[i] ?? []
                var slotIds = shapedSlotLive?.liveOutInst[blk.id]?[i] ?? []
                _ = remapOperands(inst.kind) { slotIds.insert($0.id); return $0 }
                if let r = inst.result { slotIds.remove(r.id) }
                let slots = slotRoot.roots(slotIds)
                e.pendingDeopt = shapedDeoptOps(homed: crossing, slots: slots)
            }
            lowerInst(inst)
            e.pendingDeopt = nil
            i += 1
        }
        e.setDebugLoc(blk.terminator.span)
        lowerTerminator(blk.terminator)
    }

    // MARK: - Instructions

    private func lowerInst(_ inst: SSAInst) {
        let span = inst.span
        switch inst.kind {
        case .constInt(let n):
            if inst.result?.type == .uint8 {
                define(inst, LLVMConstInt(e.i8, UInt64(n & 0xFF), 0))
            } else {
                define(inst, LLVMConstInt(e.i64, UInt64(bitPattern: Int64(n)), 1))
            }
        case .constDouble(let x):
            define(inst, LLVMConstReal(e.f64, x))
        case .constBool(let v):
            define(inst, LLVMConstInt(e.i1, v ? 1 : 0, 0))
        case .constString(let s):
            define(inst, e.lowerStringLit(s))
        case .globalRead(let name):
            define(inst, inst.result.flatMap { readGlobal(name, $0.type, span) })

        case .binary(let op, let l, let r):
            define(inst, lowerBinary(op, l, r, span))

        case .alloc(let t):
            define(inst, lowerAlloc(t, span))
        case .stackAlloc(let t):
            guard let lt = storageType(t, span) else { return }
            let slot = e.entryAlloca(lt, "slot")
            // Zero-init a recorded slot before any safepoint can observe it (I11b): the all-zero pattern decodes
            // to no managed words (a leaf's tag 0, an enum's case 0 with a null payload), so a
            // mid-construction aggregate scans safely.
            if let r = inst.result, shapedSlots[r.id] != nil { LLVMBuildStore(b, LLVMConstNull(lt), slot) }
            define(inst, slot)
        case .load(let addr):
            guard let r = inst.result else { return }
            // A buffer-held value loads as a copy into a buffer of its own, a typed GC root while live.
            if heldByBuffer(r.type) {
                guard let size = erasedTypeSize(r.type, span) else { return }
                let buf = e.runtimeSizedBuffer(size, "erased.copy", checked: curChecksStack)
                var src = val(addr)
                if LLVMGetPointerAddressSpace(LLVMTypeOf(src)) == 1 { src = e.toUnmanaged(src) }
                let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                _ = e.buildCall(memcpy, mty, [buf, src, size])
                registerErasedComponents(buf, r.type, LLVMConstInt(e.i64, 0, 0), span)
                define(inst, buf)
                return
            }
            guard let rt = ty(r.type, span) else { return }
            define(inst, loadReloading(val(addr), r.type, rt))
        case .store(let addr, let value):
            // An erased value (`.typeParam`, or a composed `.generic`) is held by a buffer pointer, so a
            // store of one is a VWT-sized copy from the source buffer into the destination — the write dual
            // of the erased field read/return path (task 100.4.3.10). A residual `.typeParam` only survives
            // in an erased body, where `curVWTParams` sizes the copy. The destination may be a `p1` field
            // address of an erased class receiver; a synchronous copy has no safepoint, so casting both
            // operands to addr0 is sound.
            if heldByBuffer(value.type) {
                guard let size64 = erasedTypeSize(value.type, span) else { return }
                let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                var dst = val(addr), src = val(value)
                if LLVMGetPointerAddressSpace(LLVMTypeOf(dst)) == 1 { dst = e.toUnmanaged(dst) }
                if LLVMGetPointerAddressSpace(LLVMTypeOf(src)) == 1 { src = e.toUnmanaged(src) }
                _ = e.buildCall(memcpy, mty, [dst, src, size64])
            } else {
                LLVMBuildStore(b, val(value), val(addr))
            }
        case .writeBarrier:
            break   // handled by the fused-pair path in `lowerBlock`; a lone barrier is a no-op
        case .fieldAddr(let base, let idx):
            define(inst, fieldSlotAddr(base, idx, span))
        case .elementAddr(let base, let index):
            define(inst, EgressArrays.elementAddr(self, base, index, inst.result!.type, span))
        case .arrayLen(let arr):
            define(inst, LLVMBuildLoad2(b, e.i64, e.gepByte(val(arr), LLVMConstInt(e.i64, 8, 0)), "arr.len"))
        case .boundscheck(let index, let length):
            EgressArrays.emitBoundscheck(self, val(index), val(length))

        case .call(let call):
            lowerCall(call, inst: inst, span: span)

        case .mailboxInit(let obj):
            EgressConcurrency.lowerMailboxInit(self, obj, span)
        case .actorSend(let receiver, let handler, let args):
            guard case .named(let actorName, _) = receiver.type else {
                e.fail("7.2.3: actorSend on a non-actor receiver", span); return
            }
            _ = e.emitActorSend(actorName, handler, val(receiver), { args.map { self.val($0) } }, span)
        case .fiber(let startFn, let env, _):
            EgressConcurrency.lowerFiber(self, startFn: startFn, env: env, span: span)

        case .makeStruct(let t, let fields):
            define(inst, makeStruct(t, fields, span))
        case .makeEnum(let t, let caseIndex, let fields):
            define(inst, makeEnum(t, caseIndex, fields, span))
        case .extractField(let base, let idx):
            // A single-field shaped wrapper lowers to its field's type directly (task 121.1.1), so extracting
            // its one field is identity — the value already *is* the field. (No `extractvalue` on a strTy.)
            if e.isShapedWrapper(base.type) {
                define(inst, val(base))
            } else {
                guard case .named(let name, _) = base.type else { e.fail("extractField on a non-nominal value", span); return }
                let raw = LLVMBuildExtractValue(b, val(base), UInt32(e.llvmFieldIndex(name, idx)), "fld")!
                define(inst, inst.result.map { e.fromFieldStorage(raw, $0.type) } ?? raw)
            }
        case .enumTag(let base):
            if case .generic(let gb, let ga) = base.type {
                guard let en = e.enumMap[gb], let l = erasedEnumLayout(en, ga, span) else {
                    e.fail("enumTag on a non-enum generic", span); return
                }
                define(inst, loadEnumCase(val(base), l))
            } else {
                define(inst, enumTag(base, span))
            }
        case .extractPayload(let base, let caseIndex, let fieldIndex):
            define(inst, extractPayload(base, caseIndex, fieldIndex, inst.result!.type, span))

        case .box(let value, let interfaces, let onStack):
            define(inst, lowerBox(value, interfaces, onStack, span))
        case .arrayLit(let elements, let elem):
            define(inst, EgressArrays.lowerArrayLit(self, elements, elem, span))
        case .makeClosure(let funcName, let env, let onStack):
            define(inst, EgressConcurrency.makeClosure(self, funcName, env, onStack, span))
        case .funcAddr(let name):
            // The bare C-ABI code pointer of a top-level function (task 128.2, Runtime.ofFunc). The
            // callable's `fn` is a `ptr` already usable as an addrspace(0) RawPtr (the closure/fiber
            // paths store it into an i8ptr slot directly), so no cast is needed.
            guard let c = e.callables["f:\(name)"] else {
                e.fail("128.2: unknown function '\(name)' for Runtime.ofFunc", span); return
            }
            e.runtimeEntries.insert(String(cString: LLVMGetValueName(c.fn)))
            define(inst, c.fn)
        }
    }

    // Every producer of a result goes through here, so a homed value's home is written with it.
    func define(_ inst: SSAInst, _ value: LLVMValueRef?) {
        guard let value = value, let result = inst.result else { return }
        values[result.id] = value
        storeHomeIfShaped(result.id, value)
    }

    // MARK: - Terminators (block args → φ incomings)

    private func lowerTerminator(_ term: SSATerm) {
        // Loop-scoped typed-root unwind (task 100.4.3.6): a back-edge restores the shadow-top saved at its
        // header, clearing this iteration's producer pushes before the next iteration re-pushes them. The
        // non-back successors of such a block are the loop exit, which also wants the pre-loop top, so an
        // unconditional restore here is correct for the standard loop shapes. A `ret` block is never a
        // back-edge source (it branches nowhere), so this never races the function epilogue pop.
        if let header = curBackEdges[curBlockId], let slot = headerSaveSlot[header], curProducerSave != nil {
            let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i64])
            _ = e.buildCall(pop.0, pop.1, [LLVMBuildLoad2(b, e.i64, slot, "loopshadow")])
        }
        switch term.kind {
        case .br(let target, let args):
            passArgs(to: target, args)
            LLVMBuildBr(b, blockMap[target])
        case .condBr(let cond, let then, let thenArgs, let els, let elseArgs):
            passArgs(to: then, thenArgs)
            passArgs(to: els, elseArgs)
            LLVMBuildCondBr(b, val(cond), blockMap[then], blockMap[els])
        case .switchOn(let scrutinee, let cases, let defaultTarget, let defaultArgs):
            passArgs(to: defaultTarget, defaultArgs)
            let sw = LLVMBuildSwitch(b, val(scrutinee), blockMap[defaultTarget], UInt32(cases.count))
            for c in cases {
                passArgs(to: c.target, c.args)
                LLVMAddCase(sw, LLVMConstInt(e.i64, UInt64(bitPattern: Int64(c.value)), 1), blockMap[c.target])
            }
        case .ret(let v):
            // Producer-internal typed-root epilogue (task 100.4.3.6): unwind every shadow node this frame
            // pushed, restoring the shadow-top saved in the prologue. Before the return move, so the
            // frame's registrations never outlive it. The returned composed buffer's `T`-components are
            // re-registered by the caller (consumer bracketing) or the caller's own prologue, if held.
            if let save = curProducerSave {
                let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i64])
                _ = e.buildCall(pop.0, pop.1, [save])
            }
            if let sret = curSretParam, let rt = curReturnType, let v = v {
                // Erased return: move the value buffer into the caller's result buffer (backend.md §4),
                // sized by the return type's derived VWT (a bare `T`, or a composed `Box<T>` summed from
                // its field VWTs). A move is a memcpy — the source is not read again after return, so the
                // trivial (POD) inline memcpy is sound without the indirect `move` witness.
                guard let size64 = erasedTypeSize(rt, term.span) else { return }
                let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                // The source may be a `p1` field address of an erased **class** receiver (task 100.4.3.9) —
                // cast it to addr0 for the memcpy. A synchronous copy has no safepoint, so the object cannot
                // move mid-copy; the addrspacecast is sound here.
                var srcBuf = val(v)
                if LLVMGetPointerAddressSpace(LLVMTypeOf(srcBuf)) == 1 { srcBuf = e.toUnmanaged(srcBuf) }
                _ = e.buildCall(memcpy, mty, [sret, srcBuf, size64])
                LLVMBuildRetVoid(b)
            } else if let v = v {
                LLVMBuildRet(b, val(v))
            } else {
                LLVMBuildRetVoid(b)
            }
        case .unreachable:
            LLVMBuildUnreachable(b)
        }
    }

    // Record each edge argument as a pending incoming of the target block's φ, from the current block.
    // The predecessor block is fixed now; the argument's LLVM value is resolved in `flushIncomings`,
    // after every block is lowered, so an argument defined in a later-lowered block still resolves.
    private func passArgs(to target: Int, _ args: [SSAValue]) {
        guard !args.isEmpty, let params = blocksById[target]?.params else { return }
        guard let pred = LLVMGetInsertBlock(b) else { return }
        for (i, arg) in args.enumerated() where i < params.count {
            guard let phi = values[params[i].id] else { continue }
            pendingIncomings.append((phi: phi, pred: pred, arg: arg))
        }
    }

    // Wire every deferred φ incoming once all definitions exist.
    private func flushIncomings() {
        for p in pendingIncomings {
            // `val` may emit instructions now — a homed shaped arg loads from its frame slot (task 176). Emit
            // them at the end of the predecessor (before its terminator), not at the function's last block,
            // so the loads sit in the edge's source block where they are dominated by the slot's store.
            if let term = LLVMGetBasicBlockTerminator(p.pred) {
                LLVMPositionBuilderBefore(b, term)
            } else {
                LLVMPositionBuilderAtEnd(b, p.pred)
            }
            var incoming: [LLVMValueRef?] = [val(p.arg)]
            var block: [LLVMBasicBlockRef?] = [p.pred]
            LLVMAddIncoming(p.phi, &incoming, &block, 1)
        }
        pendingIncomings.removeAll(keepingCapacity: true)
    }

    // MARK: - Operations

    private func lowerBinary(_ op: BinOp, _ l: SSAValue, _ r: SSAValue, _ span: Span) -> LLVMValueRef {
        let lv = val(l), rv = val(r)
        if l.type == .double {
            switch op {
            case .add: return LLVMBuildFAdd(b, lv, rv, "fadd")
            case .sub: return LLVMBuildFSub(b, lv, rv, "fsub")
            case .mul: return LLVMBuildFMul(b, lv, rv, "fmul")
            case .div: return LLVMBuildFDiv(b, lv, rv, "fdiv")
            case .mod: return LLVMBuildFRem(b, lv, rv, "frem")
            case .eq, .neq, .lt, .gt, .lte, .gte:
                let pred: LLVMRealPredicate
                switch op {
                case .eq:  pred = LLVMRealOEQ
                case .neq: pred = LLVMRealONE
                case .lt:  pred = LLVMRealOLT
                case .gt:  pred = LLVMRealOGT
                case .lte: pred = LLVMRealOLE
                default:   pred = LLVMRealOGE
                }
                return LLVMBuildFCmp(b, pred, lv, rv, "fcmp")
            case .bitAnd, .bitOr, .bitXor, .shl, .shr:
                e.fail("7.2.3: bitwise/shift operators are not valid on Double", span); return lv
            case .and, .or:
                e.fail("logical '&&'/'||' are lowered to branches in SSAIRgen; none should reach the egress", span); return lv
            }
        }
        // Integer path: signed for Int, unsigned for UInt8/UInt64 — differing on div/rem, `>>`, and compares.
        let unsigned = (l.type == .uint8 || l.type == .uint64)
        switch op {
        case .add: return LLVMBuildAdd(b, lv, rv, "add")
        case .sub: return LLVMBuildSub(b, lv, rv, "sub")
        case .mul: return LLVMBuildMul(b, lv, rv, "mul")
        case .div: return unsigned ? LLVMBuildUDiv(b, lv, rv, "div") : LLVMBuildSDiv(b, lv, rv, "div")
        case .mod: return unsigned ? LLVMBuildURem(b, lv, rv, "rem") : LLVMBuildSRem(b, lv, rv, "rem")
        case .bitAnd: return LLVMBuildAnd(b, lv, rv, "and")
        case .bitOr:  return LLVMBuildOr(b, lv, rv, "or")
        case .bitXor: return LLVMBuildXor(b, lv, rv, "xor")
        case .shl:    return LLVMBuildShl(b, lv, rv, "shl")
        case .shr:    return unsigned ? LLVMBuildLShr(b, lv, rv, "shr") : LLVMBuildAShr(b, lv, rv, "shr")
        case .eq, .neq, .lt, .gt, .lte, .gte:
            let pred: LLVMIntPredicate
            switch op {
            case .eq:  pred = LLVMIntEQ
            case .neq: pred = LLVMIntNE
            case .lt:  pred = unsigned ? LLVMIntULT : LLVMIntSLT
            case .gt:  pred = unsigned ? LLVMIntUGT : LLVMIntSGT
            case .lte: pred = unsigned ? LLVMIntULE : LLVMIntSLE
            default:   pred = unsigned ? LLVMIntUGE : LLVMIntSGE
            }
            return LLVMBuildICmp(b, pred, lv, rv, "cmp")
        case .and, .or:
            e.fail("logical '&&'/'||' are lowered to branches in SSAIRgen; none should reach the egress", span); return lv
        }
    }

    // A managed heap allocation for a class / actor / synthesized env object: size = header (+ mailbox
    // for an actor) + fields, then stamp the type-id header. `alloc` for a value aggregate never
    // occurs (those are `stackAlloc`/`makeStruct`).
    private func lowerAlloc(_ t: Type, _ span: Span) -> LLVMValueRef? {
        if case .generic(let base, _) = t, let c = e.classMap[base] { return lowerErasedAlloc(t, fields: c.fields.count, span) }
        guard case .named(let name, let kind) = t else { e.fail("7.2.3: alloc of non-nominal type", span); return nil }
        let obj: LLVMValueRef
        if e.actorMap[name] != nil || e.classMap[name] != nil {
            obj = e.rtAllocManaged(LLVMConstInt(e.i64, UInt64(e.objectSize(name)), 0))
        } else {
            e.fail("7.2.3: alloc of unknown heap type '\(name)'", span); return nil
        }
        e.writeTypeIdHeader(obj, name)
        return obj
    }

    // A generic class allocated in a compiled-once body: sized from the dictionary's sizes, with the descriptor the
    // dictionary holds for this instantiation in its header.
    private func lowerErasedAlloc(_ t: Type, fields: Int, _ span: Span) -> LLVMValueRef? {
        guard let dict = curDictionary,
              let i = e.recipes[curFnName]?.needs.firstIndex(of: .object(t)) else {
            e.fail("251.3: no descriptor in '\(curFnName)' for '\(t)'", span); return nil
        }
        guard let size = erasedFieldOffset(t, fields, span) else { return nil }   // past the last field
        let header = LLVMBuildPtrToInt(b, e.loadDictionaryWord(dict, curDictionaryWords.count + i), e.i64, "desc")!
        let obj = e.rtAllocManaged(size)
        LLVMBuildStore(b, header, obj)
        return obj
    }

    // The address of field `idx` in `base`. A struct base (a `stackAlloc` slot) GEPs at field index;
    // a class/actor/env base (a managed object pointer) GEPs past the object header (index+1).
    private func fieldSlotAddr(_ base: SSAValue, _ idx: Int, _ span: Span) -> LLVMValueRef? {
        // A residual composed generic (`Box<T>`) is held as an opaque buffer (task 100.4.3.3.4): the
        // field slot is the buffer pointer offset by the field's derived-VWT byte offset (0 for the
        // first field; the running sum of prior field sizes otherwise, computed from the VWTs).
        if case .generic = base.type {
            guard let off = erasedFieldOffset(base.type, idx, span) else { return nil }
            return e.gepByte(val(base), off)
        }
        guard case .named(let name, let kind) = base.type else {
            e.fail("7.2.3: fieldAddr on a non-nominal base", span); return nil
        }
        switch kind {
        case .struct_:
            guard let st = e.structType(name) else { return nil }
            return e.structGEP(st, val(base), e.llvmFieldIndex(name, idx))
        case .class_:
            guard let ct = e.classType(name) else { return nil }
            return e.structGEP(ct, val(base), e.llvmFieldIndex(name, idx))
        case .actor_:
            guard let at = e.actorType(name) else { return nil }
            return e.structGEP(at, val(base), e.llvmFieldIndex(name, idx))
        default:
            e.fail("7.2.3: fieldAddr on '\(name)'", span); return nil
        }
    }

    private func makeStruct(_ t: Type, _ fields: [SSAValue], _ span: Span) -> LLVMValueRef? {
        // A residual composed generic (`Box<T>`) is built into a derived-VWT-sized stack buffer: each
        // field is copied to its offset — a VWT-sized memcpy for a type-parameter/composed field (held
        // by buffer), a plain store for a concrete scalar field (task 100.4.3.3.4).
        if case .generic(let base, let args) = t, let s = e.structMap[base] {
            guard let size = erasedTypeSize(t, span) else { return nil }
            let buf = e.runtimeSizedBuffer(size, "erased.box", checked: curChecksStack)
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            for (i, f) in s.fields.enumerated() where i < fields.count {
                guard let off = erasedFieldOffset(t, i, span) else { return nil }
                let dst = e.gepByte(buf, off)
                let ft = substType(f.type, subst)
                if heldByBuffer(ft) {
                    guard let fsize = erasedTypeSize(ft, span) else { return nil }
                    let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                    _ = e.buildCall(memcpy, mty, [dst, val(fields[i]), fsize])
                    registerErasedComponents(buf, ft, off, span)   // typed GC root for the `T`-component (100.4.3.6)
                } else {
                    LLVMBuildStore(b, val(fields[i]), dst)
                    if mentionsTypeParam(ft) { registerErasedComponents(buf, ft, off, span) }   // a generic class
                }
            }
            return buf
        }
        // A single-field shaped wrapper is its field (task 121.1.1): the value *is* the one field's value, no
        // aggregate to insert into — `struct String { let base }` built from a `StringBase` is that StringBase.
        if e.isShapedWrapper(t), let f = fields.first {
            return val(f)
        }
        guard case .named(let name, _) = t, let st = e.structType(name) else {
            e.fail("7.2.3: makeStruct of non-struct", span); return nil
        }
        var agg = LLVMGetUndef(st)
        for (idx, f) in fields.enumerated() {
            agg = LLVMBuildInsertValue(b, agg, e.toFieldStorage(val(f), f.type), UInt32(e.llvmFieldIndex(name, idx)), "")
        }
        return agg
    }

    // Build an enum value `{ i64 tag, [P x i64] payload }` in a temp slot, then load the aggregate.
    private func makeEnum(_ t: Type, _ caseIndex: Int, _ fields: [SSAValue], _ span: Span) -> LLVMValueRef? {
        // A residual composed generic enum (`Opt<T>`) is built into a derived-VWT-sized stack buffer: the
        // tag word at offset 0, then each payload field copied to its offset (task 100.4.3.3.4).
        if case .generic(let base, let args) = t, let en = e.enumMap[base], caseIndex < en.cases.count {
            guard let size = erasedTypeSize(t, span), let l = erasedEnumLayout(en, args, span) else { return nil }
            let buf = e.runtimeSizedBuffer(size, "erased.enum", checked: curChecksStack)
            if case .tagOnly = l.kind {} else {
                // A payload-free case is the zeroed payload with its extra inhabitant or tag written in.
                let (memset, msty) = e.runtimeFn("memset", ret: e.i8ptr, params: [e.i8ptr, e.i32, e.i64], varArg: false)
                _ = e.buildCall(memset, msty, [buf, LLVMConstInt(e.i32, 0, 0), size])
            }
            let subst = Dictionary(uniqueKeysWithValues: zip(en.generics.map(\.name), args))
            for (i, f) in en.cases[caseIndex].fields.enumerated() where i < fields.count {
                guard let off = erasedEnumPayloadOffset(base, args, caseIndex, i, span) else { return nil }
                let dst = e.gepByte(buf, off)
                let ft = substType(f.type, subst)
                if heldByBuffer(ft) {
                    guard let fsize = erasedTypeSize(ft, span) else { return nil }
                    let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                    _ = e.buildCall(memcpy, mty, [dst, val(fields[i]), fsize])
                    registerErasedComponents(buf, ft, off, span)   // typed GC root for the `T`-component (100.4.3.6)
                } else {
                    LLVMBuildStore(b, val(fields[i]), dst)
                    if mentionsTypeParam(ft) { registerErasedComponents(buf, ft, off, span) }   // a generic class
                }
            }
            storeEnumCase(buf, l, const64(caseIndex))
            return buf
        }
        guard case .named(let name, _) = t, let et = e.enumType(name),
              let en = e.enumMap[name] else { e.fail("7.2.3: makeEnum of non-enum", span); return nil }
        switch e.shapes.enumLayout(name) {
        case .tagOnly:
            var elems: [LLVMValueRef?] = [LLVMConstInt(LLVMStructGetTypeAtIndex(et, 0), UInt64(caseIndex), 0)]
            return elems.withUnsafeMutableBufferPointer { LLVMConstNamedStruct(et, $0.baseAddress, 1) }
        case .overExtraInhabitants(let p):
            if caseIndex == p { return payloadAggregate(et, en.cases[p], fields) }
            // A payload-free case: the zeroed payload with the case's extra inhabitant written in.
            guard let x = e.shapes.payloadExtraInhabitants(en.cases[p].fields.map(\.type)) else {
                e.fail("enum \(name) has no extra inhabitants for its cases", span); return nil
            }
            let k = e.shapes.enumExtraInhabitantIndex(name, caseIndex)
            let value = UInt64(x.first + k) << UInt64(x.shift)
            if value == 0 { return LLVMConstNull(et) }
            let slot = e.entryAlloca(et, "enum")
            LLVMBuildStore(b, LLVMConstNull(et), slot)
            LLVMBuildStore(b, LLVMConstInt(e.intType(bytes: x.width), value, 0),
                           e.gepByte(slot, LLVMConstInt(e.i64, UInt64(x.offset), 0)))
            return LLVMBuildLoad2(b, et, slot, "enumv")
        case .spareBits(let payloads, let tagOffset):
            // The zeroed region with the case's payload over it; then the word at `tagOffset`: the payload case's
            // reference plus `c`, a pointer derived from it, or `c << 3` for a payload-free case.
            let index = UInt32(tagOffset / 8)
            var agg = LLVMConstNull(et)!
            if payloads.contains(caseIndex), !fields.isEmpty {
                guard let cst = e.caseStructType(name, en.cases[caseIndex]) else { return nil }
                let slot = e.entryAlloca(et, "enum")
                LLVMBuildStore(b, LLVMConstNull(et), slot)
                for (idx, f) in fields.enumerated() { LLVMBuildStore(b, val(f), e.structGEP(cst, slot, idx)) }
                agg = LLVMBuildLoad2(b, et, slot, "enumv")!
                if caseIndex == 0 { return agg }
                let ref = LLVMBuildExtractValue(b, agg, index, "sb.ref")!
                return LLVMBuildInsertValue(b, agg, e.gepByte(ref, const64(caseIndex)), index, "enumv")
            }
            let word = LLVMConstIntToPtr(const64(caseIndex << EnumLayout.spareBitShift), e.p1)!
            return LLVMBuildInsertValue(b, agg, word, index, "enumv")
        case .tagged(_, let w):
            // The zeroed region with the case's payload over it, then the tag, the last element.
            let last = LLVMCountStructElementTypes(et) - 1
            let tag = LLVMConstInt(e.intType(bytes: w), UInt64(caseIndex), 0)!
            if fields.isEmpty { return LLVMBuildInsertValue(b, LLVMConstNull(et), tag, last, "enumv") }
            guard let cst = e.caseStructType(name, en.cases[caseIndex]) else { return nil }
            let slot = e.entryAlloca(et, "enum")
            LLVMBuildStore(b, LLVMConstNull(et), slot)
            for (idx, f) in fields.enumerated() {
                LLVMBuildStore(b, val(f), e.structGEP(cst, slot, idx))
            }
            LLVMBuildStore(b, tag, e.structGEP(et, slot, Int(last)))
            return LLVMBuildLoad2(b, et, slot, "enumv")
        }
    }

    // An enum aggregate whose first elements are a case's payload fields, the rest zero.
    private func payloadAggregate(_ et: LLVMTypeRef, _ c: NOIREnumCase, _ fields: [SSAValue]) -> LLVMValueRef {
        var agg = LLVMConstNull(et)!
        for (i, f) in fields.enumerated() where i < c.fields.count {
            agg = LLVMBuildInsertValue(b, agg, e.toFieldStorage(val(f), c.fields[i].type), UInt32(i), "enumf")!
        }
        return agg
    }

    // A named enum value's case index, as an `i64`. Over the payload's extra inhabitants, the field that holds
    // them, shifted, is the k-th past its first unused value for the k-th payload-free case (declared order,
    // skipping the payload case), and anything else is the payload case.
    private func enumTag(_ base: SSAValue, _ span: Span) -> LLVMValueRef? {
        guard case .named(let name, _) = base.type, let et = e.enumType(name), let en = e.enumMap[name] else {
            e.fail("7.2.3: enumTag on non-enum", span); return nil
        }
        switch e.shapes.enumLayout(name) {
        case .tagOnly:
            return LLVMBuildZExt(b, LLVMBuildExtractValue(b, val(base), 0, "tag")!, e.i64, "tag64")
        case .tagged(_, let w):
            let raw = LLVMBuildExtractValue(b, val(base), LLVMCountStructElementTypes(et) - 1, "tag")!
            return w < 8 ? LLVMBuildZExt(b, raw, e.i64, "tag64") : raw
        case .spareBits(let payloads, let tagOffset):
            // The address's low bits and whether it is below the first page are the same before and after the
            // collector moves the object, so the integer may be taken from any copy of the pointer.
            let ref = LLVMBuildExtractValue(b, val(base), UInt32(tagOffset / 8), "sb")!
            let word = LLVMBuildPtrToInt(b, ref, e.i64, "sb.word")!
            return spareBitCase(word, allPayloads: payloads.count == en.cases.count)
        case .overExtraInhabitants(let p):
            guard let x = e.shapes.payloadExtraInhabitants(en.cases[p].fields.map(\.type)) else {
                return LLVMConstInt(e.i64, UInt64(p), 0)
            }
            let slot = e.entryAlloca(et, "enum")
            LLVMBuildStore(b, val(base), slot)
            let it = e.intType(bytes: x.width)
            var v = LLVMBuildLoad2(b, it, e.gepByte(slot, LLVMConstInt(e.i64, UInt64(x.offset), 0)), "xi")!
            if x.width < 8 { v = LLVMBuildZExt(b, v, e.i64, "xi64")! }
            if x.shift > 0 { v = LLVMBuildLShr(b, v, LLVMConstInt(e.i64, UInt64(x.shift), 0), "xis")! }
            let k = LLVMBuildSub(b, v, LLVMConstInt(e.i64, UInt64(x.first), 0), "k")!
            let empties = UInt64(en.cases.count - 1)
            let isEmpty = LLVMBuildICmp(b, LLVMIntULT, k, LLVMConstInt(e.i64, empties, 0), "isempty")!
            // The k-th payload-free case is case k, or k + 1 past the payload case.
            let pastPayload = LLVMBuildICmp(b, LLVMIntUGE, k, LLVMConstInt(e.i64, UInt64(p), 0), "past")!
            let emptyCase = LLVMBuildAdd(b, k, LLVMBuildZExt(b, pastPayload, e.i64, "skip")!, "ecase")!
            return LLVMBuildSelect(b, isEmpty, emptyCase, LLVMConstInt(e.i64, UInt64(p), 0), "tag")
        }
    }

    // Read a payload field of an enum *value*: spill it, GEP the case struct over the payload region.
    private func extractPayload(_ base: SSAValue, _ caseIndex: Int, _ fieldIndex: Int,
                                _ fieldType: Type, _ span: Span) -> LLVMValueRef? {
        // A residual composed generic enum (`Opt<T>`) held by buffer: the payload field is at its
        // derived offset past the tag; a `T` field yields a buffer pointer, a concrete field a load.
        if case .generic(let genBase, let args) = base.type {
            guard let off = erasedEnumPayloadOffset(genBase, args, caseIndex, fieldIndex, span) else { return nil }
            let ptr = e.gepByte(val(base), off)
            if heldByBuffer(fieldType) { return ptr }
            guard let fty = ty(fieldType, span) else { return nil }
            let v = LLVMBuildLoad2(b, fty, ptr, "pl")!
            if let en = e.enumMap[genBase], let l = erasedEnumLayout(en, args, span), case .spareBits(_, let tagOffset) = l.kind,
               LLVMIsAConstantInt(off) != nil, Int(LLVMConstIntGetZExtValue(off)) == tagOffset {
                return spareBitUntag(v)   // the reference less its case
            }
            return v
        }
        guard case .named(let name, _) = base.type, let et = e.enumType(name),
              let en = e.enumMap[name], let cst = e.caseStructType(name, en.cases[caseIndex]),
              let fty = ty(fieldType, span) else { e.fail("7.2.3: extractPayload on non-enum", span); return nil }
        switch e.shapes.enumLayout(name) {
        case .overExtraInhabitants:
            // The payload case's fields are the enum's elements.
            let raw = LLVMBuildExtractValue(b, val(base), UInt32(fieldIndex), "pl")!
            return e.fromFieldStorage(raw, fieldType)
        case .spareBits(_, let tagOffset):
            // The reference carrying the case is untagged; the case's other fields read as they lie.
            if e.shapes.enumCaseLayout(name, caseIndex).offsets[fieldIndex] == tagOffset {
                return spareBitUntag(LLVMBuildExtractValue(b, val(base), UInt32(tagOffset / 8), "sb")!)
            }
        case .tagOnly, .tagged:
            break
        }
        let slot = e.entryAlloca(et, "enum")
        LLVMBuildStore(b, val(base), slot)
        return LLVMBuildLoad2(b, fty, e.structGEP(cst, slot, fieldIndex), "pl")
    }

    // Wrap a conformer as `any I` / `any A & B`, or upcast `any B` → `any A` — the SSA `box` op's value
    // is already lowered, so this is `lowerBox` over an operand.
    private func lowerBox(_ value: SSAValue, _ interfaces: [String], _ onStack: Bool, _ span: Span) -> LLVMValueRef? {
        if case .existential(let src) = value.type, interfaces.count == 1 {
            let box = val(value)
            let witnessPtr = e.anyBoxWitness(box)
            let payload = e.anyBoxPayload(box)
            let idx = e.witnessSlotIndex(src, "base_\(interfaces[0])")
            guard idx >= 0 else { e.fail("7.2.3: '\(src)' has no base '\(interfaces[0])'", span); return nil }
            let base = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(e.witnessType(src), witnessPtr, idx), "base")!
            return e.makeAnyBox(base, payload, onStack: onStack)
        }
        guard case .named(let t, _) = value.type else { e.fail("7.2.3: cannot box non-nominal value", span); return nil }
        let witness = interfaces.count == 1 ? e.witnessInstance(t, interfaces[0]) : e.compositeInstance(t, interfaces)
        guard let w = witness, let pl = e.boxPayload({ self.val(value) }, value.type) else { return nil }
        return e.makeAnyBox(w, pl, onStack: onStack)
    }

    // MARK: - Calls

    private func lowerCall(_ call: SSACall, inst: SSAInst, span: Span) {
        switch call.kind {
        case .direct(let name):
            if let v = lowerDirectCall(name, call.args, typeArgs: call.typeArgs,
                                       resultType: inst.result?.type ?? .void, span: span) {
                define(inst, v)
            }
        case .witness(let receiver, let interface, let method):
            // Erased requirement dispatch (task 100.4.3.3.3): the receiver is a `.typeParam` value held
            // by buffer, and the witness table is the PWT parameter passed for that bound (backend.md
            // §4) — dispatch through it with the value-buffer pointer as self, rather than the boxed
            // existential path below.
            if case .typeParam(let tp) = receiver.type {
                guard let pwt = curPWTParams["\(tp)::\(interface)"] else {
                    e.fail("100.4.3.3.3: no witness parameter for '\(tp): \(interface)'", span); return
                }
                var argVals: [LLVMValueRef] = []
                var argTys: [LLVMTypeRef] = []
                for a in call.args {
                    guard let t = ty(a.type, span) else { return }
                    argTys.append(t); argVals.append(val(a))
                }
                if let v = e.witnessDispatchErased(pwt: pwt, iface: interface, method: method, selfPtr: val(receiver),
                                                   argVals: argVals, argTys: argTys,
                                                   resultType: inst.result?.type ?? .void, span: span) {
                    define(inst, v)
                }
                return
            }
            let box = val(receiver)
            let witnessPtr: LLVMValueRef
            if case .composition(let ifaces) = receiver.type {
                let compPtr = e.anyBoxWitness(box)
                guard let ownerIdx = ifaces.firstIndex(of: interface) else {
                    e.fail("7.2.3: no interface owns '\(method)' in composition", span); return
                }
                witnessPtr = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(e.compositeType(ifaces), compPtr, ownerIdx), "sub")!
            } else {
                witnessPtr = e.anyBoxWitness(box)
            }
            let payload = e.anyBoxPayload(box)
            var argVals: [LLVMValueRef] = []
            var argTys: [LLVMTypeRef] = []
            for a in call.args {
                guard let t = ty(a.type, span) else { return }
                argTys.append(t); argVals.append(val(a))
            }
            if let v = e.witnessDispatch(witnessPtr: witnessPtr, iface: interface, method: method, payload: payload,
                                         argVals: argVals, argTys: argTys,
                                         resultType: inst.result?.type ?? .void, span: span) {
                define(inst, v)
            }
        case .indirect(let callee):
            guard case .function(let ptys, let rty) = callee.type, let retTy = ty(rty, span) else {
                e.fail("7.2.3: indirect call on a non-function value", span); return
            }
            let closure = val(callee)
            let cloTy = e.structTy([e.i64, e.i8ptr, e.p1])
            let fnPtr = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(cloTy, closure, 1), "clo.fn")!
            let env = LLVMBuildLoad2(b, e.p1, e.structGEP(cloTy, closure, 2), "clo.env")!
            var paramTys: [LLVMTypeRef] = [e.p1]
            for t in ptys { guard let lt = ty(t, span) else { return }; paramTys.append(lt) }
            var argVals: [LLVMValueRef?] = [env]
            for a in call.args { argVals.append(val(a)) }
            let r = e.buildCall(fnPtr, e.fnType(retTy, paramTys), argVals)
            define(inst, r)
        }
    }

    // The byte count of a `StringBase` value (task 121). The tag is `word1`'s top nibble (`>> 60`): `small`
    // (0) keeps its count in byte 15's low nibble (bits 56–59, 0–15); `immortal` (1) / `heap` (2) keep it in
    // `word1`'s low 56 bits. The bit-stealing layout is codegen's; `count` is lowered here, not via a C leaf.
    func strLen(_ value: LLVMValueRef) -> LLVMValueRef {
        let word1 = LLVMBuildExtractValue(b, value, 1, "s.w1")!
        let tag = LLVMBuildLShr(b, word1, LLVMConstInt(e.i64, 60, 0), "s.ltag")!
        let isSmall = LLVMBuildICmp(b, LLVMIntEQ, tag, LLVMConstInt(e.i64, 0, 0), "s.issmall")!
        let smallCount = LLVMBuildAnd(b, LLVMBuildLShr(b, word1, LLVMConstInt(e.i64, 56, 0), "s.sc")!,
                                      LLVMConstInt(e.i64, 0xF, 0), "s.smallcount")!
        let bigCount = LLVMBuildAnd(b, word1, LLVMConstInt(e.i64, 0x00FF_FFFF_FFFF_FFFF, 0), "s.bigcount")!
        return LLVMBuildSelect(b, isSmall, smallCount, bigCount, "s.len")!
    }

    // The tag-aware UTF-8 byte address of a `StringBase` value as an addrspace(0) `i8*` (task 121). `heap`
    // (tag 2): bytes sit past the buffer's `{ header, cap }` prefix at `word0 + 16`. `immortal` (1)/empty:
    // bytes at `word0`. `small` (0): the bytes are *inline* in the 16-byte value, so there is no persistent
    // address — materialize the value to a fresh stack slot (its own, so concurrent `bytePointer`s don't
    // clobber) and point at offset 0 (little-endian: inline byte i is at slot+i). The slot is addrspace(0)
    // plain bytes (no GC root). The address is a raw interior pointer (`rawInterior`) whose base is the slot,
    // the heap buffer or the immortal bytes, so it stays valid across stops: a collection moving the buffer
    // and a stack move both fix it.
    func strPtr(_ value: LLVMValueRef) -> LLVMValueRef {
        let word0 = LLVMBuildExtractValue(b, value, 0, "s.w0")!
        let word1 = LLVMBuildExtractValue(b, value, 1, "s.w1p")!
        let tag = LLVMBuildLShr(b, word1, LLVMConstInt(e.i64, 60, 0), "s.tag")!
        let isSmall = LLVMBuildICmp(b, LLVMIntEQ, tag, LLVMConstInt(e.i64, 0, 0), "s.issmall")!
        let isHeap = LLVMBuildICmp(b, LLVMIntEQ, tag, LLVMConstInt(e.i64, 2, 0), "s.isheap")!
        let slot = e.entryAlloca(e.strTy, "s.spill")
        LLVMBuildStore(b, value, slot)
        let smallInt = LLVMBuildPtrToInt(b, slot, e.i64, "s.smallint")!
        let baseInt = LLVMBuildSelect(b, isSmall, smallInt, word0, "s.base")!
        let off = LLVMBuildSelect(b, isHeap, LLVMConstInt(e.i64, 16, 0), LLVMConstInt(e.i64, 0, 0), "s.off")!
        return e.rawInterior(baseInt, off, "s.data")
    }

    // Tail-alloc a `ManagedBuffer<Header, Element>` of `capV` elements through the rooted plan-aware seam,
    // returning the buffer reference (`p1`): size = 16 + headerSize + cap*stride, with the weak-ODR type-id
    // header word at offset 0 and the capacity at 8 (task 180). The one buffer-alloc path — `__managedBufferCreate`
    // and String's heap byte buffer (121.1.3) both go through here, so there is no bespoke String allocator.
    func emitManagedBufferAlloc(header hdr: Type, element elem: Type, capacity capV: LLVMValueRef) -> LLVMValueRef {
        let tid = e.managedBufferTypeId(header: hdr, element: elem)
        let elemBytes = LLVMBuildMul(b, capV, LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "mb.elembytes")!
        let bytes = LLVMBuildAdd(b, LLVMConstInt(e.i64, UInt64(e.managedBufferElementStart(header: hdr)), 0), elemBytes, "mb.bytes")!
        let buf = e.rtAllocManaged(bytes)
        LLVMBuildStore(b, e.descOffsetHeader(tid), buf)
        LLVMBuildStore(b, capV, e.gepByte(buf, LLVMConstInt(e.i64, 8, 0)))
        return buf
    }

    // A channel's operations (`runtime/channel.nomu`, `concurrency.md` §4). The value crosses as an address and
    // its value witness. The waiter is a slot in this frame, so no operation allocates. The slot handed over
    // is this call's own: the runtime roots it through the shadow list while the fiber is parked, and a
    // buffer already registered there would be rooted twice.
    private func lowerChannelOp(_ name: String, _ args: [SSAValue], resultType: Type, span: Span) -> LLVMValueRef? {
        let buf = LLVMBuildIntToPtr(b, e.managedAddress(val(args[0])), e.i8ptr, "chan.buf")!
        if name == "__channelClose" {
            let (fn, fty) = e.nomuChanClose()
            return e.buildCall(fn, fty, [buf])
        }
        let sends = name == "__channelSend" || name == "__channelFulfill"
        let valueType: Type
        if sends {
            valueType = args[1].type
        } else if case .generic(_, let a) = resultType, a.count == 1 {
            valueType = a[0]
        } else if case .named(let n, _) = resultType, let en = e.enumMap[n],
                  let some = en.cases.first(where: { $0.name == "some" }), some.fields.count == 1 {
            valueType = some.fields[0].type   // a specialized `Option<T>`: its `some` payload is `T`
        } else {
            e.fail("channelReceive: result is not an Option", span); return nil
        }
        guard let vwt = channelWitness(valueType, span) else { return nil }
        let waiter = e.entryAlloca(LLVMArrayType2(e.i64, 7)!, "chan.waiter")
        let (memset, msty) = e.runtimeFn("memset", ret: e.i8ptr, params: [e.i8ptr, e.i32, e.i64], varArg: false)
        let (memcpy, mcty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)

        if sends {
            let src: LLVMValueRef
            if heldByBuffer(valueType) {
                guard let size = erasedTypeSize(valueType, span) else { return nil }
                src = e.runtimeSizedBuffer(size, "chan.src", checked: curChecksStack)
                _ = e.buildCall(memcpy, mcty, [src, val(args[1]), size])
            } else {
                guard let vt = ty(valueType, span) else { return nil }
                src = e.entryAlloca(vt, "chan.src")
                LLVMBuildStore(b, val(args[1]), src)
            }
            if name == "__channelFulfill" {
                let (fn, fty) = e.nomuChanFulfill()
                return e.buildCall(fn, fty, [buf, src, vwt])
            }
            let (fn, fty) = e.nomuChanSend()
            return e.buildCall(fn, fty, [buf, src, vwt, waiter])
        }

        // Receive into the payload of a zeroed `Option<T>`, then set its tag from the result. An await copies
        // the stored value the same way.
        let (fn, fty) = name == "__channelAwait" ? e.nomuChanAwait() : e.nomuChanReceive()
        if case .generic(let base, let a) = resultType {
            guard let en = e.enumMap[base], let some = en.cases.firstIndex(where: { $0.name == "some" }),
                  let none = en.cases.firstIndex(where: { $0.name == "none" }),
                  let size = erasedTypeSize(resultType, span),
                  let off = erasedEnumPayloadOffset(base, a, some, 0, span) else { return nil }
            let opt = e.runtimeSizedBuffer(size, "chan.opt", checked: curChecksStack)
            _ = e.buildCall(memset, msty, [opt, LLVMConstInt(e.i32, 0, 0), size])
            let ok = e.buildCall(fn, fty, [buf, e.gepByte(opt, off), vwt, waiter])!
            guard let l = erasedEnumLayout(en, a, span) else { return nil }
            storeOptionCase(opt, ok, l, some: some, none: none)
            registerErasedComponents(opt, resultType, LLVMConstInt(e.i64, 0, 0), span)
            return opt
        }
        guard case .named(let n, _) = resultType, let et = e.enumType(n), let en = e.enumMap[n],
              let some = en.cases.firstIndex(where: { $0.name == "some" }),
              let none = en.cases.firstIndex(where: { $0.name == "none" }),
              let l = namedEnumLayout(n) else {
            e.fail("channelReceive: result is not an Option", span); return nil
        }
        let slot = e.entryAlloca(et, "chan.opt")
        LLVMBuildStore(b, LLVMConstNull(et), slot)
        let payload = e.gepByte(slot, const64(e.shapes.enumCaseLayout(n, some).offsets[0]))
        let ok = e.buildCall(fn, fty, [buf, payload, vwt, waiter])!
        storeOptionCase(slot, ok, l, some: some, none: none)
        return LLVMBuildLoad2(b, et, slot, "chan.optv")
    }

    // `select`, as sema rewrites it (`NOIRGen.lowerSelect`). The area is an entry alloca: a header of 3 words, then
    // 6 words per case (`runtime/channel.nomu`). A receive's `Option<T>` is zeroed at registration and its payload
    // is the runtime's destination; a send's value is copied to a slot. Both are kept here, keyed by the area and
    // case, and every address goes into the area just before the wait: a later case's run-time-sized slot can
    // move the stack, which would leave an address stored earlier stale. The wait stores each case's channel
    // the same way, and again after it, at the address the collector may have moved it to, for `done` to take
    // the losing waiters out.
    private func lowerSelectOp(_ name: String, _ args: [SSAValue], typeArgs: [Type], resultType: Type, span: Span) -> LLVMValueRef? {
        let area = val(args[0])
        func caseAt(_ i: Int) -> LLVMValueRef { e.gepByte(area, LLVMConstInt(e.i64, UInt64(24 + 48 * i), 0)) }
        func store(_ v: LLVMValueRef, _ base: LLVMValueRef, _ off: Int) {
            LLVMBuildStore(b, v, e.gepByte(base, LLVMConstInt(e.i64, UInt64(off), 0)))
        }
        func constIndex(_ v: SSAValue) -> Int? {
            let c = val(v)
            guard LLVMIsAConstantInt(c) != nil else { e.fail("select: a case index is not a constant", span); return nil }
            return Int(LLVMConstIntGetSExtValue(c))
        }
        // A channel is stored as its managed pointer, never an integer made from it, so a store after the wait
        // takes the address the collector relocated.
        func bufPtr(_ v: SSAValue) -> LLVMValueRef { val(v) }
        switch name {
        case "__selectBegin":
            guard let n = constIndex(args[0]) else { return nil }
            let a = e.entryAlloca(LLVMArrayType2(e.i64, UInt64(3 + 6 * n))!, "sel.area")
            LLVMBuildStore(b, LLVMConstInt(e.i64, UInt64(n), 0), a)
            return a
        case "__selectRecv", "__selectSend":
            guard let i = constIndex(args[1]), typeArgs.count >= 1, let vwt = channelWitness(typeArgs[0], span) else { return nil }
            let c = caseAt(i)
            let sends = name == "__selectSend"
            store(LLVMConstInt(e.i64, sends ? 1 : 0, 0), c, 0)
            store(vwt, c, 24)
            store(LLVMConstInt(e.i64, 0, 0), c, 32)
            if sends {
                let valueType = typeArgs[0]
                let src: LLVMValueRef
                if heldByBuffer(valueType) {
                    guard let size = erasedTypeSize(valueType, span) else { return nil }
                    src = e.runtimeSizedBuffer(size, "sel.src", checked: curChecksStack)
                    let (memcpy, mcty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
                    _ = e.buildCall(memcpy, mcty, [src, val(args[3]), size])
                } else {
                    guard let vt = ty(valueType, span) else { return nil }
                    src = e.entryAlloca(vt, "sel.src")
                    LLVMBuildStore(b, val(args[3]), src)
                }
                selectSlots["\(args[0].id):\(i)"] = src
                return nil
            }
            guard typeArgs.count == 2, let (opt, payload) = selectOption(typeArgs[1], span) else { return nil }
            selectSlots["\(args[0].id):\(i)"] = payload
            selectOptions["\(args[0].id):\(i)"] = opt
            return nil
        case "__selectAfter":
            guard let i = constIndex(args[1]) else { return nil }
            let c = caseAt(i)
            store(LLVMConstInt(e.i64, 2, 0), c, 0)
            store(LLVMConstNull(e.i8ptr), c, 8)
            store(val(args[2]), c, 16)
            store(LLVMConstInt(e.i64, 0, 0), c, 32)
            return nil
        case "__selectLine":
            guard let i = constIndex(args[1]) else { return nil }
            let c = caseAt(i)
            store(LLVMConstInt(e.i64, 3, 0), c, 0)
            store(LLVMConstNull(e.i8ptr), c, 8)
            store(LLVMConstNull(e.i8ptr), c, 16)
            store(LLVMConstInt(e.i64, 0, 0), c, 32)
            return nil
        case "__selectLineResult":
            guard let i = constIndex(args[1]) else { return nil }
            let block = LLVMBuildLoad2(b, e.i8ptr, e.gepByte(caseAt(i), LLVMConstInt(e.i64, 16, 0)), "sel.line")!
            let (fn, fty) = EgressBuiltins.lineFromBlockFn(self)
            return e.buildCall(fn, fty, [block])
        case "__selectWait":
            // One operand per case: a channel's buffer, or 0 for a case with no channel.
            var bufs: [(Int, SSAValue)] = []
            for (i, a) in args.dropFirst(2).enumerated() where selectSlots["\(args[0].id):\(i)"] != nil { bufs.append((i, a)) }
            for (i, buf) in bufs {
                store(selectSlots["\(args[0].id):\(i)"]!, caseAt(i), 16)
                store(bufPtr(buf), caseAt(i), 8)
            }
            let (wait, wty) = e.nomuSelectWait()
            let won = e.buildCall(wait, wty, [area, val(args[1])])!
            for (i, buf) in bufs { store(bufPtr(buf), caseAt(i), 8) }
            let (done, dty) = e.nomuSelectDone()
            _ = e.buildCall(done, dty, [area])
            return won
        case "__selectRecvResult":
            guard let i = constIndex(args[1]), let opt = selectOptions["\(args[0].id):\(i)"] else {
                e.fail("select: no receive registered for this case", span); return nil
            }
            let ok = LLVMBuildLoad2(b, e.i64, e.gepByte(caseAt(i), LLVMConstInt(e.i64, 32, 0)), "sel.ok")!
            return selectOptionResult(opt, ok, resultType, span)
        default:
            return nil
        }
    }

    // A zeroed `Option<T>` for a select's receive, and the address of its payload.
    private func selectOption(_ optType: Type, _ span: Span) -> (LLVMValueRef, LLVMValueRef)? {
        let (memset, msty) = e.runtimeFn("memset", ret: e.i8ptr, params: [e.i8ptr, e.i32, e.i64], varArg: false)
        if case .generic(let base, let a) = optType {
            guard let en = e.enumMap[base], let some = en.cases.firstIndex(where: { $0.name == "some" }),
                  let size = erasedTypeSize(optType, span),
                  let off = erasedEnumPayloadOffset(base, a, some, 0, span) else { return nil }
            let opt = e.runtimeSizedBuffer(size, "sel.opt", checked: curChecksStack)
            _ = e.buildCall(memset, msty, [opt, LLVMConstInt(e.i32, 0, 0), size])
            registerErasedComponents(opt, optType, LLVMConstInt(e.i64, 0, 0), span)
            return (opt, e.gepByte(opt, off))
        }
        guard case .named(let n, _) = optType, let et = e.enumType(n), let en = e.enumMap[n],
              let some = en.cases.firstIndex(where: { $0.name == "some" }) else {
            e.fail("select: a receive's result is not an Option", span); return nil
        }
        let slot = e.entryAlloca(et, "sel.opt")
        LLVMBuildStore(b, LLVMConstNull(et), slot)
        return (slot, e.gepByte(slot, const64(e.shapes.enumCaseLayout(n, some).offsets[0])))
    }

    // The `Option<T>` a select's receive filled, its tag set from the case's result.
    private func selectOptionResult(_ opt: LLVMValueRef, _ ok: LLVMValueRef, _ optType: Type, _ span: Span) -> LLVMValueRef? {
        let base: String
        if case .generic(let g, _) = optType { base = g } else if case .named(let n, _) = optType { base = n } else {
            e.fail("select: a receive's result is not an Option", span); return nil
        }
        guard let en = e.enumMap[base], let some = en.cases.firstIndex(where: { $0.name == "some" }),
              let none = en.cases.firstIndex(where: { $0.name == "none" }) else {
            e.fail("select: a receive's result is not an Option", span); return nil
        }
        let layout: DynEnumLayout?
        if case .generic(_, let a) = optType { layout = erasedEnumLayout(en, a, span) } else { layout = namedEnumLayout(base) }
        guard let l = layout else { return nil }
        storeOptionCase(opt, ok, l, some: some, none: none)
        if case .generic = optType { return opt }
        guard let et = e.enumType(base) else { return nil }
        return LLVMBuildLoad2(b, et, opt, "sel.optv")
    }

    // An `Option`'s case: `some` when the runtime moved a value into its payload (`ok` is 1), else `none`, whose
    // payload the runtime left zero.
    private func storeOptionCase(_ opt: LLVMValueRef, _ ok: LLVMValueRef, _ l: DynEnumLayout, some: Int, none: Int) {
        let got = LLVMBuildICmp(b, LLVMIntNE, ok, LLVMConstInt(e.i64, 0, 0), "chan.got")!
        storeEnumCase(opt, l, LLVMBuildSelect(b, got, const64(some), const64(none), "chan.case")!)
    }

    // The value witness for a channel's element: a type parameter's from the dictionary, a generic class's
    // (one managed word), or a concrete type's.
    private func channelWitness(_ t: Type, _ span: Span) -> LLVMValueRef? {
        if case .typeParam(let n) = t {
            guard let w = curVWTParams[n] else { e.fail("channel: no witness for '\(n)'", span); return nil }
            return w
        }
        if case .generic(let base, _) = t, e.classMap[base] != nil { return e.valueWitness(t) }
        if mentionsTypeParam(t) {
            e.fail("a channel of '\(t)' in compiled-once code is not supported yet", span); return nil
        }
        return e.valueWitness(t)
    }

    // A `ManagedBuffer` whose element mentions `T`, in a compiled-once body: the element size comes from the
    // witnesses, and the descriptor from the dictionary, which holds the caller's instantiation's (an `object`
    // need), as `lowerErasedAlloc` does for a generic class. The header is concrete.
    private func lowerErasedManagedBufferAlloc(_ t: Type, header: Type, element: Type, capacity: LLVMValueRef,
                                               _ span: Span) -> LLVMValueRef? {
        guard let dict = curDictionary,
              let i = e.recipes[curFnName]?.needs.firstIndex(of: .object(t)) else {
            e.fail("no descriptor in '\(curFnName)' for '\(t)'", span); return nil
        }
        guard let stride = erasedTypeSize(element, span) else { return nil }
        let elemBytes = LLVMBuildMul(b, capacity, stride, "mb.elembytes")!
        let bytes = LLVMBuildAdd(b, LLVMConstInt(e.i64, UInt64(e.managedBufferElementStart(header: header)), 0), elemBytes, "mb.bytes")!
        let desc = LLVMBuildPtrToInt(b, e.loadDictionaryWord(dict, curDictionaryWords.count + i), e.i64, "desc")!
        let buf = e.rtAllocManaged(bytes)
        LLVMBuildStore(b, desc, buf)
        LLVMBuildStore(b, capacity, e.gepByte(buf, LLVMConstInt(e.i64, 8, 0)))
        return buf
    }

    private func lowerDirectCall(_ name: String, _ args: [SSAValue], typeArgs: [Type] = [], resultType: Type, span: Span) -> LLVMValueRef? {
        switch name {
        case "__channelSend", "__channelReceive", "__channelClose", "__channelFulfill", "__channelAwait":
            return lowerChannelOp(name, args, resultType: resultType, span: span)
        case "__selectBegin", "__selectRecv", "__selectSend", "__selectAfter", "__selectLine", "__selectWait", "__selectRecvResult",
             "__selectLineResult":
            return lowerSelectOp(name, args, typeArgs: typeArgs, resultType: resultType, span: span)
        case "print":    return EgressBuiltins.emitPrint(self, args, span)
        case "putByte":  return EgressBuiltins.emitPutByte(self, args, span)
        case "__stringAllocHeap":
            // task 121.1.3: a `heap` StringBase backed by a fresh `ManagedBuffer<EmptyHeader, UInt8>` of
            // `count` bytes — allocated through the shared `emitManagedBufferAlloc` (the same path as
            // `__managedBufferCreate`), then wrapped into the bit-stealing value: word0 = buffer base,
            // word1 = (heap tag << 60) | count. The bytes are uninitialized; the Nomu `concat` fills them
            // with no safepoint in between.
            let capV = val(args[0])
            let buf = emitManagedBufferAlloc(header: .named("EmptyHeader", .struct_), element: .uint8, capacity: capV)
            let w0 = LLVMBuildPtrToInt(b, buf, e.i64, "sb.w0")!
            let w1 = LLVMBuildOr(b, LLVMConstInt(e.i64, UInt64(2) << 60, 0), capV, "sb.w1")!
            var sb = LLVMGetUndef(e.strTy)
            sb = LLVMBuildInsertValue(b, sb, w0, 0, "sb0")!
            sb = LLVMBuildInsertValue(b, sb, w1, 1, "sb1")!
            return sb
        case "__stringSmallConcat":
            // task 121.2: build a `small` StringBase inline from two sources — the ≤15-byte `concat` result
            // (concat guards `strLen(a) + strLen(b) ≤ 15`). Zero a 16-byte slot (canonical: unused inline bytes
            // are 0), copy both sources to offsets 0 and `an`, set byte 15 = count (small tag 0 in the top
            // nibble, count in the low), and load the value back once — no mutate-then-reload of an SSA value.
            let sa = val(args[0]), sb2 = val(args[1])
            let an = strLen(sa), bn = strLen(sb2)
            let pa = strPtr(sa), pb = strPtr(sb2)
            let slot = e.entryAlloca(e.strTy, "small.build")
            LLVMBuildStore(b, LLVMConstNull(e.strTy), slot)
            let slot8 = LLVMBuildBitCast(b, slot, e.i8ptr, "small.slot8")!
            let (memcpy, mty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
            _ = e.buildCall(memcpy, mty, [slot8, pa, an])
            _ = e.buildCall(memcpy, mty, [e.gepByte(slot8, an), pb, bn])
            let n = LLVMBuildAdd(b, an, bn, "small.n")!
            LLVMBuildStore(b, LLVMBuildTrunc(b, n, e.i8, "small.b15")!,
                           e.gepByte(slot8, LLVMConstInt(e.i64, 15, 0)))
            return LLVMBuildLoad2(b, e.strTy, slot, "small.val")
        case "__string_count_int":          return strLen(val(args[0]))      // StringBase byte count (task 121)
        case "__string_bytepointer_rawptr": return strPtr(val(args[0]))      // StringBase tag-aware byte address
        case "sleep":    return EgressBuiltins.emitSleep(self, args, span)
        case "readLine": return EgressBuiltins.emitReadLine(self)
        case "__array_count_int": return LLVMBuildLoad2(b, e.i64, e.gepByte(val(args[0]), LLVMConstInt(e.i64, 8, 0)), "arr.count")
        case "__arraySet":    return EgressArrays.emitArraySet(self, args, span)
        case "__arrayAppend": return EgressArrays.emitArrayAppend(self, args, span)
        // Unsafe raw memory (task 125). RawPtr / Ptr<T> are addrspace(0) i8ptr words; load/store/advance
        // are plain addrspace(0) memory ops (no barrier, never a GC root); alloc is `__nomu_raw_alloc` and free
        // is libc's `free`.
        case "__rawAlloc":
            let (fn, fty) = e.nomuRawAlloc()
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        case "__rawFree":
            let (fn, fty) = e.runtimeFn("free", ret: e.voidTy, params: [e.i8ptr], varArg: false)
            return e.buildCall(fn, fty, [val(args[0])])
        case "__rawAdvanced":
            return e.gepByte(val(args[0]), val(args[1]))
        case "__rawStore":
            LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), val(args[2])))
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawZeroBytes":
            // memset(self, 0, n) — bulk-zero a reused heap hole (task 150.4.5.1).
            let (mfn, mfty) = e.runtimeFn("memset", ret: e.i8ptr, params: [e.i8ptr, e.i32, e.i64], varArg: false)
            let z = LLVMBuildTrunc(b, LLVMConstInt(e.i64, 0, 0), e.i32, "zero.byte")
            _ = e.buildCall(mfn, mfty, [val(args[0]), z, val(args[1])])
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawCopyBytes":
            // memcpy(self, from, n) — copy a raw byte range (grow the minor promotion queue). Non-overlapping.
            let (cfn, cfty) = e.runtimeFn("memcpy", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
            _ = e.buildCall(cfn, cfty, [val(args[0]), val(args[1]), val(args[2])])
            return LLVMConstInt(e.i64, 0, 0)
        case "__rawCompareBytes":
            // memcmp(self, with, n), widened to `Int` — compare two raw byte ranges in one gc-leaf call.
            let (cfn, cfty) = e.runtimeFn("memcmp", ret: e.i32, params: [e.i8ptr, e.i8ptr, e.i64], varArg: false)
            let r = e.buildCall(cfn, cfty, [val(args[0]), val(args[1]), val(args[2])])!
            return LLVMBuildSExt(b, r, e.i64, "raw.cmp")
        case "__rawLoad":
            guard let lt = ty(resultType, span) else { return nil }
            return LLVMBuildLoad2(b, lt, e.gepByte(val(args[0]), val(args[1])), "raw.load")
        // Atomics (task 128.1.1, scheduler substrate). Seq-cst ops on an i64 or pointer word over an
        // addrspace(0) RawPtr slot — pure LLVM instructions, no OS/asm. The primitive under the MT-safe run
        // queue, STW flags, and futex words. gc-leaf: no barrier, never a GC root. The fixture keeps offsets
        // 8-aligned. A pointer word stays a pointer (task 263); the store, swap and exchange take the type of
        // their operands.
        case "__atomicLoad":
            guard let wt = ty(resultType, span) else { return nil }
            let ld = LLVMBuildLoad2(b, wt, e.gepByte(val(args[0]), val(args[1])), "atomic.load")
            LLVMSetOrdering(ld, LLVMAtomicOrderingSequentiallyConsistent)
            LLVMSetAlignment(ld, 8)
            return ld
        case "__atomicStore":
            let st = LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), val(args[2])))
            LLVMSetOrdering(st, LLVMAtomicOrderingSequentiallyConsistent)
            LLVMSetAlignment(st, 8)
            return LLVMConstInt(e.i64, 0, 0)
        case "__atomicCas":
            // cmpxchg yields { old, i1 success }; return the old word (caller compares to `expected`).
            let cx = LLVMBuildAtomicCmpXchg(b, e.gepByte(val(args[0]), val(args[3])),
                                            val(args[1]), val(args[2]),
                                            LLVMAtomicOrderingSequentiallyConsistent,
                                            LLVMAtomicOrderingSequentiallyConsistent, 0)
            return LLVMBuildExtractValue(b, cx, 0, "atomic.cas.old")
        case "__atomicFetchAdd":
            return LLVMBuildAtomicRMW(b, LLVMAtomicRMWBinOpAdd, e.gepByte(val(args[0]), val(args[2])),
                                      val(args[1]), LLVMAtomicOrderingSequentiallyConsistent, 0)
        case "__atomicExchange":
            // atomicrmw xchg: swap the word for `value`, yield the previous word. The futex-mutex xchg.
            return LLVMBuildAtomicRMW(b, LLVMAtomicRMWBinOpXchg, e.gepByte(val(args[0]), val(args[2])),
                                      val(args[1]), LLVMAtomicOrderingSequentiallyConsistent, 0)
        // Raw OS clock (task 128.1.1, scheduler substrate). Monotonic nanoseconds straight from the OS —
        // on macOS the libSystem entry `uint64_t clock_gettime_nsec_np(clockid_t)` (the stable Darwin
        // floor, selfhosted-scheduler.md §3.3), no C-runtime shim. `CLOCK_MONOTONIC` is 6 on Darwin. The
        // Linux lowering (raw `clock_gettime`/vDSO) lands with the Linux build target (§5).
        case "__sysWallNanos":
            let (fn, fty) = e.runtimeFn("clock_gettime_nsec_np", ret: e.i64, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])   // CLOCK_REALTIME
        case "__sysTimebase":
            let (fn, fty) = e.runtimeFn("mach_timebase_info", ret: e.i32, params: [e.i8ptr], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [val(args[0])])!, e.i64, "timebase.r")
        case "__sysGetenv":
            let (fn, fty) = e.runtimeFn("getenv", ret: e.i8ptr, params: [e.i8ptr], varArg: false)
            return e.buildCall(fn, fty, [val(args[0])])
        case "__sysExecutablePath":
            let (fn, fty) = e.runtimeFn("_NSGetExecutablePath", ret: e.i32, params: [e.i8ptr, e.i8ptr], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [val(args[0]), val(args[1])])!, e.i64, "exepath.r")
        case "__sysCreat":
            // int creat(const char* path, mode_t mode); mode_t is 16 bits on Darwin.
            let i16 = LLVMInt16TypeInContext(e.ctx)!
            let (fn, fty) = e.runtimeFn("creat", ret: e.i32, params: [e.i8ptr, i16], varArg: false)
            let mode = LLVMBuildTrunc(b, val(args[1]), i16, "creat.mode")
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [val(args[0]), mode])!, e.i64, "creat.r")
        case "__sysClose":
            let (fn, fty) = e.runtimeFn("close", ret: e.i32, params: [e.i32], varArg: false)
            let cfd = LLVMBuildTrunc(b, val(args[0]), e.i32, "close.fd")
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [cfd])!, e.i64, "close.r")
        case "__sysCopyLiteral":
            let text = val(args[1])
            let n = strLen(text)
            LLVMBuildMemCpy(b, val(args[0]), 1, strPtr(text), 1, n)
            return n
        case "__sysTicks":
            let (fn, fty) = e.runtimeFn("mach_absolute_time", ret: e.i64, params: [], varArg: false)
            return e.buildCall(fn, fty, [])
        case "__sysMonotonicNanos":
            let (fn, fty) = e.runtimeFn("clock_gettime_nsec_np", ret: e.i64, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 6, 0)])
        // The carrier-local slot: one thread-specific word read and written in place, no call.
        // A zeroed reservation, pages committed on first touch (the collector's heap and side tables).
        case "__sysReserveZeroed":
            let (fn, fty) = e.nomuReserveZeroed()
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        // The machine's physical memory: `hw.memsize` through `sysctlbyname` on darwin, pages times page size
        // through `sysconf` on Linux; 0 when the call fails.
        case "__sysPhysicalMemory":
            let i32 = e.i32
            switch TargetPlatform.host.os {
            case .darwin:
                let value = e.entryAlloca(e.i64, "memsize")
                let len = e.entryAlloca(e.i64, "memsize.len")
                LLVMBuildStore(b, LLVMConstInt(e.i64, 0, 0), value)
                LLVMBuildStore(b, LLVMConstInt(e.i64, 8, 0), len)
                let name = LLVMBuildGlobalStringPtr(b, "hw.memsize", "memsize.name")!
                let (fn, fty) = e.runtimeFn("sysctlbyname", ret: i32,
                                            params: [e.i8ptr, e.i8ptr, e.i8ptr, e.i8ptr, e.i64], varArg: false)
                let rc = e.buildCall(fn, fty, [name, value, len, LLVMConstNull(e.i8ptr), LLVMConstInt(e.i64, 0, 0)])!
                let ok = LLVMBuildICmp(b, LLVMIntEQ, rc, LLVMConstInt(i32, 0, 0), "memsize.ok")
                let v = LLVMBuildLoad2(b, e.i64, value, "memsize.v")!
                return LLVMBuildSelect(b, ok, v, LLVMConstInt(e.i64, 0, 0), "physmem")
            case .linux:
                // _SC_PHYS_PAGES 85, _SC_PAGESIZE 30; -1 on failure.
                let (fn, fty) = e.runtimeFn("sysconf", ret: e.i64, params: [i32], varArg: false)
                let pages = e.buildCall(fn, fty, [LLVMConstInt(i32, 85, 0)])!
                let size = e.buildCall(fn, fty, [LLVMConstInt(i32, 30, 0)])!
                let ok = LLVMBuildAnd(b, LLVMBuildICmp(b, LLVMIntSGT, pages, LLVMConstInt(e.i64, 0, 0), "pages.ok"),
                                      LLVMBuildICmp(b, LLVMIntSGT, size, LLVMConstInt(e.i64, 0, 0), "size.ok"), "physmem.ok")
                return LLVMBuildSelect(b, ok, LLVMBuildMul(b, pages, size, "physmem.v"), LLVMConstInt(e.i64, 0, 0), "physmem")
            }
        // Unmanaged memory without the zero-fill (a fiber stack a move copies into).
        case "__sysAllocUninitialized":
            let (fn, fty) = e.nomuRawAlloc(zeroed: false)
            return e.buildCall(fn, fty, [val(args[0]), val(args[1])])
        case "__sysCarrierLocal":
            return e.emitCarrierLocalGet()
        case "__sysSetCarrierLocal":
            e.emitCarrierLocalSet(val(args[0]))
            return LLVMConstInt(e.i64, 0, 0)
        // I/O poller substrate (task 128.1.7): the macOS kqueue floor + pipe/read/write, bound as libSystem
        // externs (selfhosted-scheduler.md §3.3). fd numbers and counts are i32 at the C boundary; buffers
        // are raw i8ptr. Results are sign-extended back to i64.
        case "__sysKqueue":
            let (fn, fty) = e.runtimeFn("kqueue", ret: e.i32, params: [], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [])!, e.i64, "kqueue.r")
        case "__sysKevent":
            // int kevent(int kq, const struct kevent* changes, int nchanges, struct kevent* events,
            //            int nevents, const struct timespec* timeout) — timeout NULL = block.
            let (fn, fty) = e.runtimeFn("kevent", ret: e.i32,
                                        params: [e.i32, e.i8ptr, e.i32, e.i8ptr, e.i32, e.i8ptr], varArg: false)
            let kq = LLVMBuildTrunc(b, val(args[0]), e.i32, "kq")
            let nch = LLVMBuildTrunc(b, val(args[2]), e.i32, "nch")
            let nev = LLVMBuildTrunc(b, val(args[4]), e.i32, "nev")
            let r = e.buildCall(fn, fty, [kq, val(args[1]), nch, val(args[3]), nev, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "kevent.r")
        case "__sysPipe":
            let (fn, fty) = e.runtimeFn("pipe", ret: e.i32, params: [e.i8ptr], varArg: false)
            return LLVMBuildSExt(b, e.buildCall(fn, fty, [val(args[0])])!, e.i64, "pipe.r")
        case "__sysWrite":
            // ssize_t write(int fd, const void* buf, size_t count)
            let (fn, fty) = e.runtimeFn("write", ret: e.i64, params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let wfd = LLVMBuildTrunc(b, val(args[0]), e.i32, "wfd")
            return e.buildCall(fn, fty, [wfd, val(args[1]), val(args[2])])
        case "__sysRead":
            // ssize_t read(int fd, void* buf, size_t count)
            let (fn, fty) = e.runtimeFn("read", ret: e.i64, params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let rfd = LLVMBuildTrunc(b, val(args[0]), e.i32, "rfd")
            return e.buildCall(fn, fty, [rfd, val(args[1]), val(args[2])])
        case "__sysPoll":
            // int poll(struct pollfd* fds, nfds_t n, int timeout) over one `{ int fd; short events; short
            // revents; }` asking POLLIN (1), timeout 0 so it never blocks. 1 when ready, else 0.
            let i16 = LLVMInt16TypeInContext(ctx)!
            let pollfdTy = e.structTy([e.i32, i16, i16])
            let slot = e.entryAlloca(pollfdTy, "pollfd")
            LLVMBuildStore(b, LLVMBuildTrunc(b, val(args[0]), e.i32, "pfd"), e.structGEP(pollfdTy, slot, 0))
            LLVMBuildStore(b, LLVMConstInt(i16, 1, 0), e.structGEP(pollfdTy, slot, 1))
            LLVMBuildStore(b, LLVMConstInt(i16, 0, 0), e.structGEP(pollfdTy, slot, 2))
            let (fn, fty) = e.runtimeFn("poll", ret: e.i32, params: [e.i8ptr, e.i32, e.i32], varArg: false)
            let r = e.buildCall(fn, fty, [slot, LLVMConstInt(e.i32, 1, 0), LLVMConstInt(e.i32, 0, 0)])!
            let ready = LLVMBuildICmp(b, LLVMIntSGT, r, LLVMConstInt(e.i32, 0, 0), "poll.ready")
            return LLVMBuildZExt(b, ready, e.i64, "poll.r")
        // Fault handling (task 219). The Darwin layouts: `struct sigaction` is { handler ptr @0, sa_mask u32 @8,
        // sa_flags i32 @12 } (16 bytes); `stack_t` is { ss_sp ptr @0, ss_size u64 @8, ss_flags i32 @16 }
        // (24 bytes), where SS_DISABLE is 4. Linux differs in both (task 218).
        case "__sysSigaction":
            let i32 = e.i32
            let saTy = e.structTy([e.i8ptr, i32, i32])
            let sa = e.entryAlloca(saTy, "sigaction")
            LLVMBuildStore(b, val(args[1]), e.structGEP(saTy, sa, 0))
            LLVMBuildStore(b, LLVMConstInt(i32, 0, 0), e.structGEP(saTy, sa, 1))
            LLVMBuildStore(b, LLVMBuildTrunc(b, val(args[2]), i32, "sa.flags"), e.structGEP(saTy, sa, 2))
            let (fn, fty) = e.runtimeFn("sigaction", ret: i32, params: [i32, e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [LLVMBuildTrunc(b, val(args[0]), i32, "sig"), sa, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "sigaction.r")
        case "__sysSigaltstack":
            let i32 = e.i32
            let ssTy = e.structTy([e.i8ptr, e.i64, i32])
            let ss = e.entryAlloca(ssTy, "stack_t")
            LLVMBuildStore(b, val(args[0]), e.structGEP(ssTy, ss, 0))
            LLVMBuildStore(b, val(args[1]), e.structGEP(ssTy, ss, 1))
            LLVMBuildStore(b, LLVMConstInt(i32, 0, 0), e.structGEP(ssTy, ss, 2))
            let (fn, fty) = e.runtimeFn("sigaltstack", ret: i32, params: [e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [ss, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "sigaltstack.r")
        case "__sysUnblockSignal":
            // Darwin's `sigset_t` is a 32-bit mask with signal n at bit n − 1; SIG_UNBLOCK is 2.
            let i32 = e.i32
            let set = e.entryAlloca(i32, "sigset")
            let sig = LLVMBuildTrunc(b, val(args[0]), i32, "sig")!
            let bit = LLVMBuildShl(b, LLVMConstInt(i32, 1, 0), LLVMBuildSub(b, sig, LLVMConstInt(i32, 1, 0), "sig.b")!, "sig.bit")!
            LLVMBuildStore(b, bit, set)
            let (fn, fty) = e.runtimeFn("pthread_sigmask", ret: i32, params: [i32, e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [LLVMConstInt(i32, 2, 0), set, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "sigmask.r")
        case "__sysCurrentAltStack":
            // sigaltstack(NULL, &old): the base when a stack is set and enabled, else null.
            let i32 = e.i32
            let ssTy = e.structTy([e.i8ptr, e.i64, i32])
            let old = e.entryAlloca(ssTy, "stack_t.old")
            LLVMBuildStore(b, LLVMConstNull(e.i8ptr), e.structGEP(ssTy, old, 0))
            LLVMBuildStore(b, LLVMConstInt(i32, 4, 0), e.structGEP(ssTy, old, 2))
            let (fn, fty) = e.runtimeFn("sigaltstack", ret: i32, params: [e.i8ptr, e.i8ptr], varArg: false)
            _ = e.buildCall(fn, fty, [LLVMConstNull(e.i8ptr), old])
            let base = LLVMBuildLoad2(b, e.i8ptr, e.structGEP(ssTy, old, 0), "ss.sp")!
            let flags = LLVMBuildLoad2(b, i32, e.structGEP(ssTy, old, 2), "ss.flags")!
            let off = LLVMBuildICmp(b, LLVMIntNE, LLVMBuildAnd(b, flags, LLVMConstInt(i32, 4, 0), "ss.dis"),
                                    LLVMConstInt(i32, 0, 0), "ss.off")
            return LLVMBuildSelect(b, off, LLVMConstNull(e.i8ptr), base, "altstack")
        case "__sysImageHeader":
            // The linker's `__mh_execute_header`: the executable's Mach-O header, its load address.
            let g = e.getOrAddGlobal(LLVMInt8TypeInContext(e.ctx)!, "_mh_execute_header")
            return g
        case "__sysProtect":
            let i32 = e.i32
            let (fn, fty) = e.runtimeFn("mprotect", ret: i32, params: [e.i8ptr, e.i64, i32], varArg: false)
            let r = e.buildCall(fn, fty, [val(args[0]), val(args[1]), LLVMBuildTrunc(b, val(args[2]), i32, "prot")])
            return LLVMBuildSExt(b, r!, e.i64, "mprotect.r")
        case "__sysRaise":
            let i32 = e.i32
            let (fn, fty) = e.runtimeFn("raise", ret: i32, params: [i32], varArg: false)
            let r = e.buildCall(fn, fty, [LLVMBuildTrunc(b, val(args[0]), i32, "sig")])
            return LLVMBuildSExt(b, r!, e.i64, "raise.r")
        // Asm-floor context switch (task 128.2): rtSwitch(from, to, message), returning the message the switch
        // that resumes this context passes.
        case "__sysCtxSwitch":
            let (fn, fty) = e.runtimeFn("rtSwitch", ret: e.i8ptr, params: [e.i8ptr, e.i8ptr, e.i8ptr], varArg: false)
            // An Int message is a number in the register, never dereferenced: the asm boundary is the one place
            // it is given a pointer's type.
            var message = val(args[2])
            if LLVMGetTypeKind(LLVMTypeOf(message)) == LLVMIntegerTypeKind {
                message = LLVMBuildIntToPtr(b, message, e.i8ptr, "switch.message")!
            }
            return e.buildCall(fn, fty, [val(args[0]), val(args[1]), message])!
        case "__sysFiberInit":
            let (fn, fty) = e.runtimeFn("rtFiberInit", ret: e.voidTy,
                                        params: [e.i8ptr, e.i8ptr, e.i8ptr, e.i8ptr], varArg: false)
            _ = e.buildCall(fn, fty, [val(args[0]), val(args[1]), val(args[2]), val(args[3])])
            return LLVMConstInt(e.i64, 0, 0)
        // Carrier thread create (task 128.2): pthread_create(handle, NULL, entry, arg). `entry` is a
        // (RawPtr)->RawPtr Nomu function address, ABI-identical to void*(*)(void*).
        // The thread starts in `rtThreadStart` (the asm floor), which clears x28 and calls entry(arg) from a
        // malloc'd { entry, arg } record it frees.
        case "__sysThreadCreate":
            let (fn, fty) = e.runtimeFn("pthread_create", ret: e.i32,
                                        params: [e.i8ptr, e.i8ptr, e.i8ptr, e.i8ptr], varArg: false)
            let (mfn, mty) = e.runtimeFn("malloc", ret: e.i8ptr, params: [e.i64], varArg: false)
            let rec = e.buildCall(mfn, mty, [LLVMConstInt(e.i64, 16, 0)])!
            LLVMBuildStore(b, val(args[1]), rec)
            LLVMBuildStore(b, val(args[2]), e.gepByte(rec, LLVMConstInt(e.i64, 8, 0)))
            let start = e.runtimeFn("rtThreadStart", ret: e.i8ptr, params: [e.i8ptr], varArg: false).0
            let r = e.buildCall(fn, fty, [val(args[0]), LLVMConstNull(e.i8ptr), start, rec])
            return LLVMBuildSExt(b, r!, e.i64, "thread.create.r")
        case "__sysExit":
            let (fn, fty) = e.runtimeFn("exit", ret: e.voidTy, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMBuildTrunc(b, val(args[0]), e.i32, "exit.code")])
        case "__sysThreadJoin":
            // pthread_join(pthread_t, NULL); the handle (a pointer-sized pthread_t) is loaded from the slot.
            let t = LLVMBuildLoad2(b, e.i8ptr, val(args[0]), "pthread.t")
            let (fn, fty) = e.runtimeFn("pthread_join", ret: e.i32, params: [e.i8ptr, e.i8ptr], varArg: false)
            let r = e.buildCall(fn, fty, [t!, LLVMConstNull(e.i8ptr)])
            return LLVMBuildSExt(b, r!, e.i64, "thread.join.r")
        // Indirect call through a RawPtr code address with the fiber-entry ABI i8ptr(i8ptr) (task 128.1.3).
        case "__sysCallEntry":
            return e.buildCall(val(args[0]), e.fnType(e.i8ptr, [e.i8ptr]), [val(args[1])])
        // Futex (task 128.1.1, scheduler substrate). macOS __ulock_wait / __ulock_wake — the libSystem
        // futex floor (selfhosted-scheduler.md §3.3), no C-runtime shim. Operation bits (private XNU ABI):
        // UL_COMPARE_AND_WAIT = 1; ULF_NO_ERRNO = 0x01000000 returns the negated errno rather than setting
        // the thread-local errno (so the primitive stays subset-friendly, no libc errno slot); ULF_WAKE_ALL
        // = 0x100 wakes every waiter (STW broadcast) instead of one (lock handoff).
        case "__sysFutexWait":
            // int __ulock_wait(uint32 operation, void* addr, uint64 value, uint32 timeout_us)
            let (wf, wt) = e.runtimeFn("__ulock_wait", ret: e.i32,
                                       params: [e.i32, e.i8ptr, e.i64, e.i32], varArg: false)
            let op = LLVMConstInt(e.i32, 0x0100_0001, 0)
            let tmo = LLVMBuildTrunc(b, val(args[2]), e.i32, "futex.tmo")
            let r = e.buildCall(wf, wt, [op, val(args[0]), val(args[1]), tmo])
            return LLVMBuildSExt(b, r!, e.i64, "futex.wait.r")
        case "__sysFutexWake":
            // int __ulock_wake(uint32 operation, void* addr, uint64 wake_value)
            let (kf, kt) = e.runtimeFn("__ulock_wake", ret: e.i32,
                                       params: [e.i32, e.i8ptr, e.i64], varArg: false)
            let oneOp = LLVMConstInt(e.i32, 0x0100_0001, 0)
            let allOp = LLVMConstInt(e.i32, 0x0100_0001 | 0x100, 0)
            let op = LLVMBuildSelect(b, val(args[1]), allOp, oneOp, "futex.wake.op")
            let r = e.buildCall(kf, kt, [op, val(args[0]), LLVMConstInt(e.i64, 0, 0)])
            return LLVMBuildSExt(b, r!, e.i64, "futex.wake.r")
        // Ptr<T>: typed element access at the natural stride of T (index-scaled, C-style packed).
        case "__ptrAlloc":
            guard case .ptr(let elem) = resultType else { e.fail("125: __ptrAlloc result not Ptr<T>", span); return nil }
            let strideV = LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0)
            let bytes = LLVMBuildMul(b, val(args[0]), strideV, "ptr.bytes")!
            let (fn, fty) = e.nomuRawAlloc()
            return e.buildCall(fn, fty, [bytes, LLVMConstInt(e.i64, UInt64(e.shapes.align(elem)), 0)])
        case "__ptrStore":
            let off = LLVMBuildMul(b, val(args[2]), LLVMConstInt(e.i64, UInt64(e.rawStride(args[1].type)), 0), "ptr.off")!
            LLVMBuildStore(b, val(args[1]), e.gepByte(val(args[0]), off))
            return LLVMConstInt(e.i64, 0, 0)
        case "__ptrLoad":
            guard let lt = ty(resultType, span) else { return nil }
            let off = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(resultType)), 0), "ptr.off")!
            return LLVMBuildLoad2(b, lt, e.gepByte(val(args[0]), off), "ptr.load")
        case "__ptrAdvanced":
            guard case .ptr(let elem) = resultType else { e.fail("125: __ptrAdvanced result not Ptr<T>", span); return nil }
            let off = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "ptr.adv")!
            return e.gepByte(val(args[0]), off)
        case "__ptrAsRaw", "__rawAsPtr":
            return val(args[0])   // no-op reinterpret — both are one addrspace(0) word
        case "__ptrNull":
            return LLVMConstPointerNull(e.i8ptr)
        case "__staticStorage":
            return staticStorageBlock(args, span)
        case "__ptrIsNull":
            return LLVMBuildICmp(b, LLVMIntEQ, val(args[0]), LLVMConstPointerNull(e.i8ptr), "ptr.isnull")
        case "__ptrEq":
            return LLVMBuildICmp(b, LLVMIntEQ, val(args[0]), val(args[1]), "ptr.eq")
        case "__rawToInt":
            // A RawPtr (addrspace(0)) → its numeric address as an Int (ptrtoint). Sound on raw memory (the
            // Immix heap + side tables are addrspace(0)); the collector uses it for addr→index math (150.3.1).
            return LLVMBuildPtrToInt(b, val(args[0]), e.i64, "raw.toint")
        // GC type-table reads (task 150 rung 2): reach the codegen-emitted per-type-id side tables from
        // Nomu through the existing runtime accessors (`c-types.md` §1/§3.2). Pure gc-leaf reads.
        case "__gcObjAddr":
            // A managed object (addrspace(1) p1) → its raw address as a RawPtr (addrspace(0)), recorded with
            // the object as its base (`rawInterior`), so a moving collection updates it.
            let a = e.managedAddress(val(args[0]))
            return e.rawInterior(a, LLVMConstInt(e.i64, 0, 0), "obj.raw")
        case "__gcStackmapBase", "__gcStackmapSize":
            // The linker synthesizes `section$start$<seg>$<sect>` / `section$end$…` symbols whose addresses
            // bracket the section — the libc-free way to reach `__llvm_stackmaps` from generated code. The
            // `\u{01}` prefix suppresses LLVM's automatic `_` Mach-O mangling so the literal ld64 name is used.
            let startName = "\u{01}section$start$__LLVM_STACKMAPS$__llvm_stackmaps"
            let endName = "\u{01}section$end$__LLVM_STACKMAPS$__llvm_stackmaps"
            let start = LLVMGetNamedGlobal(e.mod, startName) ?? LLVMAddGlobal(e.mod, e.i8ptr, startName)
            if name == "__gcStackmapBase" { return start }
            let end = LLVMGetNamedGlobal(e.mod, endName) ?? LLVMAddGlobal(e.mod, e.i8ptr, endName)
            let sb = LLVMBuildPtrToInt(b, start, e.i64, "sm.b")!
            let se = LLVMBuildPtrToInt(b, end, e.i64, "sm.e")!
            return LLVMBuildSub(b, se, sb, "sm.size")
        case "__gcFrameIndexBase":
            // The GC frame index section's start, through its linker section-bracket symbol, as for
            // `__gcStackmapBase` (the driver always creates the section).
            let name = "\u{01}section$start$__DATA_CONST$__nomu_frameidx"
            return LLVMGetNamedGlobal(e.mod, name) ?? LLVMAddGlobal(e.mod, e.i8ptr, name)
        case "__gcFrameAddr":
            let (fn, fty) = e.runtimeFn("llvm.frameaddress.p0", ret: e.i8ptr, params: [e.i32], varArg: false)
            return e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])
        case "__gcReturnAddr":
            let (fn, fty) = e.runtimeFn("llvm.returnaddress.p0", ret: e.i8ptr, params: [e.i32], varArg: false)
            let ra = e.buildCall(fn, fty, [LLVMConstInt(e.i32, 0, 0)])!
            return LLVMBuildPtrToInt(b, ra, e.i64, "retaddr")
        case "__gcTypeCount", "__gcDescBase":
            // The descriptor section (`__DATA,__nomu_descs`), through its linker section-bracket symbols as for
            // `__gcStackmapBase`: its start, or its record count (byte size / the 32-byte record). A type-id is
            // a record's byte offset from the start.
            let startName = "\u{01}section$start$__DATA$__nomu_descs"
            let start = LLVMGetNamedGlobal(e.mod, startName) ?? LLVMAddGlobal(e.mod, e.i8ptr, startName)
            if name == "__gcDescBase" { return start }
            let endName = "\u{01}section$end$__DATA$__nomu_descs"
            let end = LLVMGetNamedGlobal(e.mod, endName) ?? LLVMAddGlobal(e.mod, e.i8ptr, endName)
            let bytes = LLVMBuildSub(b, LLVMBuildPtrToInt(b, end, e.i64, "desc.e")!,
                                     LLVMBuildPtrToInt(b, start, e.i64, "desc.b")!, "desc.bytes")!
            return LLVMBuildUDiv(b, bytes, LLVMConstInt(e.i64, 32, 0), "desc.count")
        case "__gcPtrmapBase":
            // The pointer-map section (`__DATA,__nomu_ptrmaps`): each descriptor's `ptrmapOff` indexes it.
            let name = "\u{01}section$start$__DATA$__nomu_ptrmaps"
            return LLVMGetNamedGlobal(e.mod, name) ?? LLVMAddGlobal(e.mod, e.i8ptr, name)
        case "__rawLoadInt32":
            let v = LLVMBuildLoad2(b, e.i32, e.gepByte(val(args[0]), val(args[1])), "ld32")!
            LLVMSetAlignment(v, 4)
            return LLVMBuildSExt(b, v, e.i64, "ld32.x")
        case "__sysFatal":
            // write(2, text, len); abort(). Both gc-leaf libc calls.
            let text = val(args[0])
            let (wfn, wty) = e.runtimeFn("write", ret: e.i64, params: [e.i32, e.i8ptr, e.i64], varArg: false)
            _ = e.buildCall(wfn, wty, [LLVMConstInt(e.i32, 2, 0), strPtr(text), strLen(text)])
            let (afn, aty) = e.runtimeFn("abort", ret: e.voidTy, params: [], varArg: false)
            return e.buildCall(afn, aty, [])
        case "__managedBufferCreate":
            // task 180: tail-alloc `{ type-id, cap, Header, Element[cap] }`. `Header`/`Element` come from the
            // result's ManagedBuffer type. The returned `p1` is the ManagedBuffer reference (same
            // representation as any class), rooted via the shared `emitManagedBufferAlloc`.
            if case .generic(_, let a) = resultType, a.count == 2 {
                return lowerErasedManagedBufferAlloc(resultType, header: a[0], element: a[1], capacity: val(args[0]), span)
            }
            guard let (hdr, elem) = e.managedBufferArgs(resultType) else {
                e.fail("180: __managedBufferCreate result is not a ManagedBuffer", span); return nil
            }
            return emitManagedBufferAlloc(header: hdr, element: elem, capacity: val(args[0]))
        case "__managedBufferCapacity":
            // The allocated element count, stored at byte 8 by `create`.
            return LLVMBuildLoad2(b, e.i64, e.gepByte(val(args[0]), LLVMConstInt(e.i64, 8, 0)), "mb.cap")
        case "__managedBufferHeaderPtr":
            // The header region as a raw addrspace(0) address (`base + 16`), an interior pointer recorded
            // with the buffer as its base (`rawInterior`), so it stays valid when the buffer moves.
            let baseH = e.managedAddress(val(args[0]))
            return e.rawInterior(baseH, LLVMConstInt(e.i64, 16, 0), "mb.hdr.raw")
        case "__managedBufferElementPtr":
            // Element `i` at `base + 16 + headerSize + i*stride`, as a raw addrspace(0) interior pointer, like
            // the header pointer.
            guard let (hdr, elem) = e.managedBufferArgs(args[0].type) else {
                e.fail("180: __managedBufferElementPtr receiver is not a ManagedBuffer", span); return nil
            }
            let elemStart = e.managedBufferElementStart(header: hdr)
            let baseE = e.managedAddress(val(args[0]))
            let ix = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "mb.ix")!
            let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, UInt64(elemStart), 0), ix, "mb.eoff")!
            return e.rawInterior(baseE, off, "mb.elem.raw")
        case "__managedBufferStoreRef":
            // task 180: store a managed reference into element slot `i` through the write-barrier / `p1`
            // path (not a raw store), so the collector records the edge. The slot stays an addrspace(1)
            // pointer (a gepByte off the buffer `p1`), which is what `storeField` routes through the barrier.
            guard let (hdr, elem) = e.managedBufferArgs(args[0].type) else {
                e.fail("180: __managedBufferStoreRef receiver is not a ManagedBuffer", span); return nil
            }
            let recvV = val(args[0])
            let elemStart = e.managedBufferElementStart(header: hdr)
            let ix = LLVMBuildMul(b, val(args[2]), LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "mb.ix")!
            let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, UInt64(elemStart), 0), ix, "mb.eoff")!
            e.storeField(recvV, e.gepByte(recvV, off), val(args[1]))
            return LLVMConstInt(e.i64, 0, 0)
        case "__managedBufferRef":
            // Load the managed reference at element slot `i` as a `p1` (same reload-before-safepoint
            // discipline as the raw accessors: the buffer can relocate).
            guard let (hdr, elem) = e.managedBufferArgs(args[0].type) else {
                e.fail("180: __managedBufferRef receiver is not a ManagedBuffer", span); return nil
            }
            let recvV = val(args[0])
            let elemStart = e.managedBufferElementStart(header: hdr)
            let ix = LLVMBuildMul(b, val(args[1]), LLVMConstInt(e.i64, UInt64(e.rawStride(elem)), 0), "mb.ix")!
            let off = LLVMBuildAdd(b, LLVMConstInt(e.i64, UInt64(elemStart), 0), ix, "mb.eoff")!
            return LLVMBuildLoad2(b, e.p1, e.gepByte(recvV, off), "mb.ref")
        case "__managedBufferStoreHeaderRef":
            // Store a managed reference into the header region (`base + 16`) through the barrier.
            let recvV = val(args[0])
            e.storeField(recvV, e.gepByte(recvV, LLVMConstInt(e.i64, 16, 0)), val(args[1]))
            return LLVMConstInt(e.i64, 0, 0)
        case "__managedBufferHeaderRef":
            // Load the managed reference stored in the header region as a `p1`.
            let recvV = val(args[0])
            return LLVMBuildLoad2(b, e.p1, e.gepByte(recvV, LLVMConstInt(e.i64, 16, 0)), "mb.href")
        case "__int_double_double": return LLVMBuildSIToFP(b, val(args[0]), e.f64, "i2d")
        case "__double_int_int":
            let (fn, fty) = e.runtimeFn("llvm.round.f64", ret: e.f64, params: [e.f64], varArg: false)
            let rounded = e.buildCall(fn, fty, [val(args[0])])!
            return LLVMBuildFPToSI(b, rounded, e.i64, "d2i")
        case "__int_uint8_uint8": return LLVMBuildTrunc(b, val(args[0]), e.i8, "i2u8")
        case "__uint8_int_int":   return LLVMBuildZExt(b, val(args[0]), e.i64, "u82i")
        // UInt64 conversions: Int↔UInt64 share the i64 representation (no-op reinterpret); UInt8→UInt64
        // zero-extends, UInt64→UInt8 truncates to the low byte.
        case "__int_uint64_uint64":     return val(args[0])
        case "__uint64_int_int":        return val(args[0])
        case "__uint8_uint64_uint64":   return LLVMBuildZExt(b, val(args[0]), e.i64, "u82u64")
        case "__uint64_uint8_uint8":    return LLVMBuildTrunc(b, val(args[0]), e.i8, "u642u8")
        case "__void_timemonotonic_int": return EgressBuiltins.emitTimeMonotonic(self, args, span)
        default:
            if Builtins.cLeaf.contains(name) { return EgressBuiltins.emitCLeaf(self, name, args) }
            // An imported *generic* function (task 100.4.3.4): call it through the erased witness-passing
            // ABI to the producer's compiled-once symbol, threading the VWTs for the concrete type
            // arguments — rather than the by-value signature below. Checked before the `callables`
            // fast-path: `emitErasedExternalCall` caches the declaration under this key, so a second call
            // to the same generic must still route here to marshal its args (not a raw by-value call).
            if let sig = e.externalGenericSigs[name] {
                return emitErasedExternalCall(name, sig: sig, args: args, typeArgs: typeArgs,
                                              resultType: resultType, span: span)
            }
            // A user free function or a method symbol — resolve the declared callable.
            let key = name.hasPrefix("m:") ? name : "f:\(name)"
            if let c = e.callables[key] {
                if !curVWTParams.isEmpty, let sig = erasedSigs[key] {
                    return emitErasedExternalCall(name, sig: sig, args: args, typeArgs: typeArgs, resultType: resultType,
                                                  span: span, declared: (c.fn, c.ty))
                }
                return e.buildCall(c.fn, c.ty, args.map { val($0) })
            }
            // A function imported from a dependency (task 100.4.2): declared here as an external symbol
            // (no body), resolved at link against the dependency's object. Signature comes from the call.
            if e.externalFuncNames.contains(name) {
                guard let retTy = ty(resultType, span) else { return nil }
                var paramTys: [LLVMTypeRef] = []
                for a in args { guard let t = ty(a.type, span) else { return nil }; paramTys.append(t) }
                // An imported function's callee name is its per-origin identity `origin@name`
                // (task 100.2.3.2); decode it to the producer's mangled symbol so this external
                // declaration matches the definition the dependency emitted.
                // A bare imported name is a runtime function, which keeps its bare symbol.
                let symbol = Mangle.function(name, home: ExternalName.isEncoded(name) ? e.homeModule : [])
                let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys)
                e.callables[key] = Callable(fn: fn, ty: fnTy,
                                            ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                         body: [], isMutating: false, span: span),
                                            selfType: nil, selfByPointer: false)
                return e.buildCall(fn, fnTy, args.map { val($0) })
            }
            // An instance method on an imported type (task 100.4.3.5): its body lives in the producer, so
            // declare the producer's symbol and link. The receiver type is origin-encoded in the callee
            // (`m:<origin@Type>:method`); decode the origin for the qualifier, matching the symbol the
            // dependency emitted. Parameter types (self included) follow the values ssairgen produced — a
            // class receiver is a reference, a non-mutating value receiver is by value. A *mutating* value
            // method would need its self-by-pointer ABI, which awaits `isMutating` in the `.nmi` (B).
            if name.hasPrefix("m:") {
                let rest = name.dropFirst(2)
                if let colon = rest.firstIndex(of: ":"),
                   case let typePart = String(rest[rest.startIndex..<colon]),
                   ExternalName.isEncoded(typePart) {
                    let method = String(rest[rest.index(after: colon)...])
                    // Erased generic method (task 100.4.3.5.3.3): `typePart` is a mono'd instantiation of
                    // an imported generic type whose method the producer compiled once erased. Route
                    // through the witness ABI with the receiver's type-arg VWTs to the erased symbol (no
                    // type-arg suffix), rather than the undefined monomorphized method symbol.
                    if let typeArgs = e.monoTypeArgs[typePart] {
                        let erasedTypeKey = String(typePart.prefix { $0 != "<" })   // util@Box
                        if let sig = e.externalGenericSigs["m:\(erasedTypeKey):\(method)"] {
                            let symbol = Mangle.method(erasedTypeKey, method, home: e.homeModule)
                            return emitErasedExternalCall("m:\(erasedTypeKey):\(method)", sig: sig, args: args,
                                typeArgs: typeArgs, resultType: resultType, span: span, symbolOverride: symbol)
                        }
                    }
                    guard let retTy = ty(resultType, span) else { return nil }
                    let argVals = args.map { val($0) }
                    let paramTys = argVals.map { LLVMTypeOf($0)! }
                    let symbol = Mangle.method(typePart, method, home: e.homeModule)
                    let (fn, fnTy) = e.emitFunction(symbol, ret: retTy, params: paramTys)
                    e.callables[key] = Callable(fn: fn, ty: fnTy,
                                                ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                             body: [], isMutating: false, span: span),
                                                selfType: nil, selfByPointer: false)
                    return e.buildCall(fn, fnTy, argVals)
                }
            }
            // A property accessor `m:Type:prop.get`/`.set` with no method body is a stored-field
            // requirement — ssairgen devirtualized it to a direct call; lower it to a field access.
            if let v = lowerStoredAccessor(name, args, span) { return v }
            e.fail("7.2.3: unknown call target '\(name)'", span); return nil
        }
    }

    // Call an imported generic function through the erased witness-passing ABI (task 100.4.3.4;
    // backend.md §4) — the caller half of `declareErasedFunction`. The producer compiled the generic
    // once behind hidden leading parameters; here the consumer threads the VWTs for its concrete type
    // arguments, boxes each `.typeParam` value into a stack buffer, and reads the result back from a
    // caller-allocated result buffer.
    // The dictionary a call of `symbol` at `typeArgs` passes: in a compiled-once body the word its own dictionary
    // holds for it, else the constant for these concrete types.
    private func dictionaryArgument(_ symbol: String, _ typeArgs: [Type], _ span: Span) -> LLVMValueRef? {
        if let own = curDictionary {
            let need = DictionaryNeed.callee(symbol: symbol, typeArgs: typeArgs)
            guard let i = e.recipes[curFnName]?.needs.firstIndex(of: need) else {
                e.fail("251.2: no dictionary word in '\(curFnName)' for a call of '\(symbol)'", span); return nil
            }
            return e.loadDictionaryWord(own, curDictionaryWords.count + i)
        }
        guard let d = e.dictionary(dictionaryKey(symbol, typeArgs)) else {
            e.fail("251.2: no dictionary for a call of '\(symbol)' at \(typeArgs)", span); return nil
        }
        return d
    }

    private func emitErasedExternalCall(_ name: String, sig: ExternalGenericSig, args: [SSAValue],
                                        typeArgs: [Type], resultType: Type, span: Span,
                                        symbolOverride: String? = nil,
                                        declared own: (LLVMValueRef, LLVMTypeRef)? = nil) -> LLVMValueRef? {
        guard typeArgs.count == sig.generics.count, args.count == sig.params.count else {
            e.fail("100.4.3.4: erased call of '\(name)' has \(typeArgs.count) type arg(s) / \(args.count) value arg(s), signature wants \(sig.generics.count) / \(sig.params.count)", span)
            return nil
        }
        let returnsTP = heldByBuffer(sig.ret)

        // The erased signature, matching the producer's `declareErasedFunction`: the dictionary, then a
        // result buffer when the return mentions a type parameter, then the value parameters (a `.typeParam`
        // one indirect as a buffer pointer; a concrete one by value).
        var paramTys: [LLVMTypeRef] = [e.i8ptr]
        if returnsTP { paramTys.append(e.i8ptr) }
        for p in sig.params {
            // A generic **class** receiver is a managed `p1` reference, passed directly (task 100.4.3.9); a
            // value `.typeParam` / `.generic` buffer is an i8ptr; a concrete param is its own type.
            if case .generic(let gb, _) = p, e.classMap[gb] != nil { paramTys.append(e.p1) }
            else if mentionsTypeParam(p) { paramTys.append(e.i8ptr) }
            else { guard let t = ty(p, span) else { return nil }; paramTys.append(t) }
        }
        let fnRetTy: LLVMTypeRef = returnsTP ? e.voidTy : (ty(resultType, span) ?? e.voidTy)

        // The producer's erased symbol — its qualified name with no type-argument suffix — decoded from
        // the callee's per-origin identity `origin@bare` (task 100.2.3.2), so this matches the definition.
        let symbol: String
        if let symbolOverride {           // an erased generic *method* — `Mangle.method`, computed by the caller
            symbol = symbolOverride
        } else {
            symbol = Mangle.function(name, home: ExternalName.isEncoded(name) ? e.homeModule : [])
        }
        let key = "f:\(name)"
        let fn: LLVMValueRef, fnTy: LLVMTypeRef
        if let own { fn = own.0; fnTy = own.1 }
        else if let c = e.callables[key] { fn = c.fn; fnTy = c.ty }
        else {
            let declared = e.emitFunction(symbol, ret: fnRetTy, params: paramTys)
            e.callables[key] = Callable(fn: declared.fn, ty: declared.ty,
                                        ir: NOIRFunc(name: name, params: [], returnType: resultType,
                                                     body: [], isMutating: false, span: span),
                                        selfType: nil, selfByPointer: false)
            fn = declared.fn; fnTy = declared.ty
        }

        guard let dict = dictionaryArgument(name, typeArgs, span) else { return nil }
        var callArgs: [LLVMValueRef?] = [dict]
        var resultBuf: LLVMValueRef? = nil
        let erasedResult = heldByBuffer(resultType)
        if returnsTP {
            if erasedResult {       // this frame does not know the size either: it comes from the witnesses
                guard let size = erasedTypeSize(resultType, span) else { return nil }
                resultBuf = e.runtimeSizedBuffer(size, "erased.ret", checked: curChecksStack)
            } else {
                guard let rt = ty(resultType, span) else { return nil }
                resultBuf = e.entryAlloca(rt, "erased.ret")
            }
            callArgs.append(resultBuf)
        }
        // Non-POD `T` arg buffers to register as typed GC roots across the call (task 100.4.3.6): the
        // collector can't see managed pointers inside an opaque `T` buffer, so without this the callee's
        // allocations would strand or dangle them. Each pairs the buffer with its value-layout VWT.
        var shadowBufs: [(buf: LLVMValueRef, vwt: LLVMValueRef)] = []
        for (i, p) in sig.params.enumerated() {
            let v = val(args[i])
            // A generic **class** receiver is already a managed `p1` pointer — pass it directly, no buffer
            // spill (task 100.4.3.9). The statepoint GC tracks it as an ordinary pointer argument.
            if case .generic(let gb, _) = p, e.classMap[gb] != nil {
                callArgs.append(v)
            } else if heldByBuffer(args[i].type) {
                callArgs.append(v)    // an erased caller's value is already a buffer, rooted by that caller
            } else if mentionsTypeParam(p) {
                // A composed value receiver (`sig.params[0]` typed `.generic`) that ssairgen already
                // materialized as a pointer is its own storage buffer: a mutating value method passes `self`
                // by its real address (ssairgen's `structAddr`), so thread it through rather than copying into
                // a fresh buffer — the producer's erased `T`-field write then lands in the caller's storage
                // and sticks past the call (task 100.4.3.10). A read-only value self arrives as a first-class
                // aggregate, and a bare `.typeParam` value (incl. a managed class type argument, itself a
                // pointer) is the value to box — both are spilled into a buffer as before.
                let buf: LLVMValueRef
                let isComposed: Bool = { if case .generic = p { return true } else { return false } }()
                if isComposed, LLVMGetTypeKind(LLVMTypeOf(v)) == LLVMPointerTypeKind {
                    buf = v
                } else {
                    guard let at = ty(args[i].type, span) else { return nil }
                    let a = e.entryAlloca(at, "erased.arg")
                    LLVMBuildStore(b, v, a)
                    buf = a
                }
                callArgs.append(buf)
                // Register the arg buffer as a typed GC root if it carries any managed content — a direct
                // `addrspace(1)` field *or* shaped content (a `String`, whose `word0` is a conditional
                // managed pointer). Reading only the direct offsets would drop a shaped-only type (`T =
                // String`), leaving its heap buffer unrooted across the erased call (the erased-generic
                // shaped typed-root gap — `internals/gc-model-upgrade.md`).
                if !e.shapes.shape(args[i].type).isEmpty { shadowBufs.append((buf, e.valueWitness(args[i].type))) }
            } else {
                callArgs.append(v)
            }
        }

        // Register the non-POD buffers on the current fiber's typed-root shadow stack, around the call.
        // A node per buffer rides this (addrspace-0) frame; `rtShadowPopTo` restores the saved top on
        // return. POD args are left unregistered — the hybrid fast path keeps them pure inline buffers.
        var savedTop: LLVMValueRef? = nil
        if !shadowBufs.isEmpty {
            let save = e.preludeFn("nomu_fn_rtShadowSave", ret: e.i64, params: [])
            savedTop = e.buildCall(save.0, save.1, [])
            let push = e.preludeFn("nomu_fn_rtShadowPush", ret: e.voidTy, params: [e.i8ptr, e.i8ptr, e.i8ptr])
            let nodeTy = e.structTy([e.i8ptr, e.i8ptr, e.i8ptr])
            for sb in shadowBufs {
                let node = e.entryAlloca(nodeTy, "shadow.node")
                _ = e.buildCall(push.0, push.1, [node, sb.buf, sb.vwt])
            }
        }

        let call = e.buildCall(fn, fnTy, callArgs)

        if let st = savedTop {
            let pop = e.preludeFn("nomu_fn_rtShadowPopTo", ret: e.voidTy, params: [e.i64])
            _ = e.buildCall(pop.0, pop.1, [st])
        }
        if let buf = resultBuf, erasedResult {
            registerErasedComponents(buf, resultType, LLVMConstInt(e.i64, 0, 0), span)
            return buf
        }
        if returnsTP, let rt = ty(resultType, span), let buf = resultBuf {
            return LLVMBuildLoad2(b, rt, buf, "erased.res")
        }
        return call
    }

    // A stored-field-backed property accessor `m:Type:prop.get` / `m:Type:prop.set` reached as a direct
    // call (no method body exists) — read/write the field directly. Mirrors the NOIR egress's
    // stored-field getter/setter path. `self` is args[0] (a struct value for a getter, a pointer for a
    // class or a mutating setter); the setter's new value is args[1]. Returns nil if `name` is not such
    // an accessor.
    private func lowerStoredAccessor(_ name: String, _ args: [SSAValue], _ span: Span) -> LLVMValueRef? {
        guard name.hasPrefix("m:") else { return nil }
        let rest = name.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let type = String(rest[rest.startIndex..<colon])
        let method = String(rest[rest.index(after: colon)...])
        let isGet = method.hasSuffix(".get"), isSet = method.hasSuffix(".set")
        guard isGet || isSet else { return nil }
        let prop = String(method.dropLast(4))
        guard let info = e.aggInfo(type), let pos = info.fields.firstIndex(where: { $0.name == prop }),
              let fieldTy = ty(info.fields[pos].type, span) else { return nil }
        let selfV = val(args[0])
        if isGet {
            if info.kind == .classRef {
                return LLVMBuildLoad2(b, fieldTy, e.structGEP(info.ty, selfV, e.llvmFieldIndex(type, pos)), "ld")
            }
            let raw = LLVMBuildExtractValue(b, selfV, UInt32(e.llvmFieldIndex(type, pos)), "fld")!   // struct value receiver
            return e.fromFieldStorage(raw, info.fields[pos].type)
        }
        // setter: `self` is a pointer (class, or a mutating struct receiver passed by address)
        let slot = e.structGEP(info.ty, selfV, e.llvmFieldIndex(type, pos))
        if info.kind == .classRef { e.storeField(selfV, slot, val(args[1])) }
        else { LLVMBuildStore(b, val(args[1]), slot) }
        return LLVMConstInt(e.i64, 0, 0)
    }

}
