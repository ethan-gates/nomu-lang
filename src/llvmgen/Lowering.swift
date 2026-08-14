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
import frontend

final class NOIRToLLVM {
    private let ctx: LLVMContextRef
    private let mod: LLVMModuleRef
    private let b: LLVMBuilderRef

    private let i8ptr: LLVMTypeRef      // opaque `ptr` (addrspace 0) — code / static / C-owned memory
    private let p1: LLVMTypeRef         // opaque `ptr addrspace(1)` — a managed (GC-heap) reference (8.4.1 D1)
    private let i1: LLVMTypeRef         // 8.5.2 — `Bool` (0/1); LLVM's natural boolean
    private let i32: LLVMTypeRef
    private let i64: LLVMTypeRef
    private let f64: LLVMTypeRef         // `Double` — LLVM's native double
    private let voidTy: LLVMTypeRef
    private let strTy: LLVMTypeRef      // { i8* data, i64 len } — matches runtime.h `String`
    // Heap-box layouts (8.4.1). A closure / `any I` *value* is a managed `p1` pointer to one of
    // these heap objects, so no GC pointer ever rides inside a by-value aggregate across a safepoint
    // (RewriteStatepointsForGC can't relocate GC pointers nested in first-class aggregates). A
    // closure fuses its captures inline after the fn pointer, so creation is a single allocation.
    private let closureHdrTy: LLVMTypeRef  // { ptr fn } — the fixed prefix of a heap closure { fn, caps… }
    private let anyBoxTy: LLVMTypeRef      // { ptr witness (addr0), ptr addrspace(1) payload } — the `any I` heap box (D1)
    private let spawnHandleTy: LLVMTypeRef // { ptr fiber (addr0, runtime-owned) } — SpawnHandle (8.2.6)

