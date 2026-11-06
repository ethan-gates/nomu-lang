// Values too large for registers, passed through explicit pointers.
//
// LLVM demotes a large result by itself, to a hidden pointer it loads the result through. That does not work
// here: statepoint lowering finds the call again by walking back from the result, and loses it when the
// result is several loads; and the hidden pointer is an address into the caller's frame that the frame
// tracking cannot see, so a stack move during the callee would leave it stale. A large argument goes to the
// stack, into the caller's outgoing area, which a function forwarding it must lay out in its own frame, so a
// frame-split wrapper could need a frame over the limit. The pass `nomu-indirect-large-values`, run after
// optimization and before the stack checks are expanded and `rewrite-statepoints-for-gc`, handles both. A
// function returning a large type takes a result pointer as a new first parameter, marked with
// `nomu.frame.addr` so it is tracked, and returns nothing. When a signature's large parameters together pass
// `StackParameterWords`, each becomes a pointer.
//
// A caller passes slots in its frame. The result is written at `ret` and loaded right after the call, and an
// argument is stored right before the call and loaded at the callee's entry, before its stack check, so no
// slot holds a reference at a stop and the collector does not need to see them. The callee never writes an
// argument's slot. A call whose result is returned at once passes its own result pointer along, and a call
// reached with no stop since entry passes on the pointer an argument arrived in, so a wrapper needs no slots.
// That relies on the stack check's slow path never collecting; preemption at the check must revisit it.
//
// The rule depends only on the types, so it needs no agreement beyond that: definitions, declarations from
// other modules, direct and indirect calls and function pointers all follow it.

#include "NomuLLVMPasses.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Casting.h"

using namespace llvm;

