import support
// MARK: - Type references

// A named type (`Int`, `Point`) or a function type (`(Int) -> Int`).
// `name` is a canonical rendering usable as a dictionary key; `fn` is set for function types.
// A reference type so function types can recurse (a struct here would be infinite-size).
public final class TypeRef {
    public let name: String
    public let fn: FnType?
    public let existentialOf: [String]?   // set for `any I` / `any A & B` — the interface names (M5 A1.4/A1.5b)
    public let opaqueOf: [String]?        // set for `some I` / `some A & B` — the interface names (M5 A3)
    public let genericArgs: [TypeRef]?    // set for an applied generic type `Box<Int>` (M5 5.2.1)
    public let qualifier: String?         // set for a module-qualified type `util.Point` (task 100.2.3.2)
    public let span: Span

    public init(name: String, fn: FnType? = nil, existentialOf: [String]? = nil, opaqueOf: [String]? = nil, genericArgs: [TypeRef]? = nil, qualifier: String? = nil, span: Span) {
        self.name = name
        self.fn = fn
        self.existentialOf = existentialOf
        self.opaqueOf = opaqueOf
        self.genericArgs = genericArgs
        self.qualifier = qualifier
        self.span = span
    }
}

public struct FnType {
    public let params: [TypeRef]
    public let ret: TypeRef?   // nil = void

    public init(params: [TypeRef], ret: TypeRef?) {
        self.params = params
        self.ret = ret
    }
}

// MARK: - Program

public struct Program {
    public let decls: [TopDecl]
    public let imports: [ImportDecl]   // per-file imports (task 100.2); file identity via each span

    public init(decls: [TopDecl], imports: [ImportDecl] = []) {
        self.decls = decls
        self.imports = imports
    }
}

// Per-origin identity for an imported symbol (task 100.2.3.2). Two modules may export the same name, so
// on the consumer side an imported symbol is keyed by `origin@name` (origin = the producer module's
// relative path) — unique even under a name collision. Resolution rewrites a user reference (bare when
// unambiguous, or qualified `mod.name`) to this key; codegen decodes it back to the producer's mangled
// symbol. `@` cannot appear in a Nomu identifier or module path component, so the split is unambiguous.
public enum ExternalName {
    public static func encode(origin: String, name: String) -> String { origin + "@" + name }
    public static func decode(_ key: String) -> (origin: String, name: String)? {
        guard let at = key.firstIndex(of: "@") else { return nil }
        return (String(key[key.startIndex..<at]), String(key[key.index(after: at)...]))
    }
    public static func isEncoded(_ key: String) -> Bool { key.contains("@") }
}

// One source file's parse result within a module (task 100.2.3.1). A module is represented as its files
// rather than a single concatenated `Program`, so per-file imports survive: a module shares one symbol
// namespace across its files, but **imports are file-scoped** (Go's model). `.decls`/`.imports` mirror
// `Program`, so the module-wide passes can still operate on the union view (`files.flatMap(\.decls)`).
public struct SourceFile {
    public let path: String
    public let decls: [TopDecl]
    public let imports: [ImportDecl]

    public init(path: String, decls: [TopDecl], imports: [ImportDecl]) {
        self.path = path
        self.decls = decls
        self.imports = imports
    }
}

// A per-file import (modules.md §Imports; syntax.md §3). Imports form a block at the top of the file.
// `import pkg/util/parse` is first-party (the `pkg` root = the importing file's own package);
// `import foo` / `import foo/bar` names an external package's root module or a submodule. `as` renames
// the local qualifier only; `public import` re-exports; `test import` widens test-module access.
// Conditional imports (task 141) will later wrap these in a comptime block within the same section.
public enum ImportRoot: Equatable {
    case pkg                  // `pkg/…` — the importing file's own package
    case package_(String)     // `foo/…` — an external package named `foo`
}

