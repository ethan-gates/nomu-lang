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

    // Compiler-internal (task 188): emit the entry module as a home-qualified **library object** (no `main`,
    // no program-wide type maps, no runtime link) rather than a binary — the shape every cross-workspace
    // build wants, since an external workspace's products are linked into a consumer, not run. Set by the
    // driver when it builds an external workspace's products (the embedded `nomu` workspace, or a pinned
    // local external). Never from the CLI.
    public var emitLibrary = false
    // Compiler-internal (task 174): this is the build of the embedded `nomu` workspace itself (`core`/
    // `runtime`/`std`), not a user program. Beyond `emitLibrary` (which it implies), it links their symbols
    // strong (no weak-origin, except the `runtime` package's own bare weak-ODR set). With the prepend retired
    // (174.5/.5.1) it no longer gates a prepend; it still marks these as the prelude build (strong linkage,
    // runtime-subset-by-membership source).
    public var compilingPrelude = false
    // Compiler-internal (task 174.4): designate every function in this `compilingPrelude` build runtime-subset
    // by **package membership** — set for the `runtime` package. Replaces the file-designation (the prepend's
    // `runtime.nomu` parse) as the subset source for the package build: its functions compile `noSafepoint`,
    // so the package copy carries no stackmaps, is unpinned, and dead-strips — collapsing the inert duplicate
    // the prepend's bare copies shadowed (the 100.4.4 interim). The prepend keeps its file-designation until
    // the prepend itself retires (174.5).
    public var runtimeSubsetByMembership = false

    public init() {}
}
