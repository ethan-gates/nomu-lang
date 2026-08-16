import sema
import midend
import noir
import ast
import support
// M8 · 8.2 — lower the typed IR (frontend `NOIRModule`) to an LLVM module via the C API. This is the
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
// the boundary later slices push. Types: Int is **i64**; Bool is **i1** (0/1, 8.5.2); String is the
// runtime `{ i8*, i64 }` struct; a `struct` is an LLVM struct in field order, passed/returned by
// value (mutating `self` is a pointer to it). Nomu `main` → `nomu_main`.
import Foundation
import LLVM_C

final class NOIRToLLVM {
    let ctx: LLVMContextRef
    let mod: LLVMModuleRef
    let b: LLVMBuilderRef

    let i8ptr: LLVMTypeRef      // opaque `ptr` (addrspace 0) — code / static / C-owned memory
    let p1: LLVMTypeRef         // opaque `ptr addrspace(1)` — a managed (GC-heap) reference (8.4.1 D1)
    let i1: LLVMTypeRef         // 8.5.2 — `Bool` (0/1); LLVM's natural boolean
    let i32: LLVMTypeRef
    let i64: LLVMTypeRef
    let f64: LLVMTypeRef         // `Double` — LLVM's native double
    let voidTy: LLVMTypeRef
    let strTy: LLVMTypeRef      // { i8* data, i64 len } — matches runtime.h `String`
    // Heap-box layouts (8.4.1). A closure / `any I` *value* is a managed `p1` pointer to one of
    // these heap objects, so no GC pointer ever rides inside a by-value aggregate across a safepoint
    // (RewriteStatepointsForGC can't relocate GC pointers nested in first-class aggregates). A
    // closure fuses its captures inline after the fn pointer, so creation is a single allocation.
    let closureHdrTy: LLVMTypeRef  // { ptr fn } — the fixed prefix of a heap closure { fn, caps… }
    let anyBoxTy: LLVMTypeRef      // { ptr witness (addr0), ptr addrspace(1) payload } — the `any I` heap box (D1)
    let spawnHandleTy: LLVMTypeRef // { ptr fiber (addr0, runtime-owned) } — SpawnHandle (8.2.6)

