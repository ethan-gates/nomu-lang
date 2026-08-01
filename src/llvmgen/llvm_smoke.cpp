// M8.1 · 8.1.1 smoke test: prove we can drive LLVM's C++ API through the Bazel overlay.
// Builds a trivial module with a function `answer() -> i64 { ret 42 }` and prints its IR.
// Throwaway — deleted once the real backend path (via swift-llvm-bindings) works.
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>

int main() {
  llvm::LLVMContext ctx;
  auto mod = std::make_unique<llvm::Module>("nomu_smoke", ctx);

  auto *i64 = llvm::Type::getInt64Ty(ctx);
  auto *fnTy = llvm::FunctionType::get(i64, /*isVarArg=*/false);
  auto *fn = llvm::Function::Create(fnTy, llvm::Function::ExternalLinkage,
                                    "answer", mod.get());

  llvm::IRBuilder<> b(llvm::BasicBlock::Create(ctx, "entry", fn));
  b.CreateRet(llvm::ConstantInt::get(i64, 42));

  if (llvm::verifyModule(*mod, &llvm::errs()))
    return 1;

  mod->print(llvm::outs(), nullptr);
  return 0;
}
