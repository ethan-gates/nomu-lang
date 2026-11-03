# The frame contract: what must hold wherever a fiber can stop

Part of the frames series ([frames.md](frames.md)); the output of task 241. It states what any mechanism
describing Nomu's frames must guarantee, precisely enough to test. Task 242 judges candidate designs
against it and 243 tests the leading one. Requirements are numbered (R1…) so designs and tests can cite
them.

## Priorities

Soundness is required: a mechanism that can leave a stale heap reference or a stale stack address is
rejected, however rare the case. Among sound mechanisms, run-time performance and predictability come first:
the mutator's cost at and between stopping points, and no performance cliffs from small source edits.
Implementation and maintenance cost come after. Nomu's own LLVM passes, run after the statepoint rewrite or
replacing an LLVM pass, are in scope where LLVM's pass ordering causes friction.

## The summary

> At every point where the runtime can stop a fiber, every live value the runtime must find or change is in
> a location the runtime can name, and the code reads it back from there afterwards.

The rest of this part makes "point", "value", "find or change", "name" and "read back" precise.

## Stopping points

A fiber stops when control enters the runtime and the runtime may run a collection or move the stack before
returning. Today:

| point | where it is emitted | what the runtime may do there |
|---|---|---|
| the safepoint poll's slow path | loop headers that reach no other safepoint (`emitHeaderPoll`, `__nomu_gc_poll_slow`) | collect |
| the allocation slow path | every managed allocation's miss path (`__nomu_alloc_slow`) | collect |
| a park | join, sleep, reading a line (the `schedForwarder` functions) | collect while parked |
| any call that can reach one of the above | every call not marked `gc-leaf-function` | whatever its callee's stop does |

With 104 and 236, two more:

| point | where | what |
|---|---|---|
| the stack check | function entry, before the frame is set up | grow (move) the stack; collect if growth allocates; preempt |
| the preemption request | the same check, and the loop-header poll | park, then any of the above |

**R1. Every stopping point is known to the compiler,** and a call is a stopping point exactly when its
callee can reach one. A call wrongly treated as unable to stop is unsound; one wrongly treated as able to
stop costs a record and spills (240, problem 20). Today this is the hand-kept leaf list; the call graph and
the runtime subset (149) can derive it.

**The state at a stop.** The top frame is in the runtime. Every Nomu frame below it is suspended at a call,
so its caller-saved registers are dead and its live values are in its frame or in callee-saved registers,
which some frame above saved or the switch saved into the fiber's context buffer. The stack check is the
exception: it runs at entry, before the frame exists, with the arguments live in argument registers.

**Not stopping points.** A `gc-leaf` call; code in the runtime subset, which never polls or parks; a call
into code Nomu does not own, which runs on the carrier's stack (104's libc rule) and returns before the
fiber can stop.

## The values

At a stopping point, each frame of the stopped fiber (each frame from the anchor to the base) can hold
values of these kinds live across the stop:

