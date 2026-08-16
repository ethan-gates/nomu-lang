import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Free-variable collection (respects shadowing via `bound`)

    func collectUses(_ stmts: [NOIRStmt], bound: inout Set<String>, used: inout [String]) {
        for s in stmts { collectUsesStmt(s, bound: &bound, used: &used) }
    }

    func collectUsesStmt(_ stmt: NOIRStmt, bound: inout Set<String>, used: inout [String]) {
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

    func collectUsesExpr(_ e: NOIRExpr, bound: Set<String>, used: inout [String]) {
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
    func lowerPrint(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    func lowerIntToDouble(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let v = args.first.flatMap({ lowerExpr($0.value) }) else {
            fail("__int_double_double expects one argument", span); return nil
        }
        return LLVMBuildSIToFP(b, v, f64, "i2d")
    }

    // `d.int` — narrow Double (f64) to Int (i64), rounding to nearest with ties away from zero
    // (`llvm.round`), then a signed truncation to integer.
    func lowerDoubleToInt(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    func lowerCLeafBuiltin(_ name: String, _ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    func cType(_ t: Type) -> LLVMTypeRef {
        switch t {
        case .string: return strTy
        case .double: return f64
        case .bool:   return i1
        default:      return i64   // Int (and Void params never occur)
        }
    }

    func lowerConcat(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard args.count == 2 else {
            fail("8.2.1: concat expects two String arguments", span)
            return nil
        }
        guard let a = lowerExpr(args[0].value), let c = lowerExpr(args[1].value) else { return nil }
        let (fn, ty) = runtimeFn("rt_str_concat", ret: strTy, params: [strTy, strTy], varArg: false)
        return buildCall(fn, ty, [a, c])
    }

    func lowerStringLit(_ s: String) -> LLVMValueRef {
        let data = LLVMBuildGlobalStringPtr(b, s, "str")!
        let len = LLVMConstInt(i64, UInt64(s.utf8.count), 0)
        let (fn, ty) = runtimeFn("rt_str_lit", ret: strTy, params: [i8ptr, i64], varArg: false)
        return buildCall(fn, ty, [data, len])!
    }

    // MARK: - Helpers

    func structGEP(_ structTy: LLVMTypeRef, _ addr: LLVMValueRef, _ idx: Int) -> LLVMValueRef {
        var idxs: [LLVMValueRef?] = [LLVMConstInt(i32, 0, 0), LLVMConstInt(i32, UInt64(idx), 0)]
        return idxs.withUnsafeMutableBufferPointer {
            LLVMBuildGEP2(b, structTy, addr, $0.baseAddress, 2, "fld")
        }!
    }

    // Thin wrappers over the LLVM C API that own the `[LLVMTypeRef?]` buffer dance the raw calls
    // require, so call sites read in terms of types/values, not pointers + counts.
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

    // The single seam through which every LLVM function is created. When `debug` is given it also
    // attaches a `DISubprogram` (recovered later via `LLVMGetSubprogram`), so 8.3's line-table/
    // debug-scope setup lands here instead of at each `LLVMAddFunction`.
    //
    // 8.4.1 — every function *we emit a body for* (free fns, methods, actor handlers, witness/
    // property thunks, closures, spawn routines) is `gc "statepoint-example"`: any of them can be a
    // frame at a safepoint, so the caller needs a stack map at each of its calls (compiler.md §2 GC backend substrate).
    // Runtime C declarations pass `gc: false` (`runtimeFn`) and stay plain.
    func emitFunction(_ name: String, ret: LLVMTypeRef, params: [LLVMTypeRef],
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
    // (compiler.md §2 GC backend substrate, perf lever). Conservative: when unsure, a call stays non-leaf, since
    // mislabeling a GC-triggering call as leaf is the unsound direction. 6.1.4: `rt_str_concat`
    // allocates (→ can trigger GC), so it is non-leaf (a statepoint recording the caller's roots);
    // `rt_str_lit` still only wraps a static pointer (no alloc), so it stays leaf. `String` staying a
    // runtime-owned value (buffer `addr0`) is why its value never becomes a GC root here — the full
    // GC-object form (Q6) needs `String` heap-boxed (the FCA limit), deferred with 6.2.
    static let gcLeafRuntimeFns: Set<String> = [
        "printf", "rt_str_lit", "rt_mutex_new", "rt_mutex_unlock",
        "rt_bounds_trap",   // aborts, never allocates — no statepoint needed
        "memcpy",           // libc block copy — never allocates (array grow)
        "memset",           // libc fill — zeroes the inline-allocated object; never allocates
        "rt_gc_write_barrier",   // M6 · 6.3.1 — remembers the mutated object; never triggers GC
    ]

    func markGCLeaf(_ fn: LLVMValueRef) {
        let name = "gc-leaf-function"
        let attr = LLVMCreateStringAttribute(ctx, name, UInt32(name.utf8.count), "", 0)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, attr)
    }

    var funcAttrIndex: LLVMAttributeIndex {
        LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex))
    }

    func addAlwaysInline(_ fn: LLVMValueRef) {
        let k = LLVMGetEnumAttributeKindForName("alwaysinline", "alwaysinline".utf8.count)
        LLVMAddAttributeAtIndex(fn, funcAttrIndex, LLVMCreateEnumAttribute(ctx, k, 0))
    }

    // Build a stub seam's body without disturbing the caller's builder position / debug location
    // (a seam stub carries no subprogram, so a foreign `!dbg` would trip the verifier).
    func withStubBody(_ fn: LLVMValueRef, _ build: () -> Void) {
        let savedBlock = LLVMGetInsertBlock(b)
        let savedLoc = di != nil ? LLVMGetCurrentDebugLocation2(b) : nil
        if di != nil { LLVMSetCurrentDebugLocation2(b, nil) }
        LLVMPositionBuilderAtEnd(b, LLVMAppendBasicBlockInContext(ctx, fn, "entry"))
        build()
        if let savedBlock = savedBlock { LLVMPositionBuilderAtEnd(b, savedBlock) }
        if di != nil { LLVMSetCurrentDebugLocation2(b, savedLoc) }
    }

}
