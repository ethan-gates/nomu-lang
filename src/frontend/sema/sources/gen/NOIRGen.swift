import noir
import ast
import support
// NOIR generation: the lowering walk that turns the checked AST into a NOIR module. This is the
// core recursive descent — declarations → members → statements → expressions/calls — that runs
// during `Sema.check()` before the finished-module passes (`Mutation`, `Exhaustiveness`,
// `RuntimeSubset`).
//
// A capability namespace over `inout Sema`, matching the other extracted capabilities: each
// lowering step is a `static func` taking `_ s: inout Sema`. The type environment it queries
// (`resolve`, the symbol/interface oracle, `unify`/`substitute`) and the walk's scope/state
// accessors stay on `Sema` and are called as `s.…`; sibling lowering steps are called directly
// with `&s`.
enum NOIRGen {

    // MARK: - Statements

    static func lowerBlock(_ s: inout Sema, _ block: Block) -> [NOIRStmt] {
        s.pushScope()
        let stmts = block.map { lowerStmt(&s, $0) }
        s.popScope()
        return stmts
    }

    static func lowerStmt(_ s: inout Sema, _ stmt: Stmt) -> NOIRStmt {
        switch stmt {
        case .binding(let b):
            // `let x: some I = expr` — a fresh opaque binding whose hidden underlying is
            // `expr`'s concrete type (M5 A3). Each such binding gets its own opaque identity.
            if let tref = b.type, tref.opaqueOf != nil {
                s.opaqueBindingCounter += 1
                let owner = "let:\(s.opaqueBindingCounter)"
                let ann = s.resolve(tref, opaqueOwner: owner)
                let value = checkExpr(&s, b.value)
                if case .opaque(let ifaces, _) = ann {
                    recordOpaque(&s, value, interfaces: ifaces, owner: owner, at: b.span)
                }
                s.declare(b.name, ann, isMutable: b.isMutable)
                return NOIRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)
            }
            let annotated = b.type.map { s.resolve($0) }
            let ce = checkExpr(&s, b.value, expected: annotated)
            let value = coerce(&s, ce, to: annotated)
            checkAssignable(&s, value.type, to: annotated, role: "bind", at: b.span)
            let type = annotated ?? value.type
            s.declare(b.name, type, isMutable: b.isMutable)
            return NOIRStmt(kind: .letBinding(name: b.name, isMutable: b.isMutable, value: value), span: b.span)

        case .spawnLet(let name, _, let value, let span):
            let v = checkExpr(&s, value)
            s.declare(name, v.type)   // reading a spawn binding yields its result value
            return NOIRStmt(kind: .spawnLet(name: name, value: v, resultType: v.type), span: span)

        case .assign(let lhs, let rhs, let span):
            // Array subscript write `a[i] = x` — reference semantics (mutates the shared buffer, so a
            // `let`-bound array is fine, like a class field). Lowered to a builtin call codegen handles.
            if case .index(let arr, let idxE, _) = lhs {
                let a = checkExpr(&s, arr)
                guard case .array(let elem) = a.type else {
                    if a.type != .error { s.diags.error("cannot subscript-assign a value of type '\(a.type)' — only 'Array<T>' supports '[ ] ='", at: span) }
                    return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs)), span: span)
                }
                let iIdx = checkExpr(&s, idxE, expected: .int)
                if iIdx.type != .int && iIdx.type != .error {
                    s.diags.error("array index must be an 'Int', got '\(iIdx.type)'", at: iIdx.span)
                }
                let ce = checkExpr(&s, rhs, expected: elem)
                let value = coerce(&s, ce, to: elem)
                checkAssignable(&s, value.type, to: elem, role: "assign", at: span)
                let callee = NOIRExpr(type: .void, span: span, kind: .varRef("__arraySet"))
                let call = NOIRExpr(type: .void, span: span, kind: .call(callee: callee,
                    args: [NOIRArg(label: nil, value: a), NOIRArg(label: nil, value: iIdx), NOIRArg(label: nil, value: value)], typeArgs: []))
                return NOIRStmt(kind: .exprStmt(call), span: span)
            }
            // A write to a computed property lowers to a setter accessor call (M5 A1).
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(&s, base)
                // A property write through `any I` / `any A & B` — dispatched via the witness
                // set slot (M5 A1.4). A get-only requirement is a clean local error.
                if let iface = s.existentialInterfaces(b.type).first(where: { s.aggregatedProperties($0).contains { $0.name == field } }),
                   let prop = s.aggregatedProperties(iface).first(where: { $0.name == field }) {
                    let propType = s.resolve(prop.type)
                    guard prop.isSettable else {
                        s.diags.error("cannot assign to read-only property '\(field)' of 'any \(iface)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(&s, rhs, expected: propType)
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                // A property write inside an interface default (self: interface) — routes to the
                // set slot; the concrete synthesized copy writes the real field/setter (M5).
                if case .named(let tn, .interface_) = b.type,
                   let prop = s.aggregatedProperties(tn).first(where: { $0.name == field }) {
                    let propType = s.resolve(prop.type)
                    guard prop.isSettable else {
                        s.diags.error("cannot assign to read-only property '\(field)' of '\(tn)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(&s, rhs, expected: propType)
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                if case .named(let tn, let kind) = b.type, let info = s.computedProps[tn]?[field] {
                    guard info.hasSetter else {
                        s.diags.error("cannot assign to read-only computed property '\(field)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs, expected: info.type)), span: span)
                    }
                    let value = checkExpr(&s, rhs, expected: info.type)
                    // The setter mutates the value; on a value type it needs a mutable receiver.
                    if kind != .class_ {
                        s.methodCallSites.append(Sema.CallSite(callee: "\(tn).\(field).set",
                                                        receiverMutable: isMutableReceiver(s, base), span: span))
                    }
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                // Computed-property write on an applied generic type `Box<Int>` (task 151).
                if case .generic(let gbase, let gargs) = b.type, let info = s.computedProps[gbase]?[field] {
                    let propType = s.substitute(info.type, GenericInference.genericSubst(&s, gbase, gargs))
                    guard info.hasSetter else {
                        s.diags.error("cannot assign to read-only computed property '\(field)'", at: span)
                        return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs, expected: propType)), span: span)
                    }
                    let value = checkExpr(&s, rhs, expected: propType)
                    if s.kindOf(gbase) != .class_ {
                        s.methodCallSites.append(Sema.CallSite(callee: "\(gbase).\(field).set",
                                                        receiverMutable: isMutableReceiver(s, base), span: span))
                    }
                    let call = NOIRExpr(type: .void, span: span,
                                      kind: .methodCall(receiver: b, method: "\(field).set", args: [value]))
                    return NOIRStmt(kind: .exprStmt(call), span: span)
                }
                let ftype = fieldType(&s, of: b.type, field: field, at: mspan)
                let target = NOIRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(s, target)
                let ce = checkExpr(&s, rhs, expected: ftype)
                let value = coerce(&s, ce, to: ftype)
                checkAssignable(&s, value.type, to: ftype, role: "assign", at: span)
                return NOIRStmt(kind: .assign(target: target, value: value), span: span)
            }
            let target = checkExpr(&s, lhs)
            rejectLetFieldTarget(s, target)
            let ce = checkExpr(&s, rhs, expected: target.type)
            let value = coerce(&s, ce, to: target.type)
            checkAssignable(&s, value.type, to: target.type, role: "assign", at: span)
            return NOIRStmt(kind: .assign(target: target, value: value), span: span)

        case .compoundAssign(let lhs, let rhs, let span):
            if case .member(let base, let field, let mspan) = lhs {
                let b = checkExpr(&s, base)
                if case .named(let tn, _) = b.type, s.computedProps[tn]?[field] != nil {
                    s.diags.error("compound assignment ('+=') to a computed property is not supported yet", at: span)
                    return NOIRStmt(kind: .exprStmt(checkExpr(&s, rhs)), span: span)
                }
                let ftype = fieldType(&s, of: b.type, field: field, at: mspan)
                let target = NOIRExpr(type: ftype, span: mspan, kind: .fieldAccess(base: b, field: field))
                rejectLetFieldTarget(s, target)
                // The `+=` operand takes the target's type as context, so a bare literal adopts it
                // (`w += 1` on a UInt64 keeps the whole op UInt64) rather than defaulting to Int.
                return NOIRStmt(kind: .compoundAssign(target: target, value: checkExpr(&s, rhs, expected: ftype)), span: span)
            }
            let target = checkExpr(&s, lhs)
            rejectLetFieldTarget(s, target)
            return NOIRStmt(kind: .compoundAssign(target: target, value: checkExpr(&s, rhs, expected: target.type)), span: span)

        case .ret(let e, let span):
            // A `some I` return is not a coercion target — it yields the concrete value
            // unboxed and records the one hidden underlying type (M5 A3).
            if case .opaque(let ifaces, let owner) = s.currentReturnType {
                let v = e.map { checkExpr(&s, $0) }
                if let v { recordOpaque(&s, v, interfaces: ifaces, owner: owner, at: span) }
                return NOIRStmt(kind: .ret(v), span: span)
            }
            let rt = s.currentReturnType
            let ret = e.map { (x: Expr) -> NOIRExpr in let ce = checkExpr(&s, x, expected: rt); return coerce(&s, ce, to: rt) }
            if let ret { checkAssignable(&s, ret.type, to: rt, role: "return", at: span) }
            return NOIRStmt(kind: .ret(ret), span: span)

        case .ifStmt(let st):
            let cond = checkExpr(&s, st.cond)
            let then = lowerBlock(&s, st.thenBody)
            let els = st.elseBody.map { lowerBlock(&s, $0) }
            return NOIRStmt(kind: .ifStmt(cond: cond, then: then, else: els), span: st.span)

        case .whileStmt(let st):
            let cond = checkExpr(&s, st.cond)
            s.loopDepth += 1
            let body = lowerBlock(&s, st.body)
            s.loopDepth -= 1
            return NOIRStmt(kind: .whileStmt(cond: cond, body: body), span: st.span)

        case .breakStmt(let span):
            if s.loopDepth == 0 { s.diags.error("'break' outside a loop", at: span) }
            return NOIRStmt(kind: .breakStmt, span: span)

        case .continueStmt(let span):
            if s.loopDepth == 0 { s.diags.error("'continue' outside a loop", at: span) }
            return NOIRStmt(kind: .continueStmt, span: span)

        case .switchStmt(let sw):
            return NOIRStmt(kind: .switchStmt(lowerSwitch(&s, sw)), span: sw.span)

        case .expr(let e):
            let ir = checkExpr(&s, e)
            return NOIRStmt(kind: .exprStmt(ir), span: ir.span)
        }
    }

    static func lowerSwitch(_ s: inout Sema, _ sw: SwitchStmt) -> NOIRSwitch {
        let subject = checkExpr(&s, sw.subject)
        // The subject's enum, if any, gives payload binding types. An applied generic enum
        // (`Option<Int>`) substitutes its type arguments into each payload binding (M5 5.2.3).
        let enumDecl: EnumDecl?
        var enumSubst: [String: Type] = [:]
        switch subject.type {
        case .named(let n, .enum_):
            enumDecl = s.enums[n]
        case .generic(let n, let a):
            enumDecl = s.enums[n]
            for (p, t) in zip(s.enums[n]?.generics ?? [], a) { enumSubst[p.name] = t }
        default:
            enumDecl = nil
        }
        let savedScope = s.genericScope
        if let g = enumDecl?.generics, !g.isEmpty { s.genericScope = Set(g.map(\.name)) }
        defer { s.genericScope = savedScope }
        var arms: [NOIRCaseArm] = []
        for arm in sw.cases {
            guard case .enumCase(let name, let names, _) = arm.pattern else { continue }
            let caseDecl = enumDecl?.cases.first { $0.name == name }
            let bindings: [NOIRBinding] = zip(names, caseDecl?.fields ?? []).map {
                NOIRBinding(name: $0.0, type: s.substitute(s.resolve($0.1.type), enumSubst))
            }
            s.pushScope()
            for b in bindings { s.declare(b.name, b.type) }
            let body = lowerBlock(&s, arm.body)
            s.popScope()
            arms.append(NOIRCaseArm(caseName: name, bindings: bindings, body: body, span: arm.span))
        }
        return NOIRSwitch(subject: subject, arms: arms)
    }

    // MARK: - Expressions

    // Coerce a concrete conformer to `any I` / `any A & B` where an existential is
    // expected, inserting a box (M5 A1.4/A1.5b). A conformance mismatch is diagnosed here.
    // A binding/return annotation must match the value's type once coercions have run
    // (existential/opaque targets already rewrote the type). Anything still unequal is a
    // mismatch — caught here rather than leaking to the C compiler, and (for generics, whose
    // instantiations share one C layout) rather than passing silently.
    static func checkAssignable(_ s: inout Sema, _ actual: Type, to expected: Type?, role: String, at span: Span) {
        guard let expected, actual != expected, actual != .error, expected != .error else { return }
        switch role {
        case "return": s.diags.error("cannot return value of type '\(actual)' where '\(expected)' is expected", at: span)
        case "assign": s.diags.error("cannot assign value of type '\(actual)' to '\(expected)'", at: span)
        default:       s.diags.error("cannot bind value of type '\(actual)' to '\(expected)'", at: span)
        }
    }

    static func coerce(_ s: inout Sema, _ e: NOIRExpr, to expected: Type?) -> NOIRExpr {
        let target: [String]
        switch expected {
        case .existential(let iface): target = [iface]
        case .composition(let ifaces): target = ifaces
        default: return e
        }
        // Already this existential/composition.
        if e.type == expected { return e }
        switch e.type {
        case .named(let t, let kind):
            let missing = target.filter { s.conformsTo[t]?.contains($0) != true }
            if missing.isEmpty {
                if target.count > 1 { recordComposite(&s, t, kind, target) }
                return NOIRExpr(type: expected!, span: e.span, kind: .box(value: e, interfaces: target))
            }
            s.diags.error("type '\(t)' does not conform to '\(missing.joined(separator: " & "))'", at: e.span)
            return e
        case .existential(let src):
            // `any B` → `any A` where B refines A: re-box through the source witness's base
            // pointer (M5 A1.4). Composition targets/sources stay unsupported for now.
            if target.count == 1, target[0] == src || s.transitiveBases(src).contains(target[0]) {
                return NOIRExpr(type: expected!, span: e.span, kind: .box(value: e, interfaces: target))
            }
            s.diags.error("cannot convert 'any \(src)' to 'any \(target.joined(separator: " & "))' — 'any B' only widens to a base interface of B", at: e.span)
            return e
        case .composition:
            s.diags.error("existential upcast from a composition is not supported yet; box the concrete value directly", at: e.span)
            return e
        case .error:
            return e
        default:
            s.diags.error("cannot convert '\(e.type)' to 'any \(target.joined(separator: " & "))'", at: e.span)
            return e
        }
    }

    // Validate and record the hidden underlying of a `some I` site (M5 A3): the value must be
    // a concrete type conforming to every listed interface, and — across a function's returns —
    // must be the *same* concrete type each time (the one underlying).
    static func recordOpaque(_ s: inout Sema, _ v: NOIRExpr, interfaces: [String], owner: String, at span: Span) {
        // Look through an opaque initializer/return to its concrete underlying (M5 A3): a
        // `some I` value can be produced by returning / binding another opaque of a known
        // underlying, not only a concrete literal.
        var concrete = v.type
        if case .opaque(_, let innerOwner) = concrete {
            guard let u = s.opaqueUnderlyings[innerOwner] else {
                s.diags.error("cannot resolve the underlying type of this opaque value yet — declare the producing function before this use", at: span)
                return
            }
            concrete = u
        }
        guard case .named(let tn, _) = concrete else {
            if concrete != .error {
                s.diags.error("a 'some \(interfaces.joined(separator: " & "))' value must be a concrete type; got '\(v.type)'", at: span)
            }
            return
        }
        for i in interfaces where s.allConformsTo[tn]?.contains(i) != true {
            s.diags.error("type '\(tn)' does not conform to '\(i)', so it can't be returned as 'some \(interfaces.joined(separator: " & "))'", at: span)
        }
        if let existing = s.opaqueUnderlyings[owner], existing != concrete {
            s.diags.error("a 'some' type resolves to one concrete type — this also yields '\(existing)', not just '\(tn)'", at: span)
            return
        }
        s.opaqueUnderlyings[owner] = concrete
    }

    static func recordComposite(_ s: inout Sema, _ typeName: String, _ kind: NamedKind, _ ifaces: [String]) {
        let key = "\(typeName):\(ifaces.joined(separator: "&"))"
        if s.compositePairs.insert(key).inserted {
            s.compositeList.append(NOIRComposite(typeName: typeName, typeKind: kind, interfaces: ifaces))
        }
    }

    // `expected` carries a contextual type inward (binding annotation, return
    // position, call-argument slot) so leading-dot `.case` construction can infer
    // its enum (M4.10). nil elsewhere; most expressions ignore it.
    static func checkExpr(_ s: inout Sema, _ e: Expr, expected: Type? = nil) -> NOIRExpr {
        switch e {
        case .intLit(let v, let span):
            // An integer literal takes a `UInt8` context directly (`let b: UInt8 = 200`), with a
            // compile-time range check. Otherwise it is `Int`.
            if expected == .uint8 {
                if v < 0 || v > 255 {
                    s.diags.error("integer literal '\(v)' is out of range for UInt8 (0...255)", at: span)
                }
                return NOIRExpr(type: .uint8, span: span, kind: .intLit(v))
            }
            // A `UInt64` context takes a nonnegative literal directly. Literals are stored as a signed
            // 64-bit `Int`, so values in 2^63...2^64-1 are out of literal reach — build those with `~`
            // and shifts (e.g. `~UInt64(0)` for all-ones).
            if expected == .uint64 {
                if v < 0 {
                    s.diags.error("integer literal '\(v)' is out of range for UInt64 (must be nonnegative)", at: span)
                }
                return NOIRExpr(type: .uint64, span: span, kind: .intLit(v))
            }
            return NOIRExpr(type: .int,    span: span, kind: .intLit(v))
        case .doubleLit(let v, let span): return NOIRExpr(type: .double, span: span, kind: .doubleLit(v))
        case .boolLit(let v, let span):   return NOIRExpr(type: .bool,   span: span, kind: .boolLit(v))
        case .stringLit(let v, let span): return NOIRExpr(type: .string, span: span, kind: .stringLit(v))

        case .ident(let name, let span):
            if let t = s.lookup(name) {
                return NOIRExpr(type: t, span: span, kind: .varRef(name))
            }
            // Bare access to a property member of `self` — `p` means `self.p` (M5). Fires for
            // an interface default (self: interface, a property requirement) and for a computed
            // property on a concrete receiver; stored fields are already bound by name.
            if let selfTy = s.lookup("self"), s.bareMemberOfSelf(selfTy, name) {
                return checkExpr(&s, .member(.ident("self", span: span), name, span: span))
            }
            if let sig = s.funcs[name] {
                return NOIRExpr(type: .function(params: sig.params, ret: sig.ret), span: span, kind: .varRef(name))
            }
            s.diags.error("undefined name '\(name)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .varRef(name))

        case .genericIdent(let name, _, let span):
            // Reached only when `Name<Args>` is used somewhere other than a construction or a
            // qualified enum case (those are intercepted by checkCall / the `.member` branch).
            s.diags.error("type arguments on '\(name)' are only valid when constructing it, e.g. '\(name)<...>(...)' or '\(name)<...>.case(...)'", at: span)
            return NOIRExpr(type: .error, span: span, kind: .varRef(name))

        case .member(let base, let field, let span):
            // Qualified no-payload enum construction: `EnumType.case` / `EnumType<Args>.case`.
            // (A payload case used bare falls through buildEnumInit as a wrong-arity error.)
            if let (typeName, explicit) = s.typeNameAndArgs(base), s.lookup(typeName) == nil, s.enums[typeName] != nil {
                return EnumConstruction.buildEnumInit(&s, typeName, field, [], explicit: explicit, expected: expected, at: span)
            }
            // Pointer static properties (task 125): `RawPtr.null`, `Ptr<T>.null`.
            if let (tn, explicit) = s.typeNameAndArgs(base), s.lookup(tn) == nil, tn == "RawPtr" || tn == "Ptr" {
                return PointerIntrinsics.checkPointerStaticMember(&s, tn, explicit, field, span)
            }
            let b = checkExpr(&s, base)
            // Pointer instance properties (task 125): `p.isNull`.
            if case .rawPtr = b.type, field == "isNull" { return s.ptrIntrinsic("__ptrIsNull", .bool, [b], span) }
            if case .ptr = b.type, field == "isNull" { return s.ptrIntrinsic("__ptrIsNull", .bool, [b], span) }
            // Numeric conversions (M6 stdlib), property-style: `i.double` widens Int→Double;
            // `d.int` narrows Double→Int, rounding to nearest (ties away from zero). These are the
            // only Int/Double conversions — arithmetic never converts implicitly.
            if b.type == .int, field == "double" {
                return BuiltinsSema.member("__int_double_double", b, span)
            }
            if b.type == .double, field == "int" {
                return BuiltinsSema.member("__double_int_int", b, span)
            }
            // Byte conversions: `i.uint8` truncates Int→UInt8 (low 8 bits); `b.int` zero-extends
            // UInt8→Int (unsigned, always 0...255). These are the only Int/UInt8 conversions.
            if b.type == .int, field == "uint8" {
                return BuiltinsSema.member("__int_uint8_uint8", b, span)
            }
            if b.type == .uint8, field == "int" {
                return BuiltinsSema.member("__uint8_int_int", b, span)
            }
            // Word conversions: `i.uint64` reinterprets Int→UInt64 (same 64 bits); `u.int` reinterprets
            // back. `b.uint64` zero-extends UInt8→UInt64; `u.uint8` truncates UInt64→UInt8 (low 8 bits).
            if b.type == .int, field == "uint64" {
                return BuiltinsSema.member("__int_uint64_uint64", b, span)
            }
            if b.type == .uint64, field == "int" {
                return BuiltinsSema.member("__uint64_int_int", b, span)
            }
            if b.type == .uint8, field == "uint64" {
                return BuiltinsSema.member("__uint8_uint64_uint64", b, span)
            }
            if b.type == .uint64, field == "uint8" {
                return BuiltinsSema.member("__uint64_uint8_uint8", b, span)
            }

            // String property builtins (`str.hash`). Method builtins with arguments (`str.eq(x)`)
            // are handled in checkCall, since they parse with a call's argument list.
            if b.type == .string, field == "hash" {
                return BuiltinsSema.member("__string_hash_int", b, span)
            }
            // Array<T> builtin members (M6 stdlib). `count` is the element count; lowered to a builtin
            // call codegen recognizes by name (element type comes from the receiver's `.array` type).
            if case .array = b.type {
                switch field {
                case "count":
                    return BuiltinsSema.member("__array_count_int", b, span)
                default:
                    s.diags.error("value of type '\(b.type)' has no member '\(field)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
            }
            // A property-requirement read through `any I` / `any A & B` — via the getter slot.
            if let iface = s.existentialInterfaces(b.type).first(where: { s.aggregatedProperties($0).contains { $0.name == field } }),
               let prop = s.aggregatedProperties(iface).first(where: { $0.name == field }) {
                return NOIRExpr(type: s.resolve(prop.type), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read through `some I` — statically dispatched to the hidden
            // underlying (M5 A3). Emit the getter form uniformly; codegen resolves it to a direct
            // field load or a getter call once the underlying is known (so a forward reference to
            // a later-declared producer needs no underlying at check time). A `Self`-typed
            // property binds to the underlying when it is already resolved, else stays opaque.
            if case .opaque(let ifaces, let owner) = b.type,
               let iface = ifaces.first(where: { s.aggregatedProperties($0).contains { $0.name == field } }),
               let prop = s.aggregatedProperties(iface).first(where: { $0.name == field }) {
                let ty = s.resolve(prop.type, selfAs: s.opaqueUnderlyings[owner] ?? b.type)
                return NOIRExpr(type: ty, span: span, kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read through a bounded type parameter `T: I` — via the
            // bound's witness getter slot (M5 5.2.2).
            if case .typeParam(let t) = b.type,
               let iface = (s.genericBounds[t] ?? []).first(where: { s.aggregatedProperties($0).contains { $0.name == field } }),
               let prop = s.aggregatedProperties(iface).first(where: { $0.name == field }) {
                return NOIRExpr(type: s.resolve(prop.type, selfAs: b.type), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A property-requirement read inside an interface default (self: interface).
            if case .named(let tn, .interface_) = b.type,
               let prop = s.aggregatedProperties(tn).first(where: { $0.name == field }) {
                return NOIRExpr(type: s.resolve(prop.type), span: span, kind: .fieldAccess(base: b, field: field))
            }
            // A computed-property read lowers to a getter accessor call (M5 A1).
            if case .named(let tn, _) = b.type, let info = s.computedProps[tn]?[field] {
                return NOIRExpr(type: info.type, span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A computed-property read on an applied generic type `Box<Int>` (task 151): the getter's
            // declared type substitutes `T` to the concrete argument.
            if case .generic(let gbase, let gargs) = b.type, let info = s.computedProps[gbase]?[field] {
                return NOIRExpr(type: s.substitute(info.type, GenericInference.genericSubst(&s, gbase, gargs)), span: span,
                              kind: .methodCall(receiver: b, method: "\(field).get", args: []))
            }
            // A field read on an applied generic type `Box<Int>` (M5 5.2.3): the field is stored
            // boxed; its declared `T` substitutes to the concrete argument for the result type.
            if case .generic(let gbase, let gargs) = b.type {
                let type = GenericInference.genericMemberType(&s, gbase, gargs, field, at: span)
                return NOIRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))
            }
            let type = fieldType(&s, of: b.type, field: field, at: span)
            return NOIRExpr(type: type, span: span, kind: .fieldAccess(base: b, field: field))

        case .implicitMember(let name, let span):
            return EnumConstruction.buildImplicitEnum(&s, name, [], expected: expected, at: span)

        case .binary(let op, let l, let r, let span):
            // A value op (arithmetic / bitwise / shift) produces its operand type, so an expected
            // type flows into both operands — `let b: UInt8 = 5 + 3` or `1 << 4` types its literals
            // as UInt8. A comparison yields Bool, so its context does not describe the operands.
            let operandExpected: Type? = TypeChecks.isComparisonOp(op) ? nil : expected
            var lhs = checkExpr(&s, l, expected: operandExpected)
            var rhs = checkExpr(&s, r, expected: operandExpected)
            // A bare integer literal on one side of a UInt8 operation adopts the UInt8 type, so
            // `b + 1`, `b << 2`, `b & 240` need no conversion (arithmetic still never converts a
            // non-literal Int to UInt8).
            (lhs, rhs) = TypeChecks.adoptUInt8Literal(op, lhs, rhs)
            let type = TypeChecks.binaryResult(s, op, lhs, rhs, at: span)
            return NOIRExpr(type: type, span: span, kind: .binary(op, lhs, rhs))

        case .unary(let op, let operand, let span):
            // `-x` / `~x` produce the operand's type, so an expected type flows in (`let m: UInt8 =
            // ~0`); `!x` operates on Bool, so its context does not describe the operand.
            return TypeChecks.checkUnary(&s, op, operand, at: span, expected: op == .not ? nil : expected)

        case .call(let callee, let args, let span):
            return checkCall(&s, callee: callee, args: args, span: span, expected: expected)

        case .closure(let params, let ret, let body, let span):
            let ps = params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type), span: $0.span) }
            let retTy = s.resolve(ret)
            s.pushScope()
            for p in ps { s.declare(p.name, p.type) }
            let saved = s.currentReturnType; s.currentReturnType = retTy
            let savedLoop = s.loopDepth; s.loopDepth = 0   // `break`/`continue` can't cross into a closure
            let irBody = lowerBlock(&s, body)
            s.loopDepth = savedLoop
            s.currentReturnType = saved
            s.popScope()
            let type = Type.function(params: ps.map(\.type), ret: retTy)
            return NOIRExpr(type: type, span: span, kind: .closure(params: ps, body: irBody))

        case .arrayLit(let elems, let span):
            // Element type: unify the elements' types, or take it from an `Array<T>` annotation on
            // the left (needed for an empty literal, which has nothing to infer from).
            var expectedElem: Type? = nil
            if case .array(let e)? = expected { expectedElem = e }
            let irElems = elems.map { checkExpr(&s, $0, expected: expectedElem) }
            var elemTy = expectedElem ?? irElems.first?.type
            if elemTy == nil {
                s.diags.error("cannot infer the element type of an empty array literal — add an annotation like 'Array<Int>'", at: span)
                elemTy = .error
            }
            // Every element must match the element type.
            for ir in irElems where ir.type != .error && ir.type != elemTy! {
                s.diags.error("array element has type '\(ir.type)', expected '\(elemTy!)'", at: ir.span)
            }
            return NOIRExpr(type: .array(elemTy!), span: span, kind: .arrayLit(elements: irElems))

        case .index(let base, let idx, let span):
            let irBase = checkExpr(&s, base)
            let irIdx = checkExpr(&s, idx, expected: .int)
            if irIdx.type != .int && irIdx.type != .error {
                s.diags.error("array index must be an 'Int', got '\(irIdx.type)'", at: irIdx.span)
            }
            guard case .array(let elem) = irBase.type else {
                if irBase.type != .error {
                    s.diags.error("cannot subscript a value of type '\(irBase.type)' — only 'Array<T>' supports '[ ]'", at: span)
                }
                return NOIRExpr(type: .error, span: span, kind: .index(base: irBase, idx: irIdx))
            }
            return NOIRExpr(type: elem, span: span, kind: .index(base: irBase, idx: irIdx))

        case .error(let span):
            // A parser error-recovery placeholder. The driver stops before Sema when the
            // parse sink holds errors, so this is unreachable in the normal flow; type it
            // `.error` (which suppresses further diagnostics) and emit no new diagnostic.
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
    }

    // A method-requirement / interface-default call: check the args, resolve the requirement's
    // parameter and return types with `Self` bound to `selfAs`, and emit the witness `.methodCall`.
    // The dispatch paths (existential / opaque / bounded type-param / interface-default /
    // inherited-default) differ only in how they find `req` and what `Self` binds to.
    static func requirementCall(_ s: inout Sema, receiver recv: NOIRExpr, _ req: InterfaceMethod,
                                method name: String, selfAs: Type, _ args: [Arg], at span: Span) -> NOIRExpr {
        let irArgs = args.map { checkExpr(&s, $0.value) }
        checkArgTypes(s, irArgs, against: req.params.map { s.resolve($0.type, selfAs: selfAs) }, at: span)
        return NOIRExpr(type: s.resolve(req.returnType, selfAs: selfAs), span: span,
                      kind: .methodCall(receiver: recv, method: name, args: irArgs))
    }

    static func checkCall(_ s: inout Sema, callee: Expr, args: [Arg], span: Span, expected: Type? = nil) -> NOIRExpr {
        // Qualified enum construction: `EnumType.case(args)` or `EnumType<Args>.case(args)`. A
        // `static fun` of the same enum takes precedence over case construction for that name.
        if case .member(let base, let caseName, _) = callee,
           let (typeName, explicit) = s.typeNameAndArgs(base), s.lookup(typeName) == nil, s.enums[typeName] != nil,
           s.staticMethodDecl(typeName, .enum_, caseName) == nil {
            return EnumConstruction.buildEnumInit(&s, typeName, caseName, args, explicit: explicit, expected: expected, at: span)
        }
        // Pointer static constructors (task 125): `RawPtr.alloc(...)`, `Ptr<T>.alloc(...)`.
        if case .member(let base, let method, _) = callee,
           let (tn, explicit) = s.typeNameAndArgs(base), s.lookup(tn) == nil {
            if tn == "RawPtr" { return PointerIntrinsics.checkRawPtrStatic(&s, method, args, span) }
            if tn == "Ptr" {
                guard let elems = explicit, elems.count == 1 else {
                    s.diags.error("'Ptr' needs one type argument, e.g. 'Ptr<Int>.\(method)(...)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                return PointerIntrinsics.checkPtrStatic(&s, elems[0], method, args, span)
            }
        }
        // Static interface-requirement call on a bounded type parameter: `T.zero()` where `T: I` and
        // `I` declares a `static fun zero` requirement. `Self` in the requirement binds to `T`; the
        // `.staticCall` is resolved by monomorphization to the concrete conformer's static method.
        if case .member(let base, let name, _) = callee, case .ident(let tp, _) = base,
           s.genericScope.contains(tp),
           let iface = (s.genericBounds[tp] ?? []).first(where: { s.aggregatedMethods($0).contains { $0.name == name && $0.isStatic } }),
           let req = s.aggregatedMethods(iface).first(where: { $0.name == name && $0.isStatic }) {
            let selfT = Type.typeParam(tp)
            let irArgs = args.map { checkExpr(&s, $0.value) }
            checkArgTypes(s, irArgs, against: req.params.map { s.resolve($0.type, selfAs: selfT) }, at: span)
            let ret = s.resolve(req.returnType, selfAs: selfT)
            return NOIRExpr(type: ret, span: span, kind: .staticCall(onType: selfT, method: name, args: irArgs))
        }
        // Static method: `Type.method(args)` — a type-associated function with no receiver. Only
        // for a non-generic user type (generic types reject members entirely, so no static free
        // function is ever emitted for them); the call lowers to a direct call of `Type.method`.
        if case .member(let base, let name, _) = callee,
           let (tn, explicit) = s.typeNameAndArgs(base), s.lookup(tn) == nil,
           let k = s.kindOf(tn), let m = s.staticMethodDecl(tn, k, name) {
            // A generic type's static method: `Box<Int>.make(...)`. The signature substitutes the
            // explicit type args, and they ride on the call so monomorphization specializes the
            // static free function per instantiation (task 151). Inference of the args from the
            // value arguments is not done yet — the args are required explicitly.
            if let arity = s.genericArity(tn) {
                guard let targs = explicit, targs.count == arity else {
                    s.diags.error("static method '\(tn).\(name)' on a generic type needs explicit type arguments, e.g. '\(tn)<…>.\(name)(…)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                let (paramTypes, ret) = GenericInference.genericMethodSig(&s, tn, targs, m)
                let irArgs = checkArgs(&s, args, expectedParams: paramTypes)
                checkArgTypes(s, irArgs.map(\.value), against: paramTypes, at: span)
                let calleeType = Type.function(params: paramTypes, ret: ret)
                return NOIRExpr(type: ret, span: span,
                              kind: .call(callee: irVar("\(tn).\(name)", calleeType, span), args: irArgs, typeArgs: targs))
            }
            let paramTypes = m.params.map { s.resolve($0.type) }
            let irArgs = checkArgs(&s, args, expectedParams: paramTypes)
            checkArgTypes(s, irArgs.map(\.value), against: paramTypes, at: span)
            let ret = s.resolve(m.returnType)
            let calleeType = Type.function(params: paramTypes, ret: ret)
            return NOIRExpr(type: ret, span: span,
                          kind: .call(callee: irVar("\(tn).\(name)", calleeType, span), args: irArgs, typeArgs: []))
        }
        // `Type.member(...)` on a user type that is not a static method: a targeted diagnostic
        // instead of falling through to "undefined name 'Type'" (the type name is not a value).
        if case .member(let base, let name, _) = callee,
           let (tn, _) = s.typeNameAndArgs(base), s.lookup(tn) == nil, s.genericArity(tn) == nil,
           let k = s.kindOf(tn), k != .enum_ {
            if s.methodDecl(tn, k, name) != nil {
                s.diags.error("'\(name)' is an instance method of '\(tn)'; call it on a value, not on the type", at: span)
            } else {
                s.diags.error("type '\(tn)' has no static method '\(name)'", at: span)
            }
            return NOIRExpr(type: .error, span: span, kind: .intLit(0))
        }
        // Leading-dot enum construction: `.case(args)` — enum inferred from context.
        if case .implicitMember(let caseName, _) = callee {
            return EnumConstruction.buildImplicitEnum(&s, caseName, args, expected: expected, at: span)
        }
        // Member call: base.member(args) — an actor send or an instance method.
        if case .member(let base, let name, _) = callee {
            let recv = checkExpr(&s, base)
            // Array<T> builtin methods (M6 stdlib). `append(x)` grows the array; lowered to a builtin
            // call codegen recognizes (element type from the receiver's `.array` type).
            if case .array(let elem) = recv.type {
                switch name {
                case "append":
                    guard args.count == 1 else {
                        s.diags.error("Array.append expects 1 argument, got \(args.count)", at: span)
                        return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                    }
                    let ce = checkExpr(&s, args[0].value, expected: elem)
                    let value = coerce(&s, ce, to: elem)
                    checkAssignable(&s, value.type, to: elem, role: "argument", at: span)
                    let ac = NOIRExpr(type: .void, span: span, kind: .varRef("__arrayAppend"))
                    return NOIRExpr(type: .void, span: span, kind: .call(callee: ac,
                        args: [NOIRArg(label: nil, value: recv), NOIRArg(label: nil, value: value)], typeArgs: []))
                default:
                    s.diags.error("value of type '\(recv.type)' has no method '\(name)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
            }
            // RawPtr instance methods (task 125): free / advanced / store / load / asPtr.
            if case .rawPtr = recv.type {
                return PointerIntrinsics.checkRawPtrMethod(&s, recv, name, args, span, expected: expected)
            }
            // Ptr<T> instance methods (task 125): load / store / advanced / asRaw. T is fixed by the
            // receiver, so load/store need no annotation (unlike RawPtr).
            if case .ptr(let elem) = recv.type {
                return PointerIntrinsics.checkPtrMethod(&s, recv, elem, name, args, span)
            }
            // String method builtins. `eq(other)` is byte equality (there is no `==` on String yet).
            if recv.type == .string {
                switch name {
                case "eq":
                    guard args.count == 1 else {
                        s.diags.error("String.eq expects 1 argument, got \(args.count)", at: span)
                        return NOIRExpr(type: .error, span: span, kind: .boolLit(false))
                    }
                    let rhs = checkExpr(&s, args[0].value)
                    if rhs.type != .string && rhs.type != .error {
                        s.diags.error("String.eq expects a String argument, got '\(rhs.type)'", at: rhs.span)
                    }
                    return BuiltinsSema.method("__string_eq_bool_string", recv, [rhs], span)
                default:
                    s.diags.error("value of type 'String' has no method '\(name)'", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .boolLit(false))
                }
            }
            // A method-requirement call through `any I` / `any A & B` — dispatched via the
            // witness slot (including requirements inherited by refinement, M5 A1.5).
            if let iface = s.existentialInterfaces(recv.type).first(where: { s.aggregatedMethods($0).contains { $0.name == name } }),
               let req = s.aggregatedMethods(iface).first(where: { $0.name == name }) {
                // Covariant `Self` erases to the receiver's own existential type: `c.clone()` on
                // `any B` yields `any B` (M5 5.6). Params are `Self`-free here (a contravariant
                // `Self` would have made the interface non-existential-legal).
                return requirementCall(&s, receiver: recv, req, method: name, selfAs: recv.type, args, at: span)
            }
            // A method-requirement call through `some I` — statically dispatched to the hidden
            // underlying (M5 A3). `Self` binds to the underlying concrete type (chosen: the
            // caller gets the concrete type back), falling back to the opaque type itself if the
            // underlying isn't resolved yet (a forward reference to a later-declared producer).
            if case .opaque(let ifaces, let owner) = recv.type,
               let iface = ifaces.first(where: { s.aggregatedMethods($0).contains { $0.name == name } }),
               let req = s.aggregatedMethods(iface).first(where: { $0.name == name }) {
                let selfBind = s.opaqueUnderlyings[owner] ?? recv.type
                return requirementCall(&s, receiver: recv, req, method: name, selfAs: selfBind, args, at: span)
            }
            // A requirement call through a bounded type parameter `T: I` — dispatched via the
            // witness passed for that bound (M5 5.2.2). `Self` binds to `T`.
            if case .typeParam(let t) = recv.type,
               let iface = (s.genericBounds[t] ?? []).first(where: { s.aggregatedMethods($0).contains { $0.name == name } }),
               let req = s.aggregatedMethods(iface).first(where: { $0.name == name }) {
                return requirementCall(&s, receiver: recv, req, method: name, selfAs: recv.type, args, at: span)
            }
            // Instance method on an applied generic type `Box<Int>` (task 151): resolve the method on
            // the template and substitute the instantiation's type args into its signature. The
            // `.methodCall` rides through, and monomorphization specializes the body per instantiation.
            if case .generic(let gbase, let gargs) = recv.type,
               let gkind = s.kindOf(gbase),
               let method = s.methodDecl(gbase, gkind, name) {
                let (paramTypes, ret) = GenericInference.genericMethodSig(&s, gbase, gargs, method)
                let irArgs = args.map { checkExpr(&s, $0.value) }
                checkArgTypes(s, irArgs, against: paramTypes, at: span)
                if gkind != .class_ {
                    s.methodCallSites.append(Sema.CallSite(callee: "\(gbase).\(name)",
                                                    receiverMutable: isMutableReceiver(s, base), span: span))
                }
                return NOIRExpr(type: ret, span: span, kind: .methodCall(receiver: recv, method: name, args: irArgs))
            }
            if case .named(let typeName, let kind) = recv.type {
                // Actor send: base.handler(args).
                if kind == .actor_, let handler = s.actors[typeName]?.handlers.first(where: { $0.name == name }) {
                    let irArgs = args.map { checkExpr(&s, $0.value) }
                    checkArgTypes(s, irArgs, against: handler.params.map { s.resolve($0.type) }, at: span)
                    return NOIRExpr(type: s.resolve(handler.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // Requirement call inside an interface default (self: interface). `Self` in the
                // requirement binds to the receiver's type (M5 A2).
                if kind == .interface_, let req = s.interfaceMethod(typeName, name) {
                    return requirementCall(&s, receiver: recv, req, method: name, selfAs: recv.type, args, at: span)
                }
                // Instance method on a struct/enum/class value.
                if let method = s.methodDecl(typeName, kind, name) {
                    let irArgs = args.map { checkExpr(&s, $0.value) }
                    checkArgTypes(s, irArgs, against: method.params.map { s.resolve($0.type) }, at: span)
                    // Value types (struct/enum) get the mutating-receiver check; classes are
                    // reference types, so a mutating method is callable on any binding.
                    if kind != .class_ {
                        s.methodCallSites.append(Sema.CallSite(callee: "\(typeName).\(name)",
                                                        receiverMutable: isMutableReceiver(s, base), span: span))
                    }
                    return NOIRExpr(type: s.resolve(method.returnType), span: span,
                                  kind: .methodCall(receiver: recv, method: name, args: irArgs))
                }
                // A default requirement this type inherits (synthesized as a concrete method).
                // `Self` in the requirement binds to the concrete receiver type (M5 A2).
                if let req = (s.inheritedDefaults[typeName] ?? []).first(where: { $0.name == name }) {
                    return requirementCall(&s, receiver: recv, req, method: name, selfAs: recv.type, args, at: span)
                }
            }
            if recv.type != .error {
                s.diags.error("value of type '\(recv.type)' has no method '\(name)'", at: span)
            }
            return NOIRExpr(type: .error, span: span, kind: .methodCall(receiver: recv, method: name,
                                                                       args: args.map { checkExpr(&s, $0.value) }))
        }

        if case .ident(let name, _) = callee {
            // print — accepts zero or one arg of any printable type.
            if name == "print" {
                let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr(&s, $0.value)) }
                return NOIRExpr(type: .void, span: span, kind: .call(callee: irVar(name, .void, span), args: irArgs, typeArgs: []))
            }

            // putByte(b: UInt8) — write one raw byte to stdout (libc-buffered, flushed at exit).
            // The low-level output primitive a string type builds its printing on.
            if name == "putByte" {
                guard args.count == 1 else {
                    s.diags.error("putByte expects one argument (a UInt8)", at: span)
                    return NOIRExpr(type: .void, span: span, kind: .intLit(0))
                }
                let a = checkExpr(&s, args[0].value, expected: .uint8)
                if a.type != .uint8, a.type != .error {
                    s.diags.error("putByte expects a UInt8, got '\(a.type)'", at: a.span)
                }
                return NOIRExpr(type: .void, span: span, kind: .call(callee: irVar(name, .void, span), args: [NOIRArg(label: nil, value: a)], typeArgs: []))
            }

            if name == "time_monotonic" {
                return NOIRExpr(type: .int, span: span, kind: .call(callee: irVar("__void_timemonotonic_int", .int, span), args: [], typeArgs:[]))
            }
            // addrOf(obj) — the raw address of a heap (reference-type) object as a RawPtr (task 150 rung 2).
            // A GC-internal seed for the mark-verify tracer: it hands the Nomu tracer a root to walk from.
            // Valid only on a non-moving heap (rung 2 NoGC); a moving collector would invalidate the alias.
            if name == "addrOf" {
                guard args.count == 1 else {
                    s.diags.error("addrOf expects one argument (a heap object)", at: span)
                    return NOIRExpr(type: .error, span: span, kind: .intLit(0))
                }
                let a = checkExpr(&s, args[0].value)
                if a.type != .error, !s.isReferenceType(a.type) {
                    s.diags.error("addrOf expects a heap (reference-type) object, got '\(a.type)'", at: span)
                }
                return s.ptrIntrinsic("__gcObjAddr", .rawPtr, [a], span)
            }
            // Construction of a generic type — infer the type arguments from the fields (M5 5.2.3).
            if s.genericArity(name) != nil {
                return GenericInference.checkGenericConstruct(&s, name, args, at: span)
            }
            // Construction: TypeName(...) for struct/class/actor. Thread each field's declared type
            // in as the expected type of its argument (matched by label, else by position), so a
            // literal adopts a `UInt8`/`Double` field and a real mismatch is a clean diagnostic.
            if let k = s.kindOf(name), k != .enum_ {
                let fields = s.constructorFields(name)
                let irArgs = args.enumerated().map { (i, a) -> NOIRArg in
                    let exp: Type? = fields.flatMap { fs in
                        a.label.flatMap { l in fs.first { $0.label == l }?.type } ?? (i < fs.count ? fs[i].type : nil)
                    }
                    let v = checkExpr(&s, a.value, expected: exp)
                    if let exp, v.type != exp, v.type != .error, exp != .error {
                        s.diags.error("argument of type '\(v.type)' does not match expected '\(exp)'", at: v.span)
                    }
                    return NOIRArg(label: a.label, value: v)
                }
                return NOIRExpr(type: .named(name, k), span: span, kind: .construct(typeName: name, args: irArgs))
            }
            // Named function / non-print builtin.
            if let sig = s.funcs[name] {
                if !sig.generics.isEmpty {
                    let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr(&s, $0.value)) }
                    return GenericInference.checkGenericCall(&s, name, sig, irArgs, at: span, expected: expected)
                }
                let irArgs = checkArgs(&s, args, expectedParams: sig.params)
                checkArgTypes(s, irArgs.map(\.value), against: sig.params, at: span)
                let calleeType = Type.function(params: sig.params, ret: sig.ret)
                return NOIRExpr(type: sig.ret, span: span, kind: .call(callee: irVar(name, calleeType, span), args: irArgs, typeArgs: []))
            }
        }

        // Generic construction with explicit type arguments: `Box<Int>(value: 3)`.
        if case .genericIdent(let name, let refs, _) = callee {
            let explicit = refs.map { s.resolve($0) }
            if GenericInference.genericTypeShape(&s, name) != nil {
                return GenericInference.checkGenericConstruct(&s, name, args, explicit: explicit, at: span)
            }
            if s.enums[name] != nil {
                s.diags.error("generic enum '\(name)' is constructed through a case, e.g. '\(name)<...>.case(...)'", at: span)
                return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
            }
            s.diags.error("'\(name)' is not a generic type; explicit type arguments are not allowed here", at: span)
            return NOIRExpr(type: .error, span: span, kind: .construct(typeName: name, args: []))
        }

        // Fallback: type the callee; call it if it is a function value.
        let c = checkExpr(&s, callee)
        let irArgs = args.map { NOIRArg(label: $0.label, value: checkExpr(&s, $0.value)) }
        if case .function(_, let ret) = c.type {
            return NOIRExpr(type: ret, span: span, kind: .call(callee: c, args: irArgs, typeArgs: []))
        }
        if c.type != .error {
            s.diags.error("value of type '\(c.type)' is not callable", at: span)
        }
        return NOIRExpr(type: .error, span: span, kind: .call(callee: c, args: irArgs, typeArgs: []))
    }

    // MARK: - Type checks

    // Assigning to a `let` field is rejected (M4.10 field-level immutability). Bare
    // field writes inside methods are already caught by the AST Typechecker (self is
    // read-only); this covers `value.field = …` targets on struct/class values.
    static func rejectLetFieldTarget(_ s: borrowing Sema, _ target: NOIRExpr) {
        guard case .fieldAccess(let base, let field) = target.kind else { return }
        let typeName: String
        switch base.type {
        case .named(let n, .struct_), .named(let n, .class_): typeName = n   // concrete value/reference
        case .generic(let n, _):                              typeName = n   // an applied generic type (5.2.3)
        default:                                              return
        }
        let fields = s.structs[typeName]?.fields ?? s.classes[typeName]?.fields ?? []
        if let f = fields.first(where: { $0.name == field }), !f.isMutable {
            s.diags.error("cannot assign to 'let' field '\(field)'", at: target.span)
        }
    }

    static func fieldType(_ s: inout Sema, of type: Type, field: String, at span: Span) -> Type {
        // A field on an applied generic type `Box<Int>` — substitute the arguments (M5 5.2.3).
        if case .generic(let base, let args) = type {
            return GenericInference.genericMemberType(&s, base, args, field, at: span)
        }
        guard case .named(let name, let kind) = type else {
            if type != .error { s.diags.error("value of type '\(type)' has no field '\(field)'", at: span) }
            return .error
        }
        let fields: [VarField]
        switch kind {
        case .struct_: fields = s.structs[name]?.fields ?? []
        case .class_:  fields = s.classes[name]?.fields ?? []
        case .actor_:  fields = s.actors[name]?.fields.map { VarField(name: $0.name, type: $0.type, isMutable: true, span: $0.span) } ?? []
        case .enum_, .interface_:   fields = []
        }
        if let f = fields.first(where: { $0.name == field }) { return s.resolve(f.type) }
        s.diags.error("type '\(name)' has no field '\(field)'", at: span)
        return .error
    }

    static func checkArgTypes(_ s: borrowing Sema, _ args: [NOIRExpr], against params: [Type], at span: Span) {
        if args.count != params.count {
            s.diags.error("expected \(params.count) argument(s), got \(args.count)", at: span)
            return
        }
        for (a, p) in zip(args, params) where a.type != p && a.type != .error && p != .error {
            s.diags.error("argument of type '\(a.type)' does not match expected '\(p)'", at: a.span)
        }
    }

    // Check call args, threading a per-position expected type inward (for leading-dot
    // enum inference); `expectedParams` is nil where the slots aren't known.
    static func checkArgs(_ s: inout Sema, _ args: [Arg], expectedParams: [Type]?) -> [NOIRArg] {
        var out: [NOIRArg] = []
        for (i, a) in args.enumerated() {
            let exp = expectedParams.flatMap { i < $0.count ? $0[i] : nil }
            let ce = checkExpr(&s, a.value, expected: exp)
            out.append(NOIRArg(label: a.label, value: coerce(&s, ce, to: exp)))
        }
        return out
    }

    static func irVar(_ name: String, _ type: Type, _ span: Span) -> NOIRExpr {
        NOIRExpr(type: type, span: span, kind: .varRef(name))
    }

    // A mutable receiver for a mutating method call (M4.11, conservative first cut):
    // a `var` local, or `self` (mutation through self makes the enclosing method
    // mutating by inference, which keeps the check sound). Anything else — a `let`
    // local, a parameter, a field access, a temporary — is immutable.
    static func isMutableReceiver(_ s: borrowing Sema, _ base: Expr) -> Bool {
        if case .ident(let name, _) = base {
            return name == "self" || s.lookupMutable(name)
        }
        return false
    }

    // MARK: - Declarations

    static func lowerDecl(_ s: inout Sema, _ decl: TopDecl) -> NOIRDecl {
        switch decl {
        case .structDecl(let sd):
            let fields = sd.fields.map { lowerField(s, $0) }
            var methods = lowerMethods(&s, sd.methods, selfType: .named(sd.name, .struct_), fields: fields)
            methods += lowerAccessors(&s, sd.properties, selfType: .named(sd.name, .struct_), fields: fields)
            methods += InterfaceModel.lowerInheritedDefaults(&s, sd.name, selfType: .named(sd.name, .struct_), fields: fields)
            lowerStaticMethods(&s, sd.methods, typeName: sd.name)
            return .structDecl(NOIRStruct(name: sd.name, fields: fields, methods: methods, span: sd.span))
        case .enumDecl(let e):
            let cases = e.cases.map { NOIREnumCase(name: $0.name, fields: $0.fields.map { lowerField(s, $0) }, span: $0.span) }
            var methods = lowerMethods(&s, e.methods, selfType: .named(e.name, .enum_), fields: [])
            methods += lowerAccessors(&s, e.properties, selfType: .named(e.name, .enum_), fields: [])
            methods += InterfaceModel.lowerInheritedDefaults(&s, e.name, selfType: .named(e.name, .enum_), fields: [])
            lowerStaticMethods(&s, e.methods, typeName: e.name)
            return .enumDecl(NOIREnum(name: e.name, cases: cases, methods: methods, span: e.span))
        case .classDecl(let c):
            let fields = c.fields.map { lowerField(s, $0) }
            var methods = lowerMethods(&s, c.methods, selfType: .named(c.name, .class_), fields: fields)
            methods += lowerAccessors(&s, c.properties, selfType: .named(c.name, .class_), fields: fields)
            methods += InterfaceModel.lowerInheritedDefaults(&s, c.name, selfType: .named(c.name, .class_), fields: fields)
            lowerStaticMethods(&s, c.methods, typeName: c.name)
            return .classDecl(NOIRClass(name: c.name, fields: fields, methods: methods, span: c.span))
        case .actorDecl(let a):
            return .actorDecl(lowerActor(&s, a))
        case .funcDecl(let f):
            return .funcDecl(lowerFunc(&s, f))
        case .interfaceDecl:
            preconditionFailure("interfaces are validated in check(), not lowered (M5 A1)")
        case .extensionDecl:
            preconditionFailure("extensions must be merged before Sema (M4.12)")
        }
    }

    // MARK: - Generic decls (M5 5.2.1)

    // A generic bound must name an interface. A `Self`-mentioning (constraint-only) bound is now
    // allowed: monomorphization (M5 5.4) specializes `<T: I>` to a concrete `T` where `-> Self` is
    // a direct call — no Self-witness needed — so the 5.2.2 deferral is lifted (M5 5.6).
    static func validateBounds(_ s: borrowing Sema, _ generics: [GenericParam]) {
        for g in generics {
            for b in g.bounds where s.interfaces[b.name] == nil {
                s.diags.error("'\(b.name)' is not an interface — a generic bound must name an interface", at: b.span)
            }
        }
    }

    // Lower a generic type to one uniform IR shape (M5 5.2.3): its type parameters are in
    // scope while resolving fields (so a `T` field becomes `.typeParam("T")`), the bounds are
    // recorded, and the generic params ride onto the IR decl for codegen. Instance methods /
    // computed properties on a generic type are deferred — rejected with a clear message.
    static func lowerGenericDecl(_ s: inout Sema, _ decl: TopDecl) -> NOIRDecl {
        let generics: [GenericParam]
        switch decl {
        case .structDecl(let sd): generics = sd.generics
        case .enumDecl(let e):   generics = e.generics
        case .classDecl(let c):  generics = c.generics
        default: preconditionFailure("lowerGenericDecl on a non-generic-capable decl")
        }
        let savedScope = s.genericScope; let savedBounds = s.genericBounds
        s.genericScope = Set(generics.map(\.name))
        for g in generics { s.genericBounds[g.name] = g.bounds.map(\.name) }
        defer { s.genericScope = savedScope; s.genericBounds = savedBounds }
        validateBounds(s, generics)
        let irGenerics = generics.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(\.name), isShared: $0.isShared) }
        switch decl {
        case .structDecl(let sd):
            // Instance methods on a generic struct (task 151, slice 1). `self` is the applied generic
            // type `S<T…>`; fields and signatures resolve with the type's params in scope (set above),
            // so a `T` becomes `.typeParam`. Monomorphization specializes each method per instantiation.
            let selfT = Type.generic(base: sd.name, args: generics.map { .typeParam($0.name) })
            let fields = sd.fields.map { lowerField(s, $0) }
            let methods = lowerMethods(&s, sd.methods, selfType: selfT, fields: fields)
                        + lowerAccessors(&s, sd.properties, selfType: selfT, fields: fields)
            lowerStaticMethods(&s, sd.methods, typeName: sd.name, generics: irGenerics)
            return .structDecl(NOIRStruct(name: sd.name, generics: irGenerics,
                                        fields: fields, methods: methods, span: sd.span))
        case .classDecl(let c):
            let selfT = Type.generic(base: c.name, args: generics.map { .typeParam($0.name) })
            let fields = c.fields.map { lowerField(s, $0) }
            let methods = lowerMethods(&s, c.methods, selfType: selfT, fields: fields)
                        + lowerAccessors(&s, c.properties, selfType: selfT, fields: fields)
            lowerStaticMethods(&s, c.methods, typeName: c.name, generics: irGenerics)
            return .classDecl(NOIRClass(name: c.name, generics: irGenerics,
                                      fields: fields, methods: methods, span: c.span))
        case .enumDecl(let e):
            let selfT = Type.generic(base: e.name, args: generics.map { .typeParam($0.name) })
            let cases = e.cases.map { NOIREnumCase(name: $0.name, fields: $0.fields.map { lowerField(s, $0) }, span: $0.span) }
            let methods = lowerMethods(&s, e.methods, selfType: selfT, fields: [])
                        + lowerAccessors(&s, e.properties, selfType: selfT, fields: [])
            lowerStaticMethods(&s, e.methods, typeName: e.name, generics: irGenerics)
            return .enumDecl(NOIREnum(name: e.name, generics: irGenerics, cases: cases, methods: methods, span: e.span))
        default: preconditionFailure("unreachable")
        }
    }

    static func rejectGenericMembers(_ s: inout Sema, _ methods: [FuncDecl], _ properties: [ComputedProperty], at span: Span) {
        if !methods.isEmpty || !properties.isEmpty {
            s.diags.error("methods and computed properties on a generic type aren't supported yet (M5 5.2.3)", at: span)
        }
    }

    // MARK: - Members

    static func lowerField(_ s: borrowing Sema, _ f: VarField) -> NOIRField {
        NOIRField(name: f.name, type: s.resolve(f.type), isMutable: f.isMutable, span: f.span)
    }

    // Lower each `fun` member with `self` (immutable) and the receiver's fields
    // declared by bare name, mirroring how actor handlers see their fields (T3).
    // Lower a body in its own scope: `self` (when present), the type's fields, and the params are
    // declared, and `currentReturnType` is set for the duration. The shared skeleton behind method,
    // static-method, accessor, free-function, and actor-handler lowering.
    static func withMethodScope(_ s: inout Sema, selfType: Type?, fields: [NOIRField],
                                params: [NOIRParam], returnType: Type, _ block: Block) -> [NOIRStmt] {
        s.pushScope()
        if let selfType { s.declare("self", selfType) }
        for f in fields { s.declare(f.name, f.type) }
        for p in params { s.declare(p.name, p.type) }
        let saved = s.currentReturnType; s.currentReturnType = returnType
        let body = lowerBlock(&s, block)
        s.currentReturnType = saved
        s.popScope()
        return body
    }

    static func lowerMethods(_ s: inout Sema, _ methods: [FuncDecl], selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        let ownerType: String? = {
            switch selfType {
            case .named(let n, _), .generic(let n, _): return n
            default:                                   return nil
            }
        }()
        for m in methods where !m.isStatic {
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type), span: $0.span) }
            // A `some I` method return keys its opaque identity by "m:Type.method" — the same
            // key the call site uses when it resolves the method's return type (M5 A3).
            let ret = s.resolve(m.returnType, opaqueOwner: ownerType.map { "m:\($0).\(m.name)" })
            let body = withMethodScope(&s, selfType: selfType, fields: fields, params: params, returnType: ret, m.body)
            out.append(NOIRFunc(name: m.name, params: params, returnType: ret, body: body, isMutating: false, span: m.span))
        }
        return out
    }

    // Lower each `static fun` member as a free function named `Type.method` — no `self` and no
    // fields in scope, so a body that references `self` or a bare field name is an undefined-name
    // error. The qualified name is unspellable by users, so it never collides with a real free
    // function; the call site `Type.method(...)` targets it as an ordinary direct call.
    static func lowerStaticMethods(_ s: inout Sema, _ methods: [FuncDecl], typeName: String,
                                   generics: [NOIRGenericParam] = []) {
        for m in methods where m.isStatic {
            let params = m.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type), span: $0.span) }
            let ret = s.resolve(m.returnType)
            let body = withMethodScope(&s, selfType: nil, fields: [], params: params, returnType: ret, m.body)
            // On a generic type the free function carries the type's parameters, so monomorphization
            // treats it as a generic template and specializes it per instantiation (task 151).
            s.pendingStaticFuncs.append(.funcDecl(NOIRFunc(name: "\(typeName).\(m.name)", generics: generics,
                                                         params: params, returnType: ret, body: body,
                                                         isMutating: false, span: m.span)))
        }
    }

    static func registerProps(_ s: inout Sema, _ typeName: String, _ props: [ComputedProperty], generics: [GenericParam] = []) {
        let saved = s.genericScope; s.genericScope = Set(generics.map(\.name)); defer { s.genericScope = saved }
        var table: [String: Sema.PropInfo] = [:]
        for p in props { table[p.name] = Sema.PropInfo(type: s.resolve(p.type), hasSetter: p.setter != nil) }
        s.computedProps[typeName] = table
    }

    // A computed property lowers to accessor methods on its type: a getter `prop.get`
    // (() -> T) and, if settable, a setter `prop.set` ((T) -> Void). The `.` keeps
    // their names out of any user method's namespace (Mangle 9-encodes it), and being
    // ordinary methods they reuse method codegen, self-passing, and mutation inference
    // (the setter is inferred mutating because it writes a field).
    static func lowerAccessors(_ s: inout Sema, _ props: [ComputedProperty], selfType: Type, fields: [NOIRField]) -> [NOIRFunc] {
        var out: [NOIRFunc] = []
        for p in props {
            let propType = s.resolve(p.type)
            let getBody = accessorBody(&s, p.getter, returnType: propType, selfType: selfType,
                                       fields: fields, params: [], span: p.span)
            out.append(NOIRFunc(name: "\(p.name).get", params: [], returnType: propType,
                              body: getBody, isMutating: false, span: p.span))
            if let setter = p.setter {
                let param = NOIRParam(label: setter.paramName, name: setter.paramName, type: propType, span: p.span)
                let setBody = accessorBody(&s, setter.body, returnType: .void, selfType: selfType,
                                           fields: fields, params: [param], span: p.span)
                out.append(NOIRFunc(name: "\(p.name).set", params: [param], returnType: .void,
                                  body: setBody, isMutating: false, span: p.span))
            }
        }
        return out
    }

    // Lowers an accessor body with `self`, the type's fields, and any accessor param in
    // scope (mirroring `lowerMethods`). A single-expression getter body is an implicit
    // `return` of that expression (the bare-body shorthand, and the common `get` form).
    static func accessorBody(_ s: inout Sema, _ block: Block, returnType: Type, selfType: Type,
                             fields: [NOIRField], params: [NOIRParam], span: Span) -> [NOIRStmt] {
        var block = block
        if returnType != .void, block.count == 1, case .expr(let e) = block[0] {
            block = [.ret(e, span: span)]
        }
        return withMethodScope(&s, selfType: selfType, fields: fields, params: params, returnType: returnType, block)
    }

    static func lowerFunc(_ s: inout Sema, _ f: FuncDecl) -> NOIRFunc {
        // A generic function's type parameters + bounds are in scope while lowering its body,
        // so `x: T` typechecks and `x.req()` dispatches through the bound's witness (M5 5.2.2).
        let savedScope = s.genericScope, savedBounds = s.genericBounds, savedShared = s.sharedParams
        s.genericScope = Set(f.generics.map(\.name))
        s.genericBounds = Dictionary(f.generics.map { ($0.name, $0.bounds.map(\.name)) }, uniquingKeysWith: { a, _ in a })
        s.sharedParams = Set(f.generics.filter(\.isShared).map(\.name))
        defer { s.genericScope = savedScope; s.genericBounds = savedBounds; s.sharedParams = savedShared }
        validateBounds(s, f.generics)
        let params = f.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type), span: $0.span) }
        let ret = s.resolve(f.returnType, opaqueOwner: "fn:\(f.name)")
        let body = withMethodScope(&s, selfType: nil, fields: [], params: params, returnType: ret, f.body)
        let irGenerics = f.generics.map { NOIRGenericParam(name: $0.name, bounds: $0.bounds.map(\.name), isShared: $0.isShared) }
        return NOIRFunc(name: f.name, generics: irGenerics, params: params, returnType: ret, body: body, isMutating: false, span: f.span)
    }

    static func lowerActor(_ s: inout Sema, _ a: ActorDecl) -> NOIRActor {
        let fields = a.fields.map { af in
            NOIRActorField(name: af.name, type: s.resolve(af.type),
                         initializer: af.initializer.map { checkExpr(&s, $0) }, span: af.span)
        }
        var handlers: [NOIRHandler] = []
        for h in a.handlers {
            let params = h.params.map { NOIRParam(label: $0.label, name: $0.name, type: s.resolve($0.type), span: $0.span) }
            let ret = s.resolve(h.returnType)
            // Actors are fire-and-forget message-send only (§9): a handler is a one-way message
            // sink and cannot return a value to the sender. There is no reply/ask mechanism; a value
            // from concurrent work comes from a `spawn let` result or a channel, not an actor.
            if ret != .void {
                s.diags.error("an actor 'on' handler cannot return a value — actor messages are fire-and-forget (a handler is a one-way message sink). To get a value from concurrent work, use a spawned task's result or a channel, not an actor", at: h.span)
            }
            s.pushScope()
            for f in fields { s.declare(f.name, f.type) }   // handler body sees actor fields by name
            for p in params { s.declare(p.name, p.type) }
            let saved = s.currentReturnType; s.currentReturnType = ret
            let body = lowerBlock(&s, h.body)
            s.currentReturnType = saved
            s.popScope()
            handlers.append(NOIRHandler(name: h.name, params: params, returnType: ret, body: body, span: h.span))
        }
        return NOIRActor(name: a.name, fields: fields, handlers: handlers, span: a.span)
    }
}
