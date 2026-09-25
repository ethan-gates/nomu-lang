import ast
import support
import modules
import parse
import Foundation

private let zeroSpan = Span(startOffset: -1, endOffset: -1, map: nil)

// Reconstruct external (body-free) declarations from an imported interface, for the consumer's Sema
// (task 100.4.2). Types are re-parsed from their `.nmi` text through the real parser — no second
// grammar. Everything is `public` (only public symbols reach a `.nmi`).
//
// The `.nmi` carries the full surface (task 100.4.1): enums, generics + bounds, methods, computed
// properties, conformances, interfaces. Reconstruction covers what the consumer can use today: struct /
// class / enum types (including **generic** types, task 100.4.3.1 — the consumer monomorphizes their
// layout locally) and non-generic free functions. Deferred to the erased witness-dispatch path
// (100.4.3.2–.4): generic *functions* (no body in the consumer) and *methods* on imported types.
public func interfaceToDecls(_ iface: ModuleInterface) -> [TopDecl] {
    func typeRef(_ s: String) -> TypeRef { parseTypeText(s) ?? TypeRef(name: s, span: zeroSpan) }
    func field(_ f: InterfaceField) -> VarField {
        VarField(name: f.name, type: typeRef(f.type), isMutable: f.isMutable, span: zeroSpan)
    }
    // Reconstruct a type's generic parameters + bounds (task 100.4.3.1), so an imported generic type is
    // monomorphized locally by the consumer just like an own-module one.
    func generics(_ gs: [InterfaceGeneric]) -> [GenericParam] {
        gs.map { GenericParam(name: $0.name, bounds: $0.bounds.map { Conformance(name: $0, span: zeroSpan) },
                              isShared: $0.isShared, span: zeroSpan) }
    }

    var out: [TopDecl] = []
    // Imported interfaces (task 100.4.3.3.3): a consumer needs the requirement surface to conform its own
    // types to an imported interface and to bound-check a call to an imported generic. Bodies don't cross,
    // so a defaulted requirement reconstructs with an empty placeholder body (enough for conformance
    // checking that a default exists; invoking an imported default is a separate, deferred concern).
    for p in iface.interfaces {
        let methods = p.methods.map { m in
            InterfaceMethod(name: m.name, params: m.params.map { Param(label: $0.label, name: $0.name, type: typeRef($0.type), span: zeroSpan) },
                            returnType: m.ret.map(typeRef), defaultBody: m.hasDefault ? [] : nil,
                            isStatic: m.isStatic, span: zeroSpan)
        }
        let props = p.properties.map { InterfacePropertyReq(name: $0.name, type: typeRef($0.type), isSettable: $0.isSettable, span: zeroSpan) }
        out.append(.interfaceDecl(InterfaceDecl(name: p.name, refines: p.refines.map { Conformance(name: $0, span: zeroSpan) },
                                                methods: methods, properties: props, visibility: .public, span: zeroSpan)))
    }
    for t in iface.types {
        let fields = t.fields.map(field)
        if t.keyword == "class" {
            out.append(.classDecl(ClassDecl(name: t.name, generics: generics(t.generics), fields: fields, properties: [],
                                            methods: [], conformances: [], visibility: .public, span: zeroSpan)))
        } else {
            out.append(.structDecl(StructDecl(name: t.name, generics: generics(t.generics), fields: fields, properties: [],
                                              methods: [], conformances: [], visibility: .public, span: zeroSpan)))
        }
    }
    for e in iface.enums {
        let cases = e.cases.map { EnumCaseDecl(name: $0.name, fields: $0.fields.map(field), span: zeroSpan) }
        out.append(.enumDecl(EnumDecl(name: e.name, generics: generics(e.generics), cases: cases, properties: [],
                                      methods: [], conformances: [], visibility: .public, span: zeroSpan)))
    }
    // Free functions, generic included. A generic function reconstructs with its type parameters +
    // bounds so a consumer's call type-checks; it stays external (Sema marks it, never lowering its
    // empty body into the module — so monomorphization never sees it to clone), and a call is emitted
    // through the erased witness-dispatch ABI to the producer's compiled-once symbol (task 100.4.3.4).
    for f in iface.functions {
        let params = f.params.map { Param(label: $0.label, name: $0.name, type: typeRef($0.type), span: zeroSpan) }
        out.append(.funcDecl(FuncDecl(name: f.name, generics: generics(f.generics), params: params,
                                      returnType: f.ret.map(typeRef), body: [], isStatic: false,
                                      visibility: .public, span: zeroSpan)))
    }
    return out
}