namespace nomu {

bool canStop(const CallInst &CI);   // CallBundles.cpp

namespace {

// The registers a result may use: x0–x7, or v0–v7 for floating point. Counting both against one limit sends
// a few results that would fit through memory, and keeps the rule to the type alone.
constexpr uint64_t ReturnRegisters = 8;

// How many words of large parameters a signature keeps on the stack. Below this a stack argument is faster: it
// is copied once, where a pointer adds a load at entry and a store at each call (20 to 40% at 9 words, even at
// about 40, in a recursive call that passes the value on). The limit also bounds what a frame-split wrapper
// lays out, well under the stack reserve.
constexpr uint64_t StackParameterWords = 40;

// The words `T` takes, stopping once past `StackParameterWords`.
uint64_t words(Type *T, const DataLayout &DL) {
  if (!T->isSized())      // void, and an intrinsic's metadata and tokens
    return 0;
  if (auto *S = dyn_cast<StructType>(T)) {
    uint64_t N = 0;
    for (Type *E : S->elements()) {
      N += words(E, DL);
      if (N > StackParameterWords)
        break;
    }
    return N;
  }
  if (auto *A = dyn_cast<ArrayType>(T)) {
    uint64_t E = words(A->getElementType(), DL);
    if (E != 0 && A->getNumElements() > StackParameterWords / E)
      return StackParameterWords + 1;
    return E * A->getNumElements();
  }
  return (DL.getTypeSizeInBits(T).getFixedValue() + 63) / 64;
}

bool isLarge(Type *T, const DataLayout &DL) { return words(T, DL) > ReturnRegisters; }

// Whether `FT`'s large parameters go by pointer: all of them, once together they pass the limit.
bool indirectParameters(FunctionType *FT, const DataLayout &DL) {
  uint64_t N = 0;
  for (Type *P : FT->params())
    if (isLarge(P, DL))
      N += words(P, DL);
  return N > StackParameterWords;
}

bool isIndirect(FunctionType *FT, Type *P, const DataLayout &DL) {
  return isLarge(P, DL) && indirectParameters(FT, DL);
}

bool rewritten(FunctionType *FT, const DataLayout &DL) {
  return isLarge(FT->getReturnType(), DL) || indirectParameters(FT, DL);
}

FunctionType *indirectType(FunctionType *FT, const DataLayout &DL) {
  LLVMContext &C = FT->getContext();
  auto *Ptr = PointerType::get(C, 0);
  bool Result = isLarge(FT->getReturnType(), DL);
  SmallVector<Type *, 8> Params;
  if (Result)
    Params.push_back(Ptr);
  for (Type *P : FT->params())
    Params.push_back(isIndirect(FT, P, DL) ? Ptr : P);
  return FunctionType::get(Result ? Type::getVoidTy(C) : FT->getReturnType(), Params, FT->isVarArg());
}

// `Attrs` for the indirect form: a result pointer is new and a large parameter's attributes no longer apply,
// the result's attributes are gone with it, and the function may now write memory, or read it through a
// parameter, which attributes deduced from the old form may deny.
AttributeList indirectAttributes(AttributeList Attrs, FunctionType *FT, const DataLayout &DL) {
  LLVMContext &C = FT->getContext();
  AttributeSet Fn = Attrs.getFnAttrs().removeAttribute(C, Attribute::Memory).removeAttribute(C, Attribute::Speculatable);
  bool Result = isLarge(FT->getReturnType(), DL);
  SmallVector<AttributeSet, 8> Sets;
  if (Result)
    Sets.push_back(AttributeSet());
  for (unsigned I = 0; I < FT->getNumParams(); ++I)
    Sets.push_back(isIndirect(FT, FT->getParamType(I), DL) ? AttributeSet() : Attrs.getParamAttrs(I));
  return AttributeList::get(C, Fn, Result ? AttributeSet() : Attrs.getRetAttrs(), Sets);
}

Function *frameMarker(Module &M) {
  LLVMContext &C = M.getContext();
  auto *Ptr = PointerType::get(C, 0);
  auto *Marker = cast<Function>(M.getOrInsertFunction("nomu.frame.addr", FunctionType::get(Ptr, {Ptr}, false)).getCallee());
  Marker->addFnAttr("gc-leaf-function");
  Marker->setDoesNotAccessMemory();
  Marker->setDoesNotThrow();
  Marker->setWillReturn();
  return Marker;
}

// What a function in the indirect form knows about its own pointers.
struct Indirect {
  Value *Result = nullptr;                      // the result pointer, marked
  DenseMap<Value *, Argument *> Arrived;        // a large parameter's load at entry -> the pointer it came in
};

// `F` in the indirect form, its body moved over, each large parameter loaded at entry, and every use of it
// replaced. Calls still carry the old function type until `rewriteCalls` reaches them.
Function *indirectFunction(Function *F, Indirect &Info, const DataLayout &DL) {
  FunctionType *Old = F->getFunctionType();
  Function *NF = Function::Create(indirectType(Old, DL), F->getLinkage(), F->getAddressSpace(), "");
  F->getParent()->getFunctionList().insert(F->getIterator(), NF);
  NF->copyAttributesFrom(F);
  NF->setAttributes(indirectAttributes(F->getAttributes(), Old, DL));
  NF->copyMetadata(F, 0);
  NF->takeName(F);
  NF->splice(NF->begin(), F);

  unsigned Shift = isLarge(Old->getReturnType(), DL) ? 1 : 0;
  if (Shift)
    NF->getArg(0)->setName("result");
  IRBuilder<> B(F->getContext());
  if (!NF->isDeclaration())
    B.SetInsertPoint(&NF->getEntryBlock(), NF->getEntryBlock().getFirstInsertionPt());
  for (unsigned I = 0; I < F->arg_size(); ++I) {
    Argument *From = F->getArg(I), *To = NF->getArg(I + Shift);
    To->takeName(From);
    if (!isIndirect(Old, From->getType(), DL)) {
      From->replaceAllUsesWith(To);
    } else if (!NF->isDeclaration()) {
      LoadInst *L = B.CreateAlignedLoad(From->getType(), To, DL.getABITypeAlign(From->getType()), To->getName() + ".value");
      From->replaceAllUsesWith(L);
      Info.Arrived[L] = To;
    }
  }
  F->replaceAllUsesWith(NF);
  F->eraseFromParent();
  return NF;
}

// `P` marked as a possible frame address, once, at the function's entry.
Value *marked(Value *P, Function &F, DenseMap<Value *, Value *> &Marks) {
  if (!F.hasGC())
    return P;
  Value *&M = Marks[P];
  if (!M) {
    Function *Marker = frameMarker(*F.getParent());
    IRBuilder<> B(&F.getEntryBlock(), F.getEntryBlock().getFirstInsertionPt());
    M = B.CreateCall(Marker->getFunctionType(), Marker, {P}, P->getName() + ".addr");
  }
  return M;
}

// Whether the instruction after `CI`, debug records aside, returns its result, its only use.
ReturnInst *returnedAtOnce(CallInst *CI) {
  auto *R = dyn_cast_or_null<ReturnInst>(CI->getNextNode());
  return R && CI->hasOneUse() && R->getReturnValue() == CI ? R : nullptr;
}

// Whether `CI` is in the entry block with nothing before it that can stop.
bool noStopSinceEntry(CallInst *CI) {
  BasicBlock &Entry = CI->getFunction()->getEntryBlock();
  if (CI->getParent() != &Entry)
    return false;
  for (Instruction &I : Entry) {
    if (&I == CI)
      return true;
    if (auto *C = dyn_cast<CallInst>(&I); C && canStop(*C))
      return false;
  }
  return false;
}

// Rewrites `F`'s calls that pass or return a large type.
void rewriteCalls(Function &F, Indirect &Info, DenseMap<Value *, Value *> &Marks, const DataLayout &DL) {
  SmallVector<CallInst *, 8> Calls;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (auto *CI = dyn_cast<CallInst>(&I))
        if (rewritten(CI->getFunctionType(), DL) && !CI->isInlineAsm() && !CI->getIntrinsicID())
          Calls.push_back(CI);

  for (CallInst *CI : Calls) {
    FunctionType *Old = CI->getFunctionType();
    Type *Ty = Old->getReturnType();
    bool LargeResult = isLarge(Ty, DL);
    ReturnInst *Ret = LargeResult && Info.Result ? returnedAtOnce(CI) : nullptr;
    IRBuilder<> Entry(&F.getEntryBlock(), F.getEntryBlock().getFirstInsertionPt());
    IRBuilder<> B(CI);
    IRBuilder<> After(CI->getNextNode());

    auto NewSlot = [&](Type *T) {
      AllocaInst *Slot = Entry.CreateAlloca(T, DL.getAllocaAddrSpace(), nullptr, "value.slot");
      B.CreateLifetimeStart(Slot);
      return Slot;
    };
    SmallVector<Value *, 8> Args;
    AllocaInst *ResultSlot = nullptr;
    if (LargeResult) {
      if (!Ret)
        ResultSlot = NewSlot(Ty);
      Args.push_back(Ret ? Info.Result : ResultSlot);
    }
    SmallVector<AllocaInst *, 2> ArgSlots;
    for (unsigned I = 0; I < CI->arg_size(); ++I) {
      Value *A = CI->getArgOperand(I);
      if (I >= Old->getNumParams() || !isIndirect(Old, A->getType(), DL)) {
        Args.push_back(A);
        continue;
      }
      auto Came = Info.Arrived.find(A);
      if (Came != Info.Arrived.end() && noStopSinceEntry(CI)) {
        Args.push_back(marked(Came->second, F, Marks));
        continue;
      }
      AllocaInst *Slot = NewSlot(A->getType());
      B.CreateAlignedStore(A, Slot, DL.getABITypeAlign(A->getType()));
      ArgSlots.push_back(Slot);
      Args.push_back(Slot);
    }

    SmallVector<OperandBundleDef, 1> Bundles;
    CI->getOperandBundlesAsDefs(Bundles);
    CallInst *New = B.CreateCall(indirectType(Old, DL), CI->getCalledOperand(), Args, Bundles);
    New->setCallingConv(CI->getCallingConv());
    New->setAttributes(indirectAttributes(CI->getAttributes(), Old, DL));
    New->copyMetadata(*CI);
    New->setDebugLoc(CI->getDebugLoc());
    New->setTailCallKind(CallInst::TCK_None);   // the slots are in this frame

    After.SetInsertPoint(New->getNextNode());
    if (!LargeResult) {
      if (!Ty->isVoidTy()) {
        New->takeName(CI);
        CI->replaceAllUsesWith(New);
      }
    } else if (ResultSlot) {
      Value *Loaded = After.CreateLoad(Ty, ResultSlot, CI->getName());
      After.CreateLifetimeEnd(ResultSlot);
      CI->replaceAllUsesWith(Loaded);
    } else {
      IRBuilder<> Back(Ret);
      Back.CreateRetVoid()->setDebugLoc(Ret->getDebugLoc());
      Ret->eraseFromParent();
    }
    for (AllocaInst *Slot : ArgSlots)
      After.CreateLifetimeEnd(Slot);
    CI->eraseFromParent();
  }
}

} // namespace

void indirectLargeValues(Module &M) {
  const DataLayout &DL = M.getDataLayout();
  SmallVector<Function *, 8> Large;
  for (Function &F : M)
    if (!F.isIntrinsic() && rewritten(F.getFunctionType(), DL))
      Large.push_back(&F);

  DenseMap<Function *, Indirect> Info;
  DenseMap<Function *, Value *> Results;
  for (Function *F : Large) {
    bool LargeResult = isLarge(F->getReturnType(), DL);
    Indirect I;
    Function *NF = indirectFunction(F, I, DL);
    if (NF->isDeclaration())
      continue;
    Info[NF] = std::move(I);
    if (LargeResult)
      Results[NF] = NF->getArg(0);
  }

  for (Function &F : M) {
    if (F.isDeclaration())
      continue;
    DenseMap<Value *, Value *> Marks;
    Indirect &I = Info[&F];
    if (auto It = Results.find(&F); It != Results.end())
      I.Result = marked(It->second, F, Marks);
    rewriteCalls(F, I, Marks, DL);
    for (auto &[L, Arg] : I.Arrived)
      if (L->use_empty())
        cast<Instruction>(L)->eraseFromParent();
  }

  for (auto &[F, Result] : Results) {
    Value *Out = Info[F].Result;
    for (BasicBlock &BB : *F)
      if (auto *R = dyn_cast<ReturnInst>(BB.getTerminator()); R && R->getReturnValue()) {
        Value *V = R->getReturnValue();
        IRBuilder<> B(R);
        B.CreateAlignedStore(V, Out, DL.getABITypeAlign(V->getType()));
        B.CreateRetVoid()->setDebugLoc(R->getDebugLoc());
        R->eraseFromParent();
      }
  }
}

} // namespace nomu
