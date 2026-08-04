// M8 — the LLVM backend seam. All LLVM C-API use stays inside this module, so the driver sees a
// flat surface: a typed `IRModule` in, a native object out (`emitObject`), or nil/error. The
// per-node lowering lives in `Lowering.swift` (`IRToLLVM`); this file drives target setup, the GC
// pass pipeline (`mem2reg`/`sroa` → `rewrite-statepoints-for-gc`, or `-O2` in release), and object
// emission via `llvm-c/TargetMachine.h`.
import LLVM_C
import frontend

/// Lower a whole typed IR module to a native object file for the host triple (the driver then links
/// it with the runtime `.a`). Returns nil on success, else a `file:line:col`-prefixed error.
/// `optimize` selects the release (`default<O2>`) pipeline over the debug default (8.5.3).
public func emitObject(_ module: IRModule, to path: String, optimize: Bool = false) -> String? {
    // Register the host target + asm printer; both are required to emit objects. These return
    // nonzero when LLVM was configured without a native target (won't happen for our host build).
    guard LLVMInitializeNativeTarget() == 0 else { return "LLVM: no native target configured" }
    guard LLVMInitializeNativeAsmPrinter() == 0 else { return "LLVM: no native asm printer configured" }

    let ctx = LLVMContextCreate()!
    defer { LLVMContextDispose(ctx) }
    let mod = LLVMModuleCreateWithNameInContext("nomu", ctx)!

    let lowerer = IRToLLVM(ctx: ctx, mod: mod)
    lowerer.lower(module)
    if let err = lowerer.error { return err }
    guard lowerer.loweredMain else { return "LLVM: no `main` function to lower" }

    if LLVMVerifyModule(mod, LLVMReturnStatusAction, nil) != 0 {
        return "LLVM: module failed verification"
    }
    return emitModuleObject(mod, to: path, optimize: optimize)
}

/// Emit an already-built, verified module to a native object file for the host triple, via
/// `llvm-c/TargetMachine.h`. Returns nil on success, else an error message.
private func emitModuleObject(_ mod: LLVMModuleRef, to path: String, optimize: Bool) -> String? {
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

    // Stamp the target's data layout onto the module so it and the object agree.
    let dl = LLVMCreateTargetDataLayout(tm)
    let dlStr = LLVMCopyStringRepOfTargetData(dl)
    LLVMSetDataLayout(mod, dlStr)
    LLVMDisposeMessage(dlStr)
    LLVMDisposeTargetData(dl)

    // 8.4.1 — GC substrate pass pipeline. `mem2reg`/`sroa` promote our alloca-per-local lowering
    // to SSA so `RewriteStatepointsForGC` can see the `addrspace(1)` roots (a correctness
    // prerequisite, m6-spec.md §6.0.8), then the rewrite turns every non-`gc-leaf` call in a
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
    let pipeline = optimize
        ? "default<O2>,rewrite-statepoints-for-gc"
        : "function(mem2reg,sroa),rewrite-statepoints-for-gc"
    if let err = LLVMRunPasses(mod, pipeline, tm, opts) {
        let m = LLVMGetErrorMessage(err).map { String(cString: $0) } ?? "unknown"
        LLVMConsumeError(err)
        return "LLVM: GC pass pipeline failed: \(m)"
    }

    var emitErr: UnsafeMutablePointer<CChar>? = nil
    let rc = path.withCString { cpath in
        LLVMTargetMachineEmitToFile(tm, mod, cpath, LLVMObjectFile, &emitErr)
    }
    if rc != 0 {
        let m = emitErr.map { String(cString: $0) } ?? "unknown"
        LLVMDisposeMessage(emitErr)
        return "LLVM: object emission failed: \(m)"
    }
    return nil
}
