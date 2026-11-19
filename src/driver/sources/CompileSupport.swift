import Foundation
import ast
import parse
import noir
import support
import interface
import ssair
import ssairgen
import ssairpasses
import facts
import embedded
import midend
import sema

// The `.nmi` perf section (task 164.4.3): the module's published results, read from the fact store after
// module inference. Module inference runs over the monomorphized lowering, which holds each exported generic
// in erased form under its bare symbol (generic functions, and the methods of generic type templates), so a
// generic's result is computed over its erased body, the form a dependent's call reaches. The results are
// re-keyed to the per-definition convention and projected onto the public surface, so only an exported
// definition carries one (no private symbol leaks, and the key matches the ABI facts). A definition with no
// result is read by a dependent as "unknown", the conservative floor.
func publishedResults(_ iface: ModuleInterface, from store: FactStore) -> InterfacePerf {
    var computed: [String: EscapeSummary] = [:]
    for id in store.symbolIDs { if let s = store.facts(for: id)?.perf.escape { computed[id.mangled] = s } }
    let perDef = perDefinitionEscapeResults(computed)

    var surface = Set(iface.functions.map(\.name))
    for t in iface.types { for m in t.methods { surface.insert("\(t.name).\(m.name)") } }
    for e in iface.enums { for m in e.methods { surface.insert("\(e.name).\(m.name)") } }
    return InterfacePerf(escape: perDef.filter { surface.contains($0.key) })
}

// Re-key a dependency's published results to the call names an importer uses for them (task 164.6), so the
// importer's module inference finds a result at the `.direct(name)` its SSA emits for an imported call: a
// free function `foo` → `origin@foo`, a method `Type.method` → `m:origin@Type:method` (mirrors
// `ExternalName.encode` + ssairgen's method symbol). The union of these over the visible dependencies is
// the importer's dependency results.
func publishedResultsByCallName(_ published: [String: EscapeSummary], origin: String) -> [String: EscapeSummary] {
    var out: [String: EscapeSummary] = [:]
    for (key, s) in published {
        if let dot = key.firstIndex(of: ".") {   // `Type.method` — a method on an imported type
            let type = String(key[..<dot]), method = String(key[key.index(after: dot)...])
            out[ssaMethodSymbol(ExternalName.encode(origin: origin, name: type), method)] = s
        } else {                                 // a bare free-function name
            out[ExternalName.encode(origin: origin, name: key)] = s
        }
    }
    return out
}

// Lex + parse an embedded prelude source (trusted — a diagnostic here is a compiler bug).
private func parseEmbeddedPrelude(_ source: String, _ name: String) -> Program {
    let diags = DiagnosticSink()
    var lexer = Lexer(source, file: name, diagnostics: diags)
    var parser = Parser(lexer.tokenize(), diagnostics: diags)
    let parsed = parser.parse()
    if diags.hasErrors {
        fputs("internal error: failed to parse the embedded prelude '\(name)'\n" + diags.render() + "\n", stderr)
        exit(1)
    }
    return parsed
}

// Prepend the `runtime` prelude for a white-box runtime test (`test.runtime_prelude`, task 174.5): the fixture
// calls runtime internals directly, so they must be local decls. Returns the runtime function names as the
// runtime-subset designation (its functions compile `noSafepoint`, like the package), with the initializers
// of its globals (`global:<name>`), which run on the process's main thread before any fiber exists. The bare
// weak-ODR definitions fold with the `runtime` package's, so this adds no runtime duplication to the test
// binary.
func prependRuntimePrelude(_ program: Program) -> (Program, Set<String>) {
    let decls = zip(EmbeddedSources.runtimeFiles, runtimePrependFileNames).flatMap { file, name in
        parseEmbeddedPrelude(file.source, name).decls
    }
    let subset = Set(decls.compactMap { decl -> String? in
        if case .funcDecl(let f) = decl { return f.name }
        if case .globalDecl(let g) = decl { return "global:\(g.name)" }
        return nil
    })
    return (Program(decls: decls + program.decls, imports: program.imports), subset)
}

// The names the prepended runtime files parse under, which an ordinary module's weak-origin set lists. Each
// keeps its `runtime/` directory so it cannot equal a user file's name.
let runtimePrependFileNames = EmbeddedSources.runtimeFiles.map { "runtime/" + $0.name }

