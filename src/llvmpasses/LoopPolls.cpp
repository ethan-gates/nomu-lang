// The loop-header safepoint poll, expanded after optimization.
//
// Codegen emits each loop header's poll as a placeholder: a call to `nomu.loop.poll(slow, offFiber)` that touches
// only memory the program cannot see, with a `deopt` bundle naming the shaped values live at the header
// (empty when none, so the inliner merges a caller's recorded values into it). The optimizer therefore keeps
// the poll in its loop and moves the program's loads and stores around it: an array's count or buffer pointer
// is hoisted out of the loop rather than reloaded after every poll. That is sound because the poll stops only
// for the collector, which moves objects and rewrites shaped frame words: every managed value live across the
// expanded poll is relocated by `rewrite-statepoints-for-gc`, and frame words the collector rewrites are read
// volatile (`loadReloading`); another fiber changes this fiber's memory only through atomics, actors and
// channels, which the optimizer does not move. The pass `nomu-expand-loop-polls`, run after optimization and
// before the statepoint rewrite, turns each placeholder into the poll itself: the running fiber's stack limit,
// read through x28, compared with all ones, and when raised there a call to the slow path carrying the
// placeholder's bundle. A request to stop raises the limit to all ones (task 236.3, the request word in
// `runtime/scheduler.nomu`), so one word serves the poll and the function-entry check; a loop needs no SP test,
// since a stack overflows only at an entry. A poll whose `offFiber` is set (the
// runtime package's, whose code also runs with no fiber, x28 0) tests x28 first.
//
// A call in a loop still keeps the vectorizer and the loop idioms away, so `nomu-strip-mine-loops`, run just
// before the vectorizer, moves the poll out of each innermost loop whose only stop it is: the loop runs in
// chunks of up to K iterations, an inner loop with no call, and an outer loop that polls between chunks.
// Design: `design/plans/tasks/245-loop-strip-mining.md`.
//
// Polls that bound nothing go: strip mining first deletes those the optimizer left outside every cycle, and the
// expansion deletes a loop header's poll when another poll the loop keeps runs on every iteration.

#include "NomuLLVMPasses.h"

#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"

using namespace llvm;

