import noir
import ast
import support
import ssair
import LLVM_C

// The layout check. Every Nomu layout other than codegen's LLVM types reads field offsets and sizes from the
// value layout (`ShapeEnv.fieldsLayout`, `ShapeEnv.size`): the GC descriptors, enum payloads, array strides,
// the VWT sizes and the erased path's offsets. Codegen's aggregate types must therefore place each field
// exactly where the value layout says, or the collector scans the wrong words and an erased body reads the
// wrong bytes. This compares, under the target's data layout, every aggregate type egress built against the
// value layout, and reports the first disagreement as a compile error.
extension LLVMGen {
    func checkLayout(_ dl: LLVMTargetDataRef) -> String? {
        func size(_ t: LLVMTypeRef) -> Int { Int(LLVMABISizeOfType(dl, t)) }
        func offset(_ t: LLVMTypeRef, _ i: Int) -> Int { Int(LLVMOffsetOfElement(dl, t, UInt32(i))) }

        // Field i at `want[i]`, element `index(i)` in `t`.
        func checkFields(_ what: String, _ t: LLVMTypeRef, _ fields: [Type], _ want: [Int], _ index: (Int) -> Int) -> String? {
            for (i, f) in fields.enumerated() {
                let got = offset(t, index(i))
                if got != want[i] {
                    return "internal: \(what) field \(i) (\(f)) is at byte \(got) in its LLVM layout but at \(want[i]) in the value layout"
                }
            }
            return nil
        }

        for (name, t) in structTypes.sorted(by: { $0.key < $1.key }) {
            guard let s = structMap[name], !s.fields.isEmpty, LLVMGetTypeKind(t) == LLVMStructTypeKind,
                  !isShapedWrapper(.named(name, .struct_)) else { continue }
            if let err = checkFields("struct \(name)", t, s.fields.map(\.type), shapes.structLayout(name).offsets,
                                     { self.llvmFieldIndex(name, $0) }) {
                return err
            }
            let want = sizeOf(.named(name, .struct_))
            if size(t) != want {
                return "internal: struct \(name) is \(size(t)) bytes in its LLVM layout but \(want) in the value layout"
            }
        }
        for (name, t) in classTypes.sorted(by: { $0.key < $1.key }) {
            guard let c = classMap[name] else { continue }
            if let err = checkFields("class \(name)", t, c.fields.map(\.type), objectLayout(name).offsets,
                                     { self.llvmFieldIndex(name, $0) }) {
                return err
            }
        }
        for (name, t) in actorTypes.sorted(by: { $0.key < $1.key }) {
            guard let a = actorMap[name] else { continue }
            if let err = checkFields("actor \(name)", t, a.fields.map(\.type), objectLayout(name).offsets,
                                     { self.llvmFieldIndex(name, $0) }) {
                return err
            }
            if offset(t, actorMailboxIndex(name)) != actorMailboxOffset(name) {
                return "internal: actor \(name)'s mailbox is at byte \(offset(t, actorMailboxIndex(name))) in its LLVM layout but at \(actorMailboxOffset(name)) in the value layout"
            }
        }
        for (key, t) in messageTypes.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let h = actorMap[parts[0]]?.handlers.first(where: { $0.name == parts[1] }) else { continue }
            if let err = checkFields("message \(key)", t, h.params.map(\.type), messageArgsLayout(h).offsets, { 4 + $0 }) {
                return err
            }
        }
        for (name, et) in enumTypes.sorted(by: { $0.key < $1.key }) {
            guard let en = enumMap[name] else { continue }
            let want = sizeOf(.named(name, .enum_))
            if size(et) != want {
                return "internal: enum \(name) is \(size(et)) bytes in its LLVM layout but \(want) in the value layout"
            }
            switch shapes.enumLayout(name) {
            case .overExtraInhabitants(let p):
                // The payload case's fields are the enum's elements.
                let c = en.cases[p]
                if let err = checkFields("enum \(name) case \(c.name)", et, c.fields.map(\.type),
                                         shapes.enumCaseLayout(name, p).offsets, { $0 }) {
                    return err
                }
            case .tagOnly:
                break
            case .spareBits:
                // Each case's struct is GEP'd over the region from byte 0.
                for (ci, c) in en.cases.enumerated() where !c.fields.isEmpty {
                    guard let cst = caseStructType(name, c) else { continue }
                    if let err = checkFields("enum \(name) case \(c.name)", cst, c.fields.map(\.type),
                                             shapes.enumCaseLayout(name, ci).offsets, { $0 }) {
                        return err
                    }
                }
            case .tagged(let tagOffset, _):
                // Each case's struct is GEP'd over the payload region from byte 0; the tag is the last element.
                for (ci, c) in en.cases.enumerated() where !c.fields.isEmpty {
                    guard let cst = caseStructType(name, c) else { continue }
                    if let err = checkFields("enum \(name) case \(c.name)", cst, c.fields.map(\.type),
                                             shapes.enumCaseLayout(name, ci).offsets, { $0 }) {
                        return err
                    }
                }
                let last = Int(LLVMCountStructElementTypes(et)) - 1
                if offset(et, last) != tagOffset {
                    return "internal: enum \(name)'s tag is at byte \(offset(et, last)) in its LLVM layout but at \(tagOffset) in the value layout"
                }
            }
        }
        return nil
    }
}
