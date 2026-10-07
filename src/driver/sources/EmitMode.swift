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
    case ssair     // after NOIR→SSAIR lowering (the optimizer IR, post-mono)
    case llvm      // after the SSAIR→LLVM egress (the module as emitted, pre-optimization)
    case binary    // full pipeline → native binary (default)
}

// NOIR is lowered to a native binary through the LLVM backend (M8) — LLVM's C API →
// object → link. The C backend was the differential oracle through 8.2 and was retired at the
// 8.2 exit, so there is no longer a backend to select.

// Specialization depth for the generics a module *consumes* across a boundary (the consumer dial, task
// 100.5.2). `none` keeps every imported generic on the erased witness path (debug default — fast builds,
// no `.bir` read); `edge` specializes directly-called instances (nested generic calls stay witness);
// `all` specializes the whole instantiation tree (release default — recovers monomorphized performance).
// A producer's advertised prespecialization still binds under `none` (it overrides the consumer dial).
public enum MonoMode: String, Equatable {
    case none, edge, all
}

public struct EmitOptions {
    public var ast = false       // --emit-ast: emit the parsed AST (<name>.ast)
    public var noir = false      // --emit-noir: emit NOIR (<name>.noir)
    public var ssair = false     // --emit-ssair: emit SSAIR, the optimizer IR (<name>.ssair)
    public var nmi = false        // --emit-nmi: emit the module's public interface (<name>.nmi), task 100.4.1
    public var llvm = false      // --emit-llvm: emit LLVM IR as emitted by the egress, pre-opt (<name>.ll)
    public var stopAt: Stage = .binary
    // 8.5.3 — LLVM optimization level. Default (debug) runs the minimal `mem2reg`/`sroa` the
    // statepoint rewrite needs and preserves Tier-0 debug info; `-O`/`--release` runs the full
    // `default<O2>` pipeline (faster code, debug info degraded). Both precede statepoint rewriting.
    public var optimize = false  // -O / --release
    // Task 149 — interim runtime-subset designation: the set of function names compiled under the subset
    // rules (no implicit GC alloc / heap construct / non-subset call). A compiler input standing in for
    // module membership until the module system (task 100) lands. Set by `--runtime-subset=a,b`.
    public var subsetFuncs: Set<String> = []
    // `-o <path>` — the output binary path. Artifacts derive from it (`<path>.o`, `<path>.ll`, …); its
    // parent directory is created. When nil, the path is derived from the primary source's location
    // under `build/`. The driver builds the file list; a module's identity/output name is given, not
    // inferred from a filename.
    public var outputPath: String? = nil
    // `--mono=none|edge|all` — the consumer specialization dial (task 100.5.2). Nil means "mode default":
    // resolved by `effectiveMono` to `none` for a debug build and `all` for a release (`-O`) build, so the
    // dial follows the optimization level unless set explicitly. Part of the build-cache key (task 172).
    public var mono: MonoMode? = nil
    // The dial in force, resolving the nil default against the optimization level (debug=none, release=all).
    public var effectiveMono: MonoMode { mono ?? (optimize ? .all : .none) }

    public init() {}
}
