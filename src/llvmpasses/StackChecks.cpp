// The function-entry stack check, expanded after optimization.
//
// Codegen emits each checked function's check as a placeholder at its entry: a call to `nomu.stack.check`
// whose argument is the slow path (`__nomu_stack_slow`), whose `deopt` bundle names the shaped values live at
// entry, and whose `!nomu.stack.owner` metadata names the function it belongs to. The placeholder touches
// only memory the program cannot see, so it blocks no optimization of the program's own memory. Inlining
// copies a callee's placeholder into its caller, where it would test a frame that no longer exists, inside
// the caller's loops. Those copies are deleted right after each round of inlining (`dropInlinedStackChecks`,
// at the optimizer's peephole extension point); the pass `nomu-expand-stack-checks`, run after optimization
// and before `rewrite-statepoints-for-gc`, deletes any left and expands each function's own: the SP compared with the running fiber's stack limit, read through x28, and the slow path
// called when it is below. A placeholder that tail-call elimination moved into a loop goes back to the
// entry when it records no values. Design: `design/plans/tasks/104-fiber-stack-strategy.md`, "Decided: the
// entry check".

#include "NomuLLVMPasses.h"

#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Constants.h"
#include "llvm-c/Core.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

using namespace llvm;

namespace nomu {

namespace {

// The running fiber's stack limit: the fiber record's offset 304 (`runtime/scheduler.nomu`), the fiber in x28.
constexpr uint64_t LimitOffset = 304;

Value *readRegister(IRBuilder<> &B, StringRef Name) {
  LLVMContext &C = B.getContext();
  Metadata *Reg = MDNode::get(C, MDString::get(C, Name));
  return B.CreateIntrinsic(Intrinsic::read_register, {B.getInt64Ty()}, {MetadataAsValue::get(C, Reg)});
}

// The function a placeholder belongs to, from its `!nomu.stack.owner` metadata.
Function *owner(CallInst *CI) {
  MDNode *N = CI->getMetadata("nomu.stack.owner");
  if (!N || N->getNumOperands() != 1)
    return nullptr;
  if (auto *V = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get()))
    return dyn_cast<Function>(V->getValue());
  return nullptr;
}

// Whether `I` may call code that uses stack: any call but debug and lifetime markers, the placeholder itself,
// and the frame-address markers (identities). Intrinsics count, since some lower to library calls.
bool usesStack(const Instruction &I) {
  auto *CB = dyn_cast<CallBase>(&I);
  if (!CB || isa<DbgInfoIntrinsic>(CB) || CB->isLifetimeStartOrEnd())
    return false;
  if (const Function *Callee = CB->getCalledFunction()) {
    StringRef Name = Callee->getName();
    if (Name == "nomu.stack.check" || Name == "nomu.frame.addr" || Name == "nomu.raw.interior" || Name == "llvm.read_register.i64")
      return false;
  }
  return true;
}

// Where the check goes: before the function's first call on every path, since the reserve already holds
// the function's own frame and the check only has to precede what it calls. That is the nearest common
// dominator of its calls (before the first call there, else at its end), moved out of any loop to the
// loop's preheader. Paths that call nothing pass no check, so LLVM's shrink-wrapping keeps them free of the
// prologue too. Returns null when the function calls nothing (it needs no check). A placeholder whose
// recorded values do not all dominate that point stays where it is.
Instruction *placement(CallInst *CI, DominatorTree &DT, LoopInfo &LI) {
  Function &F = *CI->getFunction();
  BasicBlock *Common = nullptr;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (usesStack(I)) {
        Common = Common ? DT.findNearestCommonDominator(Common, &BB) : &BB;
        break;
      }
  if (!Common)
    return nullptr;
  bool Hoisted = false;
  while (Loop *L = LI.getLoopFor(Common)) {
    BasicBlock *Pre = L->getLoopPreheader();
    Common = Pre ? Pre : DT.getNode(L->getHeader())->getIDom()->getBlock();
    Hoisted = true;
  }
  Instruction *At = Common->getTerminator();
  if (!Hoisted)
    for (Instruction &I : *Common)
      if (usesStack(I)) {
        At = &I;
        break;
      }
  for (const Use &Op : CI->operands())
    if (auto *Def = dyn_cast<Instruction>(Op.get()); Def && !DT.dominates(Def, At))
      return CI;
  return At;
}

// The room a check needs below its SP beyond the reserve: a wrapper's `!nomu.stack.need` (the frame of the
// function it calls, `nomuSplitLargeFrame`), else 0.
uint64_t need(CallInst *CI) {
  if (MDNode *N = CI->getMetadata("nomu.stack.need"))
    if (N->getNumOperands() == 1)
      if (auto *C = mdconst::dyn_extract<ConstantInt>(N->getOperand(0)))
        return C->getZExtValue();
  return 0;
}

void expand(CallInst *CI) {
  auto *Slow = cast<Function>(CI->getArgOperand(0));
  IRBuilder<> B(CI);
  Value *Fiber = B.CreateIntToPtr(readRegister(B, "x28"), B.getPtrTy(), "stk.fiber");
  Value *Limit = B.CreateLoad(B.getInt64Ty(), B.CreateConstGEP1_64(B.getInt8Ty(), Fiber, LimitOffset),
                              "stk.limit");
  Value *Need = B.getInt64(need(CI));
  Value *SP = readRegister(B, "sp");
  if (need(CI) != 0)
    SP = B.CreateSub(SP, Need, "stk.below");
  Value *Short = B.CreateICmpULT(SP, Limit, "stk.short");
  MDNode *Unlikely = MDBuilder(CI->getContext()).createUnlikelyBranchWeights();
  Instruction *Then = SplitBlockAndInsertIfThen(Short, CI, /*Unreachable=*/false, Unlikely);
  B.SetInsertPoint(Then);
  SmallVector<OperandBundleDef, 1> Bundles;
  CI->getOperandBundlesAsDefs(Bundles);
  CallInst *Call = B.CreateCall(Slow->getFunctionType(), Slow, {Need}, Bundles);
  Call->setCallingConv(Slow->getCallingConv());
  Call->setDebugLoc(CI->getDebugLoc());
  CI->eraseFromParent();
}

} // namespace