    let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)   // synthetic: resolves to line 0

    var runtimeFns: [String: (fn: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    // 8.4.2/8.4.4 — the inert mutator seams (`__nomu_poll` / `__nomu_gc_alloc` / `__nomu_write_barrier`).
    var pollFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var gcAllocFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var barrierFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var stopWorldGlobalCache: LLVMValueRef?   // 6.2.3 — external `@__nomu_stop_world` (i32)
    var intFmt: LLVMValueRef?
    var strFmt: LLVMValueRef?

    // Type + function registries. `structMap`/`structTypes`: Nomu structs and their (cached) LLVM
    // struct types. `funcMap`: top-level functions. `callables`: LLVM functions declared on demand
    // (free functions keyed `f:<name>`, methods `m:<type>:<method>`), with `pending` bodies.
    var structMap: [String: NOIRStruct] = [:]
    var structTypes: [String: LLVMTypeRef] = [:]
    var enumMap: [String: NOIREnum] = [:]
    var enumTypes: [String: LLVMTypeRef] = [:]
    var classMap: [String: NOIRClass] = [:]
    var classTypes: [String: LLVMTypeRef] = [:]
    var actorMap: [String: NOIRActor] = [:]
    var actorTypes: [String: LLVMTypeRef] = [:]
    var funcMap: [String: NOIRFunc] = [:]
    var closureSeq = 0
    // 6.5.2 — non-escaping allocation sites from escape analysis; empty when the pass is disabled.
    let escapes: EscapeResult
    // §6.6 — inline the allocation bump fast path; `NOMU_NO_INLINE_ALLOC` reverts to the out-of-line
    // `rt_alloc` tail-call (the pre-6.6 body) for A/B measurement.
    let inlineAlloc = ProcessInfo.processInfo.environment["NOMU_NO_INLINE_ALLOC"] == nil
    // M6 · 6.1.3 — GC pointer maps. Each heap type gets a type-id (written into the object header,
    // 6.1.2) that keys `typeMaps[id]` = the byte offsets of its managed (`p1`) fields, which
    // `scan_object` walks. Class/actor here; closures/any-boxes/String follow (they need a header
    // slot added first). Emitted as flat tables at module finalization.
    var typeIds: [String: UInt64] = [:]
    var typeMaps: [[Int32]] = []
    // M6 · 6.2.4 — parallel to `typeMaps`: `typeSizes[id]` = the object's total byte size (header
    // included). Every moving-space object is fixed-size per type-id (class/actor/closure/any-box are
    // monomorphized), so the collector's `get_current_size`/`get_size_when_copied` read this table by
    // type-id instead of parsing the object. No header change (§6.2.4).
    var typeSizes: [Int32] = []
    // M6 stdlib · Slice 4 — parallel to `typeMaps`: `typeKinds[id]` = 0 for a fixed-size object, 1 for
    // an array buffer (variable size). For an array buffer, `typeStrides[id]` = one element's byte
    // stride and `typeMaps[id]` = the managed-pointer offsets *within one element* (applied per element
    // by `scan_object`); `typeSizes[id]` is unused (size comes from the object's `cap`).
    var typeKinds: [Int32] = []
    var typeStrides: [Int32] = []
    var arrayBufMapIds: [String: UInt64] = [:]   // element-type description → array-buffer type-id
    var anyBoxMapId: UInt64?   // one shared map for every `any I` box (payload at byte 16)
    var arrayHandleMapId: UInt64?   // M6 stdlib — one shared type-id for every Array handle (bufptr at byte 16)
    // M6 · 6.4 actor mailbox. `mailboxTypeId` is the one shared type-id for every mailbox object
    // `{ header, mb_head, mb_tail, scheduled }`. `messageTypes`/`messageTypeIds` are the per-handler
    // message struct + its type-id; `actorThunks` the per-handler drain thunk; `actorDrainFn` the one
    // shared `nomu_actor_drain` loop. Keyed "actor:handler".
    var mailboxTypeId: UInt64?
    var msgPrefixTypeRef: LLVMTypeRef?
    var messageTypes: [String: LLVMTypeRef] = [:]
    var messageTypeIds: [String: UInt64] = [:]
    var actorThunks: [String: LLVMValueRef] = [:]
    var actorDrainFn: (LLVMValueRef, LLVMTypeRef)?

    // 8.2.5 witness machinery. `interfaceDefs` gives a requirement surface to lay out a witness
    // struct; `opaqueUnderlyings` resolves `some I` to its hidden concrete type. Witness types and
    // per-conformance instances (LLVM globals) are built lazily on first box/upcast, keyed
    // `type::iface` (and `type::A&B` for composites).
    var interfaceDefs: [String: NOIRInterface] = [:]
    var witnessSlotsCache: [String: [String]] = [:]
    var opaqueUnderlyings: [String: Type] = [:]
    var witnessTypes: [String: LLVMTypeRef] = [:]
    var witnessGlobals: [String: LLVMValueRef] = [:]
    var compositeTypes: [String: LLVMTypeRef] = [:]
    var compositeGlobals: [String: LLVMValueRef] = [:]

    struct Callable {
        let fn: LLVMValueRef
        let ty: LLVMTypeRef
        let ir: NOIRFunc
        let selfType: String?     // struct type name when this is a method
        let selfByPointer: Bool   // mutating method → self is `T*`
    }
    var callables: [String: Callable] = [:]
    var pending: [String] = []

    // 8.2.6 spawn machinery. A `spawn let` binding maps to a heap `SpawnHandle*`; reading it (or
    // leaving the scope) joins the fiber. `activeSpawns` is the join set for the current function.
    struct SpawnLocal {
        let handleSlot: LLVMValueRef   // alloca of spawnHandleTy holding the fiber
        let resultTy: LLVMTypeRef      // the joined result's LLVM type
    }
    var spawnLocals: [String: SpawnLocal] = [:]
    var activeSpawns: [SpawnLocal] = []
    var spawnSeq = 0

    // While lowering a loop body: where `break`/`continue` branch, and the `activeSpawns` count on
    // loop entry so each exiting edge joins only the spawns the body created (per-iteration join —
    // `loops.md`). A stack so nested loops target the innermost.
    struct LoopCtx {
        let header: LLVMBasicBlockRef   // `continue` and the back-edge branch here
        let exit: LLVMBasicBlockRef     // `break` branches here
        let spawnBase: Int              // activeSpawns.count at loop entry
    }
    var loopStack: [LoopCtx] = []
    // While lowering an actor handler body: the (loaded) mutex to unlock at every exit.

    // A local (param / let / self) → the address holding its value, and the value's LLVM type.
    var locals: [String: (addr: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    var currentFn: LLVMValueRef?

    // While lowering a method body: the receiver, so a bare field reference (`x` inside a method)
    // resolves through `self`.
    // A struct is a value; a class is a heap reference (its value is a pointer to `{ header, … }`).
    enum AggKind { case structVal, classRef }

    struct SelfCtx {
        let fields: [NOIRField]    // fields for bare-name access inside a method; [] for enums
        let kind: AggKind        // class fields sit after the object header (index +1)
        let llvmTy: LLVMTypeRef  // the struct/class aggregate type (the pointee for a class)
        let addr: LLVMValueRef   // pointer to the receiver's fields (struct value / object)
    }
    var currentSelf: SelfCtx?

    // 8.3 — DWARF Tier 0. The DIBuilder, the compile-unit file, and the subprogram `!dbg` locations
    // attach to. `currentScope` and the builder's current debug location are saved/restored across
    // thunks (like the rest of the builder state) so each hoisted function keeps its own scope.
    // Nil `di` ⇒ no debug info (the module named no source file); everything below is then inert.
    var di: LLVMDIBuilderRef?
    var diFile: LLVMMetadataRef?
    var diCU: LLVMMetadataRef?
    var currentScope: LLVMMetadataRef?
    var diTypeCache: [String: LLVMMetadataRef] = [:]   // 8.3.2 basic/composite DITypes

    // Settable across the split extension files (LoweringGC etc.); the class is module-internal.
    var loweredMain = false
    var error: String?

    init(ctx: LLVMContextRef, mod: LLVMModuleRef, escapes: EscapeResult = EscapeResult(nonEscaping: [])) {
        self.ctx = ctx
        self.mod = mod
        self.escapes = escapes
        b = LLVMCreateBuilderInContext(ctx)
        i8ptr = LLVMPointerType(LLVMInt8TypeInContext(ctx), 0)
        p1 = LLVMPointerType(LLVMInt8TypeInContext(ctx), 1)
        i1 = LLVMInt1TypeInContext(ctx)
        i32 = LLVMInt32TypeInContext(ctx)
        i64 = LLVMInt64TypeInContext(ctx)
        f64 = LLVMDoubleTypeInContext(ctx)
        voidTy = LLVMVoidTypeInContext(ctx)
        var fields: [LLVMTypeRef?] = [i8ptr, i64]
        strTy = fields.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 2, /*packed=*/0)
        }
        // { i64 header (6.1.3 type-id), i8ptr fn }; captures follow, per closure. fn is addr0.
        var clo: [LLVMTypeRef?] = [i64, i8ptr]
        closureHdrTy = clo.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 2, 0)
        }
        // { i64 header (6.1.3 type-id), i8ptr witness (static, addr0), p1 payload (managed) }
        var box: [LLVMTypeRef?] = [i64, i8ptr, p1]
        anyBoxTy = box.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 3, 0)
        }
        var sh: [LLVMTypeRef?] = [i8ptr]
        spawnHandleTy = sh.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, 1, 0)
        }
    }

    deinit { LLVMDisposeBuilder(b) }

    func lower(_ module: NOIRModule) {
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
        emitTypeMaps()                          // M6 · 6.1.3 — all heap types now assigned type-ids
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

    // A `DISubprogram` for a source-backed function; nil for thunks (`debug` nil) so their
    // synthetic instructions carry no `!dbg` and the inlinable-call verifier rule doesn't apply.
    func makeSubprogram(_ displayName: String, linkage: String, line: Int) -> LLVMMetadataRef? {
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
    func setDebugLoc(_ span: Span) {
        guard di != nil, let scope = currentScope, span.begin.line > 0 else { return }
        let loc = LLVMDIBuilderCreateDebugLocation(
            ctx, UInt32(span.begin.line), UInt32(span.begin.col), scope, nil)
        LLVMSetCurrentDebugLocation2(b, loc)
    }

    // Enter `fn`'s scope: adopt its subprogram (nil for thunks) and seed a live debug location at
    // `line` so prologue instructions are covered; a nil scope clears the location instead.
    func enterDebugScope(_ fn: LLVMValueRef, line: Int) {
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
    let dwSigned: LLVMDWARFTypeEncoding = 5      // DW_ATE_signed
    let dwFloat: LLVMDWARFTypeEncoding = 4       // DW_ATE_float
    let dwBoolean: LLVMDWARFTypeEncoding = 2     // DW_ATE_boolean
    let dwUnsignedChar: LLVMDWARFTypeEncoding = 8 // DW_ATE_unsigned_char

    func diType(_ t: Type) -> LLVMMetadataRef? {
        guard di != nil else { return nil }
        switch t {
        case .int:    return diBasic("Int", dwSigned, bits: 64)
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

    // The runtime `String` is `{ i8* data, i64 len }` — a 16-byte composite of a char pointer and a
    // length, laid out at slot offsets 0 and 1.
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

    // A class value is a pointer to `{ i64 header, fields… }`; model the object composite (with a
    // header slot so field offsets match the +1 index) and return a pointer to it.
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

    // Attach a `DILocalVariable` + `llvm.dbg.declare` to `addr` (the variable's storage), so a
    // debugger can read it. `argNo` marks a parameter (1-based); nil is an ordinary local. No-op
    // when there's no scope or the type is unmodeled.
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
