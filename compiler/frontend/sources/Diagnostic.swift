// Collected diagnostics — the checker reports many errors and continues, rather
// than exiting on the first (m4.9-spec.md §6). A reference type so a single sink
// threads through the semantic pass.

public enum Severity {
    case error
    case warning
}

public struct Diagnostic {
    public let severity: Severity
    public let message: String
    public let span: Span
}

public final class DiagnosticSink {
    public private(set) var diagnostics: [Diagnostic] = []

    public init() {}

    public func error(_ message: String, at span: Span) {
        diagnostics.append(Diagnostic(severity: .error, message: message, span: span))
    }

    public func warning(_ message: String, at span: Span) {
        diagnostics.append(Diagnostic(severity: .warning, message: message, span: span))
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    public var isEmpty: Bool { diagnostics.isEmpty }

    // `file:line:col: error: message`, one per line, in source order.
    public func render() -> String {
        diagnostics.map { d in
            let kind = d.severity == .error ? "error" : "warning"
            return "\(d.span.file):\(d.span.begin.line):\(d.span.begin.col): \(kind): \(d.message)"
        }.joined(separator: "\n")
    }
}
