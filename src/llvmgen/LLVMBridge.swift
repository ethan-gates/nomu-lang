import ssair
import ssairpasses
import facts
import noir
import ast
import support
// M8 — the LLVM backend boundary. All LLVM C-API use stays inside this module, so the driver sees a
// flat surface: an already-gen'd `SSAModule` in, a native object out (`emitObject`), or nil/error. The
// driver gens NOIR → SSAIR (`lowerToSSAIR`) and interposes inference + `.nmi` emit (task 164); this file
// runs the optimizer pipeline → LLVM (`SSAIRToLLVM`), target setup, the GC pass pipeline (`mem2reg`/`sroa`
// → `rewrite-statepoints-for-gc`, or `-O2` in release), and object emission via `llvm-c/TargetMachine.h`.
import Foundation
import LLVM_C
import NomuLLVMPasses

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

/// The optimizer switches a job's settings give (`opt.*` in the compiler's settings): each SSAIR pass, the
/// escape provider, and the inline allocation fast path. All on, with the legacy provider, by default.
public struct OptimizerSettings {
    public enum EscapeProvider { case legacy, graph, graphPrecise }
    public var devirt = true
    public var inline = true
    public var escape = true
    public var scalar = true
    public var escapeProvider = EscapeProvider.legacy
    public var inlineAlloc = true
    // Measurement only (`measure.*`, task 243.1): unsound switches that remove a cost of finding roots.
    public var noStatepoints = false
    public var noShapedHomes = false
    public var noLoopPolls = false
    public var gcValueRegs = 0
    public var noFrameSplit = false
    public var noStackChecks = false
    public var libcDirect = false
    // Compiled against the runtime prelude (`test.runtime_prelude`): a white-box test that calls runtime
    // internals by name (`FrameTable.runtimePrelude`).
    public var runtimePrelude = false
    public init() {}
}

/// Lower an already-gen'd SSAIR module to a native object file for the host triple (the driver gens the
/// SSA, interposes inference + `.nmi` emit, then calls this and links the result with the runtime `.a`).
/// `noirModule` is the source NOIR the egress still reads for lowering. Returns nil on success, else a
/// `file:line:col`-prefixed error. `optimize` selects the release (`default<O2>`) pipeline over the debug
/// default (8.5.3).
// Emit `ssa` as an object at `path`. A checked function whose frame is larger than the stack reserve holds
// (`LLVMGen.stackFrameLimit`) is known only once LLVM lays the frame out, so the module then compiles again
// with each such function split into a wrapper that checks for its frame and an unchecked body
// (`nomuSplitLargeFrame`); a body whose frame comes out larger than its wrapper asked for compiles once
// more with the larger size.
public func emitObject(_ ssa: SSAModule, from noirModule: NOIRModule, to path: String, optimize: Bool = false,
                       onStage: StageSink? = nil,
                       emitLLVMTo: String? = nil, stopAfterEgress: Bool = false,
                       requireMain: Bool = true, externalFuncNames: Set<String> = [],
                       externalGenericSigs: [String: ExternalGenericSig] = [:],
                       weakOriginFiles: Set<String> = [], emitTypeMaps: Bool = true,
                       homeModule: [String] = [], dependencyModules: [[String]] = [], isRuntimePackage: Bool = false,
                       facts: FactStore = FactStore(),
                       optimizer: OptimizerSettings = OptimizerSettings(), gcRecordLevel: Int = 0,
                       gcPlan: Int = 0) -> String? {
    var largeFrames: [String: Int] = [:]
    for _ in 0..<3 {
        var oversized: [String: Int] = [:]
        let err = emitObjectAttempt(ssa, from: noirModule, to: path, optimize: optimize, onStage: onStage,
                                    emitLLVMTo: emitLLVMTo, stopAfterEgress: stopAfterEgress,
                                    requireMain: requireMain, externalFuncNames: externalFuncNames,
                                    externalGenericSigs: externalGenericSigs, weakOriginFiles: weakOriginFiles,
                                    emitTypeMaps: emitTypeMaps, homeModule: homeModule,
                                    dependencyModules: dependencyModules, isRuntimePackage: isRuntimePackage,
                                    facts: facts, optimizer: optimizer, gcRecordLevel: gcRecordLevel,
                                    gcPlan: gcPlan, largeFrames: largeFrames, oversized: &oversized)
        if oversized.isEmpty { return err }
        let before = largeFrames
        for (f, size) in oversized { largeFrames[f] = max(largeFrames[f] ?? 0, (size + 256 + 15) / 16 * 16) }
        // Splitting again cannot help when no frame asks for more room: the wrapper itself is over the limit.
        if largeFrames == before {
            let lines = oversized.sorted { $0.key < $1.key }.map { "  '\($0.key)': \($0.value) bytes" }
            return "stack frames still over the limit after splitting:\n" + lines.joined(separator: "\n")
        }
    }
    return "stack frames still over the limit after splitting: " + largeFrames.keys.sorted().joined(separator: ", ")
}