// Rewrite an imported declaration to its per-origin identity (`origin@name`, task 100.2.3.2), and any
// type reference inside it that names one of the module's own exported types to that type's identity.
func encodeExternalDecl(_ decl: TopDecl, origin: String, ownTypes: Set<String>,
                                foreign: [String: String] = [:]) -> TopDecl {
    func encT(_ r: TypeRef?) -> TypeRef? {
        guard let r = r else { return nil }
        let nm = ownTypes.contains(r.name) ? ExternalName.encode(origin: origin, name: r.name)
               : foreign[r.name].map { ExternalName.encode(origin: $0, name: r.name) } ?? r.name
        let fn = r.fn.map { FnType(params: $0.params.compactMap { encT($0) }, ret: encT($0.ret)) }
        return TypeRef(name: nm, fn: fn, existentialOf: r.existentialOf, opaqueOf: r.opaqueOf,
                       genericArgs: r.genericArgs?.compactMap { encT($0) }, qualifier: r.qualifier, span: r.span)
    }
    // A reconstructed computed property's declared type references an imported type by its bare name;
    // origin-encode it like a field's (task 100.4.3.5.4). The accessor bodies are empty placeholders.
    func encP(_ p: ComputedProperty) -> ComputedProperty {
        ComputedProperty(name: p.name, type: encT(p.type)!, getter: p.getter, setter: p.setter, span: p.span)
    }
    // A reconstructed method's (instance or `static`) signature may name an imported type — encode its
    // param/return types like a field's, so a static method's `-> Rect` return resolves to the right
    // per-origin identity (task 100.4.3.5.4). Bodies are empty (they live in the producer).
    func encM(_ m: FuncDecl) -> FuncDecl {
        FuncDecl(name: m.name, generics: m.generics,
                 params: m.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
                 returnType: encT(m.returnType), body: m.body, isStatic: m.isStatic,
                 visibility: m.visibility, span: m.span)
    }
    let key = { ExternalName.encode(origin: origin, name: $0) }
    switch decl {
    case .funcDecl(let f):
        return .funcDecl(FuncDecl(name: key(f.name), generics: f.generics,
            params: f.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
            returnType: encT(f.returnType), body: f.body, isStatic: f.isStatic, visibility: f.visibility, span: f.span))
    case .structDecl(let s):
        return .structDecl(StructDecl(name: key(s.name), generics: s.generics,
            fields: s.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: s.properties.map(encP), methods: s.methods.map(encM), conformances: s.conformances, visibility: s.visibility, span: s.span))
    case .classDecl(let c):
        return .classDecl(ClassDecl(name: key(c.name), generics: c.generics,
            fields: c.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
            properties: c.properties.map(encP), methods: c.methods.map(encM), conformances: c.conformances, visibility: c.visibility, span: c.span))
    case .enumDecl(let e):
        return .enumDecl(EnumDecl(name: key(e.name), generics: e.generics,
            cases: e.cases.map { EnumCaseDecl(name: $0.name,
                fields: $0.fields.map { VarField(name: $0.name, type: encT($0.type)!, isMutable: $0.isMutable, span: $0.span) },
                span: $0.span) },
            properties: e.properties.map(encP), methods: e.methods.map(encM), conformances: e.conformances, visibility: e.visibility, span: e.span))
    // An interface keeps its bare name; its requirements' types are encoded like a method's, so a requirement naming
    // a type from another module (`-> String`) resolves.
    case .interfaceDecl(let i):
        return .interfaceDecl(InterfaceDecl(name: i.name, refines: i.refines,
            methods: i.methods.map { m in
                InterfaceMethod(name: m.name,
                                params: m.params.map { Param(label: $0.label, name: $0.name, type: encT($0.type)!, span: $0.span) },
                                returnType: encT(m.returnType), defaultBody: m.defaultBody, isStatic: m.isStatic, span: m.span)
            },
            properties: i.properties.map { InterfacePropertyReq(name: $0.name, type: encT($0.type)!, isSettable: $0.isSettable, span: $0.span) },
            visibility: i.visibility, span: i.span, origin: origin))
    default:
        return decl
    }
}

// Report leaf-name collisions (task 100.2.3.2): two imports in one file addressed by the same qualifier
// (a shared module leaf with no disambiguating alias). The remedy is to alias one with `as`.
func reportLeafCollisions(_ collisions: [(file: String, leaf: String, span: Span)], into diags: DiagnosticSink) {
    for c in collisions {
        diags.error("two imports in this file share the qualifier '\(c.leaf)' — alias one with 'as' (e.g. 'import … as \(c.leaf)2')", at: c.span)
    }
}

