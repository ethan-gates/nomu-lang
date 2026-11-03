// Tracking possibly-stack addresses: pointers that may point into a caller's frame become tracked values,
// so the statepoint rewrite records them at every stop and the stack copier can adjust them.
//
// A pointer a function receives (a `mutating` method's `self`, an erased generic's argument and result
// buffers, a saved shadow-stack top) may point into a caller's frame, which a stack move relocates. The
// function cannot recompute it, so it must be held where the runtime can find and fix it: a recorded slot.
// Codegen marks each such pointer where it enters with a call to `nomu.frame.addr`, an identity the
// optimizer cannot see through. This transform, the pass `nomu-track-frame-addresses`, runs after
// optimization and before `rewrite-statepoints-for-gc`: each marker becomes an identity inline asm producing an `addrspace(1)`
// value, its derived pointers (GEPs, PHIs, selects) are rebuilt in `addrspace(1)`, and every other use
// reads an `addrspacecast` back placed right before it. The rewrite then spills and reloads these values at
// stops like heap references; the collector skips the ones that are not managed objects
// (`rtKeepManagedSlots`), and the copier adjusts the ones in the moved stack.
// Design: `design/internals/frames-designs.md`, candidate 1, and the frame contract's R5 (S2 values).

#include "NomuLLVMPasses.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/StandardInstrumentations.h"
#include "llvm/Support/Error.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm-c/Error.h"
#include "llvm-c/TargetMachine.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>

using namespace llvm;

namespace {

constexpr unsigned Tracked = 1;

// `asm "", "=r,0"(ptr %p)`: the same bits, as a tracked pointer the optimizer cannot relate to %p.
Value *track(IRBuilder<> &B, Value *P) {
  auto *Ty = FunctionType::get(PointerType::get(B.getContext(), Tracked), {P->getType()}, false);
  auto *Asm = InlineAsm::get(Ty, "", "=r,0", /*hasSideEffects=*/false);
  CallInst *CI = B.CreateCall(Ty, Asm, {P}, P->getName() + ".tracked");
  CI->addFnAttr(Attribute::get(B.getContext(), "gc-leaf-function"));   // an identity, never a stop
  return CI;
}

// Whether `U` derives a pointer from operand `Op` that should stay tracked: the base of a GEP, an incoming
// value of a PHI, or an arm of a select.
bool derives(const User *U, unsigned Op) {
  if (auto *G = dyn_cast<GetElementPtrInst>(U))
    return Op == G->getPointerOperandIndex();
  if (isa<PHINode>(U))
    return U->getType()->isPointerTy();
  if (auto *S = dyn_cast<SelectInst>(U))
    return Op != 0 && S->getType()->isPointerTy();
  return false;
}

void trackFunction(Function &F, Function *Marker, unsigned &Markers, unsigned &Derived) {
  // The marked values and everything derived from them, in discovery order.
  SetVector<Instruction *> Set;
  for (Use &U : Marker->uses())
    if (auto *CI = dyn_cast<CallInst>(U.getUser()))
      if (CI->getFunction() == &F && CI->getCalledFunction() == Marker)
        Set.insert(CI);
  if (Set.empty())
    return;
  for (size_t I = 0; I < Set.size(); ++I)
    for (Use &U : Set[I]->uses())
      if (derives(U.getUser(), U.getOperandNo()))
        Set.insert(cast<Instruction>(U.getUser()));

  // A tracked counterpart for each, operands filled in after all exist (PHIs can form cycles).
  DenseMap<Value *, Value *> Counterpart;
  IRBuilder<> B(F.getContext());
  for (Instruction *I : Set) {
    if (auto *CI = dyn_cast<CallInst>(I)) {
      B.SetInsertPoint(CI);
      Counterpart[CI] = track(B, CI->getArgOperand(0));
      ++Markers;
    } else if (auto *P = dyn_cast<PHINode>(I)) {
      B.SetInsertPoint(P);
      Counterpart[P] = B.CreatePHI(PointerType::get(F.getContext(), Tracked), P->getNumIncomingValues(),
                                   P->getName() + ".tracked");
      ++Derived;
    } else if (auto *G = dyn_cast<GetElementPtrInst>(I)) {
      B.SetInsertPoint(G);
      SmallVector<Value *, 4> Idx(G->indices());
      // The base is filled in below; a placeholder keeps the builder from folding.
      auto *NG = GetElementPtrInst::Create(G->getSourceElementType(),
                                           PoisonValue::get(PointerType::get(F.getContext(), Tracked)), Idx,
                                           G->getName() + ".tracked", G->getIterator());
      NG->setNoWrapFlags(G->getNoWrapFlags());
      Counterpart[G] = NG;
      ++Derived;
    } else if (auto *S = dyn_cast<SelectInst>(I)) {
      auto *Poison = PoisonValue::get(PointerType::get(F.getContext(), Tracked));
      Counterpart[S] = SelectInst::Create(S->getCondition(), Poison, Poison, S->getName() + ".tracked",
                                          S->getIterator());
      ++Derived;
    }
  }
  // An operand outside the set (an untracked pointer merged with a tracked one) is tracked where it is
  // used: at the end of the incoming block for a PHI, before the instruction otherwise.
  auto tracked = [&](Value *V, Instruction *At) -> Value * {
    if (auto It = Counterpart.find(V); It != Counterpart.end())
      return It->second;
    B.SetInsertPoint(At);
    return track(B, V);
  };
  for (Instruction *I : Set) {
    if (auto *P = dyn_cast<PHINode>(I)) {
      auto *NP = cast<PHINode>(Counterpart[P]);
      for (unsigned K = 0; K < P->getNumIncomingValues(); ++K) {
        BasicBlock *In = P->getIncomingBlock(K);
        NP->addIncoming(tracked(P->getIncomingValue(K), In->getTerminator()), In);
      }
    } else if (auto *G = dyn_cast<GetElementPtrInst>(I)) {
      cast<GetElementPtrInst>(Counterpart[G])->setOperand(0, tracked(G->getPointerOperand(), G));
    } else if (auto *S = dyn_cast<SelectInst>(I)) {
      auto *NS = cast<SelectInst>(Counterpart[S]);
      NS->setOperand(1, tracked(S->getTrueValue(), S));
      NS->setOperand(2, tracked(S->getFalseValue(), S));
    }
  }
  // Every other use reads the tracked value back, converted right before it (for a PHI, at the end of the
  // incoming block), so no untracked copy is live across a stop.
  for (Instruction *I : Set) {
    SmallVector<Use *, 8> Uses;
    for (Use &U : I->uses())
      if (!Set.count(dyn_cast<Instruction>(U.getUser())))
        Uses.push_back(&U);
    for (Use *U : Uses) {
      auto *User = cast<Instruction>(U->getUser());
      Instruction *At = User;
      if (auto *P = dyn_cast<PHINode>(User))
        At = P->getIncomingBlock(*U)->getTerminator();
      B.SetInsertPoint(At);
      U->set(B.CreateAddrSpaceCast(Counterpart[I], I->getType(), I->getName() + ".raw"));
    }
  }
  for (Instruction *I : Set)
    I->dropAllReferences();
  for (Instruction *I : Set)
    I->eraseFromParent();
}

// The transform over a module; `Enabled` false drops the markers instead (measurement only,
// `measure.no_frame_split`), leaving the pointers untracked. Returns false when the result fails verification.
bool trackModule(Module &M, bool Enabled) {
  Function *Marker = M.getFunction("nomu.frame.addr");
  if (!Marker)
    return true;
  if (!Enabled) {
    for (Use &U : make_early_inc_range(Marker->uses())) {
      auto *CI = cast<CallInst>(U.getUser());
      CI->replaceAllUsesWith(CI->getArgOperand(0));
      CI->eraseFromParent();
    }
    Marker->eraseFromParent();
    return true;
  }
  unsigned Markers = 0, Derived = 0;
  for (Function &F : M)
    if (!F.isDeclaration())
      trackFunction(F, Marker, Markers, Derived);
  if (Marker->use_empty())
    Marker->eraseFromParent();
  if (std::getenv("NOMU_FRAME_SPLIT_STATS"))
    errs() << "frame-track " << M.getName() << ": " << Markers << " marked, " << Derived << " derived\n";
  return !verifyModule(M, &errs());
}

// The new-PM pass, named in a pipeline as `nomu-track-frame-addresses` (or `nomu-drop-frame-addresses`).
// A verification failure is reported through `Failed`, which the runner turns into an error.
struct TrackFrameAddressesPass : PassInfoMixin<TrackFrameAddressesPass> {
  bool Enabled;
  bool *Failed;
  TrackFrameAddressesPass(bool Enabled, bool *Failed) : Enabled(Enabled), Failed(Failed) {}
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
    if (!trackModule(M, Enabled))
      *Failed = true;
    return PreservedAnalyses::none();
  }
};

} // namespace