private func emitObjectAttempt(_ ssa: SSAModule, from noirModule: NOIRModule, to path: String, optimize: Bool = false,
                       onStage: StageSink? = nil,
                       emitLLVMTo: String? = nil, stopAfterEgress: Bool = false,
                       requireMain: Bool = true, externalFuncNames: Set<String> = [],
                       externalGenericSigs: [String: ExternalGenericSig] = [:],
                       weakOriginFiles: Set<String> = [], emitTypeMaps: Bool = true,
                       homeModule: [String] = [], dependencyModules: [[String]] = [], isRuntimePackage: Bool = false,
                       facts: FactStore = FactStore(),
                       optimizer: OptimizerSettings = OptimizerSettings(), gcRecordLevel: Int = 0,
                       gcPlan: Int = 0, largeFrames: [String: Int], oversized: inout [String: Int]) -> String? {
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

    // The backend egress takes the gen'd SSAIR → LLVM (the sole path since M7.7 retired the NOIR
    // tree-walk; the driver owns gen now, task 165.1). The optimizer pipeline runs in place, verifying
    // the GC-precision invariants (§7.0.5) after every pass. Pipeline order is devirt → inline →
    // stack/scalar promotion (§7.0.4): devirt un-uses a locally-dispatched box and inline exposes callee
    // bodies, so promotion then falls out. Each pass has a switch in `optimizer` so a tier-off baseline stays
    // available for bisecting a regression.
    var ssaModule = ssa
    var passes: [SSAPass] = []
    if optimizer.devirt { passes.append(Devirtualize()) }
    if optimizer.inline { passes.append(Inline()) }
    // Escape provider A/B (tasks 166.3/166.4): `graph` swaps the legacy `escapingValues` for the
    // points-to-graph-backed `graphEscaping`. Its faithful query reproduces `escapingValues` exactly (an
    // unchanged-output differential oracle over the suite); `graphPrecise` uses the graph's
    // container/field-sensitive query, which promotes a superset. Both stay available to bisect a precision
    // regression back to faithful, then back to legacy.
    if optimizer.escape {
        if optimizer.escapeProvider != .legacy {
            let aggregates = ssaModule.aggregates
            let precise = optimizer.escapeProvider == .graphPrecise
            passes.append(StackPromotion(escaping: { graphEscaping($0, aggregates: aggregates, precise: precise) }))
        } else {
            passes.append(StackPromotion())
        }
    }
    // Scalar promotion (§7.3.1) rides the escape switch (off ⇒ no promotion) with its own bisect switch;
    // it decomposes a loop-carried non-escaping class the simple-slot path leaves heap.
    if optimizer.escape && optimizer.scalar { passes.append(ScalarPromotion()) }
    let pipeline = PassPipeline(passes)
    let violations = pipeline.run(&ssaModule, stem: path, onStage: onStage)
    if let first = violations.first { return "SSAIR verify: \(first)" }
    let egress = SSAIRToLLVM(ctx: ctx, mod: mod)
    egress.e.externalFuncNames = externalFuncNames
    egress.e.externalGenericSigs = externalGenericSigs
    egress.e.weakOriginFiles = weakOriginFiles
    egress.e.emitsTypeMaps = emitTypeMaps
    egress.e.homeModule = homeModule
    egress.e.dependencyModules = dependencyModules
    egress.e.isRuntimePackage = isRuntimePackage
    egress.e.emitsProcessEntry = requireMain
    egress.e.inlineAlloc = optimizer.inlineAlloc
    egress.e.measureNoStatepoints = optimizer.noStatepoints
    egress.e.measureNoShapedHomes = optimizer.noShapedHomes
    egress.e.measureNoLoopPolls = optimizer.noLoopPolls
    egress.e.measureNoStackChecks = optimizer.noStackChecks
    egress.e.measureLibcDirect = optimizer.libcDirect
    egress.e.countsAllocations = gcRecordLevel > 1
    egress.e.emitsWriteBarrier = gcPlan == 0
    cgStage("llvm", "egress", onStage) { egress.lower(ssaModule, from: noirModule) }
    if let err = egress.error { return err }
    // The entry object must have `main`; a library object need not.
    if requireMain, !egress.loweredMain { return "LLVM: no `main` function to lower" }
    if let err = checkHostSlotLayout(egress.e) { return err }

    var errorMessage: UnsafeMutablePointer<CChar>! = nil
    let verifyRC = cgStage("llvm", "verify", onStage) { LLVMVerifyModule(mod, LLVMReturnStatusAction, &errorMessage) }
    if verifyRC != 0 {
        let message = String(cString: errorMessage)
        print("LLVM Module Verification Failed:\n\(message)")
        return "LLVM: module failed verification"
    }
    // The egress module as emitted, before the optimization/statepoint pipeline — the artifact
    // `--emit-llvm` captures (a stable golden for backend refactors; `--stop=llvm` halts here).
    if let llpath = emitLLVMTo {
        llpath.withCString { _ = LLVMPrintModuleToFile(mod, $0, nil) }
    }
    if stopAfterEgress { return nil }
    for (name, need) in largeFrames.sorted(by: { $0.key < $1.key }) {
        if let f = LLVMGetNamedFunction(mod, name) { _ = nomuSplitLargeFrame(f, UInt64(need)) }
    }
    return emitModuleObject(mod, to: path, optimize: optimize, optimizer: optimizer, onStage: onStage,
                            entries: egress.e.runtimeEntries, oversized: &oversized)
}

