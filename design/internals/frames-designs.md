# Frame mechanism designs: the candidates, judged against the contract

One of the frames design documents ([frames.md](frames.md)); the output of task 242. It lays out the ways Nomu could
meet [the contract](frames-contract.md), judges each requirement by requirement in the contract's priority
order (soundness as a gate, then run-time performance and predictability, then implementation cost), and
names the design task 243 tries to break. Requirement numbers (R1–R8, G1–G4, T1–T3) are the contract's;
problem numbers are [the inventory's](frames-statepoints.md).

## Facts the designs rest on

Checked in LLVM's source (main, the line Nomu's pinned LLVM 23 follows) for this part:

- **What counts as managed is the GC strategy's call.** RS4GC asks the function's strategy,
  `GCStrategy::isGCManagedPointer(Type*)` (`isGCPointerType` in `RewriteStatepointsForGC.cpp`). A strategy
  Nomu registers itself (LLVM's `GCRegistry`, a supported extension point) can declare more than one
  address space managed, with no change to the pass.
- **RS4GC's base rules.** Arguments, loads, call results and `inttoptr`s are bases; GEPs and phis derive from
  bases; an `addrspacecast` into a managed space asserts ("unsupported addrspacecast"). That assertion is
  problem 2's wall, and a call result or `inttoptr` is the accepted way around it.
- **A tracked frame index is recorded `Direct`, but the code may carry it in a register.** In the
  statepoint lowering, a tracked value that is a frame index is "lowered directly": recorded as a `Direct`
  frame address and rematerialized after the call (`willLowerDirectly`, `StatepointDirectLeaf::rematerialize`
  in `StatepointLowering.cpp`). 243 found that the rematerialized address is merged with the one computed
  before the call: arm64 code computes it into callee-saved `x19` before the stop and uses `x19` after, while
  the record says `Direct`. A moved stack would leave `x19` stale. The same happens untracked, as in
  `read_line`'s `ticker`, where a stack buffer's address sits in `x24` across `sleep`.
- **An opaque frame address is spilled and reloaded.** A frame address that reaches the backend through an
  operation it cannot see through (a call) is treated as any tracked value: spilled to a slot at the stop,
  recorded `Indirect`, reloaded after (243, claim 1).
- **Registers for tracked values exist and are off.** `max-registers-for-gc-values` (default 0) and
  `fixup-allow-gcptr-in-csr` let tracked values stay in registers, including callee-saved ones, recorded
  as register locations the runtime must recover by unwinding (problem 19, task 177).
- **`preserve_nonecc`** makes every general register caller-saved (x86-64, AArch64, LoongArch).
- **The address space is integral today** (problem 23): no `ni:1`, so nothing stops the optimizer
  introducing integer round-trips of managed pointers.

## The layers

A design answers four questions, which combine:

1. **Recording:** how a live value's location is named at each stop.
2. **No stray copies:** how a copy outside the named location (a register, an integer, a hoisted frame
   address) is ruled out.
3. **The frame table:** its format, and how it survives the link (T1–T3).
4. **The stack itself:** whether it moves at all.

### Recording

- **A. Statepoints as today.** RS4GC tracks `addrspace(1)`; shaped values ride deopt bundles (176); erased
  buffers ride the shadow stack. Meets R2–R3 with problems 4–8; nothing for S1/S2 (R5) or R8.
- **B. Statepoints with one tracked space for "may be managed or on a stack".** A Nomu GC strategy;
  `addrspace(1)` comes to mean "a pointer the runtime may have to change": a heap reference, an interior
  pointer into a heap object, or an address into a fiber's stack. Every such value live across a stop is
  then spilled to a recorded slot (or, for a frame index, rematerialized) by machinery that already works.
  - The collector rewrites the words that point into the heap, and scans in place an object a word points
    at on a stack (a promoted object's managed fields; 179.4's pinned frame roots). The copier rewrites the
    words that point into the old stack. Each tests the word's range, which is sound because every recorded
    word is known to be a pointer (R5's marking).
  - A stack address enters the space through an operation LLVM cannot see through until after instruction
    selection (an opaque call or an identity inline asm), which RS4GC accepts as a base; it is then spilled
    to a recorded slot at each stop and reloaded. Entering through a cast or `inttoptr` leaves it a frame
    index, recorded `Direct` but carried in a register (243, claim 1); allocas in the tracked space crash
    RS4GC.
  - Interior pointers become ordinary derived pointers: RS4GC records base and derived, which lifts I12
    and gives 246's raw pointers a tracked form (R4, G4).
  - Promoted objects cross calls (problem 2): the callee's parameter is the same space whether the caller
    passes a heap object or its frame slot. This is 179's value-level reading of `addrspace(1)`, extended
    to stacks.
  - Shaped values stay on their homes. Whether a home can be a tracked alloca in `gc-live` (which may make
    the call model the write and retire problem 4's `volatile`s) is a question for 243.
- **C. A Nomu rewrite pass in place of RS4GC.** Nomu's pass decides what is tracked per value (179's
  classification, shapes as first-class roots, stack addresses), and emits `gc.statepoint`s that LLVM's
  lowering and stack maps carry on as today. It can also run where Nomu chooses in the pipeline, with
  optimization after it (problem 9). It removes problems 1–3 and 6–8 by construction and owns
  problem 4. Cost: a correctness-critical pass of RS4GC's size (3,334 lines) to own across LLVM upgrades.
- **D. A Nomu machine-level mechanism.** No statepoints: values carry their kind to machine code (pseudo
  instructions or operand flags), and a pass after register allocation records where each lives at each
  stop, in registers or slots, emitting Nomu's own table. The most freedom: values can stay in registers
  with their save locations recorded (.NET's model). The most work, and LLVM's instruction selection drops
  the information at each step it does not know about, so every lowering path is a soundness risk.

### No stray copies

- **K1. Non-integral managed space** (`ni:1`): the optimizer may not introduce integer round-trips of
  tracked pointers (problem 23; closes problem 10's class for compiler-made integers).
- **K2. Frame addresses never carried across a stop in a register.** A machine pass (Nomu's, compiled into
  its LLVM build) before register allocation: a virtual register defined from a frame index and live across
  a stopping call is split, and its uses after the call take a fresh frame-index materialization. Cost: one
  address computation after a stop for each such value, where today the register holds it for free.
- **K3. No callee-saved registers** (`preserve_nonecc` between Nomu functions). Every value live across a
  call is in the caller's frame, so callee-saved registers never hold anything at a stop. Spill slots still
  need describing, so K3 does not replace recording. Cost: every call saves and restores, in the caller,
  whatever is live; Go pays this, and its effect on Nomu's compute benchmarks is unmeasured.
- **K4. Verification.** A static check of the linked code (`tools/frame-stackaddr-asm.py`, made exact
  with the frame table: no register or slot holds a tracked kind across a stop unless recorded), and the
  stress modes: a collection at every stop with moved-from memory reused at once, and the stack moved at
  every check with the old stack made inaccessible.

### The frame table

- **F1. LLVM stack maps and 195's post-link index,** as today. Meets T2; leaves problems 17–18 (T1) and the
  shape-ordinal side tables (problem 8).
- **F2. A Nomu per-function frame table:** one entry per function in its own section atom, dropped with its
  function by dead stripping and folding as `eh_frame` is; lookup through a sorted index. Produced from the
  stack maps by a link-time step (with A or B), or emitted directly (with C or D). Adds R8's per-function
  argument kinds for the stack check.

### The stack

- **M. Copying stacks** (104's choice): the requirements on S1, S2, S3, R and R7–R8 all apply.
- **N. Stacks that never move:** a large reserved range per fiber committed as touched (104's option B), or
  segmented stacks. R5–R8 do not apply. Costs: page-granular stacks (16 KiB pages on Apple silicon, against
  Go's 2 KiB minimum) and the virtual-address budget for the first; the hot split, a performance cliff, for
  the second. 104 chose copying for performance; N stays the fallback 194 names.

## The candidates

Whole designs, each a choice per layer:

| | recording | stray copies | table | stack |
|---|---|---|---|---|
| **1. Extended statepoints** | B | K1, K2, K4 | F2 from stack maps | M |
| **2. Nomu's rewrite pass** | C | K1, K2, K4 | F2 | M |
| **3. Nomu's machine-level frames** | D | K4 | F2 | M |
| **4. Go's convention** | B or C | K1, K3, K4 | F2 | M |
| **5. Fixed stacks** | A (+ K1, 246's fix) | K1, K4 | F1 or F2 | N |

### Against the contract

| requirement | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| R1 stopping points known | call graph, as any | as any | as any | as any | as any |
| R2 heap refs named, read back | yes (RS4GC) | yes | yes, if every lowering keeps kinds | yes | yes |
| R3 shapes named, across objects | homes + F2 | first-class | first-class | as 1 or 2 | as today |
| R4 interior pointers | derived pointers | derived pointers | recorded | as 1 or 2 | banned (I12 + 246) |
| R5 S1 frame addresses | rematerialized; K2 | as 1 | recorded | in frame by K3, recorded | n/a |
| R5 S2 possibly-stack pointers | tracked, range-tested | as 1 | recorded | as 1 or 2 | n/a |
| R6 frame chain, runtime records | runtime | runtime | runtime | runtime | n/a |
| R7 runtime base frames | checked by K4 | as 1 | as 1 | as 1 | n/a |
| R8 arguments at the check | F2 argument kinds | as 1 | as 1 | as 1 | n/a |
| G4 raw pointers into managed memory | tracked form | tracked form | tracked form | as 1 or 2 | banned |
| T1–T3 | F2 | F2 | F2 | F2 | F1 or F2 |

Soundness, the gate: every candidate can meet the contract. Each rests on a different claim that could be
wrong, which is what 243 tests:

- 1 and 4 rest on RS4GC accepting stack addresses as tracked values, and on K2 catching every frame
  address the machine level would carry.
- 2 rests on Nomu's pass being right, the same claim as RS4GC's plus Nomu's changes.
- 3 rests on every path through instruction selection and register allocation keeping each value's kind,
  the hardest of these to make exhaustive.
- 5 rests only on the heap side (R2–R4), which holds today apart from G4.

### Performance and predictability

The mutator's costs, against today:

| | between stops | at a stop (a call that can stop) | per call | per function entry |
|---|---|---|---|---|
| today | none | spill and reload each live heap reference | — | — |
| 1 | none | as today, plus each live possibly-stack pointer; frame addresses recomputed | — | the stack check (104) |
| 2 | none | as 1; can be narrower (only what may be managed is tracked) | — | the check |
| 3 | none | can keep values in registers, recording their save locations | — | the check |
| 4 | none | as 1 or 2 | save and restore everything live across any call | the check |
| 5 | none | as today | — | none, or a split check |

- **1 and 2** cost what statepoints cost today plus the stack addresses, and keep 177's lever: tracked
  values in callee-saved registers, recovered by unwinding, which narrows the gap to 3.
- **3** has the lowest ceiling at the highest cost to build. Its edge over 1 has three parts: tracked values
  in registers (which 177's lever mostly gives 1 as well), shaped values in registers across stops (only
  3), and maps at every instruction, which allow asynchronous preemption and so loops without polls (only
  3; [236](../plans/tasks/236-fiber-preemption.md), "Asynchronous preemption"). 243.1 measured the ceiling:
  about 5–6% for references at stops (partly recovered by the register option), about 4% for shaped values,
  and 29% for polls in call-free array loops, which loop strip mining recovers in every candidate
  ([243](../plans/tasks/243-frame-mechanism-feasibility.md), "Results"). Candidate 1 stays the lead.
- **4** puts a cost on every call in compute code, the workload where Nomu aims to beat Go, to remove a
  problem K2 removes at stops only.
- **5** is predictable at run time apart from the hot split (segmented) or the per-fiber page floor
  (reserved ranges); it gives up small stacks, which is what 104 chose copying for.

Predictability: in 1, 2 and 3 a small edit changes which values are live across a stop, and so how many
spills there are, as in Go; nothing in them depends on a heuristic that an edit can flip. In 4, K3 adds no
cliff. In 5 the hot split is a cliff that an edit to call depth can trigger.

## The leading candidate: 1, extended statepoints

1 meets every requirement using LLVM's own lowering, a supported extension point (the GC strategy), one
datalayout setting and one machine pass, and its costs at run time are today's plus the stack addresses
live across stops. 2 is the same design with Nomu's pass in RS4GC's place, and 1 leads to it: if 243 finds
RS4GC's limits in the way (allocas as tracked values, the `addrspacecast` rule, the deopt bundles for
shapes), the step is to replace that one pass, keeping everything else. 3's gain over 1 is the
register-resident ceiling, which 177 can measure for 1 first. 4 is a cost on every call to fix what K2
fixes at stops. 5 stays the fallback.

### What 243 should try to break

Each claim, the experiment that could disprove it, and what follows if it does:

1. **RS4GC accepts stack addresses as tracked values.** IR cases: an alloca's address entering the tracked
   space by a call result, by `inttoptr`, and by allocas in the tracked space; each live across a
   statepoint; check the records (a frame index should be `Direct`) and the code after the call. If
   none works: candidate 2.
2. **K2 catches every frame address carried across a stop.** Build K2, then the static check over the suite
   and benchmarks, debug and release: zero frame addresses in registers across stops, `read_line` and
   `mutating_self` included. If some escape (another machine pass recreates them after K2): move K2 later,
   or add K3 for the functions affected.
3. **Range testing is sound.** Every recorded word is a pointer, and the copier adjusts only those in the
   old stack's range; the collector skips those outside the heap. Cases: a promoted object passed down
   three calls, a `mutating` method in a loop, an erased-generic buffer, a shadow-stack node.
4. **The whole suite under the stress modes,** with the stack moved at every check and the old stack made
   inaccessible, and a collection at every stop with moved-from memory reused: no fault, no wrong output.
5. **The cost.** Spills and reloads at stops, frame-address recomputations, code size and frame-table size,
   on the compute and switch benchmarks, against today.
6. **`ni:1`.** Turning it on changes nothing in the suite's output and little in code size; it can land
   on its own, before any of this.

## Refs

[frames-contract.md](frames-contract.md), [frames-statepoints.md](frames-statepoints.md),
[frames-prior-art.md](frames-prior-art.md); tasks [104](../plans/tasks/104-fiber-stack-strategy.md),
[176](../plans/tasks/176-shaped-gc-roots.md), [177](../plans/tasks/177-register-resident-gc-roots.md),
[179](../plans/tasks/179-value-level-gc-classification.md), [243](../plans/tasks/243-frame-mechanism-feasibility.md),
[246](../plans/tasks/246-raw-pointers-into-managed-memory.md); LLVM `RewriteStatepointsForGC.cpp`,
`StatepointLowering.cpp`, `FixupStatepointCallerSaved.cpp`, [LangRef](https://llvm.org/docs/LangRef.html)
(`preserve_nonecc`, non-integral pointers).
