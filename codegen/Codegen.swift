import Foundation
import frontend

// Maps variable name → nomu type name within a function body.
private typealias Scope = [String: String]

public struct Codegen {
    private let program: Program
    private var out = ""

    // Quick lookup tables populated at init
    private var structs:  [String: StructDecl] = [:]
    private var enums:    [String: EnumDecl]   = [:]
    private var classes:  [String: ClassDecl]  = [:]
    private var funcs:    [String: FuncDecl]   = [:]

    public init(_ program: Program) {
        self.program = program
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): structs[s.name] = s
            case .enumDecl(let e):   enums[e.name]   = e
            case .classDecl(let c):  classes[c.name] = c
            case .funcDecl(let f):   funcs[f.name]   = f
            case .actorDecl:         break
            }
        }
    }

    public mutating func emit() -> String {
        emitPreamble()
        for decl in program.decls { emitTopDecl(decl) }
        emitCMain()
        return out
    }

    // MARK: - Top-level

    private mutating func emitTopDecl(_ decl: TopDecl) {
        switch decl {
        case .structDecl(let s): emitStruct(s)
        case .enumDecl(let e):   emitEnum(e)
        case .funcDecl(let f):   emitFunc(f)
        case .classDecl, .actorDecl: break  // steps 2–4
        }
    }

    // MARK: - Type declarations

    private mutating func emitStruct(_ s: StructDecl) {
        out += "typedef struct {\n"
        for f in s.fields { out += "    \(cType(f.type.name)) \(f.name);\n" }
        out += "} \(s.name);\n\n"
    }

    private mutating func emitEnum(_ e: EnumDecl) {
        let tags = e.cases.map { "\(e.name)_\($0.name)" }.joined(separator: ", ")
        out += "typedef enum { \(tags) } \(e.name)_tag;\n"
        out += "typedef struct {\n"
        out += "    \(e.name)_tag tag;\n"
        out += "    union {\n"
        for c in e.cases {
            if c.fields.isEmpty {
                out += "        char \(c.name)_pad;\n"
            } else {
                out += "        struct {\n"
                for f in c.fields { out += "            \(cType(f.type.name)) \(f.name);\n" }
                out += "        } \(c.name);\n"
            }
        }
        out += "    } payload;\n"
        out += "} \(e.name);\n\n"
    }

    // MARK: - Functions

    private mutating func emitFunc(_ f: FuncDecl) {
        var scope: Scope = [:]
        for p in f.params { scope[p.name] = p.type.name }

        let cName   = f.name == "main" ? "nomu_main" : f.name
        let retType = f.returnType.map { cType($0.name) } ?? "void"
        let params  = f.params.isEmpty
            ? "void"
            : f.params.map { "\(cType($0.type.name)) \($0.name)" }.joined(separator: ", ")

        out += "\(retType) \(cName)(\(params)) {\n"
        for stmt in f.body { emitStmt(stmt, scope: &scope, ind: "    ") }
        out += "}\n\n"
    }

    // MARK: - Statements

    private mutating func emitStmt(_ stmt: Stmt, scope: inout Scope, ind: String) {
        switch stmt {
        case .binding(let b):
            emitBinding(b, scope: &scope, ind: ind)
        case .assign(let lhs, let rhs, _):
            out += "\(ind)\(emitExpr(lhs, scope: scope)) = \(emitExpr(rhs, scope: scope));\n"
        case .compoundAssign(let lhs, let rhs, _):
            out += "\(ind)\(emitExpr(lhs, scope: scope)) += \(emitExpr(rhs, scope: scope));\n"
        case .ret(let e, _):
            out += "\(ind)return\(e.map { " \(emitExpr($0, scope: scope))" } ?? "");\n"
        case .switchStmt(let sw):
            emitSwitch(sw, scope: &scope, ind: ind)
        case .expr(let e):
            out += "\(ind)\(emitExpr(e, scope: scope));\n"
        case .send:
            break  // steps 3–4
        }
    }

    private mutating func emitBinding(_ b: BindingStmt, scope: inout Scope, ind: String) {
        let typeName = b.type?.name ?? typeOf(b.value, scope: scope)
        scope[b.name] = typeName
        out += "\(ind)\(cType(typeName)) \(b.name) = \(emitInit(b.value, as: typeName, scope: scope));\n"
    }

    private mutating func emitSwitch(_ sw: SwitchStmt, scope: inout Scope, ind: String) {
        let subj     = emitExpr(sw.subject, scope: scope)
        let enumName = typeOf(sw.subject, scope: scope)
        guard let ed = enums[enumName] else {
            out += "\(ind)/* switch: unknown enum type '\(enumName)' */\n"; return
        }

        out += "\(ind)switch (\(subj).tag) {\n"
        for arm in sw.cases {
            guard case .enumCase(let caseName, let bindings, _) = arm.pattern,
                  let cd = ed.cases.first(where: { $0.name == caseName }) else { continue }

            out += "\(ind)    case \(enumName)_\(caseName): {\n"
            var inner = scope
            for (binding, field) in zip(bindings, cd.fields) {
                out += "\(ind)        \(cType(field.type.name)) \(binding) = \(subj).payload.\(caseName).\(field.name);\n"
                inner[binding] = field.type.name
            }
            for stmt in arm.body { emitStmt(stmt, scope: &inner, ind: ind + "        ") }
            out += "\(ind)        break;\n"
            out += "\(ind)    }\n"
        }
        out += "\(ind)}\n"
    }

    // MARK: - Expressions

    // Returns an expression string usable anywhere a C rvalue is expected.
    private func emitExpr(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit(let v, _):   return "\(v)"
        case .boolLit(let v, _):  return v ? "1" : "0"
        case .ident(let n, _):    return n
        case .member(let base, let field, _):
            let op = classes[typeOf(base, scope: scope)] != nil ? "->" : "."
            return "\(emitExpr(base, scope: scope))\(op)\(field)"
        case .binary(let op, let lhs, let rhs, _):
            return "(\(emitExpr(lhs, scope: scope)) \(cOp(op)) \(emitExpr(rhs, scope: scope)))"
        case .call(let callee, let args, _):
            return emitCall(callee: callee, args: args, scope: scope)
        case .spawn:
            return "/* spawn — step 4 */"
        }
    }

    // Emit an expression in initializer position (bindings only).
    // Allows struct compound-literal form at the top level.
    private func emitInit(_ e: Expr, as typeName: String, scope: Scope) -> String {
        if case .call(let callee, let args, _) = e,
           case .ident(let name, _) = callee,
           structs[name] != nil {
            return structLiteral(name: name, args: args, scope: scope)
        }
        return emitExpr(e, scope: scope)
    }

    private func emitCall(callee: Expr, args: [Arg], scope: Scope) -> String {
        guard case .ident(let name, _) = callee else {
            // e.g. methodCall — skip for step 1
            return "\(emitExpr(callee, scope: scope))(\(args.map { emitExpr($0.value, scope: scope) }.joined(separator: ", ")))"
        }
        if name == "print" {
            let arg = args.first.map { emitExpr($0.value, scope: scope) } ?? "0"
            return "printf(\"%lld\\n\", (long long)(\(arg)))"
        }
        if structs[name] != nil { return structLiteral(name: name, args: args, scope: scope) }
        if classes[name] != nil { return "\(name)_new()" }
        let argStr = args.map { emitExpr($0.value, scope: scope) }.joined(separator: ", ")
        return "\(name)(\(argStr))"
    }

    private func structLiteral(name: String, args: [Arg], scope: Scope) -> String {
        guard let s = structs[name] else { return "/* unknown struct \(name) */" }
        let fields = s.fields.map { f -> String in
            let v = args.first(where: { $0.label == f.name }).map { emitExpr($0.value, scope: scope) } ?? "0"
            return ".\(f.name) = \(v)"
        }.joined(separator: ", ")
        return "(\(name)){ \(fields) }"
    }

    // MARK: - Type resolution

    private func typeOf(_ e: Expr, scope: Scope) -> String {
        switch e {
        case .intLit:               return "Int"
        case .boolLit:              return "Bool"
        case .ident(let n, _):      return scope[n] ?? ""
        case .member(let base, let field, _):
            let bt = typeOf(base, scope: scope)
            return structs[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? classes[bt]?.fields.first(where: { $0.name == field })?.type.name
                ?? ""
        case .call(let callee, _, _):
            guard case .ident(let n, _) = callee else { return "" }
            if structs[n] != nil || enums[n] != nil || classes[n] != nil { return n }
            return funcs[n]?.returnType?.name ?? ""
        case .binary:   return "Int"
        case .spawn(let n, _, _): return n
        }
    }

    // MARK: - C helpers

    private func cType(_ name: String) -> String {
        switch name {
        case "Int", "Bool": return "int64_t"
        default: return classes[name] != nil ? "\(name)*" : name
        }
    }

    private func cOp(_ op: BinOp) -> String {
        switch op {
        case .add: return "+"
        case .sub: return "-"
        case .mul: return "*"
        case .div: return "/"
        case .eq:  return "=="
        case .neq: return "!="
        case .lt:  return "<"
        case .gt:  return ">"
        case .lte: return "<="
        case .gte: return ">="
        }
    }

    // MARK: - Preamble and entry point

    private mutating func emitPreamble() {
        out += """
        #include <stdio.h>
        #include <stdlib.h>
        #include <stdint.h>
        #include <string.h>

        typedef struct { size_t refcount; } ObjectHeader;
        static inline void* rt_alloc(size_t size) {
            void* p = malloc(size);
            ((ObjectHeader*)p)->refcount = 1;
            return p;
        }
        static inline void rt_retain(void* p) {
            if (p) ((ObjectHeader*)p)->refcount++;
        }


        """
    }

    private mutating func emitCMain() {
        out += """
        int main(void) {
            nomu_main();
            return 0;
        }
        """
    }
}