public struct ImportDecl {
    public let root: ImportRoot
    public let path: [String]     // components after the root: `pkg/util/parse` → ["util", "parse"]
    public let alias: String?     // `as bar` — renames the local qualifier
    public let isPublic: Bool     // `public import` — re-export into this module's public API
    public let isTest: Bool       // `test import` — white-box access for a test module
    public let span: Span

    public init(root: ImportRoot, path: [String], alias: String?, isPublic: Bool, isTest: Bool, span: Span) {
        self.root = root; self.path = path; self.alias = alias
        self.isPublic = isPublic; self.isTest = isTest; self.span = span
    }

    // The imported module's leaf name — the bare qualifier at use sites (`net.Client` → "net"),
    // overridden by an alias.
    public var leafName: String {
        if let alias { return alias }
        if let last = path.last { return last }
        if case .package_(let name) = root { return name }
        return "pkg"
    }
}

// MARK: - Top-level declarations

public enum TopDecl {
    case structDecl(StructDecl)
    case enumDecl(EnumDecl)
    case classDecl(ClassDecl)
    case actorDecl(ActorDecl)
    case interfaceDecl(InterfaceDecl)
    case funcDecl(FuncDecl)
    case extensionDecl(ExtensionDecl)
}

// A declaration's reach across the module system (modules.md §visibility), widest last. `private` is
// file-scoped; `internal` — the default — is module-scoped; `package` reaches every module in the
// package; `public` is the module's external API. Written as a contextual prefix modifier, so the
// words stay usable as identifiers. `rank` orders the tiers for consistency checks (a symbol may not
// expose one of lesser reach in its public/package signature).
public enum Visibility: Int, Comparable {
    case `private` = 0    // visible in its file only
    case `internal` = 1   // visible in its module (default)
    case `package` = 2    // visible to every module in the package
    case `public` = 3     // visible externally — the module API

    public static func < (a: Visibility, b: Visibility) -> Bool { a.rawValue < b.rawValue }
}

// An interface (M5 A1; interfaces.md §1). Its body holds method requirements — a bare
// signature is mandatory, a signature with a body is an overridable default — and
// property requirements (`var x: T { get }` / `{ get set }`, accessor-shaped, never
// storage). Conformance (`extension T: I`), `any`/`some`, and refinement come later.
public struct InterfaceDecl {
    public let name: String
    public let refines: [Conformance]   // M5 A1.5: base interfaces (`interface B: A`)
    public let methods: [InterfaceMethod]
    public let properties: [InterfacePropertyReq]
    public let visibility: Visibility
    public let span: Span

    public init(name: String, refines: [Conformance], methods: [InterfaceMethod], properties: [InterfacePropertyReq], visibility: Visibility = .internal, span: Span) {
        self.name = name; self.refines = refines; self.methods = methods; self.properties = properties; self.visibility = visibility; self.span = span
    }
}

public struct InterfaceMethod {
    public let name: String
    public let params: [Param]
    public let returnType: TypeRef?
    public let defaultBody: Block?    // nil = mandatory requirement; non-nil = overridable default
    public let isStatic: Bool         // `static fun` requirement — satisfied by a static method, called `T.name(…)`
    public let span: Span

    public init(name: String, params: [Param], returnType: TypeRef?, defaultBody: Block?, isStatic: Bool = false, span: Span) {
        self.name = name; self.params = params; self.returnType = returnType; self.defaultBody = defaultBody; self.isStatic = isStatic; self.span = span
    }
}

public struct InterfacePropertyReq {
    public let name: String
    public let type: TypeRef
    public let isSettable: Bool        // `{ get }` vs `{ get set }`
    public let span: Span

    public init(name: String, type: TypeRef, isSettable: Bool, span: Span) {
        self.name = name; self.type = type; self.isSettable = isSettable; self.span = span
    }
}

// A named interface a type declares conformance to (`struct T: I`, `extension T: I`).
// Carries the name's span for locality in conformance diagnostics (M5 A1.3).
public struct Conformance {
    public let name: String
    public let span: Span

    public init(name: String, span: Span) {
        self.name = name; self.span = span
    }
}