namespace nomu {

namespace {

// The running fiber's stack limit: the fiber record's offset 40 (`runtime/scheduler.nomu`), the fiber in x28.
constexpr uint64_t LimitOffset = 40;

Value *readRegister(IRBuilder<> &B, StringRef Name) {
  LLVMContext &C = B.getContext();
  Metadata *Reg = MDNode::get(C, MDString::get(C, Name));
  return B.CreateIntrinsic(Intrinsic::read_register, {B.getInt64Ty()}, {MetadataAsValue::get(C, Reg)});
}

bool isLoopPoll(const Instruction &I) {
  auto *CI = dyn_cast<CallInst>(&I);
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "nomu.loop.poll";
}

// Deletes each loop header's poll that another poll in the loop makes redundant: one that dominates every latch,
// so every iteration that goes around passes it. A strip-mined inner loop's poll does this for its outer loop
// (it runs at each entry to the inner loop). Loops go innermost first and a poll that was deleted counts for
// nothing, so the poll an outer loop relies on is one that stays.
void dropDominatedHeaderPolls(Function &F) {
  DominatorTree DT(F);
  LoopInfo LI(DT);
  SmallPtrSet<Instruction *, 8> Dead;
  SmallVector<Loop *, 8> Loops = LI.getLoopsInPreorder();
  for (Loop *L : reverse(Loops)) {
    BasicBlock *H = L->getHeader();
    Instruction *P = nullptr;
    for (Instruction &I : *H)
      if (isLoopPoll(I) && !Dead.contains(&I))
        P = &I;
    if (!P)
      continue;
    SmallVector<BasicBlock *, 4> Latches;
    L->getLoopLatches(Latches);
    if (Latches.empty())
      continue;
    bool Covered = any_of(L->blocks(), [&](BasicBlock *BB) {
      if (BB == H)
        return false;
      bool HasPoll = any_of(*BB, [&](Instruction &I) { return isLoopPoll(I) && !Dead.contains(&I); });
      return HasPoll && all_of(Latches, [&](BasicBlock *T) { return DT.dominates(BB, T); });
    });
    if (Covered)
      Dead.insert(P);
  }
  for (Instruction *I : Dead)
    I->eraseFromParent();
}

} // namespace

// Expands every loop poll placeholder in `M`. Returns whether it changed anything.
bool expandLoopPolls(Module &M) {
  Function *Placeholder = M.getFunction("nomu.loop.poll");
  if (!Placeholder)
    return false;
  SmallPtrSet<Function *, 16> WithPolls;
  for (Use &U : Placeholder->uses())
    WithPolls.insert(cast<CallInst>(U.getUser())->getFunction());
  for (Function *F : WithPolls)
    dropDominatedHeaderPolls(*F);
  SmallVector<CallInst *, 16> All;
  for (Use &U : Placeholder->uses())
    All.push_back(cast<CallInst>(U.getUser()));
  for (CallInst *CI : All) {
    auto *Slow = cast<Function>(CI->getArgOperand(0));
    bool OffFiber = !cast<ConstantInt>(CI->getArgOperand(1))->isZero();
    IRBuilder<> B(CI);
    Value *X28 = readRegister(B, "x28");
    if (OffFiber) {
      // No fiber, no poll: branch past it when x28 is 0.
      Instruction *OnFiber = SplitBlockAndInsertIfThen(B.CreateICmpNE(X28, B.getInt64(0), "poll.onfiber"), CI,
                                                       /*Unreachable=*/false);
      CI->moveBefore(OnFiber->getIterator());
      B.SetInsertPoint(CI);
    }
    // Volatile: the coordinator writes the word from another thread, so the load is never hoisted or merged.
    Value *Fiber = B.CreateIntToPtr(X28, B.getPtrTy(), "poll.fiber");
    LoadInst *Limit = B.CreateLoad(B.getInt64Ty(), B.CreateConstGEP1_64(B.getInt8Ty(), Fiber, LimitOffset),
                                   "poll.limit");
    Limit->setVolatile(true);
    Value *Stop = B.CreateICmpEQ(Limit, B.getInt64(-1), "poll.stop");
    MDNode *Unlikely = MDBuilder(CI->getContext()).createUnlikelyBranchWeights();
    Instruction *Then = SplitBlockAndInsertIfThen(Stop, CI, /*Unreachable=*/false, Unlikely);
    B.SetInsertPoint(Then);
    SmallVector<OperandBundleDef, 1> Bundles;
    CI->getOperandBundlesAsDefs(Bundles);
    CallInst *Call = B.CreateCall(Slow->getFunctionType(), Slow, {}, Bundles);
    Call->setCallingConv(Slow->getCallingConv());
    Call->setDebugLoc(CI->getDebugLoc());
    CI->eraseFromParent();
  }
  Placeholder->eraseFromParent();
  return true;
}

namespace {

// The most iterations a chunk runs, and the most instructions it may run between polls (K times the loop's
// size), which bounds the delay a stop sees in a loop with a large body. HotSpot's C2 strip-mines at 1,000
// iterations.
constexpr unsigned MaxChunk = 1000;
constexpr unsigned ChunkBudget = 16384;


// Whether `I` is a call the inner loop may not keep: any call but debug and lifetime markers and the program's
// side-effect-free intrinsics. Such a loop keeps its poll where it is.
bool blocksStripMining(const Instruction &I) {
  auto *CB = dyn_cast<CallBase>(&I);
  if (!CB || isa<DbgInfoIntrinsic>(CB) || CB->isLifetimeStartOrEnd() || isLoopPoll(I))
    return false;
  if (auto *II = dyn_cast<IntrinsicInst>(CB))
    return !II->onlyAccessesInaccessibleMemOrArgMem() && II->mayHaveSideEffects();
  return true;
}

// The loop's one poll placeholder and its chunk length, or null when the loop is not strip-mined: not innermost,
// not in simplified form, with a call it cannot keep, or with a body too large for chunks of two.
CallInst *candidate(Loop *L, unsigned &Chunk) {
  if (!L->isInnermost() || !L->getLoopPreheader() || !L->getLoopLatch())
    return nullptr;
  auto *Latch = dyn_cast<BranchInst>(L->getLoopLatch()->getTerminator());
  if (!Latch)
    return nullptr;
  CallInst *Poll = nullptr;
  unsigned Size = 0;
  for (BasicBlock *BB : L->blocks())
    for (Instruction &I : *BB) {
      if (isLoopPoll(I)) {
        if (Poll)
          return nullptr;
        Poll = cast<CallInst>(&I);
      } else if (blocksStripMining(I)) {
        return nullptr;
      }
      if (!isa<PHINode>(I) && !isa<DbgInfoIntrinsic>(I))
        ++Size;
    }
  if (!Poll)
    return nullptr;
  // The poll moves to the outer header, so what it records must be defined before the loop.
  for (Value *Op : Poll->operand_values())
    if (auto *I = dyn_cast<Instruction>(Op); I && L->contains(I))
      return nullptr;
  Chunk = std::min(MaxChunk, ChunkBudget / std::max(Size, 1u));
  return Chunk >= 2 ? Poll : nullptr;
}

// Strip-mine `L` around its poll `Poll`, `Chunk` iterations a chunk. With preheader P, header H and latch T:
//
//   P → O (the outer header: the header's values as φs, then the poll) → H … T → X (a chunk's end) → O or out
//
// A counter c, 0 at O, counts the chunk's iterations. When the latch's exit count (`BTC`, the back edges taken, expanded in P), each chunk runs `min(BTC - done, Chunk - 1) + 1`
// iterations and the inner latch tests only c, so the inner loop has one countable exit and vectorizes; X leaves
// once every iteration has run (HotSpot's C2 does the same). Otherwise the latch's own test is `and`ed with c's,
// and X returns to O while the loop's own test holds. Exits other than the latch's are untouched: they leave
// both loops.
void stripMine(Loop *L, CallInst *Poll, unsigned Chunk, ScalarEvolution &SE) {
  BasicBlock *P = L->getLoopPreheader();
  BasicBlock *H = L->getHeader();
  BasicBlock *T = L->getLoopLatch();
  LLVMContext &C = H->getContext();
  Function *F = H->getParent();
  auto *LatchBr = cast<BranchInst>(T->getTerminator());
  Type *I64 = Type::getInt64Ty(C);

  // The trip count, when the latch's exit is counted: the back edges taken before the latch leaves, if no
  // other exit leaves first (another exit leaves both loops, so it needs no count).
  Value *Trips = nullptr;
  if (LatchBr->isConditional() && L->isLoopExiting(T)) {
    const SCEV *BTC = SE.getExitCount(L, T);
    if (!isa<SCEVCouldNotCompute>(BTC) && BTC->getType()->isIntegerTy() &&
        BTC->getType()->getIntegerBitWidth() <= 64) {
      SCEVExpander Exp(SE, "strip");
      if (Exp.isSafeToExpandAt(BTC, P->getTerminator())) {
        Trips = Exp.expandCodeFor(BTC, BTC->getType(), P->getTerminator());
        if (Trips->getType() != I64) {
          IRBuilder<> PB(P->getTerminator());
          Trips = PB.CreateZExt(Trips, I64, "strip.btc");
        }
      }
    }
  }

  BasicBlock *O = BasicBlock::Create(C, H->getName() + ".chunk", F, H);
  P->getTerminator()->replaceUsesOfWith(H, O);
  IRBuilder<> B(O);
  for (PHINode &Phi : H->phis()) {
    PHINode *Outer = B.CreatePHI(Phi.getType(), 2, Phi.getName() + ".outer");
    Outer->addIncoming(Phi.getIncomingValueForBlock(P), P);
    Phi.setIncomingBlock(Phi.getBasicBlockIndex(P), O);
    Phi.setIncomingValue(Phi.getBasicBlockIndex(O), Outer);
  }
  // A counted loop: the iterations already run, and this chunk's last iteration (from 0).
  PHINode *Done = nullptr;
  Value *Last = nullptr;
  if (Trips) {
    Done = B.CreatePHI(I64, 2, "chunk.done");
    Done->addIncoming(B.getInt64(0), P);
  }
  Poll->moveBefore(*O, O->end());
  B.SetInsertPoint(O);
  if (Trips) {
    Value *Rem = B.CreateSub(Trips, Done, "chunk.rem", /*HasNUW=*/true);
    Last = B.CreateBinaryIntrinsic(Intrinsic::umin, Rem, B.getInt64(Chunk - 1), nullptr, "chunk.last");
  }
  B.CreateBr(H);

  // The chunk counter, first among H's φs.
  Type *CountTy = Trips ? I64 : Type::getInt32Ty(C);
  PHINode *Count = PHINode::Create(CountTy, 2, "chunk.n", H->begin());
  Count->addIncoming(ConstantInt::get(CountTy, 0), O);
  B.SetInsertPoint(LatchBr);
  Value *Next = B.CreateAdd(Count, ConstantInt::get(CountTy, 1), "chunk.next", /*HasNUW=*/true, /*HasNSW=*/true);
  Count->addIncoming(Next, T);

  // X: the chunk's end. A value of the inner loop used past it passes through a φ in X, keeping the inner loop
  // in LCSSA form for the vectorizer.
  BasicBlock *X = BasicBlock::Create(C, H->getName() + ".chunk.end", F, T->getNextNode());
  IRBuilder<> XB(X);
  DenseMap<Value *, Value *> Closed;
  auto close = [&](Value *V) -> Value * {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !L->contains(I))
      return V;
    auto [It, New] = Closed.try_emplace(V, nullptr);
    if (New) {
      PHINode *Phi = XB.CreatePHI(V->getType(), 1, V->getName() + ".chunk");
      Phi->addIncoming(V, T);
      It->second = Phi;
    }
    return It->second;
  };
  // Each outer φ takes, from X, what the header's φ takes from the latch.
  auto HP = std::next(H->phis().begin());   // past the counter
  for (PHINode &Outer : O->phis()) {
    if (&Outer == Done)
      continue;
    Outer.addIncoming(close(HP->getIncomingValueForBlock(T)), X);
    ++HP;
  }

