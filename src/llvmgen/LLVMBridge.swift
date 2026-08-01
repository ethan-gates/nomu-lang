// M8.1 · 8.1.2 — prove Swift can import an LLVM Clang module via cxx-interop against
// @llvm-project. Step 1: does the import resolve at all (module map + headers wired)?
// Builds toward constructing an llvm.Module from Swift.
import LLVM_C  // LLVM's stable C API module (pure C — no C++ interop hazards)

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