/// A value the runtime reads from a global in the settings object: an `int64_t`, a `uint8_t` 0 or 1, or a
/// NUL-terminated `const char[]`.
public enum RuntimeGlobal {
    case int(Int64)
    case bool(Bool)
    case string(String)
}

/// Emit the settings object a binary links (G14 of the build-configuration design): one exported constant
/// per runtime setting, under the symbol the runtime declares. Returns nil on success, else an error.
public func emitSettingsObject(_ globals: [(symbol: String, value: RuntimeGlobal)], to path: String) -> String? {
    guard LLVMInitializeNativeTarget() == 0 else { return "LLVM: no native target configured" }
    guard LLVMInitializeNativeAsmPrinter() == 0 else { return "LLVM: no native asm printer configured" }
    guard LLVMInitializeNativeAsmParser() == 0 else { return "LLVM: no native asm parser configured" }
    let ctx = LLVMContextCreate()!
    defer { LLVMContextDispose(ctx) }
    let mod = LLVMModuleCreateWithNameInContext("nomu.settings", ctx)!
    for (symbol, value) in globals {
        let initializer: LLVMValueRef
        switch value {
        case .int(let v): initializer = LLVMConstInt(LLVMInt64TypeInContext(ctx), UInt64(bitPattern: v), 1)
        case .bool(let b): initializer = LLVMConstInt(LLVMInt8TypeInContext(ctx), b ? 1 : 0, 0)
        case .string(let s): initializer = LLVMConstStringInContext2(ctx, s, s.utf8.count, 0)
        }
        let g = LLVMAddGlobal(mod, LLVMTypeOf(initializer), symbol)!
        LLVMSetInitializer(g, initializer)
        LLVMSetGlobalConstant(g, 1)
    }
    return emitModuleObject(mod, to: path, optimize: false)
}

// The target objects are emitted for: the host triple, CPU and CPU features, as `emitModuleObject` passes them
// to the target machine. Build-cache keys cover them, since an object is tuned to the host it was built on.
public func objectTarget() -> (triple: String, cpu: String, features: String) {
    let triple = LLVMGetDefaultTargetTriple()!, cpu = LLVMGetHostCPUName()!, features = LLVMGetHostCPUFeatures()!
    defer { LLVMDisposeMessage(triple); LLVMDisposeMessage(cpu); LLVMDisposeMessage(features) }
    return (String(cString: triple), String(cString: cpu), String(cString: features))
}

