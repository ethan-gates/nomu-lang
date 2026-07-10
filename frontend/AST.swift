// MARK: - Type references

public struct TypeRef {
    public let name: String
    public let line: Int
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
    public let line: Int
}

public struct VarField {
    public let name: String
    public let type: TypeRef
    public let line: Int
}

public struct EnumDecl {
    public let name: String
    public let cases: [EnumCaseDecl]
    public let line: Int
}

public struct EnumCaseDecl {
    public let name: String
    public let fields: [VarField]
    public let line: Int
}

public struct ClassDecl {
    public let name: String
    public let fields: [VarField]
    public let deinitBody: Block?
    public let line: Int
}

public struct ActorDecl {
    public let name: String
    public let fields: [ActorField]
    public let handlers: [OnHandler]
    public let line: Int
}

public struct ActorField {
    public let name: String
    public let type: TypeRef
    public let initializer: Expr?
    public let line: Int
}

public struct OnHandler {
    public let name: String
    public let params: [Param]
    public let body: Block
    public let line: Int
}

public struct FuncDecl {
    public let name: String
    public let params: [Param]
    public let returnType: TypeRef?
    public let body: Block
    public let line: Int
}

public struct Param {
    public let label: String
    public let name: String
    public let type: TypeRef
    public let line: Int
}

public typealias Block = [Stmt]

// MARK: - Statements

public enum Stmt {
    case binding(BindingStmt)
    case assign(lhs: Expr, rhs: Expr, line: Int)
    case compoundAssign(lhs: Expr, rhs: Expr, line: Int)  // +=
    case ret(Expr?, line: Int)
    case switchStmt(SwitchStmt)
    case send(Expr, line: Int)
    case expr(Expr)
}

public struct BindingStmt {
    public let isMutable: Bool
    public let name: String
    public let type: TypeRef?
    public let value: Expr
    public let line: Int
}

public struct SwitchStmt {
    public let subject: Expr
    public let cases: [CaseArm]
    public let line: Int
}

public struct CaseArm {
    public let pattern: Pattern
    public let body: Block
    public let line: Int
}

// .circle(let r, let s) → name="circle", bindings=["r", "s"] (positional)
public enum Pattern {
    case enumCase(name: String, bindings: [String], line: Int)
}

// MARK: - Expressions

public indirect enum Expr {
    case intLit(Int, line: Int)
    case boolLit(Bool, line: Int)
    case ident(String, line: Int)
    case member(Expr, String, line: Int)
    case call(Expr, [Arg], line: Int)
    case binary(BinOp, Expr, Expr, line: Int)
    case spawn(String, [Arg], line: Int)
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
