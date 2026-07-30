// Symbol mangling — the single place that turns a Nomu name into a C identifier.
//
// Generated Nomu symbols share C's global namespace, so an unmangled name that
// matches a libc symbol (`abs`, `free`, `read`, …) is a link/compile collision.
// Every globally-visible generated identifier (functions, types, methods, enum
// tags, constructors) is routed through here to get a reserved prefix + a readable,
// reversible encoding. Struct fields and locals are scoped, so they are left alone.
//
// Fully-qualified form: `nomu_<module>_<scope…>_<symbol>`, each component
// **9-encoded** so the `_` join is unambiguous — a literal `_` in a Nomu name
// becomes `90`, a `.` becomes `91`, and the escape char `9` itself becomes `99`.
// The escape and its code are **all digits** on purpose: letters are never touched,
// so every letter in a mangled name is a real source letter and words stay readable;
// a digit run is always machinery. A top-level symbol has no scope
// (`abs` → `nomu_main_abs`); a method's scope is its type
// (`Rect.area` → `nomu_main_Rect_area`). The module is an implied "main" until real
// modules exist (modules.md). Plain names stay readable; only underscores, dots, and
// the rare digit-`9` pick up noise. Components are never at position 0 (the `nomu_`
// prefix leads), so a digit-led escape can't start an identifier. Fully
// de-mangleable. This whole scheme is swappable here.
enum Mangle {
    static let prefix = "nomu_"

    // The current compilation unit's module. Real modules are later work
    // (modules.md); until then every symbol is qualified under an implied "main".
    static let module = "main"

    // 9-encode one Nomu identifier component. Nomu identifiers are [A-Za-z0-9_], so
    // `_` (freed for use as the component separator) and `9` (the escape) need
    // escaping; `.` appears in compiler-synthesized accessor names (`area.get`,
    // M5 A1) and encodes too, keeping those out of any user method's name space.
    // Escape and codes are all digits (not letters), so every letter in a mangled
    // name is a real source letter. The generic-instance brackets from monomorphization
    // (M5 5.4) — a specialized name is `Box<Int>` / `describe<Circle>` — encode too.
    static func encode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "9": out += "99"
            case "_": out += "90"
            case ".": out += "91"
            case "<": out += "92"   // generic-instance open (M5 5.4)
            case ">": out += "93"   // generic-instance close
            case ",": out += "94"   // type-argument separator
            default:  out.append(ch)
            }
        }
        return out
    }

    // nomu_<module>_<scope…>_<symbol>: the module, then any enclosing scopes, then
    // the symbol — each 9-encoded, joined by `_`.
    static func qualify(_ scopesAndSymbol: [String]) -> String {
        prefix + ([module] + scopesAndSymbol).map(encode).joined(separator: "_")
    }

    // A free (top-level) function. `main` is the process entry the runtime calls by a
    // fixed name (nomu_runtime.c → `extern void nomu_main(void)`), so it is exempt.
    static func function(_ name: String) -> String {
        name == "main" ? "nomu_main" : qualify([name])
    }

    // A nominal type (struct/enum/class/actor).
    static func type(_ name: String) -> String { qualify([name]) }

    // A method / actor handler: scoped under its type.
    static func method(_ typeName: String, _ member: String) -> String {
        qualify([typeName, member])
    }

    // An enum value tag (C enum constant) and the tag enum's type name.
    static func tag(_ enumName: String, _ caseName: String) -> String {
        qualify([enumName, caseName])
    }
    static func tagType(_ enumName: String) -> String { qualify([enumName]) + "_tag" }

    // Witness tables (M5 A1.4): the per-interface struct type, the per-conformance
    // instance, and the uniform-signature thunk wrapping one requirement's impl.
    static func witnessType(_ iface: String) -> String { qualify([iface]) + "_witness" }
    static func witnessInstance(_ type: String, _ iface: String) -> String { qualify([type, iface]) + "_witness" }
    static func witnessThunk(_ type: String, _ iface: String, _ slot: String) -> String { qualify([type, iface, slot]) + "_thunk" }

    // Composite witnesses (M5 A1.5b): the per-composition struct type and per-type instance.
    static func compositeType(_ ifaces: [String]) -> String { qualify(["comp"] + ifaces) }
    static func compositeInstance(_ type: String, _ ifaces: [String]) -> String { qualify([type, "comp"] + ifaces) }

    // Compiler-synthesized members on a reference type.
    static func ctor(_ typeName: String) -> String { qualify([typeName]) + "_new" }
    static func release(_ typeName: String) -> String { qualify([typeName]) + "_release" }
    static func deinitFn(_ typeName: String) -> String { qualify([typeName]) + "_deinit" }
}
