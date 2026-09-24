import ast
import support
import modules
import parse
import Foundation

private let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)

// Reconstruct external (body-free) declarations from an imported interface, for the consumer's Sema
// (task 100.4.2). Types are re-parsed from their `.nmi` text through the real parser — no second
// grammar. Everything is `public` (only public symbols reach a `.nmi`) and generic-free (subset).
public func interfaceToDecls(_ iface: ModuleInterface) -> [TopDecl] {
    func typeRef(_ s: String) -> TypeRef { parseTypeText(s) ?? TypeRef(name: s, span: zeroSpan) }

    var out: [TopDecl] = []
    for t in iface.types {
        let fields = t.fields.map { VarField(name: $0.name, type: typeRef($0.type), isMutable: $0.isMutable, span: zeroSpan) }
        if t.keyword == "class" {
            out.append(.classDecl(ClassDecl(name: t.name, generics: [], fields: fields, properties: [],
                                            methods: [], conformances: [], visibility: .public, span: zeroSpan)))
        } else {
            out.append(.structDecl(StructDecl(name: t.name, generics: [], fields: fields, properties: [],
                                              methods: [], conformances: [], visibility: .public, span: zeroSpan)))
        }
    }
    for f in iface.functions {
        let params = f.params.map { Param(label: $0.label, name: $0.name, type: typeRef($0.type), span: zeroSpan) }
        out.append(.funcDecl(FuncDecl(name: f.name, generics: [], params: params,
                                      returnType: f.ret.map(typeRef), body: [], isStatic: false,
                                      visibility: .public, span: zeroSpan)))
    }
    return out
}

// A module's public interface (task 100.4.1) — the body-free surface a consumer compiles against.
// Serialized as JSON for now: textual and inspectable, and it round-trips for free (the bespoke binary
// is task 162). Subset to start: non-generic public free functions and public struct/class types with
// their field layouts. Enums, methods, generics, conformances, and the mutating/shareability facts
// layer in as separate compilation matures.

public struct ModuleInterface: Codable, Equatable {
    public var package: String
    public var modulePath: [String]
    public var types: [InterfaceType]
    public var functions: [InterfaceFunc]
    // Modules this one re-exports via `public import` (task 100.2.4). A consumer follows these to admit
    // the re-exported modules' public surfaces into its own, each keeping its origin module's identity
    // (so a re-exported call still links to the true producer). Recorded here so re-export resolution is
    // interface-mediated — a downstream sees the edge without the re-exporter's source.
    public var reexports: [InterfaceRef]
    public init(package: String, modulePath: [String], types: [InterfaceType], functions: [InterfaceFunc],
                reexports: [InterfaceRef] = []) {
        self.package = package; self.modulePath = modulePath; self.types = types; self.functions = functions
        self.reexports = reexports
    }
}

// A reference to another module's interface: its package + relative module path (task 100.2.4).
public struct InterfaceRef: Codable, Equatable {
    public var package: String
    public var modulePath: [String]
    public init(package: String, modulePath: [String]) { self.package = package; self.modulePath = modulePath }
}

public struct InterfaceFunc: Codable, Equatable {
    public var name: String; public var params: [InterfaceParam]; public var ret: String?
    public init(name: String, params: [InterfaceParam], ret: String?) {
        self.name = name; self.params = params; self.ret = ret
    }
}
public struct InterfaceParam: Codable, Equatable {
    public var label: String; public var name: String; public var type: String
    public init(label: String, name: String, type: String) { self.label = label; self.name = name; self.type = type }
}
public struct InterfaceType: Codable, Equatable {
    public var keyword: String; public var name: String; public var fields: [InterfaceField]
    public init(keyword: String, name: String, fields: [InterfaceField]) {
        self.keyword = keyword; self.name = name; self.fields = fields
    }
}
public struct InterfaceField: Codable, Equatable {
    public var name: String; public var type: String; public var isMutable: Bool
    public init(name: String, type: String, isMutable: Bool) {
        self.name = name; self.type = type; self.isMutable = isMutable
    }
}

// Build the interface of one module from the merged program: its `public`, non-generic declarations
// whose file lies in the module's directory. Deterministic — declarations are name-sorted.
public func buildInterface(_ program: Program, package: String, module: ModuleID, packageRoot: String) -> ModuleInterface {
    func inModule(_ span: Span) -> Bool { moduleID(forFile: span.file, packageRoot: packageRoot) == module }

    var types: [InterfaceType] = []
    var funcs: [InterfaceFunc] = []
    for decl in program.decls {
        switch decl {
        case .funcDecl(let f) where f.visibility == .public && f.generics.isEmpty && inModule(f.span):
            funcs.append(InterfaceFunc(
                name: f.name,
                params: f.params.map { InterfaceParam(label: $0.label, name: $0.name, type: renderType($0.type)) },
                ret: f.returnType.map(renderType)))
        case .structDecl(let s) where s.visibility == .public && s.generics.isEmpty && inModule(s.span):
            types.append(InterfaceType(keyword: "struct", name: s.name,
                fields: s.fields.map { InterfaceField(name: $0.name, type: renderType($0.type), isMutable: $0.isMutable) }))
        case .classDecl(let c) where c.visibility == .public && c.generics.isEmpty && inModule(c.span):
            types.append(InterfaceType(keyword: "class", name: c.name,
                fields: c.fields.map { InterfaceField(name: $0.name, type: renderType($0.type), isMutable: $0.isMutable) }))
        default:
            break
        }
    }
    // Re-export edges (task 100.2.4): the module's `public import`s of first-party (`pkg/…`) modules.
    // External-package public imports await cross-package linkage, so they are not recorded yet.
    var reexports: [InterfaceRef] = []
    for imp in program.imports {
        guard imp.isPublic, case .pkg = imp.root else { continue }
        reexports.append(InterfaceRef(package: package, modulePath: imp.path))
    }
    reexports.sort { $0.modulePath.lexicographicallyPrecedes($1.modulePath) }

    types.sort { $0.name < $1.name }
    funcs.sort { $0.name < $1.name }
    return ModuleInterface(package: package, modulePath: module.components, types: types,
                           functions: funcs, reexports: reexports)
}

// The `.nmi` bytes: pretty, key-sorted JSON, so the arrays' name-sort makes a byte diff mean a real
// interface change (interface byte-stability for incremental caching later).
public func serialize(_ i: ModuleInterface) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(i) else { return "" }
    return String(decoding: data, as: UTF8.self) + "\n"
}

// Parse a `.nmi` back to an interface (the consumer side; task 100.4.2). Returns nil on malformed input.
public func parseInterface(_ text: String) -> ModuleInterface? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ModuleInterface.self, from: data)
}

// Render a syntactic type reference to its `.nmi` text.
func renderType(_ t: TypeRef?) -> String {
    guard let t else { return "Void" }
    if let ex = t.existentialOf { return "any " + ex.joined(separator: " & ") }
    if let op = t.opaqueOf { return "some " + op.joined(separator: " & ") }
    if let fn = t.fn { return "(" + fn.params.map(renderType).joined(separator: ", ") + ") -> " + renderType(fn.ret) }
    if let ga = t.genericArgs, !ga.isEmpty { return t.name + "<" + ga.map(renderType).joined(separator: ", ") + ">" }
    return t.name
}
