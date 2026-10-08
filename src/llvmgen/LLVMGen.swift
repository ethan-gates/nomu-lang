import noir
import support
import Foundation
import LLVM_C

// A struct is a value; a class is a heap reference (its value is a pointer to `{ header, … }`), so
// its field index i sits at aggregate index i+1 (past the object header).
enum AggKind { case structVal, classRef }

// A captured local: its name and the (addr, ty) slot it lives in in the enclosing scope. Shared by
// closures and `spawn let`, which both copy free variables by value into a heap env.
typealias Capture = (name: String, local: (addr: LLVMValueRef, ty: LLVMTypeRef))

// A declared LLVM function: its value ref, function type, the source IR its body lowers from, and
// (for methods) the receiver type and whether `self` is passed by pointer. Built by the callable-
// declaration primitives; the body is filled later by whichever egress walks `ir`.
struct Callable {
    let fn: LLVMValueRef
    let ty: LLVMTypeRef
    let ir: NOIRFunc
    let selfType: String?     // struct type name when this is a method
    let selfByPointer: Bool   // mutating method → self is `T*`
}

// The shared LLVM/GC emission machinery — the code both egresses lower through: the LLVM context /
// module / builder, the cached primitive types, and the type-layout, GC-map, witness, and runtime-call
// primitives. Held by composition: the `SSAIRToLLVM` egress owns one `LLVMGen` and calls its
// primitives, so the whole GC ABI is emitted from a single place. `final`, so the primitives dispatch
// statically (ssair.md).
//
// This shared emitter was factored out (M7 §7.1.2 / §7.2.3) so the GC ABI lived in one place while the
// NOIR tree-walk and the SSAIR CFG-walk co-existed behind the corpus differential. The NOIR walk
// retired at M7.7; `LLVMGen` now serves `SSAIRToLLVM` alone.
final class LLVMGen {
    let ctx: LLVMContextRef
    let mod: LLVMModuleRef
    let b: LLVMBuilderRef

    let i8ptr: LLVMTypeRef      // opaque `ptr` (addrspace 0) — code / static / C-owned memory
    let p1: LLVMTypeRef         // opaque `ptr addrspace(1)` — a managed (GC-heap) reference (8.4.1 D1)
    let i1: LLVMTypeRef         // 8.5.2 — `Bool` (0/1); LLVM's natural boolean
    let i8: LLVMTypeRef         // `UInt8` — an 8-bit unsigned byte
    let i32: LLVMTypeRef
    let i64: LLVMTypeRef
    let f64: LLVMTypeRef        // `Double` — LLVM's native double
    let voidTy: LLVMTypeRef
    let strTy: LLVMTypeRef      // { i64 word0, i64 word1 } — the bit-stealing String (task 121/176); matches runtime.h `String`
    let closureHdrTy: LLVMTypeRef  // { i64 header, i8ptr fn } — the fixed prefix of a heap closure { fn, caps… }
    let anyBoxTy: LLVMTypeRef      // { i64 header, i8ptr witness (addr0), p1 payload } — the `any I` heap box (D1)
    let spawnHandleTy: LLVMTypeRef // { i8ptr fiber (addr0, runtime-owned) } — SpawnHandle (8.2.6)

