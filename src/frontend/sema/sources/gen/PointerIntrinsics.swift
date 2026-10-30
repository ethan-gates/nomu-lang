import noir
import ast
import support
// Pointer intrinsics (task 125) — the builtin typechecking for the unsafe raw-memory
// surface `RawPtr` and `Ptr<T>`: their static methods (`RawPtr.alloc`, `Ptr<T>.alloc`),
// instance methods (`load`/`store`/`advanced`/atomics/…), and the `.null` static property.
// The runtime's privileged operations are on `Runtime` (RuntimeIntrinsics.swift). Reached from expression checking when a receiver
// (or a qualified type name) is a pointer type.
//
// A capability namespace over `inout Sema`: it reads the diagnostic sink and the
// top-level function table, and calls back into the core expression walk (`checkExpr`,
// `coerce`, `checkAssignable`) to check argument sub-expressions. NOIR intrinsic-call
// nodes are built through `Sema.ptrIntrinsic`.
enum PointerIntrinsics {

    // MARK: - Argument helpers

    // Unsafe raw-memory surface (task 125). Element types are limited to the single-word scalars a
    // plain addrspace(0) load/store can move; aggregates are out of the minimal floor.
    static func isRawScalar(_ t: Type) -> Bool {
        switch t {
        case .int, .uint8, .uint64, .double, .bool, .rawPtr, .ptr: return true
        default: return false
        }
    }

    // Validate a builtin call's argument labels against a fixed expected list (nil = an unlabeled
    // positional argument). The pointer surface spells its offsets/counts explicitly (`toByteOffset:`,
    // `by:`), so the labels are required, matching the design.
    static func checkArgLabels(_ s: inout Sema, _ args: [Arg], _ expected: [String?], _ ctx: String, _ span: Span) -> Bool {
        guard args.count == expected.count else {
            let sig = expected.map { $0.map { "\($0):" } ?? "_" }.joined(separator: ", ")
            s.diags.error("\(ctx) expects \(expected.count) argument(s) (\(sig)), got \(args.count)", at: span)
            return false
        }
        var ok = true
        for (a, want) in zip(args, expected) where a.label != want {
            let wantDesc = want.map { "label '\($0):'" } ?? "no label"
            let gotDesc = a.label.map { "'\($0):'" } ?? "no label"
            s.diags.error("\(ctx): expected \(wantDesc), got \(gotDesc)", at: span)
            ok = false
        }
        return ok
    }

    // Check an `Int`-typed argument of a pointer builtin, enforcing the type as the virtual signature
    // demands (a byte offset / count / alignment). `coerce(_, to: .int)` is a no-op, so this is what
    // actually rejects a non-Int argument.
    static func intArg(_ s: inout Sema, _ e: Expr, _ ctx: String, _ what: String) -> NOIRExpr {
        let v = NOIRGen.checkExpr(&s, e, expected: .int)
        if v.type != .int, v.type != .error {
            s.diags.error("\(ctx): \(what) must be an 'Int', got '\(v.type)'", at: v.span)
        }
        return v
    }

    static func ptrArg(_ s: inout Sema, _ e: Expr, _ ctx: String, _ what: String) -> NOIRExpr {
        let v = NOIRGen.checkExpr(&s, e)
        if v.type != .rawPtr, v.type != .error {
            s.diags.error("\(ctx): \(what) must be a 'RawPtr', got '\(v.type)'", at: v.span)
        }
        return v
    }

    // MARK: - Static property

