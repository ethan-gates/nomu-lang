import noir
import ast
import support
// Monomorphization — the specialization pass (design: generics.md §6, noir.md).
// An IR→IR pass, run after Sema/exhaustiveness and before codegen.
//
// Under a single compilation unit there is no ABI boundary to preserve, so this
// specializes **every** generic instantiation (Swift's whole-module optimization).
// It walks the module from its concrete roots (non-generic funcs, `main`), discovers
// generic instantiations — `.call` type arguments and `.generic` types — to a
// worklist/fixpoint, and **clones each generic decl with its type parameters replaced
// by concrete types**, dropping the `generics` list. The specialized decls are
// fully-concrete: no `.typeParam`, no `.generic`, no witness parameters. Codegen then
// emits direct calls / inline fields / no boxing through its existing concrete paths —
// a requirement call whose receiver is now concrete simply isn't taken by codegen's
// `.typeParam` witness-dispatch branch, so it devirtualizes.
//
// The one exception: a **public** generic function is additionally emitted **erased**
// (type parameters retained, under its bare symbol) so a consumer module can call it
// through runtime witnesses. What in it mentions a type parameter survives into codegen, which
// lowers it to a VWT-driven opaque buffer (cross-module generics; generics.md §6,
// backend.md §4); its concrete types are specialized as in any other body. Internal
// generics stay monomorphized-only.
//
// `any I` is left untouched (inherently dynamic — the explicit erasure opt-in), so the
// witness tables / conformances / interfaces ride through unchanged.
//
// Whole-program mono is a policy for the single-CU world; when multi-file/module builds
// land it is rescoped to within-module (cross-module specialization opt-in), preserving
// the stable-ABI default at module edges (generics.md §6).

// `privateTypes` names this module's types below `package` visibility: their erased methods are emitted only when an
// erased body uses them.
public func monomorphize(_ module: NOIRModule, recipes: DictionaryRecipes? = nil, privateTypes: Set<String> = [],
                         into diags: DiagnosticSink) -> NOIRModule {
    Monomorphizer(module: module, recipes: recipes, privateTypes: privateTypes, diags: diags).run()
}

private final class Monomorphizer {
    let module: NOIRModule
    let diags: DiagnosticSink

    // Generic templates (never emitted directly; only their specializations are).
    var genericFuncs:   [String: NOIRFunc]   = [:]
    var genericStructs: [String: NOIRStruct] = [:]
    var genericEnums:   [String: NOIREnum]   = [:]
    var genericClasses: [String: NOIRClass]  = [:]
    var baseKind:       [String: NamedKind] = [:]   // generic type base → its kind

    var out: [NOIRDecl] = []
    var monoTypeArgs: [String: [Type]] = [:]   // mono'd type name → its type args (task 100.4.3.5.3.3)
    private var instances: [String: (base: String, args: [Type])] = [:]   // a named instance, from when it is enqueued
    // Specialized names already emitted (guards recursion) + requested (dedupes the worklist).
    var doneFuncs = Set<String>(), doneTypes = Set<String>()
    var reqFuncs  = Set<String>(), reqTypes  = Set<String>()
    var funcWork: [(base: String, args: [Type])] = []
    var typeWork: [(base: String, args: [Type])] = []
    var recursionErrored = false
    // Rewriting a body that stays compiled once: a type that mentions a type parameter stays as written (codegen
    // holds it by buffer), and only the concrete ones are specialized, as in a non-generic body.
    var erasing = false

    // Cap on type-argument nesting depth (counted as `<` in a specialized name) — beyond
    // this we assume polymorphic recursion (`f<Box<T>>` → `f<Box<Box<T>>>` → …) and error.
    let depthCap = 64

    // The dependencies' dictionary recipes, by symbol, and the instances this module's concrete calls need.
    let imported: DictionaryRecipes?
    var importedRecipes: [String: DictionaryRecipe] = [:]
    var dictionaries: [String: DictionaryInstance] = [:]
    var requestedDictionaries = Set<String>()

    let privateTypes: Set<String>

