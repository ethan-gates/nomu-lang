// M8.1 · 8.1.2 — prove Swift can import an LLVM Clang module via cxx-interop against
// @llvm-project (the C API module `LLVM_C`, pure C — no C++ interop hazards).
// M8.1 · 8.1.3 — hand-build the hello-world module (int arithmetic + external print) through
// the same C API. M8.1 · 8.1.5 — lower a real `main` from the typed IR (`IRToLLVM`) and emit it.
import LLVM_C
import frontend

public func llvmInteropOK() -> Bool {
    // Prove the C API is usable from Swift: build a module, a fn `answer()->i64 { ret 42 }`.
    let ctx = LLVMContextCreate()
    defer { LLVMContextDispose(ctx) }
    let mod = LLVMModuleCreateWithNameInContext("nomu_smoke", ctx)
    let i64 = LLVMInt64TypeInContext(ctx)
    let fnTy = LLVMFunctionType(i64, nil, 0, 0)
    let fn = LLVMAddFunction(mod, "answer", fnTy)
    let entry = LLVMAppendBasicBlockInContext(ctx, fn, "entry")
    let b = LLVMCreateBuilderInContext(ctx)
    LLVMPositionBuilderAtEnd(b, entry)
    _ = LLVMBuildRet(b, LLVMConstInt(i64, 42, 0))
    let ok = LLVMVerifyModule(mod, LLVMReturnStatusAction, nil) == 0
    LLVMDisposeBuilder(b)
    return ok
}

/// Result of building a module by hand: whether it verifies, and its textual IR.
public struct BuiltModule {
    public let verified: Bool
    public let ir: String
}

/// Construct, entirely via the LLVM C API, the equivalent of Nomu's `fun main { print(2 + 3) }`
/// into `ctx` (the caller owns `ctx` and the returned module):
///
///   define i32 @main() {
///   entry:
///     %sum = add i64 2, 3
///     call i32 (ptr, ...) @printf(ptr @fmt, i64 %sum)
///     ret i32 0
///   }
///
/// `print(int)` mirrors the C backend's lowering (`CodegenIR.swift`): `printf("%lld\n", n)`.
/// 8.1.5 replaces this fixed module with real lowering from the typed IR.
private func buildHelloWorld(in ctx: LLVMContextRef) -> LLVMModuleRef {
    let mod = LLVMModuleCreateWithNameInContext("nomu_main", ctx)!
    let b = LLVMCreateBuilderInContext(ctx)
    defer { LLVMDisposeBuilder(b) }

    let i8 = LLVMInt8TypeInContext(ctx)
    let i32 = LLVMInt32TypeInContext(ctx)
    let i64 = LLVMInt64TypeInContext(ctx)
    let i8ptr = LLVMPointerType(i8, 0)

    // Declare the external variadic `int printf(const char*, ...)`.
    var printfParams: [LLVMTypeRef?] = [i8ptr]
    let printfTy = printfParams.withUnsafeMutableBufferPointer {
        LLVMFunctionType(i32, $0.baseAddress, 1, /*isVarArg=*/1)
    }
    let printfFn = LLVMAddFunction(mod, "printf", printfTy)

    // define i32 @main()
    let mainTy = LLVMFunctionType(i32, nil, 0, 0)
    let mainFn = LLVMAddFunction(mod, "main", mainTy)
    let entry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")
    LLVMPositionBuilderAtEnd(b, entry)

    // %sum = add i64 2, 3   (constant-folded by LLVM, but built as a real `add`).
    let sum = LLVMBuildAdd(b, LLVMConstInt(i64, 2, 0), LLVMConstInt(i64, 3, 0), "sum")

    // @fmt = private global "%lld\n\0"; get an i8* to it.
    let fmt = LLVMBuildGlobalStringPtr(b, "%lld\n", "fmt")

    // call i32 (ptr, ...) @printf(ptr @fmt, i64 %sum)
    var callArgs: [LLVMValueRef?] = [fmt, sum]
    _ = callArgs.withUnsafeMutableBufferPointer {
        LLVMBuildCall2(b, printfTy, printfFn, $0.baseAddress, 2, "")
    }

    // ret i32 0
    _ = LLVMBuildRet(b, LLVMConstInt(i32, 0, 0))
    return mod
}

/// 8.1.3 — build + verify the hello-world module and return its textual IR.
public func buildHelloWorldModule() -> BuiltModule {
    let ctx = LLVMContextCreate()!
    defer { LLVMContextDispose(ctx) }
    let mod = buildHelloWorld(in: ctx)

    let verified = LLVMVerifyModule(mod, LLVMReturnStatusAction, nil) == 0

    let cstr = LLVMPrintModuleToString(mod)
    let ir = cstr.map { String(cString: $0) } ?? ""
    LLVMDisposeMessage(cstr)

    return BuiltModule(verified: verified, ir: ir)
}

/// 8.1.5 — lower a `main` from the typed IR (`IRModule`) and emit it as a native object file for
/// the host triple. The first real Nomu-through-LLVM slice. Self-contained: all LLVM_C use stays
/// inside this module, so the driver's LLVM path is a flat `IRModule → String?` surface (nil =
/// success, else an error). Coverage is the 8.1.5 sliver (`IRToLLVM`); 8.2 broadens it.
public func emitObject(_ module: IRModule, to path: String) -> String? {
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
    return emitModuleObject(mod, to: path)
}

/// Emit an already-built, verified module to a native object file for the host triple, via
/// `llvm-c/TargetMachine.h`. Returns nil on success, else an error message.
private func emitModuleObject(_ mod: LLVMModuleRef, to path: String) -> String? {
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
