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
    // The shared LLVM/GC emission machinery (composition, m7-spec.md §7.2.3). The tree-walk below
    // reaches the context/builder/cached-types through the forwarders that follow, so its bodies are
    // unchanged; the forwarders retire with this path once the SSAIR egress replaces it.
    let e: LLVMGen

    var ctx: LLVMContextRef { e.ctx }
    var mod: LLVMModuleRef { e.mod }
    var b: LLVMBuilderRef { e.b }
    var i8ptr: LLVMTypeRef { e.i8ptr }
    var p1: LLVMTypeRef { e.p1 }
    var i1: LLVMTypeRef { e.i1 }
    var i32: LLVMTypeRef { e.i32 }
    var i64: LLVMTypeRef { e.i64 }
    var f64: LLVMTypeRef { e.f64 }
    var voidTy: LLVMTypeRef { e.voidTy }
    var strTy: LLVMTypeRef { e.strTy }
    var closureHdrTy: LLVMTypeRef { e.closureHdrTy }
    var anyBoxTy: LLVMTypeRef { e.anyBoxTy }
    var spawnHandleTy: LLVMTypeRef { e.spawnHandleTy }
    var zeroSpan: Span { e.zeroSpan }

    // Type-layout primitives moved to `LLVMGen`; forwarded so the tree-walk is unchanged.
    func structType(_ name: String) -> LLVMTypeRef? { e.structType(name) }
    func classType(_ name: String) -> LLVMTypeRef? { e.classType(name) }
    func enumType(_ name: String) -> LLVMTypeRef? { e.enumType(name) }
    func actorType(_ name: String) -> LLVMTypeRef? { e.actorType(name) }
    func llvmType(_ t: Type, _ span: Span) -> LLVMTypeRef? { e.llvmType(t, span) }
    func aggInfo(_ typeName: String) -> (ty: LLVMTypeRef, kind: AggKind, fields: [NOIRField])? { e.aggInfo(typeName) }
    func fieldLLVMIndex(_ kind: AggKind, _ fieldPos: Int) -> Int { e.fieldLLVMIndex(kind, fieldPos) }
    func actorMailboxIndex(_ name: String) -> Int { e.actorMailboxIndex(name) }
    func caseStructType(_ enumName: String, _ c: NOIREnumCase) -> LLVMTypeRef? { e.caseStructType(enumName, c) }
    func caseSlots(_ c: NOIREnumCase) -> Int { e.caseSlots(c) }
    func slotCount(_ t: Type) -> Int { e.slotCount(t) }
    func isScalarLeaf(_ ty: LLVMTypeRef) -> Bool { e.isScalarLeaf(ty) }
    func selfLLVMType(_ typeName: String) -> LLVMTypeRef? { e.selfLLVMType(typeName) }
    func typeMethods(_ typeName: String) -> [NOIRFunc] { e.typeMethods(typeName) }

    // (Runtime-fn caches + the mutator seams moved to LLVMGen — LLVMGenRuntime.swift.)

    // Type + function registries. `structMap`/`structTypes`: Nomu structs and their (cached) LLVM
    // struct types. `funcMap`: top-level functions. `callables`: LLVM functions declared on demand
    // (free functions keyed `f:<name>`, methods `m:<type>:<method>`), with `pending` bodies.
    // All of these — the type registries, `funcMap`, and the callable caches — moved to `LLVMGen`
    // (shared by both egresses). The tree-walk reads them through the get-only forwarders below and
    // the layout/declaration methods through the method forwarders further down. The one write to
    // `funcMap` (in `lower`) goes straight to `e.funcMap`.
    var structMap: [String: NOIRStruct] { e.structMap }
    var enumMap: [String: NOIREnum] { e.enumMap }
    var classMap: [String: NOIRClass] { e.classMap }
    var actorMap: [String: NOIRActor] { e.actorMap }
    var funcMap: [String: NOIRFunc] { e.funcMap }
    var closureSeq = 0
    // 6.5.2 — non-escaping allocation sites from escape analysis; empty when the pass is disabled.
    let escapes: EscapeResult
    // §6.6 — inline the allocation bump fast path; `NOMU_NO_INLINE_ALLOC` reverts to the out-of-line
    // `rt_alloc` tail-call (the pre-6.6 body) for A/B measurement.
    var inlineAlloc: Bool { e.inlineAlloc }   // → LLVMGen
    // M6 · 6.1.3 — GC pointer maps. Each heap type gets a type-id (written into the object header,
    // 6.1.2) that keys `typeMaps[id]` = the byte offsets of its managed (`p1`) fields, which
    // `scan_object` walks. Class/actor here; closures/any-boxes/String follow (they need a header
    // slot added first). Emitted as flat tables at module finalization.
    // (GC pointer-map caches moved to LLVMGen — LLVMGenGCMaps.swift.)
    // M6 · 6.2.4 — parallel to `typeMaps`: `typeSizes[id]` = the object's total byte size (header
    // included). Every moving-space object is fixed-size per type-id (class/actor/closure/any-box are
    // monomorphized), so the collector's `get_current_size`/`get_size_when_copied` read this table by
    // type-id instead of parsing the object. No header change (§6.2.4).
    // M6 stdlib · Slice 4 — parallel to `typeMaps`: `typeKinds[id]` = 0 for a fixed-size object, 1 for
    // an array buffer (variable size). For an array buffer, `typeStrides[id]` = one element's byte
    // stride and `typeMaps[id]` = the managed-pointer offsets *within one element* (applied per element
    // by `scan_object`); `typeSizes[id]` is unused (size comes from the object's `cap`).
    // M6 · 6.4 actor mailbox machinery moved to `LLVMGen` (the `msgPrefixTypeRef`/`messageTypes`/
    // `messageTypeIds`/`actorThunks`/`actorDrainFn` caches + their primitives, LLVMGenActor.swift) —
    // the message ABI + drain machinery, shared by both egresses. (`mailboxTypeId` is on LLVMGen too.)
    // `lowerActorCall` stays on the walker (it lowers arg exprs) and reaches them via forwarders.

    // 8.2.5 witness machinery moved to `LLVMGen` (the `interfaceDefs`/`witnessSlotsCache`/
    // `witnessTypes`/`witnessGlobals`/`compositeTypes`/`compositeGlobals` caches + their primitives,
    // LLVMGenWitness.swift) — the conformance ABI, shared by both egresses. The one write to
    // `interfaceDefs` (in `lower`) goes straight to `e.interfaceDefs`.

    // `Callable` (now top-level) + the `callables`/`pending` caches moved to `LLVMGen`. The tree-walk
    // reads declared callables through this get-only forwarder; the sole `pending` drain (in `lower`)
    // mutates `e.pending` directly.
    var callables: [String: Callable] { e.callables }

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
    // `currentFn` (the LLVM function being emitted into) moved to LLVMGen; forwarded (scalar — no COW).
    var currentFn: LLVMValueRef? { get { e.currentFn } set { e.currentFn = newValue } }

    // While lowering a method body: the receiver, so a bare field reference (`x` inside a method)
    // resolves through `self`. (`AggKind` is now a top-level type, in LLVMGen.swift.)

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
    // Debug-info state moved to LLVMGen (LLVMGenDebug.swift); `di`/`currentScope` forwarded (both
    // scalar — no COW). The `currentScope` setter is used by thunk enter/leave.
    var di: LLVMDIBuilderRef? { get { e.di } set { e.di = newValue } }
    var currentScope: LLVMMetadataRef? { get { e.currentScope } set { e.currentScope = newValue } }

    // Settable across the split extension files (LoweringGC etc.); the class is module-internal.
    var loweredMain = false
    var error: String? { e.error }   // → LLVMGen (written only by `fail`)

    init(ctx: LLVMContextRef, mod: LLVMModuleRef, escapes: EscapeResult = EscapeResult(nonEscaping: [])) {
        self.e = LLVMGen(ctx: ctx, mod: mod)
        self.escapes = escapes
    }

    func lower(_ module: NOIRModule) {
        for i in module.interfaces { e.interfaceDefs[i.name] = i }
        e.opaqueUnderlyings = module.opaqueUnderlyings
        for decl in module.decls {
            switch decl {
            case .funcDecl(let f):   self.e.funcMap[f.name] = f
            case .structDecl(let s): self.e.structMap[s.name] = s
            case .enumDecl(let en):  self.e.enumMap[en.name] = en
            case .classDecl(let c):  self.e.classMap[c.name] = c
            case .actorDecl(let a):  self.e.actorMap[a.name] = a
            }
        }
        guard let mainFn = funcMap["main"] else { return }   // `loweredMain` stays false → caller errors
        setupDebugInfo(sourceFile: mainFn.span.file)
        declareFree("main")
        while error == nil, !e.pending.isEmpty {
            defineBody(e.pending.removeFirst())
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
    // Debug-info methods moved to LLVMGen (LLVMGenDebug.swift); forwarded so the tree-walk +
    // `emitFunction` are unchanged.
    func setupDebugInfo(sourceFile path: String) { e.setupDebugInfo(sourceFile: path) }
    func makeSubprogram(_ displayName: String, linkage: String, line: Int) -> LLVMMetadataRef? { e.makeSubprogram(displayName, linkage: linkage, line: line) }
    func setDebugLoc(_ span: Span) { e.setDebugLoc(span) }
    func enterDebugScope(_ fn: LLVMValueRef, line: Int) { e.enterDebugScope(fn, line: line) }

    func declareLocal(_ name: String, type: Type, addr: LLVMValueRef, line: Int, argNo: Int? = nil) {
        e.declareLocal(name, type: type, addr: addr, line: line, argNo: argNo)
    }

}
