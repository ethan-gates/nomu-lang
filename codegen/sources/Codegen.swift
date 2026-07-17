import Foundation
import frontend

// Maps variable name → nomu type name within a function body.
private typealias Scope = [String: String]

public struct Codegen {
    private let program: Program
    private var out = ""

    // Quick lookup tables populated at init
    private var structs:  [String: StructDecl] = [:]
    private var enums:    [String: EnumDecl]   = [:]
    private var classes:  [String: ClassDecl]  = [:]
    private var actors:   [String: ActorDecl]  = [:]
    private var funcs:    [String: FuncDecl]   = [:]

    // Closures: hoisted env-struct + impl-function definitions, and a registry of
    // function types (canonical name → signature) for call-site casts.
    private var closureDefs = ""
    private var closureSeq  = 0
    private var fnTypes: [String: FnType] = [:]

    public init(_ program: Program) {
        self.program = program
        for decl in program.decls {
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
        emitPreamble()
        // Type declarations first — closure env structs may reference user types.
        for decl in program.decls {
            if case .funcDecl = decl { continue }
            emitTopDecl(decl)
        }
        // Marker where hoisted closure definitions get spliced in (after types, before funcs).
        let marker = "/*__NOMU_CLOSURES__*/\n"
        out += marker
        for decl in program.decls {
            if case .funcDecl(let f) = decl { emitFunc(f) }
        }
        emitCMain()
        return out.replacingOccurrences(of: marker, with: closureDefs)
    }

    // MARK: - Top-level

    private mutating func emitTopDecl(_ decl: TopDecl) {
        switch decl {
        case .structDecl(let s): emitStruct(s)
        case .enumDecl(let e):   emitEnum(e)
        case .classDecl(let c):  emitClass(c)
        case .actorDecl(let a):  emitActor(a)
        case .funcDecl(let f):   emitFunc(f)
        }
    }

    // MARK: - Type declarations

    private mutating func emitStruct(_ s: StructDecl) {
        out += "typedef struct {\n"
        for f in s.fields { out += "    \(cType(f.type.name)) \(f.name);\n" }
        out += "} \(s.name);\n\n"
    }

    private mutating func emitEnum(_ e: EnumDecl) {
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
                for f in c.fields { out += "            \(cType(f.type.name)) \(f.name);\n" }
                out += "        } \(c.name);\n"
            }
        }
        out += "    } payload;\n"
        out += "} \(e.name);\n\n"
    }

    // MARK: - Classes

    private mutating func emitClass(_ c: ClassDecl) {
        // Reference type under bump-and-leak: heap-allocated, never freed (no GC yet,
        // no deinit). The header word is vestigial until real GC arrives (M6).
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in c.fields { out += "    \(cType(f.type.name)) \(f.name);\n" }
        out += "} \(c.name);\n\n"

        let ctorParams = c.fields.isEmpty
            ? "void"
            : c.fields.map { "\(cType($0.type.name)) \($0.name)" }.joined(separator: ", ")
        out += "static \(c.name)* \(c.name)_new(\(ctorParams)) {\n"
        out += "    \(c.name)* self = (\(c.name)*)rt_alloc(sizeof(\(c.name)));\n"
        for f in c.fields { out += "    self->\(f.name) = \(f.name);\n" }
        out += "    return self;\n"
        out += "}\n\n"
    }

    // MARK: - Actors

    private mutating func emitActor(_ a: ActorDecl) {
        let name      = a.name
        let msgType   = "\(name)_msg"
        let queueType = "MsgQueue_\(name)"

        // Message tag enum + payload union
        let tags = a.handlers.map { "\(name)_\($0.name)" }.joined(separator: ", ")
        out += "typedef enum { \(tags) } \(name)_msg_tag;\n"
        out += "typedef struct {\n"
        out += "    \(name)_msg_tag tag;\n"
        out += "    union {\n"
        for h in a.handlers {
            if h.params.isEmpty {
                out += "        char \(h.name)_pad;\n"
            } else {
                out += "        struct {\n"
                for p in h.params { out += "            \(cType(p.type.name)) \(p.name);\n" }
                out += "        } \(h.name);\n"
            }
        }
        out += "    } payload;\n"
        out += "} \(msgType);\n\n"

        // Mailbox + actor struct (thread, mutex, condvar, shutdown flag)
        out += "typedef struct { \(msgType)* buf; size_t len, cap; } \(queueType);\n\n"

        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in a.fields { out += "    \(cType(f.type.name)) \(f.name);\n" }
        out += "    \(queueType) queue;\n"
        out += "    pthread_t      thread;\n"
        out += "    pthread_mutex_t mutex;\n"
        out += "    pthread_cond_t  cond;\n"
        out += "    int shutdown;\n"
        out += "    int joined;\n"
        out += "} \(name);\n\n"

        // Enqueue — called from any thread; locks, appends, signals actor thread
        out += "static void \(name)_enqueue(\(name)* self, \(msgType) msg) {\n"
        out += "    pthread_mutex_lock(&self->mutex);\n"
        out += "    if (self->queue.len == self->queue.cap) {\n"
        out += "        self->queue.cap = self->queue.cap == 0 ? 4 : self->queue.cap * 2;\n"
        out += "        self->queue.buf = (\(msgType)*)realloc(self->queue.buf, sizeof(\(msgType)) * self->queue.cap);\n"
        out += "    }\n"
        out += "    self->queue.buf[self->queue.len++] = msg;\n"
        out += "    pthread_cond_signal(&self->cond);\n"
        out += "    pthread_mutex_unlock(&self->mutex);\n"
        out += "}\n\n"

        // Run loop — actor's dedicated thread; steals the queue batch, dispatches without holding the lock
        out += "static void* \(name)_run(void* arg) {\n"
        out += "    \(name)* self = (\(name)*)arg;\n"
        out += "    for (;;) {\n"
        out += "        pthread_mutex_lock(&self->mutex);\n"
        out += "        while (self->queue.len == 0 && !self->shutdown)\n"
        out += "            pthread_cond_wait(&self->cond, &self->mutex);\n"
        out += "        // Steal the pending batch so enqueue can proceed without contention\n"
        out += "        size_t n = self->queue.len;\n"
        out += "        \(msgType)* msgs = self->queue.buf;\n"
        out += "        self->queue.buf = NULL; self->queue.len = 0; self->queue.cap = 0;\n"
        out += "        pthread_mutex_unlock(&self->mutex);\n"
        out += "        if (n == 0) break;  // shutdown && empty\n"
        out += "        // Dispatch — actor fields only ever touched here\n"
        out += "        for (size_t i = 0; i < n; i++) {\n"
        out += "            \(msgType) m = msgs[i];\n"
        out += "            switch (m.tag) {\n"
        for h in a.handlers {
            out += "                case \(name)_\(h.name): {\n"
            for p in h.params {
                out += "                    \(cType(p.type.name)) \(p.name) = m.payload.\(h.name).\(p.name);\n"
            }
            var handlerScope: Scope = [:]
            for f in a.fields {
                out += "                    \(cType(f.type.name)) \(f.name) = self->\(f.name);\n"
                handlerScope[f.name] = f.type.name
            }
            for p in h.params { handlerScope[p.name] = p.type.name }
            emitBlock(h.body, scope: &handlerScope, ind: "                    ")
            for f in a.fields { out += "                    self->\(f.name) = \(f.name);\n" }
            out += "                    break;\n"
            out += "                }\n"
        }
        out += "            }\n"
        out += "        }\n"
        out += "        free(msgs);\n"
        out += "    }\n"
        out += "    return NULL;\n"
        out += "}\n\n"

        // Join — signals shutdown, waits for the actor thread to drain and exit (idempotent)
        out += "static void \(name)_join(\(name)* self) {\n"
        out += "    if (self->joined) return;\n"
        out += "    pthread_mutex_lock(&self->mutex);\n"
        out += "    self->shutdown = 1;\n"
        out += "    pthread_cond_signal(&self->cond);\n"
        out += "    pthread_mutex_unlock(&self->mutex);\n"
        out += "    pthread_join(self->thread, NULL);\n"
        out += "    self->joined = 1;\n"
        out += "}\n\n"

        // Constructor — fields with initializers don't appear as parameters
        let ctorFields = a.fields.filter { $0.initializer == nil }
        let ctorParams = ctorFields.isEmpty
            ? "void"
            : ctorFields.map { "\(cType($0.type.name)) \($0.name)" }.joined(separator: ", ")
        out += "static \(name)* \(name)_new(\(ctorParams)) {\n"
        out += "    \(name)* self = (\(name)*)rt_alloc(sizeof(\(name)));\n"
        for f in a.fields {
            if let init_ = f.initializer {
                let emptyScope: Scope = [:]
                let v = emitExpr(init_, scope: emptyScope)
                out += "    self->\(f.name) = \(v);\n"
            } else {
                out += "    self->\(f.name) = \(f.name);\n"
            }
        }
        out += "    pthread_mutex_init(&self->mutex, NULL);\n"
        out += "    pthread_cond_init(&self->cond, NULL);\n"
        out += "    pthread_create(&self->thread, NULL, \(name)_run, self);\n"
        out += "    return self;\n"
        out += "}\n\n"

        // Deinit (joins thread, frees queue, destroys sync primitives) + release
        out += "static void \(name)_deinit(\(name)* self) {\n"
        out += "    \(name)_join(self);\n"
        out += "    free(self->queue.buf);\n"
        out += "    pthread_mutex_destroy(&self->mutex);\n"
        out += "    pthread_cond_destroy(&self->cond);\n"
        out += "}\n\n"

        out += "static void \(name)_release(\(name)* self) {\n"
        out += "    if (self && --self->header.refcount == 0) {\n"
        out += "        \(name)_deinit(self);\n"
        out += "        free(self);\n"
        out += "    }\n"
        out += "}\n\n"
    }

    // MARK: - Functions

    private mutating func emitFunc(_ f: FuncDecl) {
        var scope: Scope = [:]
        for p in f.params {
            scope[p.name] = p.type.name
            if let ft = p.type.fn { fnTypes[p.type.name] = ft }   // closure param → known signature
        }

        let cName   = f.name == "main" ? "nomu_main" : f.name
        let retType = f.returnType.map { cType($0.name) } ?? "void"
        let params  = f.params.isEmpty
            ? "void"
            : f.params.map { "\(cType($0.type.name)) \($0.name)" }.joined(separator: ", ")

        out += "\(retType) \(cName)(\(params)) {\n"
        emitBlock(f.body, scope: &scope, ind: "    ")
        out += "}\n\n"
    }

    // Emits a block of statements. Classes bump-and-leak (no release); only the retired
    // actor path still releases its handle at scope end (joins the actor thread).
    private mutating func emitBlock(_ stmts: Block, scope: inout Scope, ind: String) {
        let outerKeys = Set(scope.keys)
        for stmt in stmts { emitStmt(stmt, scope: &scope, ind: ind) }
        for key in Set(scope.keys).subtracting(outerKeys).sorted() {
            if let typeName = scope[key], actors[typeName] != nil {
                out += "\(ind)\(typeName)_release(\(key));\n"
            }
        }
    }

    // MARK: - Statements

    private mutating func emitStmt(_ stmt: Stmt, scope: inout Scope, ind: String) {
        switch stmt {
        case .binding(let b):
            emitBinding(b, scope: &scope, ind: ind)
        case .assign(let lhs, let rhs, _):
            // bind before appending: emitExpr may mutate `out` (closure hoisting), which
            // would overlap the `out +=` write.
            let l = emitExpr(lhs, scope: scope); let r = emitExpr(rhs, scope: scope)
            out += "\(ind)\(l) = \(r);\n"
        case .compoundAssign(let lhs, let rhs, _):
            let l = emitExpr(lhs, scope: scope); let r = emitExpr(rhs, scope: scope)
            out += "\(ind)\(l) += \(r);\n"
        case .ret(let e, _):
            if let e { let v = emitExpr(e, scope: scope); out += "\(ind)return \(v);\n" }
            else { out += "\(ind)return;\n" }
        case .ifStmt(let s):
            emitIf(s, scope: &scope, ind: ind)
        case .switchStmt(let sw):
            emitSwitch(sw, scope: &scope, ind: ind)
        case .expr(let e):
            let v = emitExpr(e, scope: scope)
            out += "\(ind)\(v);\n"
        case .send(let e, _):
            emitSend(e, scope: &scope, ind: ind)
        case .join(let e, _):
            guard case .ident(let actorVar, _) = e,
                  let actorType = scope[actorVar]
            else { out += "\(ind)/* join: unrecognized form */\n"; return }
            out += "\(ind)\(actorType)_join(\(actorVar));\n"
        }
    }

    private mutating func emitBinding(_ b: BindingStmt, scope: inout Scope, ind: String) {
        let typeName = b.type?.name ?? typeOf(b.value, scope: scope)
        scope[b.name] = typeName
        // A closure-bound name needs its signature registered for later call-site casts.
        if case .closure(let ps, let r, _, _) = b.value {
            fnTypes[typeName] = FnType(params: ps.map { $0.type }, ret: r)
        }
        let value = emitInit(b.value, as: typeName, scope: scope)
        out += "\(ind)\(cType(typeName)) \(b.name) = \(value);\n"
    }

    private mutating func emitSend(_ e: Expr, scope: inout Scope, ind: String) {
        guard case .call(let callee, let args, _) = e,
              case .member(let actorExpr, let handlerName, _) = callee,
              case .ident(let actorVar, _) = actorExpr,
              let actorType = scope[actorVar],
              let ad = actors[actorType],
              let handler = ad.handlers.first(where: { $0.name == handlerName })
        else {
            out += "\(ind)/* send: unrecognized form */\n"
            return
        }

        let msgType = "\(actorType)_msg"
        let tag     = "\(actorType)_\(handlerName)"

        var fieldInits = ".tag = \(tag)"
        for p in handler.params {
            let v: String
            if let a = args.first(where: { $0.label == p.label }) { v = emitExpr(a.value, scope: scope) }
            else { v = "0" }
            fieldInits += ", .payload.\(handlerName).\(p.name) = \(v)"
        }

        out += "\(ind)\(actorType)_enqueue(\(actorVar), (\(msgType)){ \(fieldInits) });\n"
    }

    private mutating func emitIf(_ s: IfStmt, scope: inout Scope, ind: String) {
        let cond = emitExpr(s.cond, scope: scope)
        out += "\(ind)if (\(cond)) {\n"
        var thenScope = scope   // branch-local bindings stay in the branch
        emitBlock(s.thenBody, scope: &thenScope, ind: ind + "    ")
        out += "\(ind)}"
        if let elseBody = s.elseBody {
            out += " else {\n"
            var elseScope = scope
            emitBlock(elseBody, scope: &elseScope, ind: ind + "    ")
            out += "\(ind)}"
        }
        out += "\n"
    }

    private mutating func emitSwitch(_ sw: SwitchStmt, scope: inout Scope, ind: String) {
        let subj     = emitExpr(sw.subject, scope: scope)
        let enumName = typeOf(sw.subject, scope: scope)
        guard let ed = enums[enumName] else {
            out += "\(ind)/* switch: unknown enum type '\(enumName)' */\n"; return
        }

        out += "\(ind)switch (\(subj).tag) {\n"
        for arm in sw.cases {
            guard case .enumCase(let caseName, let bindings, _) = arm.pattern,
                  let cd = ed.cases.first(where: { $0.name == caseName }) else { continue }

            out += "\(ind)    case \(enumName)_\(caseName): {\n"
            var inner = scope
            for (binding, field) in zip(bindings, cd.fields) {
                out += "\(ind)        \(cType(field.type.name)) \(binding) = \(subj).payload.\(caseName).\(field.name);\n"
                inner[binding] = field.type.name
            }
            for stmt in arm.body { emitStmt(stmt, scope: &inner, ind: ind + "        ") }
            // classes bump-and-leak: no release of pattern-bound class locals
            out += "\(ind)        break;\n"
            out += "\(ind)    }\n"
        }
        out += "\(ind)}\n"
    }

    // MARK: - Expressions

    // Returns an expression string usable anywhere a C rvalue is expected.
    private mutating func emitExpr(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit(let v, _):   return "\(v)"
        case .boolLit(let v, _):  return v ? "1" : "0"
        case .ident(let n, _):    return n
        case .member(let base, let field, _):
            let bt = typeOf(base, scope: scope)
            let op = (classes[bt] != nil || actors[bt] != nil) ? "->" : "."
            return "\(emitExpr(base, scope: scope))\(op)\(field)"
        case .binary(let op, let lhs, let rhs, _):
            return "(\(emitExpr(lhs, scope: scope)) \(cOp(op)) \(emitExpr(rhs, scope: scope)))"
        case .call(let callee, let args, _):
            return emitCall(callee: callee, args: args, scope: scope)
        case .spawn(let name, let args, _):
            guard let ad = actors[name] else { return "/* spawn: unknown actor \(name) */" }
            let labels = ad.fields.filter { $0.initializer == nil }.map(\.name)
            return "\(name)_new(\(emitLabeled(labels, args, scope: scope).joined(separator: ", ")))"
        case .closure(let params, let ret, let body, _):
            return emitClosure(params: params, ret: ret, body: body, scope: scope)
        }
    }

    // Emit each argument in order (a for-loop, to avoid mutating self inside a map closure).
    private mutating func emitArgs(_ args: [Arg], scope: Scope) -> [String] {
        var vals: [String] = []
        for a in args { vals.append(emitExpr(a.value, scope: scope)) }
        return vals
    }

    // Match declared labels to arguments in declaration order; a missing one becomes "0".
    private mutating func emitLabeled(_ labels: [String], _ args: [Arg], scope: Scope) -> [String] {
        var vals: [String] = []
        for label in labels {
            if let a = args.first(where: { $0.label == label }) {
                vals.append(emitExpr(a.value, scope: scope))
            } else {
                vals.append("0")
            }
        }
        return vals
    }

    // Emit an expression in initializer position (bindings only).
    // Allows struct compound-literal form at the top level.
    private mutating func emitInit(_ e: Expr, as typeName: String, scope: Scope) -> String {
        if case .call(let callee, let args, _) = e,
           case .ident(let name, _) = callee,
           structs[name] != nil {
            return structLiteral(name: name, args: args, scope: scope)
        }
        return emitExpr(e, scope: scope)
    }

    private mutating func emitCall(callee: Expr, args: [Arg], scope: Scope) -> String {
        guard case .ident(let name, _) = callee else {
            return "\(emitExpr(callee, scope: scope))(\(emitArgs(args, scope: scope).joined(separator: ", ")))"
        }
        // A closure-typed local: cast the code pointer and pass the captured env first.
        if let ft = fnTypes[scope[name] ?? ""] {
            let retC     = ft.ret.map { cType($0.name) } ?? "void"
            let argTypes = ft.params.map { cType($0.name) }.joined(separator: ", ")
            let sig      = "\(retC)(*)(void*\(ft.params.isEmpty ? "" : ", \(argTypes)"))"
            let vals     = emitArgs(args, scope: scope)
            let tail     = vals.isEmpty ? "" : ", " + vals.joined(separator: ", ")
            return "((\(sig))\(name).fn)(\(name).env\(tail))"
        }
        if name == "print" {
            let arg = args.isEmpty ? "0" : emitExpr(args[0].value, scope: scope)
            return "printf(\"%lld\\n\", (long long)(\(arg)))"
        }
        if structs[name] != nil { return structLiteral(name: name, args: args, scope: scope) }
        if let cd = classes[name] {
            return "\(name)_new(\(emitLabeled(cd.fields.map(\.name), args, scope: scope).joined(separator: ", ")))"
        }
        return "\(name)(\(emitArgs(args, scope: scope).joined(separator: ", ")))"
    }

    private mutating func structLiteral(name: String, args: [Arg], scope: Scope) -> String {
        guard let s = structs[name] else { return "/* unknown struct \(name) */" }
        var fields: [String] = []
        for f in s.fields {
            if let a = args.first(where: { $0.label == f.name }) {
                fields.append(".\(f.name) = \(emitExpr(a.value, scope: scope))")
            } else {
                fields.append(".\(f.name) = 0")
            }
        }
        return "(\(name)){ \(fields.joined(separator: ", ")) }"
    }

    // MARK: - Closures (closure conversion to an env struct + impl function)

    private mutating func emitClosure(params: [Param], ret: TypeRef?, body: Block, scope: Scope) -> String {
        let idx = closureSeq; closureSeq += 1
        let name    = "nomu_clo\(idx)"
        let envName = "\(name)_env"

        // Captured = free variables used in the body that exist in the enclosing scope
        // (excludes params, body-locals, and globals such as function names).
        var bound = Set(params.map(\.name))
        var used: [String] = []
        collectUsesBlock(body, bound: &bound, used: &used)
        var seen = Set<String>()
        let caps = used.filter { scope[$0] != nil && seen.insert($0).inserted }

        // Environment struct.
        var def = "typedef struct {\n"
        if caps.isEmpty {
            def += "    char _empty;\n"
        } else {
            for c in caps { def += "    \(cType(scope[c]!)) \(c);\n" }
        }
        def += "} \(envName);\n\n"

        // Implementation function: env pointer + declared params.
        let retC = ret.map { cType($0.name) } ?? "void"
        var sig = "void* __envv"
        for p in params { sig += ", \(cType(p.type.name)) \(p.name)" }
        def += "static \(retC) \(name)(\(sig)) {\n"
        def += "    \(envName)* __env = (\(envName)*)__envv;\n"
        var cscope: Scope = [:]
        for c in caps {
            def += "    \(cType(scope[c]!)) \(c) = __env->\(c);\n"
            cscope[c] = scope[c]
        }
        for p in params { cscope[p.name] = p.type.name }

        // Emit the body into `def` by redirecting `out` temporarily.
        let saved = out; out = ""
        emitBlock(body, scope: &cscope, ind: "    ")
        def += out; out = saved
        def += "}\n\n"
        closureDefs += def

        // Site: bump-allocate the env, copy captures by value, produce the Closure value.
        var site = "({ \(envName)* __e = (\(envName)*)rt_alloc(sizeof(\(envName)));"
        for c in caps { site += " __e->\(c) = \(c);" }
        site += " (Closure){ .fn = (void*)\(name), .env = __e }; })"
        return site
    }

    // Free-variable collection (respects shadowing via `bound`).
    private func collectUsesBlock(_ block: Block, bound: inout Set<String>, used: inout [String]) {
        for stmt in block { collectUsesStmt(stmt, bound: &bound, used: &used) }
    }

    private func collectUsesStmt(_ stmt: Stmt, bound: inout Set<String>, used: inout [String]) {
        switch stmt {
        case .binding(let b):
            collectUsesExpr(b.value, bound: bound, used: &used)
            bound.insert(b.name)
        case .assign(let l, let r, _), .compoundAssign(let l, let r, _):
            collectUsesExpr(l, bound: bound, used: &used)
            collectUsesExpr(r, bound: bound, used: &used)
        case .ret(let e, _):
            if let e { collectUsesExpr(e, bound: bound, used: &used) }
        case .ifStmt(let s):
            collectUsesExpr(s.cond, bound: bound, used: &used)
            var b1 = bound; collectUsesBlock(s.thenBody, bound: &b1, used: &used)
            if let eb = s.elseBody { var b2 = bound; collectUsesBlock(eb, bound: &b2, used: &used) }
        case .switchStmt(let sw):
            collectUsesExpr(sw.subject, bound: bound, used: &used)
            for arm in sw.cases {
                var ab = bound
                if case .enumCase(_, let bindings, _) = arm.pattern { ab.formUnion(bindings) }
                collectUsesBlock(arm.body, bound: &ab, used: &used)
            }
        case .expr(let e):
            collectUsesExpr(e, bound: bound, used: &used)
        case .send, .join:
            break
        }
    }

    private func collectUsesExpr(_ e: Expr, bound: Set<String>, used: inout [String]) {
        switch e {
        case .intLit, .boolLit: break
        case .ident(let n, _): if !bound.contains(n) { used.append(n) }
        case .member(let base, _, _): collectUsesExpr(base, bound: bound, used: &used)
        case .call(let callee, let args, _):
            collectUsesExpr(callee, bound: bound, used: &used)
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .binary(_, let l, let r, _):
            collectUsesExpr(l, bound: bound, used: &used)
            collectUsesExpr(r, bound: bound, used: &used)
        case .spawn(_, let args, _):
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .closure(let ps, _, let cbody, _):
            var nb = bound
            for p in ps { nb.insert(p.name) }
            collectUsesBlock(cbody, bound: &nb, used: &used)
        }
    }

    // MARK: - Type resolution

    private func typeOf(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit:               return "Int"
        case .boolLit:              return "Bool"
        case .ident(let n, _):      return scope[n] ?? ""
        case .member(let base, let field, _):
            let bt = typeOf(base, scope: scope)
            return structs[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? classes[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? actors[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? ""
        case .call(let callee, _, _):
            guard case .ident(let n, _) = callee else { return "" }
            if structs[n] != nil || enums[n] != nil || classes[n] != nil { return n }
            return funcs[n]?.returnType?.name ?? ""
        case .binary:   return "Int"
        case .spawn(let n, _, _): return n
        case .closure(let params, let ret, _, _):
            return "(" + params.map { $0.type.name }.joined(separator: ", ") + ") -> " + (ret?.name ?? "Void")
        }
    }

    // MARK: - C helpers

    private func cType(_ name: String) -> String {
        switch name {
        case "Int", "Bool": return "int64_t"
        default:
            if fnTypes[name] != nil || name.contains(" -> ") { return "Closure" }
            return (classes[name] != nil || actors[name] != nil) ? "\(name)*" : name
        }
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

    // MARK: - Preamble and entry point

    private mutating func emitPreamble() {
        out += """
        #include <stdio.h>
        #include <stdlib.h>
        #include <stdint.h>
        #include <string.h>
        #include <pthread.h>

        typedef struct { size_t refcount; } ObjectHeader;
        static inline void* rt_alloc(size_t size) {
            void* p = calloc(1, size);
            if (!p) { fputs("out of memory\\n", stderr); exit(1); }
            ((ObjectHeader*)p)->refcount = 1;
            return p;
        }
        static inline void rt_retain(void* p) {
            if (p) ((ObjectHeader*)p)->refcount++;
        }

        // A closure value: code pointer + captured environment (heap-allocated, bump-and-leak).
        typedef struct { void* fn; void* env; } Closure;


        """
    }

    private mutating func emitCMain() {
        out += """
        int main(void) {
            nomu_main();
            return 0;
        }
        """
    }
}
