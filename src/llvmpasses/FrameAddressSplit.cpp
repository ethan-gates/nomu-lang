// Frame-address splitting: no address into the current frame is carried in a register across a stop.
//
// A stop (a `STATEPOINT`: a call that may collect or switch fibers) is where the copier may move the stack,
// so any frame address held in a register across one would point into the old stack afterwards. The stack
// map records what lives in stack slots; it cannot fix up a register. This pass runs on machine SSA before
// register allocation. For each virtual register computed from a frame index (the address of a stack
// object, possibly offset by an immediate or copied), every use that some path reaches only through a stop
// gets a fresh computation of the address placed after the stop, and the original value dies before the
// stop. Register allocation then has nothing frame-derived to keep across it.
//
// What it cannot rematerialize (a frame address merged by a PHI, or combined with another register) it
// leaves alone and counts; `tools/frame-stackaddr-asm.py` checks the linked code for what remains.
// Design: `design/internals/frames-designs.md`, "No stray copies" (K2).
//
// `NOMU_FRAME_SPLIT_STATS=1` prints, per function that has frame addresses live across a stop, how many
// uses were split and how many values were left unhandled.

#include "NomuLLVMPasses.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/CodeGen/TargetOpcodes.h"
#include "llvm/CodeGen/TargetPassConfig.h"
#include "llvm/CodeGen/TargetSubtargetInfo.h"
#include "llvm/Target/RegisterTargetPassConfigCallback.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>
#include <mutex>

using namespace llvm;

namespace {

bool isStop(const MachineInstr &MI) { return MI.getOpcode() == TargetOpcode::STATEPOINT; }

class FrameAddressSplit : public MachineFunctionPass {
public:
  static char ID;
  FrameAddressSplit() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override { return "Nomu frame-address split"; }

  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesCFG();
    MachineFunctionPass::getAnalysisUsage(AU);
  }

  bool runOnMachineFunction(MachineFunction &MF) override;

private:
  MachineRegisterInfo *MRI = nullptr;
  const TargetInstrInfo *TII = nullptr;
  DenseMap<const MachineBasicBlock *, bool> BlockHasStop;
  // A rematerializable frame address: the instructions computing it, root (the frame-index instruction)
  // first, each later one using only the previous one's result.
  DenseMap<Register, SmallVector<MachineInstr *, 4>> Chains;
  // Values derived from a frame address that cannot be recomputed.
  SmallSet<Register, 8> Opaque;

  bool isRoot(const MachineInstr &MI) const;
  std::optional<Register> chainStep(const MachineInstr &MI) const;
  void classify(MachineFunction &MF);
  bool stopBetween(MachineBasicBlock::const_iterator From, MachineBasicBlock::const_iterator To) const;
  bool crossesStop(const MachineInstr &Def, const MachineBasicBlock &UseBlock,
                   MachineBasicBlock::const_iterator UseAt) const;
  Register rematerialize(Register Reg, MachineBasicBlock &MBB, MachineBasicBlock::iterator Before);
};

char FrameAddressSplit::ID = 0;

// An instruction computing a stack object's address: it names a frame index, defines one virtual register,
// reads no virtual register, and does nothing else.
bool FrameAddressSplit::isRoot(const MachineInstr &MI) const {
  if (MI.mayLoadOrStore() || MI.isCall() || MI.hasUnmodeledSideEffects() || MI.isPHI() || MI.isCopy())
    return false;
  bool HasFrameIndex = false;
  unsigned Defs = 0;
  for (const MachineOperand &MO : MI.operands()) {
    if (MO.isFI())
      HasFrameIndex = true;
    else if (MO.isReg() && MO.getReg().isVirtual()) {
      if (!MO.isDef())
        return false;
      ++Defs;
    } else if (MO.isReg() && MO.isDef() && !MO.isDead())
      return false;
  }
  return HasFrameIndex && Defs == 1 && MI.getOperand(0).isReg() && MI.getOperand(0).isDef();
}

// For an instruction that recomputes one virtual register from one other (a copy, or an add of an
// immediate), the register it reads.
std::optional<Register> FrameAddressSplit::chainStep(const MachineInstr &MI) const {
  if (MI.getNumExplicitDefs() != 1 || !MI.getOperand(0).isReg() || !MI.getOperand(0).getReg().isVirtual())
    return std::nullopt;
  for (const MachineOperand &MO : MI.implicit_operands())
    if (MO.isReg() && MO.isDef() && !MO.isDead())
      return std::nullopt;
  if (MI.isCopy() && MI.getOperand(1).getReg().isVirtual() && !MI.getOperand(1).getSubReg() &&
      !MI.getOperand(0).getSubReg())
    return MI.getOperand(1).getReg();
  if (auto Add = TII->isAddImmediate(MI, MI.getOperand(0).getReg()))
    if (Add->Reg.isVirtual()) {
      unsigned VirtualUses = 0;
      for (const MachineOperand &MO : MI.uses())
        if (MO.isReg() && MO.getReg().isVirtual())
          ++VirtualUses;
      if (VirtualUses == 1)
        return Add->Reg;
    }
  return std::nullopt;
}

