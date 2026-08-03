// M8 · 8.2 — lower the typed IR (frontend `IRModule`) to an LLVM module via the C API. This is the
// backend. Through 8.2 it was developed as the LLVM sibling of the C backend (`CodegenIR`) and
// differential-tested against it; at the 8.2 exit the C backend was retired, so per-node comments
// that reference `CodegenIR` are design lineage, not a live counterpart.
//
//   8.2.1 — primitives + control flow + functions: Int/Bool/String literals, arithmetic/
//           comparison, let/var, assignment + `+=`, if/else, return, user + builtin calls
//           (`print`, string `concat`).
//   8.2.2 — value types: `struct` construction, stored-field load/store, methods (self by value),
//           mutating methods (self by pointer), computed properties (get/set).
//   8.2.5 — interfaces + generics + `Result`: witness tables (a struct of function pointers per
//           conformance, built on demand), `any I` boxing (`AnyBox { ptr witness, ptr payload }`)
//           + dynamic dispatch through the witness slot, `any A & B` composition (a composite
//           witness), `some`/opaque devirtualization (the concrete underlying is known), and
//           existential upcast (`any B` → `any A` via the witness base pointer). Monomorphized
//           generics and `Result<T,E>` need nothing here — mono ran before codegen, so a generic
//           instance arrives as a concrete named struct/enum the earlier slices already lower.
//   8.2.6 — concurrency: `actor` layout (`{ header, fields…, mu }`, a reference type like a class)
//           with each `on`-handler mutex-serialized (lock at entry, unlock at every exit — the mutex
//           is an opaque runtime `void*`, `rt_mutex_new`); `spawn let` closure-converted onto a
//           fiber (`fiber_spawn`), the binding joined (`spawn_join`) on read and at scope/function
//           exit (the structured-concurrency guarantee); colorless blocking calls `sleep`
//           (`rt_sleep_ms`) and `readLine` (`rt_read_line`). Share analysis is a frontend/Sema
//           safety check, not a codegen concern, so it is not repeated here.
//
// Nodes outside the covered set set `error` (a `file:line:col`-prefixed message, not a crash) —
// the boundary later slices push. ABI parity with `CodegenIR.cType`: Int and Bool are both **i64**
// (bool 0/1); String is the runtime `{ i8*, i64 }` struct; a `struct` is an LLVM struct in field
// order, passed/returned by value (mutating `self` is a pointer to it). Nomu `main` → `nomu_main`.
import LLVM_C
import frontend

final class IRToLLVM {
    private let ctx: LLVMContextRef
    private let mod: LLVMModuleRef
    private let b: LLVMBuilderRef

    private let i8ptr: LLVMTypeRef
    private let i32: LLVMTypeRef
    private let i64: LLVMTypeRef
    private let voidTy: LLVMTypeRef
    private let strTy: LLVMTypeRef      // { i8* data, i64 len } — matches runtime.h `String`
    private let closureTy: LLVMTypeRef  // { ptr fn, ptr env } — matches runtime.h `Closure`
    private let anyBoxTy: LLVMTypeRef   // { ptr witness, ptr payload } — an `any I` box (8.2.5)
    private let spawnHandleTy: LLVMTypeRef  // { ptr fiber } — matches runtime.h `SpawnHandle` (8.2.6)

    private let zeroSpan = Span(file: "", begin: Pos(line: 0, col: 0), end: Pos(line: 0, col: 0))