// LLVMRunPasses, with Nomu's passes registered by name (the C API cannot register a pass), and the same
// defaults as `LLVMCreatePassBuilderOptions` gives.
extern "C" LLVMErrorRef nomuRunPasses(LLVMModuleRef ModRef, const char *Pipeline, LLVMTargetMachineRef TMRef) {
  Module &M = *unwrap(ModRef);
  TargetMachine *TM = reinterpret_cast<TargetMachine *>(TMRef);
  bool Failed = false;

  PassInstrumentationCallbacks PIC;
  PassBuilder PB(TM, PipelineTuningOptions(), std::nullopt, &PIC);
  PB.registerPipelineParsingCallback(
      [&Failed](StringRef Name, ModulePassManager &MPM, ArrayRef<PassBuilder::PipelineElement>) {
        if (Name == "nomu-track-frame-addresses" || Name == "nomu-drop-frame-addresses") {
          MPM.addPass(TrackFrameAddressesPass(Name == "nomu-track-frame-addresses", &Failed));
          return true;
        }
        return false;
      });
  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  PB.registerLoopAnalyses(LAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerModuleAnalyses(MAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
  StandardInstrumentations SI(M.getContext(), /*DebugLogging=*/false, /*VerifyEach=*/false);
  SI.registerCallbacks(PIC, &MAM);

  ModulePassManager MPM;
  if (auto Err = PB.parsePassPipeline(MPM, Pipeline))
    return wrap(std::move(Err));
  MPM.run(M, MAM);
  if (Failed)
    return wrap(make_error<StringError>("frame-address tracking produced invalid IR", inconvertibleErrorCode()));
  return LLVMErrorSuccess;
}