// Find every frame-derived value. Machine SSA visits defs before uses in reverse post-order except across
// back edges, which only PHIs cross, so a worklist over uses reaches everything.
void FrameAddressSplit::classify(MachineFunction &MF) {
  SmallVector<Register, 16> Work;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB)
      if (isRoot(MI)) {
        Register R = MI.getOperand(0).getReg();
        Chains[R] = {&MI};
        Work.push_back(R);
      }
  while (!Work.empty()) {
    Register R = Work.pop_back_val();
    bool Rematerializable = Chains.count(R);
    for (MachineInstr &User : MRI->use_nodbg_instructions(R)) {
      if (User.mayLoadOrStore() || User.isCall())
        continue;
      for (const MachineOperand &Def : User.defs()) {
        if (!Def.isReg() || !Def.getReg().isVirtual())
          continue;
        Register D = Def.getReg();
        if (Chains.count(D) || Opaque.count(D))
          continue;
        auto Source = chainStep(User);
        if (Rematerializable && Source && *Source == R) {
          auto Chain = Chains[R];
          Chain.push_back(&User);
          Chains[D] = std::move(Chain);
        } else {
          Opaque.insert(D);
        }
        Work.push_back(D);
      }
    }
  }
}

bool FrameAddressSplit::stopBetween(MachineBasicBlock::const_iterator From,
                                    MachineBasicBlock::const_iterator To) const {
  for (auto I = From; I != To; ++I)
    if (isStop(*I))
      return true;
  return false;
}

// Whether some path from `Def` to the use at `UseAt` in `UseBlock` passes a stop. `UseAt` is the use's
// instruction, or the block's end for a PHI's incoming value. Def dominates the use, so walking predecessors
// back from the use ends at Def's block.
bool FrameAddressSplit::crossesStop(const MachineInstr &Def, const MachineBasicBlock &UseBlock,
                                    MachineBasicBlock::const_iterator UseAt) const {
  const MachineBasicBlock *DefBlock = Def.getParent();
  auto AfterDef = std::next(MachineBasicBlock::const_iterator(Def));
  if (&UseBlock == DefBlock) {
    // The use follows Def in its block: the straight path is the only one that does not pass Def again.
    for (auto I = UseBlock.begin(); I != UseAt; ++I)
      if (&*I == &Def)
        return stopBetween(AfterDef, UseAt);
  }
  if (stopBetween(UseBlock.begin(), UseAt))
    return true;
  SmallVector<const MachineBasicBlock *, 8> Work(UseBlock.pred_begin(), UseBlock.pred_end());
  SmallPtrSet<const MachineBasicBlock *, 16> Seen;
  while (!Work.empty()) {
    const MachineBasicBlock *B = Work.pop_back_val();
    if (!Seen.insert(B).second)
      continue;
    if (B == DefBlock) {
      if (stopBetween(AfterDef, B->end()))
        return true;
      continue;
    }
    if (BlockHasStop.lookup(B))
      return true;
    Work.append(B->pred_begin(), B->pred_end());
  }
  return false;
}

// Recompute `Reg` before `Before`: clone its chain with fresh registers; the last clone defines a register of
// `Reg`'s class.
Register FrameAddressSplit::rematerialize(Register Reg, MachineBasicBlock &MBB,
                                          MachineBasicBlock::iterator Before) {
  Register Prev;
  for (MachineInstr *Step : Chains[Reg]) {
    Register Old = Step->getOperand(0).getReg();
    Register New = MRI->createVirtualRegister(MRI->getRegClass(Old));
    MachineInstr *Clone = MBB.getParent()->CloneMachineInstr(Step);
    Clone->getOperand(0).setReg(New);
    if (Prev)
      for (MachineOperand &MO : Clone->uses())
        if (MO.isReg() && MO.getReg().isVirtual())
          MO.setReg(Prev);
    MBB.insert(Before, Clone);
    Prev = New;
  }
  return Prev;
}