| kind | what | who changes it |
|---|---|---|
| **H1** heap references | an `addrspace(1)` pointer to a managed object | the collector, when it moves the object |
| **H2** shaped values | a value whose words are references only in some cases, decided by a tag in the value (`String`'s buffer word, an enum payload) (176) | the collector, conditionally |
| **H3** interior heap pointers | an address inside a managed object | forbidden across a stop today (I12) |
| **S1** own-frame addresses | the address of something in this frame: a stack-promoted object, a value-aggregate slot, a shaped home, a struct-return or argument buffer, a shadow-stack node | the copier |
| **S2** possibly-stack addresses | a pointer the frame received or loaded that may point into a caller's frame: a by-reference `self`, a struct-return pointer, an erased-generic buffer, a promoted object passed to a callee | the copier, when it points into the moved stack |
| **S3** the frame chain | saved frame pointers and return addresses | the copier |
| **R** runtime records into the stack | the fiber's saved context (stack pointer, frame pointer, callee-saved registers), its anchor (`anchor-sp`), its stack base, its shadow-stack top, and the shadow stack's `prev` links | the copier |

**R2. Every H1 and H2 value live across a stop is in a named location** (a frame slot, or a callee-saved
register whose save location is known) **and the code reads it from there after the stop.** A copy of the
value elsewhere (a register, an integer derived from it, a value forwarded by the optimizer) must not be
used after the stop. The two silent bugs in 240 (problems 5 and 10) were copies that escaped this.

**R3. For each H2 value, the shape is named with the location,** resolvable across separately compiled
objects (240, problem 8).

**R4. No H3 value is live across a stop,** or each one is named with its base, and the collector rewrites it
by the base's displacement. Either is acceptable; the choice belongs to 242.

**R5. Every S1 and S2 value live across a stop that can move the stack is either recomputed from the frame
after the stop, or held in a named location, marked as an address, and read from there after the stop.**
- An S1 address recomputed from the stack or frame pointer after the stop is correct by construction, and
  needs no record. The measurement below shows this is what LLVM does for nearly every S1 address today,
  and that it sometimes carries one in a register instead; the mechanism must rule that out or record it.
- An S2 value cannot be recomputed, so it must be named and marked. The marking matters: a word known to be
  an address can be adjusted soundly by testing whether it falls in the old stack's range, which handles an
  S2 without knowing at compile time whether it points into a stack. A word not known to be an address
  cannot be (Scala Native's guessing, [frames-prior-art.md](frames-prior-art.md)).
- Only values that may point into a stack need this. Nomu's types and facts exclude most pointers: a raw
  pointer from an off-heap allocation, a global, a witness table or a heap object passed as a raw pointer
  never points into a stack. The fewer values marked, the fewer kept out of registers.

**R6. The copier can find every S3 and R value.** S3 by walking frames (frame pointers are kept,
`frame-pointer=non-leaf`); R values are at fixed places in the fiber record, and the shadow stack is a list
from the fiber's `shadow-top`.

**R7. Frames with no records are covered too.** The runtime's frames at the base of every fiber stack
(`rtSchedFiberMain`; a mailbox fiber's `rtSchedMailboxFiberMain` and `nomu_actor_drain`) stay live below
the user frames and have no records. The copier moves them with the rest; they must hold no stack address
across their call into user code, or be described like any other frame.

**R8. At the stack check, the arguments in registers are named** with their kinds (H1, H2, S2), since the
check runs before the function has a frame to spill them into.

## What the language and runtime guarantee

These make the requirements sufficient. A mechanism may rely on them; each has an owner that keeps it true.

- **G1. No pointer into a fiber's stack is stored outside that stack,** except in the runtime records (R).
  Escape analysis keeps stack-promoted objects from escaping to the heap, to globals and to other fibers;
  sharing rules keep a fiber's stack private. Stack addresses flow only down the call tree, Go's invariant.
- **G2. Code Nomu does not own never holds a stack address across a stop.** It runs on the carrier's stack
  and receives fiber-stack addresses only for the duration of a call that cannot stop (104).
- **G3. Runtime-subset code holds raw addresses only between stops,** since it never polls or parks; the
  frames that stay live across a stop are those of R7.
- **G4. A raw pointer into managed or frame memory is never live across a stop, or is described.** This
  does not hold today. `StringBase.bytePointer()` gives a `RawPtr` into a heap buffer or, for a small
  string, a stack slot; `ManagedBuffer.headerPtr()` and `elementPtr(at:)` give interior pointers; all are
  made by `ptrtoint`/`inttoptr`, so no mechanism sees them, and I12 checks only SSAIR's address operations.
  `String.eq` holds two across its loop's poll and reads a moved buffer's old copy (reproduced: task
  [246](../plans/tasks/246-raw-pointers-into-managed-memory.md)). Such pointers are H3 values (R4) or S1/S2
  values (R5) under another type; whichever the mechanism chooses, the type must not hide them.

## What the toolchain must preserve

- **T1. Each function's description survives the link with the function:** dropped with it when it is
  dead-stripped, dropped with a folded duplicate, and found from its code address (240, problems 16–18).
- **T2. Lookup from a return address costs no setup at launch or first collection,** within 195's budget (under
  1 ms of setup for a 2M-line program).
- **T3. Several images** (a future dynamic library, through FFI) each carry their own descriptions, found
  from a code address.

## How each requirement is tested

| test | catches | today |
|---|---|---|
| collection at every stopping point | R2, R3 violations that survive a collection | `NOMU_GC_STRESS` |
| moved-from memory reused at once | a stale H1/H2 read that would otherwise find intact bytes | the `nursery-tight` and `*-nursery` legs (176.5.7) |
| the stack moved at every check, the old stack made inaccessible | any stale S1, S2, S3 or R value faults at its first use | to build (104, 243) |
| a static check of generated code | a stack address or heap reference kept in a register or spilled slot across a stop without a record | prototype: `tools/frame-stackaddr-asm.py` (below) |
| the suite under every leg, debug and release, inliner on and off | interaction with optimization | the suite's `pipeline` and `gc` dimensions |

A violation of R2 or R5 shows as wrong output or a fault under these legs; the stack-move leg turns every
stale stack address into a fault at its first use.

## What Nomu's generated code holds today

Measured for this part (241) to see which requirements today's code already meets by accident and which it
breaks. Two views, both heuristics with the limits described; the tools are `tools/frame-stackaddr-ir.py`
and `tools/frame-stackaddr-asm.py`.

**In LLVM IR after the statepoint rewrite** (the entry module of 144 fixtures and examples, built debug and
release; for each statepoint, the non-GC pointers live across it, by where they come from):

| | debug | release |
|---|---|---|
| statepoints | 1,777 | 1,839 |
| with a non-GC pointer live across | 1,023 | 1,087 |
| live pointers from an alloca (S1) | 4,051 | 4,336 |
| from a pointer parameter (S2 candidates) | 10 | 26 |
| from a load | 12 | 204 |
| from a call | 24 | 244 |

- S1 addresses are live across most statepoints: in release, 3,806 of the 4,336 are `{ i64, i64 }` slots,
  the `String` homes and slots 176 records.
- The parameters are a `mutating` method's `self` (16, an address into the caller's frame), the actor
  drain's mailbox (9, a heap object passed raw) and one fiber-registry pointer.
- The loads are almost all the scheduler global (`rtSched`, 193), and the calls are runtime results and
  off-heap allocations: none point into a stack, which the requirement's last point uses.

**In the linked machine code** (514 suite binaries, 1,623 distinct functions, each counted once; a register
holds a stack address when computed from `sp` or `x29`):

- Of 1,910 statepoint calls in user code, 4 had such an address in a callee-saved register, read after the
  call: in `read_line`'s `ticker`, the address of `print`'s string buffer, hoisted out of the loop into
  `x24` and held across the poll and `sleep`. Everywhere else LLVM recomputed frame addresses after the
  call.
- 191 stores of a stack address to memory, nearly all `printf`'s variadic argument area, used only during a
  call that cannot stop.
- The scan cannot see addresses that arrive as parameters or are loaded from memory. Examined by hand, the
  release `mutating_self` fixture's `Pair.run` moves `self` from `x0` into callee-saved `x20` at entry and
  reads through it after each poll in its loop: an S2 value in a register across every stop, the common
  shape for any `mutating` method with a loop.

**What follows.** R2–R4 hold today (176, 195). R5 does not: S1 holds by accident (LLVM usually recomputes,
LICM sometimes hoists), and S2 fails in the ordinary case. R6–R8 have no mechanism yet. A stack copier on
today's code would corrupt `mutating` methods first.
