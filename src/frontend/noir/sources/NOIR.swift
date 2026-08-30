import ast
import support
// NOIR — the Nomu typed mid-level IR (structured; design: noir.md).
//
// Produced by the semantic pass (Sema) from the AST; codegen consumes it (T2).
// Structured — keeps `if`/`switch`/closures as nested nodes, not a CFG. Every
// expression and statement is a hybrid node: common `type`/`span` on a wrapper
// struct, variant data in a `kind` enum — so `expr.type`/`expr.span` are direct
// while matching on `.kind` stays exhaustive.

public struct NOIRModule {
    public let decls: [NOIRDecl]
    public let interfaces: [NOIRInterface]      // M5 A1.4: drives witness-table type emission
    public let conformances: [NOIRConformance]  // M5 A1.4: drives witness-table instance emission
    public let composites: [NOIRComposite]      // M5 A1.5b: composite (any A & B) witnesses to emit
    public let opaqueUnderlyings: [String: Type]   // M5 A3: opaque owner → hidden concrete underlying type

    public init(decls: [NOIRDecl], interfaces: [NOIRInterface] = [], conformances: [NOIRConformance] = [],
                composites: [NOIRComposite] = [], opaqueUnderlyings: [String: Type] = [:]) {
        self.decls = decls
        self.interfaces = interfaces
        self.conformances = conformances
        self.composites = composites
        self.opaqueUnderlyings = opaqueUnderlyings
    }
}

// A concrete type boxed as `any A & B` — codegen emits a composite witness struct (one
// witness-table pointer per interface) and an instance referencing the single witnesses.
public struct NOIRComposite {
    public let typeName: String
    public let typeKind: NamedKind
    public let interfaces: [String]   // canonical

    public init(typeName: String, typeKind: NamedKind, interfaces: [String]) {
        self.typeName = typeName; self.typeKind = typeKind; self.interfaces = interfaces
    }
}

// The requirement surface of an interface, resolved to types — enough for codegen to
// lay out a witness-table struct (a function-pointer slot per requirement, method then
// property accessors, then the reserved type-witness slot).
public struct NOIRInterface {
    public let name: String
    public let methods: [NOIRMethodReq]
    public let properties: [NOIRPropReq]
    public let bases: [String]   // M5 A1.4: transitive base interfaces — a witness carries a pointer to each, so `any B` upcasts to `any A`

    public init(name: String, methods: [NOIRMethodReq], properties: [NOIRPropReq], bases: [String]) {
        self.name = name; self.methods = methods; self.properties = properties; self.bases = bases
    }
}

public struct NOIRMethodReq {
    public let name: String
    public let params: [Type]
    public let ret: Type

    public init(name: String, params: [Type], ret: Type) {
        self.name = name; self.params = params; self.ret = ret
    }
}

public struct NOIRPropReq {
    public let name: String
    public let type: Type
    public let isSettable: Bool

    public init(name: String, type: Type, isSettable: Bool) {
        self.name = name; self.type = type; self.isSettable = isSettable
    }
}

// A checked conformance `T: I` — codegen emits one witness-table instance per entry.
public struct NOIRConformance {
    public let typeName: String
    public let typeKind: NamedKind
    public let interfaceName: String

    public init(typeName: String, typeKind: NamedKind, interfaceName: String) {
        self.typeName = typeName; self.typeKind = typeKind; self.interfaceName = interfaceName
    }
}

public enum NOIRDecl {
    case structDecl(NOIRStruct)
    case enumDecl(NOIREnum)
    case classDecl(NOIRClass)
    case actorDecl(NOIRActor)
    case funcDecl(NOIRFunc)
}

// MARK: - Declarations

public struct NOIRField {
    public let name: String
    public let type: Type
    public let isMutable: Bool   // `var` vs `let` field; read by M5-C's deeply-immutable check
    public let span: Span
    public init(name: String, type: Type, isMutable: Bool, span: Span) {
        self.name = name; self.type = type; self.isMutable = isMutable; self.span = span
    }
}