// A module's public interface (task 100.4.1) — the body-free surface a consumer compiles against.
// Serialized as JSON for now: textual and inspectable, and it round-trips for free (the bespoke binary
// is task 162). Carries the declaration/signature surface: struct/class/enum types (with generics,
// fields, computed properties, methods, conformances), interfaces (requirements), and free functions.
// Per-type layout + GC pointer-map (task 100.4.7) and body-derived contract facts (mutating-ness /
// shareability, task 100.4.5) are added when those phases land.

public struct ModuleInterface: Codable, Equatable {
    public var package: String
    public var modulePath: [String]
    public var types: [InterfaceType]
    public var enums: [InterfaceEnum]
    public var interfaces: [InterfaceProtocol]
    public var functions: [InterfaceFunc]
    // Modules this one re-exports via `public import` (task 100.2.4). A consumer follows these to admit
    // the re-exported modules' public surfaces into its own, each keeping its origin module's identity
    // (so a re-exported call still links to the true producer). Recorded here so re-export resolution is
    // interface-mediated — a downstream sees the edge without the re-exporter's source.
    public var reexports: [InterfaceRef]
    public init(package: String, modulePath: [String], types: [InterfaceType],
                enums: [InterfaceEnum] = [], interfaces: [InterfaceProtocol] = [],
                functions: [InterfaceFunc], reexports: [InterfaceRef] = []) {
        self.package = package; self.modulePath = modulePath; self.types = types
        self.enums = enums; self.interfaces = interfaces; self.functions = functions
        self.reexports = reexports
    }
}

// A reference to another module's interface: its package + relative module path (task 100.2.4).
public struct InterfaceRef: Codable, Equatable {
    public var package: String
    public var modulePath: [String]
    public init(package: String, modulePath: [String]) { self.package = package; self.modulePath = modulePath }
}

// A generic type parameter with its interface bounds (task 100.4.1). Position is significant, so the
// generics list keeps declared order. `bounds` are interface names, name-sorted.
public struct InterfaceGeneric: Codable, Equatable {
    public var name: String; public var bounds: [String]; public var isShared: Bool
    public init(name: String, bounds: [String], isShared: Bool) {
        self.name = name; self.bounds = bounds; self.isShared = isShared
    }
}

