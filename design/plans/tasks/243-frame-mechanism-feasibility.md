# Frame mechanism feasibility: experiments that could falsify the design

**Avenue:** Risk · **Type/Lifecycle:** `research · prototype` · **Size:** L · **Status:** done;
fifth of [194](194-gc-frame-metadata.md)'s children (after 242) · **Source:** 194

## Deliverable

Evidence for or against [242](242-frame-mechanism-designs.md)'s leading design: experiments built to
disprove it, run until they fail to.

## Outcome

Candidate 1 (extended statepoints) survives every experiment, and most of it is now built:

- **243.1:** candidate 3's ceiling over today is about 5–9% on reference- and `String`-heavy code, so
  candidate 1 is the build; polls cost 29% in call-free array loops, recoverable in any candidate by loop
  strip mining (245).
- **Claims 1, 2, 3, 4, 6 hold; claim 5 finds no measurable cost.** Frame addresses with a frame index are
  recomputed after each stop (K2, `src/llvmpasses/FrameAddressSplit.cpp`); pointers that may point into a
  caller's frame are tracked values recorded at each stop (`src/llvmpasses/TrackFrameAddresses.cpp`); the
  copier (`runtime/stackmove.nomu`) adjusts every recorded word in the old stack's range and the collector
  skips words that are not managed objects. The full suite (936 runs) passes with every resume moving the
  stack and the old one inaccessible.
- **Built along the way, to keep:** K2 and the tracking (on by default), the copier and its stress mode
  `NOMU_STACK_MOVE`, `Runtime.protect`, the suite group `stack-move` and the harness's `--run-setting`, move-proof
  anchors and shadow-stack saves in the runtime, and the `frames_mutating` workload.
- **Left for the build (104 and 194's implementation tasks):** moving at a function-entry check (no check
  exists yet), promoted objects passed to callees (escape analysis does not allow it yet; the collector
  would then need to scan their fields from the frame), and the open items at the end of claim 4.

## First: the ceiling (243.1)

Before testing candidate 1's claims, bound how much candidate 3 (Nomu's machine-level frames) could gain
over today, since the result decides which design the claims should test. Each experiment is a build switch
that is unsound and exists only to measure, run on the compute and switch benchmarks, debug and release:

1. **No statepoint rewrite:** heap references are not spilled and reloaded at stops. Gives the whole cost
   of the stack-slot form of roots, the most that registers for tracked values (177, or candidate 3) can
   recover.
2. **No shaped homes:** `String` and other shaped values stay in registers with no `volatile` reloads. Gives
   the cost of the shaped path, which only candidate 3 removes.
3. **No loop polls.** Gives the cost of the polls, which only asynchronous preemption with maps at every
   instruction removes ([236](236-fiber-preemption.md), "Asynchronous preemption").

If the three together are a few percent, candidate 1 is the build and 3 stays a later option. If they are
large, plan for candidate 3 directly and build the parts the candidates share first (the value
classification, the frame table, the copier, the stack check, the stress modes and the static check).

### Results

Built: the `measure.*` settings and `measure_*` configs (`cfg.yaml`), the workloads `benchmarks/frames_tree`,
`frames_strings`, `frames_loops` and `frames_fib` (each round's input depends on the round, so no
configuration lets the optimizer skip work), and `tools/frames-ceiling.py`. Every run used
`NOMU_NURSERY_RESERVE=7000`, one carrier, release; a `gc_record` build of each workload confirmed no
collection runs; every configuration's output matched today's. Median of 7, change against today; the
control (`frames_fib`, no references live across calls) puts the noise at about ±4%:

| workload | today | regs | no polls | no homes | no statepoints | no statepoints, no homes | all three |
|---|---|---|---|---|---|---|---|
| `frames_tree` (references across recursion) | 177 ms | −1.0% | +0.9% | +1.5% | −5.6% | −5.6% | −5.3% |
| `frames_strings` (`String` across recursion) | 58 ms | +3.8% | +5.1% | −4.3% | −3.7% | −5.4% | −6.4% |
| `frames_loops` (call-free array loops) | 253 ms | −1.0% | **−29.0%** | 0.0% | −7.8% | −8.8% | **−33.2%** |
| `frames_fib` (control) | 47 ms | +0.3% | +4.2% | +1.6% | +3.1% | +0.2% | +0.2% |
| `micro_carried` | 21 ms | +0.8% | −1.1% | +0.1% | +0.8% | 0.0% | −1.9% |
| `pingpong_fiber` | 38.5 ms | +2.4% | −1.9% | +3.2% | +1.9% | +4.7% | −0.5% |
| `pingpong_actor` | 21.6 ms | −2.6% | +1.3% | +0.5% | −6.2% | −8.9% | −7.1% |

