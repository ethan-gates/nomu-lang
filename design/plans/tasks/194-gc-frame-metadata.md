# GC frame metadata — LLVM statepoints or our own

**Avenue:** Risk · **Type/Lifecycle:** `epic · evaluate` (codegen + runtime) · **Size:** XL ·
**Status:** a tracking epic, opened; its work is in child tasks, 239–244 first (below), with
implementation and post-implementation tasks added as it goes · **Source:** raised by [190](190-explicit-module-builds.md) 190.6 F1 (stack scanning
across objects), now [195](195-link-time-gc-frame-index.md); grown by [104](104-fiber-stack-strategy.md)'s
moving stacks and interprocedural stack promotion, both blocked on statepoints

This is a tracking epic: it holds the deliverable, the evidence, the order of its children and the
decision record, and no implementation. Each child is its own task so it can grow as much detail as it
needs. It spans the whole effort, not only the decision: research and design, implementation, then the work
after a working system (verification, generalizing, polish). A production-grade mechanism
can be running well before 194 is complete; 194 is complete when its children are. If the decision is to replace statepoints, this is likely the largest and most defining piece of
Nomu, so it is done with the discipline below.

## Deliverable

A decision, with its design, on how Nomu describes frames to its runtime: where live heap references and
live stack addresses are at every point a fiber can stop (the contract below). The question is whether
LLVM's statepoints can be kept or must be replaced by our own mechanism. Also: keep LLVM's statepoint and stackmap machinery, or
replace it with our own. Either way the runtime reads a compact frame table built at link time, sorted, with
no setup at launch or first collection; this task designs that table too, since its producer depends on the
decision.

