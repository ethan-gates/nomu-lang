import noir
import support
import LLVM_C

// Debug info (8.3, DWARF Tier 0), moved into the shared emitter (ssair.md): the DIBuilder /
// compile unit / file, per-function subprograms + scope, source locations, DWARF types, and local
// `llvm.dbg.declare` records. Both egresses thread debug info through here.
extension LLVMGen {
    // Create the DIBuilder, its file, and the compile unit from the source path. A blank path leaves
    // `di` nil, so all later debug-info work is skipped.
    func setupDebugInfo(sourceFile path: String) {
        guard !path.isEmpty else { return }
        addModuleFlag("Debug Info Version", LLVMConstInt(i32, 3, 0))   // DEBUG_METADATA_VERSION
        addModuleFlag("Dwarf Version", LLVMConstInt(i32, 4, 0))
        let dib = LLVMCreateDIBuilder(mod)
        di = dib
        let (name, dir) = splitPath(path)
        diFile = LLVMDIBuilderCreateFile(dib, name, name.utf8.count, dir, dir.utf8.count)
        let producer = "nomu"
        diCU = LLVMDIBuilderCreateCompileUnit(
            dib, LLVMDWARFSourceLanguageC, diFile, producer, producer.utf8.count,
            /*isOptimized=*/0, "", 0, /*RuntimeVer=*/0, "", 0,
            LLVMDWARFEmissionFull, /*DWOId=*/0, /*SplitDebugInlining=*/1,
            /*DebugInfoForProfiling=*/0, "", 0, "", 0)
    }

    func addModuleFlag(_ key: String, _ value: LLVMValueRef) {
        LLVMAddModuleFlag(mod, LLVMModuleFlagBehaviorWarning, key, key.utf8.count,
                          LLVMValueAsMetadata(value))
    }

    func splitPath(_ path: String) -> (name: String, dir: String) {
        guard let slash = path.lastIndex(of: "/") else { return (path, ".") }
        return (String(path[path.index(after: slash)...]), String(path[..<slash]))
    }

    // A `DISubprogram` for a source-backed function; nil for thunks (`di` nil or no debug requested).
    func makeSubprogram(_ displayName: String, linkage: String, line: Int) -> LLVMMetadataRef? {
        guard let dib = di else { return nil }
        let subTy = LLVMDIBuilderCreateSubroutineType(dib, diFile, nil, 0, LLVMDIFlagZero)
        let ln = UInt32(max(line, 1))
        return LLVMDIBuilderCreateFunction(
            dib, diCU, displayName, displayName.utf8.count, linkage, linkage.utf8.count,
            diFile, ln, subTy, /*IsLocalToUnit=*/0, /*IsDefinition=*/1, /*ScopeLine=*/ln,
            LLVMDIFlagZero, /*IsOptimized=*/0)
    }

    // Point the builder's current debug location at `span`, scoped to the active subprogram.
    func setDebugLoc(_ span: Span) {
        guard di != nil, let scope = currentScope, span.begin.line > 0 else { return }
        let loc = LLVMDIBuilderCreateDebugLocation(
            ctx, UInt32(span.begin.line), UInt32(span.begin.col), scope, nil)
        LLVMSetCurrentDebugLocation2(b, loc)
    }

    // Enter `fn`'s scope: adopt its subprogram (nil for thunks) and seed a live debug location.
    func enterDebugScope(_ fn: LLVMValueRef, line: Int) {
        guard di != nil else { return }
        currentScope = LLVMGetSubprogram(fn)
        if let scope = currentScope, line > 0 {
            LLVMSetCurrentDebugLocation2(b, LLVMDIBuilderCreateDebugLocation(ctx, UInt32(line), 0, scope, nil))
        } else {
            LLVMSetCurrentDebugLocation2(b, nil)
        }
    }

    // 8.3.2 — the DWARF type for a Nomu type. Int/Bool are basic types, String/structs composites, a
    // class a pointer to its object composite; unmodeled types return nil (their locals stay undeclared).
    func diType(_ t: Type) -> LLVMMetadataRef? {
        guard di != nil else { return nil }
        switch t {
        case .int:    return diBasic("Int", dwSigned, bits: 64)
        case .uint8:  return diBasic("UInt8", dwUnsignedChar, bits: 8)
        case .uint64: return diBasic("UInt64", dwUnsigned, bits: 64)
        case .double: return diBasic("Double", dwFloat, bits: 64)
        case .bool:   return diBasic("Bool", dwBoolean, bits: 8)   // i1, one byte in memory (8.5.2)
        case .string: return diStringType()
        case .named(let n, .struct_): return diStructType(n)
        case .named(let n, .class_):  return diClassPointer(n)
        case .opaque: return diType(concreteUnderlying(t))
        default:      return nil                          // enum/actor/function/`any` — unmodeled (Tier 0)
        }
    }

    func diBasic(_ name: String, _ encoding: LLVMDWARFTypeEncoding, bits: UInt64 = 64) -> LLVMMetadataRef? {
        if let c = diTypeCache["b:\(name)"] { return c }
        let t = LLVMDIBuilderCreateBasicType(di, name, name.utf8.count, bits, encoding, LLVMDIFlagZero)
        diTypeCache["b:\(name)"] = t
        return t
    }

