// Extension merge (M4.12) — folds plain extensions (`extension T { … }`) into the
// member set of their target struct/enum/class before typechecking, so every
// downstream pass sees one type with all its methods and needs no extension-awareness
// (design: m4.12-spec.md; interfaces.md §1, the plain-extension form).
//
// This is the only genuinely new machinery M4.12 adds — the decl-to-type member
// merge that M5 Phase A's conformance extensions will reuse. Conformance extensions
// (`extension T: I`) and generic-type extensions are M5; the parser already rejects
// the conformance form, so every `ExtensionDecl` reaching here is the plain form.
//
// Errors reported (collect-and-continue, into the shared sink):
//   - extending an unknown type, or a function name
//   - extending an `actor` (deferred until actor instance methods exist)
//   - a method whose (name + nominal argument types) duplicates one already on the
//     type — from the body or an earlier extension

public func mergeExtensions(_ program: Program, into diags: DiagnosticSink) -> Program {
    var merger = ExtensionMerger(program: program, diags: diags)
    return merger.run()
}

private struct ExtensionMerger {
    let program: Program
    let diags: DiagnosticSink

    enum Kind { case struct_, enum_, class_, actor_ }
    private var kinds: [String: Kind] = [:]
    private var funcNames: Set<String> = []
    // Target type name → the extensions targeting it, in program order.
    private var byType: [String: [ExtensionDecl]] = [:]

    init(program: Program, diags: DiagnosticSink) {
        self.program = program
        self.diags = diags
        for decl in program.decls {
            switch decl {
            case .structDecl(let s): kinds[s.name] = .struct_
            case .enumDecl(let e):   kinds[e.name] = .enum_
            case .classDecl(let c):  kinds[c.name] = .class_
            case .actorDecl(let a):  kinds[a.name] = .actor_
            case .funcDecl(let f):   funcNames.insert(f.name)
            case .extensionDecl(let x): byType[x.typeName, default: []].append(x)
            }
        }
    }

    mutating func run() -> Program {
        validateTargets()
        var out: [TopDecl] = []
        for decl in program.decls {
            switch decl {
            case .structDecl(let s):
                let methods = merged(s.methods, into: s.name)
                out.append(.structDecl(StructDecl(name: s.name, fields: s.fields, properties: s.properties, methods: methods, span: s.span)))
            case .enumDecl(let e):
                let methods = merged(e.methods, into: e.name)
                out.append(.enumDecl(EnumDecl(name: e.name, cases: e.cases, properties: e.properties, methods: methods, span: e.span)))
            case .classDecl(let c):
                let methods = merged(c.methods, into: c.name)
                out.append(.classDecl(ClassDecl(name: c.name, fields: c.fields, properties: c.properties, methods: methods, span: c.span)))
            case .actorDecl, .funcDecl:
                out.append(decl)
            case .extensionDecl:
                break   // folded into its target above, or reported invalid
            }
        }
        return Program(decls: out)
    }

    // Report extensions whose target can't be extended. Valid targets (struct/enum/
    // class) merge in `merged`; invalid ones are dropped, their methods discarded.
    private func validateTargets() {
        for (typeName, exts) in byType {
            switch kinds[typeName] {
            case .struct_, .enum_, .class_:
                continue
            case .actor_:
                for ext in exts {
                    diags.error("extensions on 'actor' types are not supported yet", at: ext.typeNameSpan)
                }
            case nil:
                for ext in exts {
                    if funcNames.contains(typeName) {
                        diags.error("'\(typeName)' is a function, not a type; only struct/enum/class can be extended", at: ext.typeNameSpan)
                    } else {
                        diags.error("cannot extend unknown type '\(typeName)'", at: ext.typeNameSpan)
                    }
                }
            }
        }
    }

    // Body methods followed by extension methods, skipping any whose signature
    // duplicates one already present (the first declaration wins; the duplicate is
    // reported). Keys on name + nominal argument types (interfaces.md §4.2).
    private func merged(_ body: [FuncDecl], into typeName: String) -> [FuncDecl] {
        guard let exts = byType[typeName] else { return body }
        var result = body
        var seen = Set(body.map(signature))
        for ext in exts {
            for m in ext.methods {
                let sig = signature(m)
                if seen.contains(sig) {
                    diags.error("extension method '\(m.name)' collides with an existing method on '\(typeName)'", at: m.span)
                    continue
                }
                seen.insert(sig)
                result.append(m)
            }
        }
        return result
    }

    private func signature(_ m: FuncDecl) -> String {
        m.name + "(" + m.params.map { $0.type.name }.joined(separator: ",") + ")"
    }
}