// A free function or a type's method. `generics` is empty for a non-generic function; `isStatic` marks a
// `static fun` member (never set on a free function).
public struct InterfaceFunc: Codable, Equatable {
    public var name: String; public var generics: [InterfaceGeneric]
    public var params: [InterfaceParam]; public var ret: String?; public var isStatic: Bool
    public init(name: String, generics: [InterfaceGeneric] = [], params: [InterfaceParam],
                ret: String?, isStatic: Bool = false) {
        self.name = name; self.generics = generics; self.params = params; self.ret = ret; self.isStatic = isStatic
    }
}
public struct InterfaceParam: Codable, Equatable {
    public var label: String; public var name: String; public var type: String
    public init(label: String, name: String, type: String) { self.label = label; self.name = name; self.type = type }
}
// A computed property on a type, or a property requirement on an interface. `isSettable` is `{ get set }`
// vs `{ get }` — it also determines whether a `name.set` witness slot exists.
public struct InterfaceProperty: Codable, Equatable {
    public var name: String; public var type: String; public var isSettable: Bool
    public init(name: String, type: String, isSettable: Bool) {
        self.name = name; self.type = type; self.isSettable = isSettable
    }
}
// A struct or class type (`keyword`). Carries its generic parameters, stored fields (declared order —
// layout-significant), computed properties, methods, and the interfaces it conforms to.
public struct InterfaceType: Codable, Equatable {
    public var keyword: String; public var name: String; public var generics: [InterfaceGeneric]
    public var fields: [InterfaceField]; public var properties: [InterfaceProperty]
    public var methods: [InterfaceFunc]; public var conformances: [String]
    public init(keyword: String, name: String, generics: [InterfaceGeneric] = [], fields: [InterfaceField],
                properties: [InterfaceProperty] = [], methods: [InterfaceFunc] = [], conformances: [String] = []) {
        self.keyword = keyword; self.name = name; self.generics = generics; self.fields = fields
        self.properties = properties; self.methods = methods; self.conformances = conformances
    }
}
public struct InterfaceField: Codable, Equatable {
    public var name: String; public var type: String; public var isMutable: Bool
    public init(name: String, type: String, isMutable: Bool) {
        self.name = name; self.type = type; self.isMutable = isMutable
    }
}
// An enum type. Cases keep declared order (discriminant-significant); their payloads are labelled fields.
public struct InterfaceEnum: Codable, Equatable {
    public var name: String; public var generics: [InterfaceGeneric]; public var cases: [InterfaceCase]
    public var properties: [InterfaceProperty]; public var methods: [InterfaceFunc]; public var conformances: [String]
    public init(name: String, generics: [InterfaceGeneric] = [], cases: [InterfaceCase],
                properties: [InterfaceProperty] = [], methods: [InterfaceFunc] = [], conformances: [String] = []) {
        self.name = name; self.generics = generics; self.cases = cases
        self.properties = properties; self.methods = methods; self.conformances = conformances
    }
}
public struct InterfaceCase: Codable, Equatable {
    public var name: String; public var fields: [InterfaceField]
    public init(name: String, fields: [InterfaceField]) { self.name = name; self.fields = fields }
}
// An interface (protocol). `refines` are base interfaces. `methods`/`properties` are the requirements,
// name-sorted; the witness-table slot order is derived from them by the pinned rule (slot keys `name`,
// `name.get`, `name.set` in lexicographic order — see task 100.4.1). `hasDefault` marks a method a
// conformer may omit (an overridable default).
public struct InterfaceProtocol: Codable, Equatable {
    public var name: String; public var refines: [String]
    public var methods: [InterfaceMethodReq]; public var properties: [InterfaceProperty]
    public init(name: String, refines: [String] = [], methods: [InterfaceMethodReq] = [],
                properties: [InterfaceProperty] = []) {
        self.name = name; self.refines = refines; self.methods = methods; self.properties = properties
    }
}
public struct InterfaceMethodReq: Codable, Equatable {
    public var name: String; public var params: [InterfaceParam]; public var ret: String?
    public var isStatic: Bool; public var hasDefault: Bool
    public init(name: String, params: [InterfaceParam], ret: String?, isStatic: Bool, hasDefault: Bool) {
        self.name = name; self.params = params; self.ret = ret; self.isStatic = isStatic; self.hasDefault = hasDefault
    }
}

// MARK: - Emit

