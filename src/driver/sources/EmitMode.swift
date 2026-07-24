// How far the compiler runs, and which intermediate artifacts it emits.
//
// Emit flags are **additive** — each requests an extra dump/report and never
// suppresses the binary. `stopAt` is the separate control that halts the pipeline
// (default: run all the way to the binary). Stopping at a stage emits that stage's
// artifact. More stop stages will be added as more intermediate formats appear.

public enum Stage {
    case ast       // after parse
    case typedIR   // after the semantic pass
    case binary    // full pipeline → native binary (default)
}

public struct EmitOptions {
    public var ast = false       // --emit-ast: emit the parsed AST (<name>.ast)
    public var typedIR = false   // --emit-typedir: emit the typed IR (<name>.typedir)
    public var c = false         // --emit-c: emit the generated C (<name>.c)
    public var stopAt: Stage = .binary

    public init() {}
}
