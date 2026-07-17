import Foundation

public struct Typechecker {
    private let program: Program
    private var typeKinds: [String: DeclKind] = [
        "Int": .builtin,
        "Bool": .builtin,
    ]

    private enum DeclKind {
        case struct_, enum_, class_, actor_, builtin
    }

    public init(_ program: Program) {
        self.program = program
    }

    public mutating func check() {
        collectTypeKinds()
        checkPOD()
        checkLetVar()
    }

    // MARK: - Phase 1: collect declared type names

    private mutating func collectTypeKinds() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): typeKinds[s.name] = .struct_
            case .enumDecl(let e):   typeKinds[e.name] = .enum_
            case .classDecl(let c):  typeKinds[c.name] = .class_
            case .actorDecl(let a):  typeKinds[a.name] = .actor_
            case .funcDecl:          break
            }
        }
    }

    // MARK: - Phase 2: POD constraint on structs and enums

    private func checkPOD() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s):
                for field in s.fields where containsReference(field.type.name) {
                    fail("value type '\(s.name)' may not store a reference field '\(field.name)'; use a class",
                         line: field.line)
                }
            case .enumDecl(let e):
                for c in e.cases {
                    for field in c.fields where containsReference(field.type.name) {
                        fail("value type '\(e.name)' may not store a reference field '\(field.name)'; use a class",
                             line: field.line)
                    }
                }
            default:
                break
            }
        }
    }

    // A type "contains a reference" if it is a class/actor, or is a
    // struct/enum that transitively has a field whose type does.
    private func containsReference(_ name: String) -> Bool {
        switch typeKinds[name] {
        case .class_, .actor_:
            return true
        case .struct_:
            return structDecl(named: name)?
                .fields.contains { containsReference($0.type.name) } ?? false
        case .enum_:
            return enumDecl(named: name)?
                .cases.flatMap(\.fields).contains { containsReference($0.type.name) } ?? false
        case .builtin, nil:
            return false
        }
    }

    // MARK: - Phase 3: let/var enforcement

    private func checkLetVar() {
        for decl in program.decls {
            switch decl {
            case .funcDecl(let f):
                checkBlock(f.body, lets: [])
            case .actorDecl(let a):
                for h in a.handlers { checkBlock(h.body, lets: []) }
            default:
                break
            }
        }
    }

    private func checkBlock(_ block: Block, lets: Set<String>) {
        var lets = lets
        for stmt in block { checkStmt(stmt, lets: &lets) }
    }

    private func checkStmt(_ stmt: Stmt, lets: inout Set<String>) {
        switch stmt {
        case .binding(let b):
            if !b.isMutable { lets.insert(b.name) }
        case .assign(let lhs, _, let line):
            rejectLetTarget(lhs, lets: lets, line: line)
        case .compoundAssign(let lhs, _, let line):
            rejectLetTarget(lhs, lets: lets, line: line)
        case .ifStmt(let s):
            checkBlock(s.thenBody, lets: lets)
            if let elseBody = s.elseBody { checkBlock(elseBody, lets: lets) }
        case .switchStmt(let sw):
            for arm in sw.cases {
                var innerLets = lets
                if case .enumCase(_, let bindings, _) = arm.pattern {
                    innerLets.formUnion(bindings)  // pattern bindings are always immutable
                }
                checkBlock(arm.body, lets: innerLets)
            }
        case .ret, .send, .join, .expr:
            break
        }
    }

    private func rejectLetTarget(_ lhs: Expr, lets: Set<String>, line: Int) {
        if case .ident(let name, _) = lhs, lets.contains(name) {
            fail("cannot assign to '\(name)' ('let' constant)", line: line)
        }
    }

    // MARK: - Lookup helpers

    private func structDecl(named name: String) -> StructDecl? {
        for decl in program.decls {
            if case .structDecl(let s) = decl, s.name == name { return s }
        }
        return nil
    }

    private func enumDecl(named name: String) -> EnumDecl? {
        for decl in program.decls {
            if case .enumDecl(let e) = decl, e.name == name { return e }
        }
        return nil
    }

    // MARK: - Error reporting

    private func fail(_ msg: String, line: Int) -> Never {
        fputs("error:\(line): \(msg)\n", stderr)
        exit(1)
    }
}
