import ast
import support

// Symbol mangling — the single source of truth for the LLVM symbol names of Nomu callables and GC
// descriptors (backend.md §3, task 203). Symbols follow Rust's v0 scheme (RFC 2603): `_R`, then a path whose
// identifiers are length-prefixed, so names never collide and `c++filt`, lldb and `perf` demangle them.
//
// The subset Nomu uses:
//   module    `C<scope>` then `Nm<component>` per further identity component (workspace name, module path)
//   function  `Nv<module><name>`; a generic instance wraps it, `I<path><type args>E`
//   type      `Nt<module><name>`, nested types `Nt<outer><inner>`
//   method    `Nv<type><method>`; an accessor `count.get` nests, `Nv(Nv<type>5count)3get`
//   closure   `NC<module>[s<index>]0`, a spawn routine `NC<module>[s<index>]5spawn`
//   GC data   `I Nd C4nomu <kind> <types> E` (or `Nd C4nomu <kind>` with no type), its pointer map
//             `Nd <descriptor> 6ptrmap`
// Modules (`m`), types (`t`), values (`v`) and GC data (`d`) are distinct namespaces, so a module and a type
// of the same name never meet. Paths directly under `C4nomu` with no workspace-name component below them
// (`Nt C4nomu <name>`) are reserved for what has no module: type parameters, `Self`, builtin named types.
//
// Two exemptions keep fixed names: the program entry `nomu_main`, and the `runtime` package's functions,
// `nomu_fn_<name>` (an empty home), since the C runtime calls them by name and they are weak-ODR.
public enum Mangle {
    // A module's identity components: workspace scope, workspace name, then the workspace-relative path.
    public typealias Module = [String]

    // A free function defined in `home` (or, for an origin-keyed name `origin@name`, in `origin`). `main` is
    // the fixed entry; an empty home is a bare runtime name.
    public static func function(_ name: String, home: Module) -> String {
        if name == "main" { return "nomu_main" }
        let (module, rest) = split(name, home: home)
        guard !module.isEmpty else { return "nomu_fn_" + bare(rest) }
        for (prefix, label) in [("clo:", ""), ("spawn:", "spawn")] where rest.hasPrefix(prefix) {
            if let index = Int(rest.dropFirst(prefix.count)) {
                return "_RNC" + modulePath(module) + disambiguator(index) + ident(label)
            }
        }
        // Type arguments name the compiling module's own types bare, so they resolve against `home`.
        let key = KeyParser.parse(rest)
        var path = "Nv" + modulePath(module) + ident(key.head)
        if !key.args.isEmpty { path = "I" + path + key.args.map { type($0, home: home) }.joined() + "E" }
        return "_R" + path
    }

    // A method or `on` handler of `type`, defined in `home` (or in the type's origin when it is origin-keyed).
    // An empty home is a bare runtime name.
    public static func method(_ typeName: String, _ method: String, home: Module) -> String {
        let (module, rest) = split(typeName, home: home)
        guard !module.isEmpty else { return "nomu_m_" + bare(rest) + "_" + bare(method) }
        var path = namedPath(KeyParser.parse(rest), module: module, home: home)
        let parts = method.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        for (i, part) in parts.enumerated() {
            // A generic method instance carries its arguments on its last part.
            let key = i == parts.count - 1 ? KeyParser.parse(part) : KeyParser.Key(head: part, args: [])
            path = "Nv" + path + ident(key.head)
            if !key.args.isEmpty { path = "I" + path + key.args.map { type($0, home: home) }.joined() + "E" }
        }
        return "_R" + path
    }

    // A GC descriptor of `kind` over `types` (a heap type, an element type, …), compiled in `home`. A
    // descriptor with no type is a singleton (`anybox`, `mailbox`).
    public static func descriptor(_ kind: String, _ types: [Type] = [], home: Module) -> String {
        let base = "NdC4nomu" + ident(kind)
        return "_R" + (types.isEmpty ? base : "I" + base + types.map { type($0, home: home) }.joined() + "E")
    }

    // A descriptor for a named heap type (class, actor, enum), by its NOIR name.
    public static func descriptor(_ kind: String, named name: String, home: Module) -> String {
        "_RI" + "NdC4nomu" + ident(kind) + type(KeyParser.parse(name), home: home) + "E"
    }

    // An actor message's descriptor: the actor type, then the handler.
    public static func messageDescriptor(_ actor: String, _ handler: String, home: Module) -> String {
        "_RNd" + String(descriptor("msg", named: actor, home: home).dropFirst(2)) + ident(handler)
    }

    // A descriptor's pointer map.
    public static func pointerMap(of descriptor: String) -> String {
        descriptor.hasPrefix("_R") ? "_RNd" + descriptor.dropFirst(2) + ident("ptrmap") : descriptor + "__ptrmap"
    }

    // The v0 type of a NOIR type.
    public static func type(_ t: Type, home: Module) -> String {
        switch t {
        case .int: return "x"
        case .uint8: return "h"
        case .uint64: return "y"
        case .double: return "d"
        case .bool: return "b"
        case .void: return "u"
        case .stringBase: return "e"
        case .rawPtr: return "Pu"
        case .ptr(let e): return "P" + type(e, home: home)
        case .array(let e): return "S" + type(e, home: home)
        case .function(let ps, let r): return "F" + ps.map { type($0, home: home) }.joined() + "E" + type(r, home: home)
        case .named(let n, _): return type(KeyParser.parse(n), home: home)
        case .generic(let b, let args):
            return namedPath(KeyParser.Key(head: b, args: args.map(KeyParser.Key.init(type:))), home: home)
        case .existential(let i): return "D" + interfacePath(i, home: home) + "EL_"
        case .composition(let is_): return "D" + is_.map { interfacePath($0, home: home) }.joined() + "EL_"
        case .opaque(let ifs, _): return "I" + reserved("some") + ifs.map { "D" + interfacePath($0, home: home) + "EL_" }.joined() + "E"
        case .typeParam(let p): return reserved(p)
        case .selfType: return reserved("Self")
        case .error: return reserved("error")
        }
    }

