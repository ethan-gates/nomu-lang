import ast
import support
public struct Typechecker {
    private let program: Program
    // Errors are collected, not fatal (the no-crash contract — frontend/README.md P0).
    private let diags: DiagnosticSink
    private var typeKinds: [String: DeclKind] = [
        "Int": .builtin,
        "Bool": .builtin,
        "String": .builtin,
    ]

    private enum DeclKind {
        case struct_, enum_, class_, actor_, interface_, builtin
    }

    public init(_ program: Program, diagnostics: DiagnosticSink = DiagnosticSink()) {
        self.program = program
        self.diags = diagnostics
    }

    @discardableResult
    public mutating func check() -> DiagnosticSink {
        collectTypeKinds()
        checkPOD()
        checkLetVar()
        return diags
    }

    // MARK: - Phase 1: collect declared type names

    private mutating func collectTypeKinds() {
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): typeKinds[s.name] = .struct_
            case .enumDecl(let e):   typeKinds[e.name] = .enum_
            case .classDecl(let c):  typeKinds[c.name] = .class_
            case .actorDecl(let a):  typeKinds[a.name] = .actor_
            case .interfaceDecl(let i): typeKinds[i.name] = .interface_
            case .funcDecl:          break
            case .extensionDecl:     break   // merged into its target before this pass (M4.12)
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
                         span: field.span)
                }
            case .enumDecl(let e):
                for c in e.cases {
                    for field in c.fields where containsReference(field.type.name) {
                        fail("value type '\(e.name)' may not store a reference field '\(field.name)'; use a class",
                             span: field.span)
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
        case .interface_, .builtin, nil:
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
            case .structDecl(let s):
                checkMethods(s.methods)
                checkProperties(s.properties)
            case .classDecl(let c):
                checkMethods(c.methods)
                checkProperties(c.properties)
            case .enumDecl(let e):
                checkMethods(e.methods)
                checkProperties(e.properties)
            case .interfaceDecl(let i):
                for m in i.methods { if let body = m.defaultBody { checkBlock(body, lets: []) } }
            case .extensionDecl:
                break   // merged into its target before this pass (M4.12)
            }
        }
    }

    // Method bodies get the ordinary local let/var check. Field-write validity
    // (`let` fields, reassigning `self`) is enforced in Sema (M4.11), which has the
    // resolved receiver types the AST pass lacks; mutating-ness is inferred there.
    private func checkMethods(_ methods: [FuncDecl]) {
        for m in methods { checkBlock(m.body, lets: []) }
    }

    // Accessor bodies get the same local let/var check as method bodies.
    private func checkProperties(_ properties: [ComputedProperty]) {
        for p in properties {
            checkBlock(p.getter, lets: [])
            if let setter = p.setter { checkBlock(setter.body, lets: []) }
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
        case .spawnLet(let name, _, _, _):
            lets.insert(name)   // a spawn binding is immutable
        case .assign(let lhs, _, let span):
            rejectLetTarget(lhs, lets: lets, span: span)
        case .compoundAssign(let lhs, _, let span):
            rejectLetTarget(lhs, lets: lets, span: span)
        case .ifStmt(let s):
            checkBlock(s.thenBody, lets: lets)
            if let elseBody = s.elseBody { checkBlock(elseBody, lets: lets) }
        case .whileStmt(let s):
            checkBlock(s.body, lets: lets)
        case .switchStmt(let sw):
            for arm in sw.cases {
                var innerLets = lets
                if case .enumCase(_, let bindings, _) = arm.pattern {
                    innerLets.formUnion(bindings)  // pattern bindings are always immutable
                }
                checkBlock(arm.body, lets: innerLets)
            }
        case .ret, .expr, .breakStmt, .continueStmt:
            break
        }
    }

    private func rejectLetTarget(_ lhs: Expr, lets: Set<String>, span: Span) {
        if case .ident(let name, _) = lhs, lets.contains(name) {
            fail("cannot assign to '\(name)' ('let' constant)", span: span)
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

    private func fail(_ msg: String, span: Span) {
        diags.error(msg, at: span)
    }
}