private func renderGenerics(_ gs: [GenericParam]) -> [InterfaceGeneric] {
    gs.map { InterfaceGeneric(name: $0.name, bounds: $0.bounds.map(\.name).sorted(), isShared: $0.isShared) }
}
private func renderParams(_ ps: [Param]) -> [InterfaceParam] {
    ps.map { InterfaceParam(label: $0.label, name: $0.name, type: renderType($0.type)) }
}
// A public type exports all of its members (pinned policy, task 100.4.1). Methods are name-sorted for
// determinism; a static method carries `isStatic`.
private func renderMethods(_ ms: [FuncDecl]) -> [InterfaceFunc] {
    ms.map { InterfaceFunc(name: $0.name, generics: renderGenerics($0.generics), params: renderParams($0.params),
                           ret: $0.returnType.map(renderType), isStatic: $0.isStatic) }
      .sorted { $0.name < $1.name }
}
private func renderProperties(_ ps: [ComputedProperty]) -> [InterfaceProperty] {
    ps.map { InterfaceProperty(name: $0.name, type: renderType($0.type), isSettable: $0.setter != nil) }
      .sorted { $0.name < $1.name }
}
private func renderCases(_ cs: [EnumCaseDecl]) -> [InterfaceCase] {
    cs.map { c in InterfaceCase(name: c.name,
        fields: c.fields.map { InterfaceField(name: $0.name, type: renderType($0.type), isMutable: $0.isMutable) }) }
}
private func renderConformances(_ cs: [Conformance]) -> [String] { cs.map(\.name).sorted() }

// Build the interface of one module from the merged program: its `public` declarations whose file lies
// in the module's directory. Deterministic — top-level declarations are name-sorted, as are the
// order-insensitive members (see the pinned conventions in task 100.4.1).
public func buildInterface(_ program: Program, package: String, module: ModuleID, packageRoot: String) -> ModuleInterface {
    func inModule(_ span: Span) -> Bool { moduleID(forFile: span.file, packageRoot: packageRoot) == module }

    var types: [InterfaceType] = []
    var enums: [InterfaceEnum] = []
    var interfaces: [InterfaceProtocol] = []
    var funcs: [InterfaceFunc] = []
    for decl in program.decls {
        switch decl {
        case .funcDecl(let f) where f.visibility == .public && inModule(f.span):
            funcs.append(InterfaceFunc(name: f.name, generics: renderGenerics(f.generics),
                params: renderParams(f.params), ret: f.returnType.map(renderType)))
        case .structDecl(let s) where s.visibility == .public && inModule(s.span):
            types.append(InterfaceType(keyword: "struct", name: s.name, generics: renderGenerics(s.generics),
                fields: s.fields.map { InterfaceField(name: $0.name, type: renderType($0.type), isMutable: $0.isMutable) },
                properties: renderProperties(s.properties), methods: renderMethods(s.methods),
                conformances: renderConformances(s.conformances)))
        case .classDecl(let c) where c.visibility == .public && inModule(c.span):
            types.append(InterfaceType(keyword: "class", name: c.name, generics: renderGenerics(c.generics),
                fields: c.fields.map { InterfaceField(name: $0.name, type: renderType($0.type), isMutable: $0.isMutable) },
                properties: renderProperties(c.properties), methods: renderMethods(c.methods),
                conformances: renderConformances(c.conformances)))
        case .enumDecl(let e) where e.visibility == .public && inModule(e.span):
            enums.append(InterfaceEnum(name: e.name, generics: renderGenerics(e.generics), cases: renderCases(e.cases),
                properties: renderProperties(e.properties), methods: renderMethods(e.methods),
                conformances: renderConformances(e.conformances)))
        case .interfaceDecl(let i) where i.visibility == .public && inModule(i.span):
            let methods = i.methods.map { m in
                InterfaceMethodReq(name: m.name, params: renderParams(m.params), ret: m.returnType.map(renderType),
                                   isStatic: m.isStatic, hasDefault: m.defaultBody != nil) }
                .sorted { $0.name < $1.name }
            let props = i.properties.map { InterfaceProperty(name: $0.name, type: renderType($0.type), isSettable: $0.isSettable) }
                .sorted { $0.name < $1.name }
            interfaces.append(InterfaceProtocol(name: i.name, refines: i.refines.map(\.name).sorted(),
                                                methods: methods, properties: props))
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
    enums.sort { $0.name < $1.name }
    interfaces.sort { $0.name < $1.name }
    funcs.sort { $0.name < $1.name }
    return ModuleInterface(package: package, modulePath: module.components, types: types, enums: enums,
                           interfaces: interfaces, functions: funcs, reexports: reexports)
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
