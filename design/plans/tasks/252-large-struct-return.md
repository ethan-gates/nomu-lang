# Large structs returned by value

**Avenue:** Risk · **Type/Lifecycle:** `bug` · **Size:** M · **Status:** done ·
**Source:** found probing [251](251-erased-generic-objects.md) 251.9

## What

A call returning a value too large for the return registers (over 8 words on arm64) miscompiled. It needed no
generics or fibers, and it predates the working tree. A 9-field or larger result read 0 from a simple caller and
segfaulted the compiler from a recursive one, in debug and release. Inlining hid it: SSAIR's inliner took `make` up
to 11 fields, and LLVM's took the rest in release.

## Cause

LLVM demotes such a return to a hidden result pointer, in `x8` on arm64, and loads each field after the call.
`lowerCallFromStatepointLoweringInfo` (`StatepointLowering.cpp`) walks back from the result to find the call, and
accepts one `LOAD` or a run of `CopyFromReg`. Several fields give a `TokenFactor`, which fails an assert that is off
in our build, and the calls disappear from the code. The hidden pointer is also an address into the caller's frame
that the frame tracking cannot see, so a stack move during the callee would have left it stale.

## Steps

- **252.1** Do the demotion ourselves. **Done.** The pass `nomu-indirect-large-values` (`LargeValues.cpp`) runs
  after optimization, so it sees only calls that survived inlining. A function returning a type over 8 registers
  takes a result pointer as a new first parameter, marked with `nomu.frame.addr` so it is tracked. A caller passes a
  slot in its frame and loads the result right after the call. A call whose result is returned at once passes its
  own pointer along. The rule depends only on the type, so definitions, declarations, direct and indirect calls and
  function pointers agree with no other coordination. The result is written at `ret` and loaded right after the
  call, so the slot holds no reference at a stop.

  Also fixed by this: `twin(make())` (`Cannot select`) and the 300-field `fiber let`, in both modes. By-value
  arguments of 20 fields were already correct. Test: `large_return` in the stack-move matrix: a recursive, a
  forwarded, an interface and a closure return with managed fields. It fails on the compiler from before the fix.
  It needed 252.4 to pass in release.
- **252.2** Frames over the limit from large values. **Done.** A frame-split wrapper must stay small and fixed, or
  splitting cannot help, and two things broke that. LLVM rewrote the internal body's return, so the wrapper rebuilt
  the value in a slot of its own: 848 bytes at 80 words. The body now takes the wrapper's linkage, or `weak_odr`, and
  is hidden, so its signature stays. And a wrapper forwarding a large by-value argument laid it out as outgoing
  arguments, which failed from 80 words in debug and release. `nomu-indirect-large-values` now also passes large
  parameters by pointer once a signature's large parameters pass 40 words. A callee loads the value at entry, before
  its stack check, and a call with no stop since entry passes the pointer along, so a wrapper needs no slot.

  The limit comes from measurement, in a recursive call passing the value on, against stack arguments:

  | Words | Reads a few fields | Reads all |
  |---:|---|---|
  | 9 | +41% | +38% |
  | 20 | +23% | +10% |
  | 40 | -3% | -6% |
  | 41, with the rule | +6% | -9% |
  | 60 and up | stack arguments do not compile | |

  The retry loop now stops once no frame asks for more room, and names each function and size. Test:
  `large_argument` in the stack-move matrix, which fails to compile before this. Buffers sized at runtime are outside
  this: that is 251.9.

  Forwarding through a wrapper relies on the stack check's slow path never collecting, since the slot's references are
  not recorded. [236](236-fiber-preemption.md) must revisit this if it adds a stop at that check.
- **252.3** Roots lost in release: a shaped root recorded on a call was dropped when that call was inlined. A shaped
  value (`String`'s buffer word) is recorded in a `deopt` bundle on each call it is live across. LLVM's inliner
  merges the caller's bundle only into inner calls that already have one, so an inner call with none, such as
  `concat` in an inlined function that allocates, stopped with the value unrecorded. **Done.** The pass
  `nomu-bundle-calls` (`CallBundles.cpp`) gives every call that can stop an empty bundle before any inlining. A
  bundle stops tail recursion elimination, which cost `frames_strings` 77%, so release runs that first. Measured
  against the same compiler without the pass, best of 7, one carrier: every workload within noise, `frames_strings`
  -0.3%; `print_loop` swings from run to run with or without it. `__text` grew by 32 bytes on `frames_strings`, and the suite's
  time is unchanged. Test: `inlined_roots` in the stack-move matrix.
- **252.4** References lost inside aggregates. **Done.** `rewrite-statepoints-for-gc` tracks pointers, and skips an
  aggregate holding a reference without a word, because the check is an assert. So a struct value live across a
  stop kept its old reference after a moving collection. Release reached this when the optimizer sank an
  `extractvalue` past a call. Debug reached it directly: a by-value struct parameter read after a stop failed on 5
  GC legs. This is also why reductions with a print passed: a change in the code's shape moved the `extractvalue`.

  The pass `nomu-split-reference-aggregates` (`ReferenceAggregates.cpp`), last before the rewrite, reads each
  reference out as a pointer where the aggregate is defined. A use a stop may separate from the definition takes the
  pointer, or the aggregate rebuilt with it right before that use. Tests: `large_return` and `aggregate_param` in the
  stack-move matrix, which fail without it.

## Refs

`src/llvmpasses/LargeValues.cpp`, `CallBundles.cpp`, `ReferenceAggregates.cpp`; `LLVMBridge.swift` (the pipeline, the frame retry); `frames.md`; LLVM
`StatepointLowering.cpp`, `InlineFunction.cpp`; `LLVMGenRuntime.swift` (the `deopt` bundles); `shaped-roots.md`.