    init(module: NOIRModule, recipes: DictionaryRecipes?, privateTypes: Set<String>, diags: DiagnosticSink) {
        self.module = module; self.diags = diags; self.imported = recipes; self.privateTypes = privateTypes
        for r in recipes?.recipes ?? [] { importedRecipes[r.symbol] = r }
    }

    func run() -> NOIRModule {
        // Register every generic template first (a root may reference one declared later).
        var roots: [NOIRDecl] = []
        for decl in module.decls {
            switch decl {
            case .funcDecl(let f)   where !f.generics.isEmpty: genericFuncs[f.name]   = f
            case .structDecl(let s) where !s.generics.isEmpty: genericStructs[s.name] = s; baseKind[s.name] = .struct_
            case .enumDecl(let e)   where !e.generics.isEmpty: genericEnums[e.name]   = e; baseKind[e.name] = .enum_
            case .classDecl(let c)  where !c.generics.isEmpty: genericClasses[c.name] = c; baseKind[c.name] = .class_
            default: roots.append(decl)
            }
        }
        roots += layoutDecls()
        for r in roots { out.append(rewriteDecl(r, [:])) }
        while !funcWork.isEmpty || !typeWork.isEmpty {
            while let w = funcWork.popLast() { specializeFunc(w.base, w.args) }
            while let w = typeWork.popLast() { specializeType(w.base, w.args) }
        }
        // An **exported** generic function (`public` cross-package, or `package` same-package — task
        // 187.4.4) is also emitted **erased**, under its bare symbol, so a consumer module can call it
        // through runtime witnesses (the debug baseline; the call-site witness-argument ABI is 100.4.3.4).
        // Type parameters are retained: residual `.typeParam` survives into codegen, which lowers it to a
        // VWT-driven opaque buffer. `internal`/`private` generics stay monomorphized-only (emitted above) unless an erased body calls them.
        var erased = Set<String>()
        var pending: [[NOIRStmt]] = []
        for decl in module.decls {
            if case .funcDecl(let f) = decl, !f.generics.isEmpty, f.visibility >= .package {
                out.append(.funcDecl(f))
                erased.insert(f.name)
                pending.append(f.body)
            }
        }
        // Generic types' methods are emitted erased below, so their bodies call through this ABI too.
        // In name order, as everything this function emits: dictionary order varies from run to run, and the
        // object must be the same bytes from every compile.
        // An imported type's erased methods are its producer's: a type shipped in a `.bir` keeps its methods only to
        // specialize them, and its template is emitted for its layout alone.
        // A type's erased methods are emitted when a consumer can call them, the type being exported, or when an
        // erased body here uses the type with a type parameter in it; the rest would only be dead-stripped.
        var keptTypes = Set<String>()
        func erasedMethods(_ name: String, _ methods: [NOIRFunc]) -> [NOIRFunc] {
            ExternalName.isEncoded(name) || !keptTypes.contains(name) ? [] : methods
        }
        func methodsOf(_ name: String) -> [NOIRFunc] {
            genericStructs[name]?.methods ?? genericEnums[name]?.methods ?? genericClasses[name]?.methods ?? []
        }
        func keep(_ name: String) {
            guard keptTypes.insert(name).inserted else { return }
            pending += erasedMethods(name, methodsOf(name)).map { eraseFunc($0).body }
        }
        // The erased bodies are rewritten like a concrete one, except that what mentions a type parameter is kept: a
        // concrete `Option<Node>` there is the specialized enum a concrete caller or field hands it, held by value.
        erasing = true
        defer { erasing = false }
        pending = []
        for i in out.indices {
            guard case .funcDecl(let f) = out[i], erased.contains(f.name), !f.generics.isEmpty else { continue }
            let e = eraseFunc(f)
            out[i] = .funcDecl(e)
            pending.append(e.body)
        }
        let typeNames = (Array(genericStructs.keys) + Array(genericEnums.keys) + Array(genericClasses.keys)).sorted()
        for name in typeNames where !privateTypes.contains(name) { keep(name) }
        // A private generic that an erased body calls has no specialization to call: it is emitted erased too. A
        // generic type an erased body uses with a type parameter keeps its erased methods, which the body's method
        // calls and witness tables reach.
        while let body = pending.popLast() {
            var bound = Set<String>(), used: [String] = []
            collectUses(body, &bound, &used)
            for name in used {
                guard let f = genericFuncs[name], erased.insert(name).inserted else { continue }
                let e = eraseFunc(f)
                out.append(.funcDecl(e))
                pending.append(e.body)
            }
            var mentioned = Set<String>()
            erasedTypeUses(body, into: &mentioned)
            for name in mentioned.sorted() where methodsOf(name).isEmpty == false { keep(name) }
        }
        // An erased body may hold a composed generic value (`Box<T>`) by buffer and access its fields
        // (task 100.4.3.3.4). Emit each generic type **template** (type parameters retained) so codegen
        // has the field layout for such a `.generic` receiver. Its concrete LLVM struct type is never
        // built (erased bodies hold it as an opaque buffer and index fields by VWT-derived offset), so a
        // `T` field needs no concrete shape. Instance methods are retained on the template and lowered
        // **erased** (task 100.4.3.5.3), so a consumer calls them through runtime witnesses with `self` a
        // value-buffer receiver. Each own-module instantiation keeps its specialized methods (emitted by
        // `specializeType`), so the erased copy adds the cross-module symbol without disturbing the
        // concrete path. (Gating to the *type's* `public` visibility — to drop internal generic types'
        // dead erased methods — awaits type visibility on `NOIRStruct`/`NOIREnum`; members are not
        // individually marked public here, so the type is the unit, 100.4.3.5.3.)
        for (name, s) in genericStructs.sorted(by: { $0.key < $1.key }) {
            out.append(.structDecl(NOIRStruct(name: name, generics: s.generics, fields: s.fields.map { rewriteField($0, [:]) },
                                              methods: erasedMethods(name, s.methods).map(eraseFunc), span: s.span)))
        }
        for (name, e) in genericEnums.sorted(by: { $0.key < $1.key }) {
            let cases = e.cases.map { c in NOIREnumCase(name: c.name, fields: c.fields.map { rewriteField($0, [:]) }, span: c.span) }
            out.append(.enumDecl(NOIREnum(name: name, generics: e.generics, cases: cases,
                                          methods: erasedMethods(name, e.methods).map(eraseFunc), span: e.span)))
        }
        // A generic **class** template, for the erased method path on a reference receiver (task 100.4.3.9):
        // like structs/enums, retain the template so codegen has the field layout; its methods lower erased
        // with `self` a managed object pointer and fields indexed by VWT-derived offset past the header.
        for (name, c) in genericClasses.sorted(by: { $0.key < $1.key }) {
            out.append(.classDecl(NOIRClass(name: name, generics: c.generics, fields: c.fields.map { rewriteField($0, [:]) },
                                            methods: erasedMethods(name, c.methods).map(eraseFunc), span: c.span)))
        }
        // The specializations the erased bodies and templates reach.
        while !funcWork.isEmpty || !typeWork.isEmpty {
            while let w = funcWork.popLast() { specializeFunc(w.base, w.args) }
            while let w = typeWork.popLast() { specializeType(w.base, w.args) }
        }
        var result = NOIRModule(decls: out, interfaces: module.interfaces, conformances: module.conformances,
                        composites: module.composites, opaqueUnderlyings: module.opaqueUnderlyings,
                        externalMutatingMethods: module.externalMutatingMethods, monoTypeArgs: monoTypeArgs)
        result.recipes = dictionaryRecipes(out, imported: imported)
        result.dictionaries = dictionaries
        return result
    }