public struct NOIRStruct {
    public let name: String
    public let generics: [NOIRGenericParam]   // M5 5.2.3: type parameters (empty for a non-generic type)
    public let fields: [NOIRField]
    public let methods: [NOIRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
    public init(name: String, generics: [NOIRGenericParam] = [], fields: [NOIRField], methods: [NOIRFunc], span: Span) {
        self.name = name; self.generics = generics; self.fields = fields; self.methods = methods; self.span = span
    }
}

public struct NOIREnumCase {
    public let name: String
    public let fields: [NOIRField]
    public let span: Span

    public init(name: String, fields: [NOIRField], span: Span) {
        self.name = name; self.fields = fields; self.span = span
    }
}

public struct NOIREnum {
    public let name: String
    public let generics: [NOIRGenericParam]   // M5 5.2.3
    public let cases: [NOIREnumCase]
    public let methods: [NOIRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
    public init(name: String, generics: [NOIRGenericParam] = [], cases: [NOIREnumCase], methods: [NOIRFunc], span: Span) {
        self.name = name; self.generics = generics; self.cases = cases; self.methods = methods; self.span = span
    }
}

public struct NOIRClass {
    public let name: String
    public let generics: [NOIRGenericParam]   // M5 5.2.3
    public let fields: [NOIRField]
    public let methods: [NOIRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
    public init(name: String, generics: [NOIRGenericParam] = [], fields: [NOIRField], methods: [NOIRFunc], span: Span) {
        self.name = name; self.generics = generics; self.fields = fields; self.methods = methods; self.span = span
    }
}

public struct NOIRActorField {
    public let name: String
    public let type: Type
    public let initializer: NOIRExpr?
    public let span: Span

    public init(name: String, type: Type, initializer: NOIRExpr?, span: Span) {
        self.name = name; self.type = type; self.initializer = initializer; self.span = span
    }
}

public struct NOIRHandler {
    public let name: String
    public let params: [NOIRParam]
    public let returnType: Type       // .void if none declared
    public let body: [NOIRStmt]
    public let span: Span

    public init(name: String, params: [NOIRParam], returnType: Type, body: [NOIRStmt], span: Span) {
        self.name = name; self.params = params; self.returnType = returnType; self.body = body; self.span = span
    }
}

public struct NOIRActor {
    public let name: String
    public let fields: [NOIRActorField]
    public let handlers: [NOIRHandler]
    public let span: Span

    public init(name: String, fields: [NOIRActorField], handlers: [NOIRHandler], span: Span) {
        self.name = name; self.fields = fields; self.handlers = handlers; self.span = span
    }
}

public struct NOIRParam {
    public let label: String
    public let name: String
    public let type: Type
    public let span: Span

    public init(label: String, name: String, type: Type, span: Span) {
        self.label = label; self.name = name; self.type = type; self.span = span
    }
}

// A generic type parameter carried into codegen: its name and the interfaces it is bound to.
// Codegen adds a witness-table parameter per (param, bound) and dispatches requirement calls
// on a `.typeParam` receiver through it (M5 5.2.2).
public struct NOIRGenericParam {
    public let name: String
    public let bounds: [String]
    public let isShared: Bool   // `<shared T>` — codegen's spawn check treats such a T as shareable (M5 5.3.2)
    public init(name: String, bounds: [String], isShared: Bool = false) {
        self.name = name; self.bounds = bounds; self.isShared = isShared
    }
}

public struct NOIRFunc {
    public let name: String
    public let generics: [NOIRGenericParam]   // M5 5.2.2: type parameters (empty for a non-generic function)
    public let params: [NOIRParam]
    public let returnType: Type       // .void if none declared
    public let body: [NOIRStmt]
    public let isMutating: Bool       // inferred: a method that mutates `self` (M4.11); false for free functions
    public let span: Span

