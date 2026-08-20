import sema
import midend
import noir
import ast
import support
import Foundation
import LLVM_C

extension NOIRToLLVM {
    // MARK: - Structured concurrency (8.2.6)

    // `spawn let name = value` runs `value` on a fiber. Like a closure, the value's free variables
    // are captured by value into a heap env; a hoisted start routine `void* nomu_spawnN(void* env)`
    // computes the value and returns a heap box of the result. The site starts the fiber and stores
    // its handle; reads of `name` (and scope/function exit) join it.
    func lowerSpawnLet(name: String, value: NOIRExpr, resultType: Type, span: Span) {
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
    func joinSpawn(_ name: String) -> LLVMValueRef? {
        guard let sp = spawnLocals[name] else { return nil }
        let sj = runtimeFn("spawn_join", ret: i8ptr, params: [i8ptr], varArg: false)
        let box = buildCall(sj.0, sj.1, [sp.handleSlot])!
        return LLVMBuildLoad2(b, sp.resultTy, box, name)
    }

    // `sleep(ms)` → `rt_sleep_ms(ms)` (Int); a colorless blocking call that parks the fiber.
    func lowerSleep(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let arg = args.first, let ms = lowerExpr(arg.value) else {
            fail("8.2.6: sleep expects one Int argument", span); return nil
        }
        let fn = runtimeFn("rt_sleep_ms", ret: i64, params: [i64], varArg: false)
        return buildCall(fn.0, fn.1, [ms])
    }

    // `readLine()` → `rt_read_line(0)` (String); parks the fiber until stdin is readable.
    func lowerReadLine() -> LLVMValueRef? {
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
    func arrayElemStride(_ t: Type) -> Int { e.arrayElemStride(t) }

    func gepByte(_ ptr: LLVMValueRef, _ off: LLVMValueRef) -> LLVMValueRef { e.gepByte(ptr, off) }   // → LLVMGen

    // The shared type-id for every Array handle — identical layout for all T (one managed field,
    // bufptr at byte 16), so it is a fixed-size object using the ordinary 6.1.3 map.
    func arrayHandleTypeId() -> UInt64 { e.arrayHandleTypeId() }

    // The array-buffer type-id for element type `elem` (M6 stdlib · Slice 4): a variable-size object
    // whose per-element managed-pointer offsets are `elem`'s own managed offsets, repeated `cap` times
    // by the collector. Registered once per element type.
    func arrayBufTypeId(_ elem: Type) -> UInt64 { e.arrayBufTypeId(elem) }

    // [e0, e1, …] → allocate the handle + (for a non-empty literal) the buffer, stamp headers, store
    // each element. Returns the handle (the Array value, a managed pointer).
    func lowerArrayLit(_ elements: [NOIRExpr], _ arrayType: Type, _ span: Span) -> LLVMValueRef? {
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
    func arrayElemAddr(_ handle: LLVMValueRef, _ idxV: LLVMValueRef, _ elemType: Type)
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
    func lowerIndex(_ base: NOIRExpr, _ idx: NOIRExpr, _ elemType: Type, _ span: Span) -> LLVMValueRef? {
        guard let handle = lowerExpr(base), let idxV = lowerExpr(idx), let elemLL = llvmType(elemType, span),
              let e = arrayElemAddr(handle, idxV, elemType) else { return nil }
        return LLVMBuildLoad2(b, elemLL, e.addr, "arr.elem")
    }

    // a[i] = x → bounds-checked element store (args: handle, index, value). Result unused. A managed
    // element goes through the write barrier (`storeField`) with the buffer as the source object, so a
    // store into a mature buffer remembers it (6.3.1); a value element is a plain store.
    func lowerArraySet(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    func lowerArrayAppend(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
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
    func lowerArrayCount(_ args: [NOIRArg], _ span: Span) -> LLVMValueRef? {
        guard let a = args.first, let handle = lowerExpr(a.value) else { return nil }
        return LLVMBuildLoad2(b, i64, gepByte(handle, LLVMConstInt(i64, 8, 0)), "arr.count")
    }

    func lowerCall(callee: NOIRExpr, args: [NOIRArg], span: Span) -> LLVMValueRef? {
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
            case "__int_uint8_uint8": return lowerIntToUInt8(args, span)
            case "__uint8_int_int": return lowerUInt8ToInt(args, span)
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
    func buildArgsAndCall(_ fnTy: LLVMTypeRef, _ fn: LLVMValueRef, env: LLVMValueRef?, args: [NOIRArg]) -> LLVMValueRef? {
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

}
