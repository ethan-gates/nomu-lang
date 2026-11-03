# Frame mechanism feasibility: experiments that could falsify the design

**Avenue:** Risk · **Type/Lifecycle:** `research · prototype` · **Size:** L · **Status:** not started;
fifth of [194](194-gc-frame-metadata.md)'s children (after 242) · **Source:** 194

## Deliverable

Evidence for or against [242](242-frame-mechanism-designs.md)'s leading design: experiments built to
disprove it, run until they fail to.

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
  [247](247-loop-strip-mining.md).
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

The results, with the decision's evidence for 194; the evidence part of 245's series.

## Refs

[194](194-gc-frame-metadata.md); [242](242-frame-mechanism-designs.md); [241](241-frame-contract.md);
[104](104-fiber-stack-strategy.md).
