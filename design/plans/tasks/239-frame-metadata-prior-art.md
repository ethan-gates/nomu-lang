# Frame metadata prior art: moving collectors, stack maps and growable stacks

**Avenue:** Risk · **Type/Lifecycle:** `research` · **Size:** M · **Status:** done; first of
[194](194-gc-frame-metadata.md)'s children · **Source:** 194

## Deliverable

A cited survey of how language implementations describe frames to a moving collector and grow fiber
stacks, on LLVM and elsewhere: what each built, what it gave up, and why. It tells 194 whether its problem
has been solved before, and what 242's candidate designs can borrow.

## Questions

- **On LLVM:** who runs a moving collector over LLVM-compiled frames, and how (statepoints and their
  origin in Azul's Falcon JIT, `gcroot` and shadow stacks, conservative scanning)? Who grows stacks, and
  how (segmented stacks in gccgo, gollvm and early Rust; Julia's copy stacks; GHC keeping its stack off
  the native one)? Has anyone combined a moving collector, copying native stacks and LLVM's optimizer over
  the same frames, and if they tried and stopped, why?
- **Off LLVM:** how Go's compiler and runtime find every pointer into a stack (stack maps, its calling
  convention keeping nothing in registers across a call); OCaml 5's growable fiber stacks; the JVMs'
  (HotSpot's and others') frame maps and their relation to their JITs; .NET's GC info; V8's.
- **Research:** papers on precise stack maps under optimizing compilers, on relocating pointers into stacks,
  and on stack maps for separately compiled native code.
- **LLVM's own history:** discussions on the LLVM forums and mailing lists about statepoints' limits, about
  pointers into frames across safepoints, and about split stacks on AArch64.

Memory is not a source here: each claim cites a document, a paper, a commit or code.

## Output

The survey is [`internals/frames-prior-art.md`](../../internals/frames-prior-art.md), the prior-art part of 245's series;
what bears on the decision is listed in 194 ("What prior art says"). Three papers were read only through
their abstracts or through papers quoting them (Diwan, Moss and Hudson 1992; Cheng, Harper and Lee 1998;
the Scala Native paper); the survey says so where it cites them.

## Refs

[194](194-gc-frame-metadata.md); [104](104-fiber-stack-strategy.md) (the stack options); [176](176-shaped-gc-roots.md).