    // The types recipes name that this module has no decl for, private ones of a dependency: a generic one becomes a
    // template, specialized like any other, and the rest are returned as decls.
    private func layoutDecls() -> [NOIRDecl] {
        let zero = Span(startOffset: -1, endOffset: -1, map: nil)
        var known = Set<String>()
        for d in module.decls {
            switch d {
            case .structDecl(let s): known.insert(s.name)
            case .enumDecl(let e): known.insert(e.name)
            case .classDecl(let c): known.insert(c.name)
            case .actorDecl(let a): known.insert(a.name)
            default: break
            }
        }
        var decls: [NOIRDecl] = []
        for l in imported?.layouts ?? [] where !known.contains(l.name) {
            let params = l.generics.map { NOIRGenericParam(name: $0, bounds: []) }
            func fields(_ group: Int) -> [NOIRField] {
                guard group < l.fields.count else { return [] }
                let marks = l.fromTypeParameter.flatMap { group < $0.count ? $0[group] : nil }
                return zip(l.fieldNames[group], l.fields[group]).enumerated().map { i, f in
                    NOIRField(name: f.0, type: f.1, isMutable: true, span: zero,
                              fromTypeParameter: marks.map { i < $0.count && $0[i] } ?? false)
                }
            }
            let decl: NOIRDecl
            switch l.kind {
            case .enum_:
                let cases = l.caseNames.enumerated().map { NOIREnumCase(name: $0.element, fields: fields($0.offset), span: zero) }
                let e = NOIREnum(name: l.name, generics: params, cases: cases, methods: [], span: zero)
                decl = .enumDecl(e)
                if !params.isEmpty { genericEnums[l.name] = e }
            case .class_:
                let c = NOIRClass(name: l.name, generics: params, fields: fields(0), methods: [], span: zero)
                decl = .classDecl(c)
                if !params.isEmpty { genericClasses[l.name] = c }
            default:
                let st = NOIRStruct(name: l.name, generics: params, fields: fields(0), methods: [], span: zero)
                decl = .structDecl(st)
                if !params.isEmpty { genericStructs[l.name] = st }
            }
            if params.isEmpty { decls.append(decl) } else { baseKind[l.name] = l.kind }
        }
        return decls
    }

