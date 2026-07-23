// MARK: - Type references

// A named type (`Int`, `Point`) or a function type (`(Int) -> Int`).
// `name` is a canonical rendering usable as a dictionary key; `fn` is set for function types.
// A reference type so function types can recurse (a struct here would be infinite-size).
public final class TypeRef {
    public let name: String
    public let fn: FnType?
    public let span: Span

    public init(name: String, fn: FnType? = nil, span: Span) {
        self.name = name
        self.fn = fn
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
}

// MARK: - Top-level declarations

public enum TopDecl {
    case structDecl(StructDecl)
    case enumDecl(EnumDecl)
    case classDecl(ClassDecl)
    case actorDecl(ActorDecl)
    case funcDecl(FuncDecl)
}

public struct StructDecl {
    public let name: String
    public let fields: [VarField]
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let span: Span
}

public struct VarField {
    public let name: String
    public let type: TypeRef
    public let span: Span
}

public struct EnumDecl {
    public let name: String
    public let cases: [EnumCaseDecl]
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let span: Span
}

public struct EnumCaseDecl {
    public let name: String
    public let fields: [VarField]
    public let span: Span
}

public struct ClassDecl {
    public let name: String
    public let fields: [VarField]
    public let methods: [FuncDecl]   // T3: read-only instance methods (`fun` members)
    public let span: Span
}

public struct ActorDecl {
    public let name: String
    public let fields: [ActorField]
    public let handlers: [OnHandler]
    public let span: Span
}

public struct ActorField {
    public let name: String
    public let type: TypeRef
    public let initializer: Expr?
    public let span: Span
}

public struct OnHandler {
    public let name: String
    public let params: [Param]
    public let returnType: TypeRef?
    public let body: Block
    public let span: Span
}

public struct FuncDecl {
    public let name: String
    public let params: [Param]
    public let returnType: TypeRef?
    public let body: Block
    public let span: Span
}

public struct Param {
    public let label: String
    public let name: String
    public let type: TypeRef
    public let span: Span
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
    case switchStmt(SwitchStmt)
    case expr(Expr)
}

// `else if` is represented as an elseBody holding a single .ifStmt.
public struct IfStmt {
    public let cond: Expr
    public let thenBody: Block
    public let elseBody: Block?
    public let span: Span
}

public struct BindingStmt {
    public let isMutable: Bool
    public let name: String
    public let type: TypeRef?
    public let value: Expr
    public let span: Span
}

public struct SwitchStmt {
    public let subject: Expr
    public let cases: [CaseArm]
    public let span: Span
}

public struct CaseArm {
    public let pattern: Pattern
    public let body: Block
    public let span: Span
}

// .circle(let r, let s) → name="circle", bindings=["r", "s"] (positional)
public enum Pattern {
    case enumCase(name: String, bindings: [String], span: Span)
}

// MARK: - Expressions

public indirect enum Expr {
    case intLit(Int, span: Span)
    case boolLit(Bool, span: Span)
    case stringLit(String, span: Span)
    case ident(String, span: Span)
    case member(Expr, String, span: Span)
    case call(Expr, [Arg], span: Span)
    case binary(BinOp, Expr, Expr, span: Span)
    case closure(params: [Param], ret: TypeRef?, body: Block, span: Span)
}

public struct Arg {
    public let label: String?
    public let value: Expr

    public init(label: String? = nil, value: Expr) {
        self.label = label
        self.value = value
    }
}

public enum BinOp {
    case add, sub, mul, div
    case eq, neq, lt, gt, lte, gte
}