  if (LatchBr->isConditional()) {
    unsigned Back = LatchBr->getSuccessor(0) == H ? 0 : 1;
    BasicBlock *Exit = LatchBr->getSuccessor(1 - Back);
    Value *Cond = LatchBr->getCondition();
    B.SetInsertPoint(LatchBr);
    Value *Stay;
    if (Trips) {
      Stay = B.CreateICmpULT(Count, Last, "chunk.stay");
    } else {
      Value *More = B.CreateICmpULT(Next, ConstantInt::get(CountTy, Chunk), "chunk.more");
      Stay = Back == 0 ? B.CreateAnd(Cond, More, "chunk.stay") : B.CreateAnd(B.CreateNot(Cond), More, "chunk.stay");
    }
    BranchInst::Create(H, X, Stay, LatchBr->getIterator());
    for (PHINode &Phi : Exit->phis())
      for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I)
        if (Phi.getIncomingBlock(I) == T) {
          Phi.setIncomingValue(I, close(Phi.getIncomingValue(I)));
          Phi.setIncomingBlock(I, X);
        }
    if (Trips) {
      // Every iteration has run once `done` passes the back edges taken.
      Value *Ran = close(Next);
      XB.SetInsertPoint(X);
      Value *DoneNext = XB.CreateAdd(Done, Ran, "chunk.done.next", /*HasNUW=*/true);
      Done->addIncoming(DoneNext, X);
      XB.CreateCondBr(XB.CreateICmpULE(DoneNext, Trips, "chunk.again"), O, Exit);
    } else {
      // The loop continues past the chunk (back to O), or it is done (the old exit).
      Value *XCond = close(Cond);
      XB.SetInsertPoint(X);
      if (Back == 0)
        XB.CreateCondBr(XCond, O, Exit);
      else
        XB.CreateCondBr(XCond, Exit, O);
    }
  } else {
    Value *More = B.CreateICmpULT(Next, ConstantInt::get(CountTy, Chunk), "chunk.more");
    BranchInst::Create(H, X, More, LatchBr->getIterator());
    XB.SetInsertPoint(X);
    XB.CreateBr(O);
  }
  LatchBr->eraseFromParent();
  SE.forgetLoop(L);
}

} // namespace