// Compile one dependency module to its own object and return its public interface (task 100.4.2). The
// same pipeline the entry uses, but it emits an object with no entry point (no link here) and reports
// its own diagnostics; returns nil on any error. The interface is built from the module's own public
// surface before the prelude is prepended.
// The imported templates to inject for the consumer dial (task 100.5.2/100.5.4). `all` injects the whole
// shipped closure (whole-tree specialization). `edge` injects only the generics the consumer's own code
// calls or names **directly**, plus the non-public callees and types those reach — so a nested public generic
// (one reached only through another specialized body) stays on the erased witness path. The producer ships
// bodies with their original visibility, so a `.public` template is a generic others may call directly while a
// non-public one is a private callee that must travel with its caller. An exported type is one the consumer
// already knows from the `.nmi`; it goes with its static functions. The direct-call scan reads the consumer's
// own decls (origin-keyed call targets and type names).
func selectForDial(_ templates: [ImportedTemplate], mode: MonoMode, consumer: NOIRModule) -> [ImportedTemplate] {
    guard mode != .none else { return [] }
    if mode == .all { return templates }
    func encoded(_ t: ImportedTemplate) -> String { ExternalName.encode(origin: t.origin, name: noirDeclName(t.decl)) }
    let known = Set(consumer.decls.map(noirDeclName))
    // An "exported" template is one a consumer may call directly — `public` (cross-package) or `package`
    // (same-package, task 187.4.4); either seeds the edge dial. A sub-`package` template is a private callee,
    // pulled in only when a selected body reaches it.
    func isPublic(_ t: ImportedTemplate) -> Bool {
        switch t.decl {
        case .funcDecl(let f):                     return f.visibility >= .package
        case .structDecl, .classDecl, .enumDecl:   return known.contains(encoded(t))
        case .actorDecl, .globalDecl:              return false
        }
    }
    var byEncoded: [String: ImportedTemplate] = [:]
    var statics: [String: [String]] = [:]
    for t in templates {
        let key = encoded(t)
        byEncoded[key] = t
        if case .funcDecl = t.decl, let dot = key.lastIndex(of: "."), key[..<dot].contains("@") {
            statics[String(key[..<dot]), default: []].append(key)
        }
    }
    // The generic names the consumer's own code calls or names directly (origin-keyed, as resolved in its NOIR).
    var direct = Set<String>()
    for decl in consumer.decls { direct.formUnion(collectReferencedNames(decl)) }

    var selectedNames = Set<String>()
    var selected: [ImportedTemplate] = []
    var worklist: [ImportedTemplate] = []
    func select(_ key: String) {
        guard let t = byEncoded[key], selectedNames.insert(key).inserted else { return }
        selected.append(t); worklist.append(t)
        for s in statics[key] ?? [] { select(s) }
    }
    for t in templates where isPublic(t) && direct.contains(encoded(t)) { select(encoded(t)) }
    // Pull in the non-public callees and types the selected bodies reach (they cannot be erased-linked); leave a
    // referenced public generic un-injected so it stays on the witness path.
    while let t = worklist.popLast() {
        for ref in collectReferencedNames(t.decl).sorted() {
            guard let u = byEncoded[ref], !isPublic(u) else { continue }
            select(ref)
        }
    }
    return selected
}

private func noirDeclName(_ d: NOIRDecl) -> String {
    switch d {
    case .funcDecl(let f):   return f.name
    case .structDecl(let s): return s.name
    case .enumDecl(let e):   return e.name
    case .classDecl(let c):  return c.name
    case .actorDecl(let a):  return a.name
    case .globalDecl(let g): return g.name
    }
}

// The names of a module's own top-level declarations (task 100.5.4): the set a shipped `.bir` body's
// references are canonicalized against — a reference to one of these is this module's, so it is rewritten
// to an origin-keyed name; anything else (prelude, builtins, locals, type params) stays bare. Taken from
// the pre-prelude own-surface snapshot, so prelude names are excluded.
func topDeclNames(_ program: Program) -> Set<String> {
    var names = Set<String>()
    for decl in program.decls {
        switch decl {
        case .funcDecl(let f):      names.insert(f.name)
        case .structDecl(let s):    names.insert(s.name)
        case .classDecl(let c):     names.insert(c.name)
        case .enumDecl(let e):      names.insert(e.name)
        case .interfaceDecl(let i): names.insert(i.name)
        case .globalDecl(let g):    names.insert(g.name)
        default:                    break
        }
    }
    return names
}