    // The dictionary of `symbol` at concrete `typeArgs`, and the dictionaries, types and descriptors it reaches. The
    // types go through `resolveType`, so a type this module never named gets specialized like one it did.
    private func requestDictionary(_ symbol: String, _ typeArgs: [Type]) {
        let key = dictionaryKey(symbol, typeArgs)
        guard requestedDictionaries.insert(key).inserted, let recipe = importedRecipes[symbol] else { return }
        let subst = Dictionary(uniqueKeysWithValues: zip(recipe.generics, typeArgs))
        let needs: [DictionaryInstance.Need] = recipe.needs.map { need in
            switch need {
            case .object(let t): return .object(resolveType(t, subst))
            case .arrayBuffer(let e): return .arrayBuffer(element: resolveType(e, subst))
            case .box(let t, let ifaces): return .box(resolveType(t, subst), interfaces: ifaces)
            case .callValue(let t): return .callAdapter(resolveType(t, subst))
            case .closureEntry(let t): return .entryAdapter(resolveType(t, subst))
            case .callee(let callee, let args):
                let resolved = args.map { resolveType($0, subst) }
                requestDictionary(callee, resolved)
                return .dictionary(key: dictionaryKey(callee, resolved))
            }
        }
        dictionaries[key] = DictionaryInstance(typeArgs: typeArgs, bounds: recipe.bounds, needs: needs)
        for (arg, bounds) in zip(typeArgs, recipe.bounds) { specializeRequirementTypes(arg, bounds) }
    }

    // A witness table for `conformer: I` calls the conformer's methods with `Self` set to it. A requirement type
    // with `Self` inside an applied generic (`Option<Self>`) names an instance (`Option<Num>`) the table's thunks
    // need even when nothing else here mentions it.
    // Likewise a static requirement on a generic conformer calls a specialization of the type's static method, or,
    // for an imported type, the producer's compiled-once one with its dictionary.
    private func specializeRequirementTypes(_ conformer: Type, _ bounds: [String]) {
        guard case .named(let name, _) = conformer else { return }
        for iface in module.interfaces where bounds.contains(iface.name) {
            let types = iface.methods.flatMap { $0.selfParams + [$0.selfRet] } + iface.properties.map(\.selfType)
            for t in types where t.mentionsSelf && t != .selfType { _ = resolveType(t.replacingSelf(with: conformer), [:]) }
            guard let inst = instances[name] else { continue }
            for m in iface.methods where m.isStatic {
                let fn = "\(inst.base).\(m.name)"
                if genericFuncs[fn] != nil { enqueueFunc(fn, inst.args) }
                else if importedRecipes[fn] != nil { requestDictionary(fn, inst.args) }
            }
        }
    }