- **References at stops cost about 5–6%** on recursion holding references and about 6% on the actor
  ping-pong. With the register option (`regs`) the recursive function's code matches the no-statepoint
  build's (the node stays in callee-saved `x21`, no spill), yet the run recovers only about 1 point; the
  rest of the 5.6% lies outside that function, most likely in building the tree, and is not yet
  attributed.
- **Shaped homes cost about 4%** on the `String` workload, the part only candidate 3 removes.
- **Polls cost 29% on call-free array loops** and nothing measurable elsewhere. The machine code shows why:
  the poll's slow path is a call that may write memory, so with it in the loop LLVM reloads each array's
  count and buffer pointer every iteration; without it, those loads are hoisted out of the loop (neither
  build vectorizes; bounds checks prevent it). The relocation after the poll adds about 8% (the array's
  base becomes a phi of itself and its relocated copy). This cost is not specific to asynchronous
  preemption: **loop strip mining** removes it with polls kept, by running the loop in chunks of about a
  thousand iterations with the poll only between chunks, as HotSpot's C2 does. It applies to every
  candidate ([236](236-fiber-preemption.md), "Asynchronous preemption", option (e)); task
  [245](245-loop-strip-mining.md).
- **An artifact to avoid:** a first version of the workloads repeated identical work each round; with polls
  removed, LLVM hoisted the read-only recursive call out of the loop and did the work once (−86%). A poll
  is an optimization barrier, and a measurement without one must not let the optimizer delete work.

**What it decides.** Excluding the loop result, which strip mining recovers in any candidate, candidate 3's
ceiling over today is about 5–9% on reference- and `String`-heavy code, and part of that is reachable by
candidate 1 (the register option, measured here at about 1 point so far). That is a few percent, so by
243.1's rule candidate 1 stays the build, with strip mining added as the larger and independent win.
Limits: one machine, seven small workloads, medians of seven runs; the standard library and the runtime
were built under each configuration too.

## The claims to break (after 243.1)

From [242](242-frame-mechanism-designs.md) ([`internals/frames-designs.md`](../../internals/frames-designs.md),
"What 243 should try to break"): RS4GC accepts stack addresses as tracked values; a machine pass keeps every
frame address out of registers across stops; range testing by the collector and the copier is sound; the
suite passes under the stress modes; the cost against today; `ni:1` changes nothing observable.

### Claim 6: `ni:1` — holds; landed

The managed address space is now non-integral (`LLVMBridge.swift`, the datalayout gains `-ni:1`). The full
suite passes (882 of 882, every pipeline and GC leg). The `frames_*` workloads moved by +2% to +9%, the
control `frames_fib`, which holds no managed pointer `ni:1` could affect, by the most (+9%): machine drift,
no measurable effect.

### Claim 1: RS4GC accepts stack addresses as tracked values — holds, with a correction

Hand-written IR through the pinned LLVM's `opt -passes=rewrite-statepoints-for-gc` and `llc -O2` for
arm64, records read with `llvm-readobj --stackmap` (`tools/frames-ir-cases/`, `run.sh` reruns them):

| case | RS4GC | machine code and record |
|---|---|---|
| A: frame address entering the tracked space through an opaque call | accepted | spilled before the stop, recorded `Indirect [sp + 8]`, reloaded after: sound |
| A2: the same, the call replaced by `addrspacecast` after the rewrite | accepted | recorded `Direct sp + 0`, but the code computes `sp` into callee-saved `x19` before the stop and uses `x19` after: the record and the code disagree, unsound for a moved stack |
| B: through `ptrtoint`/`inttoptr` | accepted | as A2: `Direct` recorded, `x19` carried across the stop |
| C: allocas themselves in the tracked space (datalayout `A1`) | crashes | — |
| D: an interior pointer of a tracked frame address | accepted (rematerialized from the relocated base) | as A: spilled, `Indirect`, reloaded |