// This module's own types not exported by its `.nmi` (below `package`): a shipped body that reaches one
// ships its declaration, since no consumer can learn it otherwise.
func privateTypeNames(_ program: Program) -> Set<String> {
    var names = Set<String>()
    for decl in program.decls {
        switch decl {
        case .structDecl(let s) where s.visibility < .package: names.insert(s.name)
        case .classDecl(let c) where c.visibility < .package:  names.insert(c.name)
        case .enumDecl(let e) where e.visibility < .package:   names.insert(e.name)
        default: break
        }
    }
    return names
}

// The decls a dependency ships in its `.bir` (tasks 100.5.1 / 100.5.4): its **public generic** functions and
// types, plus the transitive closure of the **non-public** functions and types those reach — the automatic
// transitive closure (§100.5). A type ships whole, with its methods and its static functions (`Box.make`), so
// a consumer specializes them with it. A non-public callee or type is absent from the `.nmi` (interface-
// invisible), so the consumer's Sema never sees it; shipping it lets the consumer emit it locally (internal,
// origin-keyed) under `--mono`. A public callee is left out: a public generic is already seeded here, and a
// public non-generic links through the ordinary import path. `ownNames` excludes the prelude (pre-prelude
// snapshot), so a prelude/builtin callee is never pulled in.
func shippedTemplates(_ module: NOIRModule, ownNames: Set<String>, privateTypes: Set<String>) -> [NOIRDecl] {
    // This module's own functions and types, by name, with their positions in `module.decls` (excludes
    // prelude, which `ownNames` already filters out), and each type's static functions.
    var own: [String: NOIRDecl] = [:]
    var position: [String: Int] = [:]
    var statics: [String: [String]] = [:]
    for (i, decl) in module.decls.enumerated() {
        let name: String
        switch decl {
        case .funcDecl(let f):   name = f.name
        case .structDecl(let s): name = s.name
        case .classDecl(let c):  name = c.name
        case .enumDecl(let e):   name = e.name
        case .actorDecl, .globalDecl: continue
        }
        if ownNames.contains(name) {
            own[name] = decl; position[name] = i
        } else if case .funcDecl = decl, let dot = name.firstIndex(of: "."), ownNames.contains(String(name[..<dot])) {
            own[name] = decl; position[name] = i
            statics[String(name[..<dot]), default: []].append(name)
        }
    }
    // An exported generic — `public` (cross-package) or `package` (same-package, task 187.4.4) — seeds the
    // shipped `.bir` so a consumer that may call it specializes it; a sub-`package` one ships only as a
    // private callee of a seeded body. (A cross-package consumer never instantiates a `package` generic, so
    // shipping it in the one `.bir` is harmless — it stays unspecialized there.) A static function goes with
    // its type.
    func isPublic(_ decl: NOIRDecl) -> Bool {
        switch decl {
        case .funcDecl(let f):   return f.visibility >= .package
        case .structDecl(let s): return !privateTypes.contains(s.name)
        case .classDecl(let c):  return !privateTypes.contains(c.name)
        case .enumDecl(let e):   return !privateTypes.contains(e.name)
        case .actorDecl, .globalDecl: return false
        }
    }
    func isGeneric(_ decl: NOIRDecl) -> Bool {
        switch decl {
        case .funcDecl(let f):   return !f.generics.isEmpty && !f.name.contains(".")
        case .structDecl(let s): return !s.generics.isEmpty
        case .classDecl(let c):  return !c.generics.isEmpty
        case .enumDecl(let e):   return !e.generics.isEmpty
        case .actorDecl, .globalDecl: return false
        }
    }
    var shippedNames = Set<String>()
    var worklist: [NOIRDecl] = []
    func ship(_ name: String) {
        guard let decl = own[name], shippedNames.insert(name).inserted else { return }
        worklist.append(decl)
        for s in statics[name] ?? [] { ship(s) }
    }
    // Seed: every exported (`public`/`package`) generic function and type.
    for (name, decl) in own.sorted(by: { $0.key < $1.key }) where isPublic(decl) && isGeneric(decl) { ship(name) }
    // Close over the non-public functions and types the shipped decls reach, transitively.
    while let decl = worklist.popLast() {
        for ref in collectReferencedNames(decl) {
            guard let callee = own[ref], !isPublic(callee) else { continue }
            ship(ref)
        }
    }
    // In declaration order, so the `.bir` is the same bytes on every build.
    return shippedNames.map { position[$0]! }.sorted().map { module.decls[$0] }
}
