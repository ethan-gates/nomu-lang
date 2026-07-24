import Foundation
import frontend

// T2 codegen: emits C from the typed mid-level IR (design: compiler.md §1).
//
// Built alongside the AST-walking `Codegen` so the two can be diffed before the
// driver switches over (§1). This slice (1) covers `cType(Type)` and declaration
// emit — struct/enum/class/actor shells and function/handler signatures. The
// statement/expression walk lands in slice 2, so bodies are placeholders here and
// the runtime floor (`NomuRuntime.preamble`/`NomuRuntime.cMain`) is shared verbatim.
public struct CodegenIR {
    private let module: IRModule
    private var out = ""

    // Name → declaration. Kept for the member-access `.`/`->` choice and, later,
    // share analysis; the IR has already resolved types onto every node.
    private var structs: [String: IRStruct] = [:]
    private var enums:   [String: IREnum]   = [:]
    private var classes: [String: IRClass]  = [:]
    private var actors:  [String: IRActor]  = [:]
    private var funcs:   [String: IRFunc]   = [:]

    // Hoisted closure/spawn env-struct + impl-function definitions, spliced in at
    // the marker; monotonic counters give each a unique name.
    private var closureDefs = ""
    private var closureSeq  = 0
    private var spawnSeq    = 0

    // Closure bindings whose captured environment is entirely shareable — consulted
    // by the spawn-capture check (a closure is shareable iff its captures are).
    private var shareableClosureBindings: Set<String> = []

    public var diagnostics: [String] = []

    // A local (param / let / spawn handle / switch binding) visible in the body.
    // Types come off the IR now; this stack only tracks what is in scope so that
    // block-exit spawn-join and actor release fire on the right names.
    private struct Local {
        let name: String
        let type: Type
        let isSpawn: Bool   // spawn handle: reads join it, scope-exit joins it
    }
    private var frames: [[Local]] = []

    // Set while emitting an actor handler body (slice 4) so early returns write
    // fields back and unlock before returning.
    private struct HandlerCtx {
        let fields: [IRActorField]
    }
    private var handlerCtx: HandlerCtx? = nil

    // Set while emitting a method body. In a **mutating** method, fields are accessed
    // directly through `self` (no copy-to-locals) so nested self-calls see each other's
    // writes; `methodFields` names those fields and `selfIsPointer` picks `->` vs `.`.
    // A read-only method snapshots fields into locals instead (so closures can capture
    // them), leaving `methodFields` empty.
    private var methodFields: Set<String> = []
    private var selfIsPointer = false

