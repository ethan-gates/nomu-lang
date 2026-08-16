import noir
import ast
import support
// How far the compiler runs, and which intermediate artifacts it emits.
//
// Emit flags are **additive** — each requests an extra dump/report and never
// suppresses the binary. `stopAt` is the separate control that halts the pipeline
// (default: run all the way to the binary). Stopping at a stage emits that stage's
// artifact. More stop stages will be added as more intermediate formats appear.

public enum Stage {
    case ast       // after parse
    case noir      // after the semantic pass (NOIR — the Nomu typed IR)
    case binary    // full pipeline → native binary (default)
}

// NOIR is lowered to a native binary through the LLVM backend (M8) — LLVM's C API →
// object → link. The C backend was the differential oracle through 8.2 and was retired at the
// 8.2 exit, so there is no longer a backend to select.

public struct EmitOptions {
    public var ast = false       // --emit-ast: emit the parsed AST (<name>.ast)
    public var noir = false      // --emit-noir: emit NOIR (<name>.noir)
    public var stopAt: Stage = .binary
    // 8.5.3 — LLVM optimization level. Default (debug) runs the minimal `mem2reg`/`sroa` the
    // statepoint rewrite needs and preserves Tier-0 debug info; `-O`/`--release` runs the full
    // `default<O2>` pipeline (faster code, debug info degraded). Both precede statepoint rewriting.
    public var optimize = false  // -O / --release

    public init() {}
}