// Deletes the placeholders inlining copied into `F` (those another function owns). Run right after each
// round of inlining, before the loop passes, so no copy sits in a loop while the optimizer works on it.
bool dropInlinedStackChecks(Function &F) {
  bool Changed = false;
  for (BasicBlock &BB : F)
    for (Instruction &I : make_early_inc_range(BB))
      if (auto *CI = dyn_cast<CallInst>(&I))
        if (Function *Callee = CI->getCalledFunction();
            Callee && Callee->getName() == "nomu.stack.check" && owner(CI) != &F) {
          CI->eraseFromParent();
          Changed = true;
        }
  return Changed;
}

// Expands every stack check in `M`. Returns false, with a message on stderr, when a checked function lost
// its own placeholder (an optimization that copies a function's body would leave the copy unchecked).
bool expandStackChecks(Module &M) {
  Function *Placeholder = M.getFunction("nomu.stack.check");
  if (!Placeholder)
    return true;
  // Each function keeps one placeholder it owns: the one in its entry block if any (recursive inlining can
  // copy a function's own placeholder into itself), else the first.
  DenseMap<Function *, CallInst *> Own;
  SmallVector<CallInst *, 16> All;
  for (Use &U : Placeholder->uses())
    All.push_back(cast<CallInst>(U.getUser()));
  for (CallInst *CI : All) {
    Function *F = CI->getFunction();
    if (owner(CI) != F)
      continue;
    auto It = Own.find(F);
    if (It == Own.end() || (CI->getParent() == &F->getEntryBlock() && It->second->getParent() != &F->getEntryBlock()))
      Own[F] = CI;
  }
  for (CallInst *CI : All) {
    auto It = Own.find(CI->getFunction());
    if (It == Own.end() || It->second != CI)
      CI->eraseFromParent();
  }
  bool Ok = true;
  for (Function &F : M)
    if (!F.isDeclaration() && F.hasFnAttribute("nomu-stack-check") && !Own.count(&F)) {
      errs() << "internal: function '" << F.getName() << "' lost its stack check\n";
      Ok = false;
    }
  for (auto &[F, CI] : Own) {
    DominatorTree DT(*F);
    LoopInfo LI(DT);
    Instruction *At = placement(CI, DT, LI);
    if (!At) {
      CI->eraseFromParent();
      continue;
    }
    if (At != CI)
      CI->moveBefore(At->getIterator());
    expand(CI);
  }
  if (Placeholder->use_empty())
    Placeholder->eraseFromParent();
  return Ok;
}

} // namespace nomu

// `nomu.stack.check` touches only memory the program cannot see, never throws and always returns: the
// optimizer keeps it and moves the program's memory operations freely around it.
extern "C" void nomuMarkStackCheckPlaceholder(LLVMValueRef Fn) {
  auto *F = cast<Function>(unwrap(Fn));
  F->setOnlyAccessesInaccessibleMemory();
  F->setDoesNotThrow();
  F->setWillReturn();
}

