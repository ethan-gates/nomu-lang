import ast
import support

// Duplicate-symbol detection across a module's files (task 100.1.3). A module is one namespace, so
// two top-level declarations that claim the same name collide. Types (struct/enum/class/actor/
// interface) share the type namespace; functions share the value namespace; the two are checked
// independently. Runs on the merged user program before the prelude is prepended, so it flags only
// the module's own declarations — shadowing a prelude symbol is a separate (cross-module) concern.
// Overloading is not a language feature, so any repeat of a name is a collision.
public func checkDuplicates(_ program: Program, into diags: DiagnosticSink) {
    var typeNames: [String: Span] = [:]
    var funcNames: [String: Span] = [:]

    for decl in program.decls {
        switch decl {
        case .structDecl(let d):    record(d.name, d.span, &typeNames, "type", diags)
        case .enumDecl(let d):      record(d.name, d.span, &typeNames, "type", diags)
        case .classDecl(let d):     record(d.name, d.span, &typeNames, "type", diags)
        case .actorDecl(let d):     record(d.name, d.span, &typeNames, "type", diags)
        case .interfaceDecl(let d): record(d.name, d.span, &typeNames, "type", diags)
        case .funcDecl(let d):      record(d.name, d.span, &funcNames, "function", diags)
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
