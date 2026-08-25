import midend
import ssair
import ssairgen
import ssairpasses
import noir
import ast
import support
// M8 — the LLVM backend seam. All LLVM C-API use stays inside this module, so the driver sees a
// flat surface: a typed `NOIRModule` in, a native object out (`emitObject`), or nil/error. The
// per-node lowering lives in `Lowering.swift` (`NOIRToLLVM`); this file drives target setup, the GC
// pass pipeline (`mem2reg`/`sroa` → `rewrite-statepoints-for-gc`, or `-O2` in release), and object
// emission via `llvm-c/TargetMachine.h`.
import Foundation
import LLVM_C

// Codegen sub-stage timing. When the driver passes a `StageSink` (`onStage`), each sub-stage reports
// up into the phase-categorized `Timings` table (so the `ssair`/`llvm` phases break down rather than
// showing one opaque `codegen` bucket). With no sink but `NOMU_TIME_CODEGEN` set, it prints to stderr
// standalone; otherwise it is a plain call with no timing overhead.
private let cgTimed = ProcessInfo.processInfo.environment["NOMU_TIME_CODEGEN"] != nil
@discardableResult
private func cgStage<T>(_ phase: String, _ name: String, _ onStage: StageSink?, _ body: () -> T) -> T {
    if onStage == nil && !cgTimed { return body() }
    let t0 = Date()
    let r = body()
    let secs = Date().timeIntervalSince(t0)
    if let onStage { onStage(phase, name, secs) }
    else { FileHandle.standardError.write(Data("  [codegen] \(phase):\(name): \(String(format: "%.2f", secs * 1000)) ms\n".utf8)) }
    return r
}

