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
    // The object streamer assembles module-level inline asm (the `.no_dead_strip` stackmap keep, 6.2.1)
    // through the target's asm parser, so it must be registered too.
    guard LLVMInitializeNativeAsmParser() == 0 else { return "LLVM: no native asm parser configured" }

    let ctx = LLVMContextCreate()!
    defer { LLVMContextDispose(ctx) }
    let mod = LLVMModuleCreateWithNameInContext("nomu", ctx)!

    let lowerer = IRToLLVM(ctx: ctx, mod: mod)
    lowerer.lower(module)
    if let err = lowerer.error { return err }
    guard lowerer.loweredMain else { return "LLVM: no `main` function to lower" }

    var errorMessage: UnsafeMutablePointer<CChar>! = nil
    if LLVMVerifyModule(mod, LLVMReturnStatusAction, &errorMessage) != 0 {
        let message = String(cString: errorMessage)
        print("LLVM Module Verification Failed:\n\(message)")
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
    // `always-inline` (M6 · 6.2.3) collapses the mutator seams (poll / alloc / write-barrier) into
    // their call sites before the statepoint rewrite, so the poll's fast path is a bare load+branch
    // and only its cold slow-path call carries a statepoint. `default<O2>` already inlines.
    let pipeline = optimize
        ? "default<O2>,rewrite-statepoints-for-gc"
        : "function(mem2reg,sroa),always-inline,rewrite-statepoints-for-gc"
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