/// Emit an already-built, verified module to a native object file for the host triple, via
/// `llvm-c/TargetMachine.h`. Returns nil on success, else an error message.
// Run the 8-byte-slot layout check (`LLVMGen.checkSlotLayout`) under the host target's data layout, the one
// `emitModuleObject` stamps onto the module.
private func checkHostSlotLayout(_ gen: LLVMGen) -> String? {
    let triple = LLVMGetDefaultTargetTriple()!
    defer { LLVMDisposeMessage(triple) }
    var target: LLVMTargetRef? = nil
    var tErr: UnsafeMutablePointer<CChar>? = nil
    if LLVMGetTargetFromTriple(triple, &target, &tErr) != 0 {
        let m = tErr.map { String(cString: $0) } ?? "unknown"
        LLVMDisposeMessage(tErr)
        return "LLVM: no target for host triple: \(m)"
    }
    guard let tm = LLVMCreateTargetMachine(target, triple, "", "", LLVMCodeGenLevelDefault, LLVMRelocPIC,
                                           LLVMCodeModelDefault)
    else { return "LLVM: failed to create target machine" }
    defer { LLVMDisposeTargetMachine(tm) }
    let dl = LLVMCreateTargetDataLayout(tm)!
    defer { LLVMDisposeTargetData(dl) }
    return gen.checkSlotLayout(dl)
}

private func emitModuleObject(_ mod: LLVMModuleRef, to path: String, optimize: Bool,
                              optimizer: OptimizerSettings = OptimizerSettings(),
                              onStage: StageSink? = nil, entries: Set<String> = []) -> String? {
    var oversized: [String: Int] = [:]
    return emitModuleObject(mod, to: path, optimize: optimize, optimizer: optimizer, onStage: onStage,
                            entries: entries, oversized: &oversized)
}