What follows for candidate 1 (`internals/frames-designs.md` is corrected):

- A possibly-stack pointer must reach the backend **opaque**: through an operation LLVM cannot see is a
  frame address (an opaque call or an identity inline asm, kept until after instruction selection), so it is
  spilled to a recorded slot at each stop and reloaded, as heap references are. The cost is one spill and
  reload per stop it is live across, as for a heap reference.
- A frame address LLVM can see (a frame index) is recorded `Direct` yet carried in a register: the lowering's
  rematerialization is merged with the address computed before the call. So K2 (the machine pass keeping
  frame addresses out of registers across stops) is required, for the frame's own uses of its slots.
- The `A1` route (allocas in the tracked space) is out.

### Claim 2: K2 catches every frame address carried across a stop — holds for frame indices

Built: `src/llvmpasses/FrameAddressSplit.cpp`, a machine pass compiled against the pinned LLVM and added to
every code-generation pipeline through LLVM's `RegisterTargetPassConfigCallback`, right after the peephole
optimizer (the last machine-SSA pass that could merge or hoist its recomputations; the dead-instruction
cleanup that follows removes the originals). No LLVM patch. For each virtual register computed from a frame
index (directly, or by copies and adds of an immediate), each use reached from its definition through a
`STATEPOINT` gets a fresh computation after the stop, once per value per stretch of a block between stops.
Values derived from a frame address that it cannot recompute (merged with another value, by a PHI or a
select) it leaves and counts (`NOMU_FRAME_SPLIT_STATS=1`). `measure.no_frame_split` turns it off.

Every fixture, example and benchmark that builds standalone (170 debug, 168 release; the rest are compile-error
and multi-module fixtures, the same set before and after), scanned with `tools/frame-stackaddr-asm.py`:

| | debug before | debug after | release before | release after |
|---|---|---|---|---|
| user statepoints with a frame address in a callee-saved register | 6 | 0 | 11 | 0 |
| runtime statepoints, same | 17 | 2 | 4 | 4 |
| uses split (distinct functions) | — | 85 (45) | — | 32 (13) |
| values left unhandled | — | 4 | — | 4 |

- The user hits included `read_line`'s `ticker`, `binary_tree`'s benchmark loop and `walk_multiframe`;
  all are gone. The debug runtime's `rtGcReportJson` (15 of 17) is gone.
- **The remaining runtime hits are the stack walker** (`rtCollectRoots`), which copies `x29`
  (`llvm.frameaddress`) to walk the frame-pointer chain while the world is stopped. No frame index is
  involved, and the walker runs on a stack that is not being moved. Out of K2's scope; the stack copier's
  contract has to say walkers run with their own stack pinned.
- **The 4 unhandled values are 246's stack half:** `String.eq` and `String.lt`, where `bytePointer()`
  selects between a `small` string's inline bytes (a frame slot) and a heap buffer. A merged address cannot
  be recomputed after the stop, so the fix belongs to 246 (no raw pointer spans a poll), which then covers
  both the moved buffer and the moved stack. The static scan misses these (they arrive through `csel`), the
  pass's count finds them.
- The full suite passes with the pass on (882 of 882, tier full).

Not yet checked: the `noinline` pipeline in the scan (the suite runs it), and the cost (claim 5: one address
computation per split use; 32 in release across the corpus).

### Claim 3: range testing is sound — holds for the cases that occur

The copier adjusts a recorded word only when it lies in the old stack's range; the collector keeps a
recorded word only when it is a managed object (`rtKeepManagedSlots`: in the Immix heap or a large-object
chunk). Every recorded word is a pointer: the statepoint rewrite records only `addrspace(1)` values, and the
tracking marks only pointers.

Cases, the suite group `stack-move` (`tests/fixtures/stack_move_matrix/*`, across `pipeline` × `gc`, every run
under `NOMU_STACK_MOVE=1`; each forces moves by sleeping in its deepest frame and prints `bad 0`):