    // Pointer static properties: `RawPtr.null` / `Ptr<T>.null` — a null address of the named type.
    static func checkPointerStaticMember(_ s: inout Sema, _ tn: String, _ explicit: [Type]?, _ field: String, _ span: Span) -> NOIRExpr {
        guard field == "null" else {
            let ty = tn == "Ptr" ? "Ptr<T>" : tn
            s.diags.error("type '\(ty)' has no static property '\(field)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        if tn == "RawPtr" { return s.ptrIntrinsic("__ptrNull", .rawPtr, [], span) }
        guard let elems = explicit, elems.count == 1 else {
            s.diags.error("'Ptr' needs one type argument, e.g. 'Ptr<Int>.null'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        return s.ptrIntrinsic("__ptrNull", .ptr(elems[0]), [], span)
    }

    // MARK: - RawPtr static methods

    static func checkRawPtrStatic(_ s: inout Sema, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(&s, args, ["bytes", "align"], "RawPtr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let bytes = intArg(&s, args[0].value, "RawPtr.alloc", "bytes")
            let align = intArg(&s, args[1].value, "RawPtr.alloc", "align")
            return s.ptrIntrinsic("__rawAlloc", .rawPtr, [bytes, align], span)
        default:
            s.diags.error("type 'RawPtr' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // MARK: - RawPtr instance methods

    static func checkRawPtrMethod(_ s: inout Sema, _ recv: NOIRExpr, _ name: String, _ args: [Arg], _ span: Span, expected: Type?) -> NOIRExpr {
        switch name {
        case "free":
            guard checkArgLabels(&s, args, [], "RawPtr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawFree", .void, [recv], span)
        case "advanced":
            guard checkArgLabels(&s, args, ["by"], "RawPtr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(&s, args[0].value, "RawPtr.advanced", "by")
            return s.ptrIntrinsic("__rawAdvanced", .rawPtr, [recv, by], span)
        case "store":
            guard checkArgLabels(&s, args, [nil, "toByteOffset"], "RawPtr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = NOIRGen.checkExpr(&s, args[0].value)
            if value.type != .error, !isRawScalar(value.type) {
                s.diags.error("RawPtr.store supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(value.type)'", at: value.span)
            }
            let off = intArg(&s, args[1].value, "RawPtr.store", "toByteOffset")
            return s.ptrIntrinsic("__rawStore", .void, [recv, value, off], span)
        // Bulk-zero `n` bytes from this pointer — a `memset(self, 0, n)` (task 150.4.5.1). The self-hosted
        // allocator hands out reused heap holes whose bytes are stale from the previous occupant; zeroing the
        // hole restores the zero-init contract the collector relies on (an over-allocated array buffer's
        // unwritten tail must read null, so the tracer never scans stale words as pointers).
        case "zeroBytes":
            guard checkArgLabels(&s, args, [nil], "RawPtr.zeroBytes", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let n = intArg(&s, args[0].value, "RawPtr.zeroBytes", "n")
            return s.ptrIntrinsic("__rawZeroBytes", .void, [recv, n], span)
        // memcpy(self, from, byteCount) — copy a raw byte range. Used to grow the minor collector's promotion
        // queue (alloc a larger buffer, copy the live prefix over). Non-overlapping.
        case "copyBytes":
            guard checkArgLabels(&s, args, ["from", "byteCount"], "RawPtr.copyBytes", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let src = ptrArg(&s, args[0].value, "RawPtr.copyBytes", "from")
            let cn = intArg(&s, args[1].value, "RawPtr.copyBytes", "byteCount")
            return s.ptrIntrinsic("__rawCopyBytes", .void, [recv, src, cn], span)
        case "load":
            guard checkArgLabels(&s, args, ["fromByteOffset"], "RawPtr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard let elem = expected, isRawScalar(elem) else {
                s.diags.error("cannot infer the element type of 'RawPtr.load' — annotate the result with a scalar type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let off = intArg(&s, args[0].value, "RawPtr.load", "fromByteOffset")
            return s.ptrIntrinsic("__rawLoad", elem, [recv, off], span)
        // Atomics (task 128.1.1, scheduler substrate). i64 sequentially-consistent ops over a RawPtr slot
        // — the primitive under the MT-safe run queue, STW flags, and futex words. Int-width only for now.
        case "atomicLoad":
            guard checkArgLabels(&s, args, ["fromByteOffset"], "RawPtr.atomicLoad", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let off = intArg(&s, args[0].value, "RawPtr.atomicLoad", "fromByteOffset")
            return s.ptrIntrinsic("__atomicLoad", .int, [recv, off], span)
        case "atomicStore":
            guard checkArgLabels(&s, args, [nil, "toByteOffset"], "RawPtr.atomicStore", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let value = intArg(&s, args[0].value, "RawPtr.atomicStore", "value")
            let off = intArg(&s, args[1].value, "RawPtr.atomicStore", "toByteOffset")
            return s.ptrIntrinsic("__atomicStore", .void, [recv, value, off], span)
        // Compare-and-swap: returns the value read (the old word). The caller compares it to `expected` to
        // learn whether the swap took, the standard CAS-loop shape.
        case "atomicCas":
            guard checkArgLabels(&s, args, [nil, nil, "atByteOffset"], "RawPtr.atomicCas", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let expc = intArg(&s, args[0].value, "RawPtr.atomicCas", "expected")
            let desr = intArg(&s, args[1].value, "RawPtr.atomicCas", "desired")
            let coff = intArg(&s, args[2].value, "RawPtr.atomicCas", "atByteOffset")
            return s.ptrIntrinsic("__atomicCas", .int, [recv, expc, desr, coff], span)
        // Fetch-and-add: returns the previous value.
        case "atomicFetchAdd":
            guard checkArgLabels(&s, args, [nil, "atByteOffset"], "RawPtr.atomicFetchAdd", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let delta = intArg(&s, args[0].value, "RawPtr.atomicFetchAdd", "delta")
            let aoff = intArg(&s, args[1].value, "RawPtr.atomicFetchAdd", "atByteOffset")
            return s.ptrIntrinsic("__atomicFetchAdd", .int, [recv, delta, aoff], span)
        case "atomicExchange":
            guard checkArgLabels(&s, args, [nil, "atByteOffset"], "RawPtr.atomicExchange", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let newv = intArg(&s, args[0].value, "RawPtr.atomicExchange", "value")
            let xoff = intArg(&s, args[1].value, "RawPtr.atomicExchange", "atByteOffset")
            return s.ptrIntrinsic("__atomicExchange", .int, [recv, newv, xoff], span)
        case "eq":
            guard checkArgLabels(&s, args, [nil], "RawPtr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = NOIRGen.checkExpr(&s, args[0].value)
            if other.type != .rawPtr, other.type != .error {
                s.diags.error("RawPtr.eq expects a 'RawPtr' argument, got '\(other.type)'", at: other.span)
            }
            return s.ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        // The pointer's numeric address as an Int (ptrtoint), for addr→index math over raw memory (the
        // Immix side tables, task 150 rung 3): `(addr − heapBase) / lineSize`. Sound on addrspace(0) raw
        // memory the collector owns off-heap.
        case "toInt":
            guard checkArgLabels(&s, args, [], "RawPtr.toInt", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawToInt", .int, [recv], span)
        case "asPtr":
            guard checkArgLabels(&s, args, [], "RawPtr.asPtr", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            guard case .ptr = (expected ?? .error) else {
                s.diags.error("cannot infer the target type of 'RawPtr.asPtr' — annotate the result as 'Ptr<T>'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawAsPtr", expected!, [recv], span)
        default:
            s.diags.error("value of type 'RawPtr' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // MARK: - Ptr<T> static and instance methods

    static func checkPtrStatic(_ s: inout Sema, _ elem: Type, _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "alloc":
            guard checkArgLabels(&s, args, ["count"], "Ptr.alloc", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            if elem != .error, !isRawScalar(elem) {
                s.diags.error("Ptr<T>.alloc requires a scalar element type (Int, UInt8, Double, Bool, RawPtr, Ptr<T>), got '\(elem)'", at: span)
            }
            let count = intArg(&s, args[0].value, "Ptr.alloc", "count")
            return s.ptrIntrinsic("__ptrAlloc", .ptr(elem), [count], span)
        default:
            s.diags.error("type 'Ptr<\(elem)>' has no static method '\(method)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    static func checkPtrMethod(_ s: inout Sema, _ recv: NOIRExpr, _ elem: Type, _ name: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        if elem != .error, !isRawScalar(elem) {
            s.diags.error("Ptr<\(elem)> supports scalar element types (Int, UInt8, Double, Bool, RawPtr, Ptr<T>)", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        switch name {
        case "load":
            guard checkArgLabels(&s, args, ["at"], "Ptr.load", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let at = intArg(&s, args[0].value, "Ptr.load", "at")
            return s.ptrIntrinsic("__ptrLoad", elem, [recv, at], span)
        case "store":
            guard checkArgLabels(&s, args, [nil, "at"], "Ptr.store", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let ce = NOIRGen.checkExpr(&s, args[0].value, expected: elem)
            let value = NOIRGen.coerce(&s, ce, to: elem)
            NOIRGen.checkAssignable(&s, value.type, to: elem, role: "argument", at: value.span)
            let at = intArg(&s, args[1].value, "Ptr.store", "at")
            return s.ptrIntrinsic("__ptrStore", .void, [recv, value, at], span)
        case "advanced":
            guard checkArgLabels(&s, args, ["by"], "Ptr.advanced", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let by = intArg(&s, args[0].value, "Ptr.advanced", "by")
            return s.ptrIntrinsic("__ptrAdvanced", .ptr(elem), [recv, by], span)
        case "asRaw":
            guard checkArgLabels(&s, args, [], "Ptr.asRaw", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__ptrAsRaw", .rawPtr, [recv], span)
        case "free":
            guard checkArgLabels(&s, args, [], "Ptr.free", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            return s.ptrIntrinsic("__rawFree", .void, [recv], span)   // same addrspace(0) word as RawPtr.free
        case "eq":
            guard checkArgLabels(&s, args, [nil], "Ptr.eq", span) else {
                return NOIRExpr(type: .error, span: span, kind: .intLit(0))
            }
            let other = NOIRGen.checkExpr(&s, args[0].value)
            if other.type != .ptr(elem), other.type != .error {
                s.diags.error("Ptr<\(elem)>.eq expects a 'Ptr<\(elem)>' argument, got '\(other.type)'", at: other.span)
            }
            return s.ptrIntrinsic("__ptrEq", .bool, [recv, other], span)
        default:
            s.diags.error("value of type 'Ptr<\(elem)>' has no method '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }
}

// Task 180: `ManagedBuffer<Header, Element>` — the four compiler intrinsics for the stdlib generic class
// (core.nomu). The declared class carries no method bodies; `create` (static) and `capacity` / `headerPtr` /
// `elementPtr` (instance) are synthesized here as `__managedBuffer*` intrinsic calls. Codegen derives the
// header byte size, element stride, and GC descriptor from the concrete `Header`/`Element` (through
// monomorphization's type-arg table), so Sema only emits the calls carrying the `ManagedBuffer` type on the
// relevant operand (the result for `create`, the receiver for the accessors).
enum ManagedBufferIntrinsics {
    private static func err(_ span: Span) -> NOIRExpr {
        NOIRExpr(type: .error, span: span, kind: .intLit(0))
    }

    // `ManagedBuffer<Header, Element>.create(capacity: Int) -> ManagedBuffer<Header, Element>`. `base` is the
    // `ManagedBuffer` identity the result type carries — the `nomu/core` per-origin key (task 174.5.1), so
    // the instantiation monomorphizes against the external template.
    static func checkStatic(_ s: inout Sema, base: String, header: Type, element: Type,
                            _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        switch method {
        case "create":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["capacity"], "ManagedBuffer.create", span) else {
                return err(span)
            }
            let cap = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.create", "capacity")
            return s.ptrIntrinsic("__managedBufferCreate",
                                  .generic(base: base, args: [header, element]), [cap], span)
        default:
            s.diags.error("'ManagedBuffer' has no static method '\(method)'", at: span)
            return err(span)
        }
    }

    // Instance accessors on a `ManagedBuffer` receiver: the raw accessors (`capacity()`, `headerPtr()`,
    // `elementPtr(at:)`) whose layout is resolved at codegen, and the typed *reference* accessors
    // (`storeRef`/`ref`, `storeHeaderRef`/`headerRef`) which read `Header`/`Element` from the receiver's
    // generic type here. The reference accessors store/load a managed pointer through the write-barrier /
    // `p1` path (codegen), the facility `Array<SomeClass>` needs to put a reference in a buffer; the raw
    // `RawPtr` accessors reject references (barrier-free), so scalar code uses those instead.
    static func checkMethod(_ s: inout Sema, _ recv: NOIRExpr,
                            _ method: String, _ args: [Arg], _ span: Span) -> NOIRExpr {
        // `Header`/`Element` from `ManagedBuffer<Header, Element>`; the reference accessors require them.
        var header: Type? = nil, element: Type? = nil
        if case .generic(_, let gargs) = recv.type, gargs.count == 2 {
            header = gargs[0]; element = gargs[1]
        }
        switch method {
        case "capacity":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.capacity", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferCapacity", .int, [recv], span)
        case "headerPtr":
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.headerPtr", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferHeaderPtr", .rawPtr, [recv], span)
        case "elementPtr":
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at"], "ManagedBuffer.elementPtr", span) else { return err(span) }
            let i = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.elementPtr", "at")
            return s.ptrIntrinsic("__managedBufferElementPtr", .rawPtr, [recv, i], span)
        // Typed managed element access: store/load a reference at element slot `at`, through the write
        // barrier so the collector records the edge. Reference `Element` only — a bare `p1`, no aggregate;
        // a scalar/value element uses `elementPtr(at:)`.
        case "storeRef":
            guard let elem = requireRefArg(&s, element, kind: "Element", "storeRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil, "at"], "ManagedBuffer.storeRef", span) else { return err(span) }
            let value = refValueArg(&s, args[0].value, elem, span)
            let i = PointerIntrinsics.intArg(&s, args[1].value, "ManagedBuffer.storeRef", "at")
            return s.ptrIntrinsic("__managedBufferStoreRef", .void, [recv, value, i], span)
        case "ref":
            guard let elem = requireRefArg(&s, element, kind: "Element", "ref", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, ["at"], "ManagedBuffer.ref", span) else { return err(span) }
            let i = PointerIntrinsics.intArg(&s, args[0].value, "ManagedBuffer.ref", "at")
            return s.ptrIntrinsic("__managedBufferRef", elem, [recv, i], span)
        // The same, for a reference `Header` (the whole header is one managed pointer).
        case "storeHeaderRef":
            guard let hdr = requireRefArg(&s, header, kind: "Header", "storeHeaderRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [nil], "ManagedBuffer.storeHeaderRef", span) else { return err(span) }
            let value = refValueArg(&s, args[0].value, hdr, span)
            return s.ptrIntrinsic("__managedBufferStoreHeaderRef", .void, [recv, value], span)
        case "headerRef":
            guard let hdr = requireRefArg(&s, header, kind: "Header", "headerRef", span) else { return err(span) }
            guard PointerIntrinsics.checkArgLabels(&s, args, [], "ManagedBuffer.headerRef", span) else { return err(span) }
            return s.ptrIntrinsic("__managedBufferHeaderRef", hdr, [recv], span)
        default:
            s.diags.error("value of type 'ManagedBuffer' has no method '\(method)'", at: span)
            return err(span)
        }
    }

    // A reference accessor is well-formed only when the relevant type argument is a reference type (class /
    // actor / array). Returns the type on success; diagnoses and returns nil otherwise.
    private static func requireRefArg(_ s: inout Sema, _ t: Type?, kind: String,
                                      _ method: String, _ span: Span) -> Type? {
        guard let t = t else {
            s.diags.error("'ManagedBuffer.\(method)' needs the buffer's \(kind) type, e.g. 'ManagedBuffer<Header, Element>'", at: span)
            return nil
        }
        guard s.isReferenceType(t) else {
            s.diags.error("'ManagedBuffer.\(method)' requires a reference \(kind) (class or actor), but \(kind) is '\(t)'; use the raw accessor for a scalar or value \(kind.lowercased())", at: span)
            return nil
        }
        return t
    }

    // Typecheck a reference-valued argument against the expected reference type.
    private static func refValueArg(_ s: inout Sema, _ e: Expr, _ expected: Type, _ span: Span) -> NOIRExpr {
        let value = NOIRGen.coerce(&s, NOIRGen.checkExpr(&s, e, expected: expected), to: expected)
        NOIRGen.checkAssignable(&s, value.type, to: expected, role: "argument", at: span)
        return value
    }
}
