import ast
import support

// Signature visibility consistency (task 100.2.5): a declaration may not expose, in its signature, a
// type of lesser visibility than the declaration itself. A `public fun` returning an `internal` struct
// would place a non-public type into the module's public API — the interface (`.nmi`) it emits cannot
// carry that type, so a consumer would see a dangling reference. This guards the public surface at the
// producer, before it becomes an interface. Runs on the merged user program before the prelude is
// prepended (like `checkDuplicates`), so it flags only the module's own declarations.
//
// The rule uses the visibility rank (`private < internal < package < public`). Only a type declared in
// this module can carry sub-`public` visibility; imported types are public and builtins are always
// visible, so a referenced name absent from the module's type table is treated as visible.
public func checkVisibilityConsistency(_ program: Program, into diags: DiagnosticSink) {
    // Every user type's declared visibility, by name.
    var vis: [String: Visibility] = [:]
    for decl in program.decls {
        switch decl {
        case .structDecl(let d):    vis[d.name] = d.visibility
        case .enumDecl(let d):      vis[d.name] = d.visibility
        case .classDecl(let d):     vis[d.name] = d.visibility
        case .actorDecl(let d):     vis[d.name] = d.visibility
        case .interfaceDecl(let d): vis[d.name] = d.visibility
        case .funcDecl, .extensionDecl: break
        }
    }

    // The type names a signature reference mentions, recursing through generic arguments, existential
    // and opaque bounds, and function types. A generic parameter name (`T`) is never a top-level type,
    // so it is absent from `vis` and treated as visible.
    func mentioned(_ t: TypeRef?) -> [(name: String, span: Span)] {
        guard let t = t else { return [] }
        var out = [(t.name, t.span)]
        for i in t.existentialOf ?? [] { out.append((i, t.span)) }
        for i in t.opaqueOf ?? [] { out.append((i, t.span)) }
        for a in t.genericArgs ?? [] { out += mentioned(a) }
        if let fn = t.fn {
            for p in fn.params { out += mentioned(p) }
            out += mentioned(fn.ret)
        }
        return out
    }

    // Flag every exposed type whose visibility is below `ownerVis`. Only `public`/`package` signatures
    // constrain exposure — `internal`/`private` declarations reach no wider than their own types.
    func check(owner: String, kind: String, ownerVis: Visibility, exposes: [(role: String, ref: TypeRef?)]) {
        guard ownerVis >= .package else { return }
        for (role, ref) in exposes {
            for (name, span) in mentioned(ref) {
                guard let v = vis[name], v < ownerVis else { continue }
                diags.error("\(describe(ownerVis)) \(kind) '\(owner)' exposes \(describe(v)) type '\(name)' in its \(role); the exposed type must be at least as visible", at: span)
            }
        }
    }

    for decl in program.decls {
        switch decl {
        case .funcDecl(let f):
            check(owner: f.name, kind: "function", ownerVis: f.visibility,
                  exposes: f.params.map { (role: "parameter", ref: $0.type) } + [(role: "return type", ref: f.returnType)])
        case .structDecl(let s):
            check(owner: s.name, kind: "struct", ownerVis: s.visibility,
                  exposes: s.fields.map { (role: "field '\($0.name)'", ref: $0.type) })
        case .classDecl(let c):
            check(owner: c.name, kind: "class", ownerVis: c.visibility,
                  exposes: c.fields.map { (role: "field '\($0.name)'", ref: $0.type) })
        default:
            break
        }
    }
}

private func describe(_ v: Visibility) -> String {
    switch v {
    case .private:  return "private"
    case .internal: return "internal"
    case .package:  return "package"
    case .public:   return "public"
    }
}