// `oversized` receives each function to split: a checked one whose frame is over the limit, or the wrapper
// of a body whose frame is over the room its check asks for, with the frame's size.
private func emitModuleObject(_ mod: LLVMModuleRef, to path: String, optimize: Bool,
                              optimizer: OptimizerSettings = OptimizerSettings(),
                              onStage: StageSink? = nil, entries: Set<String> = [],
                              oversized: inout [String: Int]) -> String? {
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
    let hostFeatures = LLVMGetHostCPUFeatures()!
    defer { LLVMDisposeMessage(hostFeatures) }
    // x28 holds the running fiber in all Nomu code (the stack check reads its limit through it), so no
    // function may allocate it; the context switch saves and restores it with the other callee-saved registers.
    // The host's list can be empty (it is on Apple silicon), and an empty entry in the list leaves LLVM's
    // target machine without subtarget info, so only non-empty parts are joined.
    let features = ([String(cString: hostFeatures)] + (TargetPlatform.host.isArm64 ? ["+reserve-x28"] : []))
        .filter { !$0.isEmpty }.joined(separator: ",")

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
    // that one atom non-strippable while the rest of dead-strip's win is unaffected. Harmless no-op for a statepoint-free program (the symbol is simply absent).
    let keepStackmaps = ".no_dead_strip __LLVM_StackMaps\n"
    keepStackmaps.withCString { LLVMAppendModuleInlineAsm(mod, $0, keepStackmaps.utf8.count) }

    // Stamp the target's data layout onto the module so it and the object agree, with the managed address
    // space marked non-integral (`ni:1`): the optimizer may then not turn a managed pointer into an integer
    // and back, which the statepoint rewrite could not relocate (`internals/frames-statepoints.md`, problem 23).
    let dl = LLVMCreateTargetDataLayout(tm)
    let dlStr = LLVMCopyStringRepOfTargetData(dl)!
    let layout = String(cString: dlStr) + "-ni:1"
    LLVMSetDataLayout(mod, layout)
    LLVMDisposeMessage(dlStr)
    LLVMDisposeTargetData(dl)

    // Frame pointers in every function that makes calls (`frame-pointer`=`non-leaf`, clang's default on Apple
    // arm64, which the platform's ABI expects): each such function sets x29 to its frame record, so the fault
    // handler's backtrace (task 219, `runtime/fault.nomu`) can walk the chain. Without it LLVM keeps x29 as an
    // ordinary callee-saved register and the chain breaks at the first Nomu frame.
    let fpKey = "frame-pointer", fpValue = "non-leaf"
    var fnIter = LLVMGetFirstFunction(mod)
    while let f = fnIter {
        if LLVMCountBasicBlocks(f) > 0 {
            let attr = LLVMCreateStringAttribute(LLVMGetModuleContext(mod), fpKey, UInt32(fpKey.utf8.count),
                                                 fpValue, UInt32(fpValue.utf8.count))
            LLVMAddAttributeAtIndex(f, LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex)), attr)
        }
        fnIter = LLVMGetNextFunction(f)
    }

    // 8.4.1 — GC substrate pass pipeline. `mem2reg`/`sroa` promote our alloca-per-local lowering
    // to SSA so `RewriteStatepointsForGC` can see the `addrspace(1)` roots (a correctness
    // prerequisite, backend.md GC backend substrate), then the rewrite turns every non-`gc-leaf` call in a
    // `gc "statepoint-example"` function into a `gc.statepoint` with relocatable roots. Nothing
    // moves in 8.4, so the relocations are identity — behavior is unchanged. The full `-O`
    // pipeline lands in 8.5; this is the minimum ordering the rewrite needs.
    // 8.5.3 — opt level chooses what runs before the statepoint rewrite: `-O` (release) runs the
    // full `default<O2>` pipeline; the default (debug) runs just the `mem2reg`/`sroa` the rewrite
    // needs to find SSA roots, keeping Tier-0 debug info intact. `rewrite-statepoints-for-gc` runs
    // last either way (8.0.7), so opts see ordinary pointers and statepoint spill/reload noise is
    // introduced only after optimization.
    // `always-inline` (M6 · 6.2.3) collapses the mutator seams (poll / alloc / write-barrier) into
    // their call sites before the statepoint rewrite, so the poll's fast path is a bare load+branch
    // and only its cold slow-path call carries a statepoint. `default<O2>` already inlines.
    // The frame-address tracking (`nomu-track-frame-addresses`, `src/llvmpasses`) runs on the optimized IR,
    // before the rewrite. `measure.no_frame_split` drops its markers instead; `measure.no_statepoints`
    // (task 243.1) drops the rewrite, so calls stay plain and references are not spilled.
    let track = optimizer.noFrameSplit ? ",nomu-drop-frame-addresses" : ",nomu-track-frame-addresses"
    let rewrite = optimizer.noStatepoints ? "" : ",rewrite-statepoints-for-gc"
    // `nomu-bundle-calls` keeps roots recorded on a call through inlining, so it precedes any; a bundle stops
    // tail recursion elimination, so release runs that first.
    let pipeline = (optimize ? "function(sroa,early-cse,simplifycfg,tailcallelim),nomu-bundle-calls,default<O3>"
                             : "function(mem2reg,sroa),nomu-bundle-calls,always-inline")
        + ",nomu-indirect-large-values,nomu-expand-stack-checks,nomu-split-reference-aggregates"
        + track + rewrite
    if optimizer.gcValueRegs > 0 { setGCValueRegisters(optimizer.gcValueRegs) }
    // The frame-address split (`src/llvmpasses`): no address into the frame stays in a register across a stop,
    // so a copied stack leaves no stale address behind. Registered process-wide, once.
    if !optimizer.noFrameSplit { nomuRegisterFrameAddressSplit() }
    if ProcessInfo.processInfo.environment["NOMU_DUMP_LLVM"] != nil {
        (path + ".pre.ll").withCString { _ = LLVMPrintModuleToFile(mod, $0, nil) }
    }
    let passErr = cgStage("llvm", "opt", onStage) { nomuRunPasses(mod, pipeline, tm) }
    if let err = passErr {
        let m = LLVMGetErrorMessage(err).map { String(cString: $0) } ?? "unknown"
        LLVMConsumeError(err)
        return "LLVM: GC pass pipeline failed: \(m)"
    }

    if ProcessInfo.processInfo.environment["NOMU_DUMP_LLVM"] != nil {
        (path + ".post.ll").withCString { _ = LLVMPrintModuleToFile(mod, $0, nil) }
    }
    // Frame sizes: LLVM reports every function's frame (a `warn-stack-size` of 0 on each), which the build
    // records in the object's frame table (`FrameTable`, written beside it as `<stem>.frames`) for the link's
    // check of unchecked call chains; a checked function's frame over `LLVMGen.stackFrameLimit` fails the
    // build here. `NOMU_FRAME_SIZES=1` also prints the table, for `tools/frame-depth.py`.
    let reportFrames = ProcessInfo.processInfo.environment["NOMU_FRAME_SIZES"] != nil
    let diagnostics = CodegenDiagnostics()
    var table = frameTableOfModule(mod)
    table.entries = entries
    table.runtimePrelude = optimizer.runtimePrelude
    diagnostics.checked = table.checked
    let llvmCtx = LLVMGetModuleContext(mod)
    LLVMContextSetDiagnosticHandler(llvmCtx, codegenDiagnosticHandler, Unmanaged.passUnretained(diagnostics).toOpaque())
    defer { LLVMContextSetDiagnosticHandler(llvmCtx, nil, nil) }

    var emitErr: UnsafeMutablePointer<CChar>? = nil
    let rc = cgStage("llvm", "emit", onStage) { path.withCString { cpath in
        LLVMTargetMachineEmitToFile(tm, mod, cpath, LLVMObjectFile, &emitErr)
    } }
    if rc != 0 {
        let m = emitErr.map { String(cString: $0) } ?? "unknown"
        LLVMDisposeMessage(emitErr)
        return "LLVM: object emission failed: \(m)"
    }
    if let first = diagnostics.errors.first { return "LLVM: \(first)" }
    for (body, cover) in table.covered {
        if let size = diagnostics.sizes[body], size > cover.need { diagnostics.oversized.append((cover.wrapper, size)) }
    }
    if !diagnostics.oversized.isEmpty {
        for o in diagnostics.oversized { oversized[o.function] = max(oversized[o.function] ?? 0, o.size) }
        let lines = diagnostics.oversized.map { "  '\($0.function)': \($0.size) bytes" }
        return "stack frame over the limit of \(LLVMGen.stackFrameLimit) bytes the stack reserve holds:\n"
            + lines.joined(separator: "\n")
    }
    var frames = table
    frames.sizes = diagnostics.sizes
    let text = frames.encoded()
    if reportFrames { fputs(frames.report(), stderr) }
    guard FileManager.default.createFile(atPath: FrameTable.path(forObject: path), contents: Data(text.utf8)) else {
        return "cannot write '\(FrameTable.path(forObject: path))'"
    }
    return nil
}