/// Lower a whole typed IR module to a native object file for the host triple (the driver then links
/// it with the runtime `.a`). Returns nil on success, else a `file:line:col`-prefixed error.
/// `optimize` selects the release (`default<O2>`) pipeline over the debug default (8.5.3).
public func emitObject(_ module: NOIRModule, to path: String, optimize: Bool = false,
                       onStage: StageSink? = nil) -> String? {
    // Register the host target + asm printer; both are required to emit objects. These return
    // nonzero when LLVM was configured without a native target (won't happen for our host build).
    guard LLVMInitializeNativeTarget() == 0 else { return "LLVM: no native target configured" }
    guard LLVMInitializeNativeAsmPrinter() == 0 else { return "LLVM: no native asm printer configured" }
    // The object streamer assembles module-level inline asm (the `.no_dead_strip` stackmap keep, 6.2.1)
    // through the target's asm parser, so it must be registered too.
    guard LLVMInitializeNativeAsmParser() == 0 else { return "LLVM: no native asm parser configured" }

    let ctx = LLVMContextCreate()!
    defer { LLVMContextDispose(ctx) }
    let mod = LLVMModuleCreateWithNameInContext("nomu", ctx)!

    // 6.5.2 — escape analysis feeds codegen a side table of non-escaping allocation sites to
    // stack-allocate. Best-effort: `NOMU_NO_ESCAPE` disables it (empty table → every site heaps as
    // before), which is the correctness fallback and the exit-criterion off switch.
    // 7.2.3 — `NOMU_EGRESS=ssair` selects the SSAIR CFG-walk egress (NOIR→SSAIR→LLVM) over the default
    // NOIR tree-walk, for the corpus differential. Both share `LLVMGen`, so the GC ABI is identical.
    if ProcessInfo.processInfo.environment["NOMU_EGRESS"] == "ssair" {
        let ssa = cgStage("ssair", "gen", onStage) { lowerToSSAIR(module) }
        if ssa.diagnostics.hasErrors { return "SSAIR: " + ssa.diagnostics.render() }
        // M7.3/7.4 — run the optimizer pipeline in place, verifying the GC-precision invariants
        // (§7.0.5) after each pass. Pipeline order is devirt → EA (§7.0.4): devirt un-uses a
        // locally-dispatched box so stack promotion then falls out. Each pass has an A/B env gate
        // (`NOMU_NO_DEVIRT`, `NOMU_NO_ESCAPE`) so a tier-off baseline stays available.
        var ssaModule = ssa.module
        let env = ProcessInfo.processInfo.environment
        var passes: [SSAPass] = []
        if env["NOMU_NO_DEVIRT"] == nil { passes.append(Devirtualize()) }
        if env["NOMU_NO_INLINE"] == nil { passes.append(Inline()) }
        if env["NOMU_NO_ESCAPE"] == nil { passes.append(StackPromotion()) }
        // Scalar promotion (§7.3.1) rides the escape A/B flag (off ⇒ no promotion) with its own bisect
        // gate; it decomposes a loop-carried non-escaping class the simple-slot path leaves heap.
        if env["NOMU_NO_ESCAPE"] == nil && env["NOMU_NO_SCALAR"] == nil { passes.append(ScalarPromotion()) }
        let pipeline = PassPipeline(passes)
        let violations = pipeline.run(&ssaModule, stem: path, onStage: onStage)
        if let first = violations.first { return "SSAIR verify: \(first)" }
        let egress = SSAIRToLLVM(ctx: ctx, mod: mod)
        cgStage("llvm", "egress", onStage) { egress.lower(ssaModule, from: module) }
        if let err = egress.error { return err }
        guard egress.loweredMain else { return "LLVM: no `main` function to lower" }
    } else {
        let escapes = ProcessInfo.processInfo.environment["NOMU_NO_ESCAPE"] == nil
            ? analyzeEscapes(module) : EscapeResult(nonEscaping: [])
        let lowerer = NOIRToLLVM(ctx: ctx, mod: mod, escapes: escapes)
        cgStage("llvm", "egress", onStage) { lowerer.lower(module) }
        if let err = lowerer.error { return err }
        guard lowerer.loweredMain else { return "LLVM: no `main` function to lower" }
    }

    var errorMessage: UnsafeMutablePointer<CChar>! = nil
    let verifyRC = cgStage("llvm", "verify", onStage) { LLVMVerifyModule(mod, LLVMReturnStatusAction, &errorMessage) }
    if verifyRC != 0 {
        let message = String(cString: errorMessage)
        print("LLVM Module Verification Failed:\n\(message)")
        return "LLVM: module failed verification"
    }
    return emitModuleObject(mod, to: path, optimize: optimize, onStage: onStage)
}

