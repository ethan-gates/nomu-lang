import noir
import ast
import support
// How far the compiler runs, and which intermediate artifacts it emits.
//
// Emit flags are **additive** — each requests an extra dump/report and never
// suppresses the binary. `stopAt` is the separate control that halts the pipeline
// (default: run all the way to the binary). Stopping at a stage emits that stage's
// artifact. More stop stages will be added as more intermediate formats appear.

public enum Stage: String, Codable {
    case plan      // after planning: print the build plan (`Plan.dump()`) and stop
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
public enum MonoMode: String, Equatable, Codable {
    case none, edge, all
}

public struct EmitOptions: Codable {
    public var ast = false       // --emit-ast: emit the parsed AST (<name>.ast)
    public var noir = false      // --emit-noir: emit NOIR (<name>.noir)
    public var ssair = false     // --emit-ssair: emit SSAIR, the optimizer IR (<name>.ssair)
    public var nmi = false        // --emit-nmi: emit the module's public interface (<name>.nmi), task 100.4.1
    public var llvm = false      // --emit-llvm: emit LLVM IR as emitted by the egress, pre-opt (<name>.ll)
    public var stopAt: Stage = .binary
    // Task 149 — interim runtime-subset designation: the set of function names compiled under the subset
    // rules (no implicit GC alloc / heap construct / non-subset call). A compiler input standing in for
    // module membership until the module system (task 100) lands. Set by `--runtime-subset=a,b`.
    public var subsetFuncs: Set<String> = []
    // Compiler-internal (task 174): the job compiles a module of the language workspace (`core`/
    // `runtime`/`std`), not user code. Its symbols link strong (no weak origin, except the `runtime`
    // package's own bare weak-ODR set), and no white-box runtime prelude is prepended.
    public var compilingPrelude = false
    // Test-suite only (hidden `--allow-core-import`): let user code `import core`. The language workspace's
    // `core` package is otherwise importable only from `std` (modules.md §Imports — `std` is the gateway to
    // the language workspace); fixtures that exercise `core`'s compiler-backed types directly lift that gate
    // with this.
    public var allowCoreImport = false
    // Hidden `--emit-jobs`: write each job's file (`<unit>/<stem>.job.json`, the `nomu compile` input) beside
    // its outputs.
    public var emitJobs = false
    // `--verify-cache`: compile every job, taking nothing from the host cache, and fail when an entry
    // already at a job's key differs from its compile (`CacheVerification`).
    public var verifyCache = false

    public init() {}
}
