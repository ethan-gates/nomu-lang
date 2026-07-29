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
    private var interfaceDefs: [String: IRInterface] = [:]   // M5 A1.4: witness-table layout
    private var conformances: [IRConformance] = []           // M5 A1.4: one witness instance each
    private var composites: [IRComposite] = []               // M5 A1.5b: composite (any A & B) witnesses

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

    // The generic parameters of the function whose body is being emitted (M5 5.2.2), so a
    // requirement call on a `.typeParam` receiver dispatches through the right witness param.
    private var currentGenerics: [IRGenericParam] = []

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
        for i in module.interfaces { interfaceDefs[i.name] = i }
        conformances = module.conformances
        composites = module.composites
    }

    public mutating func emit() -> String {
        // The runtime/core C and the `int main` entry live in their own translation
        // units (src/runtime/*, compiled beside this by the driver); generated code
        // reaches them through the shared ABI header (M4.13).
        out += "#include \"runtime.h\"\n\n"
        // `any I` box: a witness-table pointer + a payload pointer (M5 A1.4). Defined
        // before user types so any-typed fields resolve.
        out += "typedef struct { const void* witness; void* payload; } AnyBox;\n\n"
        // Type declarations first — closure env structs may reference user types.
        for decl in module.decls {
            if case .funcDecl = decl { continue }
            emitTopDecl(decl)
        }
        // Forward-declare methods so witness thunks and bodies resolve.
        for decl in module.decls { emitMethodProtos(decl) }
        // Witness-table types, thunks, and per-conformance instances — before function protos
        // (a generic function's proto names a witness type) and bodies (which box/dispatch).
        emitWitnessTables()
        out += "\n"
        for decl in module.decls {
            if case .funcDecl(let f) = decl { emitFuncProto(f) }
        }
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
        out += "} \(Mangle.type(s.name));\n\n"
    }

    private mutating func emitEnum(_ e: IREnum) {
        let tags = e.cases.map { Mangle.tag(e.name, $0.name) }.joined(separator: ", ")
        out += "typedef enum { \(tags) } \(Mangle.tagType(e.name));\n"
        out += "typedef struct {\n"
        out += "    \(Mangle.tagType(e.name)) tag;\n"
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
        out += "} \(Mangle.type(e.name));\n\n"
    }

    private mutating func emitClass(_ c: IRClass) {
        // Reference type under bump-and-leak: heap-allocated, never freed (no GC yet).
        out += "// ===== class \(c.name) =====\n"
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in c.fields { out += "    \(cType(f.type)) \(f.name);\n" }
        let cn = Mangle.type(c.name)
        out += "} \(cn);\n\n"

        let ctorParams = c.fields.isEmpty
            ? "void"
            : c.fields.map { "\(cType($0.type)) \($0.name)" }.joined(separator: ", ")
        out += "static \(cn)* \(Mangle.ctor(c.name))(\(ctorParams)) {\n"
        out += "    \(cn)* self = (\(cn)*)rt_alloc(sizeof(\(cn)));\n"
        for f in c.fields { out += "    self->\(f.name) = \(f.name);\n" }
        out += "    return self;\n"
        out += "}\n\n"
    }

    // MARK: - Actors

    // Mutex-protected objects: each handler becomes a blocking call that locks,
    // runs the body under the lock, writes fields back, unlocks (see slice 2/4).
    private mutating func emitActor(_ a: IRActor) {
        let name = a.name
        let cn = Mangle.type(name)

        out += "// ===== actor \(name) =====\n"
        out += "typedef struct {\n"
        out += "    ObjectHeader header;\n"
        for f in a.fields { out += "    \(cType(f.type)) \(f.name);\n" }
        out += "    pthread_mutex_t mu;\n"
        out += "} \(cn);\n\n"

        for h in a.handlers { emitHandlerFunc(h, actor: a) }

        // Constructor — fields with initializers don't appear as parameters.
        let ctorFields = a.fields.filter { $0.initializer == nil }
        let ctorParams = ctorFields.isEmpty
            ? "void"
            : ctorFields.map { "\(cType($0.type)) \($0.name)" }.joined(separator: ", ")
        out += "static \(cn)* \(Mangle.ctor(name))(\(ctorParams)) {\n"
        out += "    \(cn)* self = (\(cn)*)rt_alloc(sizeof(\(cn)));\n"
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

        out += "static void \(Mangle.deinitFn(name))(\(cn)* self) {\n"
        out += "    pthread_mutex_destroy(&self->mu);\n"
        out += "}\n\n"

        out += "static void \(Mangle.release(name))(\(cn)* self) {\n"
        out += "    if (self && --self->header.refcount == 0) {\n"
        out += "        \(Mangle.deinitFn(name))(self);\n"
        out += "        rt_free(self);\n"
        out += "    }\n"
        out += "}\n\n"
    }

    private mutating func emitHandlerFunc(_ h: IRHandler, actor a: IRActor) {
        let retC = cType(h.returnType)
        var sig = "\(Mangle.type(a.name))* self"
        for p in h.params { sig += ", \(cType(p.type)) \(p.name)" }
        out += "static \(retC) \(Mangle.method(a.name, h.name))(\(sig)) {\n"
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
        let cName = Mangle.function(f.name)
        out += "\(cType(f.returnType)) \(cName)(\(fullParamList(f)));\n"
    }

    private mutating func emitFunc(_ f: IRFunc) {
        let cName = Mangle.function(f.name)
        let savedG = currentGenerics; currentGenerics = f.generics; defer { currentGenerics = savedG }
        out += "\(cType(f.returnType)) \(cName)(\(fullParamList(f))) {\n"
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

    // A generic function's C parameters: its value parameters (a `.typeParam` value is `void*`),
    // then one witness-table pointer per (type parameter, bound) — the witness-passing ABI (M5 5.2.2).
    private func fullParamList(_ f: IRFunc) -> String {
        var parts = f.params.map { "\(cType($0.type)) \($0.name)" }
        for g in f.generics { for b in g.bounds { parts.append("const \(Mangle.witnessType(b))* \(witnessParamName(g.name, b))") } }
        return parts.isEmpty ? "void" : parts.joined(separator: ", ")
    }

    private func witnessParamName(_ tp: String, _ iface: String) -> String { "wt_\(tp)_\(iface)" }

    // The bound interface of type parameter `tp` that declares `method` (a requirement name or
    // `prop.get`/`prop.set`), so codegen picks the right witness param (M5 5.2.2).
    private func boundIface(for tp: String, method: String) -> String? {
        guard let g = currentGenerics.first(where: { $0.name == tp }) else { return nil }
        for b in g.bounds {
            guard let i = interfaceDefs[b] else { continue }
            if i.methods.contains(where: { $0.name == method }) { return b }
            if i.properties.contains(where: { "\($0.name).get" == method || "\($0.name).set" == method }) { return b }
        }
        return g.bounds.first
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
        out += "static \(cType(m.returnType)) \(Mangle.method(typeName, m.name))(\(methodSig(m, typeName, kind)));\n"
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
        let selfC = selfIsPointerMethod(m, kind) ? "\(Mangle.type(typeName))*" : Mangle.type(typeName)
        var sig = "\(selfC) self"
        for p in m.params { sig += ", \(cType(p.type)) \(p.name)" }
        return sig
    }

    private mutating func emitMethodFunc(_ m: IRFunc, typeName: String, kind: NamedKind, fields: [IRField]) {
        let pointerSelf = selfIsPointerMethod(m, kind)
        let op = pointerSelf ? "->" : "."
        out += "static \(cType(m.returnType)) \(Mangle.method(typeName, m.name))(\(methodSig(m, typeName, kind))) {\n"
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

    // MARK: - Witness tables (M5 A1.4)

    // Per interface (that has conformers): a struct of function pointers — one slot per
    // method requirement, get/set slots per property requirement, and a reserved
    // type-witness slot for future associated types. Then, per conformance, uniform-
    // signature thunks (self as void*) wrapping the concrete impls, and one instance.
    private mutating func emitWitnessTables() {
        let used = Set(conformances.map(\.interfaceName))
        for i in module.interfaces where used.contains(i.name) { emitWitnessType(i) }
        // Emit instances bases-first: a witness sets base pointers to its base witnesses, which
        // must already be defined. An interface's transitive-base count is a valid topo rank.
        let ordered = conformances.sorted { (interfaceDefs[$0.interfaceName]?.bases.count ?? 0) < (interfaceDefs[$1.interfaceName]?.bases.count ?? 0) }
        for c in ordered {
            guard let i = interfaceDefs[c.interfaceName] else { continue }
            emitWitnessInstance(c, i)
        }
        emitCompositeWitnesses()
    }

    // A composite witness struct per distinct `any A & B` (one witness-table pointer per
    // interface), then an instance per boxed type referencing the single-interface
    // witnesses (already emitted, since T conforms to each) (M5 A1.5b).
    private mutating func emitCompositeWitnesses() {
        var emittedTypes = Set<String>()
        for c in composites {
            let key = c.interfaces.joined(separator: "&")
            if emittedTypes.insert(key).inserted {
                out += "typedef struct {\n"
                for i in c.interfaces { out += "    const \(Mangle.witnessType(i))* \(i);\n" }
                out += "} \(Mangle.compositeType(c.interfaces));\n\n"
            }
        }
        for c in composites {
            out += "static const \(Mangle.compositeType(c.interfaces)) \(Mangle.compositeInstance(c.typeName, c.interfaces)) = {\n"
            for i in c.interfaces { out += "    .\(i) = &\(Mangle.witnessInstance(c.typeName, i)),\n" }
            out += "};\n\n"
        }
    }

    // Which interface of a composition owns `method` (a requirement name, or `prop.get`).
    private func compositionOwner(_ ifaces: [String], _ method: String) -> String {
        for i in ifaces {
            guard let def = interfaceDefs[i] else { continue }
            if def.methods.contains(where: { $0.name == method }) { return i }
            if def.properties.contains(where: { "\($0.name).get" == method || "\($0.name).set" == method }) { return i }
        }
        return ifaces.first ?? "?"
    }

    private mutating func emitWitnessType(_ i: IRInterface) {
        out += "typedef struct {\n"
        for m in i.methods {
            var params = "void*"
            for pt in m.params { params += ", \(cType(pt))" }
            out += "    \(cType(m.ret)) (*\(m.name))(\(params));\n"
        }
        for p in i.properties {
            out += "    \(cType(p.type)) (*\(p.name)_get)(void*);\n"
            if p.isSettable { out += "    void (*\(p.name)_set)(void*, \(cType(p.type)));\n" }
        }
        // One pointer per transitive base, so `any I` widens to `any Base` by reading the slot.
        for b in i.bases { out += "    const void* base_\(b);\n" }
        out += "    const void* type_witness;\n"
        out += "} \(Mangle.witnessType(i.name));\n\n"
    }

    private mutating func emitWitnessInstance(_ c: IRConformance, _ i: IRInterface) {
        let t = c.typeName, kind = c.typeKind, iface = i.name
        for m in i.methods { emitMethodThunk(t, kind, iface, m) }
        for p in i.properties { emitPropertyThunks(t, kind, iface, p) }

        out += "static const \(Mangle.witnessType(iface)) \(Mangle.witnessInstance(t, iface)) = {\n"
        for m in i.methods { out += "    .\(m.name) = \(Mangle.witnessThunk(t, iface, m.name)),\n" }
        for p in i.properties {
            out += "    .\(p.name)_get = \(Mangle.witnessThunk(t, iface, "\(p.name)_get")),\n"
            if p.isSettable { out += "    .\(p.name)_set = \(Mangle.witnessThunk(t, iface, "\(p.name)_set")),\n" }
        }
        // Base pointers reference this same conformer's base witnesses (emitted earlier, since
        // instances are ordered bases-first), so an `any I` box can widen to `any Base`.
        for b in i.bases { out += "    .base_\(b) = &\(Mangle.witnessInstance(t, b)),\n" }
        out += "    .type_witness = 0,\n};\n\n"
    }

    private mutating func emitMethodThunk(_ t: String, _ kind: NamedKind, _ iface: String, _ m: IRMethodReq) {
        var sig = "void* self"
        for (idx, pt) in m.params.enumerated() { sig += ", \(cType(pt)) a\(idx)" }
        out += "static \(cType(m.ret)) \(Mangle.witnessThunk(t, iface, m.name))(\(sig)) {\n"
        let selfArg = witnessSelfArg(t, kind, m.name)
        let argNames = (0..<m.params.count).map { "a\($0)" }
        let call = "\(Mangle.method(t, m.name))(\(([selfArg] + argNames).joined(separator: ", ")))"
        out += m.ret == .void ? "    \(call);\n" : "    return \(call);\n"
        out += "}\n"
    }

    // Getter (and setter, if the requirement is settable). A stored field reads/writes
    // directly; a computed property routes through its A1.1 accessor method.
    private mutating func emitPropertyThunks(_ t: String, _ kind: NamedKind, _ iface: String, _ p: IRPropReq) {
        let cast = "((\(Mangle.type(t))*)self)"
        let backedByField = typeFields(t, kind).contains { $0.name == p.name }
        out += "static \(cType(p.type)) \(Mangle.witnessThunk(t, iface, "\(p.name)_get"))(void* self) {\n"
        if backedByField {
            out += "    return \(cast)->\(p.name);\n"
        } else {
            out += "    return \(Mangle.method(t, "\(p.name).get"))(\(witnessSelfArg(t, kind, "\(p.name).get")));\n"
        }
        out += "}\n"
        if p.isSettable {
            out += "static void \(Mangle.witnessThunk(t, iface, "\(p.name)_set"))(void* self, \(cType(p.type)) a0) {\n"
            if backedByField {
                out += "    \(cast)->\(p.name) = a0;\n"
            } else {
                out += "    \(Mangle.method(t, "\(p.name).set"))(\(witnessSelfArg(t, kind, "\(p.name).set")), a0);\n"
            }
            out += "}\n"
        }
    }

    // How to hand `self` (a void* payload) to a concrete impl: class and mutating value
    // methods take a pointer; a read-only value method takes the value.
    private func witnessSelfArg(_ type: String, _ kind: NamedKind, _ method: String) -> String {
        let cast = "(\(Mangle.type(type))*)self"
        if kind == .class_ { return cast }
        if methodIsMutating(type, method) { return cast }
        return "(*\(cast))"
    }

    private func typeFields(_ name: String, _ kind: NamedKind) -> [IRField] {
        switch kind {
        case .struct_: return structs[name]?.fields ?? []
        case .class_:  return classes[name]?.fields ?? []
        default:       return []
        }
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
                out += "\(ind)\(Mangle.release(n))(\(l.name));\n"
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
            // Writing a `T` field overwrites the boxed slot with a freshly boxed value — this
            // works for value and reference `T` alike (the old box leaks; the M6 GC reclaims it).
            if case .fieldAccess(let base, let field) = target.kind, isBoxedGenericField(base.type, field) {
                let slot = rawMemberAccess(base, field)
                let boxed = boxGenericValue(value)
                out += "\(ind)\(slot) = \(boxed);\n"
            } else {
                // Bind before appending: emitExpr may mutate `out` (closure hoisting).
                let l = emitExpr(target); let r = emitExpr(value)
                out += "\(ind)\(l) = \(r);\n"
            }

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
        // A concrete enum (`.named`) or an applied generic one (`.generic`, M5 5.2.3) — both
        // switch on `.tag`; a generic enum's `T` payload fields are stored boxed.
        let enumName: String
        switch sw.subject.type {
        case .named(let n, .enum_):  enumName = n
        case .generic(let n, _):     enumName = n
        default:
            out += "\(ind)/* switch: non-enum subject */\n"; return
        }
        guard let ed = enums[enumName] else {
            out += "\(ind)/* switch: non-enum subject */\n"; return
        }
        out += "\(ind)switch (\(subj).tag) {\n"
        for arm in sw.arms {
            guard let cd = ed.cases.first(where: { $0.name == arm.caseName }) else { continue }
            out += "\(ind)    case \(Mangle.tag(enumName, arm.caseName)): {\n"
            pushScope()   // payload bindings live for the arm
            for (binding, field) in zip(arm.bindings, cd.fields) {
                let raw = "\(subj).payload.\(arm.caseName).\(field.name)"
                let rhs: String
                if case .typeParam = field.type { rhs = unboxGenericValue(raw, as: binding.type) } else { rhs = raw }
                out += "\(ind)        \(cType(binding.type)) \(binding.name) = \(rhs);\n"
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
            // Not a local or field → a top-level function referenced as a value.
            return Mangle.function(n)

        case .fieldAccess(let base, let field):
            let raw = rawMemberAccess(base, field)
            // A `T` field on a generic type is stored boxed (`void*`); read it back concretely (M5 5.2.3).
            if isBoxedGenericField(base.type, field) { return unboxGenericValue(raw, as: e.type) }
            return raw

        case .construct(let typeName, let args):
            return emitConstruct(typeName: typeName, args: args)

        case .enumInit(let typeName, let caseName, let args):
            return emitEnumInit(typeName: typeName, caseName: caseName, args: args)

        case .methodCall(let receiver, let method, let args):
            return emitMethodCall(receiver: receiver, method: method, args: args)

        case .call(let callee, let args, let typeArgs):
            return emitCall(callee: callee, args: args, typeArgs: typeArgs)

        case .binary(let op, let l, let r):
            return "(\(emitExpr(l)) \(cOp(op)) \(emitExpr(r)))"

        case .closure(let params, let body):
            var ret = Type.void
            if case .function(_, let r) = e.type { ret = r }
            return emitClosure(params: params, body: body, ret: ret)

        case .box(let value, let ifaces):
            return emitBox(value: value, interfaces: ifaces)
        }
    }

    // Wrap a concrete conformer as `any I` / `any A & B`: a value type is heap-boxed (a
    // copy that outlives the temporary); a reference type's pointer is the payload
    // directly. The witness is the single witness table, or — for a composition — the
    // composite witness struct holding one table pointer per interface.
    private mutating func emitBox(value: IRExpr, interfaces ifaces: [String]) -> String {
        // `any B` → `any A` upcast: re-box through the source witness's base pointer, keeping the
        // payload. The source is a single existential; the target is one base interface (M5 A1.4).
        if case .existential(let src) = value.type, ifaces.count == 1 {
            let box = emitExpr(value)
            return "({ AnyBox __b = \(box); (AnyBox){ .witness = ((const \(Mangle.witnessType(src))*)__b.witness)->base_\(ifaces[0]), .payload = __b.payload }; })"
        }
        let v = emitExpr(value)
        guard case .named(let t, let kind) = value.type else { return "/* box of non-nominal */" }
        let witness = ifaces.count == 1
            ? "&\(Mangle.witnessInstance(t, ifaces[0]))"
            : "&\(Mangle.compositeInstance(t, ifaces))"
        if kind == .class_ || kind == .actor_ {
            return "(AnyBox){ .witness = \(witness), .payload = (void*)\(v) }"
        }
        let ct = Mangle.type(t)
        return "({ \(ct)* __p = (\(ct)*)rt_alloc(sizeof(\(ct))); *__p = \(v); (AnyBox){ .witness = \(witness), .payload = (void*)__p }; })"
    }

    // struct → compound literal; class/actor → Name_new(...).
    private mutating func emitConstruct(typeName: String, args: [IRArg]) -> String {
        if let s = structs[typeName] {
            let fields = s.fields.map { ".\($0.name) = \(constructFieldValue($0, args))" }
            return "(\(Mangle.type(typeName))){ \(fields.joined(separator: ", ")) }"
        }
        if let c = classes[typeName] {
            let vals = c.fields.map { constructFieldValue($0, args) }
            return "\(Mangle.ctor(typeName))(\(vals.joined(separator: ", ")))"
        }
        if let a = actors[typeName] {
            let labels = a.fields.filter { $0.initializer == nil }.map(\.name)
            return "\(Mangle.ctor(typeName))(\(emitLabeled(labels, args).joined(separator: ", ")))"
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
        let tag = Mangle.tag(typeName, caseName)
        if args.isEmpty { return "(\(Mangle.type(typeName))){ .tag = \(tag) }" }
        // A `T` payload field on a generic enum is stored boxed (`void*`) (M5 5.2.3).
        let caseFields = enums[typeName]?.cases.first { $0.name == caseName }?.fields ?? []
        var inits: [String] = []
        for a in args {
            let f = caseFields.first { $0.name == a.label }
            let val: String
            if let f, case .typeParam = f.type { val = boxGenericValue(a.value) } else { val = emitExpr(a.value) }
            inits.append(".\(a.label ?? "") = \(val)")
        }
        return "(\(Mangle.type(typeName))){ .tag = \(tag), .payload.\(caseName) = { \(inits.joined(separator: ", ")) } }"
    }

    private mutating func emitMethodCall(receiver: IRExpr, method: String, args: [IRExpr]) -> String {
        // Requirement call through `any I` — dispatch via the witness slot (M5 A1.4).
        // Property reads arrive as `prop.get`; the `.` maps to the `_get` slot field.
        if case .existential(let iface) = receiver.type {
            let box = emitExpr(receiver)
            let slot = method.replacingOccurrences(of: ".", with: "_")
            let argVals = args.map { emitExpr($0) }
            let callArgs = (["__b.payload"] + argVals).joined(separator: ", ")
            return "({ AnyBox __b = \(box); ((const \(Mangle.witnessType(iface))*)__b.witness)->\(slot)(\(callArgs)); })"
        }
        // Through `any A & B` — the witness is a composite struct; index the owning
        // interface's sub-table, then its slot (M5 A1.5b).
        if case .composition(let ifaces) = receiver.type {
            let box = emitExpr(receiver)
            let slot = method.replacingOccurrences(of: ".", with: "_")
            let owner = compositionOwner(ifaces, method)
            let argVals = args.map { emitExpr($0) }
            let callArgs = (["__b.payload"] + argVals).joined(separator: ", ")
            return "({ AnyBox __b = \(box); ((const \(Mangle.compositeType(ifaces))*)__b.witness)->\(owner)->\(slot)(\(callArgs)); })"
        }
        // A requirement call through a bounded type parameter `T: I` — dispatched through the
        // witness passed for that bound (M5 5.2.2). The receiver is a `void*` to the value.
        if case .typeParam(let tp) = receiver.type, let iface = boundIface(for: tp, method: method) {
            let slot = method.replacingOccurrences(of: ".", with: "_")
            let callArgs = ([emitExpr(receiver)] + args.map { emitExpr($0) }).joined(separator: ", ")
            return "\(witnessParamName(tp, iface))->\(slot)(\(callArgs))"
        }
        // A requirement call through `some I` devirtualizes: the receiver's C value is already
        // the concrete underlying (cType maps the opaque to it), so dispatch as a direct call
        // on that concrete type — no witness, no box (M5 A3).
        guard case .named(let typeName, let kind) = concreteUnderlying(receiver.type) else {
            return "/* non-object method call: \(method) */"
        }
        // A property getter that the concrete underlying backs with a *stored field* is a direct
        // field load, not a call (matches the `any`-witness thunk's stored-field path). This is
        // what lets a `some I` property read resolve without the underlying being known in Sema.
        if method.hasSuffix(".get"), typeFields(typeName, kind).contains(where: { $0.name == String(method.dropLast(4)) }) {
            return "\(emitExpr(receiver))\(memberOp(receiver.type))\(String(method.dropLast(4)))"
        }
        // A mutating value-type (struct/enum) method takes `T* self`, so pass the
        // receiver's address; the caller check guaranteed it's a mutable `var` lvalue.
        // Class/actor receivers are already pointers, and so is `self` inside a
        // pointer-self method (don't take its address again).
        // Class/actor methods and mutating value methods take `self` by pointer; a
        // read-only value method takes it by value. A class/actor receiver value is
        // already a pointer, as is a pointer-`self`; a struct/enum value is not. Bridge
        // the two: take an address of a value, or dereference a pointer, only on mismatch.
        let calleeWantsPointer = kind == .class_ || kind == .actor_ || methodIsMutating(typeName, method)
        let isSelf: Bool = { if case .varRef("self") = receiver.kind { return true }; return false }()
        let recvIsPointer = kind == .class_ || kind == .actor_ || (isSelf && selfIsPointer)
        let recvExpr = emitExpr(receiver)
        let recv: String
        if calleeWantsPointer == recvIsPointer { recv = recvExpr }
        else if calleeWantsPointer             { recv = "&\(recvExpr)" }
        else                                   { recv = "(*\(recvExpr))" }
        let argVals = args.map { emitExpr($0) }
        return "\(Mangle.method(typeName, method))(\(([recv] + argVals).joined(separator: ", ")))"
    }

    // Resolve a `some I` opaque type to its hidden concrete underlying (M5 A3); other types
    // pass through unchanged. The underlying is always known by codegen (every opaque site was
    // resolved during Sema).
    private func concreteUnderlying(_ t: Type) -> Type {
        if case .opaque(_, let owner) = t, let u = module.opaqueUnderlyings[owner] { return u }
        return t
    }

    private func methodIsMutating(_ typeName: String, _ method: String) -> Bool {
        let m = structs[typeName]?.methods.first { $0.name == method }
            ?? enums[typeName]?.methods.first { $0.name == method }
            ?? classes[typeName]?.methods.first { $0.name == method }
        return m?.isMutating ?? false
    }

    private mutating func emitCall(callee: IRExpr, args: [IRArg], typeArgs: [Type] = []) -> String {
        if case .varRef(let name) = callee.kind {
            // A generic call: box type-parameter arguments (pass a pointer) and append the
            // witness instance for each (type parameter, bound) — witness-passing ABI (M5 5.2.2).
            if let f = funcs[name], !f.generics.isEmpty {
                return emitGenericCall(f, args: args, typeArgs: typeArgs)
            }
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
            return "\(Mangle.function(name))(\(emitArgs(args).joined(separator: ", ")))"
        }
        return "\(emitExpr(callee))(\(emitArgs(args).joined(separator: ", ")))"
    }

    // A call to a generic function: value args (type-parameter args boxed to a `void*`),
    // then a witness instance per (type parameter, bound). If the function returns a type
    // parameter, the `void*` result is read back as the inferred concrete type (M5 5.2.2).
    private mutating func emitGenericCall(_ f: IRFunc, args: [IRArg], typeArgs: [Type]) -> String {
        var subst: [String: Type] = [:]
        for (g, t) in zip(f.generics, typeArgs) { subst[g.name] = t }
        var vals: [String] = []
        for (p, a) in zip(f.params, args) {
            if case .typeParam = p.type {
                vals.append(boxGenericValue(a.value))
            } else if case .function = p.type, containsTypeParam(p.type) {
                // A closure whose type mentions a type parameter is bridged to the generic
                // body's boxed ABI by a reabstraction thunk (M5 5.2.3).
                vals.append(emitReabstraction(a.value, declFn: p.type, subst: subst))
            } else {
                vals.append(emitExpr(a.value))
            }
        }
        for g in f.generics {
            for b in g.bounds {
                if case .named(let tn, _)? = subst[g.name] { vals.append("&\(Mangle.witnessInstance(tn, b))") }
            }
        }
        let call = "\(Mangle.function(f.name))(\(vals.joined(separator: ", ")))"
        // Read a type-parameter return back into its inferred concrete type.
        if case .typeParam(let rt) = f.returnType, let concrete = subst[rt] {
            return unboxGenericValue(call, as: concrete)
        }
        return call
    }

    // Prepare a value to pass where a type parameter is expected: a `void*` to the value — a
    // reference type is already a pointer; anything else (Int/Bool/String, struct, enum) is
    // copied to a fresh heap allocation so the `void*` outlives the temporary (M5 5.2.2/5.2.3).
    private mutating func boxGenericValue(_ v: IRExpr) -> String {
        let e = emitExpr(v)
        // Already a `void*` box (a type parameter in a generic body) — pass it through; boxing
        // again would store the pointer bits in a fresh box and read back garbage (M5 5.2.3).
        if case .typeParam = v.type { return e }
        if case .named(_, .class_) = v.type { return "(void*)\(e)" }
        if case .named(_, .actor_) = v.type { return "(void*)\(e)" }
        let ct = cType(v.type)
        return "({ \(ct)* __p = (\(ct)*)rt_alloc(sizeof(\(ct))); *__p = \(e); (void*)__p; })"
    }

    // Read a `void*`-boxed generic value back as its concrete type: a reference type is the
    // pointer itself; anything else is dereferenced through the concrete C type (M5 5.2.3).
    private func unboxGenericValue(_ ptr: String, as t: Type) -> String {
        switch t {
        case .named(_, .class_), .named(_, .actor_): return "((\(cType(t)))\(ptr))"
        default:                                     return "(*(\(cType(t))*)\(ptr))"
        }
    }

    // Box a concrete C rvalue string to a `void*` — the string form of `boxGenericValue`,
    // for use inside a synthesized thunk where there is no IRExpr (M5 5.2.3).
    private func boxConcrete(_ e: String, as t: Type) -> String {
        switch t {
        case .named(_, .class_), .named(_, .actor_): return "(void*)\(e)"
        default:
            let ct = cType(t)
            return "({ \(ct)* __p = (\(ct)*)rt_alloc(sizeof(\(ct))); *__p = \(e); (void*)__p; })"
        }
    }

    private func containsTypeParam(_ t: Type) -> Bool {
        switch t {
        case .typeParam:               return true
        case .function(let p, let r):  return p.contains(where: containsTypeParam) || containsTypeParam(r)
        case .generic(_, let a):       return a.contains(where: containsTypeParam)
        default:                       return false
        }
    }

    private func substituteType(_ t: Type, _ subst: [String: Type]) -> Type {
        switch t {
        case .typeParam(let n):        return subst[n] ?? t
        case .generic(let b, let a):   return .generic(base: b, args: a.map { substituteType($0, subst) })
        case .function(let p, let r):  return .function(params: p.map { substituteType($0, subst) }, ret: substituteType(r, subst))
        default:                       return t
        }
    }

    // A reabstraction thunk (M5 5.2.3): a generic body invokes a closure parameter through the
    // boxed ABI (a `T` position is a `void*`), but the concrete closure was compiled with its
    // real C types. Wrap it in a thunk that unboxes each `T`-position argument, calls the real
    // closure, and boxes a `T`-position result — generated where the type arguments are concrete.
    // The thunk's env holds the concrete closure; the site returns a `Closure` over the thunk.
    private mutating func emitReabstraction(_ closure: IRExpr, declFn: Type, subst: [String: Type]) -> String {
        guard case .function(let declParams, let declRet) = declFn else { return emitExpr(closure) }
        let idx = closureSeq; closureSeq += 1
        let name    = "__nomu_reabs\(idx)"
        let envName = "\(name)_env"
        // A position's body-facing C type: `void*` where it is a type parameter, else concrete.
        func bodyFacing(_ t: Type) -> String { if case .typeParam = t { return "void*" }; return cType(t) }

        var def = "typedef struct { Closure inner; } \(envName);\n"
        let sigParams = (["void* env"] + declParams.enumerated().map { "\(bodyFacing($1)) a\($0)" }).joined(separator: ", ")
        def += "static \(bodyFacing(declRet)) \(name)(\(sigParams)) {\n"
        def += "    Closure inner = ((\(envName)*)env)->inner;\n"
        // The concrete closure's ABI: fully-substituted C types, env first.
        let realRet   = substituteType(declRet, subst)
        let realArgs  = declParams.map { substituteType($0, subst) }
        let realCast  = "\(cType(realRet))(*)(void*\(realArgs.isEmpty ? "" : ", " + realArgs.map { cType($0) }.joined(separator: ", ")))"
        var callArgs  = ["inner.env"]
        for (i, d) in declParams.enumerated() {
            if case .typeParam = d { callArgs.append(unboxGenericValue("a\(i)", as: realArgs[i])) }
            else { callArgs.append("a\(i)") }
        }
        let realCall = "((\(realCast))inner.fn)(\(callArgs.joined(separator: ", ")))"
        if realRet == .void {
            def += "    \(realCall);\n"
        } else if case .typeParam = declRet {
            def += "    \(cType(realRet)) __r = \(realCall);\n"
            def += "    return \(boxConcrete("__r", as: realRet));\n"
        } else {
            def += "    return \(realCall);\n"
        }
        def += "}\n"
        closureDefs += def

        let inner = emitExpr(closure)
        return "({ \(envName)* __re = (\(envName)*)rt_alloc(sizeof(\(envName))); __re->inner = \(inner); (Closure){ .fn = (void*)\(name), .env = (void*)__re }; })"
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

    // A type can cross a task boundary if it is value-like or deeply immutable
    // (design: concurrency.md §5, m5-spec 5.3). The check is **structural**:
    //   - primitives, strings (immutable), and actor handles (self-synchronizing)
    //     are always shareable;
    //   - a struct / enum is shareable iff every stored field (across all enum
    //     cases) is shareable;
    //   - a class is shareable only when **deeply immutable** — every field `let`
    //     and itself shareable (the case M3 conservatively rejected);
    //   - a generic instance `Box<T>` is shareable iff the base is once its type
    //     arguments are substituted in (conditional conformance).
    // `visiting` breaks cycles on recursive types (a back-edge is assumed
    // shareable; the decision falls to the other fields). Closures are checked
    // per-binding (`shareableClosureBindings`), so a bare function type is not.
    private func isShareable(_ t: Type, visiting: Set<String> = []) -> Bool {
        switch t {
        case .int, .bool, .string, .named(_, .actor_):
            return true
        case .named(let name, .struct_):
            guard let s = structs[name] else { return false }
            return fieldsShareable(key: name, fields: s.fields, immutableOnly: false,
                                   subst: [:], visiting: visiting)
        case .named(let name, .class_):
            guard let c = classes[name] else { return false }
            return fieldsShareable(key: name, fields: c.fields, immutableOnly: true,
                                   subst: [:], visiting: visiting)
        case .named(let name, .enum_):
            guard let e = enums[name] else { return false }
            return casesShareable(key: name, cases: e.cases, subst: [:], visiting: visiting)
        case .generic(let base, let args):
            return genericShareable(base: base, args: args, visiting: visiting)
        default:
            return false
        }
    }

    // A generic instance is shareable iff the base decl's fields are, with the
    // type parameters substituted by `args` (conditional conformance).
    private func genericShareable(base: String, args: [Type], visiting: Set<String>) -> Bool {
        let key = "\(base)<\(args.map(\.description).joined(separator: ","))>"
        if let s = structs[base] {
            let m = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            return fieldsShareable(key: key, fields: s.fields, immutableOnly: false,
                                   subst: m, visiting: visiting)
        }
        if let c = classes[base] {
            let m = Dictionary(uniqueKeysWithValues: zip(c.generics.map(\.name), args))
            return fieldsShareable(key: key, fields: c.fields, immutableOnly: true,
                                   subst: m, visiting: visiting)
        }
        if let e = enums[base] {
            let m = Dictionary(uniqueKeysWithValues: zip(e.generics.map(\.name), args))
            return casesShareable(key: key, cases: e.cases, subst: m, visiting: visiting)
        }
        return false
    }

    // Structural field check shared by struct / class / generic-instance paths.
    // `immutableOnly` demands every field be `let` (the deeply-immutable-class rule).
    private func fieldsShareable(key: String, fields: [IRField], immutableOnly: Bool,
                                 subst: [String: Type], visiting: Set<String>) -> Bool {
        if visiting.contains(key) { return true }            // cycle back-edge
        if immutableOnly && fields.contains(where: { $0.isMutable }) { return false }
        let v = visiting.union([key])
        return fields.allSatisfy { isShareable(substitute($0.type, subst), visiting: v) }
    }

    private func casesShareable(key: String, cases: [IREnumCase],
                                subst: [String: Type], visiting: Set<String>) -> Bool {
        if visiting.contains(key) { return true }            // cycle back-edge
        let v = visiting.union([key])
        return cases.allSatisfy { c in
            c.fields.allSatisfy { isShareable(substitute($0.type, subst), visiting: v) }
        }
    }

    // Apply a type-parameter substitution (built from a generic base's params →
    // concrete args) to a field type, recursing through nested generics/functions.
    private func substitute(_ t: Type, _ m: [String: Type]) -> Type {
        guard !m.isEmpty else { return t }
        switch t {
        case .typeParam(let p):
            return m[p] ?? t
        case .generic(let base, let args):
            return .generic(base: base, args: args.map { substitute($0, m) })
        case .function(let ps, let r):
            return .function(params: ps.map { substitute($0, m) }, ret: substitute(r, m))
        default:
            return t
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
        case .call(let callee, let args, _):
            collectUsesExpr(callee, bound: bound, used: &used)
            for a in args { collectUsesExpr(a.value, bound: bound, used: &used) }
        case .binary(_, let l, let r):
            collectUsesExpr(l, bound: bound, used: &used)
            collectUsesExpr(r, bound: bound, used: &used)
        case .closure(let ps, let cbody):
            var nb = bound
            for p in ps { nb.insert(p.name) }
            collectUsesBlock(cbody, bound: &nb, used: &used)
        case .box(let value, _):
            collectUsesExpr(value, bound: bound, used: &used)
        }
    }

    // MARK: - C helpers

    private func memberOp(_ base: Type) -> String {
        // A generic value type is accessed by value; a generic class by pointer (M5 5.2.3).
        if case .generic(let g, _) = base { return classes[g] != nil ? "->" : "." }
        // A `some I` value is stored as its concrete underlying, so pick the operator by that.
        if case .named(_, let k) = concreteUnderlying(base), k == .class_ || k == .actor_ { return "->" }
        return "."
    }

    // A member access `base.field` / `base->field` as a raw C lvalue (no generic unboxing).
    // `self` is a pointer in a mutating value/class method; otherwise the operator follows the
    // receiver's kind.
    private mutating func rawMemberAccess(_ base: IRExpr, _ field: String) -> String {
        let op: String
        if case .varRef("self") = base.kind, selfIsPointer { op = "->" } else { op = memberOp(base.type) }
        return "\(emitExpr(base))\(op)\(field)"
    }

    // The stored field `field` on the generic type `base` (struct or class), if any.
    private func genericStoredField(_ base: String, _ field: String) -> IRField? {
        if let s = structs[base] { return s.fields.first { $0.name == field } }
        if let c = classes[base] { return c.fields.first { $0.name == field } }
        return nil
    }

    // Is `field` on a value of this type a `T`-typed slot (stored boxed as `void*`)? (M5 5.2.3)
    private func isBoxedGenericField(_ baseType: Type, _ field: String) -> Bool {
        guard case .generic(let base, _) = baseType, let f = genericStoredField(base, field) else { return false }
        if case .typeParam = f.type { return true }
        return false
    }

    // The C value for a constructor field: a `T` field is boxed to a `void*`; a concrete field
    // is emitted directly; a missing field zero-initializes (M5 5.2.3).
    private mutating func constructFieldValue(_ f: IRField, _ args: [IRArg]) -> String {
        guard let a = args.first(where: { $0.label == f.name }) else { return "0" }
        if case .typeParam = f.type { return boxGenericValue(a.value) }
        return emitExpr(a.value)
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
        case .existential, .composition: return "AnyBox"
        case .selfType: preconditionFailure("'Self' escaped to codegen — constraint-only interfaces emit no witnesses (M5 A2)")
        case .opaque: return cType(concreteUnderlying(t))   // `some I` is unboxed — the concrete underlying's C type (M5 A3)
        case .typeParam: return "void*"   // a generic value is held by pointer under witness-passing (M5 5.2.2)
        case .generic(let base, _):       // one C shape per generic base; `T` fields are `void*` (M5 5.2.3)
            return classes[base] != nil ? Mangle.type(base) + "*" : Mangle.type(base)
        case .named(let n, let kind):
            switch kind {
            case .class_, .actor_: return Mangle.type(n) + "*"
            case .struct_, .enum_: return Mangle.type(n)
            case .interface_:      return "AnyBox /* self: any \(n) */"   // interface default self (A1.2)
            }
        case .error:      return "int64_t"   // unreachable for well-typed programs
        }
    }
}
