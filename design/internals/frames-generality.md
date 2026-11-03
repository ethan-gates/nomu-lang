# Limits and generality: what another LLVM language could reuse

One of the frames design documents ([frames.md](frames.md)); the output of task 244. The contract and
the designs describe what Nomu built so a moving collector and copying fiber stacks are sound on LLVM. This part asks how much of it
another language could use: which parts are plain LLVM, which rest on guarantees Nomu's frontend and runtime
give, what a language must guarantee to use it, and how it could be packaged.

## What was built, by layer

| piece | where | depends on |
|---|---|---|
| `ni:1` (managed pointers non-integral) | datalayout | LLVM only |
| the statepoint rewrite and stack maps | stock LLVM (`rewrite-statepoints-for-gc`) | LLVM only |
| **K2**, the frame-address split: a value computed from a frame index and live across a statepoint is recomputed after it | `src/llvmpasses/FrameAddressSplit.cpp`, a machine pass added through `RegisterTargetPassConfigCallback` | LLVM only (the pinned LLVM 23 has the hook; the pass uses `STATEPOINT` and `TargetInstrInfo::isAddImmediate`) |
| **the tracking**: a marked pointer and the pointers derived from it become `addrspace(1)` values the rewrite records | `src/llvmpasses/TrackFrameAddresses.cpp`, the new-PM pass `nomu-track-frame-addresses`, between the optimizer and the rewrite | LLVM only, given the markers |
| **the markers**: which pointers may point into a caller's frame | Nomu's egress (`markFrameAddress`) | the frontend's knowledge of its values |
| the frame index (return address → record, frame size) | Nomu's driver, after the link | the stack-map format; any language can build one |
| the copier: copy, fix `sp`/`fp`, the frame-pointer chain, recorded words in the old range | `runtime/stackmove.nomu` | frame pointers kept; the runtime's own records |
| the collector's filter: a recorded word is traced only if it is a managed object | `rtKeepManagedSlots` | the heap's layout (Immix range, large-object list) |
| the stress mode: move at every resume, protect the old stack | `NOMU_STACK_MOVE` | the runtime's scheduler |

About 500 lines of C++ against LLVM's API carry the part another LLVM language would reuse directly. The rest
is a convention (the markers) and runtime code every language writes for itself.

## What depends only on LLVM

- **The two passes are target-independent code**, verified on arm64 only. K2 recognizes a frame-address
  computation as an instruction with a frame-index operand, no memory access and one virtual-register
  result, and follows copies and adds of an immediate through `isAddImmediate`. On a target that does not
  implement `isAddImmediate`, an offset address becomes a value K2 cannot recompute; it counts these
  (`NOMU_FRAME_SPLIT_STATS`), and the static scan finds what reaches the machine code.
- **The tracking needs only a marker convention.** The marker is an identity call the optimizer cannot see
  through; the transform turns it into an identity inline asm producing an `addrspace(1)` value (marked
  `gc-leaf-function`), rebuilds GEPs, PHIs and selects in that space, and converts back right before every
  other use. Nothing in it knows Nomu's types.
- **The stack-map consumer rules are general:** every recorded word is a pointer; the copier adjusts a word
  only if it lies in the old stack; the collector traces a word only if it is a managed object. Range testing
  is sound because every word tested is known to be a pointer, which is what Scala Native's register rebasing
  lacked ([prior art](frames-prior-art.md)).

## What depends on Nomu's frontend and runtime

Each of these is a guarantee the mechanism assumes. Another language must give the same guarantee or
replace the part.

1. **Pointers into a stack go only down the call tree** (contract G1). Nomu's escape analysis keeps them
   out of the heap, globals and other fibers. The copier fixes only recorded words, the frame-pointer chain
   and the runtime's own records; a stack address stored anywhere else is missed.
2. **No frame memory holds a stack address across a stop**, except the runtime's records. Statepoints
   describe SSA values live across a call, not memory. Go's maps describe every pointer word of a frame, so
   Go can store a stack address in a stack object; this mechanism cannot. In Nomu nothing does: a promoted
   object never reaches a callee (every call argument escapes), the shadow stack is a runtime record, and a
   runtime-sized buffer's address is marked.