// A generic type parameter with optional interface bounds: `<T>`, `<T: I>`, `<T: I & J>`
// (M5 5.2.1). Bounds reuse `Conformance` (name + span).
public struct GenericParam {
    public let name: String
    public let bounds: [Conformance]
    public let isShared: Bool   // `<shared T>` — the type argument must be shareable (M5 5.3.2)
    public let span: Span

    public init(name: String, bounds: [Conformance], isShared: Bool = false, span: Span) {
        self.name = name; self.bounds = bounds; self.isShared = isShared; self.span = span
    }
}

// An extension: `extension T { … }` (plain, M4.12) or `extension T: I { … }` (a
// conformance extension supplying I's witnesses, M5 A1.3). Its methods are folded
// into the target type's member set by the merge pass, and a conformance form also
// records `T: I` onto the target. Stored properties are not allowed here.
public struct ExtensionDecl {
    public let typeName: String
    public let typeNameSpan: Span   // for target-validation diagnostics
    public let conformance: Conformance?   // nil = plain extension; set = `extension T: I`
    public let methods: [FuncDecl]
    public let properties: [ComputedProperty]   // M5: computed properties (get/set); stored fields rejected
    public let span: Span

    public init(typeName: String, typeNameSpan: Span, conformance: Conformance?, methods: [FuncDecl], properties: [ComputedProperty], span: Span) {
        self.typeName = typeName; self.typeNameSpan = typeNameSpan; self.conformance = conformance; self.methods = methods; self.properties = properties; self.span = span
    }
}

public struct StructDecl {
    public let name: String
    public let generics: [GenericParam]   // M5 5.2.1: `struct Box<T>` type parameters (empty for non-generic)
    public let fields: [VarField]
    public let properties: [ComputedProperty]   // M5 A1: computed properties (get / get-set)
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let conformances: [Conformance]   // M5 A1.3: interfaces this type conforms to
    public let visibility: Visibility
    public let span: Span

    public init(name: String, generics: [GenericParam], fields: [VarField], properties: [ComputedProperty], methods: [FuncDecl], conformances: [Conformance], visibility: Visibility = .internal, span: Span) {
        self.name = name; self.generics = generics; self.fields = fields; self.properties = properties; self.methods = methods; self.conformances = conformances; self.visibility = visibility; self.span = span
    }
}

public struct VarField {
    public let name: String
    public let type: TypeRef
    public let isMutable: Bool   // `var` field vs `let` field (M4.10 field-level immutability)
    public let span: Span

    public init(name: String, type: TypeRef, isMutable: Bool, span: Span) {
        self.name = name; self.type = type; self.isMutable = isMutable; self.span = span
    }
}

// A computed property `var x: T { get { … } set(v) { … } }` (M5 A1; generics.md §3a).
// Not storage — the getter (and optional setter) are accessor bodies. A bare-body
// form `var x: T { <expr> }` is an implicit read-only get (setter == nil). The setter
// binds its incoming value explicitly (`set(v)`), not Swift's implicit `newValue`.
public struct ComputedProperty {
    public let name: String
    public let type: TypeRef
    public let getter: Block
    public let setter: Setter?        // nil = read-only
    public let span: Span

    public init(name: String, type: TypeRef, getter: Block, setter: Setter?, span: Span) {
        self.name = name; self.type = type; self.getter = getter; self.setter = setter; self.span = span
    }
}

public struct Setter {
    public let paramName: String      // the explicit `set(name)` binding
    public let body: Block

    public init(paramName: String, body: Block) {
        self.paramName = paramName; self.body = body
    }
}

public struct EnumDecl {
    public let name: String
    public let generics: [GenericParam]   // M5 5.2.1: `enum Option<T>` type parameters (empty for non-generic)
    public let cases: [EnumCaseDecl]
    public let properties: [ComputedProperty]   // M5 A1: computed properties (enums store nothing)
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let conformances: [Conformance]   // M5 A1.3: interfaces this type conforms to
    public let visibility: Visibility
    public let span: Span

