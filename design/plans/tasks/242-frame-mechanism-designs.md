# Frame mechanism designs: candidates judged against the contract

**Avenue:** Risk · **Type/Lifecycle:** `design` · **Size:** L · **Status:** done; fourth of
[194](194-gc-frame-metadata.md)'s children (after 241) · **Source:** 194

## Deliverable

The candidate mechanisms for meeting [241](241-frame-contract.md)'s contract, each described well enough to
build, judged requirement by requirement, with its failure modes and costs, and a leading candidate for 243
to try to falsify.

## Candidates known so far

- **Keep statepoints,** extended where they fall short (whether stack addresses can be tracked values; what
  the rewriter's `addrspacecast` rejection rules out).
- **An IR discipline:** every tracked value, heap reference or stack address, lives across a stopping point
  in a recorded frame slot and is read back from it afterwards (176's shaped homes generalized), with frame
  offsets recovered after code generation. Open: whether LLVM can still reuse an address it computed
  before the call, and how that is ruled out.
- **A machine-level pass** after register allocation, compiled into Nomu's LLVM build, recording where each
  tracked value lives at each stopping point.
- **Nomu's own IR passes where LLVM's ordering causes friction:** passes that run after the statepoint
  rewrite (for example, optimizing once safepoints exist, so that a pointer turned into an integer, as in
  [240](240-statepoint-inventory.md)'s hoisted barrier address, is seen against the safepoints), or a pass of
  Nomu's replacing an LLVM pass (the rewrite itself among them). Problems 9–12 of the inventory are this
  kind of friction.
- Others from [239](239-frame-metadata-prior-art.md): no callee-saved registers (`preserve_nonecc`, as Go
  and Manticore chose); recording where callee-saved registers were saved and which hold stack addresses
  (.NET's stack walker); Go's stack objects and its rule that stack addresses only flow down the call tree.

## Judged in this order

Soundness first, as a gate ([241](241-frame-contract.md), "Priorities"); then run-time performance and
predictability; then implementation and maintenance cost.

## For each

How it meets each requirement; what it costs at run time (spills, reloads, code size) and in maintenance;
what it does to the optimizer; how its frame table is produced; how it fails when wrong, and whether 243's
stress modes would catch that.

## Output

The comparison is [`internals/frames-designs.md`](../../internals/frames-designs.md), the design half of part 6
of 245's series: four layers (recording, no stray copies, the frame table, the stack), five candidates
judged against the contract, and the leading one, **extended statepoints** (a Nomu GC strategy where
`addrspace(1)` means "may be managed or on a stack", `ni:1`, a machine pass keeping frame addresses out of
registers across stops, a per-function frame table), with six claims for 243 to try to break. Found on the
way: the managed address space is integral today (inventory problem 23).

## Refs

[194](194-gc-frame-metadata.md); [241](241-frame-contract.md); [239](239-frame-metadata-prior-art.md);
[240](240-statepoint-inventory.md); [176](176-shaped-gc-roots.md).
