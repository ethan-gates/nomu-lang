import noir
import ast
// Cross-module specialization — the consumer side of the specialization dial (task 100.5.4).
//
// Under `--mono != none` a consumer specializes the generics it imports rather than calling them through
// the erased witness ABI. The producer ships each public generic template's pre-mono body in its `.bir`
// (task 100.5.1); this pass injects those templates into the consumer's NOIR module so the existing
// `Monomorphize` pass — run right after — discovers the consumer's concrete instantiations and clones a
// specialized copy, and the call sites devirtualize to direct calls (identical output to whole-program
// mono, the `wp_*` golden).
//
// A template is injected under its **producer-qualified name** (`origin@name`, the `ExternalName`
// encoding the consumer already resolves imports with, task 100.2.3.2) — the consumer's call site names
// the imported generic that way (`lib@id<Int>`), so the injected template must match for `Monomorphize`
// to specialize it. This is the design's "mint a fresh local decl per `.bir` entry, origin-keyed" step
// (100.5 "A"). Injected templates are marked **internal** so `Monomorphize` — which re-emits only
// *public* generics erased — specializes them without emitting a duplicate erased symbol (the producer
// owns that one). A name specialized locally is returned so the driver drops it from the external
// generic/func sets it hands codegen (the call now binds to the local specialization).
//
// The first milestone injects generic **functions** whose bodies reference nothing outside themselves
// (`id<T>`). Re-resolving a body's *internal* references to origin keys (a recursive or cross-template
// callee, a local-index definition table) and the `edge`-vs-`all` depth distinction are later phases of
// 100.5; whole-tree specialization is `Monomorphize`'s existing behavior, so `all` works today.

// A generic template imported from a dependency's `.bir`, tagged with its producer module's origin
// (`"lib"`, `"util/parse"`) so it can be injected under the origin-keyed name the consumer's call sites use.
public struct ImportedTemplate {
    public let origin: String
    public let decl: NOIRDecl
    public init(origin: String, decl: NOIRDecl) { self.origin = origin; self.decl = decl }
}

public struct SpecializeInjection {
    public let module: NOIRModule        // the consumer module with the imported templates injected
    public let localizedNames: Set<String>   // origin-keyed generic names now specialized locally
    public init(module: NOIRModule, localizedNames: Set<String>) {
        self.module = module; self.localizedNames = localizedNames
    }
}

// Inject imported generic templates into `module` for local specialization. A no-op when there is nothing
// to inject (so a `none`-dial caller, which passes no templates, costs nothing).
public func injectImportedTemplates(into module: NOIRModule, templates: [ImportedTemplate]) -> SpecializeInjection {
    guard !templates.isEmpty else { return SpecializeInjection(module: module, localizedNames: []) }

    // A template whose origin-keyed name already names a decl in the module (its own, or an earlier-
    // injected one) is skipped — the first binding wins, matching import resolution generally.
    var existing = Set(module.decls.map(declName))
    var injected: [NOIRDecl] = []
    var localized = Set<String>()
    for t in templates {
        let bare = declName(t.decl)
        guard !bare.isEmpty else { continue }
        let key = ExternalName.encode(origin: t.origin, name: bare)
        guard existing.insert(key).inserted else { continue }
        injected.append(renamedInternal(t.decl, to: key))
        localized.insert(key)
    }
    guard !injected.isEmpty else { return SpecializeInjection(module: module, localizedNames: []) }

    let merged = NOIRModule(decls: module.decls + injected, interfaces: module.interfaces,
                            conformances: module.conformances, composites: module.composites,
                            opaqueUnderlyings: module.opaqueUnderlyings,
                            externalMutatingMethods: module.externalMutatingMethods,
                            monoTypeArgs: module.monoTypeArgs)
    return SpecializeInjection(module: merged, localizedNames: localized)
}

private func declName(_ d: NOIRDecl) -> String {
    switch d {
    case .funcDecl(let f):   return f.name
    case .structDecl(let s): return s.name
    case .enumDecl(let e):   return e.name
    case .classDecl(let c):  return c.name
    case .actorDecl(let a):  return a.name
    }
}

// Re-key an injected template to its origin-qualified name and force internal visibility, so the call
// site (`origin@name<Args>`) matches and `Monomorphize` specializes it without re-emitting an erased copy.
// Only generic functions are injected for now; a non-function rides through unchanged.
private func renamedInternal(_ d: NOIRDecl, to key: String) -> NOIRDecl {
    guard case .funcDecl(let f) = d else { return d }
    return .funcDecl(NOIRFunc(name: key, generics: f.generics, params: f.params, returnType: f.returnType,
                              body: f.body, isMutating: f.isMutating, visibility: .internal, span: f.span))
}
