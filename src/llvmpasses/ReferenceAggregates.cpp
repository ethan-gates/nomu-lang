// References held in first-class aggregates across stops.
//
// `rewrite-statepoints-for-gc` tracks pointers. An aggregate holding a reference, live across a stop, is skipped
// without a word (the check is an assert), so a moving collection leaves the reference stale. The optimizer makes
// such values: it sinks an `extractvalue` past a call, and a parameter or a call's result may be read long after
// it arrives. The pass `nomu-split-reference-aggregates`, run last before the rewrite, reads each reference out
// as a pointer where the aggregate is defined. A use a stop may separate from the definition takes the pointer,
// or the aggregate rebuilt with it right before that use. Other fields stay in the aggregate, where a stale
// reference does no harm because every use replaces it.

#include "NomuLLVMPasses.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"

using namespace llvm;

namespace nomu {

bool canStop(const CallInst &CI);   // CallBundles.cpp

namespace {

constexpr unsigned Managed = 1;

using Path = SmallVector<unsigned, 4>;

// The index paths of the references in `T`.
void references(Type *T, Path &At, SmallVectorImpl<Path> &Out) {
  if (auto *P = dyn_cast<PointerType>(T)) {
    if (P->getAddressSpace() == Managed)
      Out.push_back(At);
  } else if (auto *S = dyn_cast<StructType>(T)) {
    for (unsigned I = 0; I < S->getNumElements(); ++I) {
      At.push_back(I);
      references(S->getElementType(I), At, Out);
      At.pop_back();
    }
  } else if (auto *A = dyn_cast<ArrayType>(T)) {
    for (unsigned I = 0; I < A->getNumElements(); ++I) {
      At.push_back(I);
      references(A->getElementType(), At, Out);
      At.pop_back();
    }
  }
}

bool isStop(const Instruction &I) {
  auto *CI = dyn_cast<CallInst>(&I);
  return CI && canStop(*CI);
}

// Where a use reads its operand: before the user, or at the end of the incoming block for a PHI.
Instruction *useSite(Use &U) {
  auto *User = cast<Instruction>(U.getUser());
  if (auto *P = dyn_cast<PHINode>(User))
    return P->getIncomingBlock(U)->getTerminator();
  return User;
}

// Whether no stop can come between `Def` and the use at `Site`: both in one block, nothing that stops between.
bool sameStretch(Value *Def, Instruction *Site) {
  auto *I = dyn_cast<Instruction>(Def);
  if (!I || I->getParent() != Site->getParent() || isa<PHINode>(I))
    return false;
  for (Instruction *At = I->getNextNode(); At != Site; At = At->getNextNode())
    if (!At || isStop(*At))
      return false;
  return true;
}

// Splits `V`, whose references are at `Refs`. Returns whether anything changed.
bool split(Value *V, ArrayRef<Path> Refs, IRBuilder<> &B, BasicBlock::iterator After) {
  SmallVector<Use *, 8> Uses;
  for (Use &U : V->uses())
    if (!sameStretch(V, useSite(U)))
      Uses.push_back(&U);
  if (Uses.empty())
    return false;

  B.SetInsertPoint(After->getParent(), After);
  SmallVector<Value *, 4> Pointers;
  for (const Path &P : Refs)
    Pointers.push_back(B.CreateExtractValue(V, P, V->getName() + ".ref"));

  for (Use *U : Uses) {
    if (auto *E = dyn_cast<ExtractValueInst>(U->getUser())) {
      ArrayRef<unsigned> Idx = E->getIndices();
      auto Hit = llvm::find_if(Refs, [&](const Path &P) { return ArrayRef<unsigned>(P) == Idx; });
      if (Hit != Refs.end()) {
        E->replaceAllUsesWith(Pointers[Hit - Refs.begin()]);
        E->eraseFromParent();
        continue;
      }
      if (!E->getType()->isAggregateType())
        continue;   // a field that holds no reference
    }
    B.SetInsertPoint(useSite(*U));
    Value *Rebuilt = V;
    for (size_t I = 0; I < Refs.size(); ++I)
      Rebuilt = B.CreateInsertValue(Rebuilt, Pointers[I], Refs[I]);
    U->set(Rebuilt);
  }
  return true;
}

} // namespace

bool splitReferenceAggregates(Module &M) {
  bool Changed = false;
  IRBuilder<> B(M.getContext());
  for (Function &F : M) {
    if (F.isDeclaration() || !F.hasGC())
      continue;
    SmallVector<std::pair<Value *, SmallVector<Path, 2>>, 16> Work;
    auto Consider = [&](Value *V) {
      if (!V->getType()->isAggregateType() || V->use_empty())
        return;
      SmallVector<Path, 2> Refs;
      Path At;
      references(V->getType(), At, Refs);
      if (!Refs.empty())
        Work.emplace_back(V, std::move(Refs));
    };
    for (Argument &A : F.args())
      Consider(&A);
    for (BasicBlock &BB : F)
      for (Instruction &I : BB)
        Consider(&I);

    for (auto &[V, Refs] : Work) {
      BasicBlock::iterator After;
      if (auto *I = dyn_cast<Instruction>(V))
        After = *I->getInsertionPointAfterDef();
      else
        After = F.getEntryBlock().getFirstInsertionPt();
      Changed |= split(V, Refs, B, After);
    }
  }
  return Changed;
}

} // namespace nomu