    let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)   // synthetic: resolves to line 0

    // The single error sink — first error wins, reported by the driver (design: noir.md).
    var error: String?

    // `some I` owner → its hidden concrete underlying (M5 A3); resolves `.opaque` to a real type.
    var opaqueUnderlyings: [String: Type] = [:]
    // Mono'd type-instantiation name → its concrete type args (task 100.4.3.5.3.3); read by the
    // erased-method call lowering to thread the receiver's type-argument VWTs.
    var monoTypeArgs: [String: [Type]] = [:]

    // Top-level function registry, and the callables declared on demand. `funcMap` holds every
    // top-level `fun` by name (input to `declareFree`). `callables` keys declared LLVM functions —
    // free functions `f:<name>`, methods `m:<type>:<method>` — with `pending` naming the bodies not
    // yet lowered. The declaration primitives (LLVMGenCallables.swift) fill these; each egress drains
    // `pending`, lowering the body its own way.
    var funcMap: [String: NOIRFunc] = [:]
    var callables: [String: Callable] = [:]
    var pending: [String] = []

    // Separate compilation (task 100.4.2). `externalFuncNames` are functions imported from a
    // dependency: a call to one emits an external declaration, resolved at link. `weakOriginFiles` are
    // source files whose functions get weak (COMDAT-folded) linkage — the interim fix for the prelude
    // being compiled into every module's object (proper fix: prelude-as-packages, task 100.3.7).
    var externalFuncNames: Set<String> = []
    // Imported generic functions (task 100.4.3.4): a call emits the erased witness-passing ABI to the
    // producer's compiled-once symbol, keyed by the callee's per-origin identity.
    var externalGenericSigs: [String: ExternalGenericSig] = [:]
    var weakOriginFiles: Set<String> = []
    // Module-path mangling (task 100.4). `homeQualifier` prefixes every symbol this module *defines*
    // (empty for the entry/root module → bare names). An imported function's callee name is its
    // per-origin identity (`origin@name`, task 100.2.3.2); the external-call site decodes it to the
    // producer's mangled symbol. Prelude/runtime functions (source file in `weakOriginFiles`) stay bare —
    // the C runtime pins those names.
    var homeQualifier: String = ""
    // The GC type-map globals are single extern tables the C runtime reads by name, so only one object
    // may define them (the entry). Dependency objects skip the definition and reference it externally.
    // (Interim: cross-module type-ids/type-map unification is a later separate-compilation task.)
    var emitsTypeMaps = true

    // The LLVM function currently being emitted into (its entry block is where allocas land). Set per
    // body/thunk by whichever egress is emitting; saved/restored across nested thunk emission.
    var currentFn: LLVMValueRef?
    // Shaped roots live across the safepoint instruction currently being lowered (task 176): a `"deopt"`
    // operand list `buildCall` attaches so a per-site statepoint call records them. Set/cleared by the
    // SSAIR→LLVM block lowering around each safepoint instruction; nil elsewhere.
    var pendingDeopt: [LLVMValueRef?]?

    // 8.2.5 witness machinery. `interfaceDefs` gives a requirement surface to lay out a witness struct
    // (its slot order lives in `witnessSlotsCache`). Witness struct types are cached in `witnessTypes`;
    // per-conformance instances (LLVM globals) in `witnessGlobals`, keyed `type::iface`. Composites
    // (`any A & B`) get their struct type + instance in `compositeTypes`/`compositeGlobals`, keyed
    // `type::A&B`. Built lazily on first box/upcast/dispatch — the ABI both egresses must share.
    var interfaceDefs: [String: NOIRInterface] = [:]
    var witnessSlotsCache: [String: [String]] = [:]
    var witnessTypes: [String: LLVMTypeRef] = [:]
    var witnessGlobals: [String: LLVMValueRef] = [:]
    // Erased-path witness instances (task 100.4.3.3.3): value-buffer-self thunks for a conformer threaded
    // into a cross-module bounded generic call, keyed `type::iface::erased`. Distinct from the `any I`
    // table above so the existential dispatch stays untouched.
    var witnessErasedGlobals: [String: LLVMValueRef] = [:]
    var compositeTypes: [String: LLVMTypeRef] = [:]
    var compositeGlobals: [String: LLVMValueRef] = [:]

    // Value-witness tables (task 100.4.3.2; ABI in internals/backend.md §4). `valueWitnessTy` is the
    // shared VWT struct type; `valueWitnessGlobals` caches the per-concrete-type instance, keyed by the
    // type's description. Built lazily on demand (an erased generic body / call site references one).
    var valueWitnessTy: LLVMTypeRef?
    var valueWitnessGlobals: [String: LLVMValueRef] = [:]

    // M6 · 6.4 actor mailbox. `msgPrefixTypeRef` is the shared message prefix; `messageTypes`/
    // `messageTypeIds` are the per-handler message struct + its type-id; `actorThunks` the per-handler
    // drain thunk; `actorDrainFn` the one shared `nomu_actor_drain` loop. Keyed "actor:handler".
    var msgPrefixTypeRef: LLVMTypeRef?
    var messageTypes: [String: LLVMTypeRef] = [:]
    var messageTypeIds: [String: UInt64] = [:]
    var actorThunks: [String: LLVMValueRef] = [:]
    var actorDrainFn: (LLVMValueRef, LLVMTypeRef)?

    // Type registries + their cached LLVM struct types (built lazily by the layout primitives).
    var structMap: [String: NOIRStruct] = [:]
    var structTypes: [String: LLVMTypeRef] = [:]
    var enumMap: [String: NOIREnum] = [:]
    var enumTypes: [String: LLVMTypeRef] = [:]
    var classMap: [String: NOIRClass] = [:]
    var classTypes: [String: LLVMTypeRef] = [:]
    var actorMap: [String: NOIRActor] = [:]
    var actorTypes: [String: LLVMTypeRef] = [:]

    // M6 GC pointer maps — each heap type gets a type-id keying `typeMaps[id]` (managed-field byte
    // offsets, or a serialized discriminant-keyed map for kind 2), `typeSizes[id]` (fixed size),
    // `typeKinds[id]` (0 fixed / 1 array / 2 shaped, task 176), `typeStrides[id]` (array element stride).
    // Emitted as flat tables at module finalization.
    var typeIds: [String: UInt64] = [:]
    var typeMaps: [[Int32]] = []
    var typeSizes: [Int32] = []
    var typeKinds: [Int32] = []
    var typeStrides: [Int32] = []
    // Parallel to `typeMaps` (task 180): each buffer type's user-header byte size (0 for a fixed object or
    // a plain array buffer) and the managed-pointer byte offsets within that header. The header offsets are
    // emitted as the prefix of the pointer-map blob, before the element/direct offsets, so the element map
    // reads at `blob + nHeaderPtr`. Empty/0 for every non-buffer and header-less type.
    var typeHeaderSizes: [Int32] = []
    var typeHeaderMaps: [[Int32]] = []
    // Parallel to `typeMaps`: each type's *shaped-field* entries (task 176, shaped-roots.md Stage 1 site 2)
    // — a `(byte offset, shape type-id)` per field that is itself a shaped value (a `String`), so the
    // collector recurses into the field's kind-2 sub-shape rather than treating it as a direct pointer. The
    // `UInt64` is the shape's registration id; its descriptor symbol (resolved at emit time) is written into
    // the pointer map as a link-time descriptor offset after the flat direct offsets. Empty for most types.
    var typeShaped: [[(offset: Int32, shapeId: UInt64)]] = []
    // Parallel to `typeMaps`: each registered type's stable descriptor symbol (`nomu_gc_desc_*`) and
    // whether it folds across modules (weak `linkonce_odr`) or is a program-local shape (`internal`).
    // Drives the link-time offset-as-id descriptor section (task 100.4.7); the flat tables above are
    // the interim representation, retired once the runtime reads descriptors.
    var typeSymbols: [(name: String, foldable: Bool)] = []
    var arrayBufMapIds: [String: UInt64] = [:]   // element-type description → array-buffer type-id
    var managedBufferMapIds: [String: UInt64] = [:]  // "Header$Element" → managed-buffer type-id (task 180)
    var valueDescIds: [String: UInt64] = [:]     // type description → value-layout descriptor id (VWT type_id, 100.4.7.4)
    var anyBoxMapId: UInt64?                      // one shared map for every `any I` box (payload at byte 16)
    var stringShapeMapId: UInt64?                 // one shared kind-2 shaped descriptor for every String (task 121/176)
    var stringStorageMapId: UInt64?               // one shared kind-1 descriptor for the heap String buffer (task 176.2)
    var arrayHandleMapId: UInt64?                 // one shared type-id for every Array handle (bufptr at byte 16)
    var mailboxTypeId: UInt64?                    // one shared type-id for every mailbox object

    // Debug info (8.3, DWARF Tier 0). `di` nil ⇒ debug work is skipped. `currentScope` is the active
    // subprogram, set per function by whichever walker is emitting a body.
    var di: LLVMDIBuilderRef?
    var diFile: LLVMMetadataRef?
    var diCU: LLVMMetadataRef?
    var currentScope: LLVMMetadataRef?
    var diTypeCache: [String: LLVMMetadataRef] = [:]
    let dwSigned: LLVMDWARFTypeEncoding = 5       // DW_ATE_signed
    let dwFloat: LLVMDWARFTypeEncoding = 4        // DW_ATE_float
    let dwBoolean: LLVMDWARFTypeEncoding = 2      // DW_ATE_boolean
    let dwUnsignedChar: LLVMDWARFTypeEncoding = 8 // DW_ATE_unsigned_char
    let dwUnsigned: LLVMDWARFTypeEncoding = 7     // DW_ATE_unsigned

    // Runtime-fn declarations + the inert mutator seams (`__nomu_poll`/`__nomu_gc_alloc`/
    // `__nomu_write_barrier`), cached once each.
    var runtimeFns: [String: (fn: LLVMValueRef, ty: LLVMTypeRef)] = [:]
    var pollFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var gcAllocFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var gcAllocRootedFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?   // task 176 — `noinline` shaped-root alloc variant
    var selfhostAllocFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?   // task 150 — self-hosted alloc slow path
    var barrierFn: (fn: LLVMValueRef, ty: LLVMTypeRef)?
    var stopWorldGlobalCache: LLVMValueRef?
    var intFmt: LLVMValueRef?
    var uintFmt: LLVMValueRef?
    var strFmt: LLVMValueRef?
    // §6.6 — inline the allocation bump fast path; `NOMU_NO_INLINE_ALLOC` reverts to the out-of-line
    // `rt_alloc` tail-call for A/B measurement.
    let inlineAlloc = ProcessInfo.processInfo.environment["NOMU_NO_INLINE_ALLOC"] == nil

    init(ctx: LLVMContextRef, mod: LLVMModuleRef) {
        self.ctx = ctx
        self.mod = mod
        b = LLVMCreateBuilderInContext(ctx)
        i8ptr = LLVMPointerType(LLVMInt8TypeInContext(ctx), 0)
        p1 = LLVMPointerType(LLVMInt8TypeInContext(ctx), 1)
        i1 = LLVMInt1TypeInContext(ctx)
        i8 = LLVMInt8TypeInContext(ctx)
        i32 = LLVMInt32TypeInContext(ctx)
        i64 = LLVMInt64TypeInContext(ctx)
        f64 = LLVMDoubleTypeInContext(ctx)
        voidTy = LLVMVoidTypeInContext(ctx)
        // String is a 16-byte bit-stealing value `{ i64 word0, i64 word1 }` (task 121 Representation):
        // `word0` is inline bytes / a buffer pointer by case, `word1` carries the tag (top nibble) + count.
        var fields: [LLVMTypeRef?] = [i64, i64]
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

    // MARK: - Foundational emission primitives (shared by both egresses)

    func fail(_ msg: String, _ span: Span) {
        if error == nil { error = "\(span): \(msg)" }
    }

    // `some I` is unboxed — resolve it to the concrete underlying (else pass the type through).
    func concreteUnderlying(_ t: Type) -> Type {
        if case .opaque(_, let owner) = t, let u = opaqueUnderlyings[owner] { return u }
        return t
    }

    func fnType(_ ret: LLVMTypeRef, _ params: [LLVMTypeRef], varArg: Bool = false) -> LLVMTypeRef {
        var ps: [LLVMTypeRef?] = params
        return ps.withUnsafeMutableBufferPointer {
            LLVMFunctionType(ret, $0.baseAddress, UInt32(params.count), varArg ? 1 : 0)
        }!
    }

    func structTy(_ elems: [LLVMTypeRef], packed: Bool = false) -> LLVMTypeRef {
        var es: [LLVMTypeRef?] = elems
        return es.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, UInt32(elems.count), packed ? 1 : 0)
        }!
    }

    func setStructBody(_ st: LLVMTypeRef, _ elems: [LLVMTypeRef], packed: Bool = false) {
        var es: [LLVMTypeRef?] = elems
        es.withUnsafeMutableBufferPointer {
            LLVMStructSetBody(st, $0.baseAddress, UInt32(elems.count), packed ? 1 : 0)
        }
    }

    func constStruct(_ ty: LLVMTypeRef, _ vals: [LLVMValueRef?]) -> LLVMValueRef {
        var vs = vals
        return vs.withUnsafeMutableBufferPointer {
            LLVMConstNamedStruct(ty, $0.baseAddress, UInt32(vals.count))
        }!
    }
}