    private let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)   // synthetic: resolves to line 0

    private var runtimeFns: [String: (fn: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    // 8.4.2/8.4.4 — the inert mutator seams (`__nomu_poll` / `__nomu_gc_alloc` / `__nomu_write_barrier`).
    private var pollFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    private var gcAllocFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    private var barrierFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    private var stopWorldGlobalCache: LLVMValueRef?   // 6.2.3 — external `@__nomu_stop_world` (i32)
    private var intFmt: LLVMValueRef?
    private var strFmt: LLVMValueRef?

    // Type + function registries. `structMap`/`structTypes`: Nomu structs and their (cached) LLVM
    // struct types. `funcMap`: top-level functions. `callables`: LLVM functions declared on demand
    // (free functions keyed `f:<name>`, methods `m:<type>:<method>`), with `pending` bodies.
    private var structMap: [String: NOIRStruct] = [:]
    private var structTypes: [String: LLVMTypeRef] = [:]
    private var enumMap: [String: NOIREnum] = [:]
    private var enumTypes: [String: LLVMTypeRef] = [:]
    private var classMap: [String: NOIRClass] = [:]
    private var classTypes: [String: LLVMTypeRef] = [:]
    private var actorMap: [String: NOIRActor] = [:]
    private var actorTypes: [String: LLVMTypeRef] = [:]
    private var funcMap: [String: NOIRFunc] = [:]
    private var closureSeq = 0
    // 6.5.2 — non-escaping allocation sites from escape analysis; empty when the pass is disabled.
    private let escapes: EscapeResult
    // §6.6 — inline the allocation bump fast path; `NOMU_NO_INLINE_ALLOC` reverts to the out-of-line
    // `rt_alloc` tail-call (the pre-6.6 body) for A/B measurement.
    private let inlineAlloc = ProcessInfo.processInfo.environment["NOMU_NO_INLINE_ALLOC"] == nil
    // M6 · 6.1.3 — GC pointer maps. Each heap type gets a type-id (written into the object header,
    // 6.1.2) that keys `typeMaps[id]` = the byte offsets of its managed (`p1`) fields, which
    // `scan_object` walks. Class/actor here; closures/any-boxes/String follow (they need a header
    // slot added first). Emitted as flat tables at module finalization.
    private var typeIds: [String: UInt64] = [:]
    private var typeMaps: [[Int32]] = []
    // M6 · 6.2.4 — parallel to `typeMaps`: `typeSizes[id]` = the object's total byte size (header
    // included). Every moving-space object is fixed-size per type-id (class/actor/closure/any-box are
    // monomorphized), so the collector's `get_current_size`/`get_size_when_copied` read this table by
    // type-id instead of parsing the object. No header change (§6.2.4).
    private var typeSizes: [Int32] = []
    // M6 stdlib · Slice 4 — parallel to `typeMaps`: `typeKinds[id]` = 0 for a fixed-size object, 1 for
    // an array buffer (variable size). For an array buffer, `typeStrides[id]` = one element's byte
    // stride and `typeMaps[id]` = the managed-pointer offsets *within one element* (applied per element
    // by `scan_object`); `typeSizes[id]` is unused (size comes from the object's `cap`).
    private var typeKinds: [Int32] = []
    private var typeStrides: [Int32] = []
    private var arrayBufMapIds: [String: UInt64] = [:]   // element-type description → array-buffer type-id
    private var anyBoxMapId: UInt64?   // one shared map for every `any I` box (payload at byte 16)
    private var arrayHandleMapId: UInt64?   // M6 stdlib — one shared type-id for every Array handle (bufptr at byte 16)
    // M6 · 6.4 actor mailbox. `mailboxTypeId` is the one shared type-id for every mailbox object
    // `{ header, mb_head, mb_tail, scheduled }`. `messageTypes`/`messageTypeIds` are the per-handler
    // message struct + its type-id; `actorThunks` the per-handler drain thunk; `actorDrainFn` the one
    // shared `nomu_actor_drain` loop. Keyed "actor:handler".
    private var mailboxTypeId: UInt64?
    private var msgPrefixTypeRef: LLVMTypeRef?
    private var messageTypes: [String: LLVMTypeRef] = [:]
    private var messageTypeIds: [String: UInt64] = [:]
    private var actorThunks: [String: LLVMValueRef] = [:]
    private var actorDrainFn: (LLVMValueRef, LLVMTypeRef)?

    // 8.2.5 witness machinery. `interfaceDefs` gives a requirement surface to lay out a witness
    // struct; `opaqueUnderlyings` resolves `some I` to its hidden concrete type. Witness types and
    // per-conformance instances (LLVM globals) are built lazily on first box/upcast, keyed
    // `type::iface` (and `type::A&B` for composites).
    private var interfaceDefs: [String: NOIRInterface] = [:]
    private var witnessSlotsCache: [String: [String]] = [:]
    private var opaqueUnderlyings: [String: Type] = [:]
    private var witnessTypes: [String: LLVMTypeRef] = [:]
    private var witnessGlobals: [String: LLVMValueRef] = [:]
    private var compositeTypes: [String: LLVMTypeRef] = [:]
    private var compositeGlobals: [String: LLVMValueRef] = [:]

    private struct Callable {
        let fn: LLVMValueRef
        let ty: LLVMTypeRef
        let ir: NOIRFunc
        let selfType: String?     // struct type name when this is a method
        let selfByPointer: Bool   // mutating method → self is `T*`
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

    // While lowering a loop body: where `break`/`continue` branch, and the `activeSpawns` count on
    // loop entry so each exiting edge joins only the spawns the body created (per-iteration join —
    // `loops.md`). A stack so nested loops target the innermost.
    private struct LoopCtx {
        let header: LLVMBasicBlockRef   // `continue` and the back-edge branch here
        let exit: LLVMBasicBlockRef     // `break` branches here
        let spawnBase: Int              // activeSpawns.count at loop entry
    }
    private var loopStack: [LoopCtx] = []
    // While lowering an actor handler body: the (loaded) mutex to unlock at every exit.

    // A local (param / let / self) → the address holding its value, and the value's LLVM type.
    private var locals: [String: (addr: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    private var currentFn: LLVMValueRef?

    // While lowering a method body: the receiver, so a bare field reference (`x` inside a method)
    // resolves through `self`.
    // A struct is a value; a class is a heap reference (its value is a pointer to `{ header, … }`).
    private enum AggKind { case structVal, classRef }

    private struct SelfCtx {
        let fields: [NOIRField]    // fields for bare-name access inside a method; [] for enums
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
    private let dwFloat: LLVMDWARFTypeEncoding = 4       // DW_ATE_float
    private let dwBoolean: LLVMDWARFTypeEncoding = 2     // DW_ATE_boolean
    private let dwUnsignedChar: LLVMDWARFTypeEncoding = 8 // DW_ATE_unsigned_char

    private func diType(_ t: Type) -> LLVMMetadataRef? {
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

    private func diBasic(_ name: String, _ encoding: LLVMDWARFTypeEncoding, bits: UInt64 = 64) -> LLVMMetadataRef? {
        if let c = diTypeCache["b:\(name)"] { return c }
        let t = LLVMDIBuilderCreateBasicType(di, name, name.utf8.count, bits, encoding, LLVMDIFlagZero)
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
        case .int:        return i64
        case .double:     return f64
        case .bool:       return i1    // 8.5.2 — Bool is LLVM's native i1 (was i64)
        case .string:     return strTy
        case .void:       return voidTy
        case .function:   return p1   // a closure value is a managed pointer to a heap { fn, caps… } object (8.4.1)
        case .named(let n, .struct_):
            if let st = structType(n) { return st }
            fail("8.2.2: unknown struct '\(n)'", span)
            return nil
        case .named(let n, .enum_):
            if let et = enumType(n) { return et }
            fail("8.2.3: unknown enum '\(n)'", span)
            return nil
        case .named(let n, .class_):
            if classMap[n] != nil { return p1 }   // a class value is a managed pointer to its object (D1)
            fail("8.2.4: unknown class '\(n)'", span)
            return nil
        case .named(let n, .actor_):
            if actorMap[n] != nil { return p1 }    // an actor handle is a managed pointer to its object (D1)
            fail("8.2.6: unknown actor '\(n)'", span)
            return nil
        case .array:
            return p1   // `Array<T>` is a reference type — a managed pointer to the heap handle (M6)
        case .existential, .composition:
            return p1   // `any I` / `any A & B` — a managed pointer to a heap { witness, payload } box (8.4.1)
        case .opaque:
            let u = concreteUnderlying(t)
            if case .opaque = u { fail("8.2.5: opaque type with no known underlying", span); return nil }
            return llvmType(u, span)                 // `some I` is unboxed — the concrete underlying's type
        default:
            fail("8.2.4: unsupported type '\(t)'", span)
            return nil
        }
    }

    // A class object is `{ i64 header /*ObjectHeader.type_id, 6.1.2*/, fields… }`, heap-allocated. The
    // header slot mirrors the runtime's `ObjectHeader`; codegen fills the type-id at 6.1.3 (zero until
    // then). Field index i is therefore at aggregate index i+1.
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

    // An actor object is `{ i64 header, fields…, mailbox }`, heap-allocated (M6 · 6.4). Fields sit at
    // index i+1 (past the header, like a class); the trailing slot holds a managed pointer to the
    // actor's mailbox object (a GC object — so it is scanned, unlike the old runtime mutex). Codegen
    // loads this at the call site and hands the mailbox to `rt_actor_send`, so the actor object never
    // crosses the runtime C ABI.
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
        elems.append(p1)   // mailbox
        setStructBody(at, elems)
        return at
    }

    // The index of an actor's mailbox slot (after the header and every field).
    private func actorMailboxIndex(_ name: String) -> Int { (actorMap[name]?.fields.count ?? 0) + 1 }

    // The aggregate type, kind, and fields of a named struct/class.
    private func aggInfo(_ typeName: String) -> (ty: LLVMTypeRef, kind: AggKind, fields: [NOIRField])? {
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
    private func caseStructType(_ enumName: String, _ c: NOIREnumCase) -> LLVMTypeRef? {
        var elems: [LLVMTypeRef] = []
        for f in c.fields {
            guard let t = llvmType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return structTy(elems)
    }

    private func caseSlots(_ c: NOIREnumCase) -> Int { c.fields.reduce(0) { $0 + slotCount($1.type) } }

    // 6.5.2 — a captured value whose LLVM type carries no managed pointer, so a stack-allocated
    // closure env holding only such captures needs no barrier and no stack-map scanning. The scalar
    // leaves (`Int`/`Double`/`Bool`) are the safe set; a `p1` capture, a String, or an aggregate that
    // could embed a pointer keeps the closure on the heap for now.
    private func isScalarLeaf(_ ty: LLVMTypeRef) -> Bool { ty == i64 || ty == f64 || ty == i1 }

    // 8-byte slots a value occupies in an enum payload. Every supported leaf is 8-aligned, so a
    // struct/enum is just the sum/tag+max of its parts — no padding to account for.
    private func slotCount(_ t: Type) -> Int {
        switch t {
        case .int, .double, .bool: return 1
        case .string:     return 2
        case .function:   return 1   // a managed pointer to a heap { fn, caps… } box (8.4.1)
        case .existential, .composition: return 1   // a managed pointer to a heap { witness, payload } box
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
            fail("8.2.3: unknown method '\(typeName).\(method)'", Span(startOffset: -1, endOffset: -1, map: nil))
            return
        }
        let sanitized = method.replacingOccurrences(of: ".", with: "_")
        // A class is a reference type: `self` is always the object pointer. A struct/enum passes
        // `self` by pointer only when the method mutates it.
        let byPointer = classMap[typeName] != nil || f.isMutating
        declareCallable(key: key, llvmName: "nomu_m_\(typeName)_\(sanitized)",
                        ir: f, selfType: typeName, selfByPointer: byPointer)
    }

    private func typeMethods(_ typeName: String) -> [NOIRFunc] {
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
        let f = NOIRFunc(name: h.name, params: h.params, returnType: h.returnType,
                       body: h.body, isMutating: true, span: h.span)
        declareCallable(key: key, llvmName: "nomu_on_\(actorName)_\(handler)",
                        ir: f, selfType: actorName, selfByPointer: true)
    }

    private func declareCallable(key: String, llvmName: String, ir f: NOIRFunc,
                                 selfType: String?, selfByPointer: Bool) {
        guard let retTy = llvmType(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        if let selfType = selfType {
            guard let st = selfLLVMType(selfType) else { return }
            if selfByPointer {
                // A class/actor receiver is the managed object pointer (addrspace 1). A struct/enum
                // mutating receiver is a pointer to the stack-resident value (addrspace 0).
                let isReference = classMap[selfType] != nil || actorMap[selfType] != nil
                paramTys.append(isReference ? p1 : LLVMPointerType(st, 0)!)
            } else {
                paramTys.append(st)
            }
        }
        for p in f.params {
            guard let t = llvmType(p.type, p.span) else { return }
            paramTys.append(t)
        }
        let (fn, fnTy) = emitFunction(llvmName, ret: retTy, params: paramTys,
                                      debug: (f.name, f.span.begin.line))
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType,
                                  selfByPointer: selfByPointer)
        pending.append(key)
    }

    private func defineBody(_ key: String) {
        guard let c = callables[key] else { return }
        let f = c.ir
        currentFn = c.fn
        let block = LLVMAppendBasicBlockInContext(ctx, c.fn, "entry")
        LLVMPositionBuilderAtEnd(b, block)

        let savedLocals = locals; let savedSelf = currentSelf
        let savedSpawns = spawnLocals; let savedActive = activeSpawns
        let savedScope = currentScope
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        locals = [:]; currentSelf = nil; spawnLocals = [:]; activeSpawns = []
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
                ?? actorMap[selfType]?.fields.map { NOIRField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) }
                ?? []
            currentSelf = SelfCtx(fields: fields, kind: isReference ? .classRef : .structVal,
                                  llvmTy: st, addr: selfPtr)
            if isReference {
                // `self` as a value is the managed object pointer; keep it in an addrspace(1) slot
                // for `varRef self` (mem2reg promotes it so the rewrite pass tracks it as a root).
                let slot = LLVMBuildAlloca(b, p1, "self")!
                LLVMBuildStore(b, selfPtr, slot)
                locals["self"] = (slot, p1)
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

            // M6 · 6.4 — an actor handler no longer locks a mutex. The mailbox serializes handlers (one
            // drain per actor at a time), so the body runs plainly like any method.
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
            if f.returnType == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        locals = savedLocals; currentSelf = savedSelf
        spawnLocals = savedSpawns; activeSpawns = savedActive
        currentScope = savedScope
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

    // Join every fiber the current function spawned — the structured-concurrency guarantee that no
    // child outlives the scope. `spawn_join` is idempotent, so re-joining an already-read spawn is safe.
    private func joinActiveSpawns() { joinSpawnsFrom(0) }

    // Join the spawns created since index `base` (those `activeSpawns[base...]`). Used at function
    // exit (base 0) and at each loop-body exit edge (base = the loop's entry count), so a `break` /
    // `continue` / back-edge joins only what that path actually spawned. `spawn_join` is idempotent.
    private func joinSpawnsFrom(_ base: Int) {
        guard base < activeSpawns.count else { return }
        let sj = runtimeFn("spawn_join", ret: i8ptr, params: [i8ptr], varArg: false)
        for s in activeSpawns[base...] { _ = buildCall(sj.0, sj.1, [s.handleSlot]) }
    }

    private func blockTerminated() -> Bool {
        LLVMGetBasicBlockTerminator(LLVMGetInsertBlock(b)) != nil
    }

    // MARK: - Statements

    private func lowerBlock(_ stmts: [NOIRStmt]) {
        for s in stmts {
            if error != nil || blockTerminated() { return }
            lowerStmt(s)
        }
    }

    // A stack slot for a local/temporary, always created in the function's **entry block** — never at
    // the current insertion point. LLVM only treats entry-block allocas as fixed frame slots; an
    // alloca emitted inside a loop body is a *dynamic* stack allocation that grows the stack every
    // iteration and overflows a fiber's fixed stack (128 KB) after enough iterations. `-O2` hoists
    // these anyway, so this only shows up in the debug pipeline (mem2reg/sroa, no LICM/DCE). Reusing
    // one slot across iterations is correct: locals are dead at the loop back-edge, and closures
    // snapshot captures **by value** at creation (`allocAndFillEnv`), so per-iteration binding does not
    // depend on a fresh slot. A scratch builder keeps the main builder's position untouched.
    private func entryAlloca(_ ty: LLVMTypeRef, _ name: String) -> LLVMValueRef {
        guard let fn = currentFn, let entry = LLVMGetEntryBasicBlock(fn) else {
            return LLVMBuildAlloca(b, ty, name)!
        }
        let tmp = LLVMCreateBuilderInContext(ctx)!
        defer { LLVMDisposeBuilder(tmp) }
        if let first = LLVMGetFirstInstruction(entry) {
            LLVMPositionBuilderBefore(tmp, first)
        } else {
            LLVMPositionBuilderAtEnd(tmp, entry)
        }
        return LLVMBuildAlloca(tmp, ty, name)!
    }

    private func lowerStmt(_ stmt: NOIRStmt) {
        setDebugLoc(stmt.span)   // 8.3: line-table entry; inherited by this statement's instructions
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            guard llvmType(value.type, stmt.span) != nil, let v = lowerExpr(value) else { return }
            // Slot type follows the produced value, not the nominal type: usually identical, but a
            // 6.5.2 stack-allocated class flows as an addrspace(0) pointer rather than the managed p1.
            let ty = LLVMTypeOf(v)!
            let slot = entryAlloca(ty, name)
            LLVMBuildStore(b, v, slot)
            locals[name] = (slot, ty)
            declareLocal(name, type: value.type, addr: slot, line: stmt.span.begin.line)

        case .assign(let target, let value):
            assignTo(target, value)

        case .compoundAssign(let target, let value):
            // Nomu's only compound assignment is `+=`, on Int or Double (CodegenIR emits `l += r`).
            guard let dst = lvalue(target) else { return }
            guard let v = lowerExpr(value) else { return }
            let cur = LLVMBuildLoad2(b, dst.ty, dst.addr, "cur")
            let sum = value.type == .double ? LLVMBuildFAdd(b, cur, v, "fadd")
                                            : LLVMBuildAdd(b, cur, v, "add")
            LLVMBuildStore(b, sum, dst.addr)

        case .ret(let e):
            // A returned value is computed before joins/unlock so its own spawn reads happen first.
            let v = e != nil ? lowerExpr(e!) : nil
            if e != nil, v == nil { return }
            joinActiveSpawns()
            if let v = v { LLVMBuildRet(b, v) } else { LLVMBuildRetVoid(b) }

        case .spawnLet(let name, let value, let resultType):
            lowerSpawnLet(name: name, value: value, resultType: resultType, span: stmt.span)

        case .ifStmt(let cond, let then, let els):
            lowerIf(cond: cond, then: then, els: els)

        case .whileStmt(let cond, let body):
            lowerWhile(cond: cond, body: body)

        case .breakStmt:
            guard let loop = loopStack.last else { return }
            joinSpawnsFrom(loop.spawnBase)
            LLVMBuildBr(b, loop.exit)

        case .continueStmt:
            guard let loop = loopStack.last else { return }
            joinSpawnsFrom(loop.spawnBase)
            LLVMBuildBr(b, loop.header)

        case .switchStmt(let sw):
            lowerSwitch(sw)

        case .exprStmt(let e):
            _ = lowerExpr(e)
        }
    }

    private func lowerIf(cond: NOIRExpr, then: [NOIRStmt], els: [NOIRStmt]?) {
        guard let fn = currentFn, let condV = lowerExpr(cond) else { return }
        let condBit = condV   // 8.5.2 — a Bool is already i1; branch on it directly
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

    // `while cond { body }` — header/body/exit blocks (`loops.md`). The header re-tests each
    // iteration; the body branches back to the header (the back-edge, where 8.4.2 will place a
    // safepoint poll). Body-scoped locals and spawns are saved on entry and restored on exit, and
    // each exiting edge (normal fall-through, `continue`, `break`) joins the spawns the body made.
    private func lowerWhile(cond: NOIRExpr, body: [NOIRStmt]) {
        guard let fn = currentFn else { return }
        let headerBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.header")!
        let bodyBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.body")!
        let exitBB = LLVMAppendBasicBlockInContext(ctx, fn, "while.exit")!

        LLVMBuildBr(b, headerBB)
        LLVMPositionBuilderAtEnd(b, headerBB)
        setDebugLoc(cond.span)
        // 8.4.2 (D3): a loop that reaches no safepoint on its own (no non-leaf call and no
        // allocation in its body) gets an inert safepoint poll each iteration, so a moving GC (M6)
        // can stop the fiber and bound time-to-safepoint. A loop that already hits a statepoint
        // every iteration needs none — elide it there. Placed at the top of the header, so every
        // back-edge (fall-through and `continue`) passes through it.
        if !loopBodyHasSafepoint(body) { emitSafepointPoll() }
        guard let condV = lowerExpr(cond) else { return }
        let condBit = condV   // 8.5.2 — a Bool is already i1; branch on it directly
        LLVMBuildCondBr(b, condBit, bodyBB, exitBB)

        LLVMPositionBuilderAtEnd(b, bodyBB)
        let base = activeSpawns.count
        let savedLocals = locals
        let savedSpawnLocals = spawnLocals
        loopStack.append(LoopCtx(header: headerBB, exit: exitBB, spawnBase: base))
        lowerBlock(body)
        if !blockTerminated() {
            joinSpawnsFrom(base)                 // normal fall-through joins the iteration's spawns
            LLVMBuildBr(b, headerBB)
        }
        loopStack.removeLast()
        locals = savedLocals
        spawnLocals = savedSpawnLocals
        activeSpawns = Array(activeSpawns.prefix(base))   // body spawns don't outlive the loop

        LLVMPositionBuilderAtEnd(b, exitBB)
    }

    // MARK: - Expressions

    private func lowerExpr(_ e: NOIRExpr) -> LLVMValueRef? {
        switch e.kind {
        case .intLit(let n):
            return LLVMConstInt(i64, UInt64(bitPattern: Int64(n)), /*SignExtend=*/1)
        case .doubleLit(let x):
            return LLVMConstReal(f64, x)
        case .boolLit(let v):
            return LLVMConstInt(i1, v ? 1 : 0, 0)
        case .stringLit(let s):
            return lowerStringLit(s)
        case .arrayLit(let elements):
            return lowerArrayLit(elements, e.type, e.span)
        case .index(let base, let idx):
            return lowerIndex(base, idx, e.type, e.span)
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
    private func lvalue(_ e: NOIRExpr) -> (addr: LLVMValueRef, ty: LLVMTypeRef)? {
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
            let slot = entryAlloca(ty, "tmp")
            LLVMBuildStore(b, v, slot)
            return (slot, ty)
        }
    }

    // Lower an assignment `target = value`, routing a reference write into a managed object field
    // through the write barrier (8.4.4). Mirrors `lvalue`'s assignable cases, but keeps the managed
    // object base (so the barrier can log it) and lowers the field base exactly once — computing the
    // target address before the value, as the plain-store path did (evaluation order preserved).
    // A write to a stack local or a struct-value field (addrspace 0, not a GC object) is a plain store.
    private func assignTo(_ target: NOIRExpr, _ valueExpr: NOIRExpr) {
        switch target.kind {
        case .varRef(let name):
            if let l = locals[name] {
                guard let v = lowerExpr(valueExpr) else { return }
                LLVMBuildStore(b, v, l.addr)
                return
            }
            if let cs = currentSelf, let pos = cs.fields.firstIndex(where: { $0.name == name }) {
                let slot = structGEP(cs.llvmTy, cs.addr, fieldLLVMIndex(cs.kind, pos))
                guard let v = lowerExpr(valueExpr) else { return }
                if cs.kind == .classRef { storeField(cs.addr, slot, v) } else { LLVMBuildStore(b, v, slot) }
                return
            }
            fail("8.2.4: unknown variable '\(name)'", target.span)
        case .fieldAccess(let base, let field):
            guard case .named(let typeName, _) = base.type, let info = aggInfo(typeName),
                  let pos = info.fields.firstIndex(where: { $0.name == field }) else {
                fail("8.2.4: field access on a non-aggregate", target.span)
                return
            }
            let basePtr: LLVMValueRef
            if info.kind == .classRef {
                guard let bv = lowerExpr(base) else { return }   // the object pointer (managed)
                basePtr = bv
            } else {
                guard let ba = lvalue(base) else { return }      // the struct's stack address
                basePtr = ba.addr
            }
            let slot = structGEP(info.ty, basePtr, fieldLLVMIndex(info.kind, pos))
            guard let v = lowerExpr(valueExpr) else { return }
            if info.kind == .classRef { storeField(basePtr, slot, v) } else { LLVMBuildStore(b, v, slot) }
        default:
            guard let dst = lvalue(target), let v = lowerExpr(valueExpr) else { return }
            LLVMBuildStore(b, v, dst.addr)
        }
    }

    private func lowerBinary(_ op: BinOp, _ l: NOIRExpr, _ r: NOIRExpr) -> LLVMValueRef? {
        guard let lv = lowerExpr(l), let rv = lowerExpr(r) else { return nil }
        // Double uses the floating-point opcodes; everything else is the i64 integer path. Sema
        // guarantees both operands share the numeric type, so the left operand's type decides.
        if l.type == .double {
            switch op {
            case .add: return LLVMBuildFAdd(b, lv, rv, "fadd")
            case .sub: return LLVMBuildFSub(b, lv, rv, "fsub")
            case .mul: return LLVMBuildFMul(b, lv, rv, "fmul")
            case .div: return LLVMBuildFDiv(b, lv, rv, "fdiv")
            case .mod: return LLVMBuildFRem(b, lv, rv, "frem")
            case .eq, .neq, .lt, .gt, .lte, .gte:
                // Ordered predicates (false when either operand is NaN).
                let pred: LLVMRealPredicate
                switch op {
                case .eq:  pred = LLVMRealOEQ
                case .neq: pred = LLVMRealONE
                case .lt:  pred = LLVMRealOLT
                case .gt:  pred = LLVMRealOGT
                case .lte: pred = LLVMRealOLE
                default:   pred = LLVMRealOGE   // .gte
                }
                return LLVMBuildFCmp(b, pred, lv, rv, "fcmp")
            }
        }
        switch op {
        case .add: return LLVMBuildAdd(b, lv, rv, "add")
        case .sub: return LLVMBuildSub(b, lv, rv, "sub")
        case .mul: return LLVMBuildMul(b, lv, rv, "mul")
        case .div: return LLVMBuildSDiv(b, lv, rv, "div")
        case .mod: return LLVMBuildSRem(b, lv, rv, "rem")
        case .eq, .neq, .lt, .gt, .lte, .gte:
            // Comparisons on Int yield Bool — now the `icmp`'s native i1 directly (8.5.2, no zext).
            let pred: LLVMIntPredicate
            switch op {
            case .eq:  pred = LLVMIntEQ
            case .neq: pred = LLVMIntNE
            case .lt:  pred = LLVMIntSLT
            case .gt:  pred = LLVMIntSGT
            case .lte: pred = LLVMIntSLE
            default:   pred = LLVMIntSGE   // .gte
            }
            return LLVMBuildICmp(b, pred, lv, rv, "cmp")
        }
    }

    private func lowerConstruct(_ typeName: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        if let s = structMap[typeName], let st = structType(typeName) {
            var agg = LLVMGetUndef(st)
            for (idx, field) in s.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                agg = LLVMBuildInsertValue(b, agg, v, UInt32(idx), "")
            }
            return agg
        }
        if let c = classMap[typeName], let ct = classType(typeName) {
            // A non-escaping class instance is stack-allocated: one `alloca` (addrspace 0, hoisted to
            // the entry block) in place of `rt_alloc`, so it never heaps. Escape analysis proved the
            // object pointer only ever feeds field access, so SROA scalar-replaces the alloca and each
            // field becomes an SSA value: a managed field becomes an addrspace(1) SSA root that the
            // statepoint rewriter relocates like any other class-typed local (the same mechanism the
            // whole GC substrate rests on), so no interior stack-map scanning is needed. Field stores
            // are plain (a stack slot is not a heap location the write barrier tracks). Same struct
            // layout as the heap object, so field GEPs are unchanged.
            if escapes.isNonEscaping(span, .classInstance) {
                let obj = entryAlloca(ct, typeName)
                writeTypeIdHeader(obj, typeName)   // kept for layout uniformity; unread on the stack
                for (idx, field) in c.fields.enumerated() {
                    guard let v = constructField(field, args, typeName, span) else { return nil }
                    LLVMBuildStore(b, v, structGEP(ct, obj, fieldLLVMIndex(.classRef, idx)))
                }
                return obj
            }
            // Heap-allocate the object (rt_alloc, bump-and-leak), then store each field past the
            // header. The class value is the returned pointer (reference semantics).
            let slots = 1 + c.fields.reduce(0) { $0 + slotCount($1.type) }
            let obj = rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
            writeTypeIdHeader(obj, typeName)   // M6 · 6.1.3 — stamp the type-id into the header
            for (idx, field) in c.fields.enumerated() {
                guard let v = constructField(field, args, typeName, span) else { return nil }
                storeField(obj, structGEP(ct, obj, fieldLLVMIndex(.classRef, idx)), v)
            }
            return obj
        }
        if let a = actorMap[typeName], let at = actorType(typeName) {
            // Heap-allocate the object, initialize each field (a declared initializer, else the
            // matching constructor argument), then install a fresh mailbox in the last slot (M6 · 6.4).
            let slots = 2 + a.fields.reduce(0) { $0 + slotCount($1.type) }   // header + fields + mailbox
            let obj = rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
            writeTypeIdHeader(obj, typeName)   // M6 · 6.1.3 — stamp the type-id into the header
            for (idx, field) in a.fields.enumerated() {
                let v: LLVMValueRef?
                if let initE = field.initializer { v = lowerExpr(initE) }
                else { v = constructActorField(field, args, typeName, span) }
                guard let fv = v else { return nil }
                storeField(obj, structGEP(at, obj, fieldLLVMIndex(.classRef, idx)), fv)
            }
            // The mailbox is its own GC object `{ header, mb_head, mb_tail, scheduled, sched_next }`
            // (zeroed by the allocator → empty + unscheduled). Stored into the actor's last slot
            // through the barrier.
            let mailbox = rtAllocManaged(LLVMConstInt(i64, 40, 0))
            writeTypeIdHeaderRaw(mailbox, mailboxTypeIdValue())
            storeField(obj, structGEP(at, obj, actorMailboxIndex(typeName)), mailbox)
            return obj
        }
        fail("8.2.6: cannot construct '\(typeName)' (not a struct, class, or actor)", span)
        return nil
    }

    private func constructActorField(_ field: NOIRActorField, _ args: [NOIRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.6: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    private func constructField(_ field: NOIRField, _ args: [NOIRArg], _ typeName: String, _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first(where: { $0.label == field.name }) else {
            fail("8.2.4: missing field '\(field.name)' in construction of '\(typeName)'", span)
            return nil
        }
        return lowerExpr(arg.value)
    }

    // Build an enum value in a temp: store the case index as the tag, then each payload field via
    // the case's struct type GEP'd over the payload region; return the loaded aggregate.
    private func lowerEnumInit(_ typeName: String, _ caseName: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let et = enumType(typeName), let e = enumMap[typeName],
              let caseIdx = e.cases.firstIndex(where: { $0.name == caseName }) else {
            fail("8.2.3: cannot construct '\(typeName).\(caseName)'", span)
            return nil
        }
        let c = e.cases[caseIdx]
        let slot = entryAlloca(et, "enum")
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
    private func lowerSwitch(_ sw: NOIRSwitch) {
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
                    let bslot = entryAlloca(bty, binding.name)
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

    private func lowerMethodCall(receiver: NOIRExpr, method: String, args: [NOIRExpr],
                                 resultType: Type, span: Span) -> LLVMValueRef? {
        // Requirement call through `any I` — dispatch dynamically via the box's witness slot.
        if case .existential(let iface) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let witnessPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
            return witnessDispatch(witnessPtr: witnessPtr, iface: iface, method: method,
                                   payload: payload, args: args, resultType: resultType, span: span)
        }
        // Through `any A & B` — the witness is a composite struct; load the owning interface's
        // sub-table, then dispatch through its slot.
        if case .composition(let ifaces) = receiver.type {
            guard let box = lowerExpr(receiver) else { return nil }
            let compPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
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

        // An actor handler call is a fire-and-forget message-send, not a direct call (M6 · 6.4): build
        // a message and `rt_actor_send` it (the handler runs later on a rented pool worker; the call
        // returns immediately with no value). `self` is the actor object pointer.
        if kind == .actor_ {
            guard let recvValue = lowerExpr(receiver) else { return nil }
            return lowerActorCall(typeName, method, recvValue, args, span)
        }

        declareMethod(typeName, method)
        guard let c = callables["m:\(typeName):\(method)"] else { return nil }

        // How `self` reaches the callee: a class receiver's value already *is* the object pointer;
        // a struct/enum mutating method wants the address of the (mutable) receiver value; a
        // read-only value method takes a copy of the value.
        let selfArg: LLVMValueRef?
        if kind == .class_ {
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
        if c.selfByPointer {
            // A class/actor impl takes the managed object pointer directly. A struct/enum mutating
            // impl takes an addrspace(0) pointer to a stack-ABI value, so cast the heap box down.
            if classMap[type] != nil || actorMap[type] != nil { return payload }
            return toUnmanaged(payload)
        }
        guard let st = selfLLVMType(type) else { return nil }
        return LLVMBuildLoad2(b, st, payload, "self")
    }

    // A uniform-signature thunk `ret(ptr self, params…)` wrapping the concrete impl: it bridges
    // `self` (the payload pointer) to the impl's ABI — by value for a read-only value method, by
    // pointer for a mutating / class method — and re-boxes a covariant-`Self` result as `any iface`.
    private func methodThunk(_ type: String, _ iface: String, _ m: NOIRMethodReq) -> LLVMValueRef? {
        guard let retTy = llvmType(m.ret, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
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
    private func propThunk(_ type: String, _ iface: String, _ p: NOIRPropReq, setter: Bool) -> LLVMValueRef? {
        guard let propTy = llvmType(p.type, zeroSpan) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
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
                storeField(payload, addr, LLVMGetParam(fn, 1)!)
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
                                 payload: LLVMValueRef, args: [NOIRExpr], resultType: Type,
                                 span: Span) -> LLVMValueRef? {
        let slot = method.replacingOccurrences(of: ".", with: "_")
        let idx = witnessSlotIndex(iface, slot)
        guard idx >= 0 else { fail("8.2.5: no witness slot '\(slot)' in '\(iface)'", span); return nil }
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(witnessType(iface), witnessPtr, idx), "slot")!

        guard let retTy = llvmType(resultType, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [p1]   // self/payload — the managed box pointer (addrspace 1)
        var argVals: [LLVMValueRef?] = [payload]
        for a in args {
            guard let t = llvmType(a.type, span), let v = lowerExpr(a) else { return nil }
            paramTys.append(t); argVals.append(v)
        }
        return buildCall(fnPtr, fnType(retTy, paramTys), argVals)
    }

    // Wrap a concrete conformer as `any I` / `any A & B`, or upcast `any B` → `any A`.
    private func lowerBox(_ value: NOIRExpr, _ ifaces: [String], _ span: Span) -> LLVMValueRef? {
        // `any B` → `any A`: re-box through the source witness's base pointer, keeping the payload.
        if case .existential(let src) = value.type, ifaces.count == 1 {
            guard let box = lowerExpr(value) else { return nil }
            let witnessPtr = anyBoxWitness(box)
            let payload = anyBoxPayload(box)
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
            let p = rtAllocManaged(LLVMConstInt(i64, UInt64(bytes), 0))
            LLVMBuildStore(b, v, p)
            return p
        }
    }

    // An `any I` value is a managed pointer to a heap `{ i8ptr witness, p1 payload }` box (8.4.1):
    // keeping the box behind a `p1` pointer means the value the mutator holds and passes across
    // calls is a single scalar GC reference the rewrite pass tracks, never a first-class aggregate
    // with a GC pointer nested inside (which the pass cannot relocate). The witness is a static
    // table (addrspace 0); the payload is the managed object / heap value-copy pointer (addrspace 1).
    private func makeAnyBox(_ witness: LLVMValueRef, _ payload: LLVMValueRef) -> LLVMValueRef {
        let box = rtAllocManaged(LLVMConstInt(i64, 24, 0))   // header + witness + payload
        LLVMBuildStore(b, LLVMConstInt(i64, anyBoxTypeId(), 0), structGEP(anyBoxTy, box, 0)) // header
        storeField(box, structGEP(anyBoxTy, box, 1), witness)   // witness (addrspace 0) → plain store
        storeField(box, structGEP(anyBoxTy, box, 2), payload)   // payload (managed) → write barrier
        return box
    }

    private func anyBoxWitness(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, i8ptr, structGEP(anyBoxTy, box, 1), "wt")!
    }
    private func anyBoxPayload(_ box: LLVMValueRef) -> LLVMValueRef {
        LLVMBuildLoad2(b, p1, structGEP(anyBoxTy, box, 2), "pl")!
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
        let scope: LLVMMetadataRef?
        let debugLoc: LLVMMetadataRef?
        let loops: [LoopCtx]
    }

    private func enterThunk(_ fn: LLVMValueRef, line: Int = 0) -> ThunkState {
        let saved = ThunkState(block: LLVMGetInsertBlock(b), locals: locals, self_: currentSelf, fn: currentFn,
                               spawnLocals: spawnLocals, activeSpawns: activeSpawns,
                               scope: currentScope, debugLoc: di != nil ? LLVMGetCurrentDebugLocation2(b) : nil,
                               loops: loopStack)
        currentFn = fn; currentSelf = nil; locals = [:]
        spawnLocals = [:]; activeSpawns = []; loopStack = []
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        enterDebugScope(fn, line: line)
        return saved
    }

    private func leaveThunk(_ saved: ThunkState) {
        locals = saved.locals; currentSelf = saved.self_; currentFn = saved.fn
        spawnLocals = saved.spawnLocals; activeSpawns = saved.activeSpawns
        loopStack = saved.loops
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
    // `baseIndex` is the field index of the first capture in `envTy` — 0 for a spawn env object,
    // 1 for a fused closure object (whose field 0 is the fn pointer).
    private func loadCapturesIntoScope(_ caps: [Capture], _ envTy: LLVMTypeRef, _ env: LLVMValueRef, baseIndex: Int = 0) {
        for (i, cap) in caps.enumerated() {
            let slot = LLVMBuildAlloca(b, cap.local.ty, cap.name)!
            let v = LLVMBuildLoad2(b, cap.local.ty, structGEP(envTy, env, i + baseIndex), cap.name)
            LLVMBuildStore(b, v, slot)
            locals[cap.name] = (slot, cap.local.ty)
        }
    }

    // At a `spawn` capture site: heap-allocate the env and copy each capture's current value into
    // it. The env is a managed (addrspace 1) object; the spawn site casts it to addrspace(0) for
    // the `fiber_spawn` boundary (D1). (Closures don't use this — they fuse captures into the
    // closure object; see `lowerClosure`.)
    private func allocAndFillEnv(_ caps: [Capture], _ envTy: LLVMTypeRef) -> LLVMValueRef {
        let bytes = caps.reduce(0) { $0 + abiSlots($1.local.ty) } * 8
        let envPtr = rtAllocManaged(LLVMConstInt(i64, UInt64(max(bytes, 8)), 0))
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            storeField(envPtr, structGEP(envTy, envPtr, i), v)
        }
        return envPtr
    }

    // A closure lowers to a hoisted impl function `ret nomu_cloN(ptr obj, params…)` plus a site
    // that heap-allocates one fused object `{ fn, caps… }` and yields a managed pointer to it (the
    // closure value). Fusing the captures inline after the fn pointer makes creation a single
    // allocation, and the value is one scalar `p1` the rewrite pass tracks — no `{fn,env}` aggregate
    // rides across a safepoint (8.4.1). The impl receives the object as its first param and reads
    // its captures from fields 1…N. Captures are the body's free variables that name enclosing locals.
    private func lowerClosure(params: [NOIRParam], body: [NOIRStmt], ret: Type, span: Span) -> LLVMValueRef? {
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUses(body, bound: &bound, used: &used)
        let caps = resolveCaptures(used)
        let objTy = structTy([i64, i8ptr] + caps.map { $0.local.ty })   // { header, fn, cap0, cap1, … }

        // 6.5.2 — a non-escaping closure whose captures are all scalar leaves gets a stack env: the
        // impl takes its env as an addrspace(0) pointer and the site `alloca`s it, so the fused object
        // never heaps. The env holds no managed pointers, so it needs no scanning; escape analysis
        // proved the closure is only invoked locally, never stored/passed/returned.
        let stackEnv = escapes.isNonEscaping(span, .closure) && caps.allSatisfy { isScalarLeaf($0.local.ty) }
        let envTy: LLVMTypeRef = stackEnv ? i8ptr : p1

        guard let retTy = llvmType(ret, span) else { return nil }
        var paramTys: [LLVMTypeRef] = [envTy]   // the closure object itself, captures read via GEP
        for p in params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            paramTys.append(t)
        }
        let (fn, _) = emitFunction("nomu_clo\(closureSeq)", ret: retTy, params: paramTys,
                                   debug: ("closure", span.begin.line))
        closureSeq += 1

        // Define the impl body against a fresh scope (captures loaded from the object + params),
        // then restore the enclosing builder position and lowering state. A fresh scope, including
        // spawn/actor state — the body's `return` must not join the enclosing function's spawns
        // (that would reference its allocas from another function).
        let saved = enterThunk(fn, line: span.begin.line)
        loadCapturesIntoScope(caps, objTy, LLVMGetParam(fn, 0)!, baseIndex: 2)
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

        // Site: allocate the fused object, store the fn pointer then each capture by value, and
        // yield the managed pointer as the closure value.
        let slots = 2 + caps.reduce(0) { $0 + abiSlots($1.local.ty) }   // header + fn + captures
        let obj = stackEnv ? entryAlloca(objTy, "clo.env")
                           : rtAllocManaged(LLVMConstInt(i64, UInt64(slots * 8), 0))
        LLVMBuildStore(b, LLVMConstInt(i64, closureTypeId(caps), 0), structGEP(objTy, obj, 0)) // header
        LLVMBuildStore(b, fn, structGEP(objTy, obj, 1))                                          // fn
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            storeField(obj, structGEP(objTy, obj, i + 2), v)
        }
        return obj
    }

    // MARK: - Structured concurrency (8.2.6)

    // `spawn let name = value` runs `value` on a fiber. Like a closure, the value's free variables
    // are captured by value into a heap env; a hoisted start routine `void* nomu_spawnN(void* env)`
    // computes the value and returns a heap box of the result. The site starts the fiber and stores
    // its handle; reads of `name` (and scope/function exit) join it.
    private func lowerSpawnLet(name: String, value: NOIRExpr, resultType: Type, span: Span) {
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
            let boxp = rtAllocManaged(LLVMConstInt(i64, UInt64(bytes), 0))
            storeField(boxp, boxp, rv)   // a reference result goes through the barrier; a value is a plain store
            // The routine returns the box to the runtime as a `void*` (addrspace 0); `spawn_join`
            // hands it back and `joinSpawn` reads the result out of it.
            LLVMBuildRet(b, toUnmanaged(boxp))
        } else if !blockTerminated() {
            LLVMBuildRet(b, LLVMConstPointerNull(i8ptr))
        }
        leaveThunk(saved)

        // Site: allocate + fill the env, start the fiber, keep its handle for joins. The env is
        // managed (addrspace 1), but the runtime holds it as a `void*` between spawn and the
        // routine's call, so it crosses the C ABI as addrspace(0) — one boundary cast (D1). The
        // spawn routine's env param and its returned result box stay addrspace(0) for the same
        // reason (runtime-owned across the fiber boundary); M6's parked-fiber scan (D4) traces them.
        let envPtr = allocAndFillEnv(caps, envTy)
        let spawn = runtimeFn("fiber_spawn", ret: i8ptr, params: [i8ptr, i8ptr], varArg: false)
        let fiber = buildCall(spawn.0, spawn.1, [fn, toUnmanaged(envPtr)])!
        let handleSlot = entryAlloca(spawnHandleTy, "\(name).h")
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
    private func lowerSleep(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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

    // ---- Array<T> (M6 stdlib · Slice 3) ----
    // A reference `Array<T>` value is a managed pointer to a fixed handle `{ i64 header, i64 len, p1
    // bufptr }` (24 bytes). The buffer is a separate variable-size GC object `{ i64 header, i64 cap,
    // elems… }`; element i is at byte 16 + i*stride, in T's natural representation. Reference semantics
    // (the handle is shared). GC sizing/scanning of the variable-size buffer is Slice 4; under NoGC the
    // buffer header is inert (small programs under Immix don't trigger a collection either).

    // One element's byte stride in the buffer — 8-aligned slots, matching the GC pointer-map layout.
    private func arrayElemStride(_ t: Type) -> Int { max(slotCount(t) * 8, 8) }

    // GEP a managed pointer by a byte offset (`i8`-typed indexing), yielding a p1 to that byte.
    private func gepByte(_ ptr: LLVMValueRef, _ off: LLVMValueRef) -> LLVMValueRef {
        let i8 = LLVMInt8TypeInContext(ctx)
        var idx: LLVMValueRef? = off
        return withUnsafeMutablePointer(to: &idx) { LLVMBuildGEP2(b, i8, ptr, $0, 1, "aoff")! }
    }

    // The shared type-id for every Array handle — identical layout for all T (one managed field,
    // bufptr at byte 16), so it is a fixed-size object using the ordinary 6.1.3 map.
    private func arrayHandleTypeId() -> UInt64 {
        if let id = arrayHandleMapId { return id }
        let id = registerMap([16], sizeBytes: 24)
        arrayHandleMapId = id
        return id
    }

    // The array-buffer type-id for element type `elem` (M6 stdlib · Slice 4): a variable-size object
    // whose per-element managed-pointer offsets are `elem`'s own managed offsets, repeated `cap` times
    // by the collector. Registered once per element type.
    private func arrayBufTypeId(_ elem: Type) -> UInt64 {
        let key = elem.description
        if let id = arrayBufMapIds[key] { return id }
        var elemOffsets: [Int32] = []
        collectManagedOffsets(elem, baseSlot: 0, into: &elemOffsets)
        let id = registerArrayMap(elemOffsets, stride: Int32(arrayElemStride(elem)))
        arrayBufMapIds[key] = id
        return id
    }

    // [e0, e1, …] → allocate the handle + (for a non-empty literal) the buffer, stamp headers, store
    // each element. Returns the handle (the Array value, a managed pointer).
    private func lowerArrayLit(_ elements: [NOIRExpr], _ arrayType: Type, _ span: Span) -> LLVMValueRef? {
        guard case .array(let elem) = arrayType else { fail("array literal has non-array type", span); return nil }
        let stride = arrayElemStride(elem)
        let n = elements.count
        let handle = rtAllocManaged(LLVMConstInt(i64, 24, 0))
        LLVMBuildStore(b, LLVMConstInt(i64, arrayHandleTypeId(), 0), handle)                            // header
        LLVMBuildStore(b, LLVMConstInt(i64, UInt64(n), 0), gepByte(handle, LLVMConstInt(i64, 8, 0)))   // len
        // Always allocate a buffer (cap = n, possibly 0), so `bufptr` is never null and append can
        // read `cap` without a null guard. Buffer header carries the array-kind type-id (Slice 4).
        let buf = rtAllocManaged(LLVMConstInt(i64, UInt64(16 + n * stride), 0))
        LLVMBuildStore(b, LLVMConstInt(i64, arrayBufTypeId(elem), 0), buf)                             // header
        LLVMBuildStore(b, LLVMConstInt(i64, UInt64(n), 0), gepByte(buf, LLVMConstInt(i64, 8, 0)))      // cap
        for (i, el) in elements.enumerated() {
            guard let v = lowerExpr(el) else { return nil }
            // Barriered: a preceding element's construction can allocate and (via a GC) promote `buf`
            // to the mature space, so a later managed-element store into it needs remembering (6.3.1).
            storeField(buf, gepByte(buf, LLVMConstInt(i64, UInt64(16 + i * stride), 0)), v)
        }
        storeField(handle, gepByte(handle, LLVMConstInt(i64, 16, 0)), buf)                             // bufptr
        return handle
    }

    // Bounds-checked p1 address of element `idxV` in `handle`. The unsigned compare `idx >= len`
    // catches negative and too-large in one test; an out-of-range index traps in the runtime (never
    // returns). On return the builder sits in the in-bounds block. Returns both the buffer object base
    // (`buf`, needed as the write-barrier source for a managed-element store) and the element address.
    private func arrayElemAddr(_ handle: LLVMValueRef, _ idxV: LLVMValueRef, _ elemType: Type)
        -> (buf: LLVMValueRef, addr: LLVMValueRef)? {
        guard let fn = currentFn else { return nil }
        let len = LLVMBuildLoad2(b, i64, gepByte(handle, LLVMConstInt(i64, 8, 0)), "arr.len")!
        let oob = LLVMBuildICmp(b, LLVMIntUGE, idxV, len, "arr.oob")!
        let trapBB = LLVMAppendBasicBlockInContext(ctx, fn, "arr.trap")!
        let okBB = LLVMAppendBasicBlockInContext(ctx, fn, "arr.ok")!
        LLVMBuildCondBr(b, oob, trapBB, okBB)
        LLVMPositionBuilderAtEnd(b, trapBB)
        let trap = runtimeFn("rt_bounds_trap", ret: LLVMVoidTypeInContext(ctx), params: [i64, i64], varArg: false)
        _ = buildCall(trap.0, trap.1, [idxV, len])
        LLVMBuildUnreachable(b)
        LLVMPositionBuilderAtEnd(b, okBB)
        let buf = LLVMBuildLoad2(b, p1, gepByte(handle, LLVMConstInt(i64, 16, 0)), "arr.buf")!
        let stride = LLVMConstInt(i64, UInt64(arrayElemStride(elemType)), 0)
        let off = LLVMBuildAdd(b, LLVMConstInt(i64, 16, 0), LLVMBuildMul(b, idxV, stride, "arr.mul"), "arr.off")!
        return (buf, gepByte(buf, off))
    }

    // a[i] → bounds-checked element load.
    private func lowerIndex(_ base: NOIRExpr, _ idx: NOIRExpr, _ elemType: Type, _ span: Span) -> LLVMValueRef? {
        guard let handle = lowerExpr(base), let idxV = lowerExpr(idx), let elemLL = llvmType(elemType, span),
              let e = arrayElemAddr(handle, idxV, elemType) else { return nil }
        return LLVMBuildLoad2(b, elemLL, e.addr, "arr.elem")
    }

    // a[i] = x → bounds-checked element store (args: handle, index, value). Result unused. A managed
    // element goes through the write barrier (`storeField`) with the buffer as the source object, so a
    // store into a mature buffer remembers it (6.3.1); a value element is a plain store.
    private func lowerArraySet(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard args.count == 3 else { fail("__arraySet expects 3 args", span); return nil }
        guard let handle = lowerExpr(args[0].value), let idxV = lowerExpr(args[1].value),
              let val = lowerExpr(args[2].value),
              let e = arrayElemAddr(handle, idxV, args[2].value.type) else { return nil }
        storeField(e.buf, e.addr, val)
        return LLVMConstInt(i64, 0, 0)
    }

    // a.append(x) → grow the buffer if full, store x at index len, bump len. Result unused. Grow is
    // done here (not in C) so the buffer allocation is a statepoint: the rewrite pass relocates the
    // handle/old-buffer/value across it, and we reload the current buffer from the (relocated) handle
    // afterward — a raw C pointer could not survive a moving collection.
    private func lowerArrayAppend(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else { fail("__arrayAppend expects 2 args", span); return nil }
        let elem = args[1].value.type
        guard let handle = lowerExpr(args[0].value), let val = lowerExpr(args[1].value), let fn = currentFn else { return nil }
        let stride = arrayElemStride(elem)
        let strideV = LLVMConstInt(i64, UInt64(stride), 0)
        let len = LLVMBuildLoad2(b, i64, gepByte(handle, LLVMConstInt(i64, 8, 0)), "app.len")!
        let buf0 = LLVMBuildLoad2(b, p1, gepByte(handle, LLVMConstInt(i64, 16, 0)), "app.buf")!
        let cap = LLVMBuildLoad2(b, i64, gepByte(buf0, LLVMConstInt(i64, 8, 0)), "app.cap")!
        let full = LLVMBuildICmp(b, LLVMIntUGE, len, cap, "app.full")!
        let growBB = LLVMAppendBasicBlockInContext(ctx, fn, "app.grow")!
        let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "app.cont")!
        LLVMBuildCondBr(b, full, growBB, contBB)

        // Grow: newCap = cap==0 ? 4 : cap*2; allocate, stamp header + cap, copy the live elements,
        // publish the new buffer into the handle. GEPs off `handle` after the alloc use the relocated
        // handle (the rewrite pass rewrites the operand), so they never dangle.
        LLVMPositionBuilderAtEnd(b, growBB)
        let isZero = LLVMBuildICmp(b, LLVMIntEQ, cap, LLVMConstInt(i64, 0, 0), "app.cap0")!
        let dbl = LLVMBuildMul(b, cap, LLVMConstInt(i64, 2, 0), "app.dbl")!
        let newCap = LLVMBuildSelect(b, isZero, LLVMConstInt(i64, 4, 0), dbl, "app.newcap")!
        let newBytes = LLVMBuildAdd(b, LLVMConstInt(i64, 16, 0), LLVMBuildMul(b, newCap, strideV, "app.nb"), "app.bytes")!
        let newBuf = rtAllocManaged(newBytes)   // statepoint: handle/buf0/val relocated across this
        LLVMBuildStore(b, LLVMConstInt(i64, arrayBufTypeId(elem), 0), newBuf)                       // header
        LLVMBuildStore(b, newCap, gepByte(newBuf, LLVMConstInt(i64, 8, 0)))                         // cap
        let copyBytes = LLVMBuildMul(b, len, strideV, "app.copy")!
        let memcpy = runtimeFn("memcpy", ret: i8ptr, params: [i8ptr, i8ptr, i64], varArg: false)
        _ = buildCall(memcpy.0, memcpy.1, [toUnmanaged(gepByte(newBuf, LLVMConstInt(i64, 16, 0))),
                                           toUnmanaged(gepByte(buf0, LLVMConstInt(i64, 16, 0))), copyBytes])
        storeField(handle, gepByte(handle, LLVMConstInt(i64, 16, 0)), newBuf)   // publish (barriered: handle may be mature)
        LLVMBuildBr(b, contBB)

        // Store the element into the current buffer (reloaded from the handle so it is the grown one
        // on the grow path) and bump len. Barriered: a managed element into a possibly-mature buffer
        // (the un-grown path) must remember it (6.3.1); a value element is a plain store.
        LLVMPositionBuilderAtEnd(b, contBB)
        let buf = LLVMBuildLoad2(b, p1, gepByte(handle, LLVMConstInt(i64, 16, 0)), "app.buf2")!
        let off = LLVMBuildAdd(b, LLVMConstInt(i64, 16, 0), LLVMBuildMul(b, len, strideV, "app.mul"), "app.off")!
        storeField(buf, gepByte(buf, off), val)
        LLVMBuildStore(b, LLVMBuildAdd(b, len, LLVMConstInt(i64, 1, 0), "app.inc"), gepByte(handle, LLVMConstInt(i64, 8, 0)))
        return LLVMConstInt(i64, 0, 0)
    }

    // `a.count` → load `len` from the handle (no allocation, no safepoint).
    private func lowerArrayCount(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let a = args.first, let handle = lowerExpr(a.value) else { return nil }
        return LLVMBuildLoad2(b, i64, gepByte(handle, LLVMConstInt(i64, 8, 0)), "arr.count")
    }

    private func lowerCall(callee: NOIRExpr, args: [NOIRArg], span: Span) -> LLVMValueRef? {
        if case .varRef(let name) = callee.kind {
            // C-leaf builtins (same-named C symbol, signature encoded in the name) lower generically.
            if Builtins.cLeaf.contains(name) { return lowerCLeafBuiltin(name, args, span) }
            switch name {
            case "print":  return lowerPrint(args, span)
            case "concat": return lowerConcat(args, span)
            case "sleep":  return lowerSleep(args, span)
            case "readLine": return lowerReadLine()
            case "__array_count_int": return lowerArrayCount(args, span)
            case "__arraySet": return lowerArraySet(args, span)
            case "__arrayAppend": return lowerArrayAppend(args, span)
            case "__int_double_double": return lowerIntToDouble(args, span)
            case "__double_int_int": return lowerDoubleToInt(args, span)
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
        guard let cval = lowerExpr(callee) else { return nil }   // the closure object pointer
        let fnPtr = LLVMBuildLoad2(b, i8ptr, structGEP(closureHdrTy, cval, 1), "clo.fn")!
        guard let retTy = llvmType(rty, span) else { return nil }
        // The env param takes the closure value's actual address space: p1 for a heap closure, addr0
        // for a 6.5.2 stack-allocated one — matching the impl generated in `lowerClosure`.
        var paramTys: [LLVMTypeRef] = [LLVMTypeOf(cval)!]
        for t in ptys {
            guard let lt = llvmType(t, span) else { return nil }
            paramTys.append(lt)
        }
        return buildArgsAndCall(fnType(retTy, paramTys), fnPtr, env: cval, args: args)
    }

    // Lower `args`, optionally prefixed by a closure `env`, and emit the call.
    private func buildArgsAndCall(_ fnTy: LLVMTypeRef, _ fn: LLVMValueRef, env: LLVMValueRef?, args: [NOIRArg]) -> LLVMValueRef? {
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

    private func collectUses(_ stmts: [NOIRStmt], bound: inout Set<String>, used: inout [String]) {
        for s in stmts { collectUsesStmt(s, bound: &bound, used: &used) }
    }

    private func collectUsesStmt(_ stmt: NOIRStmt, bound: inout Set<String>, used: inout [String]) {
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
        case .whileStmt(let cond, let body):
            collectUsesExpr(cond, bound: bound, used: &used)
            var wb = bound; collectUses(body, bound: &wb, used: &used)
        case .breakStmt, .continueStmt:
            break
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

    private func collectUsesExpr(_ e: NOIRExpr, bound: Set<String>, used: inout [String]) {
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit:
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
        case .arrayLit(let elements):
            for el in elements { collectUsesExpr(el, bound: bound, used: &used) }
        case .index(let base, let idx):
            collectUsesExpr(base, bound: bound, used: &used)
            collectUsesExpr(idx, bound: bound, used: &used)
        }
    }

    // print(Int|Bool) → printf("%lld\n", n);  print(String) → printf("%.*s\n", (int)len, data).
    private func lowerPrint(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first, let value = lowerExpr(arg.value) else {
            fail("8.2.1: print expects one argument", span)
            return nil
        }
        let (fn, ty) = runtimeFn("printf", ret: i32, params: [i8ptr], varArg: true)
        switch arg.value.type {
        case .int:
            return buildCall(fn, ty, [intFormat(), value])
        case .double:
            // Formatting (shortest round-trip, always a decimal point) lives in the C floor.
            let (pf, pty) = runtimeFn("rt_print_double", ret: voidTy, params: [f64], varArg: false)
            return buildCall(pf, pty, [value])
        case .bool:
            // Bool is i1; printf's `%lld` reads an i64, so widen to i64 (prints 0/1 as before). (8.5.2)
            return buildCall(fn, ty, [intFormat(), LLVMBuildZExt(b, value, i64, "b2i")])
        case .string:
            let data = LLVMBuildExtractValue(b, value, 0, "data")
            let len = LLVMBuildExtractValue(b, value, 1, "len")
            let len32 = LLVMBuildTrunc(b, len, i32, "len32")
            return buildCall(fn, ty, [strFormat(), len32, data])
        default:
            fail("8.2.1: print supports Int, Double, Bool, or String", arg.value.span)
            return nil
        }
    }

    // `i.double` — widen Int (i64) to Double (f64), signed. Exact for values up to 2^53.
    private func lowerIntToDouble(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let v = args.first.flatMap({ lowerExpr($0.value) }) else {
            fail("__int_double_double expects one argument", span); return nil
        }
        return LLVMBuildSIToFP(b, v, f64, "i2d")
    }

    // `d.int` — narrow Double (f64) to Int (i64), rounding to nearest with ties away from zero
    // (`llvm.round`), then a signed truncation to integer.
    private func lowerDoubleToInt(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let v = args.first.flatMap({ lowerExpr($0.value) }) else {
            fail("__double_int_int expects one argument", span); return nil
        }
        let (fn, ty) = runtimeFn("llvm.round.f64", ret: f64, params: [f64], varArg: false)
        let rounded = buildCall(fn, ty, [v])!
        return LLVMBuildFPToSI(b, rounded, i64, "d2i")
    }

    // A C-leaf builtin: a call to the same-named C function, with parameter/return types read from
    // the mangled name (`__<recv>_<name>_<ret>[_<arg>...]`). The receiver is the first argument. A
    // `Bool` return arrives as the C `int` result and is truncated to i1.
    private func lowerCLeafBuiltin(_ name: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        let sig = Builtins.signature(name)
        var vals: [LLVMValueRef] = []
        for a in args {
            guard let v = lowerExpr(a.value) else { return nil }
            vals.append(v)
        }
        let paramTys = ([sig.receiver] + sig.params).map { cType($0) }
        let retIsBool = sig.ret == .bool
        let retTy = retIsBool ? i64 : cType(sig.ret)   // C returns int for Bool; narrow below
        let (fn, ty) = runtimeFn(name, ret: retTy, params: paramTys, varArg: false)
        guard let r = buildCall(fn, ty, vals) else { return nil }
        return retIsBool ? LLVMBuildTrunc(b, r, i1, "b") : r
    }

    // The LLVM type a builtin value uses at the C boundary. Mirrors `llvmType` for the scalar/String
    // cases builtins traffic in; `Bool` is handled at the return site (i64 in, truncated to i1).
    private func cType(_ t: Type) -> LLVMTypeRef {
        switch t {
        case .string: return strTy
        case .double: return f64
        case .bool:   return i1
        default:      return i64   // Int (and Void params never occur)
        }
    }

    private func lowerConcat(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    //
    // 8.4.1 — every function *we emit a body for* (free fns, methods, actor handlers, witness/
    // property thunks, closures, spawn routines) is `gc "statepoint-example"`: any of them can be a
    // frame at a safepoint, so the caller needs a stack map at each of its calls (m6-spec.md §6.0.8).
    // Runtime C declarations pass `gc: false` (`runtimeFn`) and stay plain.
    private func emitFunction(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef],
                              varArg: Bool = false, gc: Bool = true,
                              debug: (name: String, line: Int)? = nil) -> (fn: LLVMValueRef, ty: LLVMTypeRef) {
        let ty = fnType(ret, params, varArg: varArg)
        let fn = LLVMAddFunction(mod, name, ty)!
        if gc { LLVMSetGC(fn, "statepoint-example") }
        if let debug = debug, let sp = makeSubprogram(debug.name, linkage: name, line: debug.line) {
            LLVMSetSubprogram(fn, sp)
        }
        return (fn, ty)
    }

    // Runtime C functions that never allocate on the GC heap and never park the fiber, so a GC can
    // never run across them. Marking their declarations `"gc-leaf-function"` tells the rewrite pass
    // to leave their calls as plain calls instead of statepoints — no root spill/reload around them
    // (m6-spec.md §6.0.8, perf lever). Conservative: when unsure, a call stays non-leaf, since
    // mislabeling a GC-triggering call as leaf is the unsound direction. 6.1.4: `rt_str_concat`
    // allocates (→ can trigger GC), so it is non-leaf (a statepoint recording the caller's roots);
    // `rt_str_lit` still only wraps a static pointer (no alloc), so it stays leaf. `String` staying a
    // runtime-owned value (buffer `addr0`) is why its value never becomes a GC root here — the full
    // GC-object form (Q6) needs `String` heap-boxed (the FCA limit), deferred with 6.2.
    private static let gcLeafRuntimeFns: Set<String> = [
        "printf", "rt_str_lit", "rt_mutex_new", "rt_mutex_unlock",
        "rt_bounds_trap",   // aborts, never allocates — no statepoint needed
        "memcpy",           // libc block copy — never allocates (array grow)
        "memset",           // libc fill — zeroes the inline-allocated object; never allocates
        "rt_gc_write_barrier",   // M6 · 6.3.1 — remembers the mutated object; never triggers GC
    ]

    private func markGCLeaf(_ fn: LLVMValueRef) {
        let name = "gc-leaf-function"
        let attr = LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, attr)
    }

    private var funcAttrIndex: LLVMAttributeIndex {
        LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex))
    }

    private func addAlwaysInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("alwaysinline", "alwaysinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    // Build a stub seam's body without disturbing the caller's builder position / debug location
    // (a seam stub carries no subprogram, so a foreign `!dbg` would trip the verifier).
    private func withStubBody(_ fn: LLVMValueRef, _ build: () -> Void) {
        let savedBlock = LLVMGetInsertBlock(b)
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        if di != nil { LLVMSetCurrentDebugLocation2(b, nil) }
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        build()
        if let savedBlock = savedBlock { LLVMPositionBuilderAtEnd(b, savedBlock) }
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

    // MARK: - Inline seams (8.4.4, D5)

    // Each of the three mutator seams — alloc / write-barrier / poll — is emitted as a call to an
    // `alwaysinline` stub with a trivial, provably-inert body (D5's "seam representation"). Keeping
    // the inert phase as a call into a one-line stub (rather than open-coding the disabled fast path
    // at every site) gives M6 a single body to fill; once filled, `alwaysinline` collapses the call
    // sites into the inline fast path. All three are behavior-neutral now: alloc tail-calls
    // `rt_alloc`, the barrier is a plain store, the poll is a no-op.

    // The external stop-world flag (`volatile int __nomu_stop_world`, runtime.c) the poll tests.
    private func stopWorldGlobal() -> LLVMValueRef {
        if let g = stopWorldGlobalCache { return g }
        let g = LLVMAddGlobal(mod, i32, "__nomu_stop_world")!   // no initializer → external declaration
        stopWorldGlobalCache = g
        return g
    }

    // The `__nomu_poll` seam (M6 · 6.2.3, Q3 branch-on-flag). Filled: load the per-process stop-world
    // flag; if unset (the common case) fall through — a plain load + test + branch, no statepoint; if
    // set, call `__nomu_gc_poll_slow`, which is **not** `gc-leaf`, so that call is a statepoint whose
    // stack map records the loop's live roots, and the carrier parks there precisely scannable (6.2.1).
    // `alwaysinline` + the pass pipeline's `always-inline` (LLVMBridge) collapse the fast path into the
    // loop, so only the cold slow path carries statepoint cost (Q4: the poll stays cheap).
    private func nomuPoll() -> (LLVMValueRef, LLVMTypeRef) {
        if let p = pollFn { return p }
        let ty = fnType(voidTy, [])
        let fn = LLVMAddFunction(mod, "__nomu_poll", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        addAlwaysInline(fn)   // not `gc-leaf`: the slow path calls a statepoint
        let flag = stopWorldGlobal()
        let slow = runtimeFn("__nomu_gc_poll_slow", ret: voidTy, params: [], varArg: false)
        withStubBody(fn) {
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.slow")
            let contBB = LLVMAppendBasicBlockInContext(ctx, fn, "poll.cont")
            let v = LLVMBuildLoad2(b, i32, flag, "stopreq")!
            LLVMSetVolatile(v, 1)
            let stop = LLVMBuildICmp(b, LLVMIntNE, v, LLVMConstInt(i32, 0, 0), "stop")
            LLVMBuildCondBr(b, stop, slowBB, contBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            _ = buildCall(slow.0, slow.1, [])
            LLVMBuildBr(b, contBB)
            LLVMPositionBuilderAtEnd(b, contBB)
            LLVMBuildRetVoid(b)
        }
        pollFn = (fn, ty)
        return pollFn!
    }

    private func emitSafepointPoll() {
        let p = nomuPoll()
        _ = buildCall(p.0, p.1, [])
    }

    // The `__nomu_gc_alloc` seam: `ptr addrspace(1) (i64 size)`, emitted at every managed-object
    // allocation. §6.6.2 — the inline bump-pointer fast path. Read the per-carrier mutator (a thread-
    // local, §6.6.1) and the published `{cursor, limit}` `BumpPointer` at `__nomu_bump_offset`; bump the
    // cursor and return it when the object fits and is not LOS-sized; else tail-call `rt_alloc` (the
    // slow path — a statepoint, so this function is **not** `gc-leaf`). The returned memory is zeroed
    // (Nomu's zero-init-fields contract; the actor mailbox and array buffers rely on it), matching
    // `rt_alloc`'s `memset`. The bump loads/stores sit in a call-free block, so nothing hoists across a
    // safepoint (the only safepoint is the slow-path `rt_alloc` call, which clobbers the mutator memory).
    private func nomuGcAlloc() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = gcAllocFn { return g }
        let ty = fnType(p1, [i64])
        let fn = LLVMAddFunction(mod, "__nomu_gc_alloc", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        LLVMSetGC(fn, "statepoint-example")   // its slow-path `rt_alloc` call is a statepoint
        addAlwaysInline(fn)
        // A/B: revert to the pre-6.6 out-of-line body when the inline path is disabled.
        guard inlineAlloc else {
            withStubBody(fn) { LLVMBuildRet(b, buildCall(rtAlloc(), rtAllocTy(), [LLVMGetParam(fn, 0)])!) }
            gcAllocFn = (fn, ty)
            return gcAllocFn!
        }
        // External state published by the GC binding (§6.6.1): the Default-semantics bump offset, the
        // LOS threshold, and the per-carrier mutator (thread-local). No initializer → declarations.
        let gOff = LLVMAddGlobal(mod, i64, "__nomu_bump_offset")!
        let gMax = LLVMAddGlobal(mod, i64, "__nomu_max_non_los")!
        let gMut = LLVMAddGlobal(mod, i8ptr, "rt_mutator")!
        LLVMSetThreadLocal(gMut, 1)
        let memset = runtimeFn("memset", ret: i8ptr, params: [i8ptr, i32, i64], varArg: false)
        withStubBody(fn) {
            let size = LLVMGetParam(fn, 0)!
            let fastBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.fast")!
            let bumpBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.bump")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "alloc.done")!
            // entry guards: fast path only if the offset is published (!= usize::MAX), the mutator is
            // bound (!= null — else lazy-bind happens in `rt_alloc`), and the size is not LOS-routed.
            let off = LLVMBuildLoad2(b, i64, gOff, "bump.off")!
            let offOk = LLVMBuildICmp(b, LLVMIntNE, off, LLVMConstInt(i64, .max, 0), "off.ok")!
            let mut = LLVMBuildLoad2(b, i8ptr, gMut, "mutator")!
            let mutOk = LLVMBuildICmp(b, LLVMIntNE, mut, LLVMConstPointerNull(i8ptr), "mut.ok")!
            let maxlos = LLVMBuildLoad2(b, i64, gMax, "maxlos")!
            let sizeOk = LLVMBuildICmp(b, LLVMIntULE, size, maxlos, "size.ok")!
            let canFast = LLVMBuildAnd(b, LLVMBuildAnd(b, offOk, mutOk, "g1"), sizeOk, "canfast")!
            LLVMBuildCondBr(b, canFast, fastBB, slowBB)
            // fast: load cursor/limit; align the cursor to 8 (a no-op for our 8-aligned sizes, kept to
            // match MMTk's `align_allocation`); bump; take it if it fits.
            LLVMPositionBuilderAtEnd(b, fastBB)
            let cursorPtr = gepByte(mut, off)
            let cursor = LLVMBuildLoad2(b, i64, cursorPtr, "cursor")!
            let aligned = LLVMBuildAnd(b, LLVMBuildAdd(b, cursor, LLVMConstInt(i64, 7, 0), "c+7"),
                                       LLVMConstInt(i64, ~UInt64(7), 0), "aligned")!
            let off8 = LLVMBuildAdd(b, off, LLVMConstInt(i64, 8, 0), "off+8")!
            let limit = LLVMBuildLoad2(b, i64, gepByte(mut, off8), "limit")!
            let newCursor = LLVMBuildAdd(b, aligned, size, "newcursor")!
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntULE, newCursor, limit, "fits"), bumpBB, slowBB)
            // bump: publish the new cursor, form the object at the aligned address, zero it.
            LLVMPositionBuilderAtEnd(b, bumpBB)
            LLVMBuildStore(b, newCursor, cursorPtr)
            let obj = LLVMBuildIntToPtr(b, aligned, p1, "obj")!
            _ = buildCall(memset.0, memset.1, [toUnmanaged(obj), LLVMConstInt(i32, 0, 0), size])
            LLVMBuildBr(b, doneBB)
            // slow: out-of-line allocate (handles lazy bind, TLAB refill, and LOS). A statepoint.
            LLVMPositionBuilderAtEnd(b, slowBB)
            let slowP = buildCall(rtAlloc(), rtAllocTy(), [size])!
            LLVMBuildBr(b, doneBB)
            // done: the object from whichever path taken.
            LLVMPositionBuilderAtEnd(b, doneBB)
            let phi = LLVMBuildPhi(b, p1, "obj")!
            var vals: [LLVMValueRef?] = [obj, slowP]
            var blks: [LLVMBasicBlockRef?] = [bumpBB, slowBB]
            vals.withUnsafeMutableBufferPointer { vp in
                blks.withUnsafeMutableBufferPointer { bp in
                    LLVMAddIncoming(phi, vp.baseAddress, bp.baseAddress, 2)
                }
            }
            LLVMBuildRet(b, phi)
        }
        gcAllocFn = (fn, ty)
        return gcAllocFn!
    }

    // The `__nomu_write_barrier` seam: `void (ptr addrspace(1) obj, ptr addrspace(1) slot,
    // ptr addrspace(1) val)`, emitted at every store of a managed reference into a managed object field.
    // Object-remembering *post* barrier (GenImmix's `ObjectBarrier`): store `val` into `*slot`, then
    // remember `obj` the first time it is mutated after promotion so a nursery collection sees the new
    // cross-generation pointer. **Fast path inlined (M6 · 6.3.2):** the common case — barrier off
    // (NoGC/Immix), or `obj` already remembered / young — is a couple of loads + a predicted branch,
    // with no call. Only on an object's first mutation (unlog bit still 1) does it call the out-of-line
    // slow path `rt_gc_write_barrier` (which does the atomic log + remembered-set append). The unlog-bit
    // address is computed from the layout the binding publishes (`__nomu_logbit_base`/`_log_region`,
    // 1 bit/region) rather than hardcoded MMTk constants; `__nomu_barrier_active` gates the whole check
    // (0 under NoGC/Immix, where the log-bit metadata is unmapped). Stays `gc-leaf` (no statepoint);
    // `alwaysinline` collapses it into each store site, and `-O2` LICM hoists the loop-invariant loads.
    private func nomuWriteBarrier() -> (LLVMValueRef, LLVMTypeRef) {
        if let g = barrierFn { return g }
        let i8 = LLVMInt8TypeInContext(ctx)!
        let ty = fnType(voidTy, [p1, p1, p1])
        let fn = LLVMAddFunction(mod, "__nomu_write_barrier", ty)!
        LLVMSetLinkage(fn, LLVMInternalLinkage)
        markGCLeaf(fn)
        addAlwaysInline(fn)
        let rtBarrier = runtimeFn("rt_gc_write_barrier", ret: voidTy, params: [i8ptr, i8ptr, i8ptr], varArg: false)
        // External globals published by the GC binding (no initializer → declarations).
        let gActive = LLVMAddGlobal(mod, i8, "__nomu_barrier_active")!
        let gBase = LLVMAddGlobal(mod, i64, "__nomu_logbit_base")!
        let gRegion = LLVMAddGlobal(mod, i8, "__nomu_logbit_log_region")!
        withStubBody(fn) {
            let obj = LLVMGetParam(fn, 0)!, slot = LLVMGetParam(fn, 1)!, val = LLVMGetParam(fn, 2)!
            LLVMBuildStore(b, val, slot)   // *slot = val (the field write; barrier is post-store)
            let onBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.on")!
            let slowBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.slow")!
            let doneBB = LLVMAppendBasicBlockInContext(ctx, fn, "bar.done")!
            // if (!__nomu_barrier_active) return;
            let active = LLVMBuildLoad2(b, i8, gActive, "bar.active")
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, active, LLVMConstInt(i8, 0, 0), "bar.on?"), onBB, doneBB)
            // on: region = addr(obj) >> log_region;  byte = *(base + (region >> 3));  bit = (byte >> (region & 7)) & 1
            LLVMPositionBuilderAtEnd(b, onBB)
            let objInt = LLVMBuildPtrToInt(b, obj, i64, "obj.int")
            let logR = LLVMBuildZExt(b, LLVMBuildLoad2(b, i8, gRegion, "logR8"), i64, "logR")
            let region = LLVMBuildLShr(b, objInt, logR, "region")
            let baseV = LLVMBuildLoad2(b, i64, gBase, "logbit.base")
            let byteOff = LLVMBuildLShr(b, region, LLVMConstInt(i64, 3, 0), "byteoff")
            let metaPtr = LLVMBuildIntToPtr(b, LLVMBuildAdd(b, baseV, byteOff, "metaint"), i8ptr, "metaptr")
            let byte = LLVMBuildLoad2(b, i8, metaPtr, "logbyte")
            let bitpos = LLVMBuildTrunc(b, LLVMBuildAnd(b, region, LLVMConstInt(i64, 7, 0), "bp"), i8, "bitpos")
            let bit = LLVMBuildAnd(b, LLVMBuildLShr(b, byte, bitpos, "sh"), LLVMConstInt(i8, 1, 0), "bit")
            // unlogged (bit == 1) → slow path; else done.
            LLVMBuildCondBr(b, LLVMBuildICmp(b, LLVMIntNE, bit, LLVMConstInt(i8, 0, 0), "unlogged"), slowBB, doneBB)
            LLVMPositionBuilderAtEnd(b, slowBB)
            _ = buildCall(rtBarrier.0, rtBarrier.1, [toUnmanaged(obj), toUnmanaged(slot), toUnmanaged(val)])
            LLVMBuildBr(b, doneBB)
            LLVMPositionBuilderAtEnd(b, doneBB)
            LLVMBuildRetVoid(b)
        }
        barrierFn = (fn, ty)
        return barrierFn!
    }

    // Store `val` into a field at `slot` of the object `objBase`. A managed reference (`addrspace(1)`
    // value) stored into a *heap* object goes through the write-barrier seam; everything else is a
    // plain store — value-typed fields are not GC references, and a store into a stack-allocated object
    // (6.5.2/6.5.3, an addrspace(0) base) needs no barrier: the stack slot is a root scanned every GC,
    // not a remembered-set entry, and the barrier's ABI expects an addrspace(1) object regardless.
    private func storeField(_ objBase: LLVMValueRef!, _ slot: LLVMValueRef!, _ val: LLVMValueRef!) {
        if LLVMTypeOf(val) == p1, LLVMGetPointerAddressSpace(LLVMTypeOf(objBase)) == 1 {
            let bar = nomuWriteBarrier()
            _ = buildCall(bar.0, bar.1, [objBase, slot, val])
        } else {
            LLVMBuildStore(b, val, slot)
        }
    }

    // Whether a loop body reaches a GC safepoint on its own each iteration — i.e. unconditionally
    // performs a non-leaf call or a heap allocation (both become statepoints after the rewrite). If
    // so, the loop needs no back-edge poll (D3 elision). Conservative in the safe direction: only
    // the body's *top-level* statements count (a safepoint nested in an `if`/`while`/`switch` arm
    // may not run every iteration), so when unsure we place the poll. This is the IR-level
    // approximation of D3; M6 re-audits against precise codegen safepoints when the collector is live.
    private func loopBodyHasSafepoint(_ stmts: [NOIRStmt]) -> Bool {
        for s in stmts {
            switch s.kind {
            case .letBinding(_, _, let v): if exprHasSafepoint(v) { return true }
            case .assign(let t, let v), .compoundAssign(let t, let v):
                if exprHasSafepoint(t) || exprHasSafepoint(v) { return true }
            case .ret(let e): if let e = e, exprHasSafepoint(e) { return true }
            case .exprStmt(let e): if exprHasSafepoint(e) { return true }
            case .spawnLet: return true   // fiber_spawn + rt_alloc — a safepoint
            case .ifStmt, .whileStmt, .switchStmt, .breakStmt, .continueStmt: break
            }
        }
        return false
    }

    // Whether evaluating `e` unconditionally hits a safepoint: a non-leaf call, a method/witness
    // dispatch, or a heap allocation. Leaf builtins (`print`, `concat`, string literals) and pure
    // value construction (struct/enum) are not safepoints, but their sub-expressions still execute.
    private func exprHasSafepoint(_ e: NOIRExpr) -> Bool {
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef:
            return false
        case .fieldAccess(let base, _):
            return exprHasSafepoint(base)
        case .binary(_, let l, let r):
            return exprHasSafepoint(l) || exprHasSafepoint(r)
        case .construct(let name, let args):
            if classMap[name] != nil || actorMap[name] != nil { return true }   // rt_alloc
            return args.contains { exprHasSafepoint($0.value) }
        case .enumInit(_, _, let args):
            return args.contains { exprHasSafepoint($0.value) }
        case .box, .closure:
            return true   // rt_alloc (the any-box / the fused closure object)
        case .methodCall:
            return true   // dispatches to user / witness code (non-leaf)
        case .call(let callee, let args, _):
            if case .varRef(let n) = callee.kind {
                if Builtins.cLeaf.contains(n) { return args.contains { exprHasSafepoint($0.value) } }   // pure C leaf
                switch n {
                case "print", "concat": return args.contains { exprHasSafepoint($0.value) }   // leaf
                case "__array_count_int", "__arraySet": return args.contains { exprHasSafepoint($0.value) }   // load / store
                case "__arrayAppend": return true                                              // rt_array_grow may rt_alloc
                case "__int_double_double", "__double_int_int": return args.contains { exprHasSafepoint($0.value) }   // pure sitofp / round+fptosi
                case "sleep", "readLine": return true                                          // non-leaf runtime
                default: return true                                                            // user function
                }
            }
            return true   // indirect closure call
        case .arrayLit:
            return true   // rt_alloc (the handle + the buffer)
        case .index(let base, let idx):
            return exprHasSafepoint(base) || exprHasSafepoint(idx)   // the load/bounds-trap is not a safepoint
        }
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

    // `void* rt_alloc(size_t)` — the runtime allocator (bump-and-leak until the M6 GC). We declare
    // it as returning `ptr addrspace(1)`: the C ABI returns a plain 64-bit pointer, bit-identical to
    // an addrspace(1) pointer on arm64 (addrspace 1 carries no codegen difference here), and this
    // makes the allocation call itself a GC base the rewrite pass can track. An `addrspacecast
    // (0 → 1)` at the call site would *not* work — `RewriteStatepointsForGC::findBaseDefiningValue`
    // rejects a base introduced by a differing-addrspace cast (it strips pointer casts and asserts
    // the address spaces match). So the managed address space enters at the allocator, not via a cast.
    private func rtAlloc() -> LLVMValueRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).0 }
    private func rtAllocTy() -> LLVMTypeRef { runtimeFn("rt_alloc", ret: p1, params: [i64], varArg: false).1 }

    // Allocate a managed (GC-heap) object of `bytes` bytes through the `__nomu_gc_alloc` seam
    // (8.4.4, D5) — inert now (the seam tail-calls `rt_alloc`), the inline TLAB fast path in M6.
    // The result is addrspace(1): the tracked managed reference the mutator holds (D1).
    private func rtAllocManaged(_ bytes: LLVMValueRef) -> LLVMValueRef {
        let g = nomuGcAlloc()
        return buildCall(g.0, g.1, [bytes])!
    }

    // ---- M6 · 6.1.3 — GC pointer maps ----

    // Register a fixed-size object's pointer map (managed-field byte offsets) plus its total byte size,
    // and return its type-id (the shared index into `typeMaps`/`typeSizes`/`typeKinds`/`typeStrides`).
    private func registerMap(_ offsets: [Int32], sizeBytes: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(offsets)
        typeSizes.append(sizeBytes)
        typeKinds.append(0)      // fixed
        typeStrides.append(0)
        return id
    }

    // Register an array buffer type-id (M6 stdlib · Slice 4): `elementOffsets` are the managed-pointer
    // byte offsets *within one element*, `stride` its byte size. The object's total size and live
    // extent come from its `cap`/`len` at run time, so no fixed size is stored.
    private func registerArrayMap(_ elementOffsets: [Int32], stride: Int32) -> UInt64 {
        let id = UInt64(typeMaps.count)
        typeMaps.append(elementOffsets)
        typeSizes.append(0)
        typeKinds.append(1)      // array
        typeStrides.append(stride)
        return id
    }

    // Type-id for a class/actor heap type; assigns one (and computes its pointer map) on first use.
    private func typeId(forHeapType name: String) -> UInt64 {
        if let id = typeIds[name] { return id }
        let fieldTypes: [Type] = classMap[name].map { $0.fields.map(\.type) }
            ?? actorMap[name].map { $0.fields.map(\.type) } ?? []
        let isActor = actorMap[name] != nil
        var offsets: [Int32] = []
        var slot = 1   // header occupies slot 0; fields (and the actor's trailing mu) follow
        for ft in fieldTypes {
            collectManagedOffsets(ft, baseSlot: slot, into: &offsets)
            slot += slotCount(ft)
        }
        // slot is now 1 + Σ field slots (matching the class allocation site); an actor reserves one
        // more slot for its trailing mailbox pointer (the actor allocation site's `2 + Σ`). That
        // pointer is a managed GC reference (M6 · 6.4), so it is scanned.
        if isActor { offsets.append(Int32(slot * 8)) }
        let totalSlots = slot + (isActor ? 1 : 0)
        let id = registerMap(offsets, sizeBytes: Int32(totalSlots * 8))
        typeIds[name] = id
        return id
    }

    // Type-id for a fused closure object `{ header, fn, caps… }`: managed captures (scalar `p1`) are
    // scanned, `fn` (addr0) is skipped. Each closure site is its own shape (captures vary), so a
    // fresh map is registered per closure.
    private func closureTypeId(_ caps: [Capture]) -> UInt64 {
        var offsets: [Int32] = []
        var slot = 2   // header(0) + fn(1); captures follow
        for cap in caps {
            if cap.local.ty == p1 { offsets.append(Int32(slot * 8)) }
            slot += abiSlots(cap.local.ty)
        }
        return registerMap(offsets, sizeBytes: Int32(slot * 8))   // { header, fn, caps… }
    }

    // Shared type-id for every `any I` box `{ header, witness, payload }`: scan `payload` only
    // (byte 16, slot 2); the witness is a static table (Q7). Registered once.
    private func anyBoxTypeId() -> UInt64 {
        if let id = anyBoxMapId { return id }
        let id = registerMap([16], sizeBytes: 24)   // { header, witness, payload }
        anyBoxMapId = id
        return id
    }

    // Append the byte offsets of managed (`p1`) pointers within a field of type `t` laid out starting
    // at `baseSlot`. Recurses into inline value structs; String's buffer is runtime-owned (`addr0`)
    // today so it is skipped (Q6), and enum payloads carry no references in the language today (D6).
    private func collectManagedOffsets(_ t: Type, baseSlot: Int, into offsets: inout [Int32]) {
        switch t {
        case .named(_, .class_), .named(_, .actor_), .function, .existential, .composition, .array:
            offsets.append(Int32(baseSlot * 8))   // an Array<T> field is a managed handle pointer (M6)
        case .named(let n, .struct_):
            var s = baseSlot
            for sf in (structMap[n]?.fields ?? []) {
                collectManagedOffsets(sf.type, baseSlot: s, into: &offsets)
                s += slotCount(sf.type)
            }
        case .opaque:
            collectManagedOffsets(concreteUnderlying(t), baseSlot: baseSlot, into: &offsets)
        default:
            break   // int, bool, string (buffer addr0 until Q6 heap-boxes String), enum payload
        }
    }

    // Write the type-id into the object's header (slot 0 at the object base).
    private func writeTypeIdHeader(_ obj: LLVMValueRef, _ name: String) {
        LLVMBuildStore(b, LLVMConstInt(i64, typeId(forHeapType: name), 0), obj)
    }

    // Stamp a raw (non-named-type) type-id into an object header — for the mailbox/message objects,
    // which have no Nomu type name (M6 · 6.4).
    private func writeTypeIdHeaderRaw(_ obj: LLVMValueRef, _ id: UInt64) {
        LLVMBuildStore(b, LLVMConstInt(i64, id, 0), obj)
    }

    // MARK: - M6 · 6.4 actor mailbox codegen

    // The shared type-id for every mailbox object
    // `{ i64 header, mb_head, mb_tail, i64 scheduled, sched_next }`: mb_head (8), mb_tail (16), and
    // sched_next (32, the scheduled-mailbox-queue link) are managed pointers (scanned); scheduled (24)
    // is a plain int. 40 bytes.
    private func mailboxTypeIdValue() -> UInt64 {
        if let id = mailboxTypeId { return id }
        let id = registerMap([8, 16, 32], sizeBytes: 40)
        mailboxTypeId = id
        return id
    }

    // The generic message prefix `{ i64 header, p1 next, i8ptr thunk, p1 self }` — enough for the
    // shared drain loop to reach `thunk` (idx 2). Per-handler message types extend it with args, but
    // share these offsets. (Fire-and-forget: no sender, no reply — §9.)
    private func msgPrefixType() -> LLVMTypeRef {
        if let t = msgPrefixTypeRef { return t }
        let t = structTy([i64, p1, i8ptr, p1])
        msgPrefixTypeRef = t
        return t
    }

    // The per-handler message struct `{ header, next, thunk, self, args… }`. Field indices past the
    // 4-slot prefix are 4 + argPos. Handlers are void (fire-and-forget), so there is no reply field.
    private func messageType(_ actorName: String, _ h: NOIRHandler) -> LLVMTypeRef? {
        let key = "\(actorName):\(h.name)"
        if let t = messageTypes[key] { return t }
        var elems: [LLVMTypeRef] = [i64, p1, i8ptr, p1]   // header, next, thunk, self
        for p in h.params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            elems.append(t)
        }
        let mt = LLVMStructCreateNamed(ctx, "msg.\(actorName).\(h.name)")!
        setStructBody(mt, elems)
        messageTypes[key] = mt
        return mt
    }

    // Field index of a handler's i-th arg within the message struct (past the 4-slot prefix).
    private func msgArgIndex(_ i: Int) -> Int { 4 + i }

    // Total 8-byte slots a handler's message occupies: 4-slot prefix + args. Every leaf is 8-aligned
    // and an 8-multiple (the object-model invariant), so LLVM adds no padding and byte offsets equal
    // slot*8 — the same assumption the class/actor layout makes.
    private func messageSlots(_ h: NOIRHandler) -> Int {
        var slots = 4
        for p in h.params { slots += slotCount(p.type) }
        return slots
    }

    // Type-id + pointer map for a handler's message. Managed offsets: next (8) and self (24) always,
    // plus any managed pointers inside the args. thunk (16, a code ptr) is never scanned.
    private func messageTypeIdValue(_ actorName: String, _ h: NOIRHandler) -> UInt64 {
        let key = "\(actorName):\(h.name)"
        if let id = messageTypeIds[key] { return id }
        var offsets: [Int32] = [8, 24]   // next, self
        var slot = 4                     // args start past the 4-slot prefix
        for p in h.params {
            collectManagedOffsets(p.type, baseSlot: slot, into: &offsets)
            slot += slotCount(p.type)
        }
        let id = registerMap(offsets, sizeBytes: Int32(slot * 8))
        messageTypeIds[key] = id
        return id
    }

    // The per-handler drain thunk `void @nomu_onthunk_<A>_<h>(ptr addrspace(1) msg)`: unpack self +
    // args from the message and call the handler (void — no reply). Runs on a rented pool worker
    // inside the drain loop; `msg` is a tracked GC root here, so the handler's safepoints relocate it
    // and `self` correctly.
    private func actorThunk(_ actorName: String, _ h: NOIRHandler) -> LLVMValueRef {
        let key = "\(actorName):\(h.name)"
        if let f = actorThunks[key] { return f }
        declareActorHandler(actorName, h.name)
        let handler = callables["m:\(actorName):\(h.name)"]!
        let mt = messageType(actorName, h)!
        let (fn, _) = emitFunction("nomu_onthunk_\(actorName)_\(h.name)", ret: voidTy, params: [p1])
        actorThunks[key] = fn
        withStubBody(fn) {
            let msg = LLVMGetParam(fn, 0)!
            let selfV = LLVMBuildLoad2(b, p1, structGEP(mt, msg, 3), "self")!
            var argVals: [LLVMValueRef?] = [selfV]
            for (i, p) in h.params.enumerated() {
                guard let t = llvmType(p.type, p.span) else { continue }
                argVals.append(LLVMBuildLoad2(b, t, structGEP(mt, msg, msgArgIndex(i)), p.name))
            }
            _ = buildCall(handler.fn, handler.ty, argVals)   // void handler; any return is dropped
            LLVMBuildRetVoid(b)
        }
        return fn
    }

    // The one shared drain loop `void @nomu_actor_drain(ptr addrspace(1) mb)` the pool worker calls
    // (runtime.c `rt_pool_worker_main`): pop a message, run its thunk, repeat until the mailbox is
    // empty. `mb` and each `msg` are tracked GC roots across the thunk call — the whole reason this
    // loop is codegen (not C): a moving GC may relocate them at a handler safepoint.
    private func actorDrain() -> (LLVMValueRef, LLVMTypeRef) {
        if let f = actorDrainFn { return f }
        let pop = runtimeFn("rt_mailbox_pop", ret: p1, params: [p1], varArg: false)
        let thunkTy = fnType(voidTy, [p1])
        let pre = msgPrefixType()
        let (fn, fnTy) = emitFunction("nomu_actor_drain", ret: voidTy, params: [p1])
        actorDrainFn = (fn, fnTy)
        withStubBody(fn) {
            let mb = LLVMGetParam(fn, 0)!
            let loopBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.loop")!
            let bodyBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.body")!
            let exitBB = LLVMAppendBasicBlockInContext(ctx, fn, "drain.exit")!
            LLVMBuildBr(b, loopBB)
            LLVMPositionBuilderAtEnd(b, loopBB)
            let msg = buildCall(pop.0, pop.1, [mb])!
            let isNull = LLVMBuildICmp(b, LLVMIntEQ, msg, LLVMConstNull(p1), "empty?")
            LLVMBuildCondBr(b, isNull, exitBB, bodyBB)
            LLVMPositionBuilderAtEnd(b, bodyBB)
            let thunk = LLVMBuildLoad2(b, i8ptr, structGEP(pre, msg, 2), "thunk")!
            var callArgs: [LLVMValueRef?] = [msg]
            _ = callArgs.withUnsafeMutableBufferPointer {
                LLVMBuildCall2(b, thunkTy, thunk, $0.baseAddress, 1, "")
            }
            LLVMBuildBr(b, loopBB)
            LLVMPositionBuilderAtEnd(b, exitBB)
            LLVMBuildRetVoid(b)
        }
        return actorDrainFn!
    }

    // Lower an actor handler call `recv.h(args…)` to a fire-and-forget message-send (M6 · 6.4): build
    // the message and hand it to `rt_actor_send`, which enqueues it and returns. The call is void —
    // fire-and-forget is the only actor operation (§9); there is no reply/ask of any kind.
    private func lowerActorCall(_ actorName: String, _ handler: String,
                                _ recvValue: LLVMValueRef, _ args: [NOIRExpr], _ span: Span) -> LLVMValueRef? {
        guard let a = actorMap[actorName],
              let h = a.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", span); return nil
        }
        _ = actorDrain()                       // ensure the shared drain loop exists
        let thunk = actorThunk(actorName, h)   // per-handler thunk (+ handler + message type)
        guard let mt = messageType(actorName, h), let at = actorType(actorName) else { return nil }

        // Allocate + populate the message. header, thunk, self, args are set here; `next` is filled by
        // the runtime. The message stays reachable via the mailbox chain once enqueued (no sender root).
        let bytes = messageSlots(h) * 8
        let msg = rtAllocManaged(LLVMConstInt(i64, UInt64(bytes), 0))
        writeTypeIdHeaderRaw(msg, messageTypeIdValue(actorName, h))
        LLVMBuildStore(b, thunk, structGEP(mt, msg, 2))         // thunk (code ptr, not managed)
        storeField(msg, structGEP(mt, msg, 3), recvValue)       // self (managed)
        for (i, argE) in args.enumerated() {
            guard let v = lowerExpr(argE) else { return nil }
            storeField(msg, structGEP(mt, msg, msgArgIndex(i)), v)
        }
        let mailbox = LLVMBuildLoad2(b, p1, structGEP(at, recvValue, actorMailboxIndex(actorName)), "mailbox")!
        let send = runtimeFn("rt_actor_send", ret: voidTy, params: [p1, p1], varArg: false)
        _ = buildCall(send.0, send.1, [mailbox, msg])
        return LLVMConstNull(p1)   // fire-and-forget: no value
    }

    // Emit the flat pointer-map tables the runtime/binding reads (always emitted so runtime.c's
    // externs resolve, even with no heap types): `_data` = per-id `[count, off…]` concatenated,
    // `_index[id]` = that id's start in `_data`, `_count` = number of type-ids.
    private func emitTypeMaps() {
        var data: [Int32] = []
        var index: [Int32] = []
        for map in typeMaps {
            index.append(Int32(data.count))
            data.append(Int32(map.count))
            data.append(contentsOf: map)
        }
        emitI32Array("nomu_gc_typemap_data", data.isEmpty ? [0] : data)
        emitI32Array("nomu_gc_typemap_index", index.isEmpty ? [0] : index)
        // Parallel per-type-id byte sizes (6.2.4): `_sizes[id]` = total object size. Same fallback
        // shape as the maps so the runtime externs resolve with no heap types.
        emitI32Array("nomu_gc_typemap_sizes", typeSizes.isEmpty ? [0] : typeSizes)
        // Slice 4 — per-type-id kind (0 fixed / 1 array) + array element stride. Lets the collector
        // size/scan a variable-length array buffer from its `cap`/`len` and per-element map.
        emitI32Array("nomu_gc_typemap_kind", typeKinds.isEmpty ? [0] : typeKinds)
        emitI32Array("nomu_gc_typemap_stride", typeStrides.isEmpty ? [0] : typeStrides)
        let g = LLVMAddGlobal(mod, i64, "nomu_gc_typemap_count")!
        LLVMSetInitializer(g, LLVMConstInt(i64, UInt64(typeMaps.count), 0))
        LLVMSetGlobalConstant(g, 1)
    }

    private func emitI32Array(_ name: String, _ vals: [Int32]) {
        var consts: [LLVMValueRef?] = vals.map { LLVMConstInt(i32, UInt64(bitPattern: Int64($0)), 0) }
        let g = LLVMAddGlobal(mod, LLVMArrayType2(i32, UInt64(vals.count)), name)!
        let initv = consts.withUnsafeMutableBufferPointer {
            LLVMConstArray2(i32, $0.baseAddress, UInt64(vals.count))
        }
        LLVMSetInitializer(g, initv)
        LLVMSetGlobalConstant(g, 1)
    }

    // The C-ABI boundary cast (D1): a managed reference handed to a C function that takes a `void*`
    // is cast (1 → 0) for the call. This direction is supported by the rewrite pass (the result is
    // not a GC pointer, so it is never traced as a base). One explicit cast site per crossing keeps
    // the boundary auditable.
    private func toUnmanaged(_ v: LLVMValueRef) -> LLVMValueRef { LLVMBuildAddrSpaceCast(b, v, i8ptr, "to0")! }

    private func runtimeFn(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef], varArg: Bool)
        -> (LLVMValueRef, LLVMTypeRef)
    {
        if let cached = runtimeFns[name] { return cached }
        let f = emitFunction(name, ret: ret, params: params, varArg: varArg, gc: false)
        if NOIRToLLVM.gcLeafRuntimeFns.contains(name) { markGCLeaf(f.0) }
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