    // The runtime `String` is `{ i8* data, i64 len }` — a 16-byte composite.
    func diStringType() -> LLVMMetadataRef? {
        if let c = diTypeCache["b:String"] { return c }
        let charTy = LLVMDIBuilderCreateBasicType(di, "UInt8", 5, 8, dwUnsignedChar, LLVMDIFlagZero)
        let dataTy = LLVMDIBuilderCreatePointerType(di, charTy, 64, 0, 0, "", 0)
        let members = [member("data", dataTy, sizeBits: 64, offsetBits: 0),
                       member("len", diBasic("Int", dwSigned), sizeBits: 64, offsetBits: 64)]
        let t = composite("String", sizeBits: 128, members: members)
        diTypeCache["b:String"] = t
        return t
    }

    func diStructType(_ name: String) -> LLVMMetadataRef? {
        if let c = diTypeCache["s:\(name)"] { return c }
        guard let s = structMap[name] else { return nil }
        var members: [LLVMMetadataRef?] = []
        var offsetSlots = 0
        for f in s.fields {
            let fieldSlots = slotCount(f.type)
            if let fty = diType(f.type) {
                members.append(member(f.name, fty, sizeBits: UInt64(fieldSlots) * 64,
                                      offsetBits: UInt64(offsetSlots) * 64))
            }
            offsetSlots += fieldSlots
        }
        let t = composite(name, sizeBits: UInt64(offsetSlots) * 64, members: members)
        diTypeCache["s:\(name)"] = t
        return t
    }

    // A class value is a pointer to `{ i64 header, fields… }`; model the object composite (header slot
    // so field offsets match the +1 index) and return a pointer to it.
    func diClassPointer(_ name: String) -> LLVMMetadataRef? {
        if let c = diTypeCache["c:\(name)"] { return c }
        guard let cl = classMap[name] else { return nil }
        var members: [LLVMMetadataRef?] = [member("__header", diBasic("Int", dwSigned), sizeBits: 64, offsetBits: 0)]
        var offsetSlots = 1
        for f in cl.fields {
            let fieldSlots = slotCount(f.type)
            if let fty = diType(f.type) {
                members.append(member(f.name, fty, sizeBits: UInt64(fieldSlots) * 64,
                                      offsetBits: UInt64(offsetSlots) * 64))
            }
            offsetSlots += fieldSlots
        }
        let obj = composite(name, sizeBits: UInt64(offsetSlots) * 64, members: members)
        let ptr = LLVMDIBuilderCreatePointerType(di, obj, 64, 0, 0, "", 0)
        diTypeCache["c:\(name)"] = ptr
        return ptr
    }

    func member(_ name: String, _ ty: LLVMMetadataRef?, sizeBits: UInt64, offsetBits: UInt64) -> LLVMMetadataRef? {
        LLVMDIBuilderCreateMemberType(di, diCU, name, name.utf8.count, diFile, 0,
                                      sizeBits, 0, offsetBits, LLVMDIFlagZero, ty)
    }

    func composite(_ name: String, sizeBits: UInt64, members: [LLVMMetadataRef?]) -> LLVMMetadataRef? {
        var elems = members
        return elems.withUnsafeMutableBufferPointer {
            LLVMDIBuilderCreateStructType(di, diCU, name, name.utf8.count, diFile, 0, sizeBits, 0,
                                          LLVMDIFlagZero, nil, $0.baseAddress, UInt32(members.count),
                                          0, nil, "", 0)
        }
    }

    // Attach a `DILocalVariable` + `llvm.dbg.declare` to `addr`. `argNo` marks a parameter (1-based).
    func declareLocal(_ name: String, type: Type, addr: LLVMValueRef, line: Int, argNo: Int? = nil) {
        guard let dib = di, let scope = currentScope, let ty = diType(type) else { return }
        let ln = UInt32(max(line, 1))
        let varInfo: LLVMMetadataRef?
        if let argNo = argNo {
            varInfo = LLVMDIBuilderCreateParameterVariable(dib, scope, name, name.utf8.count,
                        UInt32(argNo), diFile, ln, ty, /*AlwaysPreserve=*/1, LLVMDIFlagZero)
        } else {
            varInfo = LLVMDIBuilderCreateAutoVariable(dib, scope, name, name.utf8.count, diFile, ln, ty,
                        /*AlwaysPreserve=*/1, LLVMDIFlagZero, /*AlignInBits=*/0)
        }
        guard let vi = varInfo else { return }
        let expr = LLVMDIBuilderCreateExpression(dib, nil, 0)
        let loc = LLVMGetCurrentDebugLocation2(b)
            ?? LLVMDIBuilderCreateDebugLocation(ctx, ln, 0, scope, nil)
        LLVMDIBuilderInsertDeclareRecordAtEnd(dib, addr, vi, expr, loc, LLVMGetInsertBlock(b))
    }
}
