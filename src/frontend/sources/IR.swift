// The typed mid-level IR (structured; design: compiler.md §1).
//
// Produced by the semantic pass (Sema) from the AST; codegen consumes it (T2).
// Structured — keeps `if`/`switch`/closures as nested nodes, not a CFG. Every
// expression and statement is a hybrid node: common `type`/`span` on a wrapper
// struct, variant data in a `kind` enum — so `expr.type`/`expr.span` are direct
// while matching on `.kind` stays exhaustive.

public struct IRModule {
    public let decls: [IRDecl]
    public let interfaces: [IRInterface]      // M5 A1.4: drives witness-table type emission
    public let conformances: [IRConformance]  // M5 A1.4: drives witness-table instance emission
    public let composites: [IRComposite]      // M5 A1.5b: composite (any A & B) witnesses to emit
    public let opaqueUnderlyings: [String: Type]   // M5 A3: opaque owner → hidden concrete underlying type

    public init(decls: [IRDecl], interfaces: [IRInterface] = [], conformances: [IRConformance] = [],
                composites: [IRComposite] = [], opaqueUnderlyings: [String: Type] = [:]) {
        self.decls = decls
        self.interfaces = interfaces
        self.conformances = conformances
        self.composites = composites
        self.opaqueUnderlyings = opaqueUnderlyings
    }
}

// A concrete type boxed as `any A & B` — codegen emits a composite witness struct (one
// witness-table pointer per interface) and an instance referencing the single witnesses.
public struct IRComposite {
    public let typeName: String
    public let typeKind: NamedKind
    public let interfaces: [String]   // canonical
}

// The requirement surface of an interface, resolved to types — enough for codegen to
// lay out a witness-table struct (a function-pointer slot per requirement, method then
// property accessors, then the reserved type-witness slot).
public struct IRInterface {
    public let name: String
    public let methods: [IRMethodReq]
    public let properties: [IRPropReq]
    public let bases: [String]   // M5 A1.4: transitive base interfaces — a witness carries a pointer to each, so `any B` upcasts to `any A`
}

public struct IRMethodReq {
    public let name: String
    public let params: [Type]
    public let ret: Type
}

public struct IRPropReq {
    public let name: String
    public let type: Type
    public let isSettable: Bool
}

// A checked conformance `T: I` — codegen emits one witness-table instance per entry.
public struct IRConformance {
    public let typeName: String
    public let typeKind: NamedKind
    public let interfaceName: String
}

public enum IRDecl {
    case structDecl(IRStruct)
    case enumDecl(IREnum)
    case classDecl(IRClass)
    case actorDecl(IRActor)
    case funcDecl(IRFunc)
}

// MARK: - Declarations

public struct IRField {
    public let name: String
    public let type: Type
    public let isMutable: Bool   // `var` vs `let` field; read by M5-C's deeply-immutable check
    public let span: Span
}

public struct IRStruct {
    public let name: String
    public let fields: [IRField]
    public let methods: [IRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
}

public struct IREnumCase {
    public let name: String
    public let fields: [IRField]
    public let span: Span
}

public struct IREnum {
    public let name: String
    public let cases: [IREnumCase]
    public let methods: [IRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
}

public struct IRClass {
    public let name: String
    public let fields: [IRField]
    public let methods: [IRFunc]   // T3: instance methods; each takes an implicit `self`
    public let span: Span
}

public struct IRActorField {
    public let name: String
    public let type: Type
    public let initializer: IRExpr?
    public let span: Span
}

public struct IRHandler {
    public let name: String
    public let params: [IRParam]
    public let returnType: Type       // .void if none declared
    public let body: [IRStmt]
    public let span: Span
}

public struct IRActor {
    public let name: String
    public let fields: [IRActorField]
    public let handlers: [IRHandler]
    public let span: Span
}

public struct IRParam {
    public let label: String
    public let name: String
    public let type: Type
    public let span: Span
}

public struct IRFunc {
    public let name: String
    public let params: [IRParam]
    public let returnType: Type       // .void if none declared
    public let body: [IRStmt]
    public let isMutating: Bool       // inferred: a method that mutates `self` (M4.11); false for free functions
    public let span: Span
}

// MARK: - Statements

public struct IRStmt {
    public let kind: StmtKind
    public let span: Span
}

public indirect enum StmtKind {
    case letBinding(name: String, isMutable: Bool, value: IRExpr)
    case spawnLet(name: String, value: IRExpr, resultType: Type)
    case assign(target: IRExpr, value: IRExpr)
    case compoundAssign(target: IRExpr, value: IRExpr)
    case ret(IRExpr?)
    case ifStmt(cond: IRExpr, then: [IRStmt], else: [IRStmt]?)
    case switchStmt(IRSwitch)
    case exprStmt(IRExpr)
}

public struct IRSwitch {
    public let subject: IRExpr
    public let arms: [IRCaseArm]
}

public struct IRCaseArm {
    public let caseName: String
    public let bindings: [IRBinding]   // payload bindings, each with its resolved type
    public let body: [IRStmt]
    public let span: Span
}

public struct IRBinding {
    public let name: String
    public let type: Type
}

// MARK: - Expressions

public struct IRExpr {
    public let type: Type
    public let span: Span
    public let kind: ExprKind
}

public indirect enum ExprKind {
    case intLit(Int)
    case boolLit(Bool)
    case stringLit(String)
    case varRef(String)                                 // resolved local / param / global name
    case fieldAccess(base: IRExpr, field: String)
    case construct(typeName: String, args: [IRArg])     // struct / class / actor construction
    case enumInit(typeName: String, caseName: String, args: [IRArg])    // enum value construction (M4.10)
    case methodCall(receiver: IRExpr, method: String, args: [IRExpr])   // actor sends (T3: type methods)
    case call(callee: IRExpr, args: [IRArg])            // function / builtin call
    case binary(BinOp, IRExpr, IRExpr)
    case closure(params: [IRParam], body: [IRStmt])
    case box(value: IRExpr, interfaces: [String])       // M5 A1.4/A1.5b: wrap a conformer as `any I` / `any A & B`
}

public struct IRArg {
    public let label: String?
    public let value: IRExpr
}
