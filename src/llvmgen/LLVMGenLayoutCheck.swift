import noir
import ast
import support
import LLVM_C

// The 8-byte-slot layout check. Every Nomu layout other than codegen's LLVM types computes field offsets
// as whole 8-byte slots (`slotCount`): the GC descriptors, enum payloads, array strides, the VWT sizes and
// the erased path's offsets. Codegen's aggregate types must therefore place each field exactly where the slot
// arithmetic says, or the collector scans the wrong words and an erased body reads the wrong bytes. This
// compares, under the target's data layout, every aggregate type egress built against that arithmetic, and
// reports the first disagreement as a compile error.
extension LLVMGen {
    func checkSlotLayout(_ dl: LLVMTargetDataRef) -> String? {
        func size(_ t: LLVMTypeRef) -> Int { Int(LLVMABISizeOfType(dl, t)) }
        func offset(_ t: LLVMTypeRef, _ i: Int) -> Int { Int(LLVMOffsetOfElement(dl, t, UInt32(i))) }

        // Fields laid out from `base`: field i at `base` + the slots of fields before it, elements from
        // `firstElem` on in `t`.
        func checkFields(_ what: String, _ t: LLVMTypeRef, _ fields: [Type], base: Int, firstElem: Int) -> String? {
            var want = base
            for (i, f) in fields.enumerated() {
                let got = offset(t, firstElem + i)
                if got != want {
                    return "internal: \(what) field \(i) (\(f)) is at byte \(got) in its LLVM layout but at \(want) in the 8-byte-slot layout"
                }
                want += slotCount(f) * 8
            }
            return nil
        }

        for (name, t) in structTypes.sorted(by: { $0.key < $1.key }) {
            guard let s = structMap[name], !s.fields.isEmpty, LLVMGetTypeKind(t) == LLVMStructTypeKind,
                  !isShapedWrapper(.named(name, .struct_)) else { continue }
            if let err = checkFields("struct \(name)", t, s.fields.map(\.type), base: 0, firstElem: 0) { return err }
            if size(t) != slotCount(.named(name, .struct_)) * 8 {
                return "internal: struct \(name) is \(size(t)) bytes in its LLVM layout but \(slotCount(.named(name, .struct_)) * 8) in the 8-byte-slot layout"
            }
        }
        for (name, t) in classTypes.sorted(by: { $0.key < $1.key }) {
            guard let c = classMap[name] else { continue }
            if let err = checkFields("class \(name)", t, c.fields.map(\.type), base: 8, firstElem: 1) { return err }
        }
        for (name, t) in actorTypes.sorted(by: { $0.key < $1.key }) {
            guard let a = actorMap[name] else { continue }
            if let err = checkFields("actor \(name)", t, a.fields.map(\.type), base: 8, firstElem: 1) { return err }
        }
        for name in enumTypes.keys.sorted() {
            guard let en = enumMap[name] else { continue }
            for c in en.cases where !c.fields.isEmpty {
                guard let cst = caseStructType(name, c) else { continue }
                if let err = checkFields("enum \(name) case \(c.name)", cst, c.fields.map(\.type), base: 0, firstElem: 0) {
                    return err
                }
            }
        }
        return nil
    }
}