    public init(name: String, generics: [NOIRGenericParam] = [], params: [NOIRParam], returnType: Type,
                body: [NOIRStmt], isMutating: Bool, span: Span) {
        self.name = name
        self.generics = generics
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isMutating = isMutating
        self.span = span
    }
}

// MARK: - Statements

public struct NOIRStmt {
    public let kind: StmtKind
    public let span: Span

    public init(kind: StmtKind, span: Span) {
        self.kind = kind; self.span = span
    }
}

public indirect enum StmtKind {
    case letBinding(name: String, isMutable: Bool, value: NOIRExpr)
    case spawnLet(name: String, value: NOIRExpr, resultType: Type)
    case assign(target: NOIRExpr, value: NOIRExpr)
    case compoundAssign(target: NOIRExpr, value: NOIRExpr)
    case ret(NOIRExpr?)
    case ifStmt(cond: NOIRExpr, then: [NOIRStmt], else: [NOIRStmt]?)
    case whileStmt(cond: NOIRExpr, body: [NOIRStmt])
    case breakStmt
    case continueStmt
    case switchStmt(NOIRSwitch)
    case exprStmt(NOIRExpr)
}

public struct NOIRSwitch {
    public let subject: NOIRExpr
    public let arms: [NOIRCaseArm]

    public init(subject: NOIRExpr, arms: [NOIRCaseArm]) {
        self.subject = subject; self.arms = arms
    }
}

public struct NOIRCaseArm {
    public let caseName: String
    public let bindings: [NOIRBinding]   // payload bindings, each with its resolved type
    public let body: [NOIRStmt]
    public let span: Span

    public init(caseName: String, bindings: [NOIRBinding], body: [NOIRStmt], span: Span) {
        self.caseName = caseName; self.bindings = bindings; self.body = body; self.span = span
    }
}

public struct NOIRBinding {
    public let name: String
    public let type: Type

    public init(name: String, type: Type) {
        self.name = name; self.type = type
    }
}

// MARK: - Expressions

public struct NOIRExpr {
    public let type: Type
    public let span: Span
    public let kind: ExprKind

    public init(type: Type, span: Span, kind: ExprKind) {
        self.type = type; self.span = span; self.kind = kind
    }
}

public indirect enum ExprKind {
    case intLit(Int)
    case doubleLit(Double)
    case boolLit(Bool)
    case stringLit(String)
    case varRef(String)                                 // resolved local / param / global name
    case fieldAccess(base: NOIRExpr, field: String)
    case construct(typeName: String, args: [NOIRArg])     // struct / class / actor construction
    case enumInit(typeName: String, caseName: String, args: [NOIRArg])    // enum value construction (M4.10)
    case methodCall(receiver: NOIRExpr, method: String, args: [NOIRExpr])   // actor sends (T3: type methods)
    case call(callee: NOIRExpr, args: [NOIRArg], typeArgs: [Type])   // function / builtin call; typeArgs non-empty for a generic call (M5 5.2.2)
    case staticCall(onType: Type, method: String, args: [NOIRExpr])   // `T.m(…)` static interface-requirement dispatch; mono resolves `onType` to a concrete conformer and lowers to a direct `call`
    case binary(BinOp, NOIRExpr, NOIRExpr)
    case closure(params: [NOIRParam], body: [NOIRStmt])
    case box(value: NOIRExpr, interfaces: [String])       // M5 A1.4/A1.5b: wrap a conformer as `any I` / `any A & B`
    case arrayLit(elements: [NOIRExpr])                   // [a, b, c] — build an Array<T>; `type` is `.array(T)` (M6)
    case index(base: NOIRExpr, idx: NOIRExpr)               // a[i] — array subscript read; `type` is the element T (M6)
}

public struct NOIRArg {
    public let label: String?
    public let value: NOIRExpr

    public init(label: String?, value: NOIRExpr) {
        self.label = label; self.value = value
    }
}