    // MARK: - Specialization

    private func specializeFunc(_ base: String, _ args: [Type]) {
        let name = specName(base, args)
        guard doneFuncs.insert(name).inserted, let tmpl = genericFuncs[base] else { return }
        guard !overDepth(name, at: tmpl.span) else { return }
        let subst = Dictionary(uniqueKeysWithValues: zip(tmpl.generics.map(\.name), args))
        out.append(.funcDecl(rewriteFunc(tmpl, subst, name: name)))
    }

    private func specializeType(_ base: String, _ args: [Type]) {
        let name = specName(base, args)
        guard doneTypes.insert(name).inserted else { return }
        if !args.isEmpty { monoTypeArgs[name] = args }   // for the erased-method call lowering (100.4.3.5.3.3)
        // An imported generic type's methods are compiled once in its producer. A method may be reached here with
        // no call naming it, through a bound on a specialized generic or a witness table built for this instance,
        // so each gets its dictionary.
        for symbol in importedRecipes.keys.sorted() where symbol.hasPrefix("m:\(base):") { requestDictionary(symbol, args) }
        if let s = genericStructs[base] {
            guard !overDepth(name, at: s.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(s.generics.map(\.name), args))
            out.append(.structDecl(NOIRStruct(name: name, generics: [],
                fields: s.fields.map { rewriteField($0, subst) },
                methods: s.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: s.span)))
        } else if let e = genericEnums[base] {
            guard !overDepth(name, at: e.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(e.generics.map(\.name), args))
            out.append(.enumDecl(NOIREnum(name: name, generics: [],
                cases: e.cases.map { c in NOIREnumCase(name: c.name, fields: c.fields.map { rewriteField($0, subst) }, span: c.span) },
                methods: e.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: e.span)))
        } else if let c = genericClasses[base] {
            guard !overDepth(name, at: c.span) else { return }
            let subst = Dictionary(uniqueKeysWithValues: zip(c.generics.map(\.name), args))
            out.append(.classDecl(NOIRClass(name: name, generics: [],
                fields: c.fields.map { rewriteField($0, subst) },
                methods: c.methods.map { rewriteFunc($0, subst, name: $0.name) }, span: c.span)))
        }
    }

    private func overDepth(_ name: String, at span: Span) -> Bool {
        guard name.lazy.filter({ $0 == "<" }).count > depthCap else { return false }
        if !recursionErrored {
            recursionErrored = true
            diags.error("possible infinite specialization (polymorphic recursion) while monomorphizing '\(name.prefix(40))…'", at: span)
        }
        return true
    }

    // MARK: - Decl rewriting (roots use an empty subst; templates their instantiation's)