// Diagnostics LLVM reports while generating code for one module: every function's frame size
// (`warn-stack-size`), the checked ones over the stack reserve's limit, and errors.
private final class CodegenDiagnostics {
    var checked: Set<String> = []
    var sizes: [String: Int] = [:]
    var oversized: [(function: String, size: Int)] = []
    var errors: [String] = []
}

// The module's frame table before code generation: its defined functions, those that check their stack
// (they carry `warn-stack-size`, `emitStackCheck`), each one's direct callees and whether it makes an
// indirect call, and the functions whose address is taken (an indirect call may reach any of them). A
// threshold of 0 then goes on every defined function, so LLVM reports each frame.
private func frameTableOfModule(_ mod: LLVMModuleRef) -> FrameTable {
    let key = "warn-stack-size", zero = "0"
    let index = LLVMAttributeIndex(bitPattern: Int32(LLVMAttributeFunctionIndex))
    var table = FrameTable()
    var fnIter = LLVMGetFirstFunction(mod)
    while let f = fnIter {
        let name = String(cString: LLVMGetValueName(f))
        if LLVMCountBasicBlocks(f) > 0 {
            table.defined.insert(name)
            if LLVMGetStringAttributeAtIndex(f, index, key, UInt32(key.utf8.count)) != nil {
                table.checked.insert(name)
            }
            let coveredKey = "nomu-frame-covered"
            if let attr = LLVMGetStringAttributeAtIndex(f, index, coveredKey, UInt32(coveredKey.utf8.count)) {
                var len: UInt32 = 0
                let text = String(cString: LLVMGetStringAttributeValue(attr, &len))
                table.covered[name] = (need: Int(text) ?? 0, wrapper: String(name.dropLast(".frame".count)))
            }
            let calls = directCallees(f)
            if !calls.direct.isEmpty { table.calls[name] = calls.direct }
            if calls.indirect { table.indirect.insert(name) }
            LLVMAddAttributeAtIndex(f, index, LLVMCreateStringAttribute(LLVMGetModuleContext(mod), key,
                                                                        UInt32(key.utf8.count), zero, 1))
        }
        if !name.hasPrefix("llvm."), isAddressTaken(f) { table.addressTaken.insert(name) }
        fnIter = LLVMGetNextFunction(f)
    }
    return table
}