/// Emit an already-built, verified module to a native object file for the host triple, via
/// `llvm-c/TargetMachine.h`. Returns nil on success, else an error message.
private func emitModuleObject(_ mod: LLVMModuleRef, to path: String, optimize: Bool,
                              onStage: StageSink? = nil) -> String? {
    let triple = LLVMGetDefaultTargetTriple()!
    defer { LLVMDisposeMessage(triple) }
    LLVMSetTarget(mod, triple)

    var target: LLVMTargetRef? = nil
    var tErr: UnsafeMutablePointer<CChar>? = nil
    if LLVMGetTargetFromTriple(triple, &target, &tErr) != 0 {
        let m = tErr.map { String(cString: $0) } ?? "unknown"
        LLVMDisposeMessage(tErr)
        return "LLVM: no target for host triple: \(m)"
    }

    let cpu = LLVMGetHostCPUName()!
    defer { LLVMDisposeMessage(cpu) }
    let features = LLVMGetHostCPUFeatures()!
    defer { LLVMDisposeMessage(features) }

    guard let tm = LLVMCreateTargetMachine(
        target, triple, cpu, features,
        LLVMCodeGenLevelDefault, LLVMRelocPIC, LLVMCodeModelDefault)
    else { return "LLVM: failed to create target machine" }
    defer { LLVMDisposeTargetMachine(tm) }

    // M6 · 6.2.1 — keep the LLVM stackmaps alive under the emitted-program link's `-dead_strip`
    // (6.1.1, for binary size). The stackmap section carries no symbol reference (the runtime finds
    // it by name at load time via getsectiondata), and its anchor `__LLVM_StackMaps` is a *local*
    // symbol in this object, so nothing in another object can pin it and global dead-strip would drop
    // it — silently defeating precise root scanning. A module-level `.no_dead_strip` directive marks
    // that one atom non-strippable while the rest of dead-strip's win (the unreachable MMTk closure)
    // is unaffected. Harmless no-op for a statepoint-free program (the symbol is simply absent).
    let keepStackmaps = ".no_dead_strip __LLVM_StackMaps\n"
    keepStackmaps.withCString { LLVMAppendModuleInlineAsm(mod, $0, keepStackmaps.utf8.count) }

    // Stamp the target's data layout onto the module so it and the object agree.
    let dl = LLVMCreateTargetDataLayout(tm)
    let dlStr = LLVMCopyStringRepOfTargetData(dl)
    LLVMSetDataLayout(mod, dlStr)
    LLVMDisposeMessage(dlStr)
    LLVMDisposeTargetData(dl)

    // 8.4.1 — GC substrate pass pipeline. `mem2reg`/`sroa` promote our alloca-per-local lowering
    // to SSA so `RewriteStatepointsForGC` can see the `addrspace(1)` roots (a correctness
    // prerequisite, compiler.md §2 GC backend substrate), then the rewrite turns every non-`gc-leaf` call in a
    // `gc "statepoint-example"` function into a `gc.statepoint` with relocatable roots. Nothing
    // moves in 8.4, so the relocations are identity — behavior is unchanged. The full `-O`
    // pipeline lands in 8.5; this is the minimum ordering the rewrite needs.
    // 8.5.3 — opt level chooses what runs before the statepoint rewrite: `-O` (release) runs the
    // full `default<O2>` pipeline; the default (debug) runs just the `mem2reg`/`sroa` the rewrite
    // needs to find SSA roots, keeping Tier-0 debug info intact. `rewrite-statepoints-for-gc` runs
    // last either way (8.0.7), so opts see ordinary pointers and statepoint spill/reload noise is
    // introduced only after optimization.
    let opts = LLVMCreatePassBuilderOptions()
    defer { LLVMDisposePassBuilderOptions(opts) }
    // `always-inline` (M6 · 6.2.3) collapses the mutator seams (poll / alloc / write-barrier) into
    // their call sites before the statepoint rewrite, so the poll's fast path is a bare load+branch
    // and only its cold slow-path call carries a statepoint. `default<O2>` already inlines.
    let pipeline = optimize
        ? "default<O3>,rewrite-statepoints-for-gc"
        : "function(mem2reg,sroa),always-inline,rewrite-statepoints-for-gc"
    if ProcessInfo.processInfo.environment["NOMU_DUMP_LLVM"] != nil {
        (path + ".pre.ll").withCString { _ = LLVMPrintModuleToFile(mod, $0, nil) }
    }
    let passErr = cgStage("llvm", "opt", onStage) { LLVMRunPasses(mod, pipeline, tm, opts) }
    if let err = passErr {
        let m = LLVMGetErrorMessage(err).map { String(cString: $0) } ?? "unknown"
        LLVMConsumeError(err)
        return "LLVM: GC pass pipeline failed: \(m)"
    }

    if ProcessInfo.processInfo.environment["NOMU_DUMP_LLVM"] != nil {
        (path + ".post.ll").withCString { _ = LLVMPrintModuleToFile(mod, $0, nil) }
    }
    var emitErr: UnsafeMutablePointer<CChar>? = nil
    let rc = cgStage("llvm", "emit", onStage) { path.withCString { cpath in
        LLVMTargetMachineEmitToFile(tm, mod, cpath, LLVMObjectFile, &emitErr)
    } }
    if rc != 0 {
        let m = emitErr.map { String(cString: $0) } ?? "unknown"
        LLVMDisposeMessage(emitErr)
        return "LLVM: object emission failed: \(m)"
    }
    return nil
}
