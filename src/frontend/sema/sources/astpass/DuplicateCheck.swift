import ast
import support

// Duplicate-symbol detection within each module (tasks 100.1.3, 100.2.1). A module is one namespace,
// so two top-level declarations of the same name in the same module collide; the same name in two
// different modules does not. Types (struct/enum/class/actor/interface) share the type namespace;
// functions share the value namespace; the two are checked independently. Modules are identified by a
// declaration's directory (its file's parent) — the mechanical module boundary. Runs on the merged
// user program before the prelude is prepended, so it flags only the modules' own declarations.
// Overloading is not a language feature, so any repeat of a name in a module is a collision.
public func checkDuplicates(_ program: Program, into diags: DiagnosticSink) {
    var typeNames: [String: [String: Span]] = [:]   // module dir → name → first span
    var funcNames: [String: [String: Span]] = [:]

    func moduleOf(_ span: Span) -> String {   // a file's module is its parent directory
        let f = span.file
        return f.lastIndex(of: "/").map { String(f[..<$0]) } ?? ""
    }

    for decl in program.decls {
        switch decl {
        case .structDecl(let d):    record(d.name, d.span, &typeNames[moduleOf(d.span), default: [:]], "type", diags)
        case .enumDecl(let d):      record(d.name, d.span, &typeNames[moduleOf(d.span), default: [:]], "type", diags)
        case .classDecl(let d):     record(d.name, d.span, &typeNames[moduleOf(d.span), default: [:]], "type", diags)
        case .actorDecl(let d):     record(d.name, d.span, &typeNames[moduleOf(d.span), default: [:]], "type", diags)
        case .interfaceDecl(let d): record(d.name, d.span, &typeNames[moduleOf(d.span), default: [:]], "type", diags)
        case .funcDecl(let d):      record(d.name, d.span, &funcNames[moduleOf(d.span), default: [:]], "function", diags)
        case .extensionDecl:        break   // adds members to an existing type; declares no new symbol
        }
    }
}

private func record(_ name: String, _ span: Span, _ table: inout [String: Span], _ what: String, _ diags: DiagnosticSink) {
    if let first = table[name] {
        diags.error("duplicate \(what) '\(name)' — already declared at \(first.file):\(first.begin.line):\(first.begin.col)", at: span)
    } else {
        table[name] = span
    }
}