// Whether `f` is used other than as the target of a direct call (a statepoint's wrapped target counts as
// one): stored, passed, or referenced from a constant, so an indirect call may reach it.
private func isAddressTaken(_ f: LLVMValueRef) -> Bool {
    var use = LLVMGetFirstUse(f)
    while let u = use {
        let user = LLVMGetUser(u)!
        let isCall = LLVMIsACallInst(user) != nil || LLVMIsAInvokeInst(user) != nil
        if !isCall { return true }
        let callee = LLVMGetCalledValue(user)
        let isStatepoint = callee.map { LLVMIsAFunction($0) != nil
            && String(cString: LLVMGetValueName($0)).hasPrefix("llvm.experimental.gc.statepoint") } ?? false
        let n = LLVMGetNumArgOperands(user)
        var asArgument = false
        for k in 0..<n where LLVMGetOperand(user, k) == f && !(isStatepoint && k == 2) { asArgument = true }
        if asArgument { return true }
        use = LLVMGetNextUse(u)
    }
    return false
}

// The functions `f` calls by name, a statepoint's wrapped target in place of the statepoint intrinsic, and
// whether it calls through a pointer (inline assembly is no call).
private func directCallees(_ f: LLVMValueRef) -> (direct: Set<String>, indirect: Bool) {
    var out: Set<String> = []
    var indirect = false
    var bb = LLVMGetFirstBasicBlock(f)
    while let block = bb {
        var inst = LLVMGetFirstInstruction(block)
        while let i = inst {
            if LLVMIsACallInst(i) != nil || LLVMIsAInvokeInst(i) != nil, var callee = LLVMGetCalledValue(i) {
                if LLVMIsAFunction(callee) != nil,
                   String(cString: LLVMGetValueName(callee)).hasPrefix("llvm.experimental.gc.statepoint"),
                   let target = LLVMGetOperand(i, 2) {
                    callee = target
                }
                if LLVMIsAFunction(callee) != nil {
                    let name = String(cString: LLVMGetValueName(callee))
                    if !name.hasPrefix("llvm.") { out.insert(name) }
                } else if LLVMIsAInlineAsm(callee) == nil {
                    indirect = true
                }
            }
            inst = LLVMGetNextInstruction(i)
        }
        bb = LLVMGetNextBasicBlock(block)
    }
    return (out, indirect)
}

// The text of LLVM's stack-size warning: "<location>: stack frame size (N) exceeds limit (M) in function 'f'".
private func parseStackSizeWarning(_ text: String) -> (function: String, size: Int)? {
    guard let open = text.range(of: "stack frame size ("),
          let close = text.range(of: ") exceeds limit (", range: open.upperBound..<text.endIndex),
          let size = Int(text[open.upperBound..<close.lowerBound]),
          let fnStart = text.range(of: "in function '", range: close.upperBound..<text.endIndex),
          text.hasSuffix("'")
    else { return nil }
    return (String(text[fnStart.upperBound..<text.index(before: text.endIndex)]), size)
}

private let codegenDiagnosticHandler: LLVMDiagnosticHandler = { info, context in
    guard let info = info, let context = context else { return }
    let diagnostics = Unmanaged<CodegenDiagnostics>.fromOpaque(context).takeUnretainedValue()
    let cText = LLVMGetDiagInfoDescription(info)!
    let text = String(cString: cText)
    LLVMDisposeMessage(cText)
    switch LLVMGetDiagInfoSeverity(info) {
    case LLVMDSError:
        diagnostics.errors.append(text)
    case LLVMDSWarning:
        if let frame = parseStackSizeWarning(text) {
            diagnostics.sizes[frame.function] = max(diagnostics.sizes[frame.function] ?? 0, frame.size)
            if diagnostics.checked.contains(frame.function) && frame.size > LLVMGen.stackFrameLimit {
                diagnostics.oversized.append(frame)
            }
        } else {
            fputs("LLVM warning: \(text)\n", stderr)
        }
    default:
        break
    }
}

// `measure.gc_value_regs` (task 243.1): LLVM's statepoint lowering keeps up to `n` references in registers,
// callee-saved ones included, instead of spilling them. These are process-wide LLVM options, parsed once: the
// first module compiled with a nonzero value sets them for the process.
private var gcValueRegistersSet = false
private func setGCValueRegisters(_ n: Int) {
    if gcValueRegistersSet { return }
    gcValueRegistersSet = true
    let args = ["nomu", "-max-registers-for-gc-values=\(n)", "-fixup-allow-gcptr-in-csr"]
    var cargs = args.map { strdup($0) }
    cargs.withUnsafeMutableBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
            LLVMParseCommandLineOptions(Int32(args.count), $0, nil)
        }
    }
    for c in cargs { free(c) }
}