// Deletes the polls the optimizer left outside every cycle: the copy loop rotation puts in a loop's guard, a
// peeled iteration's, a fully unrolled loop's. Each runs at most once between the stops around it, in
// straight-line code, so it bounds nothing; the loop it came from keeps its own. A block that can reach itself
// keeps its poll even when LoopInfo sees no loop there (an irreducible cycle).
bool dropPollsOutsideLoops(Function &F, LoopInfo &LI, DominatorTree &DT) {
  SmallVector<Instruction *, 8> Dead;
  for (BasicBlock &BB : F) {
    if (LI.getLoopFor(&BB))
      continue;
    bool InCycle = any_of(successors(&BB), [&](BasicBlock *S) { return isPotentiallyReachable(S, &BB, nullptr, &DT, &LI); });
    if (InCycle)
      continue;
    for (Instruction &I : BB)
      if (isLoopPoll(I))
        Dead.push_back(&I);
  }
  for (Instruction *I : Dead)
    I->eraseFromParent();
  return !Dead.empty();
}

// Strip-mines every innermost loop of `F` whose only stop is its poll. Returns whether it changed anything.
bool stripMineLoops(Function &F, LoopInfo &LI, ScalarEvolution &SE, DominatorTree &DT) {
  bool Changed = dropPollsOutsideLoops(F, LI, DT);
  // A loop with a poll and no preheader gets one: the outer header goes there.
  for (Loop *L : LI.getLoopsInPreorder())
    if (L->isInnermost() && !L->getLoopPreheader() &&
        any_of(L->blocks(), [](BasicBlock *BB) { return any_of(*BB, isLoopPoll); }))
      Changed |= InsertPreheaderForLoop(L, &DT, &LI, nullptr, /*PreserveLCSSA=*/false) != nullptr;
  SmallVector<std::pair<Loop *, std::pair<CallInst *, unsigned>>, 8> Work;
  for (Loop *L : LI.getLoopsInPreorder()) {
    unsigned Chunk = 0;
    if (CallInst *Poll = candidate(L, Chunk))
      Work.push_back({L, {Poll, Chunk}});
  }
  for (auto &[L, PC] : Work)
    stripMine(L, PC.first, PC.second, SE);
  return Changed || !Work.empty();
}

} // namespace nomu

// `nomu.loop.poll` reads and writes only memory the program cannot see, never throws and always returns: the
// optimizer keeps every call in its place (it has an effect, so it is neither deleted, merged nor hoisted)
// and moves the program's memory operations freely around it.
extern "C" void nomuMarkLoopPollPlaceholder(LLVMValueRef Fn) {
  auto *F = cast<Function>(unwrap(Fn));
  F->setOnlyAccessesInaccessibleMemory();
  F->setDoesNotThrow();
  F->setWillReturn();
}
