// Symbol mangling — the single source of truth for the LLVM symbol names of Nomu callables
// (task 100.2.6; backend.md §3). The scheme was duplicated: the SSAIR egress (`keyAndSelf`) and the
// on-demand declarations (`LLVMGenCallables.declare*`, reached from witness/actor codegen) each built
// `nomu_fn_`/`nomu_m_`/`nomu_on_` names independently and had to stay in lockstep. Both now route
// through here, so the scheme has one home.
//
// The program entry stays `nomu_main` — the C runtime calls it by that name (runtime.c).
//
// Cross-module linkage qualifies a symbol by its origin module so two modules sharing a name do not
// collide at link (task 100.4). The `qualifier` is the module's canonical identity components (`_`-joined),
// and the producer and a consumer derive it identically — the producer from its own module identity, a
// consumer from the origin encoded in an imported reference. Since cross-package linkage (task 187.3) the
// canonical identity is `workspace-name` + the module's workspace-relative path, so two packages (and,
// with 187.5, two workspaces) that share a module name never collide. The C-ABI prelude/runtime symbols
// keep the empty qualifier (bare names): the C runtime pins them (`nomu_main`, `nomu_actor_drain`, the
// `nomu_fn_<name>` runtime leaves), and they are language-owned, folded weak-ODR. The entry binary is bare
// too — nothing imports it.
public enum Mangle {
    // The symbol qualifier for a module: its canonical identity components, `_`-joined with a trailing `_`.
    // Empty for a bare-named symbol (prelude/runtime, the entry).
    public static func qualifier(module components: [String]) -> String {
        components.isEmpty ? "" : components.map(sanitize).joined(separator: "_") + "_"
    }

    // A free function. `main` is the fixed entry symbol; everything else is `nomu_fn_<qualifier><name>`.
    static func free(_ name: String, qualifier: String = "") -> String {
        name == "main" ? "nomu_main" : "nomu_fn_\(qualifier)\(sanitize(name))"
    }

    // An instance/static method: `nomu_m_<qualifier><type>_<method>`.
    static func method(_ type: String, _ method: String, qualifier: String = "") -> String {
        "nomu_m_\(qualifier)\(type)_\(sanitize(method))"
    }

    // An actor `on`-handler: `nomu_on_<qualifier><actor>_<handler>`.
    static func actorHandler(_ actor: String, _ handler: String, qualifier: String = "") -> String {
        "nomu_on_\(qualifier)\(actor)_\(sanitize(handler))"
    }

    // Fold the separators a Nomu name may carry (`:` from callable keys, `.` from qualified members) and
    // the `-` a workspace/package name may carry (task 187.3 — the first identity component) into a valid
    // C-identifier symbol. Generic instances are already `<>`-encoded by Monomorphize.
    static func sanitize(_ s: String) -> String {
        String(s.map { $0 == ":" || $0 == "." || $0 == "-" ? "_" : $0 })
    }
}
