# Prior art: moving collectors, stack maps and growable stacks

Part of the frames series ([frames.md](frames.md)). This part surveys how other language implementations
solved, or avoided, the two problems Nomu has: letting a collector move heap objects that compiled code
refers to, and growing a fiber's stack by moving it. Every claim cites a source; where a source could not
be read in full, that is said.

## The two problems in one paragraph

A moving collector relocates heap objects, so at every point where it can run, it must find every live
reference to a heap object, including those the compiled code holds in its frames and registers, and
update them. A stack that grows by copying relocates frames, so at every point where it can grow, the
runtime must find every live address *into the stack* and update it. Both ask the compiler the same thing:
say where each live value of a kind is, at each point the runtime can stop the code. They differ in which
values: heap references are a type the compiler can track from the source, while stack addresses are
created freely by the compiler itself (an address of a local, a struct passed by reference, a spilled
frame pointer).

## Ways to give a fiber a stack

| approach | how it grows | systems |
|---|---|---|
| fixed | never grows; either committed up front, or a large range reserved and committed as touched | Nomu today (128 KiB committed); Crystal (8 MiB reserved) |
| segmented | links a new segment when a check fails, unlinks it on return | gccgo, gollvm, Go before 1.3, Rust before 2013 |
| copying | allocates a larger stack, copies, fixes pointers into the old one | Go since 1.3, Manticore, OCaml 5, Java's virtual threads |
| copied to the same address | one stack per thread; a switch saves and restores the live part | Julia (`COPY_STACKS`) |
| stackless | the compiler turns suspendable functions into state machines on the heap | Kotlin |
| off the native stack | the language's frames live in a heap object the runtime owns | GHC |