    public init(name: String, generics: [GenericParam], cases: [EnumCaseDecl], properties: [ComputedProperty], methods: [FuncDecl], conformances: [Conformance], visibility: Visibility = .internal, span: Span) {
        self.name = name; self.generics = generics; self.cases = cases; self.properties = properties; self.methods = methods; self.conformances = conformances; self.visibility = visibility; self.span = span
    }
}

public struct EnumCaseDecl {
    public let name: String
    public let fields: [VarField]
    public let span: Span

    public init(name: String, fields: [VarField], span: Span) {
        self.name = name; self.fields = fields; self.span = span
    }
}

public struct ClassDecl {
    public let name: String
    public let generics: [GenericParam]   // M5 5.2.1: `class Ref<T>` type parameters (empty for non-generic)
    public let fields: [VarField]
    public let properties: [ComputedProperty]   // M5 A1: computed properties (get / get-set)
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let conformances: [Conformance]   // M5 A1.3: interfaces this type conforms to
    public let visibility: Visibility
    public let span: Span

    public init(name: String, generics: [GenericParam], fields: [VarField], properties: [ComputedProperty], methods: [FuncDecl], conformances: [Conformance], visibility: Visibility = .internal, span: Span) {
        self.name = name; self.generics = generics; self.fields = fields; self.properties = properties; self.methods = methods; self.conformances = conformances; self.visibility = visibility; self.span = span
    }
}

public struct ActorDecl {
    public let name: String
    public let fields: [ActorField]
    public let handlers: [OnHandler]
    public let conformances: [Conformance]   // M5 A1.3: parsed, but actor conformance is rejected (parked)
    public let visibility: Visibility
    public let span: Span

    public init(name: String, fields: [ActorField], handlers: [OnHandler], conformances: [Conformance], visibility: Visibility = .internal, span: Span) {
        self.name = name; self.fields = fields; self.handlers = handlers; self.conformances = conformances; self.visibility = visibility; self.span = span
    }
}

public struct ActorField {
    public let name: String
    public let type: TypeRef
    public let initializer: Expr?
    public let span: Span

    public init(name: String, type: TypeRef, initializer: Expr?, span: Span) {
        self.name = name; self.type = type; self.initializer = initializer; self.span = span
    }
}

public struct OnHandler {
    public let name: String
    public let params: [Param]
    public let returnType: TypeRef?
    public let body: Block
    public let span: Span

    public init(name: String, params: [Param], returnType: TypeRef?, body: Block, span: Span) {
        self.name = name; self.params = params; self.returnType = returnType; self.body = body; self.span = span
    }
}

public struct FuncDecl {
    public let name: String
    public let generics: [GenericParam]   // M5 5.2.1: `fun map<T, U>(…)` type parameters (empty for non-generic)
    public let params: [Param]
    public let returnType: TypeRef?
    public let body: Block
    public let isStatic: Bool             // `static fun` — a type-associated function, no `self` receiver
    public let visibility: Visibility
    public let span: Span

    public init(name: String, generics: [GenericParam], params: [Param], returnType: TypeRef?, body: Block, isStatic: Bool = false, visibility: Visibility = .internal, span: Span) {
        self.name = name; self.generics = generics; self.params = params; self.returnType = returnType; self.body = body; self.isStatic = isStatic; self.visibility = visibility; self.span = span
    }
}

public struct Param {
    public let label: String
    public let name: String
    public let type: TypeRef
    public let span: Span

    public init(label: String, name: String, type: TypeRef, span: Span) {
        self.label = label; self.name = name; self.type = type; self.span = span
    }
}

public typealias Block = [Stmt]

// MARK: - Statements