3. **The frontend marks every possibly-stack pointer.** Nomu marks a field-writing method's receiver, an
   erased generic's buffers and runtime-sized allocations. A frontend that marks too few leaves stale
   addresses (the stress mode finds them); one that marks too many pays a spill per stop per value, which
   claim 5 measured as no visible cost for one value in a hot loop.
4. **No marked pointer points inside a heap object.** The collector's filter treats any recorded word in the
   heap as an object start. Nomu's invariant I12 keeps interior heap pointers off stops. A language with
   interior pointers (Go's, C#'s byrefs) needs the collector to find an object from an interior address, or
   must record the pair: the statepoint rewrite records derived pointers with their base, but a marked
   pointer has no known base.
5. **Code Nomu does not own never holds a stack address across a stop** (G2). C runs on the carrier's stack
   (104's rule) and cannot stop.
6. **The runtime holds no stack address across its own stops** (G3). The stress mode found two places that
   did (the allocation slow path's anchor, `rtReadLine`'s), and the generated code's saved shadow-stack top;
   all three now hold an offset from the stack top. A runtime written in C has the same obligation and no
   compiler to help: it must be audited, as Go's design says of its C and assembly.
7. **Frame pointers are kept** (`frame-pointer=non-leaf`), so the copier can fix the chain without unwind
   information.

## Preconditions, and the features that break them

| language feature | breaks | what it would take |
|---|---|---|
| passing a stack address to C that keeps it, or a C callback into code that can stop | 5 | run C on a separate stack (Go's cgo, Nomu's carrier-stack rule) and forbid callbacks that stop, or pin the stack while C frames are on it |
| unrestricted address-taking (`&local` stored anywhere) | 1, 2 | escape analysis that moves escaping locals to the heap (Go's), and either keeps stack addresses out of frame memory or describes those slots |
| interior pointers into heap objects | 4 | an object-start lookup in the collector, or base-tracked markers |
| threads with native stacks sharing pointers with fibers | 1 | native stacks never move, so pointers into them are fine; pointers from a native thread into a fiber's stack are not |
| a runtime in C | 6 | an audit, or the runtime's stack addresses kept as offsets |
| inline asm or intrinsics producing stack addresses | 3 | marking their results, as Nomu does for runtime-sized allocations |

A language with no pointers into its stacks needs none of the frontend work: stock statepoints and a copier
that fixes the frame-pointer chain suffice, as Manticore showed. The mechanism is for languages that have
such pointers and still want their stacks to move, which [prior art](frames-prior-art.md) found no LLVM
language doing soundly.

## Packaging

Three ways to offer it to others, by what each would take:

- **A library over LLVM.** The two passes as a C++ library with a small C API: register K2 for a process, a
  pass runner that knows the tracking's name (`nomuRunPasses`, `LLVMRunPasses` with Nomu's passes
  registered), and a documented marker. A frontend adds the markers, links the library, puts
  `nomu-track-frame-addresses` before `rewrite-statepoints-for-gc` in its pipeline, and writes its own copier
  and collector filter against the stack maps. This is what Nomu has now; making it a library is renaming
  the marker and writing the API documentation. It follows LLVM's C++ API, so it must be rebuilt and checked
  on each LLVM upgrade. A frontend driving `opt` instead would load the same passes as a plugin.
- **Upstream.** LLVM's statepoint documentation lists "Objects on the Stack" and "Mixing References and Raw
  Pointers" as incomplete; this is a design for both. A proposal would replace the inline-asm trick with an
  intrinsic the rewrite understands (a "frame address" value it records like a reference but no collector
  traces) and make K2 part of statepoint lowering. It needs an RFC, a second user, and tests on x86-64 as
  well as AArch64; the statepoint code has few active maintainers.

## Limits

- Verified on arm64 (Apple Silicon) only. Nothing in the passes is target-specific beyond
  `isAddImmediate`, but the claims are tested on one target.
- A stack moves only at a resume today; a move at a function-entry check (104) adds one more state, the
  arguments still in registers (contract R8), which statepoints do not describe.
- Callee-saved registers in a suspended fiber's saved context are not adjusted. K2 and the tracking ensure
  no stack address is in one across a stop; the mechanism does not handle code that breaks that, such as C.

## Refs

[244](../plans/tasks/244-frame-mechanism-generality.md); [prior art](frames-prior-art.md);
[the contract](frames-contract.md); [the designs](frames-designs.md);
[243's results](../plans/tasks/243-frame-mechanism-feasibility.md).
