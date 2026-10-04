import noir
import facts

// Fact collection (task 164.1) — Sema's cheap structural facts written into the shared fact store, keyed
// by a per-definition mangled `SymbolID`. The store is the hub the post-inference `.nmi` emit (164.4) and
// the transforms read; populating it here replaces stuffing these facts into `buildInterface` (which runs
// pre-Sema on the AST and so cannot carry them — the misalignment task 164 fixes).
//
// Key convention: `Type.method` for a method, the bare name for a type or free function. Per-definition (a
// public generic is one record over its erased body), matching the mutating-ness fixpoint's method key.
// This is the symbol-key convention the mid-end (escape summary) and emit sides must share.
//
// Today only mutating-ness is collected. Type shareability + conditional conformance, and the dependency
// compile path, are the remaining 164.1 writers.
public func collectFacts(_ module: NOIRModule) -> FactStore {
    var store = FactStore()
    func writeMethods(_ typeName: String, _ methods: [NOIRFunc]) {
        for m in methods {
            store.update(SymbolID("\(typeName).\(m.name)")) { $0.abi.mutating = m.isMutating }
        }
    }
    for decl in module.decls {
        switch decl {
        case .structDecl(let s): writeMethods(s.name, s.methods)
        case .classDecl(let c):  writeMethods(c.name, c.methods)
        case .enumDecl(let e):   writeMethods(e.name, e.methods)
        default: break
        }
    }
    return store
}