public enum Stmt {
    case binding(BindingStmt)
    case spawnLet(name: String, type: TypeRef?, value: Expr, span: Span)  // spawn let x = expr
    case assign(lhs: Expr, rhs: Expr, span: Span)
    case compoundAssign(lhs: Expr, rhs: Expr, span: Span)  // +=
    case ret(Expr?, span: Span)
    case ifStmt(IfStmt)
    case whileStmt(WhileStmt)
    case breakStmt(span: Span)
    case continueStmt(span: Span)
    case switchStmt(SwitchStmt)
    case expr(Expr)
}

// `else if` is represented as an elseBody holding a single .ifStmt.
public struct IfStmt {
    public let cond: Expr
    public let thenBody: Block
    public let elseBody: Block?
    public let span: Span

    public init(cond: Expr, thenBody: Block, elseBody: Block?, span: Span) {
        self.cond = cond; self.thenBody = thenBody; self.elseBody = elseBody; self.span = span
    }
}

// A pre-tested loop: `while <cond> { body }` (`loops.md`).
public struct WhileStmt {
    public let cond: Expr
    public let body: Block
    public let span: Span

    public init(cond: Expr, body: Block, span: Span) {
        self.cond = cond; self.body = body; self.span = span
    }
}

public struct BindingStmt {
    public let isMutable: Bool
    public let name: String
    public let type: TypeRef?
    public let value: Expr
    public let span: Span

    public init(isMutable: Bool, name: String, type: TypeRef?, value: Expr, span: Span) {
        self.isMutable = isMutable; self.name = name; self.type = type; self.value = value; self.span = span
    }
}

public struct SwitchStmt {
    public let subject: Expr
    public let cases: [CaseArm]
    public let span: Span

    public init(subject: Expr, cases: [CaseArm], span: Span) {
        self.subject = subject; self.cases = cases; self.span = span
    }
}

public struct CaseArm {
    public let pattern: Pattern
    public let body: Block
    public let span: Span

    public init(pattern: Pattern, body: Block, span: Span) {
        self.pattern = pattern; self.body = body; self.span = span
    }
}

// .circle(let r, let s) → name="circle", bindings=["r", "s"] (positional)
public enum Pattern {
    case enumCase(name: String, bindings: [String], span: Span)
}

// MARK: - Expressions

public indirect enum Expr {
    case intLit(Int, span: Span)
    case doubleLit(Double, span: Span)
    case boolLit(Bool, span: Span)
    case stringLit(String, span: Span)
    case ident(String, span: Span)
    case genericIdent(String, [TypeRef], span: Span)   // `Name<T, U>` in expression position — explicit type args for generic construction (M5 5.2.3)
    case member(Expr, String, span: Span)
    case implicitMember(String, span: Span)   // leading-dot `.case` — enum type inferred from context

    case call(Expr, [Arg], span: Span)
    case binary(BinOp, Expr, Expr, span: Span)
    case unary(UnaryOp, Expr, span: Span)
    case closure(params: [Param], ret: TypeRef?, body: Block, span: Span)
    case arrayLit([Expr], span: Span)          // [a, b, c] — an Array<T> literal
    case index(Expr, Expr, span: Span)         // a[i] — array subscript

    // A placeholder for an expression the parser could not build from broken input.
    // Only produced during error recovery — a diagnostic is always reported alongside
    // it, and the driver stops before Sema when the parse sink holds errors.
    case error(span: Span)
}

public struct Arg {
    public let label: String?
    public let value: Expr

    public init(label: String? = nil, value: Expr) {
        self.label = label
        self.value = value
    }
}

public enum BinOp: Equatable {
    case add, sub, mul, div, mod
    case eq, neq, lt, gt, lte, gte
    case bitAnd, bitOr, bitXor, shl, shr
    case and, or   // logical && / || — short-circuit; lowered to branches in SSAIRgen
}

// Prefix operators. `neg` (`-x`) and `not` (`!x`) and `bitNot` (`~x`). Lowered to binary
// forms in Sema (`0 - x`, `x == false`, `x ^ allOnes`), so no unary node reaches NOIR/SSAIR.
public enum UnaryOp: Equatable {
    case neg, not, bitNot
}
