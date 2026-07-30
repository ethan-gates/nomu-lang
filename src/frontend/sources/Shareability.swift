// The structural share-analysis predicate (design: concurrency.md §5, generics.md §7):
// which types can cross a task boundary. Shared by Sema (discharging a `<shared T>`
// bound at generic call sites, on AST decls) and codegen (the `spawn`-capture check,
// on IR decls) — each supplies a `lookup` that reports a named type's fields.
//
// Rules:
//   - primitives, `String` (immutable), and actor handles are always shareable;
//   - a struct / enum is shareable iff every stored field is (across all enum cases);
//   - a class is shareable only when **deeply immutable** — every field `let` and
//     itself shareable (the case M3 conservatively rejected);
//   - a generic instance `Box<T>` substitutes the base's type params → args, then
//     checks the base's fields (conditional conformance).
// `visiting` breaks cycles on recursive types: a back-edge is assumed shareable and
// the decision falls to the other fields.
public struct Shareability {
    // A named type's shape, as the caller sees it (AST or IR).
    public struct Decl {
        public let fields: [(type: Type, isMutable: Bool)]   // all stored fields (enum: across cases)
        public let isClass: Bool                              // class ⇒ the deeply-immutable rule
        public let params: [String]                           // generic parameter names, to zip with args
        public init(fields: [(type: Type, isMutable: Bool)], isClass: Bool, params: [String]) {
            self.fields = fields; self.isClass = isClass; self.params = params
        }
    }

    private let lookup: (String) -> Decl?

    public init(lookup: @escaping (String) -> Decl?) { self.lookup = lookup }

    public func isShareable(_ t: Type, visiting: Set<String> = []) -> Bool {
        switch t {
        case .int, .bool, .string, .named(_, .actor_):
            return true
        case .named(let name, _):
            return named(name, args: [], visiting: visiting)
        case .generic(let base, let args):
            return named(base, args: args, visiting: visiting)
        default:
            // closures (checked per-binding by codegen), `any`/`some`, `Self`, a bare
            // type parameter, `void`, `error` — not structurally shareable here.
            return false
        }
    }

    private func named(_ name: String, args: [Type], visiting: Set<String>) -> Bool {
        guard let d = lookup(name) else { return false }
        let key = args.isEmpty ? name : "\(name)<\(args.map(\.description).joined(separator: ","))>"
        if visiting.contains(key) { return true }                          // cycle back-edge
        if d.isClass && d.fields.contains(where: { $0.isMutable }) { return false }
        let subst = Dictionary(uniqueKeysWithValues: zip(d.params, args))
        let v = visiting.union([key])
        return d.fields.allSatisfy { isShareable(substitute($0.type, subst), visiting: v) }
    }

    // Apply a type-parameter substitution (base params → concrete args) to a field
    // type, recursing through nested generics / function types.
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
}