    public init(_ module: IRModule) {
        self.module = module
        for decl in module.decls {
            switch decl {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e):   enums[e.name]   = e
            case .classDecl(let c):  classes[c.name] = c
            case .actorDecl(let a):  actors[a.name]  = a
            case .funcDecl(let f):   funcs[f.name]   = f
            }
        }
    }

    public mutating func emit() -> String {
        // The runtime/core C and the `int main` entry live in their own translation
        // units (src/runtime/*, compiled beside this by the driver); generated code
        // reaches them through the shared ABI header (M4.13).
        out += "#include \"runtime.h\"\n\n"
        // Type declarations first — closure env structs may reference user types.
        for decl in module.decls {
            if case .funcDecl = decl { continue }
            emitTopDecl(decl)
        }
        // Forward-declare methods and functions so bodies and mutual calls resolve.
        for decl in module.decls { emitMethodProtos(decl) }
        for decl in module.decls {
            if case .funcDecl(let f) = decl { emitFuncProto(f) }
        }
        out += "\n"
        // Marker where hoisted closure/spawn definitions get spliced in.
        let marker = "/*__NOMU_CLOSURES__*/\n"
        out += marker
        for decl in module.decls { emitMethodBodies(decl) }
        for decl in module.decls {
            if case .funcDecl(let f) = decl { emitFunc(f) }
        }
        return out.replacingOccurrences(of: marker, with: closureDefs)
    }

    // MARK: - Top-level

    private mutating func emitTopDecl(_ decl: IRDecl) {
        switch decl {
        case .structDecl(let s): emitStruct(s)
        case .enumDecl(let e):   emitEnum(e)
        case .classDecl(let c):  emitClass(c)
        case .actorDecl(let a):  emitActor(a)
        case .funcDecl(let f):   emitFunc(f)
        }
    }

    // MARK: - Type declarations

    private mutating func emitStruct(_ s: IRStruct) {
        out += "typedef struct {\n"
        for f in s.fields { out += "    \(cType(f.type)) \(f.name);\n" }
        out += "} \(s.name);\n\n"
    }

    private mutating func emitEnum(_ e: IREnum) {
        let tags = e.cases.map { "\(e.name)_\($0.name)" }.joined(separator: ", ")
        out += "typedef enum { \(tags) } \(e.name)_tag;\n"
        out += "typedef struct {\n"
        out += "    \(e.name)_tag tag;\n"
        out += "    union {\n"
        for c in e.cases {
            if c.fields.isEmpty {
                out += "        char \(c.name)_pad;\n"
            } else {
                out += "        struct {\n"
                for f in c.fields { out += "            \(cType(f.type)) \(f.name);\n" }
                out += "        } \(c.name);\n"
            }
        }
        out += "    } payload;\n"
        out += "} \(e.name);\n\n"
    }

    private mutating func emitClass(_ c: IRClass) {
        // Reference type under bump-and-leak: heap-allocated, never freed (no GC yet).
        out += "// ===== class \(c.name) =====\n"
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in c.fields { out += "    \(cType(f.type)) \(f.name);\n" }
        out += "} \(c.name);\n\n"

        let ctorParams = c.fields.isEmpty
            ? "void"
            : c.fields.map { "\(cType($0.type)) \($0.name)" }.joined(separator: ", ")
        out += "static \(c.name)* \(c.name)_new(\(ctorParams)) {\n"
        out += "    \(c.name)* self = (\(c.name)*)rt_alloc(sizeof(\(c.name)));\n"
        for f in c.fields { out += "    self->\(f.name) = \(f.name);\n" }
        out += "    return self;\n"
        out += "}\n\n"
    }

    // MARK: - Actors

    // Mutex-protected objects: each handler becomes a blocking call that locks,
    // runs the body under the lock, writes fields back, unlocks (see slice 2/4).
    private mutating func emitActor(_ a: IRActor) {
        let name = a.name

        out += "// ===== actor \(name) =====\n"
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in a.fields { out += "    \(cType(f.type)) \(f.name);\n" }
        out += "    pthread_mutex_t mu;\n"
        out += "} \(name);\n\n"

        for h in a.handlers { emitHandlerFunc(h, actor: a) }

        // Constructor — fields with initializers don't appear as parameters.
        let ctorFields = a.fields.filter { $0.initializer == nil }
        let ctorParams = ctorFields.isEmpty
            ? "void"
            : ctorFields.map { "\(cType($0.type)) \($0.name)" }.joined(separator: ", ")
        out += "static \(name)* \(name)_new(\(ctorParams)) {\n"
        out += "    \(name)* self = (\(name)*)rt_alloc(sizeof(\(name)));\n"
        for f in a.fields {
            if let initializer = f.initializer {
                out += "    self->\(f.name) = \(emitExpr(initializer));\n"
            } else {
                out += "    self->\(f.name) = \(f.name);\n"
            }
        }
        out += "    pthread_mutex_init(&self->mu, NULL);\n"
        out += "    return self;\n"
        out += "}\n\n"

        out += "static void \(name)_deinit(\(name)* self) {\n"
        out += "    pthread_mutex_destroy(&self->mu);\n"
        out += "}\n\n"

        out += "static void \(name)_release(\(name)* self) {\n"
        out += "    if (self && --self->header.refcount == 0) {\n"
        out += "        \(name)_deinit(self);\n"
        out += "        rt_free(self);\n"
        out += "    }\n"
        out += "}\n\n"
    }

    private mutating func emitHandlerFunc(_ h: IRHandler, actor a: IRActor) {
        let retC = cType(h.returnType)
        var sig = "\(a.name)* self"
        for p in h.params { sig += ", \(cType(p.type)) \(p.name)" }
        out += "static \(retC) \(a.name)_\(h.name)(\(sig)) {\n"
        out += "    pthread_mutex_lock(&self->mu);\n"
        // Copy actor fields to locals so the body reads/writes them by name; params
        // and field locals live below the body frame (never released here).
        pushScope()
        for f in a.fields {
            out += "    \(cType(f.type)) \(f.name) = self->\(f.name);\n"
            declare(f.name, f.type)
        }
        for p in h.params { declare(p.name, p.type) }
        handlerCtx = HandlerCtx(fields: a.fields)   // early returns write back + unlock
        emitBlock(h.body, ind: "    ")
        handlerCtx = nil
        popScope()
        // Fallthrough exit (reached when there is no early return).
        out += "// fall through exit when there is no early return\n"
        for f in a.fields { out += "    self->\(f.name) = \(f.name);\n" }
        out += "    pthread_mutex_unlock(&self->mu);\n"
        out += "}\n\n"
    }

    // MARK: - Functions

    private mutating func emitFuncProto(_ f: IRFunc) {
        let cName = f.name == "main" ? "nomu_main" : f.name
        out += "\(cType(f.returnType)) \(cName)(\(paramList(f.params)));\n"
    }

    private mutating func emitFunc(_ f: IRFunc) {
        let cName = f.name == "main" ? "nomu_main" : f.name
        out += "\(cType(f.returnType)) \(cName)(\(paramList(f.params))) {\n"
        pushScope()                                   // params live below the body frame
        for p in f.params { declare(p.name, p.type) }
        emitBlock(f.body, ind: "    ")
        popScope()
        out += "}\n\n"
    }

    private func paramList(_ params: [IRParam]) -> String {
        params.isEmpty ? "void"
            : params.map { "\(cType($0.type)) \($0.name)" }.joined(separator: ", ")
    }

    // MARK: - Instance methods (T3, mutating M4.11)

    // `self` passing: a read-only value-type (struct/enum) method takes `T self` by
    // value; a **mutating** value-type method and every class method take `T* self`
    // (a pointer), so writes reach the caller's value / the shared object.
    private func selfIsPointerMethod(_ m: IRFunc, _ kind: NamedKind) -> Bool {
        m.isMutating || kind == .class_
    }

    private mutating func emitMethodProtos(_ decl: IRDecl) {
        switch decl {
        case .structDecl(let s): for m in s.methods { emitMethodProto(m, typeName: s.name, kind: .struct_) }
        case .enumDecl(let e):   for m in e.methods { emitMethodProto(m, typeName: e.name, kind: .enum_) }
        case .classDecl(let c):  for m in c.methods { emitMethodProto(m, typeName: c.name, kind: .class_) }
        case .actorDecl, .funcDecl: break
        }
    }

    private mutating func emitMethodProto(_ m: IRFunc, typeName: String, kind: NamedKind) {
        out += "static \(cType(m.returnType)) \(typeName)_\(m.name)(\(methodSig(m, typeName, kind)));\n"
    }

    private mutating func emitMethodBodies(_ decl: IRDecl) {
        switch decl {
        case .structDecl(let s): for m in s.methods { emitMethodFunc(m, typeName: s.name, kind: .struct_, fields: s.fields) }
        case .enumDecl(let e):   for m in e.methods { emitMethodFunc(m, typeName: e.name, kind: .enum_, fields: []) }
        case .classDecl(let c):  for m in c.methods { emitMethodFunc(m, typeName: c.name, kind: .class_, fields: c.fields) }
        case .actorDecl, .funcDecl: break
        }
    }

    private func methodSig(_ m: IRFunc, _ typeName: String, _ kind: NamedKind) -> String {
        let selfC = selfIsPointerMethod(m, kind) ? "\(typeName)*" : typeName
        var sig = "\(selfC) self"
        for p in m.params { sig += ", \(cType(p.type)) \(p.name)" }
        return sig
    }

    private mutating func emitMethodFunc(_ m: IRFunc, typeName: String, kind: NamedKind, fields: [IRField]) {
        let pointerSelf = selfIsPointerMethod(m, kind)
        let op = pointerSelf ? "->" : "."
        out += "static \(cType(m.returnType)) \(typeName)_\(m.name)(\(methodSig(m, typeName, kind))) {\n"
        pushScope()                                   // self / fields / params live below the body frame
        declare("self", .named(typeName, kind))
        let prevFields = methodFields, prevPointer = selfIsPointer
        selfIsPointer = pointerSelf
        if m.isMutating {
            // Direct field access through `self` — reads/writes hit the real object,
            // and a nested `self.other()` sees this method's writes (no stale copy).
            methodFields = Set(fields.map(\.name))
        } else {
            // Read-only: snapshot fields into locals so the body reads them by bare
            // name (and closures can capture them). No write-back.
            methodFields = []
            for f in fields {
                out += "    \(cType(f.type)) \(f.name) = self\(op)\(f.name);\n"
                declare(f.name, f.type)
            }
        }
        for p in m.params { declare(p.name, p.type) }
        emitBlock(m.body, ind: "    ")
        methodFields = prevFields
        selfIsPointer = prevPointer
        popScope()
        out += "}\n\n"
    }

    // MARK: - Scopes

    private mutating func pushScope() { frames.append([]) }
    private mutating func popScope()  { frames.removeLast() }

    private mutating func declare(_ name: String, _ type: Type, isSpawn: Bool = false) {
        frames[frames.count - 1].append(Local(name: name, type: type, isSpawn: isSpawn))
    }

    private func lookupLocal(_ name: String) -> Local? {
        for frame in frames.reversed() {
            if let l = frame.last(where: { $0.name == name }) { return l }
        }
        return nil
    }

    // MARK: - Statements

    // A lexical block: its own frame, so spawn handles and actor locals declared
    // inside get joined/released on the way out (structured-concurrency exit).
    private mutating func emitBlock(_ stmts: [IRStmt], ind: String) {
        pushScope()
        for s in stmts { emitStmt(s, ind: ind) }
        for l in frames[frames.count - 1].sorted(by: { $0.name < $1.name }) {
            if l.isSpawn {
                out += "\(ind)spawn_join(&\(l.name)__h);\n"       // join before leaving scope
            } else if case .named(let n, .actor_) = l.type {
                out += "\(ind)\(n)_release(\(l.name));\n"
            }
        }
        popScope()
    }

    private mutating func emitStmt(_ stmt: IRStmt, ind: String) {
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            declare(name, value.type)
            registerShareableClosure(name: name, value: value)
            out += "\(ind)\(cType(value.type)) \(name) = \(emitExpr(value));\n"

        case .spawnLet(let name, let value, let resultType):
            let (thunk, envName, caps) = emitSpawnThunk(value: value, resultType: resultType)
            // Site: allocate the env, copy captures by value, start the fiber.
            out += "\(ind)\(envName)* \(name)__e = (\(envName)*)rt_alloc(sizeof(\(envName)));\n"
            for c in caps { out += "\(ind)\(name)__e->\(c.name) = \(c.name);\n" }
            out += "\(ind)SpawnHandle \(name)__h; \(name)__h.fiber = fiber_spawn(\(thunk), \(name)__e);\n"
            declare(name, resultType, isSpawn: true)   // reads of `name` join and yield

        case .assign(let target, let value):
            // Bind before appending: emitExpr may mutate `out` (closure hoisting).
            let l = emitExpr(target); let r = emitExpr(value)
            out += "\(ind)\(l) = \(r);\n"

        case .compoundAssign(let target, let value):
            let l = emitExpr(target); let r = emitExpr(value)
            out += "\(ind)\(l) += \(r);\n"

        case .ret(let e):
            // Structured guarantee: join all active spawns before leaving the function.
            for l in frames.flatMap({ $0 }).filter(\.isSpawn).sorted(by: { $0.name < $1.name }) {
                out += "\(ind)spawn_join(&\(l.name)__h);\n"
            }
            // Actor handler: write fields back and release the mutex before returning.
            if let ctx = handlerCtx {
                for f in ctx.fields { out += "\(ind)self->\(f.name) = \(f.name);\n" }
                out += "\(ind)pthread_mutex_unlock(&self->mu);\n"
            }
            if let e { out += "\(ind)return \(emitExpr(e));\n" }
            else     { out += "\(ind)return;\n" }

        case .ifStmt(let cond, let then, let els):
            out += "\(ind)if (\(emitExpr(cond))) {\n"
            emitBlock(then, ind: ind + "    ")
            out += "\(ind)}"
            if let els {
                out += " else {\n"
                emitBlock(els, ind: ind + "    ")
                out += "\(ind)}"
            }
            out += "\n"

        case .switchStmt(let sw):
            emitSwitch(sw, ind: ind)

        case .exprStmt(let e):
            out += "\(ind)\(emitExpr(e));\n"
        }
    }

    private mutating func emitSwitch(_ sw: IRSwitch, ind: String) {
        let subj = emitExpr(sw.subject)
        guard case .named(let enumName, .enum_) = sw.subject.type, let ed = enums[enumName] else {
            out += "\(ind)/* switch: non-enum subject */\n"; return
        }
        out += "\(ind)switch (\(subj).tag) {\n"
        for arm in sw.arms {
            guard let cd = ed.cases.first(where: { $0.name == arm.caseName }) else { continue }
            out += "\(ind)    case \(enumName)_\(arm.caseName): {\n"
            pushScope()   // payload bindings live for the arm
            for (binding, field) in zip(arm.bindings, cd.fields) {
                out += "\(ind)        \(cType(binding.type)) \(binding.name) = \(subj).payload.\(arm.caseName).\(field.name);\n"
                declare(binding.name, binding.type)
            }
            emitBlock(arm.body, ind: ind + "        ")
            out += "\(ind)        break;\n"
            out += "\(ind)    }\n"
            popScope()
        }
        out += "\(ind)}\n"
    }

    // MARK: - Expressions

    // Returns a C rvalue string. The old codegen's type-guessing collapses here into
    // a switch on ExprKind — Sema already resolved construct / methodCall / call.
    private mutating func emitExpr(_ e: IRExpr) -> String {
        switch e.kind {
        case .intLit(let v):    return "\(v)"
        case .boolLit(let v):   return v ? "1" : "0"
        case .stringLit(let v): return "rt_str_lit(\(cStringLiteral(v)), \(v.utf8.count))"

        case .varRef(let n):
            if let l = lookupLocal(n) {
                // Reading a spawn-bound name joins its fiber (idempotent), yielding the result.
                if l.isSpawn { return "(*(\(cType(l.type))*)spawn_join(&\(n)__h))" }
                return n
            }
            // A field accessed by bare name inside a mutating method → through `self`.
            if methodFields.contains(n) { return "self\(selfIsPointer ? "->" : ".")\(n)" }
            return n

        case .fieldAccess(let base, let field):
            // `self` is a pointer in a mutating value method / class method → `self->field`.
            let op: String
            if case .varRef("self") = base.kind, selfIsPointer { op = "->" } else { op = memberOp(base.type) }
            return "\(emitExpr(base))\(op)\(field)"

        case .construct(let typeName, let args):
            return emitConstruct(typeName: typeName, args: args)

        case .enumInit(let typeName, let caseName, let args):
            return emitEnumInit(typeName: typeName, caseName: caseName, args: args)

        case .methodCall(let receiver, let method, let args):
            return emitMethodCall(receiver: receiver, method: method, args: args)

        case .call(let callee, let args):
            return emitCall(callee: callee, args: args)

        case .binary(let op, let l, let r):
            return "(\(emitExpr(l)) \(cOp(op)) \(emitExpr(r)))"

        case .closure(let params, let body):
            var ret = Type.void
            if case .function(_, let r) = e.type { ret = r }
            return emitClosure(params: params, body: body, ret: ret)
        }
    }

    // struct → compound literal; class/actor → Name_new(...).
    private mutating func emitConstruct(typeName: String, args: [IRArg]) -> String {
        if let s = structs[typeName] {
            var fields: [String] = []
            for f in s.fields {
                if let a = args.first(where: { $0.label == f.name }) {
                    fields.append(".\(f.name) = \(emitExpr(a.value))")
                } else {
                    fields.append(".\(f.name) = 0")
                }
            }
            return "(\(typeName)){ \(fields.joined(separator: ", ")) }"
        }
        if let c = classes[typeName] {
            return "\(typeName)_new(\(emitLabeled(c.fields.map(\.name), args).joined(separator: ", ")))"
        }
        if let a = actors[typeName] {
            let labels = a.fields.filter { $0.initializer == nil }.map(\.name)
            return "\(typeName)_new(\(emitLabeled(labels, args).joined(separator: ", ")))"
        }
        return "/* unknown type \(typeName) */"
    }

    // Member call → Type_method(recv, args...). Actor sends and struct/enum/class
    // instance methods share this C shape; the receiver is emitted as-is — a value
    // for struct/enum, a pointer for class/actor — matching the method's `self`.
    // (Kept unified deliberately; the actor-handler-parameter share check is slice 3.)
    // Enum value → tagged-union compound literal. Payload cases set the active union
    // member (named by the case); a no-payload case sets only the tag.
    private mutating func emitEnumInit(typeName: String, caseName: String, args: [IRArg]) -> String {
        let tag = "\(typeName)_\(caseName)"
        if args.isEmpty { return "(\(typeName)){ .tag = \(tag) }" }
        var inits: [String] = []
        for a in args { inits.append(".\(a.label ?? "") = \(emitExpr(a.value))") }
        return "(\(typeName)){ .tag = \(tag), .payload.\(caseName) = { \(inits.joined(separator: ", ")) } }"
    }

    private mutating func emitMethodCall(receiver: IRExpr, method: String, args: [IRExpr]) -> String {
        guard case .named(let typeName, let kind) = receiver.type else {
            return "/* non-object method call: \(method) */"
        }
        // A mutating value-type (struct/enum) method takes `T* self`, so pass the
        // receiver's address; the caller check guaranteed it's a mutable `var` lvalue.
        // Class/actor receivers are already pointers, and so is `self` inside a
        // pointer-self method (don't take its address again).
        let byPointer = kind != .class_ && kind != .actor_ && methodIsMutating(typeName, method)
        let recvAlreadyPointer: Bool = { if case .varRef("self") = receiver.kind { return selfIsPointer }; return false }()
        let recvExpr = emitExpr(receiver)
        let recv = (byPointer && !recvAlreadyPointer) ? "&\(recvExpr)" : recvExpr
        let argVals = args.map { emitExpr($0) }
        return "\(typeName)_\(method)(\(([recv] + argVals).joined(separator: ", ")))"
    }

    private func methodIsMutating(_ typeName: String, _ method: String) -> Bool {
        let m = structs[typeName]?.methods.first { $0.name == method }
            ?? enums[typeName]?.methods.first { $0.name == method }
            ?? classes[typeName]?.methods.first { $0.name == method }
        return m?.isMutating ?? false
    }

    private mutating func emitCall(callee: IRExpr, args: [IRArg]) -> String {
        if case .varRef(let name) = callee.kind {
            if name == "print" {
                if args.isEmpty { return "printf(\"\\n\")" }
                let argExpr = args[0].value
                let arg = emitExpr(argExpr)
                if argExpr.type == .string {
                    return "printf(\"%.*s\\n\", (int)(\(arg)).len, (\(arg)).data)"
                }
                return "printf(\"%lld\\n\", (long long)(\(arg)))"
            }
            if name == "readLine" { return "rt_read_line(0)" }
            if name == "concat" {
                let a = args.count > 0 ? emitExpr(args[0].value) : "rt_str_lit(\"\", 0)"
                let b = args.count > 1 ? emitExpr(args[1].value) : "rt_str_lit(\"\", 0)"
                return "rt_str_concat(\(a), \(b))"
            }
            if name == "sleep" {
                let arg = args.isEmpty ? "0" : emitExpr(args[0].value)
                return "rt_sleep_ms(\(arg))"
            }
            // A closure-typed local: cast the code pointer and pass the captured env first.
            if let local = lookupLocal(name), case .function(let params, let ret) = local.type {
                let retC     = cType(ret)
                let argTypes = params.map { cType($0) }.joined(separator: ", ")
                let sig      = "\(retC)(*)(void*\(params.isEmpty ? "" : ", \(argTypes)"))"
                let vals     = emitArgs(args)
                let tail     = vals.isEmpty ? "" : ", " + vals.joined(separator: ", ")
                return "((\(sig))\(name).fn)(\(name).env\(tail))"
            }
            return "\(name)(\(emitArgs(args).joined(separator: ", ")))"
        }
        return "\(emitExpr(callee))(\(emitArgs(args).joined(separator: ", ")))"
    }

    // Emit each argument in order (a loop, to avoid mutating self inside a map closure).
    private mutating func emitArgs(_ args: [IRArg]) -> [String] {
        var vals: [String] = []
        for a in args { vals.append(emitExpr(a.value)) }
        return vals
    }

    // Match declared labels to arguments in declaration order; a missing one becomes "0".
    private mutating func emitLabeled(_ labels: [String], _ args: [IRArg]) -> [String] {
        var vals: [String] = []
        for label in labels {
            if let a = args.first(where: { $0.label == label }) { vals.append(emitExpr(a.value)) }
            else { vals.append("0") }
        }
        return vals
    }

    // MARK: - Closures (closure conversion to an env struct + impl function)

    private mutating func emitClosure(params: [IRParam], body: [IRStmt], ret: Type) -> String {
        let idx = closureSeq; closureSeq += 1
        let name    = "nomu_clo\(idx)"
        let envName = "\(name)_env"

        // Captured = free vars used in the body that exist in the enclosing scope
        // (excludes params, body-locals, and globals such as function names).
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUsesBlock(body, bound: &bound, used: &used)
        let caps = capturedLocals(used)

        // Environment struct.
        var def = "typedef struct {\n"
        if caps.isEmpty {
            def += "    char _empty;\n"
        } else {
            for c in caps { def += "    \(cType(c.type)) \(c.name);\n" }
        }
        def += "} \(envName);\n\n"

        // Implementation function: env pointer + declared params.
        var sig = "void* __envv"
        for p in params { sig += ", \(cType(p.type)) \(p.name)" }
        def += "static \(cType(ret)) \(name)(\(sig)) {\n"
        def += "    \(envName)* __env = (\(envName)*)__envv;\n"
        for c in caps { def += "    \(cType(c.type)) \(c.name) = __env->\(c.name);\n" }

        // Emit the body against a fresh scope (captures + params), redirecting `out`.
        def += emitBodyIsolated(captures: caps, params: params, body: body)
        def += "}\n\n"
        closureDefs += def

        // Site: bump-allocate the env, copy captures by value, produce the Closure value.
        var site = "({ \(envName)* __e = (\(envName)*)rt_alloc(sizeof(\(envName)));"
        for c in caps { site += " __e->\(c.name) = \(c.name);" }
        site += " (Closure){ .fn = (void*)\(name), .env = __e }; })"
        return site
    }

    // MARK: - Structured spawn

    // Closure-convert `value` into a fiber start routine returning a boxed result.
    private mutating func emitSpawnThunk(value: IRExpr, resultType: Type) -> (String, String, [Local]) {
        let idx = spawnSeq; spawnSeq += 1
        let name    = "nomu_spawn\(idx)"
        let envName = "\(name)_env"

        var used: [String] = []
        collectUsesExpr(value, bound: [], used: &used)
        let caps = capturedLocals(used)

        // Share analysis: a capture must be able to cross the task boundary.
        for cap in caps where !isShareableBinding(cap.name, type: cap.type) {
            diagnostics.append("error: '\(cap.name)' has type '\(cap.type)' which cannot cross a task boundary — only value types and closures with shareable captures are shareable")
        }

        var def = "typedef struct {\n"
        if caps.isEmpty {
            def += "    char _empty;\n"
        } else {
            for c in caps { def += "    \(cType(c.type)) \(c.name);\n" }
        }
        def += "} \(envName);\n\n"

        let rc = cType(resultType)
        def += "static void* \(name)(void* __envv) {\n"
        def += "    \(envName)* __env = (\(envName)*)__envv;\n"
        for c in caps { def += "    \(cType(c.type)) \(c.name) = __env->\(c.name);\n" }

        // The spawn value is a single expression; emit it against the capture scope.
        let savedFrames = frames
        frames = []
        pushScope()
        for c in caps { declare(c.name, c.type) }
        let v = emitExpr(value)
        popScope()
        frames = savedFrames

        def += "    \(rc)* __box = (\(rc)*)rt_alloc(sizeof(\(rc)));\n"
        def += "    *__box = \(v);\n"
        def += "    return __box;\n"
        def += "}\n\n"
        closureDefs += def
        return (name, envName, caps)
    }

    // Emits `body` with a fresh scope of captures + params, returning the emitted C.
    // Mirrors emitFunc's frame layout (captures/params below the body frame) but
    // captures the output rather than appending to `out`.
    private mutating func emitBodyIsolated(captures: [Local], params: [IRParam], body: [IRStmt]) -> String {
        let savedOut = out; out = ""
        let savedFrames = frames
        frames = []
        pushScope()
        for c in captures { declare(c.name, c.type) }
        for p in params { declare(p.name, p.type) }
        emitBlock(body, ind: "    ")
        popScope()
        frames = savedFrames
        let body = out; out = savedOut
        return body
    }

    // MARK: - Share analysis

    // Distinct enclosing-scope locals among `used`, in first-use order, with types.
    private func capturedLocals(_ used: [String]) -> [Local] {
        var seen = Set<String>()
        var caps: [Local] = []
        for name in used {
            guard let l = lookupLocal(name), seen.insert(name).inserted else { continue }
            caps.append(l)
        }
        return caps
    }

    // A closure binding is shareable iff every capture is (design: concurrency.md §6).
    private mutating func registerShareableClosure(name: String, value: IRExpr) {
        guard case .closure(let params, let body) = value.kind else { return }
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUsesBlock(body, bound: &bound, used: &used)
        let caps = capturedLocals(used)
        if caps.allSatisfy({ isShareableBinding($0.name, type: $0.type) }) {
            shareableClosureBindings.insert(name)
        }
    }

    // A type is shareable if it can safely cross a task boundary: primitives and
    // value types (structs, enums), plus actor handles (self-synchronizing).
    // Strings, classes, and closures are not (closures are checked per-binding).
    private func isShareable(_ t: Type) -> Bool {
        switch t {
        case .int, .bool:                                        return true
        case .named(_, .struct_), .named(_, .enum_), .named(_, .actor_): return true
        default:                                                 return false
        }
    }

    private func isShareableBinding(_ name: String, type: Type) -> Bool {
        isShareable(type) || shareableClosureBindings.contains(name)
    }

    // MARK: - Free-variable collection (respects shadowing via `bound`)

    private func collectUsesBlock(_ block: [IRStmt], bound: inout Set<String>, used: inout [String]) {
        for stmt in block { collectUsesStmt(stmt, bound: &bound, used: &used) }
    }

    private func collectUsesStmt(_ stmt: IRStmt, bound: inout Set<String>, used: inout [String]) {
        switch stmt.kind {
        case .letBinding(let name, _, let value):
            collectUsesExpr(value, bound: bound, used: &used)
            bound.insert(name)
        case .spawnLet(let name, let value, _):
            collectUsesExpr(value, bound: bound, used: &used)
            bound.insert(name)
        case .assign(let target, let value), .compoundAssign(let target, let value):
            collectUsesExpr(target, bound: bound, used: &used)
            collectUsesExpr(value, bound: bound, used: &used)
        case .ret(let e):
            if let e { collectUsesExpr(e, bound: bound, used: &used) }
        case .ifStmt(let cond, let then, let els):
            collectUsesExpr(cond, bound: bound, used: &used)
            var b1 = bound; collectUsesBlock(then, bound: &b1, used: &used)
            if let els { var b2 = bound; collectUsesBlock(els, bound: &b2, used: &used) }
        case .switchStmt(let sw):
            collectUsesExpr(sw.subject, bound: bound, used: &used)
            for arm in sw.arms {
                var ab = bound
                for b in arm.bindings { ab.insert(b.name) }
                collectUsesBlock(arm.body, bound: &ab, used: &used)
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
        case .call(let callee, let args):
            collectUsesExpr(callee, bound: bound, used: &used)
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .binary(_, let l, let r):
            collectUsesExpr(l, bound: bound, used: &used)
            collectUsesExpr(r, bound: bound, used: &used)
        case .closure(let ps, let cbody):
            var nb = bound
            for p in ps { nb.insert(p.name) }
            collectUsesBlock(cbody, bound: &nb, used: &used)
        }
    }

    // MARK: - C helpers

    private func memberOp(_ base: Type) -> String {
        if case .named(_, let k) = base, k == .class_ || k == .actor_ { return "->" }
        return "."
    }

    private func cStringLiteral(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:   out += String(c)
            }
        }
        out += "\""
        return out
    }

    private func cOp(_ op: BinOp) -> String {
        switch op {
        case .add: return "+"
        case .sub: return "-"
        case .mul: return "*"
        case .div: return "/"
        case .eq:  return "=="
        case .neq: return "!="
        case .lt:  return "<"
        case .gt:  return ">"
        case .lte: return "<="
        case .gte: return ">="
        }
    }

    // MARK: - C helpers

    private func cType(_ t: Type) -> String {
        switch t {
        case .int, .bool: return "int64_t"
        case .string:     return "String"
        case .void:       return "void"
        case .function:   return "Closure"
        case .named(let n, let kind):
            switch kind {
            case .class_, .actor_: return "\(n)*"
            case .struct_, .enum_: return n
            }
        case .error:      return "int64_t"   // unreachable for well-typed programs
        }
    }
}
