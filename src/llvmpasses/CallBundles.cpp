// An empty `deopt` bundle on every call that can stop, so roots recorded on a call survive inlining.
//
// A shaped value's home is recorded in the `deopt` bundle of each call it is live across
// (`design/internals/shaped-roots.md`). When such a call is inlined, its record must reach every stop in the
// inlined body, and LLVM's inliner merges a bundle only into inner calls that already have one. The pass
// `nomu-bundle-calls`, run before any inlining, gives the other calls an empty bundle to merge into; it
// lowers to nothing. A bundle stops tail recursion elimination, so release runs that first.

#include "NomuLLVMPasses.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"

using namespace llvm;

namespace nomu {

// Whether `CI` can stop: a call that is no inline asm, intrinsic, GC leaf or compiler marker.
bool canStop(const CallInst &CI) {
  if (CI.isInlineAsm() || CI.getIntrinsicID() || CI.hasFnAttr("gc-leaf-function"))
    return false;
  const Function *Callee = CI.getCalledFunction();
  return !Callee || !(Callee->hasFnAttribute("gc-leaf-function") || Callee->getName().starts_with("nomu."));
}

bool bundleCalls(Module &M) {
  bool Changed = false;
  for (Function &F : M) {
    if (F.isDeclaration() || !F.hasGC())
      continue;
    SmallVector<CallInst *, 16> Calls;
    for (BasicBlock &BB : F)
      for (Instruction &I : BB)
        if (auto *CI = dyn_cast<CallInst>(&I); CI && !CI->hasOperandBundles() && canStop(*CI))
          Calls.push_back(CI);
    for (CallInst *CI : Calls) {
      OperandBundleDef Empty("deopt", ArrayRef<Value *>{});
      CallInst *New = CallInst::Create(CI, {Empty}, CI->getIterator());
      New->copyMetadata(*CI);
      New->takeName(CI);
      CI->replaceAllUsesWith(New);
      CI->eraseFromParent();
      Changed = true;
    }
  }
  return Changed;
}

} // namespace nomu
