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
    private var spawnSeq    = 0
    private var fnTypes: [String: FnType] = [:]

    public var diagnostics: [String] = []

    // Closure bindings whose captured environment is entirely shareable.
    // Populated in emitBinding; consulted in the spawn capture check.
    private var shareableClosureBindings: Set<String> = []

    // Set while emitting an actor handler function body so that early returns
    // write back field locals and release the actor's mutex before returning.
    private struct HandlerCtx {
        let fields: [ActorField]
        let actorName: String
    }
    private var handlerCtx: HandlerCtx? = nil

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
        // Forward-declare functions so hoisted closure/spawn thunks (and mutual calls) resolve.
        for decl in program.decls {
            if case .funcDecl(let f) = decl { emitFuncProto(f) }
        }
        out += "\n"
        // Marker where hoisted closure/spawn definitions get spliced in (after protos, before funcs).
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
        out += "// ===== class \(c.name) =====\n"
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

    // Actors are mutex-protected objects. Each handler becomes a blocking call that
    // locks the actor's mutex, runs the handler body under it, writes fields back,
    // unlocks, and returns — serializing all callers automatically (non-reentrant).
    private mutating func emitActor(_ a: ActorDecl) {
        let name = a.name

        // Actor struct: fields + a single mutex for serialization.
        out += "// ===== actor \(name) =====\n"
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in a.fields { out += "    \(cType(f.type.name)) \(f.name);\n" }
        out += "    pthread_mutex_t mu;\n"
        out += "} \(name);\n\n"

        // One blocking call function per handler.
        for h in a.handlers { emitHandlerFunc(h, actor: a) }

        // Constructor — fields with initializers don't appear as parameters.
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
        out += "    pthread_mutex_init(&self->mu, NULL);\n"
        out += "    return self;\n"
        out += "}\n\n"

        out += "static void \(name)_deinit(\(name)* self) {\n"
        out += "    pthread_mutex_destroy(&self->mu);\n"
        out += "}\n\n"

        out += "static void \(name)_release(\(name)* self) {\n"
        out += "    if (self && --self->header.refcount == 0) {\n"
        out += "        \(name)_deinit(self);\n"
        out += "        free(self);\n"
        out += "    }\n"
        out += "}\n\n"
    }

    // Emits a blocking handler function. The caller locks the actor's mutex and runs
    // the handler body inline; concurrent callers block on the mutex (non-reentrant).
    private mutating func emitHandlerFunc(_ h: OnHandler, actor a: ActorDecl) {
        let retC = h.returnType.map { cType($0.name) } ?? "void"
        var sig = "\(a.name)* self"
        for p in h.params { sig += ", \(cType(p.type.name)) \(p.name)" }
        out += "static \(retC) \(a.name)_\(h.name)(\(sig)) {\n"
        out += "    pthread_mutex_lock(&self->mu);\n"

        // Copy actor fields to locals so the handler body can read/write them by name.
        var handlerScope: Scope = [:]
        for f in a.fields {
            out += "    \(cType(f.type.name)) \(f.name) = self->\(f.name);\n"
            handlerScope[f.name] = f.type.name
        }
        for p in h.params { handlerScope[p.name] = p.type.name }

        handlerCtx = HandlerCtx(fields: a.fields, actorName: a.name)
        emitBlock(h.body, scope: &handlerScope, ind: "    ")
        handlerCtx = nil

        // Fallthrough exit (reached when there is no early return).
        out += "// fall through exit when there is no early return\n"
        for f in a.fields { out += "    self->\(f.name) = \(f.name);\n" }
        out += "    pthread_mutex_unlock(&self->mu);\n"
        out += "}\n\n"
    }

    // MARK: - Functions

    private mutating func emitFuncProto(_ f: FuncDecl) {
        let cName = f.name == "main" ? "nomu_main" : f.name
        let ret   = f.returnType.map { cType($0.name) } ?? "void"
        let params = f.params.isEmpty
            ? "void"
            : f.params.map { "\(cType($0.type.name)) \($0.name)" }.joined(separator: ", ")
        out += "\(ret) \(cName)(\(params));\n"
    }

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
            guard let typeName = scope[key] else { continue }
            if spawnResultType(typeName) != nil {
                out += "\(ind)spawn_join(&\(key)__h);\n"   // structured: join before leaving scope
            } else if actors[typeName] != nil {
                out += "\(ind)\(typeName)_release(\(key));\n"
            }
        }
    }

    // MARK: - Statements

    private mutating func emitStmt(_ stmt: Stmt, scope: inout Scope, ind: String) {
        switch stmt {
        case .binding(let b):
            emitBinding(b, scope: &scope, ind: ind)
        case .spawnLet(let name, let type, let value, _):
            emitSpawnLet(name: name, type: type, value: value, scope: &scope, ind: ind)
        case .assign(let lhs, let rhs, _):
            // bind before appending: emitExpr may mutate `out` (closure hoisting), which
            // would overlap the `out +=` write.
            let l = emitExpr(lhs, scope: scope); let r = emitExpr(rhs, scope: scope)
            out += "\(ind)\(l) = \(r);\n"
        case .compoundAssign(let lhs, let rhs, _):
            let l = emitExpr(lhs, scope: scope); let r = emitExpr(rhs, scope: scope)
            out += "\(ind)\(l) += \(r);\n"
        case .ret(let e, _):
            // Structured guarantee: join all active spawns before leaving the function.
            for key in scope.keys.sorted() {
                if spawnResultType(scope[key]) != nil {
                    out += "\(ind)spawn_join(&\(key)__h);\n"
                }
            }
            // Actor handler: write fields back and release the mutex before returning.
            if let ctx = handlerCtx {
                for f in ctx.fields { out += "\(ind)self->\(f.name) = \(f.name);\n" }
                out += "\(ind)pthread_mutex_unlock(&self->mu);\n"
            }
            if let e { let v = emitExpr(e, scope: scope); out += "\(ind)return \(v);\n" }
            else { out += "\(ind)return;\n" }
        case .ifStmt(let s):
            emitIf(s, scope: &scope, ind: ind)
        case .switchStmt(let sw):
            emitSwitch(sw, scope: &scope, ind: ind)
        case .expr(let e):
            let v = emitExpr(e, scope: scope)
            out += "\(ind)\(v);\n"
        }
    }

    private mutating func emitBinding(_ b: BindingStmt, scope: inout Scope, ind: String) {
        let typeName = b.type?.name ?? typeOf(b.value, scope: scope)
        scope[b.name] = typeName
        // A closure-bound name needs its signature registered for later call-site casts.
        // Also record whether its captures are all shareable — closures are shareable iff
        // their captured environment is (design: concurrency.md §6).
        if case .closure(let ps, let r, let body, _) = b.value {
            fnTypes[typeName] = FnType(params: ps.map { $0.type }, ret: r)
            var bound = Set(ps.map(\.name))
            var used: [String] = []
            collectUsesBlock(body, bound: &bound, used: &used)
            var seen = Set<String>()
            let caps = used.filter { scope[$0] != nil && seen.insert($0).inserted }
            let allShareable = caps.allSatisfy { cap in
                let t = spawnResultType(scope[cap]) ?? scope[cap]!
                return isShareableBinding(cap, type: t)
            }
            if allShareable { shareableClosureBindings.insert(b.name) }
        }
        let value = emitInit(b.value, as: typeName, scope: scope)
        out += "\(ind)\(cType(typeName)) \(b.name) = \(value);\n"
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
            emitBlock(arm.body, scope: &inner, ind: ind + "        ")
            out += "\(ind)        break;\n"
            out += "\(ind)    }\n"
        }
        out += "\(ind)}\n"
    }

    // MARK: - Expressions

    // Returns an expression string usable anywhere a C rvalue is expected.
    private mutating func emitExpr(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit(let v, _):        return "\(v)"
        case .boolLit(let v, _):       return v ? "1" : "0"
        case .stringLit(let v, _):     return "rt_str_lit(\(cStringLiteral(v)), \(v.utf8.count))"
        case .ident(let n, _):
            // Reading a spawn-bound name joins its thread (idempotent) and yields the result.
            if let rt = spawnResultType(scope[n]) {
                return "(*(\(cType(rt))*)spawn_join(&\(n)__h))"
            }
            return n
        case .member(let base, let field, _):
            let bt = typeOf(base, scope: scope)
            let op = (classes[bt] != nil || actors[bt] != nil) ? "->" : "."
            return "\(emitExpr(base, scope: scope))\(op)\(field)"
        case .binary(let op, let lhs, let rhs, _):
            return "(\(emitExpr(lhs, scope: scope)) \(cOp(op)) \(emitExpr(rhs, scope: scope)))"
        case .call(let callee, let args, _):
            return emitCall(callee: callee, args: args, scope: scope)
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
        // Actor method call: c.handlerName(args) → ActorType_handlerName(c, args...)
        if case .member(let base, let handlerName, _) = callee,
           case .ident(let actorVar, _) = base,
           let actorType = scope[actorVar],
           let ad = actors[actorType],
           let handler = ad.handlers.first(where: { $0.name == handlerName }) {
            for p in handler.params where !isShareable(p.type.name) {
                diagnostics.append("error: actor handler '\(handlerName)' parameter '\(p.name)' has type '\(p.type.name)' which cannot cross a task boundary — only value types are shareable")
            }
            let argVals = emitArgs(args, scope: scope)
            return "\(actorType)_\(handlerName)(\(([actorVar] + argVals).joined(separator: ", ")))"
        }

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
            if args.isEmpty { return "printf(\"\\n\")" }
            let argExpr = args[0].value
            let arg = emitExpr(argExpr, scope: scope)
            if typeOf(argExpr, scope: scope) == "String" {
                return "printf(\"%.*s\\n\", (int)(\(arg)).len, (\(arg)).data)"
            }
            return "printf(\"%lld\\n\", (long long)(\(arg)))"
        }
        if name == "readLine" {
            return "rt_read_line(0)"
        }
        if name == "concat" {
            let a = args.count > 0 ? emitExpr(args[0].value, scope: scope) : "rt_str_lit(\"\", 0)"
            let b = args.count > 1 ? emitExpr(args[1].value, scope: scope) : "rt_str_lit(\"\", 0)"
            return "rt_str_concat(\(a), \(b))"
        }
        // `sleep(ms)` — a prototype builtin (usleep/nanosleep), returns the ms slept.
        // Lets us observe real concurrent timing; not a committed language/stdlib API.
        if name == "sleep" {
            let arg = args.isEmpty ? "0" : emitExpr(args[0].value, scope: scope)
            return "rt_sleep_ms(\(arg))"
        }
        if structs[name] != nil { return structLiteral(name: name, args: args, scope: scope) }
        if let cd = classes[name] {
            return "\(name)_new(\(emitLabeled(cd.fields.map(\.name), args, scope: scope).joined(separator: ", ")))"
        }
        if let ad = actors[name] {
            let labels = ad.fields.filter { $0.initializer == nil }.map(\.name)
            return "\(name)_new(\(emitLabeled(labels, args, scope: scope).joined(separator: ", ")))"
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
        case .spawnLet(let name, _, let value, _):
            collectUsesExpr(value, bound: bound, used: &used)
            bound.insert(name)
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
        }
    }

    private func collectUsesExpr(_ e: Expr, bound: Set<String>, used: inout [String]) {
        switch e {
        case .intLit, .boolLit, .stringLit: break
        case .ident(let n, _): if !bound.contains(n) { used.append(n) }
        case .member(let base, _, _): collectUsesExpr(base, bound: bound, used: &used)
        case .call(let callee, let args, _):
            collectUsesExpr(callee, bound: bound, used: &used)
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .binary(_, let l, let r, _):
            collectUsesExpr(l, bound: bound, used: &used)
            collectUsesExpr(r, bound: bound, used: &used)
        case .closure(let ps, _, let cbody, _):
            var nb = bound
            for p in ps { nb.insert(p.name) }
            collectUsesBlock(cbody, bound: &nb, used: &used)
        }
    }

    // MARK: - Structured spawn

    private mutating func emitSpawnLet(name: String, type: TypeRef?, value: Expr, scope: inout Scope, ind: String) {
        let rt = type?.name ?? typeOf(value, scope: scope)
        let (thunk, envName, caps) = emitSpawnThunk(value: value, resultType: rt, scope: scope)

        // Site: allocate the env, copy captures by value, start the thread.
        out += "\(ind)\(envName)* \(name)__e = (\(envName)*)rt_alloc(sizeof(\(envName)));\n"
        for c in caps { out += "\(ind)\(name)__e->\(c) = \(c);\n" }
        out += "\(ind)SpawnHandle \(name)__h; \(name)__h.fiber = fiber_spawn(\(thunk), \(name)__e);\n"
        scope[name] = "spawn \(rt)"   // reads of `name` join and yield `rt`
    }

    // Closure-convert `value` into a pthread start routine returning a boxed result.
    private mutating func emitSpawnThunk(value: Expr, resultType: String, scope: Scope) -> (String, String, [String]) {
        let idx = spawnSeq; spawnSeq += 1
        let name    = "nomu_spawn\(idx)"
        let envName = "\(name)_env"

        var used: [String] = []
        collectUsesExpr(value, bound: [], used: &used)
        var seen = Set<String>()
        let caps = used.filter { scope[$0] != nil && seen.insert($0).inserted }

        for cap in caps {
            let typeName = spawnResultType(scope[cap]) ?? scope[cap]!
            if !isShareableBinding(cap, type: typeName) {
                diagnostics.append("error: '\(cap)' has type '\(typeName)' which cannot cross a task boundary — only value types and closures with shareable captures are shareable")
            }
        }

        var def = "typedef struct {\n"
        if caps.isEmpty {
            def += "    char _empty;\n"
        } else {
            for c in caps { def += "    \(cType(scope[c]!)) \(c);\n" }
        }
        def += "} \(envName);\n\n"

        let rc = cType(resultType)
        def += "static void* \(name)(void* __envv) {\n"
        def += "    \(envName)* __env = (\(envName)*)__envv;\n"
        var cscope: Scope = [:]
        for c in caps {
            def += "    \(cType(scope[c]!)) \(c) = __env->\(c);\n"
            cscope[c] = scope[c]
        }
        let v = emitExpr(value, scope: cscope)
        def += "    \(rc)* __box = (\(rc)*)rt_alloc(sizeof(\(rc)));\n"
        def += "    *__box = \(v);\n"
        def += "    return __box;\n"
        def += "}\n\n"
        closureDefs += def
        return (name, envName, caps)
    }

    // A type is shareable if it can safely cross a task boundary.
    // Primitives and value types (structs, enums) are shareable by construction.
    // Actor handles are shareable — they are self-synchronizing (mutex-protected).
    // Classes are task-local. Closures are conditionally shareable, checked per-binding.
    private func isShareable(_ typeName: String) -> Bool {
        if typeName == "Int" || typeName == "Bool" { return true }
        if structs[typeName] != nil { return true }
        if enums[typeName]   != nil { return true }
        if actors[typeName]  != nil { return true }
        return false   // classes: task-local
    }

    // Whether a named binding is shareable, accounting for closures whose
    // captures are all shareable (see emitBinding).
    private func isShareableBinding(_ name: String, type typeName: String) -> Bool {
        if isShareable(typeName) { return true }
        return shareableClosureBindings.contains(name)
    }

    // A spawn binding stores its type in the scope as "spawn <resultType>".
    private func spawnResultType(_ s: String?) -> String? {
        guard let s, s.hasPrefix("spawn ") else { return nil }
        return String(s.dropFirst("spawn ".count))
    }

    // MARK: - Type resolution

    private func typeOf(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit:               return "Int"
        case .boolLit:              return "Bool"
        case .stringLit:            return "String"
        case .ident(let n, _):
            let t = scope[n] ?? ""
            return spawnResultType(t) ?? t   // a spawn binding resolves to its result type
        case .member(let base, let field, _):
            let bt = typeOf(base, scope: scope)
            return structs[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? classes[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? actors[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? ""
        case .call(let callee, _, _):
            // Actor method call: look up the handler's declared return type.
            if case .member(let base, let handlerName, _) = callee,
               case .ident(let actorVar, _) = base,
               let actorType = scope[actorVar],
               let ad = actors[actorType],
               let handler = ad.handlers.first(where: { $0.name == handlerName }) {
                return handler.returnType?.name ?? ""
            }
            guard case .ident(let n, _) = callee else { return "" }
            if n == "sleep"    { return "Int" }
            if n == "concat"   { return "String" }
            if n == "readLine" { return "String" }
            if structs[n] != nil || enums[n] != nil || classes[n] != nil || actors[n] != nil { return n }
            return funcs[n]?.returnType?.name ?? ""
        case .binary:   return "Int"
        case .closure(let params, let ret, _, _):
            return "(" + params.map { $0.type.name }.joined(separator: ", ") + ") -> " + (ret?.name ?? "Void")
        }
    }

    // MARK: - C helpers

    private func cType(_ name: String) -> String {
        switch name {
        case "Int", "Bool": return "int64_t"
        case "String":      return "String"
        default:
            if fnTypes[name] != nil || name.contains(" -> ") { return "Closure" }
            return (classes[name] != nil || actors[name] != nil) ? "\(name)*" : name
        }
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

    // MARK: - Preamble and entry point

    private mutating func emitPreamble() {
        out += """
        #define _XOPEN_SOURCE 600
        #define _DARWIN_C_SOURCE
        #include <stdio.h>
        #include <stdlib.h>
        #include <stdint.h>
        #include <string.h>
        #include <pthread.h>
        #include <time.h>
        #include <unistd.h>
        #include <ucontext.h>
        #ifdef __APPLE__
        #include <sys/event.h>
        #endif

        typedef struct { size_t refcount; } ObjectHeader;
        static inline void* rt_alloc(size_t size) {
            void* p = calloc(1, size);
            if (!p) { fputs("out of memory\\n", stderr); exit(1); }
            ((ObjectHeader*)p)->refcount = 1;
            return p;
        }

        // A closure value: code pointer + captured environment (heap-allocated, bump-and-leak).
        typedef struct { void* fn; void* env; } Closure;

        // String: length-prefixed, null-terminated, heap-allocated data.
        typedef struct { char* data; int64_t len; } String;
        static String rt_str_lit(const char* data, int64_t len) {
            return (String){ .data = (char*)data, .len = len };
        }
        static String rt_str_concat(String a, String b) {
            int64_t len = a.len + b.len;
            char* data = (char*)rt_alloc(sizeof(ObjectHeader) + len + 1) + sizeof(ObjectHeader);
            memcpy(data, a.data, (size_t)a.len);
            memcpy(data + a.len, b.data, (size_t)b.len);
            data[len] = '\\0';
            return (String){ .data = data, .len = len };
        }

        // ---- Fiber scheduler (M4.5: multi-carrier, idle sleep, fiber-aware timer) ----
        #define RT_MAX_FIBERS 256
        #define RT_MAX_CARRIERS 16
        #define RT_STACK_SIZE (128 * 1024)

        typedef enum { FIBER_RUNNABLE, FIBER_PARKED, FIBER_DONE } FiberStatus;
        typedef struct Fiber {
            ucontext_t ctx;
            char* stack;
            FiberStatus status;
            void* result;
            struct Fiber* joiner;
            void* (*fn)(void*);
            void* arg;
        } Fiber;

        static Fiber* rt_run_queue[RT_MAX_FIBERS];
        static int rt_rq_head = 0, rt_rq_tail = 0;
        static int rt_active = 0;
        static pthread_mutex_t rt_queue_mu = PTHREAD_MUTEX_INITIALIZER;
        static pthread_cond_t rt_queue_cond = PTHREAD_COND_INITIALIZER;
        static _Thread_local Fiber* rt_current = NULL;
        static _Thread_local ucontext_t rt_sched_ctx;

        // Must be called with rt_queue_mu held. Signals a sleeping carrier.
        static void rt_rq_push(Fiber* f) {
            rt_run_queue[rt_rq_tail % RT_MAX_FIBERS] = f;
            rt_rq_tail++;
            pthread_cond_signal(&rt_queue_cond);
        }
        // Must be called with rt_queue_mu held.
        static Fiber* rt_rq_pop(void) {
            if (rt_rq_head == rt_rq_tail) return NULL;
            Fiber* f = rt_run_queue[rt_rq_head % RT_MAX_FIBERS];
            rt_rq_head++;
            return f;
        }

        static void rt_fiber_trampoline(void) {
            Fiber* self = rt_current;
            self->result = self->fn(self->arg);
            pthread_mutex_lock(&rt_queue_mu);
            self->status = FIBER_DONE;
            rt_active--;
            if (self->joiner) { rt_rq_push(self->joiner); self->joiner = NULL; }
            pthread_cond_broadcast(&rt_queue_cond); // wake all carriers to re-check rt_active == 0
            pthread_mutex_unlock(&rt_queue_mu);
            swapcontext(&self->ctx, &rt_sched_ctx);
        }

        static Fiber* fiber_spawn(void* (*fn)(void*), void* arg) {
            Fiber* f = (Fiber*)calloc(1, sizeof(Fiber));
            f->stack = (char*)malloc(RT_STACK_SIZE);
            f->fn = fn; f->arg = arg; f->status = FIBER_RUNNABLE;
            getcontext(&f->ctx);
            f->ctx.uc_stack.ss_sp = f->stack;
            f->ctx.uc_stack.ss_size = RT_STACK_SIZE;
            f->ctx.uc_link = NULL;
            makecontext(&f->ctx, rt_fiber_trampoline, 0);
            pthread_mutex_lock(&rt_queue_mu);
            rt_active++;
            rt_rq_push(f);
            pthread_mutex_unlock(&rt_queue_mu);
            return f;
        }

        static void rt_scheduler_run(void) {
            pthread_mutex_lock(&rt_queue_mu);
            while (1) {
                Fiber* f = rt_rq_pop();
                if (f) {
                    pthread_mutex_unlock(&rt_queue_mu);
                    rt_current = f;
                    swapcontext(&rt_sched_ctx, &f->ctx);
                    pthread_mutex_lock(&rt_queue_mu);
                } else if (rt_active == 0) {
                    break;
                } else {
                    pthread_cond_wait(&rt_queue_cond, &rt_queue_mu);
                }
            }
            pthread_mutex_unlock(&rt_queue_mu);
        }

        static void* rt_carrier_entry(void* _) { rt_scheduler_run(); return NULL; }

        // A structured spawn handle: a fiber whose result we will join.
        typedef struct { Fiber* fiber; } SpawnHandle;
        static void* spawn_join(SpawnHandle* h) {
            pthread_mutex_lock(&rt_queue_mu);
            if (h->fiber->status != FIBER_DONE) {
                h->fiber->joiner = rt_current;
                rt_current->status = FIBER_PARKED;
                pthread_mutex_unlock(&rt_queue_mu);
                swapcontext(&rt_current->ctx, &rt_sched_ctx);
            } else {
                pthread_mutex_unlock(&rt_queue_mu);
            }
            return h->fiber->result;
        }

        // ---- Timer heap (M4.5) ----
        #define RT_MAX_TIMERS 256
        typedef struct { uint64_t expiry_ns; Fiber* fiber; } TimerEntry;
        static TimerEntry rt_timers[RT_MAX_TIMERS];
        static int rt_timer_count = 0;
        static pthread_mutex_t rt_timer_mu = PTHREAD_MUTEX_INITIALIZER;
        static pthread_cond_t rt_timer_cond = PTHREAD_COND_INITIALIZER;

        static uint64_t rt_now_ns(void) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
        }

        // Min-heap helpers — must be called with rt_timer_mu held.
        static void rt_timer_push(uint64_t expiry, Fiber* f) {
            int i = rt_timer_count++;
            rt_timers[i] = (TimerEntry){ expiry, f };
            while (i > 0) {
                int p = (i - 1) / 2;
                if (rt_timers[p].expiry_ns <= rt_timers[i].expiry_ns) break;
                TimerEntry tmp = rt_timers[p]; rt_timers[p] = rt_timers[i]; rt_timers[i] = tmp;
                i = p;
            }
            pthread_cond_signal(&rt_timer_cond);
        }
        static void rt_timer_pop(void) {
            rt_timers[0] = rt_timers[--rt_timer_count];
            int i = 0;
            while (1) {
                int l = 2*i+1, r = 2*i+2, s = i;
                if (l < rt_timer_count && rt_timers[l].expiry_ns < rt_timers[s].expiry_ns) s = l;
                if (r < rt_timer_count && rt_timers[r].expiry_ns < rt_timers[s].expiry_ns) s = r;
                if (s == i) break;
                TimerEntry tmp = rt_timers[s]; rt_timers[s] = rt_timers[i]; rt_timers[i] = tmp;
                i = s;
            }
        }

        static void* rt_timer_thread(void* _) {
            pthread_mutex_lock(&rt_timer_mu);
            while (1) {
                if (rt_timer_count == 0) {
                    pthread_cond_wait(&rt_timer_cond, &rt_timer_mu);
                    continue;
                }
                uint64_t now = rt_now_ns();
                uint64_t next = rt_timers[0].expiry_ns;
                if (next > now) {
                    struct timespec ts = { (time_t)(next / 1000000000ULL), (long)(next % 1000000000ULL) };
                    pthread_cond_timedwait(&rt_timer_cond, &rt_timer_mu, &ts);
                    continue;
                }
                Fiber* f = rt_timers[0].fiber;
                rt_timer_pop();
                pthread_mutex_unlock(&rt_timer_mu);
                pthread_mutex_lock(&rt_queue_mu);
                rt_rq_push(f);
                pthread_mutex_unlock(&rt_queue_mu);
                pthread_mutex_lock(&rt_timer_mu);
            }
            return NULL;
        }

        static int64_t rt_sleep_ms(int64_t ms) {
            uint64_t expiry = rt_now_ns() + (uint64_t)ms * 1000000ULL;
            pthread_mutex_lock(&rt_timer_mu);
            rt_timer_push(expiry, rt_current);
            pthread_mutex_unlock(&rt_timer_mu);
            rt_current->status = FIBER_PARKED;
            swapcontext(&rt_current->ctx, &rt_sched_ctx);
            return ms;
        }

        // ---- I/O poller (M4.4: kqueue, fiber-aware fd readiness) ----
        #ifdef __APPLE__
        static int rt_kq = -1;

        static void rt_wait_readable(int fd) {
            struct kevent ev;
            EV_SET(&ev, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, rt_current);
            kevent(rt_kq, &ev, 1, NULL, 0, NULL);
            rt_current->status = FIBER_PARKED;
            swapcontext(&rt_current->ctx, &rt_sched_ctx);
        }

        static void* rt_poller_thread(void* _) {
            struct kevent events[32];
            while (1) {
                int n = kevent(rt_kq, NULL, 0, events, 32, NULL);
                for (int i = 0; i < n; i++) {
                    Fiber* f = (Fiber*)events[i].udata;
                    pthread_mutex_lock(&rt_queue_mu);
                    rt_rq_push(f);
                    pthread_mutex_unlock(&rt_queue_mu);
                }
            }
            return NULL;
        }

        static String rt_read_line(int fd) {
            rt_wait_readable(fd);
            char buf[4096];
            ssize_t n = read(fd, buf, sizeof(buf) - 1);
            if (n <= 0) return rt_str_lit("", 0);
            if (buf[n - 1] == '\\n') n--;
            char* data = (char*)rt_alloc(sizeof(ObjectHeader) + (size_t)n + 1) + sizeof(ObjectHeader);
            memcpy(data, buf, (size_t)n);
            data[n] = '\\0';
            return (String){ .data = data, .len = (int64_t)n };
        }
        #endif

        /// ====== END PREAMBLE ======

        """
    }

    private mutating func emitCMain() {
        out += """
        static void* __rt_main_entry(void* _) { nomu_main(); return NULL; }
        int main(void) {
            #ifdef __APPLE__
            rt_kq = kqueue();
            pthread_t __poller_t; pthread_create(&__poller_t, NULL, rt_poller_thread, NULL); pthread_detach(__poller_t);
            #endif
            pthread_t __timer_t; pthread_create(&__timer_t, NULL, rt_timer_thread, NULL); pthread_detach(__timer_t);
            int ncarriers = 4; // parallelism knob — will be configurable later
            fiber_spawn(__rt_main_entry, NULL);
            for (int i = 1; i < ncarriers; i++) {
                pthread_t t; pthread_create(&t, NULL, rt_carrier_entry, NULL); pthread_detach(t);
            }
            rt_scheduler_run();
            return 0;
        }
        """
    }
}