**Segmented stacks** are simple for the compiler: nothing moves, so no pointer needs fixing. Their cost is
the *hot split*, a call at a segment boundary repeated in a loop, each time allocating and freeing a
segment. Go and Rust both left them for that reason. Go 1.3 moved to copying, and the hot-split case went
from 5.37 s to 1.26 s; Rust dropped them in November 2013, citing the hot split and the cost of calls into
C. On LLVM, segmented-stack prologues exist for x86 and 32-bit ARM and not for AArch64; GCC has them on
AArch64, and gccgo's port uses them because "there are no known ongoing or planned projects to add stack
copying to GCC for any architecture".
([Go contiguous stacks design](https://docs.google.com/document/d/1wAaf1rYoM4S4gtnPh0zOlGzWtrZFQ5suE8qr2sD8uWQ/pub);
[rust-dev](https://mail-archive.com/rust-dev@mozilla.org/msg06296.html);
[LLVM Segmented Stacks](https://llvm.org/docs/SegmentedStacks.html);
[Linaro, Split-Stack Support for GCCGO](https://linaro.atlassian.net/wiki/spaces/TCWGPUB/pages/25219337407/Split-Stack+Support+for+GCCGO))

**Copying stacks** keep each stack contiguous, so calls stay cheap at any depth, and a stack can start
small. They need every pointer into the stack found and fixed, which is the subject of the rest of this
part.

## Who copies stacks, and why it is sound for them

| system | compiler | pointers into the stack | callee-saved registers | how it is sound |
|---|---|---|---|---|
| Go | its own | yes, address-taken locals, passed down only | none | precise maps of every pointer word, including "stack objects"; escape analysis keeps pointers into the stack out of the heap and out of callers |
| Manticore | LLVM | none (Standard ML) | none, by choice | nothing to fix but return addresses and roots |
| OCaml 5 | its own | none in the language | n/a | fixes the exception-handler links and frame-pointer list |
| Java (Loom) | HotSpot's JITs | none in the language | described by oop maps | frames copied to and from heap "stack chunks" |
| .NET runtime async | RyuJIT | yes (byrefs) | tracked by the unwinder | byrefs are not kept across a suspension: a read after one gives null |
| Julia | LLVM | yes | yes | the stack returns to the same address, so nothing moves |
| Scala Native | LLVM | yes | yes | not fully: rebases by address-range heuristic (below) |

**Go** is the reference design. Its compiler guarantees that "pointers to data on the stack are only ever
passed down in the call tree", and records "for each pointer-sized word on the stack, whether it is a
pointer or not". The copier walks every frame of the new stack and adjusts each word that points into the
old one, including address-taken locals, which the compiler lists per function as stack objects. Its
calling convention has "no callee-save registers, so a call may overwrite any register that doesn't have a
fixed meaning": every value live across a call sits in a frame slot the maps describe, so walking frames
finds everything. The design names its own drawbacks: restrictions on future pointer-into-stack patterns,
and the runtime's C and assembly to audit. Growing by 25% at a time was 20% slower than doubling.
([design](https://docs.google.com/document/d/1wAaf1rYoM4S4gtnPh0zOlGzWtrZFQ5suE8qr2sD8uWQ/pub);
[internal ABI](https://go.dev/src/cmd/compile/abi-internal);
[runtime/mgcstack.go](https://go.googlesource.com/go/+/HEAD/src/runtime/mgcstack.go);
[stack copying walkthrough](https://golang.design/under-the-hood/en/part4memory/ch14stack/copy/))

**Manticore** is the nearest precedent on LLVM. Farvardin and Reppy (PLDI 2020) compared six stack
strategies on one LLVM backend, among them "resize": frames in a small contiguous region, "copied to a new
region that is twice as large when the stack overflows", under a generational copying collector that finds
roots through LLVM's stack maps. Resize was "slightly more efficient on average than segmented or hybrid".
Two conditions made it sound. Standard ML has no pointers into the stack; the one way to make one, a
reified continuation, was the hard case ("a pointer into the stack exists in the heap, so it is no longer
safe to move that frame"). And their compiler used no callee-saved registers: "Cheng et al. found that the
presence of callee-saved registers requires a two-pass approach when scanning the stack to compute the root
set. Because of this complexity, we did not implement callee-save registers in our compiler."
([Farvardin and Reppy, PLDI 2020](https://kavon.farvard.in/papers/pldi20-stacks.pdf))

**OCaml 5 and Java** copy stacks on their own compilers, in languages with no pointers into frames. OCaml's
fibers start at 16 words and double; reallocation rewrites the exception-handler links and the
frame-pointer list. Loom's virtual threads "freeze" frames into heap stack chunks and "thaw" them back,
with HotSpot's oop maps describing every reference.
([OCaml 5 effects notes](https://sparkles-docs.pages.dev/research/algebraic-effects/ocaml-effects);
[stack_realloc test](https://sources.debian.org/src/ocaml/5.4.0-3/testsuite/tests/frame-pointers/stack_realloc.ml);
[OpenJDK wiki, Loom](https://wiki.openjdk.org/x/UoAOAw))

**.NET** has pointers into frames (byrefs) and never moves a stack. Its new runtime-async design, which
captures a method's state at an `await`, sidesteps them: "By-ref variables may not be hoisted across
suspension points, and any read of a by-ref variable after a suspension point will produce null".
([runtime-async spec](https://github.com/dotnet/runtime/blob/main/docs/design/specs/runtime-async.md))

**Julia** copies stacks without moving them: all tasks on a thread share one stack base, and a switch saves
the live part to a heap buffer and later restores it to the same base. A stack address stays valid inside
its task and must not be handed to another. ([src/task.c](https://github.com/JuliaLang/julia/blob/master/src/task.c),
`save_stack`, `restore_stack`)

## The one LLVM attempt with pointers into the stack: Scala Native

Scala Native compiles through LLVM, and its delimited continuations (the base of its virtual threads) copy
a stack segment out on suspend and back on resume, at the current stack position or into a heap fragment,
so frames change address. The runtime must then fix addresses into the moved segment, and LLVM gives it no
list of them. Its code shows what it does instead
([delimcc.c](https://github.com/scala-native/scala-native/blob/main/nativelib/src/main/resources/scala-native/delimcc.c)):

- It rebases the saved stack and frame pointers and its own handler chain, which it knows about.
- It rebases a callee-saved register when its value falls inside the old segment's range, widened by slack:
  256 bytes below, since "callee-save spills can create pointers slightly below the captured top", and
  16 KiB above, because "false negatives cause SIGBUS".
- It leaves the words inside the copied frames alone: "Rewriting non-pointer values that happen to look like
  stack addresses can corrupt frame data under heavy continuation churn." A frame address spilled into a
  frame keeps its old value.

Its fixes this year are the hazards in practice: frame-pointer rebasing that was "incomplete/unsafe"
([#4797](https://github.com/scala-native/scala-native/pull/4797)), and ThinLTO keeping a thread-local
address "in a register across `scalanative_continuation_suspend`", read stale once the virtual thread
resumed on another carrier ([#5119](https://github.com/scala-native/scala-native/pull/5119), fixed by
turning off LTO for the runtime's C; Nomu re-reads its carrier-local slot after every call, so it already
avoids this one). Its collector does not move objects. The paper (Pham, Odersky,
Racordon, Zendra, ICOOOLPS 2024) reports "limitations with stack address stability"; its full text was not
read.

This is the gap made concrete. On stock LLVM, a runtime that moves a stack cannot know which registers and
spill slots hold addresses into it, so it guesses, and a guess is wrong in both directions: an integer that
looks like an address gets rewritten, and an address outside the guessed range is missed.

## Describing frames to a moving collector

The heap side is older and better served.

- **Compiler-emitted tables.** Diwan, Moss and Hudson (PLDI 1992) set out what an optimizing compiler must
  emit for a compacting collector: tables of live pointers, and of values *derived* from pointers (interior
  pointers, pointer arithmetic), at each point a collection can happen; they found the tables a modest
  fraction of code size and stack tracing a small part of collection time. (Abstract only; the full text
  is paywalled.) ([bibtex](https://bibtex.github.io/PLDI-1992-DiwanMH.html))
- **LLVM's statepoints** are this design for LLVM. Each heap reference live across a statepoint is spilled
  to a recorded slot and reloaded through `gc.relocate`, and the stack map lists the slots. Their docs list
  "Mixing References and Raw Pointers" and "Objects on the Stack" under "Limitations and Half Baked Ideas":
  an alloca can be listed so a stack object is scanned in place, but this "is not well exercised", and
  nothing covers moving the stack.
  ([LLVM Statepoints](https://llvm.org/docs/Statepoints.html))
- **Callee-saved registers.** By default LLVM spills every heap reference live across a statepoint
  (`max-registers-for-gc-values` is 0). Raised, references stay in registers, and with
  `fixup-allow-gcptr-in-csr` they can sit in callee-saved registers; the runtime then finds them by
  unwinding to where each callee saved its registers. That is the two-pass scan Cheng, Harper and Lee
  describe, and what .NET's stack walker does with its record of where each callee-saved register was
  spilled (`REGDISPLAY`).
  ([FixupStatepointCallerSaved.cpp](https://github.com/llvm/llvm-project/blob/main/llvm/lib/CodeGen/FixupStatepointCallerSaved.cpp);
  [StatepointLowering.cpp](https://github.com/llvm/llvm-project/blob/main/llvm/lib/CodeGen/SelectionDAG/StatepointLowering.cpp);
  [CLR ABI](https://github.com/dotnet/runtime/blob/main/docs/design/coreclr/botr/clr-abi.md))
- **Conservative stack scanning** avoids precise maps altogether: treat any stack word that might be a heap
  reference as one, and pin what it points to. Conservative Immix (Shahriyar, Blackburn, McKinley, OOPSLA
  2014) falsely retained under 0.01% of objects and pinned 0.03%, came within 2–3% of exact Immix, and its
  reference-counting variant beat a tuned exact generational collector. It cannot help a stack copier,
  which must rewrite each address it finds and so must know which words are addresses.
  ([paper](https://www.cs.utexas.edu/~mckinley/papers/conservative-gc-oopsla-2014.pdf))

## LLVM and runtimes that move the stack

GHC's runtime relocates heap-allocated stacks, and avoids LLVM's frames by keeping Haskell frames off the
native stack: the STG stack pointer is passed in an argument register, and LLVM's native stack holds only
spills. A 2018 request on llvm-dev asked LLVM to "treat the stack pointer as a volatile register that may be
changed by any function call", for GHC and llgo; otherwise GHC must "spill all locals to memory at every
call into the RTS". It got one reply and no resolution.
([LLVM blog, GHC and LLVM](https://blog.llvm.org/2010/05/glasgow-haskell-compiler-and-llvm.html);
[LLVM Discourse](https://discourse.llvm.org/t/llvm-and-heap-allocated-thread-stacks/49527))

SWAPSTACK (Dolan, Muralidharan, Gregg, TACO 2013) added fiber switching to a modified LLVM, as a calling
convention and an intrinsic. It covers switching between stacks only.
([paper](https://researchrepository.ul.ie/articles/journal_contribution/Compiler_support_for_lightweight_context_switching/19854355))

## What this means for Nomu

Every system that moves stacks soundly meets one of three conditions:

1. **No pointers into the stack** (Standard ML, OCaml, Java).
2. **No pointers into the stack across the point where it moves** (.NET's runtime async).
3. **Its own compiler, describing every frame word, with no callee-saved registers** (Go).

Nomu meets none of them. It has pointers into the stack by design (stack promotion is central to its
performance thesis, along with struct returns and by-reference arguments), they are live across calls that
can grow the stack, and it compiles through LLVM, whose calling conventions keep values in callee-saved
registers. The one LLVM system in the same position, Scala Native, repairs addresses by heuristic and
leaves some stale. No system was found that moves stacks soundly under all three of Nomu's conditions.

What can be borrowed:

- **Go's invariant on where stack addresses go.** Pointers into a stack only flow down the call tree and
  never into the heap. Nomu's escape analysis already keeps the heap from pointing into stacks; the
  copier needs the rest, with the frames that hold such pointers described.
- **Go's stack objects.** A per-function list of address-taken frame slots, so the copier knows which
  regions are objects and can scan them for pointers into the stack.
- **No callee-saved registers, as Go and Manticore chose.** LLVM has a convention for it:
  `preserve_nonecc` "doesn't preserve any general registers. So all general registers are caller saved
  registers", on x86-64, AArch64 and LoongArch. Under it every value live across a call is spilled to the
  caller's frame, which moves the question from registers to spill slots: those still need describing.
  Floating-point and vector registers keep their usual convention.
  ([LangRef, calling conventions](https://llvm.org/docs/LangRef.html#calling-conventions))
- **Or describe callee-saved registers, as .NET does.** Record, per frame, where each callee-saved register
  was spilled, and fix addresses through those records. LLVM's unwind information already says where
  callee-saved registers are saved; what it does not say is which hold stack addresses.
- **Scala Native's lesson.** A copier that guesses fails rarely and under load. Whatever 242 chooses needs
  the stress mode 194 calls for: move the stack at every check and make the old one inaccessible, so a
  missed address faults at once.

These feed [242](../plans/tasks/242-frame-mechanism-designs.md)'s candidate designs.
