// M8.1 · 8.1.5 / M8 · 8.2.1 / 8.2.2 — lower the typed IR (frontend `IRModule`) to an LLVM module
// via the C API. The LLVM sibling of `CodegenIR`; it mirrors that backend's per-node logic so the
// two agree (the differential harness, test/differential).
//
//   8.2.1 — primitives + control flow + functions: Int/Bool/String literals, arithmetic/
//           comparison, let/var, assignment + `+=`, if/else, return, user + builtin calls
//           (`print`, string `concat`).
//   8.2.2 — value types: `struct` construction, stored-field load/store, methods (self by value),
//           mutating methods (self by pointer), computed properties (get/set).
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
    private var funcMap: [String: IRFunc] = [:]
    private var closureSeq = 0

    private struct Callable {
        let fn: LLVMValueRef
        let ty: LLVMTypeRef
        let ir: IRFunc
        let selfType: String?     // struct type name when this is a method
        let selfByPointer: Bool   // mutating method → self is `T*`
    }
    private var callables: [String: Callable] = [:]
    private var pending: [String] = []

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
    }

    deinit { LLVMDisposeBuilder(b) }

    func lower(_ module: IRModule) {
        for decl in module.decls {
            switch decl {
            case .funcDecl(let f):   funcMap[f.name] = f
            case .structDecl(let s): structMap[s.name] = s
            case .enumDecl(let e):   enumMap[e.name] = e
            case .classDecl(let c):  classMap[c.name] = c
            default: break   // actors are a later slice
            }
        }
        guard funcMap["main"] != nil else { return }   // `loweredMain` stays false → caller errors
        declareFree("main")
        while error == nil, !pending.isEmpty {
            defineBody(pending.removeFirst())
        }
        if error == nil { loweredMain = callables["f:main"] != nil }
    }

    // MARK: - Types

    private func structType(_ name: String) -> LLVMTypeRef? {
        if let t = structTypes[name] { return t }
        guard let s = structMap[name] else { return nil }
        let st = LLVMStructCreateNamed(ctx, "struct.\(name)")!
        structTypes[name] = st   // cache before filling (value structs never self-nest, but be safe)
        var elems: [LLVMTypeRef?] = []
        for f in s.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        elems.withUnsafeMutableBufferPointer {
            LLVMStructSetBody(st, $0.baseAddress, UInt32(s.fields.count), 0)
        }
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
        var elems: [LLVMTypeRef?] = [i64]   // ObjectHeader
        for f in c.fields {
            guard let ft = llvmType(f.type, f.span) else { return nil }
            elems.append(ft)
        }
        elems.withUnsafeMutableBufferPointer {
            LLVMStructSetBody(ct, $0.baseAddress, UInt32(c.fields.count + 1), 0)
        }
        return ct
    }

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
        var elems: [LLVMTypeRef?] = [i64, LLVMArrayType2(i64, UInt64(slots))]
        elems.withUnsafeMutableBufferPointer { LLVMStructSetBody(et, $0.baseAddress, 2, 0) }
        return et
    }

    // The struct of a case's payload field types — GEP'd over the enum's payload region.
    private func caseStructType(_ enumName: String, _ c: IREnumCase) -> LLVMTypeRef? {
        var elems: [LLVMTypeRef?] = []
        for f in c.fields {
            guard let t = llvmType(f.type, f.span) else { return nil }
            elems.append(t)
        }
        return elems.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, UInt32(c.fields.count), 0)
        }
    }

    private func caseSlots(_ c: IREnumCase) -> Int { c.fields.reduce(0) { $0 + slotCount($1.type) } }

    // 8-byte slots a value occupies in an enum payload. Every supported leaf is 8-aligned, so a
    // struct/enum is just the sum/tag+max of its parts — no padding to account for.
    private func slotCount(_ t: Type) -> Int {
        switch t {
        case .int, .bool: return 1
        case .string:     return 2
        case .function:   return 2   // { fn, env }
        case .named(_, .class_): return 1   // a pointer
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
        return nil
    }

    private func declareCallable(key: String, llvmName: String, ir f: IRFunc,
                                 selfType: String?, selfByPointer: Bool) {
        guard let retTy = llvmType(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef?] = []
        if let selfType = selfType {
            guard let st = selfLLVMType(selfType) else { return }
            paramTys.append(selfByPointer ? LLVMPointerType(st, 0) : st)
        }
        for p in f.params {
            guard let t = llvmType(p.type, p.span) else { return }
            paramTys.append(t)
        }
        let pn = UInt32(paramTys.count)
        let fnTy = paramTys.withUnsafeMutableBufferPointer {
            LLVMFunctionType(retTy, $0.baseAddress, pn, 0)
        }!
        let fn = LLVMAddFunction(mod, llvmName, fnTy)!
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType, selfByPointer: selfByPointer)
        pending.append(key)
    }

    private func defineBody(_ key: String) {
        guard let c = callables[key] else { return }
        let f = c.ir
        currentFn = c.fn
        let block = LLVMAppendBasicBlockInContext(ctx, c.fn, "entry")
        LLVMPositionBuilderAtEnd(b, block)

        let savedLocals = locals; let savedSelf = currentSelf
        locals = [:]; currentSelf = nil

        var paramBase: UInt32 = 0
        if let selfType = c.selfType, let st = selfLLVMType(selfType) {
            let isClass = classMap[selfType] != nil
            let selfPtr = c.selfByPointer ? LLVMGetParam(c.fn, 0)!
                                          : { let s = LLVMBuildAlloca(b, st, "self")!
                                              LLVMBuildStore(b, LLVMGetParam(c.fn, 0), s); return s }()
            let fields = structMap[selfType]?.fields ?? classMap[selfType]?.fields ?? []
            currentSelf = SelfCtx(fields: fields, kind: isClass ? .classRef : .structVal,
                                  llvmTy: st, addr: selfPtr)
            if isClass {
                // `self` as a value is the object pointer; keep it in a ptr slot for `varRef self`.
                let slot = LLVMBuildAlloca(b, i8ptr, "self")!
                LLVMBuildStore(b, selfPtr, slot)
                locals["self"] = (slot, i8ptr)
            } else {
                locals["self"] = (selfPtr, st)   // loading the slot yields the struct/enum value
            }
            paramBase = 1
        }

        for (i, p) in f.params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(c.fn, UInt32(i) + paramBase), slot)
            locals[p.name] = (slot, t)
        }
        lowerBlock(f.body)
        if !blockTerminated() {
            if f.returnType == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        locals = savedLocals; currentSelf = savedSelf
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
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            guard let ty = llvmType(value.type, stmt.span), let v = lowerExpr(value) else { return }
            let slot = LLVMBuildAlloca(b, ty, name)!
            LLVMBuildStore(b, v, slot)
            locals[name] = (slot, ty)

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
            if let e = e {
                guard let v = lowerExpr(e) else { return }
                LLVMBuildRet(b, v)
            } else {
                LLVMBuildRetVoid(b)
            }

        case .ifStmt(let cond, let then, let els):
            lowerIf(cond: cond, then: then, els: els)

        case .switchStmt(let sw):
            lowerSwitch(sw)

        case .exprStmt(let e):
            _ = lowerExpr(e)

        default:
            fail("8.2.3: unsupported statement", stmt.span)
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
            return lowerMethodCall(receiver: receiver, method: method, args: args, span: e.span)
        case .call(let callee, let args, _):
            return lowerCall(callee: callee, args: args, span: e.span)
        case .closure(let params, let body):
            var ret = Type.void
            if case .function(_, let r) = e.type { ret = r }
            return lowerClosure(params: params, body: body, ret: ret, span: e.span)
        default:
            fail("8.2.4: unsupported expression", e.span)
            return nil
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
        fail("8.2.4: cannot construct '\(typeName)' (not a struct or class)", span)
        return nil
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

    private func lowerMethodCall(receiver: IRExpr, method: String, args: [IRExpr], span: Span) -> LLVMValueRef? {
        guard case .named(let typeName, let kind) = receiver.type,
              kind == .struct_ || kind == .enum_ || kind == .class_ else {
            fail("8.2.4: only concrete struct/enum/class method calls are supported", span)
            return nil
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
        let n = UInt32(argVals.count)
        return argVals.withUnsafeMutableBufferPointer {
            LLVMBuildCall2(b, c.ty, c.fn, $0.baseAddress, n, "")
        }
    }

    // A closure lowers to a hoisted impl function `ret nomu_cloN(ptr env, params…)` plus a site
    // that heap-allocates the env (captures copied by value) and yields `{ fn, env }`. Captures
    // are the body's free variables that name enclosing locals (mirrors CodegenIR).
    private func lowerClosure(params: [IRParam], body: [IRStmt], ret: Type, span: Span) -> LLVMValueRef? {
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUses(body, bound: &bound, used: &used)
        var seen = Set<String>()
        let caps = used.compactMap { name -> (name: String, local: (addr: LLVMValueRef, ty: LLVMTypeRef))? in
            guard seen.insert(name).inserted, let l = locals[name] else { return nil }
            return (name, l)
        }

        // Env struct type (captures, in order). Empty → an i8 placeholder so rt_alloc has a size.
        var envElems: [LLVMTypeRef?] = caps.isEmpty ? [LLVMInt8TypeInContext(ctx)] : caps.map { $0.local.ty }
        let envCount = UInt32(envElems.count)
        let envTy = envElems.withUnsafeMutableBufferPointer {
            LLVMStructTypeInContext(ctx, $0.baseAddress, envCount, 0)
        }!

        guard let retTy = llvmType(ret, span) else { return nil }
        var paramTys: [LLVMTypeRef?] = [i8ptr]   // env
        for p in params {
            guard let t = llvmType(p.type, p.span) else { return nil }
            paramTys.append(t)
        }
        let pn = UInt32(paramTys.count)
        let fnTy = paramTys.withUnsafeMutableBufferPointer {
            LLVMFunctionType(retTy, $0.baseAddress, pn, 0)
        }!
        let name = "nomu_clo\(closureSeq)"; closureSeq += 1
        let fn = LLVMAddFunction(mod, name, fnTy)!

        // Define the impl body against a fresh scope (captures loaded from env + params), then
        // restore the enclosing builder position and lowering state.
        let savedBlock = LLVMGetInsertBlock(b)
        let savedLocals = locals; let savedSelf = currentSelf; let savedFn = currentFn
        currentFn = fn; currentSelf = nil; locals = [:]
        let entry = LLVMAppendBasicBlockInContext(ctx, fn, "entry")
        LLVMPositionBuilderAtEnd(b, entry)
        let env = LLVMGetParam(fn, 0)!
        for (i, cap) in caps.enumerated() {
            let slot = LLVMBuildAlloca(b, cap.local.ty, cap.name)!
            let v = LLVMBuildLoad2(b, cap.local.ty, structGEP(envTy, env, i), cap.name)
            LLVMBuildStore(b, v, slot)
            locals[cap.name] = (slot, cap.local.ty)
        }
        for (i, p) in params.enumerated() {
            guard let t = llvmType(p.type, p.span) else { break }
            let slot = LLVMBuildAlloca(b, t, p.name)!
            LLVMBuildStore(b, LLVMGetParam(fn, UInt32(i) + 1), slot)
            locals[p.name] = (slot, t)
        }
        lowerBlock(body)
        if !blockTerminated() {
            if ret == .void { LLVMBuildRetVoid(b) } else { LLVMBuildUnreachable(b) }
        }
        locals = savedLocals; currentSelf = savedSelf; currentFn = savedFn
        LLVMPositionBuilderAtEnd(b, savedBlock)

        // Site: allocate + fill the env, then build the { fn, env } value.
        let bytes = caps.reduce(0) { $0 + abiSlots($1.local.ty) } * 8
        let envPtr = buildCall(rtAlloc(), rtAllocTy(), [LLVMConstInt(i64, UInt64(max(bytes, 8)), 0)])!
        for (i, cap) in caps.enumerated() {
            let v = LLVMBuildLoad2(b, cap.local.ty, cap.local.addr, cap.name)
            LLVMBuildStore(b, v, structGEP(envTy, envPtr, i))
        }
        var clo = LLVMGetUndef(closureTy)
        clo = LLVMBuildInsertValue(b, clo, fn, 0, "")
        clo = LLVMBuildInsertValue(b, clo, envPtr, 1, "")
        return clo
    }

    private func lowerCall(callee: IRExpr, args: [IRArg], span: Span) -> LLVMValueRef? {
        if case .varRef(let name) = callee.kind {
            switch name {
            case "print":  return lowerPrint(args, span)
            case "concat": return lowerConcat(args, span)
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
        var paramTys: [LLVMTypeRef?] = [i8ptr]
        for t in ptys {
            guard let lt = llvmType(t, span) else { return nil }
            paramTys.append(lt)
        }
        let pn = UInt32(paramTys.count)
        let fnTy = paramTys.withUnsafeMutableBufferPointer {
            LLVMFunctionType(retTy, $0.baseAddress, pn, 0)
        }!
        return buildArgsAndCall(fnTy, fnPtr!, env: envPtr, args: args)
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
        var ps: [LLVMTypeRef?] = params.map { $0 }
        let ty = ps.withUnsafeMutableBufferPointer {
            LLVMFunctionType(ret, $0.baseAddress, UInt32(params.count), varArg ? 1 : 0)
        }!
        let fn = LLVMAddFunction(mod, name, ty)!
        runtimeFns[name] = (fn, ty)
        return (fn, ty)
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