    // MARK: Paths

    // The module path: the crate is the scope, every further component a module (namespace `m`).
    static func modulePath(_ module: Module) -> String {
        var path = "C" + ident(module[0])
        for c in module.dropFirst() { path = "Nm" + path + ident(c) }
        return path
    }

    // A path reserved for what has no module: directly under `C4nomu`.
    static func reserved(_ name: String) -> String { "NtC4nomu" + ident(name) }

    // A named type's path: its module (the origin, or `module`, or `home`, or reserved when none applies),
    // each `.`-separated component a type, then its generic arguments, whose bare names resolve against
    // `home`.
    static func namedPath(_ key: KeyParser.Key, module: Module? = nil, home: Module) -> String {
        let (origin, rest) = ExternalName.decode(key.head).map { ($0.origin.split(separator: "/").map(String.init), $0.name) }
            ?? ([], key.head)
        let owner = origin.isEmpty ? (module ?? home) : origin
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var path = owner.isEmpty ? reserved(parts[0]) : "Nt" + modulePath(owner) + ident(parts[0])
        for p in parts.dropFirst() { path = "Nt" + path + ident(p) }
        if !key.args.isEmpty { path = "I" + path + key.args.map { type($0, home: home) }.joined() + "E" }
        return path
    }

    static func interfacePath(_ name: String, home: Module) -> String {
        namedPath(KeyParser.Key(head: name, args: []), home: home)
    }

    // A type from a parsed Monomorphize key: builtins by their codes, anything else a named path.
    static func type(_ key: KeyParser.Key, home: Module) -> String {
        if let t = key.type { return type(t, home: home) }
        switch (key.head, key.args.count) {
        case ("Int", 0): return "x"
        case ("UInt8", 0): return "h"
        case ("UInt64", 0): return "y"
        case ("Double", 0): return "d"
        case ("Bool", 0): return "b"
        case ("Void", 0): return "u"
        case ("String", 0): return "e"
        case ("RawPtr", 0): return "Pu"
        case ("Ptr", 1): return "P" + type(key.args[0], home: home)
        case ("Array", 1): return "S" + type(key.args[0], home: home)
        case ("fn", 1...):
            return "F" + key.args.dropLast().map { type($0, home: home) }.joined() + "E" + type(key.args.last!, home: home)
        case ("Self", 0), ("error", 0): return reserved(key.head)
        default:
            if key.head.hasPrefix("any_") { return "D" + interfacePath(String(key.head.dropFirst(4)), home: home) + "EL_" }
            if key.head.hasPrefix("some_") { return reserved(key.head) }
            return namedPath(key, home: home)
        }
    }

    // MARK: Identifiers

    // A v0 identifier: its byte length, a `_` when it starts with a digit or `_`, then the bytes.
    static func ident(_ s: String) -> String {
        guard let first = s.utf8.first else { return "0" }
        let needsSeparator = (first >= 0x30 && first <= 0x39) || first == 0x5F
        return "\(s.utf8.count)" + (needsSeparator ? "_" : "") + s
    }

    // A v0 disambiguator showing as `#index`: none for 0, else `s` and the base-62 number `index - 1`.
    static func disambiguator(_ index: Int) -> String {
        index == 0 ? "" : "s" + base62(index - 1)
    }

    // A v0 base-62 number: `_` for 0, else the digits of `n - 1` and `_`.
    static func base62(_ n: Int) -> String {
        guard n > 0 else { return "_" }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var v = n - 1, out: [Character] = []
        repeat { out.append(digits[v % 62]); v /= 62 } while v > 0
        return String(out.reversed()) + "_"
    }

    // A name's module and local part: an origin-keyed name names its own module.
    static func split(_ name: String, home: Module) -> (Module, String) {
        if let (origin, rest) = ExternalName.decode(name) { return (origin.split(separator: "/").map(String.init), rest) }
        return (home, name)
    }

    // A bare runtime name: the separators a name may carry folded to `_`, as the C runtime spells them.
    static func bare(_ s: String) -> String {
        String(s.map { $0 == ":" || $0 == "." || $0 == "-" ? "_" : $0 })
    }
}

// Monomorphize's specialized names and type keys (`max<Int>`, `lib@Box<gen@Cell,Array<Int>>`), parsed back
// into a head and its arguments.
enum KeyParser {
    struct Key {
        var head: String
        var args: [Key]
        var type: Type? = nil

        init(head: String, args: [Key]) { self.head = head; self.args = args }
        init(type: Type) { self.head = ""; self.args = []; self.type = type }
    }

    static func parse(_ s: String) -> Key {
        var chars = Array(s)[...]
        let key = parseKey(&chars)
        // Trailing text the grammar does not cover stays in the head, so the name is kept whole.
        return chars.isEmpty ? key : Key(head: s, args: [])
    }

    private static func parseKey(_ s: inout ArraySlice<Character>) -> Key {
        var head = ""
        while let c = s.first, c != "<", c != ">", c != "," { head.append(c); s.removeFirst() }
        var args: [Key] = []
        if s.first == "<" {
            s.removeFirst()
            while true {
                args.append(parseKey(&s))
                guard let c = s.first else { break }
                s.removeFirst()
                if c == ">" { break }
            }
        }
        return Key(head: head, args: args)
    }
}