- **Keep statepoints:** a link-time step converts the linked binary's `__llvm_stackmaps` into the table
  (as [195](195-link-time-gc-frame-index.md) does over today's stackmaps).
- **Replace them:** our code generation emits the table's per-object input directly.

Alongside the decision: an **evaluation of generality**, whether the solution can serve other
language implementers who want moving collectors with copying stacks on LLVM (244). 239 found no system
that has done this combination on LLVM (below).

## Child tasks

In order; each produces a written output, and none is done without it.

| task | scope | output |
|---|---|---|
| [239](239-frame-metadata-prior-art.md) | prior art: what languages and research systems did about moving collection, stack maps and growable stacks, on LLVM and elsewhere, and what each gave up | a cited survey |
| [240](240-statepoint-inventory.md) | Nomu's use of statepoints today, file by file, and every problem it caused (176, 195, 129, 177, …), with root causes | an inventory |
| [241](241-frame-contract.md) | the contract, precise and testable: what must hold at every stopping point, for the collector, the stack copier and interprocedural promotion | a requirements document |
| [242](242-frame-mechanism-designs.md) | candidate mechanisms (an IR discipline, a machine-level pass, others 239 finds), each judged against 241, with failure modes | a design comparison |
| [243](243-frame-mechanism-feasibility.md) | experiments that could falsify the leading design: IR cases, a stack moved at every check, the old stack made inaccessible, measured costs | results |
| [244](244-frame-mechanism-generality.md) | what depends on Nomu's frontend and what another LLVM language could reuse; its preconditions; packaging as a library or upstream | an evaluation |

The decision is recorded here once 239–243 are done; implementation tasks (the frame-table format, its
link-time step, the producer in codegen, the runtime's readers, the stack copier) are opened from it.

## Discipline

- Requirements (241) before design (242).
- Every design claim is tied to an experiment that could disprove it (243).
- The stress modes are in the test suite before anything depends on them.

## Evidence so far

- **Size.** LLVM's format spends 12 bytes per location and three meta constants per record: ~68 bytes per
  record, ~68 MB of section for a 2M-line program. A runtime-built index pages all of it in.
- **No directory.** Records are variable length and per-object blobs are concatenated with no index, so any
  reader must step every record; at ~1M records that is 3.5–6 ms ([195](195-link-time-gc-frame-index.md) benchmark), over the 1 ms setup
  budget.
- **Shaped roots ride the deopt bundle.** A stackmap Constant cannot hold a link-time value, so shaped roots
  ([176](176-shaped-gc-roots.md)) carry a per-compile ordinal resolved through a side table, which collides
  across objects ([195](195-link-time-gc-frame-index.md)).
- **Optimizer coupling.** `rtCollectRoots` must keep its frame-reading loop inline so the
  `llvm.frameaddress` memory effect makes its caller spill roots at the statepoint (selfhosted-gc.md §9).
- **The linker cannot see inside it.** Each object's stackmaps are one blob in one section, so the linker
  relocates the addresses but applies none of its per-function transforms to the records: dead stripping
  never removes a function the section references, so every function with statepoints ships even when
  unused (195.1), weak/COMDAT folding keeps every copy's records pointing at the kept
  copy (seen in [195](195-link-time-gc-frame-index.md): a generic specialized in two consumers, `churnKeep<Cell>`, has entries in two
  blobs bound to one address), identical-code folding leaves the folded body's records, and no sorted lookup
  table is built. Other per-function metadata gets this from the linker: `eh_frame` is split per function,
  Apple's `__LD,__compact_unwind` is dropped with dead or folded functions and merged into a sorted
  `__unwind_info` at link time, and Go's linker owns its frame tables.
- **Designed for JITs.** Stackmaps and patchpoints came from WebKit's FTL JIT and statepoints from Azul's
  Falcon JIT: one in-memory module, no link. Separately compiled native binaries were never the target
  (from memory; to confirm).
- **Moving fiber stacks cannot be built on it.** [104](104-fiber-stack-strategy.md)'s target is Go's
  design: small stacks copied to a larger one on growth, every pointer into the moved stack fixed. Go can
  fix them because its compiler records them all (and its calling convention keeps nothing in registers
  across a call). Statepoints record only `addrspace(1)` values, and raw addresses into a frame are live
  across calls in code Nomu emits today: a stack-promoted object is an `addrspace(0)` slot
  (`SSAIRToLLVM.swift`, `stackAlloc`), a struct-return slot or by-reference argument is the caller's frame
  address held by the callee, and LLVM's register allocator may keep any computed frame address in a
  callee-saved register across a call. A stack moved under such a value leaves it pointing at the freed
  stack: silent corruption. Making stack addresses `addrspace(1)` so statepoints relocate them runs into
  the rewriter's rejection of `addrspacecast` into `addrspace(1)` (176). gccgo and gollvm, Go through GCC
  and LLVM, use segmented stacks instead of copying for this reason.
- **Interprocedural stack promotion is blocked on it** (176's "addrspace-across-calls wall", 148 §148.1):
  a callee's reference parameter must be `addrspace(1)` to be rooted, and a stack address cannot be cast
  into it across a safepoint, so a value proven not to escape a non-inlined callee cannot stay in the
  caller's frame.
- **Known friction elsewhere:** `musttail` with statepoints ([129](129-tail-call-optimization.md)), the
  `addrspace(1)` coupling 176 works to loosen (and 176.5, a `String` local reading a stale buffer pointer
  after a moving collection), and keeping roots in registers across safepoints
  ([177](177-register-resident-gc-roots.md)).

## What the designs say

From [242](242-frame-mechanism-designs.md) ([`internals/frames-designs.md`](../../internals/frames-designs.md)):
five candidates (extended statepoints; Nomu's rewrite pass in RS4GC's place; Nomu's machine-level frames;
Go's no-callee-saved convention; fixed stacks). Leading: **extended statepoints**, a Nomu GC strategy under
which `addrspace(1)` means "may be managed or on a stack", so stack addresses and interior pointers are
tracked by LLVM's existing lowering; `ni:1`; a machine pass that keeps frame addresses out of registers
across stops; a per-function frame table. If RS4GC's limits get in the way, the next step is Nomu's own
rewrite pass with everything else kept. 243 tests six claims.

## What the contract says

From [241](241-frame-contract.md) ([`internals/frames-contract.md`](../../internals/frames-contract.md)): R2–R4
(heap references and shaped values) hold today. R5 (stack addresses) holds for frame-local addresses only
because LLVM usually recomputes them after a call; it hoists one into a register in `read_line`, and a
`mutating` method keeps `self`, an address into its caller's frame, in a callee-saved register across every
poll in its loop. The guarantee that raw pointers into managed or frame memory never span a stop (G4) is
broken today, with a reproduced bug ([246](246-raw-pointers-into-managed-memory.md)).

## What the inventory says

From [240](240-statepoint-inventory.md) ([`internals/frames-statepoints.md`](../../internals/frames-statepoints.md)):
22 problems statepoints have caused or constrained, 15 tracing wholly or partly to the machinery. They group
as managedness fixed by type (conditional references, stack-promoted objects across calls), deopt bundles
repurposed for shaped roots (unmodeled writes needing `volatile` reloads, dropped sub-field addresses,
bundles lost to inlining, ordinals that cannot be link-time values), the optimizer running before
safepoints exist (the hoisted barrier address), and a JIT-oriented format (no index, no per-function
linker handling). Stack addresses are not described at all. The two silent wrong-output bugs were found
only by test legs that reuse moved-from memory quickly.

## What prior art says

From [239](239-frame-metadata-prior-art.md) (the survey: [`internals/frames-prior-art.md`](../../internals/frames-prior-art.md)):

- **Every system that moves stacks soundly** has no pointers into them (Standard ML, OCaml, Java), keeps
  none across the move (.NET's runtime async), or owns its compiler, describes every frame word, and has no
  callee-saved registers (Go). Nomu meets none of these.
- **The nearest precedent on LLVM, Manticore,** copied stacks under a moving collector using LLVM's stack
  maps, sound only because Standard ML has no pointers into the stack and its compiler used no callee-saved
  registers.
- **The one LLVM system in Nomu's position, Scala Native,** moves stacks holding pointers into themselves
  and repairs them by address-range guessing on callee-saved registers, leaving addresses spilled in frames
  stale; its fixes this year are the hazards the contract below names. A stress mode that moves the stack
  at every check is how to avoid the same fate.
- **Candidates for 242:** Go's invariant (stack addresses flow only down the call tree, never into the heap)
  and its per-function stack objects; no callee-saved registers through LLVM's `preserve_nonecc` (x86-64,
  AArch64), which moves the question from registers to spill slots; or recording where callee-saved
  registers were saved, as .NET's stack walker does, plus which of them hold stack addresses.
- **The heap side has more options than the stack side.** Statepoints already cover heap references
  (spilled by default, or in callee-saved registers found by unwinding), and conservative stack scanning
  with pinning comes within 2–3% of an exact collector (Conservative Immix); neither helps a stack copier,
  which must know exactly which words are stack addresses.

## The contract a replacement must meet

Root tracking and stack moving need the same guarantee from compiled code, so whatever describes frames
should provide both:

> At every point where the runtime can stop a fiber (every call that can reach a safepoint or a stack
> check), every live value the runtime must find is in a location it can locate, and the code reads it
> back from there afterwards.

- **For the collector:** live references to heap objects, which it may move (today's statepoint roots and
  176's shaped roots).
- **For stack moving:** live addresses into the fiber's stack (stack-promoted objects, struct-return and
  by-reference slots, any address LLVM computed from a frame), which the stack copier moves. The copier
  also fixes the frame-pointer chain, the arguments in registers at a stack check, and the runtime's own
  records pointing into stacks; escape analysis keeps the heap from pointing into stacks.
- **For interprocedural stack promotion:** a promoted object passed to a callee is a stack address the
  callee holds, covered by the line above, and its managed fields are roots scanned in place (176.4).

The hard part is the second line on stock LLVM: nothing at the IR level stops LLVM keeping a frame address
it computed before a call in a callee-saved register after it. A replacement meets it either by an IR
discipline LLVM cannot defeat (a stack address is used after a call only as a value reloaded from its
recorded slot, as 176's shaped homes reload roots), or by a machine-level pass after register allocation
that records where such values live (LLVM is built from source, so such a pass can be compiled into it).
Proving the chosen route keeps no stray copy is the feasibility question (243), and should come with a
stress mode that moves a stack at every check and makes the old stack inaccessible, so a stale address
faults. This summary is the starting point for 241, which owns the contract from here.

## After the decision

Children added from the decision, in two groups. **Implementation:**

- **The frame-table format:** entry layout, how shaped roots and frame sizes are stored, lookup, size per
  record; one format both walkers read.
- **The link-time step that builds it,** and how it handles dead-stripped functions, folded duplicate copies
  and multiple images. One avenue: a per-function frame-table section with `S_ATTR_LIVE_SUPPORT`, one atom
  per function, so ld64 drops an entry with its function, as for `eh_frame`; whether ld64 also drops the
  atom of a folded-away copy is untested.
- **The producer** (in codegen) and **the runtime's readers;** then 104's stack copier.

**After a working system:** verification beyond the stress modes (for example, checking that generated
code keeps no untracked copy, across the suite and large programs); generalizing it for other languages
(244's findings acted on); polish (diagnostics, tooling, the frame table's
size and lookup speed). 194 stays open until these are done.

## Dependencies & triggers

- See also [195](195-link-time-gc-frame-index.md): the link-time frame index over today's LLVM stackmaps,
  which a new frame format would feed.
- **Gates [104](104-fiber-stack-strategy.md)'s stack copier:** copying stacks needs the contract above; if
  no route meets it, 104 falls back to segmented stacks.
- **Gates interprocedural stack promotion** ([148](148-ssair-optimizer-tier.md) §148.1, 176.4).
- Interacts with [176](176-shaped-gc-roots.md), [129](129-tail-call-optimization.md),
  [177](177-register-resident-gc-roots.md), [150](150-selfhosted-gc-ladder.md).
