// M8.1 · 8.1.2 — run the LLVM-C interop proof end to end (compile + link + run).
// M8.1 · 8.1.3 — build `fun main { print(2 + 3) }` as LLVM IR via the C API, verify it, and
// print the module so the artifact is inspectable ahead of object emission (8.1.4).
import LLVMBridge

print("llvm-c interop ok: \(llvmInteropOK())")

let m = buildHelloWorldModule()
print("hello-world module verified: \(m.verified)")
print("--- IR ---")
print(m.ir, terminator: "")