bool FrameAddressSplit::runOnMachineFunction(MachineFunction &MF) {
  MRI = &MF.getRegInfo();
  if (!MRI->isSSA())
    return false;
  TII = MF.getSubtarget().getInstrInfo();
  BlockHasStop.clear();
  Chains.clear();
  Opaque.clear();
  bool AnyStop = false;
  for (MachineBasicBlock &MBB : MF) {
    bool Has = false;
    for (MachineInstr &MI : MBB)
      Has |= isStop(MI);
    BlockHasStop[&MBB] = Has;
    AnyStop |= Has;
  }
  if (!AnyStop)
    return false;
  classify(MF);
  if (Chains.empty() && Opaque.empty())
    return false;

  unsigned Split = 0, Unhandled = 0;
  // Uses to rewrite, gathered first so rewriting does not disturb the use lists being walked.
  struct Fix {
    MachineOperand *Use;
    Register Reg;
  };
  SmallVector<Fix, 16> Fixes;
  SmallVector<Register, 16> Derived;
  for (auto &Entry : Chains)
    Derived.push_back(Entry.first);
  for (Register R : Opaque)
    Derived.push_back(R);
  for (Register R : Derived) {
    MachineInstr *Def = MRI->getVRegDef(R);
    if (!Def)
      continue;
    bool Remat = Chains.count(R);
    bool Crossed = false;
    for (MachineOperand &Use : MRI->use_nodbg_operands(R)) {
      MachineInstr *User = Use.getParent();
      if (isStop(*User))
        continue;
      bool Crosses;
      if (User->isPHI()) {
        MachineBasicBlock *Pred = User->getOperand(Use.getOperandNo() + 1).getMBB();
        Crosses = crossesStop(*Def, *Pred, Pred->end());
      } else {
        Crosses = crossesStop(*Def, *User->getParent(), MachineBasicBlock::const_iterator(User));
      }
      if (!Crosses)
        continue;
      Crossed = true;
      if (Remat)
        Fixes.push_back({&Use, R});
    }
    if (Crossed && !Remat)
      ++Unhandled;
  }

  // One recomputation per value per stretch of a block between stops, at its first use there.
  DenseMap<std::pair<Register, const MachineInstr *>, Register> Reuse;
  for (const Fix &F : Fixes) {
    MachineInstr *User = F.Use->getParent();
    Register New;
    if (User->isPHI()) {
      MachineBasicBlock *Pred = User->getOperand(F.Use->getOperandNo() + 1).getMBB();
      New = rematerialize(F.Reg, *Pred, Pred->getFirstTerminator());
    } else {
      MachineBasicBlock &MBB = *User->getParent();
      const MachineInstr *LastStop = nullptr;
      for (MachineInstr &MI : MBB) {
        if (&MI == User)
          break;
        if (isStop(MI))
          LastStop = &MI;
      }
      auto Key = std::make_pair(F.Reg, LastStop ? LastStop : &MBB.front());
      auto It = Reuse.find(Key);
      // A recomputation reused only if it precedes this use; uses are gathered per value in use-list order,
      // which need not be instruction order, so check.
      if (It != Reuse.end()) {
        MachineInstr *Prior = MRI->getVRegDef(It->second);
        bool Precedes = false;
        for (auto I = Key.second->getIterator(); I != MBB.end() && &*I != User; ++I)
          if (&*I == Prior)
            Precedes = true;
        if (Prior->getParent() == &MBB && Precedes)
          New = It->second;
      }
      if (!New) {
        New = rematerialize(F.Reg, MBB, User->getIterator());
        Reuse[Key] = New;
      }
    }
    F.Use->setReg(New);
    F.Use->setIsKill(false);
    ++Split;
  }
  // The originals may still be live across a stop through a debug use; those uses do not extend liveness.

  if (std::getenv("NOMU_FRAME_SPLIT_STATS") && (Split || Unhandled))
    errs() << "frame-split " << MF.getName() << ": split " << Split << " uses, unhandled " << Unhandled
           << " values\n";
  return Split > 0;
}

} // namespace

extern "C" void nomuRegisterFrameAddressSplit(void) {
  static std::once_flag Once;
  std::call_once(Once, [] {
    // Leaked on purpose: the callback stays registered for the process.
    new RegisterTargetPassConfigCallback([](TargetMachine &, PassManagerBase &, TargetPassConfig *Config) {
      // After the last machine-SSA optimization that could merge or hoist the recomputations (machine CSE,
      // LICM, sinking, peephole); the dead-instruction cleanup right after removes the originals.
      Config->insertPass(&PeepholeOptimizerLegacyID, IdentifyingPassPtr(new FrameAddressSplit()));
    });
  });
}