    private var runtimeFns: [String: (fn: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    private var intFmt: LLVMValueRef?
    private var strFmt: LLVMValueRef?

    // Type + function registries. `structMap`/`structTypes`: Nomu structs and their (cached) LLVM
    // struct types. `funcMap`: top-level functions. `callables`: LLVM functions declared on demand
    // (free functions keyed `f:<name>`, methods `m:<type>:<method>`), with `pending` bodies.
    private var structMap: [String: IRStruct] = [:]
    private var structTypes: [String: LLVMTypeRef] = [:]
    private var enumMap: [String: IREnum] = [:]
    private var enumTypes: [String: LLVMTypeRef] = [:]
    private var classMap: [String: IRClass] = [:]
    private var classTypes: [String: LLVMTypeRef] = [:]
    private var actorMap: [String: IRActor] = [:]
    private var actorTypes: [String: LLVMTypeRef] = [:]
    private var funcMap: [String: IRFunc] = [:]
    private var closureSeq = 0

    // 8.2.5 witness machinery. `interfaceDefs` gives a requirement surface to lay out a witness
    // struct; `opaqueUnderlyings` resolves `some I` to its hidden concrete type. Witness types and
    // per-conformance instances (LLVM globals) are built lazily on first box/upcast, keyed
    // `type::iface` (and `type::A&B` for composites).
    private var interfaceDefs: [String: IRInterface] = [:]
    private var witnessSlotsCache: [String: [String]] = [:]
    private var opaqueUnderlyings: [String: Type] = [:]
    private var witnessTypes: [String: LLVMTypeRef] = [:]
    private var witnessGlobals: [String: LLVMValueRef] = [:]
    private var compositeTypes: [String: LLVMTypeRef] = [:]
    private var compositeGlobals: [String: LLVMValueRef] = [:]

    private struct Callable {
        let fn: LLVMValueRef
        let ty: LLVMTypeRef
        let ir: IRFunc
        let selfType: String?     // struct type name when this is a method
        let selfByPointer: Bool   // mutating method → self is `T*`
        let isActorHandler: Bool  // an `on`-handler: mutex-serialized (8.2.6)
    }
    private var callables: [String: Callable] = [:]
    private var pending: [String] = []

    // 8.2.6 spawn machinery. A `spawn let` binding maps to a heap `SpawnHandle*`; reading it (or
    // leaving the scope) joins the fiber. `activeSpawns` is the join set for the current function.
    private struct SpawnLocal {
        let handleSlot: LLVMValueRef   // alloca of spawnHandleTy holding the fiber
        let resultTy: LLVMTypeRef      // the joined result's LLVM type
    }
    private var spawnLocals: [String: SpawnLocal] = [:]
    private var activeSpawns: [SpawnLocal] = []
    private var spawnSeq = 0
    // While lowering an actor handler body: the (loaded) mutex to unlock at every exit.
    private var currentActorMu: LLVMValueRef?

    // A local (param / let / self) → the address holding its value, and the value's LLVM type.
    private var locals: [String: (addr: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    private var currentFn: LLVMValueRef?

    // While lowering a method body: the receiver, so a bare field reference (`x` inside a method)
    // resolves through `self`.
    // A struct is a value; a class is a heap reference (its value is a pointer to `{ header, … }`).
    private enum AggKind { case structVal, classRef }

    private struct SelfCtx {
        let fields: [IRField]    // fields for bare-name access inside a method; [] for enums
        let kind: AggKind        // class fields sit after the object header (index +1)
        let llvmTy: LLVMTypeRef  // the struct/class aggregate type (the pointee for a class)
        let addr: LLVMValueRef   // pointer to the receiver's fields (struct value / object)
    }
    private var currentSelf: SelfCtx?

    // 8.3 — DWARF Tier 0. The DIBuilder, the compile-unit file, and the subprogram `!dbg` locations
    // attach to. `currentScope` and the builder's current debug location are saved/restored across
    // thunks (like the rest of the builder state) so each hoisted function keeps its own scope.
    // Nil `di` ⇒ no debug info (the module named no source file); everything below is then inert.
    private var di: LLVMDIBuilderRef?
    private var diFile: LLVMMetadataRef?
    private var diCU: LLVMMetadataRef?
    private var currentScope: LLVMMetadataRef?
    private var diTypeCache: [String: LLVMMetadataRef] = [:]   // 8.3.2 basic/composite DITypes

    private(set) var loweredMain = false
    private(set) var error: String?

    init(ctx: LLVMContextRef, mod: LLVMModuleRef) {
        self.ctx = ctx
        self.mod = mod
        b = LLVMCreateBuilderInContext(ctx)
        i8ptr = LLVMPointerType(LLVMInt8TypeInContext(ctx), 0)
        i32 = LLVMInt32TypeInContext(ctx)
        i64 = LLVMInt64TypeInContext(ctx)
        voidTy = LLVMVoidTypeInContext(ctx)
        var fields: [LLVMTypeRef?] = [i8ptr, i64]
        strTy = fields.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 2, /*packed=*/0)
        }
        var clo: [LLVMTypeRef?] = [i8ptr, i8ptr]
        closureTy = clo.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 2, 0)
        }
        var box: [LLVMTypeRef?] = [i8ptr, i8ptr]
        anyBoxTy = box.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 2, 0)
        }
        var sh: [LLVMTypeRef?] = [i8ptr]
        spawnHandleTy = sh.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 1, 0)
        }
    }

    deinit { LLVMDisposeBuilder(b) }

    func lower(_ module: IRModule) {
        for i in module.interfaces { interfaceDefs[i.name] = i }
        opaqueUnderlyings = module.opaqueUnderlyings
        for decl in module.decls {
            switch decl {
            case .funcDecl(let f):   funcMap[f.name] = f
            case .structDecl(let s): structMap[s.name] = s
            case .enumDecl(let e):   enumMap[e.name] = e
            case .classDecl(let c):  classMap[c.name] = c
            case .actorDecl(let a):  actorMap[a.name] = a
            }
        }
        guard let mainFn = funcMap["main"] else { return }   // `loweredMain` stays false → caller errors
        setupDebugInfo(sourceFile: mainFn.span.file)
        declareFree("main")
        while error == nil, !pending.isEmpty {
            defineBody(pending.removeFirst())
        }
        if let dib = di {                       // resolve line tables/types before verify + emit
            LLVMDIBuilderFinalize(dib)
            LLVMDisposeDIBuilder(dib)
            di = nil
        }
        if error == nil { loweredMain = callables["f:main"] != nil }
    }

    // MARK: - Debug info (8.3, DWARF Tier 0)

    // Create the DIBuilder, its file, and the compile unit from the source path (the `file` every
    // span carries). Sets the two module flags the verifier requires for debug info. A blank path
    // leaves `di` nil, so all later debug-info work is skipped.
    private func setupDebugInfo(sourceFile path: String) {
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

    private func addModuleFlag(_ key: String, _ value: LLVMValueRef) {
        LLVMAddModuleFlag(mod, LLVMModuleFlagBehaviorWarning, key, key.utf8.count,
                          LLVMValueAsMetadata(value))
    }

    private func splitPath(_ path: String) -> (name: String, dir: String) {
        guard let slash = path.lastIndex(of: "/") else { return (path, ".") }
        return (String(path[path.index(after: slash)...]), String(path[..<slash]))
    }

    // A `DISubprogram` for a source-backed function; nil for thunks (`debug` nil) so their
    // synthetic instructions carry no `!dbg` and the inlinable-call verifier rule doesn't apply.
    private func makeSubprogram(_ displayName: String, linkage: String, line: Int) -> LLVMMetadataRef? {
        guard let dib = di else { return nil }
        let subTy = LLVMDIBuilderCreateSubroutineType(dib, diFile, nil, 0, LLVMDIFlagZero)
        let ln = UInt32(max(line, 1))
        return LLVMDIBuilderCreateFunction(
            dib, diCU, displayName, displayName.utf8.count, linkage, linkage.utf8.count,
            diFile, ln, subTy, /*IsLocalToUnit=*/0, /*IsDefinition=*/1, /*ScopeLine=*/ln,
            LLVMDIFlagZero, /*IsOptimized=*/0)
    }

    // Point the builder's current debug location at `span`, scoped to the active subprogram. All
    // instructions built afterward inherit it until it's changed — enough for line-table stepping.
    private func setDebugLoc(_ span: Span) {
        guard di != nil, let scope = currentScope, span.begin.line > 0 else { return }
        let loc = LLVMDIBuilderCreateDebugLocation(
            ctx, UInt32(span.begin.line), UInt32(span.begin.col), scope, nil)
        LLVMSetCurrentDebugLocation2(b, loc)
    }

    // Enter `fn`'s scope: adopt its subprogram (nil for thunks) and seed a live debug location at
    // `line` so prologue instructions are covered; a nil scope clears the location instead.
    private func enterDebugScope(_ fn: LLVMValueRef, line: Int) {
        guard di != nil else { return }
        currentScope = LLVMGetSubprogram(fn)
        if let scope = currentScope, line > 0 {
            LLVMSetCurrentDebugLocation2(b, LLVMDIBuilderCreateDebugLocation(ctx, UInt32(line), 0, scope, nil))
        } else {
            LLVMSetCurrentDebugLocation2(b, nil)
        }
    }

    // 8.3.2 — the DWARF type for a Nomu type. Int/Bool are i64 basic types, String and structs are
    // composites with member layout (offsets from the same 8-byte-slot accounting the ABI uses), a
    // class is a pointer to its object composite. Types we don't yet model (enum/actor/closure/
    // `any`/`some`) return nil, so their locals are simply left undeclared — never mis-described.
    private let dwSigned: LLVMDWARFTypeEncoding = 5      // DW_ATE_signed
    private let dwBoolean: LLVMDWARFTypeEncoding = 2     // DW_ATE_boolean
    private let dwUnsignedChar: LLVMDWARFTypeEncoding = 8 // DW_ATE_unsigned_char

    private func diType(_ t: Type) -> LLVMMetadataRef? {
        guard di != nil else { return nil }
        switch t {
        case .int:    return diBasic("Int", dwSigned)
        case .bool:   return diBasic("Bool", dwBoolean)   // stored as i64 (bool 0/1)
        case .string: return diStringType()
        case .named(let n, .struct_): return diStructType(n)
        case .named(let n, .class_):  return diClassPointer(n)
        case .opaque: return diType(concreteUnderlying(t))
        default:      return nil                          // enum/actor/function/`any` — unmodeled (Tier 0)
        }
    }

    private func diBasic(_ name: String, _ encoding: LLVMDWARFTypeEncoding) -> LLVMMetadataRef? {
        if let c = diTypeCache["b:\(name)"] { return c }
        let t = LLVMDIBuilderCreateBasicType(di, name, name.utf8.count, 64, encoding, LLVMDIFlagZero)
        diTypeCache["b:\(name)"] = t
        return t
    }

    // The runtime `String` is `{ i8* data, i64 len }` — a 16-byte composite of a char pointer and a
    // length, laid out at slot offsets 0 and 1.
    private func diStringType() -> LLVMMetadataRef? {
        if let c = diTypeCache["b:String"] { return c }
        let charTy = LLVMDIBuilderCreateBasicType(di, "UInt8", 5, 8, dwUnsignedChar, LLVMDIFlagZero)
        let dataTy = LLVMDIBuilderCreatePointerType(di, charTy, 64, 0, 0, "", 0)
        let members = [member("data", dataTy, sizeBits: 64, offsetBits: 0),
                       member("len", diBasic("Int", dwSigned), sizeBits: 64, offsetBits: 64)]
        let t = composite("String", sizeBits: 128, members: members)
        diTypeCache["b:String"] = t
        return t
    }

    private func diStructType(_ name: String) -> LLVMMetadataRef? {
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

    // A class value is a pointer to `{ i64 header, fields… }`; model the object composite (with a
    // header slot so field offsets match the +1 index) and return a pointer to it.
    private func diClassPointer(_ name: String) -> LLVMMetadataRef? {
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

    private func member(_ name: String, _ ty: LLVMMetadataRef?, sizeBits: UInt64, offsetBits: UInt64) -> LLVMMetadataRef? {
        LLVMDIBuilderCreateMemberType(di, diCU, name, name.utf8.count, diFile, 0,
                                      sizeBits, 0, offsetBits, LLVMDIFlagZero, ty)
    }

    private func composite(_ name: String, sizeBits: UInt64, members: [LLVMMetadataRef?]) -> LLVMMetadataRef? {
        var elems = members
        return elems.withUnsafeMutableBufferPointer {
            LLVMDIBuilderCreateStructType(di, diCU, name, name.utf8.count, diFile, 0, sizeBits, 0,
                                          LLVMDIFlagZero, nil, $0.baseAddress, UInt32(members.count),
                                          0, nil, "", 0)
        }
    }

    // Attach a `DILocalVariable` + `llvm.dbg.declare` to `addr` (the variable's storage), so a
    // debugger can read it. `argNo` marks a parameter (1-based); nil is an ordinary local. No-op
    // when there's no scope or the type is unmodeled.
    private func declareLocal(_ name: String, type: Type, addr: LLVMValueRef, line: Int, argNo: Int? = nil) {
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

    // MARK: - Types

    private func structType(_ name: String) -> LLVMTypeRef? {
        if let t = structTypes[name] { return t }
        guard let s = structMap[name] else { return nil }
        let st = LLVMStructCreateNamed(ctx, "struct.\(name)")!
        structTypes[name] = st   // cache before filling (value structs never self-nest, but be safe)
        var elems: [LLVMTypeRef] = []
        for f in s.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        setStructBody(st, elems)
        return st
    }

    private func llvmType(_ t: Type, _ span: Span) -> LLVMTypeRef? {
        switch t {
        case .int, .bool: return i64
        case .string:     return strTy
        case .void:       return voidTy
        case .function:   return closureTy   // a closure value is { fn, env }
        case .named(let n, .struct_):
            if let st = structType(n) { return st }
            fail("8.2.2: unknown struct '\(n)'", span)
            return nil
        case .named(let n, .enum_):
            if let et = enumType(n) { return et }
            fail("8.2.3: unknown enum '\(n)'", span)
            return nil
        case .named(let n, .class_):
            if classMap[n] != nil { return i8ptr }   // a class value is a pointer to its object
            fail("8.2.4: unknown class '\(n)'", span)
            return nil
        case .named(let n, .actor_):
            if actorMap[n] != nil { return i8ptr }    // an actor handle is a pointer to its object
            fail("8.2.6: unknown actor '\(n)'", span)
            return nil
        case .existential, .composition:
            return anyBoxTy                          // `any I` / `any A & B` — a { witness, payload } box
        case .opaque:
            let u = concreteUnderlying(t)
            if case .opaque = u { fail("8.2.5: opaque type with no known underlying", span); return nil }
            return llvmType(u, span)                 // `some I` is unboxed — the concrete underlying's type
        default:
            fail("8.2.4: unsupported type '\(t)'", span)
            return nil
        }
    }

    // A class object is `{ i64 header /*ObjectHeader.refcount*/, fields… }`, heap-allocated. The
    // header slot mirrors the runtime's `ObjectHeader`; under bump-and-leak it is unused (the M6
    // GC will). Field index i is therefore at aggregate index i+1.
    private func classType(_ name: String) -> LLVMTypeRef? {
        if let t = classTypes[name] { return t }
        guard let c = classMap[name] else { return nil }
        let ct = LLVMStructCreateNamed(ctx, "class.\(name)")!
        classTypes[name] = ct
        var elems: [LLVMTypeRef] = [i64]   // ObjectHeader
        for f in c.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        setStructBody(ct, elems)
        return ct
    }

    // An actor object is `{ i64 header, fields…, i8* mu }`, heap-allocated. Fields sit at index i+1
    // (past the header, like a class); the trailing slot holds an opaque runtime mutex pointer that
    // every handler locks. Layout is internal to the LLVM object (it never crosses the runtime C
    // ABI), so it need not match `CodegenIR`'s inlined `pthread_mutex_t`.
    private func actorType(_ name: String) -> LLVMTypeRef? {
        if let t = actorTypes[name] { return t }
        guard let a = actorMap[name] else { return nil }
        let at = LLVMStructCreateNamed(ctx, "actor.\(name)")!
        actorTypes[name] = at
        var elems: [LLVMTypeRef] = [i64]   // ObjectHeader
        for f in a.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        elems.append(i8ptr)   // mu
        setStructBody(at, elems)
        return at
    }

    // The index of an actor's mutex slot (after the header and every field).
    private func actorMuIndex(_ name: String) -> Int { (actorMap[name]?.fields.count ?? 0) + 1 }

    // The aggregate type, kind, and fields of a named struct/class.
    private func aggInfo(_ typeName: String) -> (ty: LLVMTypeRef, kind: AggKind, fields: [IRField])? {
        if let s = structMap[typeName], let t = structType(typeName) { return (t, .structVal, s.fields) }
        if let c = classMap[typeName], let t = classType(typeName) { return (t, .classRef, c.fields) }
        return nil
    }

    private func fieldLLVMIndex(_ kind: AggKind, _ fieldPos: Int) -> Int {
        kind == .classRef ? fieldPos + 1 : fieldPos   // classes reserve index 0 for the header
    }

    // An enum lowers to `{ i64 tag, [P x i64] payload }`. All supported field types are 8-aligned
    // and a multiple of 8 bytes, so a case's storage is exactly its field-slot count; P is the
    // largest case's. Payload fields are read/written by GEPing the case's struct type over the
    // payload region (opaque pointers make the reinterpretation free). This layout is internal to
    // the LLVM object (enums never cross the runtime C ABI), so it need not match `CodegenIR`'s.
    private func enumType(_ name: String) -> LLVMTypeRef? {
        if let t = enumTypes[name] { return t }
        guard let e = enumMap[name] else { return nil }
        let et = LLVMStructCreateNamed(ctx, "enum.\(name)")!
        enumTypes[name] = et
        let slots = e.cases.map { caseSlots($0) }.max() ?? 0
        setStructBody(et, [i64, LLVMArrayType2(i64, UInt64(slots))])
        return et
    }

    // The struct of a case's payload field types — GEP'd over the enum's payload region.
    private func caseStructType(_ enumName: String, _ c: IREnumCase) -> LLVMTypeRef? {
        var elems: [LLVMTypeRef] = []
        for f in c.fields {
            guard let t = llvmType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return structTy(elems)
    }

    private func caseSlots(_ c: IREnumCase) -> Int { c.fields.reduce(0) { $0 + slotCount($1.type) } }

    // 8-byte slots a value occupies in an enum payload. Every supported leaf is 8-aligned, so a
    // struct/enum is just the sum/tag+max of its parts — no padding to account for.
    private func slotCount(_ t: Type) -> Int {
        switch t {
        case .int, .bool: return 1
        case .string:     return 2
        case .function:   return 2   // { fn, env }
        case .existential, .composition: return 2   // { witness, payload }
        case .opaque:     return slotCount(concreteUnderlying(t))
        case .named(_, .class_), .named(_, .actor_): return 1   // a pointer
        case .named(let n, .struct_): return structMap[n]?.fields.reduce(0) { $0 + slotCount($1.type) } ?? 1
        case .named(let n, .enum_):   return 1 + (enumMap[n]?.cases.map { caseSlots($0) }.max() ?? 0)
        default: return 1
        }
    }

    // MARK: - Callable declaration + definition

    private func declareFree(_ name: String) {
        let key = "f:\(name)"
        guard callables[key] == nil, let f = funcMap[name] else { return }
        let llvmName = name == "main" ? "nomu_main" : "nomu_fn_\(name)"
        declareCallable(key: key, llvmName: llvmName, ir: f, selfType: nil, selfByPointer: false)
    }

    private func declareMethod(_ typeName: String, _ method: String) {
        let key = "m:\(typeName):\(method)"
        guard callables[key] == nil else { return }
        guard let f = typeMethods(typeName).first(where: { $0.name == method }) else {
            fail("8.2.3: unknown method '\(typeName).\(method)'", Span(file: "", begin: Pos(line: 0, col: 0), end: Pos(line: 0, col: 0)))
            return
        }
        let sanitized = method.replacingOccurrences(of: ".", with: "_")
        // A class is a reference type: `self` is always the object pointer. A struct/enum passes
        // `self` by pointer only when the method mutates it.
        let byPointer = classMap[typeName] != nil || f.isMutating
        declareCallable(key: key, llvmName: "nomu_m_\(typeName)_\(sanitized)",
                        ir: f, selfType: typeName, selfByPointer: byPointer)
    }

    private func typeMethods(_ typeName: String) -> [IRFunc] {
        structMap[typeName]?.methods ?? enumMap[typeName]?.methods ?? classMap[typeName]?.methods ?? []
    }

    // The aggregate pointee type used for a `self` parameter. A class always passes `self` by
    // pointer, so this is the class object type; structs/enums pass the value type.
    private func selfLLVMType(_ typeName: String) -> LLVMTypeRef? {
        if structMap[typeName] != nil { return structType(typeName) }
        if enumMap[typeName] != nil { return enumType(typeName) }
        if classMap[typeName] != nil { return classType(typeName) }
        if actorMap[typeName] != nil { return actorType(typeName) }
        return nil
    }

    // An actor `on`-handler, declared on demand: `self` is the object pointer (a reference type,
    // like a class), the body mutex-serialized (defineBody brackets it with lock/unlock).
    private func declareActorHandler(_ actorName: String, _ handler: String) {
        let key = "m:\(actorName):\(handler)"
        guard callables[key] == nil else { return }
        guard let h = actorMap[actorName]?.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", zeroSpan)
            return
        }
        let f = IRFunc(name: h.name, params: h.params, returnType: h.returnType,
                       body: h.body, isMutating: true, span: h.span)
        declareCallable(key: key, llvmName: "nomu_on_\(actorName)_\(handler)",
                        ir: f, selfType: actorName, selfByPointer: true, isActorHandler: true)
    }

    private func declareCallable(key: String, llvmName: String, ir f: IRFunc,
                                 selfType: String?, selfByPointer: Bool, isActorHandler: Bool = false) {
        guard let retTy = llvmType(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        if let selfType = selfType {
            guard let st = selfLLVMType(selfType) else { return }
            paramTys.append(selfByPointer ? LLVMPointerType(st, 0) : st)
        }
        for p in f.params {
            guard let t = llvmType(p.type, p.span) else { return }
            paramTys.append(t)
        }
        let (fn, fnTy) = emitFunction(llvmName, ret: retTy, params: paramTys,
                                      debug: (f.name, f.span.begin.line))
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType,
                                  selfByPointer: selfByPointer, isActorHandler: isActorHandler)
        pending.append(key)
    }

    private func defineBody(_ key: String) {
        guard let c = callables[key] else { return }
        let f = c.ir
        currentFn = c.fn
        let block = LLVMAppendBasicBlockInContext(ctx, c.fn, "entry")
        LLVMPositionBuilderAtEnd(b, block)

        let savedLocals = locals; let savedSelf = currentSelf
        let savedSpawns = spawnLocals; let savedActive = activeSpawns; let savedMu = currentActorMu
        let savedScope = currentScope
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        locals = [:]; currentSelf = nil; spawnLocals = [:]; activeSpawns = []; currentActorMu = nil
        // Adopt this function's subprogram + a live location before the prologue so its
        // instructions (self setup, actor lock) are covered.
        enterDebugScope(c.fn, line: f.span.begin.line)

        var paramBase: UInt32 = 0
        if let selfType = c.selfType, let st = selfLLVMType(selfType) {
            // A class or actor is a reference type: `self` is the object pointer, fields at index i+1.
            let isReference = classMap[selfType] != nil || actorMap[selfType] != nil
            let selfPtr = c.selfByPointer ? LLVMGetParam(c.fn, 0)!
                                          : { let s = LLVMBuildAlloca(b, st, "self")!
                                              LLVMBuildStore(b, LLVMGetParam(c.fn, 0), s); return s }()
            let fields = structMap[selfType]?.fields ?? classMap[selfType]?.fields
                ?? actorMap[selfType]?.fields.map { IRField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) }
                ?? []
            currentSelf = SelfCtx(fields: fields, kind: isReference ? .classRef : .structVal,
                                  llvmTy: st, addr: selfPtr)
            if isReference {
                // `self` as a value is the object pointer; keep it in a ptr slot for `varRef self`.
                let slot = LLVMBuildAlloca(b, i8ptr, "self")!
                LLVMBuildStore(b, selfPtr, slot)
                locals["self"] = (slot, i8ptr)
            } else {
                locals["self"] = (selfPtr, st)   // loading the slot yields the struct/enum value
            }
            paramBase = 1

            let selfKind: NamedKind = structMap[selfType] != nil ? .struct_
                : classMap[selfType] != nil ? .class_
                : enumMap[selfType] != nil ? .enum_ : .actor_
            if let selfSlot = locals["self"]?.addr {
                declareLocal("self", type: .named(selfType, selfKind), addr: selfSlot,
                             line: f.span.begin.line, argNo: 1)
            }

            // An actor handler runs under the actor's mutex — lock at entry, unlock at every exit.
            if c.isActorHandler {
                let muAddr = structGEP(st, selfPtr, actorMuIndex(selfType))
                let mu = LLVMBuildLoad2(b, i8ptr, muAddr, "mu")!
                let lock = runtimeFn("rt_mutex_lock", ret: voidTy, params: [i8ptr], varArg: false)
                _ = buildCall(lock.0, lock.1, [mu])
                currentActorMu = mu
            }
        }

        for (i, p) in f.params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(c.fn, UInt32(i) + paramBase), slot)
            locals[p.name] = (slot, t)
            declareLocal(p.name, type: p.type, addr: slot, line: p.span.begin.line,
                         argNo: i + Int(paramBase) + 1)
        }
        lowerBlock(f.body)
        if !blockTerminated() {
            joinActiveSpawns()
            unlockActorIfNeeded()
            if f.returnType == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        locals = savedLocals; currentSelf = savedSelf
        spawnLocals = savedSpawns; activeSpawns = savedActive; currentActorMu = savedMu
        currentScope = savedScope
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

    // Join every fiber the current function spawned — the structured-concurrency guarantee that no
    // child outlives the scope. `spawn_join` is idempotent, so re-joining an already-read spawn is safe.
    private func joinActiveSpawns() {
        let sj = runtimeFn("spawn_join", ret: i8ptr, params: [i8ptr], varArg: false)
        for s in activeSpawns { _ = buildCall(sj.0, sj.1, [s.handleSlot]) }
    }

    private func unlockActorIfNeeded() {
        guard let mu = currentActorMu else { return }
        let un = runtimeFn("rt_mutex_unlock", ret: voidTy, params: [i8ptr], varArg: false)
        _ = buildCall(un.0, un.1, [mu])
    }

    private func blockTerminated() -> Bool {
        LLVMGetBasicBlockTerminator(LLVMGetInsertBlock(b)) != nil
    }

    // MARK: - Statements

    private func lowerBlock(_ stmts: [IRStmt]) {
        for s in stmts {
            if error != nil || blockTerminated() { return }
            lowerStmt(s)
        }
    }

    private func lowerStmt(_ stmt: IRStmt) {
        setDebugLoc(stmt.span)   // 8.3: line-table entry; inherited by this statement's instructions
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            guard let ty = llvmType(value.type, stmt.span), let v = lowerExpr(value) else { return }
            let slot = LLVMBuildAlloca(b, ty, name)!
            LLVMBuildStore(b, v, slot)
            locals[name] = (slot, ty)
            declareLocal(name, type: value.type, addr: slot, line: stmt.span.begin.line)

        case .assign(let target, let value):
            guard let dst = lvalue(target) else { return }
            guard let v = lowerExpr(value) else { return }
            LLVMBuildStore(b, v, dst.addr)

        case .compoundAssign(let target, let value):
            // Nomu's only compound assignment is `+=`, on Int (CodegenIR emits `l += r`).
            guard let dst = lvalue(target) else { return }
            guard let v = lowerExpr(value) else { return }
            let cur = LLVMBuildLoad2(b, dst.ty, dst.addr, "cur")
            LLVMBuildStore(b, LLVMBuildAdd(b, cur, v, "add"), dst.addr)

        case .ret(let e):
            // A returned value is computed before joins/unlock so its own spawn reads happen first.
            let v = e != nil ? lowerExpr(e!) : nil
            if e != nil, v == nil { return }
            joinActiveSpawns()
            unlockActorIfNeeded()
            if let v = v { LLVMBuildRet(b, v) } else { LLVMBuildRetVoid(b) }

        case .spawnLet(let name, let value, let resultType):
            lowerSpawnLet(name: name, value: value, resultType: resultType, span: stmt.span)

        case .ifStmt(let cond, let then, let els):
            lowerIf(cond: cond, then: then, els: els)

        case .switchStmt(let sw):
            lowerSwitch(sw)

        case .exprStmt(let e):
            _ = lowerExpr(e)
        }
    }

    private func lowerIf(cond: IRExpr, then: [IRStmt], els: [IRStmt]?) {
        guard let fn = currentFn, let condV = lowerExpr(cond) else { return }
        let condBit = LLVMBuildICmp(b, LLVMIntNE, condV, LLVMConstInt(i64, 0, 0), "cond")
        let thenBB = LLVMAppendBasicBlockInContext(ctx, fn, "then")
        let elseBB = els != nil ? LLVMAppendBasicBlockInContext(ctx, fn, "else") : nil
        let mergeBB = LLVMAppendBasicBlockInContext(ctx, fn, "ifcont")

        LLVMBuildCondBr(b, condBit, thenBB, elseBB ?? mergeBB)

        LLVMPositionBuilderAtEnd(b, thenBB)
        var saved = locals; lowerBlock(then); locals = saved
        if !blockTerminated() { LLVMBuildBr(b, mergeBB) }

        if let els = els, let elseBB = elseBB {
            LLVMPositionBuilderAtEnd(b, elseBB)
            saved = locals; lowerBlock(els); locals = saved
            if !blockTerminated() { LLVMBuildBr(b, mergeBB) }
        }
        LLVMPositionBuilderAtEnd(b, mergeBB)
    }

    // MARK: - Expressions

    private func lowerExpr(_ e: IRExpr) -> LLVMValueRef? {
        switch e.kind {
        case .intLit(let n):
            return LLVMConstInt(i64, UInt64(bitPattern: Int64(n)), /*SignExtend=*/1)
        case .boolLit(let v):
            return LLVMConstInt(i64, v ? 1 : 0, 0)
        case .stringLit(let s):
            return lowerStringLit(s)
        case .varRef(let name) where spawnLocals[name] != nil:
            return joinSpawn(name)
        case .varRef, .fieldAccess:
            guard let lv = lvalue(e) else { return nil }
            return LLVMBuildLoad2(b, lv.ty, lv.addr, "ld")
        case .binary(let op, let l, let r):
            return lowerBinary(op, l, r)
        case .construct(let typeName, let args):
            return lowerConstruct(typeName, args, e.span)
        case .enumInit(let typeName, let caseName, let args):
            return lowerEnumInit(typeName, caseName, args, e.span)
        case .methodCall(let receiver, let method, let args):
            return lowerMethodCall(receiver: receiver, method: method, args: args,
                                   resultType: e.type, span: e.span)
        case .call(let callee, let args, _):
            return lowerCall(callee: callee, args: args, span: e.span)
        case .closure(let params, let body):
            var ret = Type.void
            if case .function(_, let r) = e.type { ret = r }
            return lowerClosure(params: params, body: body, ret: ret, span: e.span)
        case .box(let value, let interfaces):
            return lowerBox(value, interfaces, e.span)
        }
    }

    // The address of an assignable/aggregate expression. A local or self-field yields its slot; a
    // field access GEPs into its base's address; any other value is spilled to a temp alloca so a
    // field read off an rvalue (e.g. `makePoint().x`) still works.
    private func lvalue(_ e: IRExpr) -> (addr: LLVMValueRef, ty: LLVMTypeRef)? {
        switch e.kind {
        case .varRef(let name):
            if let l = locals[name] { return l }
            if let cs = currentSelf, let pos = cs.fields.firstIndex(where: { $0.name == name }) {
                guard let fieldTy = llvmType(cs.fields[pos].type, e.span) else { return nil }
                return (structGEP(cs.llvmTy, cs.addr, fieldLLVMIndex(cs.kind, pos)), fieldTy)
            }
            fail("8.2.4: unknown variable '\(name)'", e.span)
            return nil
        case .fieldAccess(let base, let field):
            guard case .named(let typeName, _) = base.type, let info = aggInfo(typeName),
                  let pos = info.fields.firstIndex(where: { $0.name == field }) else {
                fail("8.2.4: field access on a non-aggregate", e.span)
                return nil
            }
            // A struct's base is addressable (its value lives in memory); a class's value *is* the
            // object pointer, so GEP off that directly (past the header).
            let basePtr: LLVMValueRef
            if info.kind == .classRef {
                guard let bv = lowerExpr(base) else { return nil }
                basePtr = bv
            } else {
                guard let ba = lvalue(base) else { return nil }
                basePtr = ba.addr
            }
            guard let fieldTy = llvmType(info.fields[pos].type, e.span) else { return nil }
            return (structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos)), fieldTy)
        default:
            // An rvalue (e.g. a call result): materialize it in a temp so it has an address.
            guard let ty = llvmType(e.type, e.span), let v = lowerExpr(e) else { return nil }
            let slot = LLVMBuildAlloca(b, ty, "tmp")!
            LLVMBuildStore(b, v, slot)
            return (slot, ty)
        }
    }

    private func lowerBinary(_ op: BinOp, _ l: IRExpr, _ r: IRExpr) -> LLVMValueRef? {
        guard let lv = lowerExpr(l), let rv = lowerExpr(r) else { return nil }
        switch op {
        case .add: return LLVMBuildAdd(b, lv, rv, "add")
        case .sub: return LLVMBuildSub(b, lv, rv, "sub")
        case .mul: return LLVMBuildMul(b, lv, rv, "mul")
        case .div: return LLVMBuildSDiv(b, lv, rv, "div")
        case .eq, .neq, .lt, .gt, .lte, .gte:
            // Comparisons on Int yield Bool (i64 0/1): icmp → i1, then zext.
            let pred: LLVMIntPredicate
            switch op {
            case .eq:  pred = LLVMIntEQ
            case .neq: pred = LLVMIntNE
            case .lt:  pred = LLVMIntSLT
            case .gt:  pred = LLVMIntSGT
            case .lte: pred = LLVMIntSLE
            default:   pred = LLVMIntSGE   // .gte
            }
            return LLVMBuildZExt(b, LLVMBuildICmp(b, pred, lv, rv, "cmp"), i64, "cmpi")
        }
    }

    private func lowerConstruct(_ typeName: String, _ args: [IRArg], _ span: Span) -> LLVMValueRef? {
        if let s = structMap[typeName], let st = structType(typeName) {
            var agg = LLVMGetUndef(st)
            for (idx, field) in s.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                agg = LLVMBuildInsertValue(b, agg, v, UInt32(idx), "")
            }
            return agg
        }
        if let c = classMap[typeName], let ct = classType(typeName) {
            // Heap-allocate the object (rt_alloc, bump-and-leak), then store each field past the
            // header. The class value is the returned pointer (reference semantics).
            let slots = 1 + c.fields.reduce(0) { $0 + slotCount($1.type) }
            let obj = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(slots * 8), 0)])!
            for (idx, field) in c.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                LLVMBuildStore(b, v, structGEP(ct, obj, fieldLLVMIndex(.classRef, idx)))
            }
            return obj
        }
        if let a = actorMap[typeName], let at = actorType(typeName) {
            // Heap-allocate the object, initialize each field (a declared initializer, else the
            // matching constructor argument), then install a fresh runtime mutex in the last slot.
            let slots = 2 + a.fields.reduce(0) { $0 + slotCount($1.type) }   // header + fields + mu
            let obj = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(slots * 8), 0)])!
            for (idx, field) in a.fields.enumerated() {
                let v: LLVMValueRef?
                if let initE = field.initializer { v = lowerExpr(initE) }
                else { v = constructActorField(field, args, typeName, span) }
                guard let fv = v else { return nil }
                LLVMBuildStore(b, fv, structGEP(at, obj, fieldLLVMIndex(.classRef, idx)))
            }
            let muNew = runtimeFn("rt_mutex_new", ret: i8ptr, params: [], varArg: false)
            let mu = buildCall(muNew.0, muNew.1, [])!
            LLVMBuildStore(b, mu, structGEP(at, obj, actorMuIndex(typeName)))
            return obj
        }
        fail("8.2.6: cannot construct '\(typeName)' (not a struct, class, or actor)", span)
        return nil
    }

    private func constructActorField(_ field: IRActorField, _ args: [IRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.6: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    private func constructField(_ field: IRField, _ args: [IRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.4: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    // Build an enum value in a temp: store the case index as the tag, then each payload field via
    // the case's struct type GEP'd over the payload region; return the loaded aggregate.
    private func lowerEnumInit(_ typeName: String, _ caseName: String, _ args: [IRArg], _ span: Span) -> LLVMValueRef? {
        guard let et = enumType(typeName), let e = enumMap[typeName],
              let caseIdx = e.cases.firstIndex(where: { $0.name == caseName }) else {
            fail("8.2.3: cannot construct '\(typeName).\(caseName)'", span)
            return nil
        }
        let c = e.cases[caseIdx]
        let slot = LLVMBuildAlloca(b, et, "enum")!
        LLVMBuildStore(b, LLVMConstInt(i64, UInt64(caseIdx), 0), structGEP(et, slot, 0))
        if !c.fields.isEmpty {
            guard let cst = caseStructType(typeName, c) else { return nil }
            let payload = structGEP(et, slot, 1)
            for (idx, field) in c.fields.enumerated() {
                guard let arg = args.first(where: { $0.label == field.name }) else {
                    fail("8.2.3: missing payload field '\(field.name)' for '\(typeName).\(caseName)'", span)
                    return nil
                }
                guard let v = lowerExpr(arg.value) else { return nil }
                LLVMBuildStore(b, v, structGEP(cst, payload, idx))
            }
        }
        return LLVMBuildLoad2(b, et, slot, "enumv")
    }

    // switch on the enum tag: an LLVM `switch` with one block per arm (exhaustive → default is
    // unreachable). Each arm binds its payload fields (as local copies) then lowers its body.
    private func lowerSwitch(_ sw: IRSwitch) {
        guard let fn = currentFn else { return }
        guard case .named(let enumName, .enum_) = sw.subject.type,
              let e = enumMap[enumName], let et = enumType(enumName) else {
            fail("8.2.3: switch subject must be a concrete enum", sw.subject.span)
            return
        }
        guard let subj = lvalue(sw.subject) else { return }
        let tag = LLVMBuildLoad2(b, i64, structGEP(et, subj.addr, 0), "tag")

        let defaultBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.default")
        let mergeBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.merge")
        let inst = LLVMBuildSwitch(b, tag, defaultBB, UInt32(sw.arms.count))

        for arm in sw.arms {
            guard let caseIdx = e.cases.firstIndex(where: { $0.name == arm.caseName }) else { continue }
            let c = e.cases[caseIdx]
            let armBB = LLVMAppendBasicBlockInContext(ctx, fn, "sw.\(arm.caseName)")
            LLVMAddCase(inst, LLVMConstInt(i64, UInt64(caseIdx), 0), armBB)
            LLVMPositionBuilderAtEnd(b, armBB)

            let saved = locals
            if !arm.bindings.isEmpty, let cst = caseStructType(enumName, c) {
                let payload = structGEP(et, subj.addr, 1)
                for (i, binding) in arm.bindings.enumerated() {
                    guard let bty = llvmType(binding.type, sw.subject.span) else { break }
                    let val = LLVMBuildLoad2(b, bty, structGEP(cst, payload, i), binding.name)
                    let bslot = LLVMBuildAlloca(b, bty, binding.name)!
                    LLVMBuildStore(b, val, bslot)
                    locals[binding.name] = (bslot, bty)
                    declareLocal(binding.name, type: binding.type, addr: bslot, line: sw.subject.span.begin.line)
                }
            }
            lowerBlock(arm.body)
            if !blockTerminated() { LLVMBuildBr(b, mergeBB) }
            locals = saved
        }

        LLVMPositionBuilderAtEnd(b, defaultBB)
        LLVMBuildUnreachable(b)
        LLVMPositionBuilderAtEnd(b, mergeBB)
    }

    private func lowerMethodCall(receiver: IRExpr, method: String, args: [IRExpr],
                                 resultType: Type, span: Span) -> LLVMValueRef? {
        // Requirement call through `any I` — dispatch dynamically via the box's witness slot.
        if case .existential(let iface) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let witnessPtr = LLVMBuildExtractValue(b, box, 0, "wt")!
            let payload = LLVMBuildExtractValue(b, box, 1, "pl")!
            return witnessDispatch(witnessPtr: witnessPtr, iface: iface, method: method,
                                   payload: payload, args: args, resultType: resultType, span: span)
        }
        // Through `any A & B` — the witness is a composite struct; load the owning interface's
        // sub-table, then dispatch through its slot.
        if case .composition(let ifaces) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let compPtr = LLVMBuildExtractValue(b, box, 0, "wt")!
            let payload = LLVMBuildExtractValue(b, box, 1, "pl")!
            let owner = compositionOwner(ifaces, method)
            guard let ownerIdx = ifaces.firstIndex(of: owner) else {
                fail("8.2.5: no interface owns '\(method)' in composition", span); return nil
            }
            let subAddr = structGEP(compositeType(ifaces), compPtr, ownerIdx)
            let subTable = LLVMBuildLoad2(b, i8ptr, subAddr, "sub")!
            return witnessDispatch(witnessPtr: subTable, iface: owner, method: method,
                                   payload: payload, args: args, resultType: resultType, span: span)
        }

        // A concrete receiver, or a `some I` opaque one devirtualized to its known underlying.
        let recvType = concreteUnderlying(receiver.type)
        guard case .named(let typeName, let kind) = recvType,
              kind == .struct_ || kind == .enum_ || kind == .class_ || kind == .actor_ else {
            fail("8.2.5: only concrete/any/some method calls are supported", span)
            return nil
        }

        // A `some I` property read arrives as `prop.get`; when the underlying backs it with a
        // stored field, that's a direct field load (mirrors the witness thunk's stored-field path).
        if method.hasSuffix(".get") {
            let prop = String(method.dropLast(4))
            if let info = aggInfo(typeName), let pos = info.fields.firstIndex(where: { $0.name == prop }) {
                guard let fieldTy = llvmType(info.fields[pos].type, span) else { return nil }
                let basePtr: LLVMValueRef
                if info.kind == .classRef {
                    guard let bv = lowerExpr(receiver) else { return nil }
                    basePtr = bv
                } else {
                    guard let ba = lvalue(receiver) else { return nil }
                    basePtr = ba.addr
                }
                return LLVMBuildLoad2(b, fieldTy, structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos)), "ld")
            }
        }

        if kind == .actor_ { declareActorHandler(typeName, method) }
        else { declareMethod(typeName, method) }
        guard let c = callables["m:\(typeName):\(method)"] else { return nil }

        // How `self` reaches the callee: a class/actor receiver's value already *is* the object
        // pointer; a struct/enum mutating method wants the address of the (mutable) receiver value;
        // a read-only value method takes a copy of the value.
        let selfArg: LLVMValueRef?
        if kind == .class_ || kind == .actor_ {
            selfArg = lowerExpr(receiver)
        } else if c.selfByPointer {
            selfArg = lvalue(receiver)?.addr
        } else {
            selfArg = lowerExpr(receiver)
        }
        guard let selfVal = selfArg else { return nil }

        var argVals: [LLVMValueRef?] = [selfVal]
        for a in args {
            guard let v = lowerExpr(a) else { return nil }
            argVals.append(v)
        }
        return buildCall(c.fn, c.ty, argVals)
    }

    // MARK: - Witness tables + `any`/`some` (8.2.5)

    // Resolve a `some I` opaque type to its hidden concrete underlying (known to codegen, M5 A3);
    // everything else passes through unchanged.
    private func concreteUnderlying(_ t: Type) -> Type {
        if case .opaque(_, let owner) = t, let u = opaqueUnderlyings[owner] { return u }
        return t
    }

    private func namedKind(_ type: String) -> NamedKind {
        if enumMap[type] != nil { return .enum_ }
        if classMap[type] != nil { return .class_ }
        return .struct_
    }

    // The witness slots of an interface, in the layout order: each method requirement, then each
    // property's `_get` (and `_set` if settable), then a `base_<B>` per transitive base, then the
    // reserved `type_witness`. Every slot is a pointer, so the witness struct is N pointers and a
    // slot is reached by its index here.
    private func witnessSlots(_ iface: String) -> [String] {
        if let cached = witnessSlotsCache[iface] { return cached }
        guard let i = interfaceDefs[iface] else { return ["type_witness"] }
        var slots = i.methods.map(\.name)
        for p in i.properties {
            slots.append("\(p.name)_get")
            if p.isSettable { slots.append("\(p.name)_set") }
        }
        for b in i.bases { slots.append("base_\(b)") }
        slots.append("type_witness")
        witnessSlotsCache[iface] = slots
        return slots
    }

    private func witnessSlotIndex(_ iface: String, _ slot: String) -> Int {
        witnessSlots(iface).firstIndex(of: slot) ?? -1
    }

    // The witness struct type for an interface — one `ptr` slot per `witnessSlots` entry.
    private func witnessType(_ iface: String) -> LLVMTypeRef {
        if let t = witnessTypes[iface] { return t }
        let n = max(witnessSlots(iface).count, 1)
        let st = LLVMStructCreateNamed(ctx, "witness.\(iface)")!
        setStructBody(st, [LLVMTypeRef](repeating: i8ptr, count: n))
        witnessTypes[iface] = st
        return st
    }

    // The witness-table instance for a conformance `type: iface`, an internal LLVM global built on
    // demand: a struct of thunk function pointers (uniform `void*`-self signatures), base-witness
    // pointers, and the reserved type-witness. The global is cached before its slots are filled so
    // a base pointer can reference the same conformer's (recursively built) base witnesses.
    private func witnessInstance(_ type: String, _ iface: String) -> LLVMValueRef? {
        let key = "\(type)::\(iface)"
        if let g = witnessGlobals[key] { return g }
        guard let idef = interfaceDefs[iface] else {
            fail("8.2.5: unknown interface '\(iface)'", zeroSpan); return nil
        }
        let wt = witnessType(iface)
        let g = LLVMAddGlobal(mod, wt, "wt_\(type)_\(iface)")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        witnessGlobals[key] = g   // cache before recursion into base witnesses

        var vals: [LLVMValueRef?] = []
        for m in idef.methods {
            guard let thunk = methodThunk(type, iface, m) else { return nil }
            vals.append(thunk)
        }
        for p in idef.properties {
            guard let getT = propThunk(type, iface, p, setter: false) else { return nil }
            vals.append(getT)
            if p.isSettable {
                guard let setT = propThunk(type, iface, p, setter: true) else { return nil }
                vals.append(setT)
            }
        }
        for base in idef.bases {
            guard let bw = witnessInstance(type, base) else { return nil }
            vals.append(bw)
        }
        vals.append(LLVMConstPointerNull(i8ptr))   // type_witness (reserved)
        LLVMSetInitializer(g, constStruct(wt, vals))
        return g
    }

    // Bridge a thunk's `payload` pointer to the impl's `self`: a by-pointer (mutating/class) method
    // takes it directly; a by-value method loads the concrete value out of it.
    private func bridgeThunkSelf(_ payload: LLVMValueRef, _ type: String, _ c: Callable) -> LLVMValueRef? {
        if c.selfByPointer { return payload }
        guard let st = selfLLVMType(type) else { return nil }
        return LLVMBuildLoad2(b, st, payload, "self")
    }

    // A uniform-signature thunk `ret(ptr self, params…)` wrapping the concrete impl: it bridges
    // `self` (the payload pointer) to the impl's ABI — by value for a read-only value method, by
    // pointer for a mutating / class method — and re-boxes a covariant-`Self` result as `any iface`.
    private func methodThunk(_ type: String, _ iface: String, _ m: IRMethodReq) -> LLVMValueRef? {
        guard let retTy = llvmType(m.ret, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]
        for pt in m.params {
            guard let t = llvmType(pt, zeroSpan) else { return nil }
            paramTys.append(t)
        }
        let sname = m.name.replacingOccurrences(of: ".", with: "_")
        let (fn, _) = emitFunction("wt_\(type)_\(iface)_\(sname)", ret: retTy, params: paramTys)

        let saved = enterThunk(fn)
        defer { leaveThunk(saved) }

        declareMethod(type, m.name)
        guard let c = callables["m:\(type):\(m.name)"] else { return nil }
        guard let selfArg = bridgeThunkSelf(LLVMGetParam(fn, 0)!, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        for i in 0..<m.params.count { callArgs.append(LLVMGetParam(fn, UInt32(i + 1))) }
        guard let result = buildCall(c.fn, c.ty, callArgs) else { return nil }

        if case .existential = m.ret {
            // Covariant `Self`: the impl returns the concrete conformer; re-box it as `any iface`.
            guard let w = witnessInstance(type, iface),
                  let pl = boxPayload(result, .named(type, namedKind(type))) else { return nil }
            LLVMBuildRet(b, makeAnyBox(w, pl))
        } else if m.ret == .void {
            LLVMBuildRetVoid(b)
        } else {
            LLVMBuildRet(b, result)
        }
        return fn
    }

    // A property get/set thunk. A stored-field-backed requirement is a direct field load/store; a
    // computed one routes through the concrete accessor method (`prop.get` / `prop.set`).
    private func propThunk(_ type: String, _ iface: String, _ p: IRPropReq, setter: Bool) -> LLVMValueRef? {
        guard let propTy = llvmType(p.type, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]
        if setter { paramTys.append(propTy) }
        let slot = setter ? "\(p.name)_set" : "\(p.name)_get"
        let (fn, _) = emitFunction("wt_\(type)_\(iface)_\(slot)",
                                   ret: setter ? voidTy : propTy, params: paramTys)

        let saved = enterThunk(fn)
        defer { leaveThunk(saved) }
        let payload = LLVMGetParam(fn, 0)!

        if let info = aggInfo(type), let pos = info.fields.firstIndex(where: { $0.name == p.name }) {
            let addr = structGEP(info.ty, payload, fieldLLVMIndex(info.kind, pos))
            if setter {
                LLVMBuildStore(b, LLVMGetParam(fn, 1), addr)
                LLVMBuildRetVoid(b)
            } else {
                LLVMBuildRet(b, LLVMBuildLoad2(b, propTy, addr, "fld"))
            }
            return fn
        }

        let accessor = "\(p.name).\(setter ? "set" : "get")"
        declareMethod(type, accessor)
        guard let c = callables["m:\(type):\(accessor)"] else { return nil }
        guard let selfArg = bridgeThunkSelf(payload, type, c) else { return nil }
        var callArgs: [LLVMValueRef?] = [selfArg]
        if setter { callArgs.append(LLVMGetParam(fn, 1)) }
        let result = buildCall(c.fn, c.ty, callArgs)
        if setter { LLVMBuildRetVoid(b) } else { LLVMBuildRet(b, result!) }
        return fn
    }

    // The composite-witness struct type for `any A & B` — one `ptr` sub-table slot per interface.
    private func compositeType(_ ifaces: [String]) -> LLVMTypeRef {
        let key = ifaces.joined(separator: "&")
        if let t = compositeTypes[key] { return t }
        let st = LLVMStructCreateNamed(ctx, "comp.\(key)")!
        setStructBody(st, [LLVMTypeRef](repeating: i8ptr, count: max(ifaces.count, 1)))
        compositeTypes[key] = st
        return st
    }

    // The composite-witness instance for `type: A & B` — a global holding one single-interface
    // witness pointer per interface.
    private func compositeInstance(_ type: String, _ ifaces: [String]) -> LLVMValueRef? {
        let key = "\(type)::\(ifaces.joined(separator: "&"))"
        if let g = compositeGlobals[key] { return g }
        let ct = compositeType(ifaces)
        let g = LLVMAddGlobal(mod, ct, "comp_\(type)_\(ifaces.joined(separator: "_"))")!
        LLVMSetLinkage(g, LLVMInternalLinkage)
        LLVMSetGlobalConstant(g, 1)
        compositeGlobals[key] = g
        var vals: [LLVMValueRef?] = []
        for i in ifaces {
            guard let w = witnessInstance(type, i) else { return nil }
            vals.append(w)
        }
        LLVMSetInitializer(g, constStruct(ct, vals))
        return g
    }

    // Which interface of a composition declares `method` (used to pick the owning sub-table).
    private func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        for i in ifaces where witnessSlots(i).contains(slot) { return i }
        return ifaces.first ?? "?"
    }

    // Load a requirement's function pointer from a witness table and call it, self (the payload)
    // first. The call type is taken from the site (result type + argument types) — consistent with
    // the thunk's signature, since both lower the same requirement types.
    private func witnessDispatch(witnessPtr: LLVMValueRef, iface: String, method: String,
                                 payload: LLVMValueRef, args: [IRExpr], resultType: Type,
                                 span: Span) -> LLVMValueRef? {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        let idx = witnessSlotIndex(iface, slot)
        guard idx >= 0 else { fail("8.2.5: no witness slot '\(slot)' in '\(iface)'", span); return nil }
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(iface), witnessPtr, idx), "slot")!

        guard let retTy = llvmType(resultType, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]
        var argVals: [LLVMValueRef?] = [payload]
        for a in args {
            guard let t = llvmType(a.type, span), let v = lowerExpr(a) else { return nil }
            paramTys.append(t); argVals.append(v)
        }
        return buildCall(fnPtr, fnType(retTy, paramTys), argVals)
    }

    // Wrap a concrete conformer as `any I` / `any A & B`, or upcast `any B` → `any A`.
    private func lowerBox(_ value: IRExpr, _ ifaces: [String], _ span: Span) -> LLVMValueRef? {
        // `any B` → `any A`: re-box through the source witness's base pointer, keeping the payload.
        if case .existential(let src) = value.type, ifaces.count == 1 {
            guard let box = lowerExpr(value) else { return nil }
            let witnessPtr = LLVMBuildExtractValue(b, box, 0, "wt")!
            let payload = LLVMBuildExtractValue(b, box, 1, "pl")!
            let idx = witnessSlotIndex(src, "base_\(ifaces[0])")
            guard idx >= 0 else { fail("8.2.5: '\(src)' has no base '\(ifaces[0])'", span); return nil }
            let base = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(src), witnessPtr, idx), "base")!
            return makeAnyBox(base, payload)
        }
        guard case .named(let t, _) = value.type else {
            fail("8.2.5: cannot box non-nominal value", span); return nil
        }
        guard let v = lowerExpr(value) else { return nil }
        let witness = ifaces.count == 1 ? witnessInstance(t, ifaces[0]) : compositeInstance(t, ifaces)
        guard let w = witness, let pl = boxPayload(v, value.type) else { return nil }
        return makeAnyBox(w, pl)
    }

    // The `any I` payload for a value: a reference type is its pointer; a value type is copied to a
    // fresh heap allocation so the pointer outlives the temporary (rt_alloc, leaked until the M6 GC).
    private func boxPayload(_ v: LLVMValueRef, _ t: Type) -> LLVMValueRef? {
        switch t {
        case .named(_, .class_), .named(_, .actor_):
            return v
        default:
            let bytes = max(slotCount(t) * 8, 8)
            let p = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(bytes), 0)])!
            LLVMBuildStore(b, v, p)
            return p
        }
    }

    private func makeAnyBox(_ witness: LLVMValueRef, _ payload: LLVMValueRef) -> LLVMValueRef {
        var box: LLVMValueRef = LLVMGetUndef(anyBoxTy)!
        box = LLVMBuildInsertValue(b, box, witness, 0, "")!
        box = LLVMBuildInsertValue(b, box, payload, 1, "")!
        return box
    }

    // Reposition the builder to a freshly built thunk, saving the enclosing lowering state; the
    // returned tuple is handed back to `leaveThunk` to restore it (thunks are built inline, mid-body).
    private struct ThunkState {
        let block: LLVMBasicBlockRef?
        let locals: [String: (addr: LLVMValueRef, ty: LLVMTypeRef)]
        let self_: SelfCtx?
        let fn: LLVMValueRef?
        let spawnLocals: [String: SpawnLocal]
        let activeSpawns: [SpawnLocal]
        let actorMu: LLVMValueRef?
        let scope: LLVMMetadataRef?
        let debugLoc: LLVMMetadataRef?
    }

    private func enterThunk(_ fn: LLVMValueRef, line: Int = 0) -> ThunkState {
        let saved = ThunkState(block: LLVMGetInsertBlock(b), locals: locals, self_: currentSelf, fn: currentFn,
                               spawnLocals: spawnLocals, activeSpawns: activeSpawns, actorMu: currentActorMu,
                               scope: currentScope, debugLoc: di != nil ? LLVMGetCurrentDebugLocation2(b) : nil)
        currentFn = fn; currentSelf = nil; locals = [:]
        spawnLocals = [:]; activeSpawns = []; currentActorMu = nil
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        enterDebugScope(fn, line: line)
        return saved
    }

    private func leaveThunk(_ saved: ThunkState) {
        locals = saved.locals; currentSelf = saved.self_; currentFn = saved.fn
        spawnLocals = saved.spawnLocals; activeSpawns = saved.activeSpawns; currentActorMu = saved.actorMu
        if let block = saved.block { LLVMPositionBuilderAtEnd(b, block) }
        currentScope = saved.scope
        if di != nil { LLVMSetCurrentDebugLocation2(b, saved.debugLoc) }
    }

    // A captured local: its name and the (addr, ty) slot it lives in in the enclosing scope. Shared
    // by closures and `spawn let`, which both copy free variables by value into a heap env.
    private typealias Capture = (name: String, local: (addr: LLVMValueRef, ty: LLVMTypeRef))

    // The free variables of `used` that name enclosing locals, de-duplicated in first-use order.
    private func resolveCaptures(_ used: [String]) -> [Capture] {
        var seen = Set<String>()
        return used.compactMap { name in
            guard seen.insert(name).inserted, let l = locals[name] else { return nil }
            return (name, l)
        }
    }

    // The env struct type holding the captures in order; an i8 placeholder when empty so `rt_alloc`
    // still has a nonzero size.
    private func captureEnvType(_ caps: [Capture]) -> LLVMTypeRef {
        structTy(caps.isEmpty ? [LLVMInt8TypeInContext(ctx)!] : caps.map { $0.local.ty })
    }

    // Inside a freshly entered thunk: copy each capture out of `env` into a fresh local slot.
    private func loadCapturesIntoScope(_ caps: [Capture], _ envTy: LLVMTypeRef, _ env: LLVMValueRef) {
        for (i, cap) in caps.enumerated() {
            let slot = LLVMBuildAlloca(b, cap.local.ty, cap.name)!
            let v = LLVMBuildLoad2(b, cap.local.ty, structGEP(envTy, env, i), cap.name)
            LLVMBuildStore(b, v, slot)
            locals[cap.name] = (slot, cap.local.ty)
        }
    }

    // At the capture site: heap-allocate the env and copy each capture's current value into it.
    private func allocAndFillEnv(_ caps: [Capture], _ envTy: LLVMTypeRef) -> LLVMValueRef {
        let bytes = caps.reduce(0) { $0 + abiSlots($1.local.ty) } * 8
        let envPtr = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(max(bytes, 8)), 0)])!
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            LLVMBuildStore(b, v, structGEP(envTy, envPtr, i))
        }
        return envPtr
    }

    // A closure lowers to a hoisted impl function `ret nomu_cloN(ptr env, params…)` plus a site
    // that heap-allocates the env (captures copied by value) and yields `{ fn, env }`. Captures
    // are the body's free variables that name enclosing locals (mirrors CodegenIR).
    private func lowerClosure(params: [IRParam], body: [IRStmt], ret: Type, span: Span) -> LLVMValueRef? {
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUses(body, bound: &bound, used: &used)
        let caps = resolveCaptures(used)
        let envTy = captureEnvType(caps)

        guard let retTy = llvmType(ret, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]   // env
        for p in params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            paramTys.append(t)
        }
        let (fn, _) = emitFunction("nomu_clo\(closureSeq)", ret: retTy, params: paramTys,
                                   debug: ("closure", span.begin.line))
        closureSeq += 1

        // Define the impl body against a fresh scope (captures loaded from env + params), then
        // restore the enclosing builder position and lowering state.
        // A fresh scope, including spawn/actor state — the body's `return` must not join the
        // enclosing function's spawns (that would reference its allocas from another function).
        let saved = enterThunk(fn, line: span.begin.line)
        loadCapturesIntoScope(caps, envTy, LLVMGetParam(fn, 0)!)
        for (i, p) in params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(fn, UInt32(i) + 1), slot)
            locals[p.name] = (slot, t)
            declareLocal(p.name, type: p.type, addr: slot, line: p.span.begin.line, argNo: i + 2)
        }
        lowerBlock(body)
        if !blockTerminated() {
            joinActiveSpawns()
            if ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        leaveThunk(saved)

        // Site: allocate + fill the env, then build the { fn, env } value.
        let envPtr = allocAndFillEnv(caps, envTy)
        var clo = LLVMGetUndef(closureTy)
        clo = LLVMBuildInsertValue(b, clo, fn, 0, "")
        clo = LLVMBuildInsertValue(b, clo, envPtr, 1, "")
        return clo
    }

    // MARK: - Structured concurrency (8.2.6)

    // `spawn let name = value` runs `value` on a fiber. Like a closure, the value's free variables
    // are captured by value into a heap env; a hoisted start routine `void* nomu_spawnN(void* env)`
    // computes the value and returns a heap box of the result. The site starts the fiber and stores
    // its handle; reads of `name` (and scope/function exit) join it.
    private func lowerSpawnLet(name: String, value: IRExpr, resultType: Type, span: Span) {
        var used: [String] = []
        collectUsesExpr(value, bound: [], used: &used)
        let caps = resolveCaptures(used)
        let envTy = captureEnvType(caps)

        guard let resultTy = llvmType(resultType, span) else { return }
        let (fn, _) = emitFunction("nomu_spawn\(spawnSeq)", ret: i8ptr, params: [i8ptr],
                                   debug: ("spawn", span.begin.line))
        spawnSeq += 1

        // The start routine: load captures from env, compute the value, box it, return the box.
        let saved = enterThunk(fn, line: span.begin.line)
        loadCapturesIntoScope(caps, envTy, LLVMGetParam(fn, 0)!)
        if let rv = lowerExpr(value) {
            let bytes = max(slotCount(resultType) * 8, 8)
            let boxp = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(bytes), 0)])!
            LLVMBuildStore(b, rv, boxp)
            LLVMBuildRet(b, boxp)
        } else if !blockTerminated() {
            LLVMBuildRet(b, LLVMConstPointerNull(i8ptr))
        }
        leaveThunk(saved)

        // Site: allocate + fill the env, start the fiber, keep its handle for joins.
        let envPtr = allocAndFillEnv(caps, envTy)
        let spawn = runtimeFn("fiber_spawn", ret: i8ptr, params: [i8ptr, i8ptr], varArg: false)
        let fiber = buildCall(spawn.0, spawn.1, [fn, envPtr])!
        let handleSlot = LLVMBuildAlloca(b, spawnHandleTy, "\(name).h")!
        LLVMBuildStore(b, fiber, structGEP(spawnHandleTy, handleSlot, 0))
        let sl = SpawnLocal(handleSlot: handleSlot, resultTy: resultTy)
        spawnLocals[name] = sl
        activeSpawns.append(sl)
    }

    // Read a spawn binding: join the fiber (blocks until done, idempotent) and load its boxed result.
    private func joinSpawn(_ name: String) -> LLVMValueRef? {
        guard let sp = spawnLocals[name] else { return nil }
        let sj = runtimeFn("spawn_join", ret: i8ptr, params: [i8ptr], varArg: false)
        let box = buildCall(sj.0, sj.1, [sp.handleSlot])!
        return LLVMBuildLoad2(b, sp.resultTy, box, name)
    }

    // `sleep(ms)` → `rt_sleep_ms(ms)` (Int); a colorless blocking call that parks the fiber.
    private func lowerSleep(_ args: [IRArg], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first, let ms = lowerExpr(arg.value) else {
            fail("8.2.6: sleep expects one Int argument", span); return nil
        }
        let fn = runtimeFn("rt_sleep_ms", ret: i64, params: [i64], varArg: false)
        return buildCall(fn.0, fn.1, [ms])
    }

    // `readLine()` → `rt_read_line(0)` (String); parks the fiber until stdin is readable.
    private func lowerReadLine() -> LLVMValueRef? {
        let fn = runtimeFn("rt_read_line", ret: strTy, params: [i32], varArg: false)
        return buildCall(fn.0, fn.1, [LLVMConstInt(i32, 0, 0)])
    }

    private func lowerCall(callee: IRExpr, args: [IRArg], span: Span) -> LLVMValueRef? {
        if case .varRef(let name) = callee.kind {
            switch name {
            case "print":  return lowerPrint(args, span)
            case "concat": return lowerConcat(args, span)
            case "sleep":  return lowerSleep(args, span)
            case "readLine": return lowerReadLine()
            default:       break
            }
            // A closure-typed local is an indirect call; a global function name is direct.
            if locals[name] == nil, funcMap[name] != nil {
                declareFree(name)
                guard let c = callables["f:\(name)"] else { return nil }
                return buildArgsAndCall(c.ty, c.fn, env: nil, args: args)
            }
        }
        // Otherwise the callee must be a function value (a closure): `{ fn, env }` → call
        // `fn(env, args…)`.
        guard case .function(let ptys, let rty) = callee.type else {
            fail("8.2.4: unsupported call target", span)
            return nil
        }
        guard let cval = lowerExpr(callee) else { return nil }
        let fnPtr = LLVMBuildExtractValue(b, cval, 0, "clo.fn")
        let envPtr = LLVMBuildExtractValue(b, cval, 1, "clo.env")
        guard let retTy = llvmType(rty, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [i8ptr]
        for t in ptys {
            guard let lt = llvmType(t, span) else { return nil }
            paramTys.append(lt)
        }
        return buildArgsAndCall(fnType(retTy, paramTys), fnPtr!, env: envPtr, args: args)
    }

    // Lower `args`, optionally prefixed by a closure `env`, and emit the call.
    private func buildArgsAndCall(_ fnTy: LLVMTypeRef, _ fn: LLVMValueRef, env: LLVMValueRef?, args: [IRArg]) -> LLVMValueRef? {
        var argVals: [LLVMValueRef?] = []
        if let env = env { argVals.append(env) }
        for a in args {
            guard let v = lowerExpr(a.value) else { return nil }
            argVals.append(v)
        }
        let n = UInt32(argVals.count)
        return argVals.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, fnTy, fn, $0.baseAddress, n, "")
        }
    }

    // MARK: - Free-variable collection (respects shadowing via `bound`)

    private func collectUses(_ stmts: [IRStmt], bound: inout Set<String>, used: inout [String]) {
        for s in stmts { collectUsesStmt(s, bound: &bound, used: &used) }
    }

    private func collectUsesStmt(_ stmt: IRStmt, bound: inout Set<String>, used: inout [String]) {
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            collectUsesExpr(value, bound: bound, used: &used); bound.insert(name)
        case .spawnLet(let name, let value, _):
            collectUsesExpr(value, bound: bound, used: &used); bound.insert(name)
        case .assign(let t, let v), .compoundAssign(let t, let v):
            collectUsesExpr(t, bound: bound, used: &used); collectUsesExpr(v, bound: bound, used: &used)
        case .ret(let e):
            if let e = e { collectUsesExpr(e, bound: bound, used: &used) }
        case .ifStmt(let cond, let then, let els):
            collectUsesExpr(cond, bound: bound, used: &used)
            var b1 = bound; collectUses(then, bound: &b1, used: &used)
            if let els = els { var b2 = bound; collectUses(els, bound: &b2, used: &used) }
        case .switchStmt(let sw):
            collectUsesExpr(sw.subject, bound: bound, used: &used)
            for arm in sw.arms {
                var ab = bound
                for bnd in arm.bindings { ab.insert(bnd.name) }
                collectUses(arm.body, bound: &ab, used: &used)
            }
        case .exprStmt(let e):
            collectUsesExpr(e, bound: bound, used: &used)
        }
    }

    private func collectUsesExpr(_ e: IRExpr, bound: Set<String>, used: inout [String]) {
        switch e.kind {
        case .intLit, .boolLit, .stringLit:
            break
        case .varRef(let n):
            if !bound.contains(n) { used.append(n) }
        case .fieldAccess(let base, _):
            collectUsesExpr(base, bound: bound, used: &used)
        case .construct(_, let args), .enumInit(_, _, let args):
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .methodCall(let receiver, _, let args):
            collectUsesExpr(receiver, bound: bound, used: &used)
            for a in args { collectUsesExpr(a, bound: bound, used: &used) }
        case .call(let callee, let args, _):
            collectUsesExpr(callee, bound: bound, used: &used)
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .binary(_, let l, let r):
            collectUsesExpr(l, bound: bound, used: &used); collectUsesExpr(r, bound: bound, used: &used)
        case .closure(let ps, let cbody):
            var nb = bound
            for p in ps { nb.insert(p.name) }
            collectUses(cbody, bound: &nb, used: &used)
        case .box(let value, _):
            collectUsesExpr(value, bound: bound, used: &used)
        }
    }

    // print(Int|Bool) → printf("%lld\n", n);  print(String) → printf("%.*s\n", (int)len, data).
    private func lowerPrint(_ args: [IRArg], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first, let value = lowerExpr(arg.value) else {
            fail("8.2.1: print expects one argument", span)
            return nil
        }
        let (fn, ty) = runtimeFn("printf", ret: i32, params: [i8ptr], varArg: true)
        switch arg.value.type {
        case .int, .bool:
            return buildCall(fn, ty, [intFormat(), value])
        case .string:
            let data = LLVMBuildExtractValue(b, value, 0, "data")
            let len = LLVMBuildExtractValue(b, value, 1, "len")
            let len32 = LLVMBuildTrunc(b, len, i32, "len32")
            return buildCall(fn, ty, [strFormat(), len32, data])
        default:
            fail("8.2.1: print supports Int, Bool, or String", arg.value.span)
            return nil
        }
    }

    private func lowerConcat(_ args: [IRArg], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else {
            fail("8.2.1: concat expects two String arguments", span)
            return nil
        }
        guard let a = lowerExpr(args[0].value), let c = lowerExpr(args[1].value) else { return nil }
        let (fn, ty) = runtimeFn("rt_str_concat", ret: strTy, params: [strTy, strTy], varArg: false)
        return buildCall(fn, ty, [a, c])
    }

    private func lowerStringLit(_ s: String) -> LLVMValueRef {
        let data = LLVMBuildGlobalStringPtr(b, s, "str")!
        let len = LLVMConstInt(i64, UInt64(s.utf8.count), 0)
        let (fn, ty) = runtimeFn("rt_str_lit", ret: strTy, params: [i8ptr, i64], varArg: false)
        return buildCall(fn, ty, [data, len])!
    }

    // MARK: - Helpers

    private func structGEP(_ structTy: LLVMTypeRef, _ addr: LLVMValueRef, _ idx: Int) -> LLVMValueRef {
        var idxs: [LLVMValueRef?] = [LLVMConstInt(i32, 0, 0), LLVMConstInt(i32, UInt64(idx), 0)]
        return idxs.withUnsafeMutableBufferPointer {
            LLVMBuildGEP2(b, structTy, addr, $0.baseAddress, 2, "fld")
        }!
    }

    // Thin wrappers over the LLVM C API that own the `[LLVMTypeRef?]` buffer dance the raw calls
    // require, so call sites read in terms of types/values, not pointers + counts.
    private func fnType(_ ret: LLVMTypeRef, _ params: [LLVMTypeRef], varArg: Bool = false) -> LLVMTypeRef {
        var ps: [LLVMTypeRef?] = params
        return ps.withUnsafeMutableBufferPointer {
            LLVMFunctionType(ret, $0.baseAddress, UInt32(params.count), varArg ? 1 : 0)
        }!
    }

    private func structTy(_ elems: [LLVMTypeRef], packed: Bool = false) -> LLVMTypeRef {
        var es: [LLVMTypeRef?] = elems
        return es.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, UInt32(elems.count), packed ? 1 : 0)
        }!
    }

    private func setStructBody(_ st: LLVMTypeRef, _ elems: [LLVMTypeRef], packed: Bool = false) {
        var es: [LLVMTypeRef?] = elems
        es.withUnsafeMutableBufferPointer {
            LLVMStructSetBody(st, $0.baseAddress, UInt32(elems.count), packed ? 1 : 0)
        }
    }

    private func constStruct(_ ty: LLVMTypeRef, _ vals: [LLVMValueRef?]) -> LLVMValueRef {
        var vs = vals
        return vs.withUnsafeMutableBufferPointer {
            LLVMConstNamedStruct(ty, $0.baseAddress, UInt32(vals.count))
        }!
    }

    // The single seam through which every LLVM function is created. When `debug` is given it also
    // attaches a `DISubprogram` (recovered later via `LLVMGetSubprogram`), so 8.3's line-table/
    // debug-scope setup lands here instead of at each `LLVMAddFunction`.
    private func emitFunction(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef],
                              varArg: Bool = false,
                              debug: (name: String, line: Int)? = nil) -> (fn: LLVMValueRef, ty: LLVMTypeRef) {
        let ty = fnType(ret, params, varArg: varArg)
        let fn = LLVMAddFunction(mod, name, ty)!
        if let debug = debug, let sp = makeSubprogram(debug.name, linkage: name, line: debug.line) {
            LLVMSetSubprogram(fn, sp)
        }
        return (fn, ty)
    }

    private func buildCall(_ fn: LLVMValueRef, _ ty: LLVMTypeRef, _ args: [LLVMValueRef?]) -> LLVMValueRef? {
        var a = args
        return a.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, ty, fn, $0.baseAddress, UInt32(args.count), "")
        }
    }

    // 8-byte slots an LLVM value type occupies. Every value type we build is 8-aligned and a
    // multiple of 8 (i64, pointers, {i8*,i64}, {ptr,ptr}, and structs of those), so a struct is
    // the sum of its members — used to size heap envs.
    private func abiSlots(_ t: LLVMTypeRef) -> Int {
        switch LLVMGetTypeKind(t) {
        case LLVMPointerTypeKind, LLVMIntegerTypeKind:
            return 1
        case LLVMStructTypeKind:
            var n = 0
            for i in 0..<LLVMCountStructElementTypes(t) { n += abiSlots(LLVMStructGetTypeAtIndex(t, i)) }
            return n
        default:
            return 1
        }
    }

    // `void* rt_alloc(size_t)` — the runtime allocator (bump-and-leak until the M6 GC).
    private func rtAlloc() -> LLVMValueRef { runtimeFn("rt_alloc", ret: i8ptr, params: [i64], varArg: false).0 }
    private func rtAllocTy() -> LLVMTypeRef { runtimeFn("rt_alloc", ret: i8ptr, params: [i64], varArg: false).1 }

    private func runtimeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef], varArg: Bool)
        -> (LLVMValueRef, LLVMTypeRef)
    {
        if let cached = runtimeFns[name] { return cached }
        let f = emitFunction(name, ret: ret, params: params, varArg: varArg)
        runtimeFns[name] = f
        return f
    }

    private func intFormat() -> LLVMValueRef {
        if let f = intFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%lld\n", "fmt_int")!
        intFmt = f
        return f
    }

    private func strFormat() -> LLVMValueRef {
        if let f = strFmt { return f }
        let f = LLVMBuildGlobalStringPtr(b, "%.*s\n", "fmt_str")!
        strFmt = f
        return f
    }

    private func fail(_ msg: String, _ span: Span) {
        if error == nil { error = "\(span): \(msg)" }
    }
}