    private func rewriteDecl(_ d: NOIRDecl, _ s: [String: Type]) -> NOIRDecl {
        switch d {
        case .funcDecl(let f):   return .funcDecl(rewriteFunc(f, s, name: f.name))
        case .structDecl(let t): return .structDecl(NOIRStruct(name: t.name, generics: [],
            fields: t.fields.map { rewriteField($0, s) }, methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .enumDecl(let t):   return .enumDecl(NOIREnum(name: t.name, generics: [],
            cases: t.cases.map { c in NOIREnumCase(name: c.name, fields: c.fields.map { rewriteField($0, s) }, span: c.span) },
            methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .classDecl(let t):  return .classDecl(NOIRClass(name: t.name, generics: [],
            fields: t.fields.map { rewriteField($0, s) }, methods: t.methods.map { rewriteFunc($0, s, name: $0.name) }, span: t.span))
        case .actorDecl(let a):  return .actorDecl(rewriteActor(a, s))
        case .globalDecl(let g): return .globalDecl(NOIRGlobal(name: g.name, type: resolveType(g.type, s),
                                                                value: rewriteExpr(g.value, s), isConstant: g.isConstant, span: g.span))
        }
    }

    private func rewriteFunc(_ f: NOIRFunc, _ s: [String: Type], name: String) -> NOIRFunc {
        NOIRFunc(name: name, generics: [],
               params: f.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
               returnType: resolveType(f.returnType, s),
               body: f.body.map { rewriteStmt($0, s) }, isMutating: f.isMutating, span: f.span)
    }

    // The generic types an erased body names with a type parameter in their arguments (`Box<T>`, `Pair<Int, T>`),
    // anywhere: an expression's type, a binding, a closure parameter, a static call's type.
    private func erasedTypeUses(_ stmts: [NOIRStmt], into names: inout Set<String>) {
        func visit(_ t: Type) {
            switch t {
            case .generic(let base, let args):
                if args.contains(where: \.mentionsTypeParameter) { names.insert(base) }
                args.forEach(visit)
            case .array(let e), .ptr(let e): visit(e)
            case .function(let ps, let r): ps.forEach(visit); visit(r)
            default: break
            }
        }
        func expr(_ e: NOIRExpr) {
            visit(e.type)
            switch e.kind {
            case .intLit, .doubleLit, .boolLit, .stringLit, .funcRef, .globalRef, .varRef: break
            case .fieldAccess(let base, _): expr(base)
            case .construct(_, let args), .enumInit(_, _, let args): args.forEach { expr($0.value) }
            case .methodCall(let r, _, let args): expr(r); args.forEach(expr)
            case .call(let c, let args, let typeArgs): expr(c); args.forEach { expr($0.value) }; typeArgs.forEach(visit)
            case .binary(_, let l, let r): expr(l); expr(r)
            case .closure(let ps, let body): ps.forEach { visit($0.type) }; body.forEach(stmt)
            case .box(let v, _): expr(v)
            case .arrayLit(let els): els.forEach(expr)
            case .index(let b, let i): expr(b); expr(i)
            case .staticCall(let t, _, let args): visit(t); args.forEach(expr)
            case .taskStart(_, let make, let call, let fulfill): expr(make); expr(call); expr(fulfill)
            }
        }
        func stmt(_ s: NOIRStmt) {
            switch s.kind {
            case .letBinding(_, _, let v): expr(v)
            case .fiberStart(let c): expr(c)
            case .assign(let t, let v), .compoundAssign(let t, let v): expr(t); expr(v)
            case .ret(let e): if let e { expr(e) }
            case .ifStmt(let c, let t, let e): expr(c); t.forEach(stmt); e?.forEach(stmt)
            case .whileStmt(let c, let b): expr(c); b.forEach(stmt)
            case .breakStmt, .continueStmt: break
            case .switchStmt(let sw):
                expr(sw.subject)
                for arm in sw.arms { arm.bindings.forEach { visit($0.type) }; arm.body.forEach(stmt) }
            case .exprStmt(let e): expr(e)
            }
        }
        stmts.forEach(stmt)
    }

    // A body compiled once, under `erasing`: its own type parameters kept, its concrete types specialized.
    private func eraseFunc(_ f: NOIRFunc) -> NOIRFunc {
        let r = rewriteFunc(f, [:], name: f.name)
        return NOIRFunc(name: f.name, generics: f.generics, params: r.params, returnType: r.returnType, body: r.body,
                        isMutating: f.isMutating, span: f.span)
    }

    private func rewriteField(_ f: NOIRField, _ s: [String: Type]) -> NOIRField {
        NOIRField(name: f.name, type: resolveType(f.type, s), isMutable: f.isMutable, span: f.span,
                  fromTypeParameter: f.fromTypeParameter || f.type.mentionsTypeParameter)
    }

    private func rewriteActor(_ a: NOIRActor, _ s: [String: Type]) -> NOIRActor {
        NOIRActor(name: a.name,
                fields: a.fields.map { NOIRActorField(name: $0.name, type: resolveType($0.type, s),
                                                    initializer: $0.initializer.map { rewriteExpr($0, s) }, span: $0.span) },
                handlers: a.handlers.map { h in NOIRHandler(name: h.name,
                    params: h.params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
                    returnType: resolveType(h.returnType, s), body: h.body.map { rewriteStmt($0, s) }, span: h.span) },
                span: a.span)
    }

    // MARK: - Statement / expression rewriting

    private func rewriteStmt(_ st: NOIRStmt, _ s: [String: Type]) -> NOIRStmt {
        let kind: StmtKind
        switch st.kind {
        case .letBinding(let n, let m, let v):    kind = .letBinding(name: n, isMutable: m, value: rewriteExpr(v, s))
        case .assign(let t, let v):               kind = .assign(target: rewriteExpr(t, s), value: rewriteExpr(v, s))
        case .compoundAssign(let t, let v):       kind = .compoundAssign(target: rewriteExpr(t, s), value: rewriteExpr(v, s))
        case .ret(let e):                         kind = .ret(e.map { rewriteExpr($0, s) })
        case .ifStmt(let c, let t, let e):        kind = .ifStmt(cond: rewriteExpr(c, s), then: t.map { rewriteStmt($0, s) }, else: e.map { $0.map { rewriteStmt($0, s) } })
        case .whileStmt(let c, let body):         kind = .whileStmt(cond: rewriteExpr(c, s), body: body.map { rewriteStmt($0, s) })
        case .breakStmt:                          kind = .breakStmt
        case .continueStmt:                       kind = .continueStmt
        case .fiberStart(let c):                  kind = .fiberStart(call: rewriteExpr(c, s))
        case .switchStmt(let sw):
            kind = .switchStmt(NOIRSwitch(subject: rewriteExpr(sw.subject, s),
                arms: sw.arms.map { arm in NOIRCaseArm(caseName: arm.caseName,
                    bindings: arm.bindings.map { NOIRBinding(name: $0.name, type: resolveType($0.type, s)) },
                    body: arm.body.map { rewriteStmt($0, s) }, span: arm.span) }))
        case .exprStmt(let e):                    kind = .exprStmt(rewriteExpr(e, s))
        }
        return NOIRStmt(kind: kind, span: st.span)
    }

    private func rewriteExpr(_ e: NOIRExpr, _ s: [String: Type]) -> NOIRExpr {
        let newType = resolveType(e.type, s)
        let kind: ExprKind
        switch e.kind {
        case .intLit, .doubleLit, .boolLit, .stringLit, .varRef, .globalRef, .funcRef:
            kind = e.kind
        case .fieldAccess(let base, let field):
            kind = .fieldAccess(base: rewriteExpr(base, s), field: field)
        case .construct(let typeName, let args):
            kind = .construct(typeName: namedName(newType) ?? typeName, args: rewriteArgs(args, s))
        case .enumInit(let typeName, let caseName, let args):
            kind = .enumInit(typeName: namedName(newType) ?? typeName, caseName: caseName, args: rewriteArgs(args, s))
        case .methodCall(let recv, let method, let args):
            if case .generic(let base, let typeArgs) = recv.type, importedRecipes["m:\(base):\(method)"] != nil {
                let rArgs = typeArgs.map { resolveType($0, s) }
                if !rArgs.contains(where: \.mentionsTypeParameter) { requestDictionary("m:\(base):\(method)", rArgs) }
            }
            kind = .methodCall(receiver: rewriteExpr(recv, s), method: method, args: args.map { rewriteExpr($0, s) })
        case .call(let callee, let args, let typeArgs):
            let rArgs = typeArgs.map { resolveType($0, s) }
            let concrete = !rArgs.contains(where: \.mentionsTypeParameter)
            if case .varRef(let fname) = callee.kind, genericFuncs[fname] != nil, !rArgs.isEmpty, concrete {
                enqueueFunc(fname, rArgs)
                let sn = specName(fname, rArgs)
                // Codegen resolves a global call by name (`funcs[sn]`), never the callee's
                // type, so leave it a placeholder — resolving the generic function type here
                // would recurse into its unbound `T`s and enqueue stray `Box<T>` specializations.
                let newCallee = NOIRExpr(type: .void, span: callee.span, kind: .varRef(sn))
                kind = .call(callee: newCallee, args: rewriteArgs(args, s), typeArgs: [])
            } else {
                if case .varRef(let fname) = callee.kind, importedRecipes[fname] != nil, concrete { requestDictionary(fname, rArgs) }
                kind = .call(callee: rewriteExpr(callee, s), args: rewriteArgs(args, s), typeArgs: rArgs)
            }
        case .binary(let op, let l, let r):
            kind = .binary(op, rewriteExpr(l, s), rewriteExpr(r, s))
        case .closure(let params, let body):
            kind = .closure(params: params.map { NOIRParam(label: $0.label, name: $0.name, type: resolveType($0.type, s), span: $0.span) },
                            body: body.map { rewriteStmt($0, s) })
        case .box(let value, let interfaces):
            kind = .box(value: rewriteExpr(value, s), interfaces: interfaces)
        case .arrayLit(let elements):
            kind = .arrayLit(elements: elements.map { rewriteExpr($0, s) })
        case .index(let base, let idx):
            kind = .index(base: rewriteExpr(base, s), idx: rewriteExpr(idx, s))
        case .staticCall(let onType, let method, let args):
            // Resolve the dispatch type (a bound type parameter → the concrete conformer) and lower
            // to a direct call of that type's static method free function `Conformer.method`.
            let rty = resolveType(onType, s)
            // Compiled once, a static call on a type parameter dispatches through its witness.
            if rty.mentionsTypeParameter {
                kind = .staticCall(onType: rty, method: method, args: args.map { rewriteExpr($0, s) })
                return NOIRExpr(type: newType, span: e.span, kind: kind)
            }
            let tn = namedName(rty) ?? "<unresolved>"
            let rArgs = args.map { NOIRArg(label: nil, value: rewriteExpr($0, s)) }
            // A generic type's static method is a generic function over the type's parameters (`Box.make`).
            if let inst = instances[tn] {
                let callee = NOIRExpr(type: .void, span: e.span, kind: .varRef("\(inst.base).\(method)"))
                return rewriteExpr(NOIRExpr(type: resolveType(e.type, s), span: e.span,
                                            kind: .call(callee: callee, args: rArgs, typeArgs: inst.args)), [:])
            }
            let callee = NOIRExpr(type: .void, span: e.span, kind: .varRef("\(tn).\(method)"))
            kind = .call(callee: callee, args: rArgs, typeArgs: [])
        case .taskStart(let binder, let make, let call, let fulfill):
            kind = .taskStart(binder: binder, make: rewriteExpr(make, s), call: rewriteExpr(call, s),
                              fulfill: rewriteExpr(fulfill, s))
        }
        return NOIRExpr(type: newType, span: e.span, kind: kind)
    }

    private func rewriteArgs(_ args: [NOIRArg], _ s: [String: Type]) -> [NOIRArg] {
        args.map { NOIRArg(label: $0.label, value: rewriteExpr($0.value, s)) }
    }

    // MARK: - Types

    // Substitute type parameters, then rename any applied generic `Box<Int>` to a fresh
    // concrete `.named("Box<Int>")` and enqueue its specialization.
    private func resolveType(_ t: Type, _ s: [String: Type]) -> Type {
        switch t {
        case .typeParam(let p):
            if let bound = s[p] { return resolveType(bound, [:]) }
            return t
        case .generic(let base, let args):
            let rargs = args.map { resolveType($0, s) }
            if erasing, rargs.contains(where: \.mentionsTypeParameter) { return .generic(base: base, args: rargs) }
            enqueueType(base, rargs)
            return .named(specName(base, rargs), baseKind[base] ?? .struct_)
        case .function(let ps, let r):
            return .function(params: ps.map { resolveType($0, s) }, ret: resolveType(r, s))
        case .array(let e):
            return .array(resolveType(e, s))
        default:
            return t
        }
    }

    private func enqueueFunc(_ base: String, _ args: [Type]) {
        let n = specName(base, args)
        guard !doneFuncs.contains(n), reqFuncs.insert(n).inserted else { return }
        funcWork.append((base, args))
    }

    private func enqueueType(_ base: String, _ args: [Type]) {
        guard genericStructs[base] != nil || genericEnums[base] != nil || genericClasses[base] != nil else { return }
        let n = specName(base, args)
        instances[n] = (base, args)
        guard !doneTypes.contains(n), reqTypes.insert(n).inserted else { return }
        typeWork.append((base, args))
    }

    private func specName(_ base: String, _ args: [Type]) -> String {
        Type.specializedName(base, args)
    }

    private func namedName(_ t: Type) -> String? {
        if case .named(let n, _) = t { return n }
        return nil
    }
}