// A function whose frame is larger than the stack reserve holds cannot check after its prologue: the frame is
// already laid out, and may lie past the stack's end. It is split instead: its code moves to an unchecked
// body (`<name>.frame`, internal, never inlined, attribute `nomu-frame-covered` = `need`), and the function
// becomes a wrapper with the same signature whose stack check also asks for `need` bytes below its SP
// (`!nomu.stack.need`) before calling the body, so the body's frame always fits. The wrapper is never inlined
// either: its check would go with it. Arguments the body marks as possible frame addresses
// (`nomu.frame.addr`) are marked in the wrapper too, so a stack move at its check adjusts them. Design:
// `design/plans/tasks/104-fiber-stack-strategy.md`, 104.3.8.
extern "C" LLVMValueRef nomuSplitLargeFrame(LLVMValueRef Fn, uint64_t Need) {
  auto *F = cast<Function>(unwrap(Fn));
  Module &M = *F->getParent();
  LLVMContext &C = F->getContext();
  // Not internal: the optimizer rewrites an internal function's signature, and the wrapper would then rebuild
  // the value in a frame of its own. Weak, for a specialization several modules emit, and hidden, since only
  // the wrapper calls it.
  auto Linkage = F->isWeakForLinker() ? F->getLinkage() : GlobalValue::WeakODRLinkage;
  Function *Body = Function::Create(F->getFunctionType(), Linkage, F->getName() + ".frame", &M);
  Body->copyAttributesFrom(F);
  Body->setLinkage(Linkage);
  Body->setVisibility(GlobalValue::HiddenVisibility);
  Body->removeFnAttr("warn-stack-size");
  Body->removeFnAttr("nomu-stack-check");
  Body->removeFnAttr(Attribute::AlwaysInline);
  Body->addFnAttr(Attribute::NoInline);
  Body->addFnAttr("nomu-frame-covered", std::to_string(Need));
  Body->setSubprogram(F->getSubprogram());
  F->setSubprogram(nullptr);
  Body->splice(Body->begin(), F);
  for (unsigned I = 0; I < F->arg_size(); ++I) {
    Body->getArg(I)->takeName(F->getArg(I));
    F->getArg(I)->replaceAllUsesWith(Body->getArg(I));
  }

  // The body's own check placeholder still names the function as its owner; the wrapper takes its slow path.
  CallInst *Check = nullptr;
  SmallVector<bool, 8> Marked(F->arg_size(), false);
  Function *Marker = M.getFunction("nomu.frame.addr");
  for (BasicBlock &BB : *Body)
    for (Instruction &I : make_early_inc_range(BB))
      if (auto *CI = dyn_cast<CallInst>(&I)) {
        Function *Callee = CI->getCalledFunction();
        if (Callee && Callee->getName() == "nomu.stack.check") {
          if (!Check)
            Check = CI;
        } else if (Callee && Callee == Marker) {
          if (auto *A = dyn_cast<Argument>(CI->getArgOperand(0)))
            Marked[A->getArgNo()] = true;
        }
      }

  F->removeFnAttr(Attribute::AlwaysInline);
  F->addFnAttr(Attribute::NoInline);
  BasicBlock *Entry = BasicBlock::Create(C, "entry", F);
  IRBuilder<> B(Entry);
  SmallVector<Value *, 8> Args;
  for (unsigned I = 0; I < F->arg_size(); ++I) {
    Value *A = F->getArg(I);
    if (Marked[I])
      A = B.CreateCall(Marker->getFunctionType(), Marker, {A}, "frame.addr");
    Args.push_back(A);
  }
  if (Check) {
    CallInst *W = B.CreateCall(Check->getFunctionType(), Check->getCalledOperand(), {Check->getArgOperand(0)});
    W->setAttributes(Check->getAttributes());
    W->setMetadata("nomu.stack.owner", MDNode::get(C, ValueAsMetadata::get(F)));
    W->setMetadata("nomu.stack.need",
                   MDNode::get(C, ConstantAsMetadata::get(ConstantInt::get(Type::getInt64Ty(C), Need))));
    Check->eraseFromParent();
  }
  CallInst *Call = B.CreateCall(F->getFunctionType(), Body, Args);
  Call->setCallingConv(Body->getCallingConv());
  AttributeList FA = F->getAttributes();
  SmallVector<AttributeSet, 8> ParamAttrs;
  for (unsigned I = 0; I < F->arg_size(); ++I)
    ParamAttrs.push_back(FA.getParamAttrs(I));
  Call->setAttributes(AttributeList::get(C, AttributeSet(), FA.getRetAttrs(), ParamAttrs));
  if (F->getReturnType()->isVoidTy())
    B.CreateRetVoid();
  else
    B.CreateRet(Call);
  return wrap(Body);
}