| fixture | what lies in the moved stack |
|---|---|
| `derived_self` | a field-writing method's `self`, an address in `main`'s frame, passed down three calls, with field addresses derived from it live across the park |
| `erased_buffer` | an erased generic's argument and result buffers (a struct holding a heap `String`) |
| `erased_box` | a shadow-stack node: an erased body's runtime-sized `Wrap<T>` buffer, its node, and the saved shadow-stack top |

All 54 runs pass. The control: built with the protection off (`measure_no_frame_split`) and run moving, every
fixture faults on a moved-from stack in debug; in release the two erased fixtures happen to pass (the
optimizer kept the buffers in recorded or reloaded places), so the debug and noinline legs are the ones that
catch a regression there.

Not covered, and why:

- **A stack-promoted object passed to a callee.** It does not occur: every escape provider treats a call
  argument as escaping, so a promoted object (an `alloca`, an `addrspace(0)` frame address K2 handles) never
  reaches a callee or a stack map. When interprocedural escape lets one through, it reaches the callee as a
  `p1` value pointing into the stack, and the collector's filter would then also skip the object's managed
  fields; that case needs its own design (scan a promoted object's fields from its frame).
- **`self` pointing at a global.** The fixtures have no mutable globals to call a field-writing method on.
  A receiver in the heap (an array element) is covered by the suite's `struct_array_mutating`, which passes
  under the mode; how it reaches the method (copied out to a frame, or as a heap address the filter keeps)
  is not checked.

### Claim 4: the suite under a moving stack — holds

Built:

- **The copier** (`runtime/stackmove.nomu`, `rtStackMove`). A carrier moves a suspended fiber's stack just
  before switching it back in, on its own stack and under the scheduler lock: it copies the used part and
  fixes the saved `sp` and `fp`, the frame-pointer chain, the anchor, the shadow-stack list (head, `prev`
  links, buffers), and every recorded slot whose word lies in the old stack (range testing, through
  `rtWalkFrom` in slot mode). Callee-saved registers in the saved context are left alone: their words have
  no recorded kind.
- **The stress mode** `NOMU_STACK_MOVE=1`: every resume of a suspended fiber moves its stack (after a park,
  and after each stop-the-world, including the allocation slow path's collections), and the old stack is
  protected (`Runtime.protect`, a new intrinsic over `mprotect`), so a stale address faults at its first
  use. Moved-from stacks wait in a quarantine of 256 before reuse. Under the mode the parked-fiber walk also
  checks each anchor lies in its fiber's current stack. With no stack check yet (104), a resume is the
  only point a stack moves; a fiber that never parks never moves.
- **S2 values tracked** (`src/llvmpasses/TrackFrameAddresses.cpp`). Codegen marks each pointer that may
  point into a caller's frame where it enters (`markFrameAddress`, a call to `nomu.frame.addr`): a
  `mutating` value receiver, an erased generic's result buffer and `T`-typed argument buffers, and the
  erased runtime-sized buffers (`erased.box`, `erased.enum`), whose addresses have no frame index for K2.
  After optimization and before the statepoint rewrite (the new-PM pass `nomu-track-frame-addresses`,
  which Nomu's pass runner `nomuRunPasses` registers by name), each marker becomes an identity inline asm
  producing an `addrspace(1)` value (marked `gc-leaf-function`, or RS4GC makes it a statepoint), its GEPs, PHIs and selects are rebuilt in `addrspace(1)`, and every other
  use reads an `addrspacecast` back placed right before it. The rewrite then records these at stops like
  heap references.
- **The collector skips what is not an object** (`rtKeepManagedSlots`): a recorded word outside the Immix
  heap and the large-object list is left for the copier.
- **The shadow-stack top is saved as an offset** from the stack top (`rtShadowSave`, `rtShadowPopTo`):
  generated code holds the saved top across calls and only hands it back, so the runtime makes it
  move-proof, as it does the anchors below.
- **The harness option** `--run-setting stack_move=1` runs the whole suite under the mode (`tests/README.md`).

Results, full tier: 882 of 882 under the mode, three runs in a row; 882 of 882 without it.

Before S2 tracking, 849 of 882 passed under the mode. The 33 failures were all S2 values, in the non-inlined
builds:

| failing | count | what held the stale address |
|---|---|---|
| `xmod_erased`, `xmod_erased_fresh` (debug, noinline) | 18 | an erased generic callee (`hold<T>`) kept its argument and result buffers, addresses in its caller's frame, in callee-saved registers across its calls |
| `module-generic-*` (5 cases) | 5 | the same, across modules; one (`module-generic-producer`) also an `erased.box` buffer, a runtime-sized alloca whose address was spilled to an unrecorded slot |
| `mutating_self`, `struct_array_mutating` (noinline) | 10 | a `mutating` method kept `self`, an address in its caller's frame, in a callee-saved register across the stops in its loop |

Not yet covered by the mode: moving at a function-entry check (104 has none yet), and a collection at every
stop combined with moving (`--run-setting stack_move=1` with the suite's own GC legs covers the collections
the cases already request). The cost of the tracked values is claim 5.

### Claim 5: the cost — none measurable

What K2 and the tracking cost, against the same compiler with both off (`measure.no_frame_split`, which now
also drops the markers; `tools/frames-ceiling.py --configs no-move-safety`). Release, one carrier, nothing
collects, median of 7 (11 for `frames_mutating`); the control `frames_fib` puts the noise at about ±3%:

| workload | with both | without |
|---|---|---|
| `frames_tree` | 178 ms | +3.3% |
| `frames_strings` | 59 ms | +1.9% |
| `frames_loops` | 256 ms | −0.1% |
| `frames_fib` (control) | 46 ms | +3.1% |
| `frames_mutating` (new: a field-writing method's `self` live across a call every iteration) | 337 ms | +0.2% |
| `micro_carried` | 21 ms | +0.1% |
| `pingpong_fiber` | 42 ms | −2.8% |
| `pingpong_actor` | 21 ms | +2.1% |

- Removing both makes nothing faster beyond noise.
- In `frames_mutating`, tracking moves `self` from a callee-saved register to a stack slot: one store before
  each call and one load after, in a loop whose body is a short recursive call. The difference is 0.2%.
- Code size (`__text`) and stack maps over the corpus (170 debug, 169 release binaries): +0.01% and +0.01%
  debug, 0.00% and −0.00% release.
- The static scan still finds no user frame address in a callee-saved register across a stop.

Not measured: a workload heavy in erased generics (their buffers are tracked the same way), and compile time.

Found on the way, fixed:

- **The runtime held a stack address across a stop (G3).** The allocation slow path (`rtTlabAlloc`) and
  `rtReadLine` receive their caller's anchor as an address and can park more than once; after the first park
  moved the stack, the next park recorded the old anchor, and the collector walked a moved-from stack
  (`gc-many-carriers` failed 30 of 30 under the mode, `gen-mc-concurrent` occasionally). Both now keep the
  anchor as an offset from the stack top (`rtAnchorOffset`, `rtAnchorAt`) and recompute the address at each
  park.

Open: an erased body that reads a concrete field of a generic struct (`w.tag` of a `Wrap<T>` built in the
body) fails LLVM verification: the read yields the field's address, compared as an `i64`. Independent of the
frame work (it reproduces with the frame-address marker removed); `erased_box` avoids the read.

Open: the parked-fiber walk visits fibers in states 2 and 4 only, so a fiber readied after a park (state 0,
waiting in a run queue or slot) is not walked while it waits. A probe (a sleeper readied while one carrier
allocates, under minor, major and `immix` collections) read the right value every time, so either its roots
are reached another way or the probe misses the case; not yet explained.

## Experiments

- **IR cases** for each kind of tracked value and each way LLVM could keep a stray copy (a frame address in
  a callee-saved register across a call, a rematerialized address, a value split across registers), checked
  in the generated code.
- **Stress modes,** in the test suite: a collection at every safepoint (as `NOMU_GC_STRESS` does today), a
  stack moved at every check, and the old stack made inaccessible after each move so a stale address
  faults instead of corrupting memory. The whole suite runs under them.
- **Costs,** measured: spills and reloads at stopping points, code size, frame-table size, and the compute
  and switch benchmarks against statepoints.

## Output

The results, with the decision's evidence for 194.

## Refs

[194](194-gc-frame-metadata.md); [242](242-frame-mechanism-designs.md); [241](241-frame-contract.md);
[104](104-fiber-stack-strategy.md).
